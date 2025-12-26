# 🌐 Kubernetes Networking Fundamentals

> **Reference**: [Kubernetes Official Documentation - Services, Load Balancing, and Networking](https://kubernetes.io/docs/concepts/services-networking/)

---

## 📋 Table of Contents

1. [Core Network Model](#core-network-model)
2. [Container-to-Container Communication](#container-to-container-communication)
3. [Pod-to-Pod Communication](#pod-to-pod-communication)
4. [Service Discovery and Load Balancing](#service-discovery-and-load-balancing)
5. [External Access Patterns](#external-access-patterns)
6. [Network Policies](#network-policies)
7. [DNS Resolution](#dns-resolution)
8. [Summary Reference](#summary-reference)

---

## �� Core Network Model

### Fundamental Principles

Kubernetes networking is built on these core requirements:

1. **Every Pod gets its own unique cluster-wide IP address**
2. **All Pods can communicate with all other Pods without NAT** (Network Address Translation)
3. **Agents on a node can communicate with all Pods on that node**
4. **Pods share their network namespace with their containers**

> �� This flat networking model simplifies application deployment compared to traditional NAT-based container systems.

### Architecture Components

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                            │
│                                                                   │
│  ┌────────────────┐                    ┌────────────────┐       │
│  │   Control      │                    │   Worker       │       │
│  │   Plane        │                    │   Node         │       │
│  │                │                    │                │       │
│  │  ┌──────────┐  │                    │  ┌──────────┐  │       │
│  │  │ API      │◄─┼────────────────────┼─►│ kubelet  │  │       │
│  │  │ Server   │  │                    │  └──────────┘  │       │
│  │  └──────────┘  │                    │                │       │
│  │                │                    │  ┌──────────┐  │       │
│  │                │                    │  │kube-proxy│  │       │
│  │                │                    │  └──────────┘  │       │
│  │                │                    │                │       │
│  │                │                    │  ┌──────────┐  │       │
│  │                │                    │  │   CNI    │  │       │
│  │                │                    │  │  Plugin  │  │       │
│  │                │                    │  └──────────┘  │       │
│  │                │                    │                │       │
│  │                │                    │  ┌──────────┐  │       │
│  │                │                    │  │  Pods    │  │       │
│  │                │                    │  └──────────┘  │       │
│  └────────────────┘                    └────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Responsibility | Implementation |
|-----------|---------------|----------------|
| **Container Runtime** | Pod network namespace setup | CRI-compatible runtime (containerd, CRI-O) |
| **CNI Plugin** | Pod network implementation | Calico, Flannel, Cilium, Weave, etc. |
| **kube-proxy** | Service proxy and load balancing | iptables, IPVS, or eBPF modes |
| **CoreDNS** | Service discovery via DNS | DNS server for cluster |
| **Network Policy** | Traffic filtering rules | Implemented by CNI plugin |

---

## 🌐 Understanding Kubernetes Networks

Kubernetes uses three distinct network address spaces that work together:

### 1. Node Network (Underlay/Physical Network)

The **Node Network** is the physical or VM network where Kubernetes nodes reside.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Node Network (Underlay)                       │
│                    Example: 10.10.20.0/22                        │
│                    (Your cluster configuration)                  │
│                                                                  │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│   │ Control Node │  │  Worker-1    │  │  Worker-2    │         │
│   │ 10.10.20.3   │  │ 10.10.20.4   │  │ 10.10.20.5   │         │
│   └──────────────┘  └──────────────┘  └──────────────┘         │
│                                                                  │
│   • Physical/VM network interfaces                              │
│   • SSH access, node-to-node communication                      │
│   • External connectivity                                       │
└─────────────────────────────────────────────────────────────────┘
```

**Characteristics**:
- **Purpose**: Node-to-node communication, external access
- **CIDR Example**: `10.10.20.0/22`
  - Control plane: 10.10.20.3
  - Worker 1: 10.10.20.4
  - Worker 2: 10.10.20.5
- **Assignment**: By infrastructure (DHCP, static, cloud provider)
- **Visibility**: Routable within your data center/VPC
- **Used For**: 
  - SSH into nodes
  - kubelet → API server communication
  - Node-to-node CNI traffic
  - External client → NodePort/LoadBalancer

### 2. Pod Network (Overlay Network)

The **Pod Network** is a virtual network managed by the CNI plugin where Pods get their IP addresses.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Pod Network (Overlay)                         │
│                   Example: 10.8.0.0/16                           │
│                   (Your cluster configuration)                   │
│                                                                  │
│  ┌─────────────────────┐           ┌─────────────────────┐      │
│  │   Worker-1          │           │   Worker-2          │      │
│  │   10.8.0.0/24       │           │   10.8.1.0/24       │      │
│  │                     │           │                     │      │
│  │  ┌──────────────┐   │           │  ┌──────────────┐   │      │
│  │  │ Pod A        │   │           │  │ Pod D        │   │      │
│  │  │ 10.8.0.5     │   │           │  │ 10.8.1.10    │   │      │
│  │  └──────────────┘   │           │  └──────────────┘   │      │
│  │                     │           │                     │      │
│  │  ┌──────────────┐   │           │  ┌──────────────┐   │      │
│  │  │ Pod B        │   │           │  │ Pod E        │   │      │
│  │  │ 10.8.0.8     │   │           │  │ 10.8.1.15    │   │      │
│  │  └──────────────┘   │           │  └──────────────┘   │      │
│  │                     │           │                     │      │
│  │  ┌──────────────┐   │           │  ┌──────────────┐   │      │
│  │  │ Pod C        │   │           │  │ Pod F        │   │      │
│  │  │ 10.8.0.12    │   │           │  │ 10.8.1.20    │   │      │
│  │  └──────────────┘   │           │  └──────────────┘   │      │
│  └─────────────────────┘           └─────────────────────┘      │
│                                                                  │
│   • Each Pod gets unique IP from this range                     │
│   • Managed by CNI plugin (Calico, Flannel, etc.)              │
│   • Typically not routable outside cluster                      │
└─────────────────────────────────────────────────────────────────┘
```

**Characteristics**:
- **Purpose**: Pod-to-Pod communication across the cluster
- **CIDR Example**: `10.8.0.0/16`
- **Configuration**: Set during cluster initialization
  ```bash
  # Example kubeadm init
  kubeadm init --pod-network-cidr=10.8.0.0/16
  ```
- **Visibility**: Cluster-wide, not exposed externally
- **Used For**:
  - Direct Pod-to-Pod communication
  - Container-to-container within Pod via localhost
  - Kubernetes internal networking

**IPAM (IP Address Management) - How CNI Plugins Handle IP Allocation**:

Different CNI plugins handle IP allocation differently:

**1. Kubernetes-Managed IPAM (Flannel, kube-router)**:
- Kubernetes controller-manager allocates `podCIDR` per node from `--pod-network-cidr`
- Node gets assigned a sequential subnet (e.g., `/24`) in `node.spec.podCIDR`
- CNI plugin reads this `podCIDR` and assigns Pod IPs from it
- Allocation is **sequential and predictable**

```yaml
# Example: Node with Kubernetes-assigned Pod CIDR
apiVersion: v1
kind: Node
metadata:
  name: k8s-w1
spec:
  podCIDR: 10.8.0.0/24      # Assigned by K8s controller-manager
  podCIDRs:
  - 10.8.0.0/24
```

**2. CNI-Managed IPAM (Calico, Cilium)**:
- CNI plugin has its own IPAM system - **ignores `node.spec.podCIDR`**
- Uses custom resources (Calico: IPPools, Cilium: CiliumNode)
- Allocates IP blocks **dynamically** as nodes join and Pods are created
- **Calico**: 
  - Default block size is `/26` (62 IPs per block)
  - Allocates blocks on-demand from IPPool
  - Multiple blocks can be allocated to same node if needed
  - Allocation is **dynamic, not sequential**
- **Cilium**:
  - Configurable via CiliumNode resource
  - Similar dynamic allocation

```yaml
# Calico IPPool (defines available IP ranges)
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: 10.8.0.0/16        # Total available range
  blockSize: 26            # Default: /26 blocks (62 IPs each)
  ipipMode: Always
  natOutgoing: true
```

**Key Differences**:

| Aspect | Kubernetes IPAM (Flannel) | CNI IPAM (Calico) |
|--------|---------------------------|-------------------|
| **Allocation Source** | K8s controller-manager | CNI plugin's IPAM |
| **Uses node.spec.podCIDR** | ✅ Yes | ❌ No (ignores it) |
| **Allocation Pattern** | Sequential per node | Dynamic on-demand |
| **Default Block Size** | `/24` (configurable) | `/26` (Calico default) |
| **Flexibility** | Fixed per node | Multiple blocks per node |

**Checking Allocations**:

```bash
# View Kubernetes-assigned Pod CIDR (Flannel uses this)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'

# Calico-specific: View IP pools and allocations
kubectl get ippools.crd.projectcalico.org -o wide

# Cilium-specific: View node allocations
kubectl get ciliumnodes -o wide
```

### 3. Service Network (ClusterIP Range)

The **Service Network** is a virtual network for Service objects - these IPs don't actually exist on any interface.

```
┌─────────────────────────────────────────────────────────────────┐
│                   Service Network (Virtual)                      │
│                   Example: 10.96.0.0/12                          │
│                   (Default Kubernetes range)                     │
│                                                                  │
│                   ┌─────────────────────┐                        │
│                   │  Service: frontend  │                        │
│                   │  ClusterIP:         │                        │
│                   │  10.96.10.50:80     │                        │
│                   └──────────┬──────────┘                        │
│                              │                                   │
│                   kube-proxy creates rules                       │
│                              │                                   │
│                ┌─────────────┼─────────────┐                     │
│                │             │             │                     │
│           ┌────▼───┐    ┌───▼────┐   ┌───▼────┐                 │
│           │ Pod A  │    │ Pod B  │   │ Pod C  │                 │
│           │10.10.  │    │10.10.  │   │10.10.  │                 │
│           │20.5:80 │    │20.8:80 │   │21.10:80│                 │
│           └────────┘    └────────┘   └────────┘                 │
│                                                                  │
│   • Virtual IPs - no actual network interface                   │
│   • Managed by kube-proxy using iptables/IPVS                  │
│   • Load balances to Pod IPs                                   │
└─────────────────────────────────────────────────────────────────┘
```

**Characteristics**:
- **Purpose**: Stable endpoints for Services (load balancing)
- **CIDR Example**: `10.96.0.0/12` (default Kubernetes)
  - Provides 1,048,576 IP addresses
  - Can be customized: `10.32.0.0/16`, `172.20.0.0/16`, etc.
- **Assignment**: API server assigns IPs to Service objects
- **Visibility**: Only within cluster, virtual/non-routable
- **Configuration**: Set during API server startup
  ```bash
  # API server flag
  --service-cluster-ip-range=10.96.0.0/12
  ```
- **Used For**:
  - Service discovery via DNS
  - Load balancing traffic to Pods
  - Stable virtual IPs that don't change

### Network Relationships and Data Flow

Here's how all three networks interact:

```
┌──────────────────────────────────────────────────────────────────┐
│                    Complete Network Architecture                  │
│                                                                   │
│  External Client (Internet/Corporate Network)                    │
│         │                                                         │
│         │ (1) Access via NodePort/LoadBalancer                   │
│         ▼                                                         │
│  ┌─────────────────────────────────────────────────┐             │
│  │  Node Network: 10.10.20.0/22                    │             │
│  │                                                  │             │
│  │  ┌────────────┐         ┌─────────────┐        │             │
│  │  │  Worker-1  │         │  Worker-2   │        │             │
│  │  │10.10.20.4  │         │10.10.20.5   │        │             │
│  │  └─────┬──────┘         └──────┬──────┘        │             │
│  └────────┼───────────────────────┼───────────────┘             │
│           │                       │                              │
│           │ (2) kube-proxy routes to Pod IPs                     │
│           │                       │                              │
│  ┌────────┼───────────────────────┼───────────────┐             │
│  │        │  Pod Network: 10.8.0.0/16             │             │
│  │        │                       │                │             │
│  │  ┌─────▼──────┐         ┌─────▼──────┐         │             │
│  │  │ 10.8.0.0/24│         │ 10.8.1.0/24│         │             │
│  │  │            │         │             │         │             │
│  │  │ ┌────────┐ │         │ ┌─────────┐ │         │             │
│  │  │ │Pod A   │ │         │ │Pod D    │ │         │             │
│  │  │ │10.8.   │ │         │ │10.8.    │ │         │             │
│  │  │ │0.5     │ │         │ │1.10     │ │         │             │
│  │  │ └────────┘ │         │ └─────────┘ │         │             │
│  │  └────────────┘         └─────────────┘         │             │
│  └───────────────────────────────────────────────────            │
│           ▲                                                       │
│           │                                                       │
│           │ (3) Service translates ClusterIP → Pod IPs           │
│           │                                                       │
│  ┌────────┴──────────────────────────────────────┐               │
│  │  Service Network: 10.96.0.0/12 (Virtual)     │               │
│  │                                                │               │
│  │  Service: frontend                            │               │
│  │  ClusterIP: 10.96.10.50:80                   │               │
│  │  Endpoints: 10.8.0.5:80, 10.8.1.10:80        │               │
│  └────────────────────────────────────────────────               │
└──────────────────────────────────────────────────────────────────┘

Traffic Flow Example:
1. Client accesses: http://10.10.20.4:30080 (NodePort on Worker-1)
2. kube-proxy on node routes to Service ClusterIP 10.96.10.50:80
3. Service load-balances to Pod IPs: 10.8.0.5:80 or 10.8.1.10:80
4. Pod receives and processes request
5. Response flows back through the same path
```

### Network Configuration Summary

| Network Type | Example CIDR | Purpose | Routable | Configured By |
|--------------|--------------|---------|----------|---------------|
| **Node Network** | `10.10.20.0/22` | Physical node connectivity | Yes (within infra) | Infrastructure/Cloud |
| **Pod Network** | `10.8.0.0/16` | Pod-to-Pod communication | No (cluster internal) | CNI Plugin |
| **Service Network** | `10.96.0.0/12` | Service virtual IPs | No (virtual only) | Kubernetes API |

### Important Network Rules

✅ **Networks must NOT overlap**:
```bash
# ❌ BAD - Overlapping ranges
Node Network:    10.8.0.0/16
Pod Network:     10.8.0.0/16    # Overlaps!
Service Network: 10.96.0.0/12   # OK

# ✅ GOOD - Non-overlapping ranges (Example Configuration)
Node Network:    10.10.20.0/22
Pod Network:     10.8.0.0/16
Service Network: 10.96.0.0/12
```

✅ **Typical CIDR Sizing**:
- **Node Network**: Match your existing infrastructure
- **Pod Network**: 
  - Small cluster: `/24` per node, `/16` total
  - Medium cluster: `/24` per node, `/16` or `/12` total
  - Large cluster: `/24` per node, `/8` or `/12` total
- **Service Network**: 
  - Small cluster: `/16`
  - Medium/Large cluster: `/12`

### Checking Your Network Configuration

```bash
# View Pod network CIDR
kubectl cluster-info dump | grep -m 1 cluster-cidr
kubectl describe node <node-name> | grep PodCIDR

# View Service network CIDR
kubectl cluster-info dump | grep -m 1 service-cluster-ip-range

# View Node IPs
kubectl get nodes -o wide

# View Pod IPs
kubectl get pods -o wide --all-namespaces

# View Service IPs
kubectl get services --all-namespaces
```

### Real-World Configuration Example

```yaml
# Cluster Configuration
Node Network:    10.10.20.0/22
  - Control Plane: 10.10.20.3
  - Worker 1:      10.10.20.4
  - Worker 2:      10.10.20.5

Pod Network:     10.8.0.0/16
  - Worker 1 CIDR: 10.8.0.0/24
  - Worker 2 CIDR: 10.8.1.0/24
  - Worker 3 CIDR: 10.8.2.0/24

Service Network: 10.96.0.0/12
  - kubernetes service:    10.96.0.1
  - kube-dns service:      10.96.0.10
  - Your app services:     10.96.x.x
```

---

## 🔗 Container-to-Container Communication

### Within the Same Pod

Containers in the same Pod share a network namespace, enabling localhost communication.

```
┌─────────────────────────────────────────────────┐
│                    Pod: web-app                 │
│               IP: 10.8.0.5                      │
│                                                 │
│  ┌──────────────────┐      ┌─────────────────┐ │
│  │  Container 1     │      │  Container 2    │ │
│  │  (nginx)         │◄────►│  (redis)        │ │
│  │                  │      │                 │ │
│  │  Port: 8080      │      │  Port: 6379     │ │
│  └──────────────────┘      └─────────────────┘ │
│           │                         │          │
│           └─────────┬───────────────┘          │
│                     │                          │
│          ┌──────────▼──────────┐               │
│          │   localhost (lo)    │               │
│          │   127.0.0.1         │               │
│          └─────────────────────┘               │
└─────────────────────────────────────────────────┘
```

### Characteristics

- **Shared Resources**: Network namespace, IP address, loopback interface
- **Communication Method**: via `localhost` or `127.0.0.1`
- **Port Conflicts**: Containers must use different ports (can't both use port 80)
- **Use Cases**: 
  - Sidecar containers (logging, monitoring)
  - Service mesh proxies (Envoy, Linkerd)
  - Init containers for setup tasks

### Example Communication

```bash
# NGINX container talks to Redis container in same pod
redis-cli -h localhost -p 6379

# Sidecar logging agent reads from main container
curl http://localhost:8080/metrics
```

---

## 📡 Pod-to-Pod Communication

### Same Node Communication

Pods on the same node communicate through a virtual bridge and veth pairs.

```
┌────────────────────────────────────────────────────────────┐
│                        Node 1                               │
│                     10.10.20.4                              │
│                                                             │
│  ┌─────────────┐              ┌─────────────┐              │
│  │   Pod A     │              │   Pod B     │              │
│  │  10.8.0.2   │              │  10.8.0.3   │              │
│  │             │              │             │              │
│  │  ┌───────┐  │              │  ┌───────┐  │              │
│  │  │ eth0  │  │              │  │ eth0  │  │              │
│  │  └───┬───┘  │              │  └───┬───┘  │              │
│  └──────┼──────┘              └──────┼──────┘              │
│         │                            │                     │
│      veth0                         veth1                   │
│         │                            │                     │
│         └────────────┬───────────────┘                     │
│                      │                                     │
│              ┌───────▼───────┐                             │
│              │  cni0 bridge  │                             │
│              │               │                             │
│              └───────┬───────┘                             │
│                      │                                     │
│              ┌───────▼───────┐                             │
│              │   eth0 (NIC)  │                             │
│              └───────────────┘                             │
└────────────────────────────────────────────────────────────┘
```

### How It Works

1. Pod A sends packet to Pod B (10.8.0.2 → 10.8.0.3)
2. Packet goes through Pod A's `eth0` (actually a veth pair)
3. Other end of veth pair connected to `cni0` bridge
4. Bridge forwards packet to Pod B's veth pair
5. Packet arrives at Pod B's `eth0`

**Key Points**:
- ✅ No NAT required
- ✅ Direct IP-to-IP communication
- ✅ Layer 2 switching within node

---

### Cross-Node Communication

Pods on different nodes communicate through the CNI network implementation.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                           │
│                                                                      │
│  ┌──────────────────────────┐      ┌──────────────────────────┐    │
│  │       Node 1             │      │       Node 2             │    │
│  │    10.10.20.4            │      │    10.10.20.5            │    │
│  │    Pod CIDR: 10.8.0.0/24 │      │    Pod CIDR: 10.8.1.0/24 │    │
│  │                          │      │                          │    │
│  │  ┌─────────────┐         │      │  ┌─────────────┐         │    │
│  │  │   Pod A     │         │      │  │   Pod B     │         │    │
│  │  │  10.8.0.5   │         │      │  │  10.8.1.8   │         │    │
│  │  └──────┬──────┘         │      │  └──────▲──────┘         │    │
│  │         │                │      │         │                │    │
│  │    ┌────▼─────┐          │      │    ┌────┴─────┐          │    │
│  │    │cni0      │          │      │    │cni0      │          │    │
│  │    └────┬─────┘          │      │    └────▲─────┘          │    │
│  │         │                │      │         │                │    │
│  │    ┌────▼─────┐          │      │    ┌────┴─────┐          │    │
│  │    │  CNI     │          │      │    │  CNI     │          │    │
│  │    │  Plugin  │          │      │    │  Plugin  │          │    │
│  │    └────┬─────┘          │      │    └────▲─────┘          │    │
│  │         │                │      │         │                │    │
│  │    ┌────▼─────┐          │      │    ┌────┴─────┐          │    │
│  │    │ eth0     │──────────┼──────┼───►│ eth0     │          │    │
│  │    └──────────┘          │      │    └──────────┘          │    │
│  │                          │      │                          │    │
│  └──────────────────────────┘      └──────────────────────────┘    │
│                                                                     │
│  Packet Flow:                                                       │
│  1. Pod A (10.8.0.5) → Pod B (10.8.1.8)                            │
│  2. cni0 bridge on Node 1 → CNI plugin routes                      │
│  3. Encapsulated (VXLAN/IP-in-IP) or routed (BGP)                 │
│  4. Physical network → Node 2 eth0                                 │
│  5. CNI plugin decapsulates → cni0 → Pod B                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### CNI Implementation Methods

| Method | Example CNI | How It Works | Use Case |
|--------|-------------|--------------|----------|
| **Overlay Network** | Flannel (VXLAN), Weave | Encapsulates packets in UDP/VXLAN tunnel | Simple setup, works across any network |
| **IP-in-IP** | Calico | Encapsulates IP packet in another IP packet | Better performance than VXLAN |
| **BGP Routing** | Calico (BGP mode) | Uses BGP to advertise Pod routes | Best performance, requires BGP support |
| **eBPF** | Cilium | Uses eBPF for kernel-level packet processing | Modern, high-performance, observability |

### Example: Cross-Node Pod Communication

```bash
# From Pod A on Node 1, ping Pod B on Node 2
ping 10.8.1.8

# Trace the route
traceroute 10.8.1.8

# Check routing table on node
ip route show
# Output might show:
# 10.8.1.0/24 via 10.10.20.5 dev eth0
```

---

## 🎯 Service Discovery and Load Balancing

### The Service Abstraction

Services provide stable endpoints for accessing a group of Pods, even as Pods are created/destroyed.

```
┌──────────────────────────────────────────────────────────────┐
│                    Kubernetes Service                         │
│                                                               │
│                  ┌─────────────────────┐                      │
│                  │   Service: web      │                      │
│                  │   Type: ClusterIP   │                      │
│                  │   IP: 10.96.0.100   │                      │
│                  │   Port: 80          │                      │
│                  └──────────┬──────────┘                      │
│                             │                                 │
│                    (kube-proxy manages)                       │
│                             │                                 │
│       ┌─────────────────────┼─────────────────────┐           │
│       │                     │                     │           │
│       │                     │                     │           │
│  ┌────▼────┐          ┌────▼────┐          ┌────▼────┐       │
│  │  Pod 1  │          │  Pod 2  │          │  Pod 3  │       │
│  │ 10.8.0. │          │ 10.8.0. │          │ 10.8.1. │       │
│  │   10    │          │   11    │          │    5    │       │
│  │         │          │         │          │         │       │
│  │label:   │          │label:   │          │label:   │       │
│  │app=web  │          │app=web  │          │app=web  │       │
│  └─────────┘          └─────────┘          └─────────┘       │
│                                                               │
│  EndpointSlice tracks healthy Pod IPs                        │
└──────────────────────────────────────────────────────────────┘
```

### Service Types

#### 1. ClusterIP (Default)

Internal-only service with a stable cluster IP.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80        # Service port
      targetPort: 8080 # Pod port
```

**Characteristics**:
- ✅ Only accessible within the cluster
- ✅ Stable virtual IP (ClusterIP)
- ✅ Load balances to backend Pods
- ✅ Default service type

#### 2. NodePort

Exposes service on each node's IP at a static port.

```
┌────────────────────────────────────────────────────────────┐
│                   Kubernetes Cluster                        │
│                                                             │
│  External Client                                            │
│       │                                                     │
│       │  http://10.10.20.3:30080                            │
│       │  http://10.10.20.4:30080                            │
│       │  http://10.10.20.5:30080                            │
│       │                                                     │
│  ┌────▼──────┐     ┌───────────┐     ┌───────────┐         │
│  │  Node 1   │     │  Node 2   │     │  Node 3   │         │
│  │ :30080    │     │ :30080    │     │ :30080    │         │
│  └────┬──────┘     └─────┬─────┘     └─────┬─────┘         │
│       │                  │                  │               │
│       └──────────────────┼──────────────────┘               │
│                          │                                  │
│                   ┌──────▼──────┐                           │
│                   │   Service   │                           │
│                   │ ClusterIP   │                           │
│                   └──────┬──────┘                           │
│                          │                                  │
│                ┌─────────┼─────────┐                        │
│                │         │         │                        │
│           ┌────▼───┐ ┌──▼────┐ ┌──▼────┐                   │
│           │ Pod 1  │ │ Pod 2 │ │ Pod 3 │                   │
│           └────────┘ └───────┘ └───────┘                   │
└────────────────────────────────────────────────────────────┘
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-nodeport-service
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
      nodePort: 30080  # Port range: 30000-32767
```

**Characteristics**:
- ✅ Accessible from outside cluster
- ⚠️ Exposes port on all nodes
- ⚠️ Limited port range (30000-32767)
- ⚠️ Need to manage node IPs

#### 3. LoadBalancer

Provisions an external load balancer (cloud provider).

```
┌─────────────────────────────────────────────────────────────┐
│                      Cloud Environment                       │
│                                                              │
│                   External Clients                           │
│                          │                                   │
│                          │  http://lb-ip:80                  │
│                          │                                   │
│                  ┌───────▼────────┐                          │
│                  │  Cloud Load    │                          │
│                  │  Balancer      │                          │
│                  │  (AWS ELB/     │                          │
│                  │   GCP LB/      │                          │
│                  │   Azure LB)    │                          │
│                  └───────┬────────┘                          │
│                          │                                   │
│  ┌───────────────────────┼───────────────────────┐           │
│  │        Kubernetes Cluster                     │           │
│  │                       │                       │           │
│  │  ┌────────┐      ┌───▼────┐      ┌────────┐  │           │
│  │  │ Node 1 │      │ Node 2 │      │ Node 3 │  │           │
│  │  │:30080  │      │:30080  │      │:30080  │  │           │
│  │  └───┬────┘      └────┬───┘      └────┬───┘  │           │
│  │      │                │                │      │           │
│  │      └────────────────┼────────────────┘      │           │
│  │                       │                       │           │
│  │                ┌──────▼──────┐                │           │
│  │                │   Service   │                │           │
│  │                │ ClusterIP   │                │           │
│  │                └──────┬──────┘                │           │
│  │                       │                       │           │
│  │             ┌─────────┼─────────┐             │           │
│  │             │         │         │             │           │
│  │        ┌────▼───┐ ┌──▼────┐ ┌──▼────┐        │           │
│  │        │ Pod 1  │ │ Pod 2 │ │ Pod 3 │        │           │
│  │        └────────┘ └───────┘ └───────┘        │           │
│  └───────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-loadbalancer-service
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
```

**Characteristics**:
- ✅ Automatic external IP provisioning
- ✅ Managed by cloud provider
- ✅ High availability
- ⚠️ Requires cloud environment or MetalLB (bare metal)
- ⚠️ Cost per LoadBalancer

### kube-proxy Modes

| Mode | How It Works | Performance | Use Case |
|------|--------------|-------------|----------|
| **iptables** | Creates iptables rules for each service | Good | Default, most compatible |
| **IPVS** | Uses Linux IPVS for load balancing | Better | Large clusters (>1000 services) |
| **eBPF** | Uses eBPF programs in kernel | Best | Modern, requires newer kernels |

### EndpointSlices

Kubernetes uses EndpointSlices to track which Pods are backing a Service:

```yaml
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: my-service-abc123
  labels:
    kubernetes.io/service-name: my-service
addressType: IPv4
ports:
  - name: http
    protocol: TCP
    port: 8080
endpoints:
  - addresses:
      - "10.8.0.10"
    conditions:
      ready: true
  - addresses:
      - "10.8.0.11"
    conditions:
      ready: true
```

---

## 🌍 External Access Patterns

### Ingress Architecture

Ingress provides HTTP/HTTPS routing to services based on rules.

```
┌────────────────────────────────────────────────────────────────┐
│                        Internet                                 │
│                            │                                    │
│                  ┌─────────▼─────────┐                          │
│                  │   DNS Resolution  │                          │
│                  │  app.example.com  │                          │
│                  └─────────┬─────────┘                          │
│                            │                                    │
│  ┌─────────────────────────┼─────────────────────────┐          │
│  │         Kubernetes Cluster                        │          │
│  │                         │                         │          │
│  │             ┌───────────▼───────────┐             │          │
│  │             │  Ingress Controller   │             │          │
│  │             │  (NGINX/Traefik/      │             │          │
│  │             │   HAProxy)            │             │          │
│  │             │  LoadBalancer:80,443  │             │          │
│  │             └───────────┬───────────┘             │          │
│  │                         │                         │          │
│  │            Ingress Rules│(routes)                 │          │
│  │                         │                         │          │
│  │       ┌─────────────────┼─────────────────┐       │          │
│  │       │                 │                 │       │          │
│  │  ┌────▼─────┐    ┌─────▼──────┐   ┌─────▼─────┐ │          │
│  │  │ Service  │    │  Service   │   │  Service  │ │          │
│  │  │   web    │    │    api     │   │   admin   │ │          │
│  │  │ :80      │    │   :80      │   │   :80     │ │          │
│  │  └────┬─────┘    └─────┬──────┘   └─────┬─────┘ │          │
│  │       │                │                │       │          │
│  │  ┌────▼────┐     ┌────▼────┐     ┌────▼────┐   │          │
│  │  │  Pods   │     │  Pods   │     │  Pods   │   │          │
│  │  │  (web)  │     │  (api)  │     │ (admin) │   │          │
│  │  └─────────┘     └─────────┘     └─────────┘   │          │
│  └──────────────────────────────────────────────────┘          │
└────────────────────────────────────────────────────────────────┘

Routing Rules:
  app.example.com/        → web service
  app.example.com/api     → api service
  admin.example.com/      → admin service
```

### Ingress Resource Example

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-service
            port:
              number: 80
  - host: admin.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: admin-service
            port:
              number: 80
  tls:
  - hosts:
    - app.example.com
    - admin.example.com
    secretName: tls-secret
```

### Gateway API (Next Generation)

The Gateway API is the evolution of Ingress, providing more expressive and extensible routing.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: example-gateway
spec:
  gatewayClassName: example-gateway-class
  listeners:
  - name: http
    protocol: HTTP
    port: 80
```

---

## 🔒 Network Policies

Network Policies control traffic flow between Pods (Layer 3/4 firewall rules).

### Default Behavior (No Network Policy)

```
┌──────────────────────────────────────────┐
│         All Pods Can Talk to All         │
│                                          │
│  ┌────────┐    ┌────────┐    ┌────────┐ │
│  │Frontend│◄──►│Backend │◄──►│  DB    │ │
│  │  Pod   │    │  Pod   │    │  Pod   │ │
│  └────────┘    └────────┘    └────────┘ │
│      ▲             ▲             ▲       │
│      └─────────────┴─────────────┘       │
│           All traffic allowed            │
└──────────────────────────────────────────┘
```

### With Network Policy (Restricted)

```
┌──────────────────────────────────────────┐
│       Network Policy Applied             │
│                                          │
│  ┌────────┐    ┌────────┐    ┌────────┐ │
│  │Frontend│───►│Backend │───►│  DB    │ │
│  │  Pod   │    │  Pod   │    │  Pod   │ │
│  └────────┘    └────────┘    └────────┘ │
│                                          │
│  ✓ Frontend → Backend allowed           │
│  ✓ Backend → DB allowed                 │
│  ✗ Frontend → DB blocked                │
│  ✗ External → DB blocked                │
└──────────────────────────────────────────┘
```

### Network Policy Example

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-network-policy
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 5432
```

**This policy**:
- Applies to Pods with label `app=backend`
- **Ingress**: Only allows traffic from Pods with `app=frontend` on port 8080
- **Egress**: Only allows traffic to Pods with `app=database` on port 5432

### Important Notes

⚠️ **Network Policies require CNI support**: Not all CNI plugins implement NetworkPolicy
- ✅ Supports: Calico, Cilium, Weave
- ❌ Doesn't support: Flannel (basic mode)

---

## 🔍 DNS Resolution

### CoreDNS Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Kubernetes Cluster                         │
│                                                              │
│  ┌──────────┐                                                │
│  │   Pod    │                                                │
│  │          │   1. DNS Query: my-service.default.svc        │
│  │          │   ────────────────────┐                       │
│  └──────────┘                       │                       │
│                                     ▼                        │
│                          ┌──────────────────┐                │
│                          │    CoreDNS       │                │
│                          │   (kube-system)  │                │
│                          │   ClusterIP:     │                │
│                          │   10.96.0.10     │                │
│                          └────────┬─────────┘                │
│                                   │                          │
│                    2. Resolves to ClusterIP                  │
│                                   │                          │
│                          ┌────────▼─────────┐                │
│                          │   Service        │                │
│                          │   my-service     │                │
│                          │   10.96.0.100    │                │
│                          └──────────────────┘                │
└─────────────────────────────────────────────────────────────┘
```

### DNS Naming Convention

Kubernetes DNS follows this format:

```
<service-name>.<namespace>.svc.<cluster-domain>
```

**Examples**:
- `my-service` - Same namespace (short form)
- `my-service.default` - Specific namespace
- `my-service.default.svc.cluster.local` - Fully qualified (FQDN)

### Service DNS Records

```bash
# From a pod, resolve a service
nslookup my-service.default.svc.cluster.local

# Output:
# Name: my-service.default.svc.cluster.local
# Address: 10.96.0.100
```

### Pod DNS Records

Pods get DNS records in this format:

```
<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain>
```

Example: Pod with IP `10.8.0.5` in `default` namespace:

```
10-8-0-5.default.pod.cluster.local
```

### Headless Services

For direct Pod-to-Pod discovery without load balancing:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-headless-service
spec:
  clusterIP: None  # Headless
  selector:
    app: database
  ports:
  - port: 5432
```

DNS returns all Pod IPs directly:
```bash
nslookup my-headless-service.default.svc.cluster.local

# Returns:
# Name: my-headless-service.default.svc.cluster.local
# Address: 10.8.0.10
# Address: 10.8.0.11
# Address: 10.8.1.5
```

### Pod DNS Configuration

Pods can customize DNS settings:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-dns-pod
spec:
  containers:
  - name: app
    image: nginx
  dnsPolicy: "None"
  dnsConfig:
    nameservers:
      - 1.1.1.1
    searches:
      - default.svc.cluster.local
      - svc.cluster.local
      - cluster.local
    options:
      - name: ndots
        value: "5"
```

---

## 📊 Summary Reference

### Communication Matrix

| Source | Destination | Method | NAT Required | Component |
|--------|-------------|--------|--------------|-----------|
| Container | Container (same Pod) | `localhost` | ❌ No | Shared namespace |
| Pod | Pod (same node) | Virtual bridge/veth | ❌ No | CNI plugin |
| Pod | Pod (different node) | Overlay/BGP routing | ❌ No | CNI plugin |
| Pod | Service | ClusterIP | ❌ No | kube-proxy |
| External | Service (NodePort) | NodeIP:NodePort | ✅ Yes | kube-proxy |
| External | Service (LoadBalancer) | External LB IP | ✅ Yes | Cloud LB + kube-proxy |
| External | Service (Ingress) | Ingress rules (L7) | ✅ Yes | Ingress Controller |
| Pod | Internet | Default gateway | ✅ Yes (SNAT) | Node iptables |

### Port Ranges

| Type | Port Range | Usage |
|------|-----------|--------|
| Container Ports | 1-65535 | Application listens |
| Service Ports | 1-65535 | Service exposes |
| NodePort | 30000-32767 | External access via node |

### Key Concepts Summary

```
┌────────────────────────────────────────────────────────────┐
│ Networking Layer Stack                                     │
├────────────────────────────────────────────────────────────┤
│ Layer 7 (Application)                                      │
│   └─► Ingress / Gateway API (HTTP/HTTPS routing)          │
│                                                            │
│ Layer 4 (Transport)                                        │
│   └─► Service (TCP/UDP load balancing)                    │
│                                                            │
│ Layer 3 (Network)                                          │
│   └─► Pod IPs, CNI routing, NetworkPolicy                 │
│                                                            │
│ Layer 2 (Data Link)                                        │
│   └─► Virtual bridges, veth pairs                         │
└────────────────────────────────────────────────────────────┘
```

### Quick Command Reference

```bash
# Check pod IP and network namespace
kubectl get pod <pod-name> -o wide

# Get service endpoints
kubectl get endpoints <service-name>
kubectl get endpointslices

# Test service connectivity from a pod
kubectl exec -it <pod-name> -- curl <service-name>

# Check DNS resolution
kubectl exec -it <pod-name> -- nslookup <service-name>

# View kube-proxy mode
kubectl logs -n kube-system <kube-proxy-pod>

# Check network policies
kubectl get networkpolicies

# Describe service for details
kubectl describe service <service-name>

# Test external access (NodePort)
curl http://<node-ip>:<node-port>
```

### Best Practices

✅ **DO**:
- Use Services for stable endpoints
- Implement NetworkPolicies for security
- Use Ingress for HTTP/HTTPS routing
- Choose appropriate Service type for your use case
- Use DNS names instead of hardcoded IPs
- Monitor CNI plugin health
- Use headless services for StatefulSets

❌ **DON'T**:
- Hardcode Pod IPs (they change)
- Expose NodePort in production (use LoadBalancer/Ingress)
- Forget to implement NetworkPolicies
- Use host network mode unless necessary
- Bypass Services for Pod-to-Pod communication

---

## 📚 Additional Resources

- [Kubernetes Networking Documentation](https://kubernetes.io/docs/concepts/cluster-administration/networking/)
- [Services Documentation](https://kubernetes.io/docs/concepts/services-networking/service/)
- [Ingress Documentation](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Network Policies Documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/)

---

**Last Updated**: December 2025
**Kubernetes Version**: v1.28+
