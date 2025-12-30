# 🌐 Overlay Networks & VXLAN

## 📋 Table of Contents
1. [What is an Overlay Network?](#what-is-an-overlay-network)
2. [Overlay vs Underlay](#overlay-vs-underlay)
3. [VXLAN](#vxlan)
4. [Other Encapsulation Methods](#other-encapsulation-methods)
5. [Overlay Networks in Kubernetes](#overlay-networks-in-kubernetes)
6. [Performance Considerations](#performance-considerations)

---

## 🔍 What is an Overlay Network?

An **overlay network** is a virtual network built on top of an existing physical network (underlay). It creates a logical network topology that is independent of the physical network infrastructure.

```
┌──────────────────────────────────────────────────────────────┐
│              Overlay vs Physical Network                     │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Overlay Network (Virtual)                                   │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                                                          ││
│  │   Pod A          Pod B          Pod C          Pod D    ││
│  │   10.244.1.5     10.244.2.8     10.244.1.9     10.244.3.2││
│  │      │              │              │              │      ││
│  │      └──────────────┴──────────────┴──────────────┘      ││
│  │           Virtual Network (10.244.0.0/16)                ││
│  └─────────────────────────────────────────────────────────┘│
│                          │                                   │
│                   Encapsulation                              │
│                          │                                   │
│  Underlay Network (Physical)                                 │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                                                          ││
│  │   Node 1         Node 2         Node 3                  ││
│  │   192.168.1.10   192.168.1.11   192.168.1.12            ││
│  │      │              │              │                     ││
│  │      └──────────────┴──────────────┘                     ││
│  │           Physical Network (192.168.1.0/24)              ││
│  └─────────────────────────────────────────────────────────┘│
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Key Concepts

- **Encapsulation**: Wrapping original packets in an outer header for transport
- **Tunneling**: Creating a virtual point-to-point connection through the underlay
- **Decapsulation**: Removing the outer header at the destination
- **Virtual Endpoints**: Logical addresses in the overlay (e.g., Pod IPs)
- **Physical Endpoints**: Real addresses in the underlay (e.g., Node IPs)

---

## 🔄 Overlay vs Underlay

### Underlay Network

The **underlay** is the physical network infrastructure:

- Physical switches and routers
- Network cables and fiber
- Node IP addresses
- Physical network topology
- Layer 2/3 connectivity

**Example**:
```
Your Kubernetes nodes:
- k8s-master: 192.168.1.10
- k8s-worker1: 192.168.1.11
- k8s-worker2: 192.168.1.12

Physical network: 192.168.1.0/24
Router: 192.168.1.1
```

### Overlay Network

The **overlay** is the virtual network built on top:

- Logical network topology
- Virtual IP addresses (Pod IPs)
- Encapsulated traffic
- Software-defined routing
- Independent of physical topology

**Example**:
```
Your Kubernetes Pods:
- nginx-pod: 10.244.1.5
- db-pod: 10.244.2.8
- app-pod: 10.244.3.2

Pod network: 10.244.0.0/16
Virtual routes between Pods
```

### Comparison

| Aspect | Underlay | Overlay |
|--------|----------|---------|
| **Layer** | Physical (L2/L3) | Virtual (L2/L3) |
| **Addressing** | Node IPs | Pod IPs |
| **Topology** | Fixed by hardware | Flexible, software-defined |
| **Routing** | Physical routers | Virtual routing, encapsulation |
| **Changes** | Requires network admin | Software configuration |
| **Visibility** | Limited to physical network | Can span any underlay |
| **Performance** | Native | Small overhead (encapsulation) |

### Why Overlay Networks?

```
┌──────────────────────────────────────────────────────────────┐
│            Benefits of Overlay Networks                      │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ✅ Network Isolation                                        │
│     • Each tenant/namespace can have its own network         │
│     • No IP conflicts between tenants                        │
│                                                              │
│  ✅ Flexibility                                              │
│     • Works across any underlay network                      │
│     • No physical network changes needed                     │
│     • Easy to extend and modify                              │
│                                                              │
│  ✅ Multi-Datacenter/Cloud                                   │
│     • Spans across physical locations                        │
│     • Works across different cloud providers                 │
│     • Consistent networking model                            │
│                                                              │
│  ✅ Scalability                                              │
│     • Millions of virtual endpoints                          │
│     • Independent of physical network size                   │
│     • Easy to add/remove nodes                               │
│                                                              │
│  ❌ Trade-offs                                               │
│     • Encapsulation overhead (5-10%)                         │
│     • Additional CPU for encap/decap                         │
│     • More complex troubleshooting                           │
│     • MTU considerations                                     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 🔧 VXLAN

**VXLAN (Virtual Extensible LAN)** is the most common overlay network protocol, extending Layer 2 networks over Layer 3 infrastructure.

### VXLAN Basics

- **RFC**: RFC 7348
- **Port**: UDP 4789
- **Header Size**: 50 bytes (8 VXLAN + 8 UDP + 20 IP + 14 Ethernet)
- **VNI**: 24-bit VXLAN Network Identifier (16 million networks)

### VXLAN Packet Format

```
┌──────────────────────────────────────────────────────────────┐
│                 VXLAN Packet Structure                       │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Original Packet:                                            │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Ethernet │ IP │ TCP/UDP │ Payload                    │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  After VXLAN Encapsulation:                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Outer    │ Outer │ UDP    │ VXLAN  │ Original Packet│   │
│  │ Ethernet │ IP    │ Header │ Header │ (above)        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  Detailed VXLAN Header:                                      │
│  ┌────────────────────────────────────┐                     │
│  │ Flags (8 bits): 0x08              │                     │
│  │ Reserved (24 bits)                │                     │
│  │ VNI (24 bits): Network Identifier │                     │
│  │ Reserved (8 bits)                 │                     │
│  └────────────────────────────────────┘                     │
│                                                              │
│  Outer IP Header:                                            │
│  • Source: Node A IP (192.168.1.10)                          │
│  • Destination: Node B IP (192.168.1.11)                     │
│                                                              │
│  UDP Header:                                                 │
│  • Source Port: Ephemeral (for ECMP hashing)                 │
│  • Destination Port: 4789 (VXLAN)                            │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### How VXLAN Works

```
┌──────────────────────────────────────────────────────────────┐
│                  VXLAN Communication Flow                    │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Node 1 (192.168.1.10)           Node 2 (192.168.1.11)      │
│  ┌──────────────────┐            ┌──────────────────┐       │
│  │                  │            │                  │       │
│  │  Pod A           │            │  Pod B           │       │
│  │  10.244.1.5      │            │  10.244.2.8      │       │
│  │       │          │            │       │          │       │
│  │       ▼          │            │       ▼          │       │
│  │  ┌──────────┐    │            │  ┌──────────┐    │       │
│  │  │  veth    │    │            │  │  veth    │    │       │
│  │  └────┬─────┘    │            │  └────┬─────┘    │       │
│  │       │          │            │       │          │       │
│  │  ┌────▼─────┐    │            │  ┌────▼─────┐    │       │
│  │  │  Bridge  │    │            │  │  Bridge  │    │       │
│  │  └────┬─────┘    │            │  └────┬─────┘    │       │
│  │       │          │            │       │          │       │
│  │  ┌────▼─────────────┐         │  ┌────▼─────────────┐    │
│  │  │  VXLAN (VNI 100) │         │  │  VXLAN (VNI 100) │    │
│  │  │  Encapsulation   │         │  │  Decapsulation   │    │
│  │  └────┬─────────────┘         │  └────┬─────────────┘    │
│  │       │          │            │       │          │       │
│  │  ┌────▼─────┐    │            │  ┌────▼─────┐    │       │
│  │  │  eth0    │    │            │  │  eth0    │    │       │
│  │  └────┬─────┘    │            │  └────┬─────┘    │       │
│  └───────┼──────────┘            └───────┼──────────┘       │
│          │                               │                  │
│          └───────────Physical────────────┘                  │
│                     Network                                 │
│                                                              │
│  Packet Flow:                                                │
│  1. Pod A sends to 10.244.2.8                                │
│  2. Bridge routes to VXLAN interface                         │
│  3. VXLAN encapsulates with outer IP (192.168.1.10 → 11)     │
│  4. Physical network transports to Node 2                    │
│  5. VXLAN decapsulates, reveals original packet              │
│  6. Bridge delivers to Pod B                                 │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### VXLAN Configuration Example (Flannel)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-flannel-cfg
  namespace: kube-system
data:
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "Backend": {
        "Type": "vxlan",
        "VNI": 1,
        "Port": 8472
      }
    }
```

### VXLAN Verification

```bash
# Check VXLAN interfaces
ip -d link show type vxlan

# Example output:
# flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
#     link/ether 92:88:7f:3c:1a:2e brd ff:ff:ff:ff:ff:ff
#     vxlan id 1 local 192.168.1.10 dev eth0 srcport 0 0 dstport 8472

# View VXLAN forwarding database
bridge fdb show dev flannel.1

# Check VXLAN routing
ip route show dev flannel.1
```

---

## 🔀 Other Encapsulation Methods

### IP-in-IP

Encapsulates an IP packet inside another IP packet:

```
┌──────────────────────────────────────────────────────────────┐
│                    IP-in-IP Encapsulation                    │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Original Packet:                                            │
│  ┌──────────────────────────────────────┐                   │
│  │ Inner IP │ TCP/UDP │ Payload         │                   │
│  │ 10.244.1.5 → 10.244.2.8              │                   │
│  └──────────────────────────────────────┘                   │
│                                                              │
│  After IP-in-IP Encapsulation:                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Outer IP │ Inner IP │ TCP/UDP │ Payload             │   │
│  │ 192.168.1.10 → 192.168.1.11                          │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  Overhead: 20 bytes (IP header only)                         │
│  Protocol: IP Protocol 4 (IPIP)                              │
│                                                              │
│  Used by: Calico (default mode)                              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Advantages**:
- Lower overhead than VXLAN (20 vs 50 bytes)
- Simpler protocol
- Better performance

**Disadvantages**:
- Doesn't support L2 features
- Some cloud providers block IP-in-IP
- Limited to IPv4 over IPv4

### GRE (Generic Routing Encapsulation)

```
┌──────────────────────────────────────────────────────────────┐
│                    GRE Encapsulation                         │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Outer IP │ GRE Header │ Inner Packet                 │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  GRE Header: 4-8 bytes (depending on options)                │
│  Protocol: IP Protocol 47                                    │
│  Features: Can carry any L3 protocol                         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### GENEVE (Generic Network Virtualization Encapsulation)

Newer, more flexible encapsulation protocol:

- Variable-length options (extensible)
- Better than VXLAN for modern use cases
- Supported by OVS, OVN

### Comparison

| Protocol | Overhead | Complexity | Flexibility | Cloud Support |
|----------|----------|------------|-------------|---------------|
| **VXLAN** | 50 bytes | Medium | High | ✅ Excellent |
| **IP-in-IP** | 20 bytes | Low | Low | ⚠️ Limited |
| **GRE** | 24 bytes | Medium | Medium | ⚠️ Often blocked |
| **GENEVE** | Variable | High | Very High | ✅ Growing |
| **No Encap** | 0 bytes | High | N/A | ⚠️ Requires [BGP](bgp.md) |

---

## 🐝 Overlay Networks in Kubernetes

### CNI Implementations

Different CNIs use different overlay approaches:

```
┌──────────────────────────────────────────────────────────────┐
│             CNI Overlay Implementations                      │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Flannel:                                                    │
│  • Default: VXLAN overlay                                    │
│  • Alternative: host-gw (no overlay)                         │
│  • Simple, easy to setup                                     │
│                                                              │
│  Calico:                                                     │
│  • Default: IP-in-IP (cross-subnet)                          │
│  • Alternative: VXLAN mode                                   │
│  • Best: BGP mode (no overlay)                               │
│  • Flexible encapsulation options                            │
│                                                              │
│  Weave:                                                      │
│  • Mesh overlay network                                      │
│  • Automatic encryption option                               │
│  • Simple setup                                              │
│                                                              │
│  Cilium:                                                     │
│  • Default: VXLAN overlay                                    │
│  • Alternative: GENEVE                                       │
│  • Best: Native routing with BGP                             │
│  • eBPF-accelerated                                          │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

See [cni.md](cni.md) for detailed CNI comparisons.

### When to Use Overlay Networks

```
┌──────────────────────────────────────────────────────────────┐
│         Overlay Networks: When to Use                        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ✅ Use Overlay When:                                        │
│                                                              │
│  • Multi-cloud or hybrid cloud deployments                   │
│  • No control over physical network                          │
│  • Need to span across different networks                    │
│  • Simplicity is priority over performance                   │
│  • Using cloud provider networks (AWS VPC, Azure VNet)       │
│  • Network isolation requirements                            │
│                                                              │
│  ❌ Avoid Overlay When:                                      │
│                                                              │
│  • Maximum performance is critical                           │
│  • Control over physical network (can use BGP)               │
│  • Low-latency requirements                                  │
│  • High packet rate workloads                                │
│  • Cost of CPU overhead is significant                       │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## ⚡ Performance Considerations

### Overhead Analysis

```
┌──────────────────────────────────────────────────────────────┐
│              Overlay Network Performance Impact              │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Packet Size Impact:                                         │
│  ┌────────────────────────────────────────────────────┐     │
│  │  Original Packet:          1500 bytes (Ethernet)   │     │
│  │  VXLAN Overhead:           +50 bytes               │     │
│  │  Total:                    1550 bytes              │     │
│  │                                                     │     │
│  │  Problem: Exceeds standard MTU!                    │     │
│  │                                                     │     │
│  │  Solutions:                                         │     │
│  │  1. Reduce Pod MTU to 1450                         │     │
│  │  2. Increase underlay MTU to 9000 (jumbo frames)   │     │
│  │  3. Use overlay with lower overhead (IP-in-IP)     │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  CPU Overhead:                                               │
│  • Encapsulation: ~5-10% CPU                                 │
│  • Decapsulation: ~5-10% CPU                                 │
│  • Total: ~10-20% more CPU vs native routing                 │
│                                                              │
│  Latency Impact:                                             │
│  • Additional processing: +50-200 microseconds               │
│  • Not significant for most workloads                        │
│  • Matters for ultra-low-latency applications                │
│                                                              │
│  Throughput:                                                 │
│  • ~5-15% reduction vs native routing                        │
│  • eBPF acceleration can reduce overhead                     │
│  • Hardware offload (VXLAN offload) helps                    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### MTU Considerations

```
┌──────────────────────────────────────────────────────────────┐
│                    MTU Sizing                                │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Standard Ethernet MTU: 1500 bytes                           │
│                                                              │
│  Overlay MTU Calculation:                                    │
│  ┌────────────────────────────────────────────────────┐     │
│  │  Underlay MTU:              1500 bytes            │     │
│  │  - Ethernet header:         -14 bytes             │     │
│  │  - IP header:               -20 bytes             │     │
│  │  - UDP header (VXLAN):      -8 bytes              │     │
│  │  - VXLAN header:            -8 bytes              │     │
│  │  ─────────────────────────────────────────────    │     │
│  │  Pod MTU:                   1450 bytes            │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  CNI Plugins automatically configure correct MTU             │
│                                                              │
│  Verification:                                               │
│  $ ip link show                                              │
│  # Check eth0 (node) = 1500                                  │
│  # Check cni0 (pods) = 1450                                  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Optimization Techniques

1. **Hardware Offload**: Use NICs with VXLAN offload support
2. **[eBPF Acceleration](ebpf.md)**: Cilium uses eBPF for faster processing
3. **Jumbo Frames**: Increase underlay MTU to 9000
4. **Native Routing**: Use [BGP](bgp.md) mode when possible (no overlay)

---

## 🛠️ Troubleshooting Overlay Networks

### Common Issues

```bash
# 1. Check VXLAN interface
ip -d link show type vxlan

# 2. Verify MTU settings
ip link show | grep -E "(eth0|cni|flannel)" | grep mtu

# 3. Check forwarding database
bridge fdb show dev flannel.1

# 4. Verify connectivity
# From one node, ping another node's VXLAN interface
ping -c 3 <remote-vxlan-ip>

# 5. Check for packet loss
tc -s qdisc show dev flannel.1

# 6. Capture VXLAN traffic
tcpdump -i eth0 -nn udp port 4789

# 7. Check routing
ip route show table all
```

### Debugging Tips

```
┌──────────────────────────────────────────────────────────────┐
│           Overlay Network Debugging Checklist                │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ✅ Underlay connectivity OK?                                │
│     → Nodes can ping each other                              │
│                                                              │
│  ✅ VXLAN interface up?                                      │
│     → ip link show type vxlan                                │
│                                                              │
│  ✅ Correct VNI?                                             │
│     → All nodes use same VNI                                 │
│                                                              │
│  ✅ MTU configured correctly?                                │
│     → Pod MTU = Underlay MTU - overhead                      │
│                                                              │
│  ✅ Firewall allows VXLAN?                                   │
│     → UDP port 4789 (or custom port) open                    │
│                                                              │
│  ✅ Routes configured?                                       │
│     → ip route shows overlay routes                          │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 📚 Additional Resources

- [RFC 7348 - VXLAN](https://datatracker.ietf.org/doc/html/rfc7348)
- [Flannel Documentation](https://github.com/flannel-io/flannel)
- [Calico VXLAN Mode](https://docs.projectcalico.org/networking/vxlan-ipip)
- [Linux VXLAN Documentation](https://www.kernel.org/doc/Documentation/networking/vxlan.txt)

---

## 🔗 Related Topics

- [Container Network Interface (CNI)](cni.md)
- [BGP Routing](bgp.md)
- [eBPF](ebpf.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
- [Linux Networking](linux-networking.md)
