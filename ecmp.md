# ⚖️ ECMP (Equal Cost Multi-Path)

## 📋 Table of Contents
1. [What is ECMP?](#what-is-ecmp)
2. [How ECMP Works](#how-ecmp-works)
3. [Load Balancing with ECMP](#load-balancing-with-ecmp)
4. [ECMP in Kubernetes](#ecmp-in-kubernetes)
5. [Configuration Examples](#configuration-examples)
6. [Troubleshooting](#troubleshooting)

---

## 🔍 What is ECMP?

**ECMP (Equal Cost Multi-Path)** is a routing strategy that allows a router to forward packets over multiple paths with equal routing cost. Instead of selecting a single "best" path, ECMP utilizes all available equal-cost paths to distribute traffic.

```
┌──────────────────────────────────────────────────────────────┐
│              Traditional Routing vs ECMP                     │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Traditional Routing (Single Path):                          │
│  ┌────────┐                      ┌────────┐                 │
│  │ Source │ ──────────────────►  │ Dest   │                 │
│  └────────┘                      └────────┘                 │
│      │                                                       │
│      └── Path 1 (Cost 10) ✅ Used                            │
│          Path 2 (Cost 10) ❌ Unused                          │
│          Path 3 (Cost 10) ❌ Unused                          │
│                                                              │
│  Problem: 2/3 of capacity wasted!                            │
│                                                              │
│  ─────────────────────────────────────────────────────────  │
│                                                              │
│  ECMP (Multi-Path):                                          │
│  ┌────────┐     ┌───► Path 1 ───┐    ┌────────┐            │
│  │        │     │                │    │        │            │
│  │ Source │ ────┼───► Path 2 ───┼───►│  Dest  │            │
│  │        │     │                │    │        │            │
│  └────────┘     └───► Path 3 ───┘    └────────┘            │
│                                                              │
│  All paths (Cost 10) ✅ Used simultaneously                  │
│                                                              │
│  Benefit: 3x capacity, load distribution, redundancy         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Key Characteristics

- **Equal Cost**: Only works with paths that have identical routing metrics
- **Per-Flow**: Typically load balances per-flow (not per-packet) to avoid reordering
- **Hash-Based**: Uses packet header hash to select path consistently
- **Automatic**: Router automatically discovers and uses equal-cost paths
- **Failover**: Automatically removes failed paths

---

## ⚙️ How ECMP Works

### Path Selection with Hashing

ECMP uses hashing to deterministically select a path for each flow:

```
┌──────────────────────────────────────────────────────────────┐
│                    ECMP Hashing Process                      │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Extract Packet Headers                                   │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Source IP:        10.244.1.5                          │ │
│  │  Destination IP:   10.244.2.8                          │ │
│  │  Source Port:      54321                               │ │
│  │  Destination Port: 8080                                │ │
│  │  Protocol:         TCP                                 │ │
│  └────────────────────────────────────────────────────────┘ │
│                       │                                      │
│                       ▼                                      │
│  2. Hash Function                                            │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  hash = hash_function(src_ip, dst_ip, src_port,       │ │
│  │                      dst_port, protocol)               │ │
│  │                                                        │ │
│  │  Result: 0xA3F5B2C1                                    │ │
│  └────────────────────────────────────────────────────────┘ │
│                       │                                      │
│                       ▼                                      │
│  3. Modulo Operation                                         │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  path_index = hash % number_of_paths                   │ │
│  │  path_index = 0xA3F5B2C1 % 3 = 1                       │ │
│  └────────────────────────────────────────────────────────┘ │
│                       │                                      │
│                       ▼                                      │
│  4. Select Path                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Path 0: Router A (192.168.1.1)                        │ │
│  │  Path 1: Router B (192.168.1.2) ✅ Selected            │ │
│  │  Path 2: Router C (192.168.1.3)                        │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Result: All packets in this flow use Path 1                 │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Hash Fields

Different implementations use different hash fields:

| Implementation | Hash Fields | Pros | Cons |
|----------------|-------------|------|------|
| **3-tuple** | Src IP, Dst IP, Protocol | Simple | Limited distribution |
| **5-tuple** | + Src Port, Dst Port | Better distribution | Standard |
| **7-tuple** | + VLAN, Ingress Port | Best distribution | Complex |

### Per-Flow vs Per-Packet

```
┌──────────────────────────────────────────────────────────────┐
│              Per-Flow vs Per-Packet ECMP                     │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Per-Flow (Standard):                                        │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Flow 1: All packets → Path A                          │ │
│  │  Flow 2: All packets → Path B                          │ │
│  │  Flow 3: All packets → Path C                          │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Benefits:                                                   │
│  ✅ Packets arrive in order                                  │
│  ✅ Better for TCP (no reordering)                           │
│  ✅ Consistent latency per flow                              │
│                                                              │
│  Drawbacks:                                                  │
│  ⚠️  Large flows can't use multiple paths                    │
│  ⚠️  Uneven distribution with few flows                      │
│                                                              │
│  ─────────────────────────────────────────────────────────  │
│                                                              │
│  Per-Packet (Rare):                                          │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Flow 1:                                               │ │
│  │    Packet 1 → Path A                                   │ │
│  │    Packet 2 → Path B                                   │ │
│  │    Packet 3 → Path C                                   │ │
│  │    Packet 4 → Path A                                   │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Benefits:                                                   │
│  ✅ Better utilization for large flows                       │
│  ✅ Fine-grained load balancing                              │
│                                                              │
│  Drawbacks:                                                  │
│  ❌ Packet reordering                                        │
│  ❌ TCP performance degradation                              │
│  ❌ Variable latency                                         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## ⚖️ Load Balancing with ECMP

### Traffic Distribution

```
┌──────────────────────────────────────────────────────────────┐
│                ECMP Load Distribution                        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Ideal Distribution (Many Small Flows):                      │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Path A: ████████████████████ 33.3%                    │ │
│  │  Path B: ████████████████████ 33.3%                    │ │
│  │  Path C: ████████████████████ 33.4%                    │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Real World (Mix of Flow Sizes):                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Path A: ████████████████ 28%  (2 small + 1 medium)   │ │
│  │  Path B: ██████████████████████████ 45% (1 large)     │ │
│  │  Path C: ████████████ 27%  (3 small)                  │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Challenge: Large flows (elephant flows) can cause imbalance │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### ECMP vs Other Load Balancing

| Method | Granularity | State | Performance | Use Case |
|--------|-------------|-------|-------------|----------|
| **ECMP** | Per-flow | Stateless | Very High | L3 routing |
| **DNS Round-Robin** | Per-request | Stateless | High | Global LB |
| **[IPVS](linux-networking.md#ipvs-ip-virtual-server)** | Per-connection | Stateful | High | L4 LB |
| **[iptables](linux-networking.md#iptables)** | Per-connection | Stateful | Medium | L4 LB |
| **eBPF** | Per-packet | Hybrid | Very High | Modern LB |

---

## 🐝 ECMP in Kubernetes

### 1. MetalLB BGP Mode

MetalLB uses ECMP with BGP for LoadBalancer services:

```
┌──────────────────────────────────────────────────────────────┐
│            MetalLB BGP + ECMP Architecture                   │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                      Router                                  │
│                   (192.168.1.1)                              │
│                         │                                    │
│        ┌────────────────┼────────────────┐                   │
│        │ BGP Peer       │ BGP Peer       │ BGP Peer         │
│        │                │                │                   │
│   ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐             │
│   │  Node 1  │    │  Node 2  │    │  Node 3  │             │
│   │  .10     │    │  .11     │    │  .12     │             │
│   └──────────┘    └──────────┘    └──────────┘             │
│                                                              │
│  All nodes advertise:                                        │
│  • Service IP: 192.168.1.100                                 │
│  • Same metric (equal cost)                                  │
│                                                              │
│  Router sees 3 equal paths to 192.168.1.100:                 │
│  • Via 192.168.1.10 (Node 1)                                 │
│  • Via 192.168.1.11 (Node 2)                                 │
│  • Via 192.168.1.12 (Node 3)                                 │
│                                                              │
│  ECMP distributes traffic:                                   │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Client A → hash → Node 1                              │ │
│  │  Client B → hash → Node 2                              │ │
│  │  Client C → hash → Node 3                              │ │
│  │  Client D → hash → Node 1                              │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Result: True load balancing across all nodes!              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Benefits**:
- ✅ No single point of failure
- ✅ Automatic failover (BGP convergence)
- ✅ Scales horizontally
- ✅ Hardware-accelerated by router

See [metallb.md](metallb.md) for detailed MetalLB configuration.

### 2. Calico BGP Mode

Calico uses ECMP for pod network routing:

```
┌──────────────────────────────────────────────────────────────┐
│              Calico BGP + ECMP for Pods                      │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Scenario: Multiple paths to Pod subnet                      │
│                                                              │
│  Router sees routes to 10.244.2.0/24:                        │
│  • Via Node 1 (primary)                                      │
│  • Via Node 2 (backup, same cost)                            │
│                                                              │
│  With ECMP:                                                  │
│  • Traffic distributed between both paths                    │
│  • If Node 1 fails, instant failover to Node 2               │
│  • Better utilization of network capacity                    │
│                                                              │
│  Without ECMP:                                               │
│  • Only primary path used                                    │
│  • Backup path idle until failure                            │
│  • Slower failover (routing protocol convergence)            │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 3. Cloud Provider Load Balancers

Major cloud providers use ECMP internally:

```
┌──────────────────────────────────────────────────────────────┐
│          Cloud Load Balancer with ECMP                       │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  AWS NLB (Network Load Balancer):                            │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                                                        │ │
│  │     Internet                                           │ │
│  │        │                                               │ │
│  │        ▼                                               │ │
│  │   ┌──────────┐                                         │ │
│  │   │ AWS Edge │ (ECMP distribution)                     │ │
│  │   └─────┬────┘                                         │ │
│  │         │                                               │ │
│  │    ┌────┼────┐                                         │ │
│  │    │    │    │                                         │ │
│  │    ▼    ▼    ▼                                         │ │
│  │  ┌──┐ ┌──┐ ┌──┐                                       │ │
│  │  │LB│ │LB│ │LB│  (Multiple LB nodes)                  │ │
│  │  └┬─┘ └┬─┘ └┬─┘                                       │ │
│  │   │    │    │                                          │ │
│  │   └────┼────┘                                          │ │
│  │        │                                               │ │
│  │        ▼                                               │ │
│  │   K8s Nodes                                            │ │
│  │                                                        │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  • ECMP at edge for multi-AZ distribution                    │
│  • High availability and performance                         │
│  • Automatic scaling                                         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 4. Ingress Controllers

Some ingress controllers benefit from ECMP:

```
┌──────────────────────────────────────────────────────────────┐
│          Ingress with ECMP (MetalLB + BGP)                   │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  LoadBalancer Service for Ingress Controller:                │
│  • IP: 192.168.1.200                                         │
│  • Advertised by all nodes via BGP                           │
│  • Router uses ECMP to distribute                            │
│                                                              │
│  Traffic Flow:                                               │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Client → Router → (ECMP) → Node 1/2/3                │ │
│  │         → Ingress Pod → Backend Pods                   │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Benefits:                                                   │
│  ✅ Load distributed across all ingress pods                 │
│  ✅ No single node bottleneck                                │
│  ✅ Automatic failover                                       │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 🔧 Configuration Examples

### BGP with ECMP (FRRouting)

```bash
# FRRouting configuration for ECMP
router bgp 65001
 bgp router-id 192.168.1.1
 
 # Enable ECMP
 maximum-paths 8          # Allow up to 8 equal-cost paths
 maximum-paths ibgp 8     # For iBGP as well
 
 neighbor 192.168.1.10 remote-as 65000
 neighbor 192.168.1.11 remote-as 65000
 neighbor 192.168.1.12 remote-as 65000
 
 address-family ipv4 unicast
  neighbor 192.168.1.10 activate
  neighbor 192.168.1.11 activate
  neighbor 192.168.1.12 activate
 exit-address-family
!

# Verify ECMP routes
show ip route 192.168.1.100
# Should show multiple next-hops with same metric
```

### Linux Kernel ECMP

```bash
# Enable multipath routing in Linux
sysctl -w net.ipv4.fib_multipath_hash_policy=1  # L4 hashing

# Add route with multiple paths
ip route add 10.244.0.0/16 \
  nexthop via 192.168.1.10 weight 1 \
  nexthop via 192.168.1.11 weight 1 \
  nexthop via 192.168.1.12 weight 1

# Verify
ip route show 10.244.0.0/16

# Example output:
# 10.244.0.0/16
#   nexthop via 192.168.1.10 dev eth0 weight 1
#   nexthop via 192.168.1.11 dev eth0 weight 1
#   nexthop via 192.168.1.12 dev eth0 weight 1
```

### MetalLB BGP Configuration

```yaml
apiVersion: metallb.io/v1beta1
kind: BGPPeer
metadata:
  name: router
  namespace: metallb-system
spec:
  myASN: 65001
  peerASN: 65000
  peerAddress: 192.168.1.1
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.100-192.168.1.200
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: ecmp-enabled
  namespace: metallb-system
spec:
  ipAddressPools:
  - production
  # All nodes advertise, router enables ECMP
```

### Calico BGP Configuration

```yaml
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  logSeverityScreen: Info
  nodeToNodeMeshEnabled: false
  asNumber: 65001
---
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: router-peer
spec:
  peerIP: 192.168.1.1
  asNumber: 65000
```

See [bgp.md](bgp.md) for comprehensive BGP configuration.

---

## 🔍 Troubleshooting

### Verify ECMP is Working

```bash
# 1. Check routing table for multiple paths
ip route show <destination>

# Expected: Multiple nexthop entries
# 10.244.2.0/24
#   nexthop via 192.168.1.10 dev eth0 weight 1
#   nexthop via 192.168.1.11 dev eth0 weight 1

# 2. Check BGP routes
# FRRouting
vtysh -c "show ip route <destination>"

# BIRD (Calico)
birdc show route for <destination>

# 3. Test traffic distribution
# Send multiple flows and check distribution
for i in {1..100}; do
  curl -s --local-port $((30000 + i)) http://service-ip/ > /dev/null &
done

# Monitor on each node
tcpdump -i eth0 -nn dst <service-ip> | wc -l

# 4. Check connection distribution
# On router/node
netstat -tn | grep <service-ip> | awk '{print $5}' | sort | uniq -c

# 5. Verify hash policy
sysctl net.ipv4.fib_multipath_hash_policy
# 0 = Layer 3 (src/dst IP only)
# 1 = Layer 4 (includes ports) - Recommended
```

### Common ECMP Issues

```
┌──────────────────────────────────────────────────────────────┐
│                    ECMP Troubleshooting                      │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Only One Path Used                                       │
│     Symptoms: Traffic only on one node                       │
│     Causes:                                                  │
│     • ECMP not enabled on router                             │
│     • Routes have different metrics                          │
│     • Only one route advertised                              │
│     Fix:                                                     │
│     • Enable maximum-paths in BGP                            │
│     • Check route metrics are equal                          │
│     • Verify all nodes advertising                           │
│                                                              │
│  2. Uneven Distribution                                      │
│     Symptoms: Some nodes heavily loaded                      │
│     Causes:                                                  │
│     • Few large flows (elephant flows)                       │
│     • Poor hash distribution                                 │
│     • Layer 3 hashing only (use Layer 4)                     │
│     Fix:                                                     │
│     • Use L4 hash policy                                     │
│     • Increase number of flows                               │
│     • Consider flowlet switching                             │
│                                                              │
│  3. Packets Out of Order                                     │
│     Symptoms: TCP retransmissions, poor performance          │
│     Causes:                                                  │
│     • Per-packet ECMP (rare)                                 │
│     • Inconsistent hashing                                   │
│     • Asymmetric routing                                     │
│     Fix:                                                     │
│     • Ensure per-flow hashing                                │
│     • Check routing symmetry                                 │
│     • Verify hash consistency                                │
│                                                              │
│  4. Path Not Removed on Failure                              │
│     Symptoms: Traffic to dead node                           │
│     Causes:                                                  │
│     • BGP session still up                                   │
│     • Health check not working                               │
│     • Slow convergence                                       │
│     Fix:                                                     │
│     • Reduce BGP timers                                      │
│     • Enable BFD (Bidirectional Forwarding Detection)        │
│     • Check health probe config                              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Monitoring ECMP

```bash
# Traffic distribution per path
watch -n 1 'ip -s link show eth0'

# BGP route monitoring (FRRouting)
watch -n 1 'vtysh -c "show ip bgp summary"'

# Connection count per backend
watch -n 1 'conntrack -L | grep <service-ip> | \
            awk "{print \$5}" | sort | uniq -c'

# Packet rate per interface
sar -n DEV 1 10

# ECMP path utilization
# Custom monitoring with prometheus/grafana
# Metrics: packet_count, byte_count per next-hop
```

---

## 📊 Performance Considerations

### ECMP Performance Characteristics

```
┌──────────────────────────────────────────────────────────────┐
│                  ECMP Performance                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Advantages:                                                 │
│  ✅ Stateless (no connection tracking overhead)              │
│  ✅ Hardware-accelerated (ASIC-based)                        │
│  ✅ Near-linear scaling with paths                           │
│  ✅ Sub-microsecond overhead                                 │
│  ✅ Minimal CPU usage                                        │
│                                                              │
│  Limitations:                                                │
│  ❌ Per-flow granularity (not per-packet)                    │
│  ❌ Elephant flows can cause imbalance                       │
│  ❌ Hash polarization possible                               │
│  ❌ Limited to equal-cost paths                              │
│                                                              │
│  Optimization Tips:                                          │
│  • Use L4 (5-tuple) hashing for better distribution          │
│  • Increase maximum-paths value                              │
│  • Consider weighted ECMP for unequal capacity               │
│  • Enable BFD for fast failure detection                     │
│  • Monitor for hash polarization                             │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 📚 Additional Resources

- [RFC 2992 - Analysis of ECMP](https://datatracker.ietf.org/doc/html/rfc2992)
- [BGP Multipath Documentation](bgp.md)
- [MetalLB ECMP Configuration](metallb.md)
- [Calico BGP Mode](https://docs.projectcalico.org/networking/bgp)

---

## 🔗 Related Topics

- [BGP (Border Gateway Protocol)](bgp.md)
- [MetalLB Load Balancing](metallb.md)
- [Linux Networking (IPVS alternative)](linux-networking.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
