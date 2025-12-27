# 🔧 MetalLB - Load Balancer for Bare Metal Kubernetes

> **Reference**: [MetalLB Official Documentation](https://metallb.universe.tf/)

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Layer 2 Mode](#layer-2-mode)
4. [Layer 3 (BGP) Mode](#layer-3-bgp-mode)
5. [Comparison: Layer 2 vs Layer 3](#comparison-layer-2-vs-layer-3)
6. [Configuration Examples](#configuration-examples)
7. [Troubleshooting](#troubleshooting)

---

## 🎯 Overview

### What is MetalLB?

MetalLB is a **load balancer implementation for bare metal Kubernetes clusters** using standard routing protocols. It solves the problem that Kubernetes doesn't provide a LoadBalancer implementation for clusters that aren't running on cloud providers.

### Why MetalLB?

In cloud environments (AWS, GCP, Azure), LoadBalancer services automatically provision cloud load balancers. On bare metal or on-premises clusters, LoadBalancer services remain in a "pending" state because there's no controller to provide the external IP.

**MetalLB provides**:
- External IP address assignment to LoadBalancer services
- Network announcements using Layer 2 (ARP/NDP) or Layer 3 (BGP)
- True bare metal load balancing without external hardware

### Key Components

```
┌────────────────────────────────────────────────────────────────┐
│                     MetalLB Architecture                        │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              metallb-controller                           │  │
│  │  - Watches for LoadBalancer services                     │  │
│  │  - Assigns IP addresses from configured pools            │  │
│  │  - Single replica (leader election)                      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                  │
│                              ├───────────────────────┐          │
│                              │                       │          │
│  ┌───────────────────────────▼──┐   ┌───────────────▼────────┐ │
│  │    metallb-speaker (Node 1)  │   │  metallb-speaker (N...) │ │
│  │  - DaemonSet (runs on all)  │   │  - Announces IPs        │ │
│  │  - Layer 2: ARP responses    │   │  - Layer 3: BGP peering │ │
│  │  - Layer 3: BGP peering      │   │                         │ │
│  └──────────────────────────────┘   └─────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

| Component | Role | Replicas |
|-----------|------|----------|
| **metallb-controller** | IP address assignment | 1 (leader-elected) |
| **metallb-speaker** | Network announcement | DaemonSet (all nodes) |

---

## 🏗️ Architecture

### How MetalLB Works

1. **Service Creation**: User creates a LoadBalancer service
2. **IP Assignment**: Controller assigns an external IP from the configured pool
3. **Announcement**: Speaker pods announce the IP to the network
4. **Traffic Routing**: Network routes traffic to the announcing node(s)
5. **kube-proxy**: Routes traffic from node to appropriate Pod

### Network Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                       External Client                             │
│                            │                                      │
│                  ┌─────────▼─────────┐                            │
│                  │  External IP      │                            │
│                  │  (e.g., 10.10.20.201)                          │
│                  └─────────┬─────────┘                            │
│                            │                                      │
│          ┌─────────────────┴─────────────────┐                   │
│          │                                   │                   │
│   ┌──────▼──────┐                    ┌──────▼──────┐            │
│   │  Worker-1   │                    │  Worker-2   │            │
│   │  (Speaker)  │                    │  (Speaker)  │            │
│   └──────┬──────┘                    └──────┬──────┘            │
│          │                                   │                   │
│          │         kube-proxy routing        │                   │
│          │                                   │                   │
│   ┌──────▼──────┐                    ┌──────▼──────┐            │
│   │   Pod A     │                    │   Pod B     │            │
│   │ 10.8.0.10   │                    │ 10.8.1.20   │            │
│   └─────────────┘                    └─────────────┘            │
└──────────────────────────────────────────────────────────────────┘
```

---

## 📡 Layer 2 Mode

### Overview

Layer 2 mode uses standard network protocols (ARP for IPv4, NDP for IPv6) to announce external IPs. One node becomes the "leader" for each service and responds to ARP requests.

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Layer 2 Mode Operation                    │
│                                                              │
│  Client: "Who has 10.10.20.201?"                            │
│            │                                                 │
│            │  ARP Request (broadcast)                       │
│            ▼                                                 │
│  ┌─────────────────────────────────────────┐                │
│  │         Local Network Switch             │                │
│  └─────────┬───────────────────┬───────────┘                │
│            │                   │                             │
│  ┌─────────▼─────────┐  ┌─────▼──────────┐                 │
│  │  k8s-w1           │  │  k8s-w2 (LEADER)│                 │
│  │  (speaker)        │  │  (speaker)      │                 │
│  │  - Silent         │  │  - Responds!    │                 │
│  └───────────────────┘  └─────┬───────────┘                 │
│                               │                              │
│                   ARP Reply: "I have it!"                    │
│                               │                              │
│                        ┌──────▼──────┐                       │
│                        │  All traffic │                       │
│                        │  goes here   │                       │
│                        └──────────────┘                       │
└─────────────────────────────────────────────────────────────┘
```

### Characteristics

**Pros:**
- ✅ **Simple setup** - No router configuration needed
- ✅ **Works anywhere** - Any Layer 2 network
- ✅ **No special hardware** - Standard switches work fine
- ✅ **Fast failover** - ~2 seconds on leader failure

**Cons:**
- ⚠️ **Single point of traffic** - All traffic goes through one node
- ⚠️ **No load balancing** - Only one node handles traffic per service
- ⚠️ **Local subnet only** - Can't route across subnets
- ⚠️ **Bandwidth bottleneck** - Limited by single node's network capacity

### Leader Election

MetalLB uses a simple algorithm:
1. All speaker pods coordinate via Kubernetes API
2. Lowest node name (alphabetically) becomes leader
3. Leader announces the IP and handles all traffic
4. On failure, next lowest node takes over

### Configuration Example

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.10.20.200-10.10.20.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - production-pool
```

---

## 🌐 Layer 3 (BGP) Mode

### Overview

Layer 3 mode uses BGP (Border Gateway Protocol) to announce external IPs. Each node peers with your network router(s) and advertises routes, enabling true load balancing across multiple nodes.

### How It Works

```
┌────────────────────────────────────────────────────────────────┐
│                    Layer 3 BGP Mode Operation                   │
│                                                                 │
│            ┌─────────────────────────────┐                      │
│            │    BGP Router (pfSense)     │                      │
│            │    AS: 64501                │                      │
│            │    - Receives routes        │                      │
│            │    - ECMP load balancing    │                      │
│            └──────┬────────────┬─────────┘                      │
│                   │            │                                │
│        BGP Peer   │            │   BGP Peer                     │
│                   │            │                                │
│         ┌─────────▼──────┐  ┌─▼────────────┐                   │
│         │  k8s-w1        │  │  k8s-w2      │                   │
│         │  AS: 64500     │  │  AS: 64500   │                   │
│         │  Advertises:   │  │  Advertises: │                   │
│         │  10.10.20.201  │  │  10.10.20.201│                   │
│         └────────────────┘  └──────────────┘                   │
│                                                                 │
│  Router sees BOTH paths → Distributes traffic via ECMP         │
│                                                                 │
│  Client Traffic:                                               │
│    - 50% → k8s-w1 → Pod A                                      │
│    - 50% → k8s-w2 → Pod B                                      │
└────────────────────────────────────────────────────────────────┘
```

### ECMP (Equal-Cost Multi-Path)

When multiple nodes advertise the same IP:
- Router sees multiple equal-cost paths
- Distributes traffic across all advertising nodes
- Usually hash-based (source/dest IP+port)
- True load balancing at L3

### Characteristics

**Pros:**
- ✅ **True load balancing** - Traffic distributed across nodes
- ✅ **High performance** - Multiple nodes share load
- ✅ **Scalability** - More nodes = more capacity
- ✅ **Cross-subnet** - Works across routed networks
- ✅ **Better failure handling** - BGP convergence is fast

**Cons:**
- ⚠️ **Complex setup** - Requires BGP router configuration
- ⚠️ **BGP knowledge needed** - Understanding AS numbers, peering
- ⚠️ **Router requirement** - Need BGP-capable router (pfSense/FRR, etc.)

### BGP Concepts

| Term | Description | Example |
|------|-------------|---------|
| **AS Number** | Autonomous System identifier | 64500 (private range: 64512-65534) |
| **BGP Peer** | Router relationship | MetalLB ↔ pfSense |
| **Route Advertisement** | Announcing IP prefixes | "I have 10.10.20.201/32" |
| **ECMP** | Load balancing mechanism | 3 paths → 33% each |

### Configuration Example

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.10.20.200-10.10.20.220
---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: pfsense-router
  namespace: metallb-system
spec:
  myASN: 64500              # MetalLB's AS number
  peerASN: 64501            # Router's AS number
  peerAddress: 10.10.20.1   # Router IP
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: bgp-advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - production-pool
  aggregationLength: 32     # /32 for individual IPs
```

### pfSense BGP Configuration

1. **Install FRR Package**:
   - System → Package Manager → Available Packages
   - Search "FRR" → Install

2. **Enable BGP**:
   - Services → FRR → Global Settings
   - ☑ Enable FRR
   - Set Master Password
   - ☑ Enable BGP

3. **Configure BGP**:
   ```
   Services → FRR → BGP
   - Local AS: 64501
   - Router ID: 10.10.20.1
   ```

4. **Add Neighbors** (one per worker node):
   ```
   Neighbor: 10.10.20.4 (k8s-w1)
   Remote AS: 64500
   Description: k8s-w1
   
   Neighbor: 10.10.20.5 (k8s-w2)
   Remote AS: 64500
   Description: k8s-w2
   ```

---

## ⚖️ Comparison: Layer 2 vs Layer 3

### Side-by-Side Comparison

| Feature | Layer 2 (ARP/NDP) | Layer 3 (BGP) |
|---------|-------------------|---------------|
| **Setup Complexity** | Simple | Complex |
| **Router Config** | None | BGP peering required |
| **Load Balancing** | ❌ Single node per VIP | ✅ ECMP across nodes |
| **Traffic Distribution** | 100% on one node | Distributed (e.g., 33% each) |
| **Failover** | ~2 seconds | BGP convergence (~seconds) |
| **Bandwidth** | Limited to one node | Scales with nodes |
| **Cross-Subnet** | ❌ L2 only | ✅ Routable |
| **Production Use** | Small/dev clusters | Large/production clusters |

### Use Case Recommendations

**Choose Layer 2 if:**
- 🏠 Small lab/development environment
- 📊 Low traffic requirements
- 🔧 No access to BGP-capable router
- ⚡ Need quick setup

**Choose Layer 3 if:**
- 🏢 Production environment
- 📈 High traffic/performance needs
- 🌐 Multi-subnet infrastructure
- 🔄 Have BGP-capable router (pfSense, hardware router, etc.)

### Real-World Example

**Scenario**: 3-node cluster, web service getting 1000 req/sec

**Layer 2**:
```
10.10.20.201 → k8s-w2 (1000 req/sec)
                ├─ Pod A: 500 req/sec
                └─ Pod B: 500 req/sec

k8s-w1: idle (backup)
k8s-w3: idle (backup)

Bottleneck: k8s-w2 network interface
```

**Layer 3 with ECMP**:
```
10.10.20.201 → Router distributes:
    ├─ k8s-w1 (333 req/sec) → Pod A: 333 req/sec
    ├─ k8s-w2 (333 req/sec) → Pod B: 333 req/sec
    └─ k8s-w3 (334 req/sec) → Pod C: 334 req/sec

All nodes utilized
No single bottleneck
```

---

##  Configuration Examples

### Basic Layer 2 Setup

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.10.20.200-10.10.20.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
```

### Multiple Pools

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production
  namespace: metallb-system
spec:
  addresses:
  - 10.10.20.200-10.10.20.210
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: development
  namespace: metallb-system
spec:
  addresses:
  - 10.10.20.211-10.10.20.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advert
  namespace: metallb-system
```

### Using Specific Pool

```yaml
apiVersion: v1
kind: Service
metadata:
  name: production-app
  annotations:
    metallb.io/address-pool: production  # Request IP from specific pool
spec:
  type: LoadBalancer
  selector:
    app: production-app
  ports:
  - port: 80
    targetPort: 8080
```

### BGP with Node Selector

```yaml
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: border-routers
  namespace: metallb-system
spec:
  myASN: 64500
  peerASN: 64501
  peerAddress: 10.10.20.1
  nodeSelectors:
  - matchLabels:
      kubernetes.io/hostname: k8s-w1
  - matchLabels:
      kubernetes.io/hostname: k8s-w2
```

---

## 🔍 Troubleshooting

### Checking MetalLB Status

```bash
# Check controller
kubectl get pods -n metallb-system -l app=metallb,component=controller

# Check speakers
kubectl get pods -n metallb-system -l app=metallb,component=speaker

# View logs
kubectl logs -n metallb-system -l app=metallb,component=controller
kubectl logs -n metallb-system -l app=metallb,component=speaker
```

### Service Stuck in Pending

```bash
# Check service
kubectl describe service <service-name>

# Common issues:
# 1. No IP pools configured
kubectl get ipaddresspools -n metallb-system

# 2. Pool exhausted
kubectl get ipaddresspools -n metallb-system -o yaml

# 3. No L2Advertisement or BGPAdvertisement
kubectl get l2advertisements -n metallb-system
kubectl get bgpadvertisements -n metallb-system
```

### Layer 2: Check ARP

```bash
# From a client machine
ip neigh | grep <external-ip>

# Should show MAC address of the leader node
# 10.10.20.201 dev eth0 lladdr 52:54:00:xx:xx:xx REACHABLE
```

### Layer 3: Check BGP

```bash
# Check BGP peering status (from speaker pod)
kubectl exec -n metallb-system <speaker-pod> -- gobgp neighbor

# Should show state: Established
```

### View IP Assignments

```bash
# See which IPs are allocated
kubectl get services -A -o wide | grep LoadBalancer

# Check IPAddressPool usage
kubectl describe ipaddresspool <pool-name> -n metallb-system
```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Service pending | No IP pool | Create IPAddressPool |
| Service pending | Pool exhausted | Expand address range |
| Service pending | No advertisement | Create L2Advertisement/BGPAdvertisement |
| Can't reach VIP | Wrong subnet | Check VIP is routable |
| BGP not working | Firewall | Allow TCP 179 (BGP) |
| L2 not working | Network policy | Check ARP isn't blocked |

---

## 📚 Additional Resources

- [MetalLB Official Docs](https://metallb.universe.tf/)
- [MetalLB GitHub](https://github.com/metallb/metallb)
- [BGP Tutorial](https://metallb.universe.tf/concepts/bgp/)
- [Layer 2 Tutorial](https://metallb.universe.tf/concepts/layer2/)
- [pfSense FRR Package](https://docs.netgate.com/pfsense/en/latest/packages/frr.html)

---

## 🎯 Summary

MetalLB enables LoadBalancer services on bare metal Kubernetes:

- **Layer 2 Mode**: Simple, ARP-based, single active node per VIP
- **Layer 3 Mode**: BGP-based, true load balancing across nodes via ECMP
- **Use Layer 2 for**: Development, small deployments, simple setups
- **Use Layer 3 for**: Production, high traffic, scalability requirements

Choose the mode that fits your infrastructure and requirements!
