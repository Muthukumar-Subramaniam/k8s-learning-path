# Container Network Interface (CNI)

## Overview

**CNI (Container Network Interface)** is a specification and set of libraries for configuring network interfaces in Linux containers. In Kubernetes, CNI plugins are responsible for:

- Setting up Pod network interfaces
- Assigning IP addresses to Pods
- Enabling Pod-to-Pod communication
- Implementing network policies
- Managing routing and connectivity

---

## What is CNI?

CNI is a **vendor-neutral standard** developed by the Cloud Native Computing Foundation (CNCF) that defines:

1. **Network Plugin Interface**: How container runtimes interact with network plugins
2. **Configuration Format**: JSON-based configuration for network setup
3. **Plugin Execution**: Binary plugins that configure networking when containers start/stop

### Key Responsibilities

```
┌─────────────────────────────────────────────────────────────┐
│                      CNI Plugin                              │
├─────────────────────────────────────────────────────────────┤
│  1. Create network namespace for Pod                        │
│  2. Create virtual ethernet (veth) pair                     │
│  3. Attach one end to Pod, other to host/bridge            │
│  4. Assign IP address to Pod (via IPAM)                    │
│  5. Set up routes for Pod network                          │
│  6. Configure DNS                                            │
│  7. Apply network policies (if supported)                   │
└─────────────────────────────────────────────────────────────┘
```

---

## How CNI Works in Kubernetes

### Integration Flow

```
┌──────────────┐     ┌─────────────┐     ┌────────────────┐
│   kubelet    │────▶│ CNI Plugin  │────▶│ Pod Network    │
└──────────────┘     └─────────────┘     │   Namespace    │
       │                    │              └────────────────┘
       │                    │
       │                    ▼
       │             ┌─────────────┐
       │             │    IPAM     │
       │             │ (IP Assign) │
       │             └─────────────┘
       │                    │
       ▼                    ▼
┌──────────────┐     ┌─────────────┐
│   Container  │     │  IP Address │
│   Runtime    │     │   10.8.x.x  │
└──────────────┘     └─────────────┘
```

### Execution Lifecycle

1. **Pod Creation**:
   - kubelet receives Pod creation request
   - Calls container runtime to create Pod sandbox
   - Runtime creates network namespace
   - kubelet invokes CNI plugin with `ADD` command
   - CNI plugin configures networking and returns IP

2. **Pod Deletion**:
   - kubelet calls CNI plugin with `DEL` command
   - CNI plugin cleans up network interfaces and IP allocation
   - Network namespace is deleted

### CNI Configuration Location

CNI plugins are configured through files in `/etc/cni/net.d/`:

```bash
# Example: /etc/cni/net.d/10-calico.conflist
{
  "name": "k8s-pod-network",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "calico",
      "datastore_type": "kubernetes",
      "ipam": {
        "type": "calico-ipam"
      },
      "policy": {
        "type": "k8s"
      }
    }
  ]
}
```

---

## Popular CNI Plugins

### Comparison Table

| Plugin | Networking Model | Network Policies | Performance | Complexity | Use Case |
|--------|------------------|------------------|-------------|------------|----------|
| **Calico** | L3 BGP routing | ✅ Advanced | High | Medium | Production, security-focused |
| **Flannel** | VXLAN overlay | ❌ None | Medium | Low | Simple clusters, learning |
| **Cilium** | eBPF | ✅ L7 aware | Very High | High | Modern, observability |
| **Weave** | Mesh overlay | ✅ Basic | Medium | Low | Simple setup |
| **Canal** | Flannel + Calico | ✅ Calico policies | Medium | Medium | Flannel simplicity + policies |
| **Antrea** | OVS-based | ✅ Advanced | High | Medium | VMware environments |

---

## CNI Plugin Details

### 1. Calico

**Architecture**: Layer 3 BGP-based routing

```
┌──────────────────────────────────────────────────────┐
│                    Calico Network                     │
├──────────────────────────────────────────────────────┤
│                                                       │
│  Node 1                          Node 2              │
│  ┌────────────┐                  ┌────────────┐     │
│  │   Pod A    │                  │   Pod B    │     │
│  │ 10.8.0.5   │                  │ 10.8.1.5   │     │
│  └─────┬──────┘                  └─────┬──────┘     │
│        │                                │            │
│        │ cali123abc                     │ cali456def │
│        │                                │            │
│  ┌─────┴──────────┐            ┌───────┴────────┐   │
│  │  Linux Kernel  │───BGP────▶│ Linux Kernel   │   │
│  │  (routing)     │◀──BGP──────│ (routing)      │   │
│  └────────────────┘            └────────────────┘   │
│                                                       │
└──────────────────────────────────────────────────────┘
```

**Features**:
- Native L3 routing (no overlay encapsulation)
- Advanced network policies (L3/L4 and L7)
- BGP peering for routing
- Flexible IPAM with IP pools
- eBPF dataplane option
- Encryption with WireGuard

**IPAM**: 
- Custom IPAM system (ignores `node.spec.podCIDR`)
- Uses IPPool resources
- Default `/26` blocks (62 IPs per block)
- Dynamic allocation on-demand

**When to Use**:
- Production environments requiring network policies
- Security-focused deployments
- Large-scale clusters
- Need for BGP integration

---

### 2. Flannel

**Architecture**: VXLAN overlay network

```
┌──────────────────────────────────────────────────────┐
│                   Flannel Network                     │
├──────────────────────────────────────────────────────┤
│                                                       │
│  Node 1 (10.8.0.0/24)            Node 2 (10.8.1.0/24)│
│  ┌────────────┐                  ┌────────────┐     │
│  │   Pod A    │                  │   Pod B    │     │
│  │ 10.8.0.5   │                  │ 10.8.1.5   │     │
│  └─────┬──────┘                  └─────┬──────┘     │
│        │ veth                           │ veth       │
│        │                                │            │
│  ┌─────┴──────────┐            ┌───────┴────────┐   │
│  │  cni0 bridge   │            │  cni0 bridge   │   │
│  └────────┬───────┘            └───────┬────────┘   │
│           │                            │            │
│     ┌─────┴─────┐                ┌────┴──────┐     │
│     │  flannel  │───VXLAN────────│  flannel  │     │
│     │  (flanneld)│   tunnel       │ (flanneld)│     │
│     └───────────┘                └───────────┘     │
│                                                       │
└──────────────────────────────────────────────────────┘
```

**Features**:
- Simple VXLAN overlay by default
- Uses Kubernetes-managed IPAM
- Sequential IP allocation per node
- Easy to deploy
- No network policy support (use with Calico for policies)

**IPAM**:
- Uses `node.spec.podCIDR` from Kubernetes
- Controller-manager assigns `/24` subnets per node
- Predictable, sequential allocation

**When to Use**:
- Simple clusters
- Learning/development environments
- When network policies aren't required
- Quick setup needed

---

### 3. Cilium

**Architecture**: eBPF-based networking

```
┌──────────────────────────────────────────────────────┐
│                    Cilium Network                     │
├──────────────────────────────────────────────────────┤
│                                                       │
│  Node 1                          Node 2              │
│  ┌────────────┐                  ┌────────────┐     │
│  │   Pod A    │                  │   Pod B    │     │
│  │ 10.8.0.5   │                  │ 10.8.1.5   │     │
│  └─────┬──────┘                  └─────┬──────┘     │
│        │                                │            │
│        │ lxc123                         │ lxc456     │
│        │                                │            │
│  ┌─────┴──────────────┐       ┌────────┴───────────┐│
│  │   eBPF Programs    │       │   eBPF Programs    ││
│  │  - Policy enforce  │       │  - Policy enforce  ││
│  │  - Load balancing  │       │  - Load balancing  ││
│  │  - Observability   │       │  - Observability   ││
│  └────────────────────┘       └────────────────────┘│
│           │                            │            │
│     ┌─────┴─────┐                ┌────┴──────┐     │
│     │  Cilium   │───Tunneling────│  Cilium   │     │
│     │   Agent   │    or Routing  │   Agent   │     │
│     └───────────┘                └───────────┘     │
│                                                       │
└──────────────────────────────────────────────────────┘
```

**Features**:
- eBPF-based dataplane (kernel-level packet processing)
- L3/L4 and L7 network policies
- Service mesh capabilities
- Advanced observability with Hubble
- API-aware network security
- High performance

**IPAM**:
- Custom IPAM via CiliumNode resources
- Dynamic allocation
- Supports various modes (cluster-pool, Kubernetes, etc.)

**When to Use**:
- Modern cloud-native applications
- Need for L7 policies and observability
- High-performance requirements
- Service mesh features

---

### 4. Weave Net

**Architecture**: Mesh overlay network

**Features**:
- Automatic mesh network formation
- Encryption support
- Simple setup
- Basic network policies
- Multicast support

**When to Use**:
- Quick cluster setup
- Need for encryption
- Simple network topology

---

### 5. Canal

**Architecture**: Combination of Flannel (networking) + Calico (policies)

**Features**:
- Flannel's VXLAN for networking
- Calico's network policy enforcement
- Best of both worlds

**When to Use**:
- Want Flannel's simplicity with network policies
- Hybrid approach

---

## CNI and IPAM

CNI plugins handle IP Address Management differently:

### Kubernetes-Managed IPAM

**Used by**: Flannel, kube-router

```yaml
# Controller-manager assigns podCIDR to each node
apiVersion: v1
kind: Node
metadata:
  name: k8s-w1
spec:
  podCIDR: 10.8.0.0/24      # Assigned by K8s
  podCIDRs:
  - 10.8.0.0/24
```

**Characteristics**:
- ✅ Predictable IP allocation
- ✅ Simple to understand
- ❌ Fixed block size per node
- ❌ Less flexible

### CNI-Managed IPAM

**Used by**: Calico, Cilium, Weave

```yaml
# Calico manages its own IP pools
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: 10.8.0.0/16
  blockSize: 26              # Dynamic /26 blocks
  ipipMode: Always
  natOutgoing: true
```

**Characteristics**:
- ✅ Dynamic allocation
- ✅ Flexible block sizing
- ✅ Multiple blocks per node
- ❌ More complex to troubleshoot

> 📖 **See Also**: [ipam.md](ipam.md) for comprehensive IPAM details

---

## Network Policies

Network policies are Kubernetes resources that control traffic between Pods. **Not all CNI plugins support network policies**.

### Support Matrix

| CNI Plugin | Network Policy Support |
|------------|------------------------|
| Calico | ✅ Full support (L3/L4 + L7) |
| Cilium | ✅ Full support (L3/L4 + L7) |
| Weave | ✅ Basic support |
| Antrea | ✅ Full support |
| Flannel | ❌ No support |
| kube-router | ✅ Basic support |

### Example Network Policy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
```

---

## CNI Installation

### Calico Installation

```bash
# Install Tigera Calico operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml

# Install Calico custom resources
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/custom-resources.yaml

# Verify
kubectl get pods -n calico-system
kubectl get ippool -o yaml
```

### Flannel Installation

```bash
# Install Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Verify
kubectl get pods -n kube-flannel
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'
```

### Cilium Installation

```bash
# Using Cilium CLI
curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin

cilium install

# Verify
cilium status
kubectl get pods -n kube-system -l k8s-app=cilium
```

---

## Troubleshooting CNI Issues

### Common Commands

```bash
# Check CNI configuration
ls -la /etc/cni/net.d/
cat /etc/cni/net.d/*.conf*

# Check CNI binaries
ls -la /opt/cni/bin/

# View CNI plugin pods
kubectl get pods -A | grep -E 'calico|flannel|cilium|weave'

# Check CNI logs (Calico example)
kubectl logs -n calico-system -l k8s-app=calico-node

# Check pod network interfaces
kubectl exec -it <pod-name> -- ip addr

# Check routes
kubectl exec -it <pod-name> -- ip route
```

### Common Issues

1. **Pods stuck in ContainerCreating**:
   - CNI plugin not installed or not running
   - CNI configuration missing
   - Check kubelet logs: `journalctl -u kubelet | grep cni`

2. **Pods can't communicate**:
   - Network policy blocking traffic
   - Overlay network issues
   - Check CNI plugin logs

3. **IP address conflicts**:
   - IPAM misconfiguration
   - Pod CIDR overlap with node network
   - Check IP pool configuration

---

## CNI Selection Guide

### Decision Matrix

**Choose Calico if you need**:
- ✅ Network policies
- ✅ Production-grade security
- ✅ Scalability
- ✅ BGP integration

**Choose Flannel if you need**:
- ✅ Simple setup
- ✅ Learning/development
- ✅ Minimal overhead
- ❌ Don't need network policies

**Choose Cilium if you need**:
- ✅ Modern eBPF technology
- ✅ L7 network policies
- ✅ Service mesh features
- ✅ Advanced observability
- ✅ Best performance

**Choose Weave if you need**:
- ✅ Quick deployment
- ✅ Built-in encryption
- ✅ Simple mesh networking

---

## Performance Considerations

### Dataplane Comparison

```
Performance (higher is better)
    ▲
    │
    │                                    ╔════════╗
    │                                    ║ Cilium ║ (eBPF)
    │                          ╔═══════╗ ║  eBPF  ║
    │                          ║Calico ║ ╚════════╝
    │                          ║ eBPF  ║
    │                ╔═══════╗ ╚═══════╝
    │                ║Calico ║
    │      ╔═══════╗ ║  BGP  ║
    │      ║Weave  ║ ╚═══════╝
    │      ╚═══════╝
    │    ╔═══════╗
    │    ║Flannel║
    │    ║ VXLAN ║
    │    ╚═══════╝
    └────────────────────────────────────────────▶
                Network Complexity
```

---

## Related Components

- **[IPAM](ipam.md)**: IP Address Management details
- **[kube-proxy](kube-proxy.md)**: Service networking and load balancing
- **[Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)**: Overall networking architecture

---

## Key Takeaways

1. **CNI is a specification** that defines how container networking works in Kubernetes
2. **Different CNI plugins** have different features, performance, and complexity
3. **Network policies require CNI support** - not all plugins support them
4. **IPAM varies by plugin** - some use Kubernetes IPAM, others manage their own
5. **Choose based on requirements**: Calico for production/security, Flannel for simplicity, Cilium for modern features
6. **CNI plugins are critical** - without one, Pods cannot communicate

---

## References

- [CNI Specification](https://github.com/containernetworking/cni)
- [Calico Documentation](https://docs.tigera.io/calico/latest/about/)
- [Flannel Documentation](https://github.com/flannel-io/flannel)
- [Cilium Documentation](https://docs.cilium.io/)
- [Kubernetes Network Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)
