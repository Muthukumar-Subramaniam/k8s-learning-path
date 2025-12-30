# 🌐 BGP (Border Gateway Protocol)

## 📋 Table of Contents
1. [What is BGP?](#what-is-bgp)
2. [BGP Fundamentals](#bgp-fundamentals)
3. [How BGP Works](#how-bgp-works)
4. [BGP in Kubernetes](#bgp-in-kubernetes)
5. [BGP vs Other Routing Protocols](#bgp-vs-other-routing-protocols)
6. [Use Cases](#use-cases)

---

## 🔍 What is BGP?

**BGP (Border Gateway Protocol)** is a standardized exterior gateway protocol designed to exchange routing and reachability information between autonomous systems (AS) on the Internet. It's the protocol that makes the Internet work by enabling routers to share information about which networks they can reach.

### Key Characteristics

- **Protocol Type**: Path vector routing protocol
- **RFC**: RFC 4271
- **Port**: TCP 179
- **Purpose**: Inter-domain routing (between different networks/organizations)
- **Scale**: Handles hundreds of thousands of routes

### Why BGP Matters

BGP is often called the "routing protocol of the Internet" because:
- It connects different networks (ISPs, data centers, cloud providers)
- It enables traffic to find the best path across multiple networks
- It provides redundancy and failover capabilities
- It's highly scalable and policy-driven

---

## 🧩 BGP Fundamentals

### Autonomous Systems (AS)

An **Autonomous System** is a collection of IP networks under a single administrative domain that presents a common routing policy to the Internet.

```
┌─────────────────────────────────────────────────────────────┐
│                    Internet Topology                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌──────────────┐      ┌──────────────┐                  │
│   │   AS 65001   │      │   AS 65002   │                  │
│   │  (Your Org)  │◄────►│    (ISP)     │                  │
│   └──────────────┘ BGP  └──────────────┘                  │
│         │                      │                            │
│         │                      │                            │
│   ┌─────▼──────┐         ┌────▼─────────┐                 │
│   │  Networks  │         │  Backbone    │                  │
│   │10.0.0.0/8  │         │  Networks    │                  │
│   └────────────┘         └──────────────┘                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

- **Public AS Numbers**: 1-64495 (assigned by regional registries)
- **Private AS Numbers**: 64512-65535 (for internal use)

### BGP Session Types

#### 1. **eBGP (External BGP)**
- Between routers in **different** autonomous systems
- Typically used between organizations
- Default TTL = 1 (directly connected neighbors)

#### 2. **iBGP (Internal BGP)**
- Between routers in the **same** autonomous system
- Used to distribute external routes within an organization
- Default TTL = 255

```
┌─────────────────────────────────────────────────────────────┐
│                    BGP Session Types                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│     AS 65001                    AS 65002                    │
│  ┌────────────────┐          ┌────────────────┐            │
│  │                │          │                │            │
│  │   Router A ◄───┼──eBGP───►│   Router C     │            │
│  │      ▲         │          │                │            │
│  │      │         │          └────────────────┘            │
│  │      │ iBGP    │                                        │
│  │      ▼         │                                        │
│  │   Router B     │                                        │
│  │                │                                        │
│  └────────────────┘                                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## ⚙️ How BGP Works

### BGP Peering

Two routers establish a BGP **peer** relationship (also called neighbor relationship):

1. **TCP Connection**: Routers establish a TCP connection on port 179
2. **OPEN Message**: Exchange BGP capabilities and AS numbers
3. **KEEPALIVE Messages**: Maintain the connection (sent every 60 seconds by default)
4. **UPDATE Messages**: Exchange routing information
5. **NOTIFICATION**: Report errors and close connections

```
┌─────────────────────────────────────────────────────────────┐
│                    BGP Peering Process                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Router A (AS 65001)              Router B (AS 65002)      │
│  192.168.1.1                      192.168.1.2              │
│       │                                  │                  │
│       │  1. TCP SYN (port 179)          │                  │
│       ├─────────────────────────────────►│                  │
│       │  2. TCP SYN-ACK                  │                  │
│       │◄─────────────────────────────────┤                  │
│       │  3. BGP OPEN (AS 65001)          │                  │
│       ├─────────────────────────────────►│                  │
│       │  4. BGP OPEN (AS 65002)          │                  │
│       │◄─────────────────────────────────┤                  │
│       │  5. BGP KEEPALIVE                │                  │
│       ├─────────────────────────────────►│                  │
│       │  6. BGP KEEPALIVE                │                  │
│       │◄─────────────────────────────────┤                  │
│       │                                  │                  │
│       │  === Established State ===       │                  │
│       │                                  │                  │
│       │  7. BGP UPDATE (routes)          │                  │
│       ├─────────────────────────────────►│                  │
│       │  8. BGP UPDATE (routes)          │                  │
│       │◄─────────────────────────────────┤                  │
│       │                                  │                  │
└─────────────────────────────────────────────────────────────┘
```

### Route Advertisement

BGP routers announce (advertise) the networks they can reach:

1. Router learns about a network (locally connected or from another BGP peer)
2. Router evaluates the route using BGP attributes
3. Router selects the best route
4. Router advertises the route to its BGP peers

### BGP Attributes

BGP uses various attributes to select the best path:

| Attribute | Description | Selection Priority |
|-----------|-------------|-------------------|
| **Weight** | Cisco proprietary, local to router | Highest |
| **Local Preference** | Prefer routes within AS | 2 |
| **AS Path** | Number of AS hops (shorter is better) | 3 |
| **Origin** | How route was learned (IGP > EGP > Incomplete) | 4 |
| **MED** | Multi-Exit Discriminator (lower is better) | 5 |
| **Neighbor Type** | eBGP > iBGP | 6 |

### Path Selection Process

```
Route received ────► Is Next Hop reachable? ─No──► Reject
                              │
                             Yes
                              │
                              ▼
                    Highest Weight? ────────────► Select
                              │
                              ▼
                    Highest Local Pref? ─────────► Select
                              │
                              ▼
                    Shortest AS Path? ───────────► Select
                              │
                              ▼
                    Lowest MED? ─────────────────► Select
                              │
                              ▼
                    eBGP over iBGP? ─────────────► Select
                              │
                              ▼
                    Lowest IGP Metric? ──────────► Select
```

---

## 🚀 BGP in Kubernetes

BGP is used in Kubernetes environments for two primary purposes:

### 1. Pod Networking (Calico CNI)

Calico uses BGP to advertise Pod network routes across the cluster.

```
┌─────────────────────────────────────────────────────────────┐
│              Calico BGP Mode Architecture                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Physical Network Switch/Router           │   │
│  │              (BGP Route Reflector)                  │   │
│  └────────┬──────────────────────┬─────────────────────┘   │
│           │                      │                          │
│      BGP Peer               BGP Peer                        │
│           │                      │                          │
│  ┌────────▼────────┐    ┌────────▼────────┐                │
│  │  Node 1         │    │  Node 2         │                │
│  │  10.1.1.1       │    │  10.1.1.2       │                │
│  │                 │    │                 │                │
│  │  Felix (Agent)  │    │  Felix (Agent)  │                │
│  │  BIRD (BGP)     │    │  BIRD (BGP)     │                │
│  │                 │    │                 │                │
│  │  Pod Subnet:    │    │  Pod Subnet:    │                │
│  │  10.244.1.0/24  │    │  10.244.2.0/24  │                │
│  │                 │    │                 │                │
│  │  ┌───────────┐  │    │  ┌───────────┐  │                │
│  │  │   Pod A   │  │    │  │   Pod B   │  │                │
│  │  │10.244.1.5 │  │    │  │10.244.2.8 │  │                │
│  │  └───────────┘  │    │  └───────────┘  │                │
│  └─────────────────┘    └─────────────────┘                │
│                                                             │
│  Each node advertises its Pod subnet via BGP                │
│  Routes: 10.244.1.0/24 → 10.1.1.1                          │
│          10.244.2.0/24 → 10.1.1.2                          │
└─────────────────────────────────────────────────────────────┘
```

**Benefits**:
- No encapsulation overhead (native routing)
- Better performance (no VXLAN/IP-in-IP)
- Works well with existing network infrastructure
- Fine-grained control over routing policies

**Configuration**:
```yaml
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  logSeverityScreen: Info
  nodeToNodeMeshEnabled: true  # Full mesh BGP between nodes
  asNumber: 64512              # Private AS number
```

See [cni.md](cni.md) for more on Calico.

### 2. Load Balancer Services (MetalLB)

MetalLB uses BGP to advertise LoadBalancer service IPs to the network.

```
┌─────────────────────────────────────────────────────────────┐
│           MetalLB BGP Mode Architecture                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│                 Network Router (pfSense)                    │
│                   192.168.1.1 (AS 65000)                    │
│                           │                                 │
│                    BGP Peering                              │
│           ┌───────────────┼───────────────┐                 │
│           │               │               │                 │
│      ┌────▼─────┐    ┌────▼─────┐   ┌────▼─────┐           │
│      │  Node 1  │    │  Node 2  │   │  Node 3  │           │
│      │ (AS 65001)│   │ (AS 65001)│  │ (AS 65001)│           │
│      │          │    │          │   │          │           │
│      │ MetalLB  │    │ MetalLB  │   │ MetalLB  │           │
│      │ Speaker  │    │ Speaker  │   │ Speaker  │           │
│      └──────────┘    └──────────┘   └──────────┘           │
│                                                             │
│  Service IP: 192.168.1.100 advertised via BGP to router    │
│  Router learns: 192.168.1.100 → 192.168.1.10/11/12         │
│  Traffic distributed using ECMP (Equal Cost Multi-Path)    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Benefits**:
- True load balancing across multiple nodes (ECMP)
- Fast failover (BGP convergence)
- No single point of failure
- Works with existing network infrastructure

**Configuration**:
```yaml
apiVersion: metallb.io/v1beta1
kind: BGPPeer
metadata:
  name: router-peer
  namespace: metallb-system
spec:
  myASN: 65001              # MetalLB AS number
  peerASN: 65000            # Router AS number
  peerAddress: 192.168.1.1  # Router IP
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
  name: advertise
  namespace: metallb-system
spec:
  ipAddressPools:
  - production
```

See [metallb.md](metallb.md) for detailed MetalLB configuration.

---

## 🔄 BGP vs Other Routing Protocols

| Feature | BGP | OSPF | RIP |
|---------|-----|------|-----|
| **Type** | Path Vector | Link State | Distance Vector |
| **Use Case** | Inter-domain | Intra-domain | Small networks |
| **Scalability** | Excellent (Internet scale) | Good (enterprise) | Poor (limited) |
| **Convergence** | Slow | Fast | Slow |
| **Route Selection** | Policy-based | Cost-based | Hop count |
| **Metric** | Multiple attributes | Cost | Hops (max 15) |
| **Protocol** | TCP (179) | IP (89) | UDP (520) |
| **Complexity** | High | Medium | Low |

### Why BGP for Kubernetes?

1. **Scalability**: Can handle large numbers of routes efficiently
2. **Policy Control**: Fine-grained control over route advertisement
3. **Integration**: Works with existing network infrastructure
4. **Vendor Neutral**: Standard protocol supported by all major vendors
5. **Flexibility**: Supports both IPv4 and IPv6

---

## 💡 Use Cases

### Kubernetes Contexts

1. **Calico CNI in BGP Mode**
   - Pod-to-pod routing without encapsulation
   - Direct routing for better performance
   - Integration with data center routers

2. **MetalLB Layer 3 Mode**
   - LoadBalancer services in bare-metal clusters
   - High availability and load distribution
   - Network-level failover

3. **Multi-Cluster Networking**
   - Route advertisement between Kubernetes clusters
   - Service mesh connectivity
   - Hybrid cloud scenarios

### General Network Contexts

1. **Internet Service Providers (ISPs)**
   - Connecting different ISP networks
   - Route exchange between autonomous systems

2. **Enterprise Networks**
   - Multi-site connectivity
   - Data center interconnection
   - Cloud provider connectivity

3. **Data Centers**
   - Spine-leaf architectures
   - EVPN (Ethernet VPN) over BGP
   - Network automation and SDN

---

## 📚 Additional Resources

- **RFC 4271**: BGP-4 Specification
- **RFC 4456**: BGP Route Reflection
- **RFC 4760**: Multiprotocol Extensions for BGP-4
- [Calico BGP Documentation](https://docs.projectcalico.org/networking/bgp)
- [MetalLB BGP Configuration](metallb.md#layer-3-bgp-mode)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)

---

## 🔗 Related Topics

- [Container Network Interface (CNI)](cni.md)
- [MetalLB Load Balancing](metallb.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
- [IP Address Management (IPAM)](ipam.md)
- [Network Policies](network-policy.md)
