# Calico Network Interfaces - Real-World Example

This document provides a real-world example of Calico networking on a Kubernetes control plane node, showing actual network interfaces and routing configuration.

## Environment Details

- **Node**: k8s-cp1 (Control Plane)
- **Node IP**: 10.10.20.3/22
- **Calico Version**: Running with IPIP mode
- **Kubernetes Version**: v1.35.0
- **Operating System**: AlmaLinux 10.1 (Heliotrope Lion)

## Network Configuration

```
Node Network:    10.10.20.0/22
Pod Network:     10.8.0.0/16
Service Network: 10.96.0.0/12
```

## Network Interfaces Output

```bash
[root@k8s-cp1 ~]# ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host noprefixroute
       valid_lft forever preferred_lft forever

2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 00:50:56:b6:ad:70 brd ff:ff:ff:ff:ff:ff
    altname enp2s0
    altname ens160
    inet 10.10.20.3/22 brd 10.10.23.255 scope global noprefixroute eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::250:56ff:feb6:ad70/64 scope link proto kernel_ll
       valid_lft forever preferred_lft forever

4: tunl0@NONE: <NOARP,UP,LOWER_UP> mtu 1480 qdisc noqueue state UNKNOWN group default qlen 1000
    link/ipip 0.0.0.0 brd 0.0.0.0
    inet 10.8.170.64/32 scope global tunl0
       valid_lft forever preferred_lft forever

5: calif86b4c07487@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1480 qdisc noqueue state UP group default qlen 1000
    link/ether ee:ee:ee:ee:ee:ee brd ff:ff:ff:ff:ff:ff link-netns cni-cc0ba05c-2db7-7e4f-1889-caada27ebf31
    inet6 fe80::ecee:eeff:feee:eeee/64 scope link proto kernel_ll
       valid_lft forever preferred_lft forever

6: cali51a8a41be5f@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1480 qdisc noqueue state UP group default qlen 1000
    link/ether ee:ee:ee:ee:ee:ee brd ff:ff:ff:ff:ff:ff link-netns cni-81c9dac6-1c7c-b7ea-b4e5-cea50a00dbea
    inet6 fe80::ecee:eeff:feee:eeee/64 scope link proto kernel_ll
       valid_lft forever preferred_lft forever

7: cali1a7063df1d7@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1480 qdisc noqueue state UP group default qlen 1000
    link/ether ee:ee:ee:ee:ee:ee brd ff:ff:ff:ff:ff:ff link-netns cni-f2c1e93f-2d97-a2da-7b5f-b93acd4c6da6
    inet6 fe80::ecee:eeff:feee:eeee/64 scope link proto kernel_ll
       valid_lft forever preferred_lft forever
```

### Interface Breakdown

#### 1. **lo (Loopback)**
- Standard loopback interface
- Used for local node communication
- Address: 127.0.0.1/8

#### 2. **eth0 (Physical Network Interface)**
- Primary network interface connected to the node network
- Address: 10.10.20.3/22
- This is the interface used for:
  - Node-to-node communication
  - External cluster access
  - IPIP tunnel endpoints

#### 3. **tunl0 (IPIP Tunnel)**
- Calico's IPIP tunnel interface
- Address: 10.8.170.64/32
- Used for encapsulating Pod traffic between nodes
- The MTU is reduced to 1480 (20 bytes less than eth0's 1500) to accommodate the IPIP header

**Why IPIP?**
- Provides Layer 3 network connectivity
- Works across networks that don't support BGP
- Encapsulates Pod-to-Pod traffic in IP packets

#### 4. **cali* Interfaces (Virtual Ethernet Pairs)**
- Three veth pairs: `calif86b4c07487`, `cali51a8a41be5f`, `cali1a7063df1d7`
- Each represents one Pod running on this node
- One end is in the host network namespace (what we see)
- Other end (`@if2`) is inside the Pod's network namespace
- These are connected like a virtual cable between the host and Pod

**Veth Pair Architecture:**
```
Host Network Namespace          Pod Network Namespace
┌─────────────────────┐        ┌──────────────────┐
│  calif86b4c07487    │========│  eth0 (in Pod)   │
│  (host side)        │        │  10.8.170.65/32  │
└─────────────────────┘        └──────────────────┘
```

## Routing Table Output

```bash
[root@k8s-cp1 ~]# route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.10.20.1      0.0.0.0         UG    100    0        0 eth0
10.8.94.64      10.10.20.5      255.255.255.192 UGH   0      0        0 tunl0
10.8.170.65     0.0.0.0         255.255.255.255 UH    0      0        0 calif86b4c07487
10.8.170.66     0.0.0.0         255.255.255.255 UH    0      0        0 cali51a8a41be5f
10.8.170.67     0.0.0.0         255.255.255.255 UH    0      0        0 cali1a7063df1d7
10.8.247.192    10.10.20.4      255.255.255.192 UGH   0      0        0 tunl0
10.10.20.0      0.0.0.0         255.255.252.0   U     100    0        0 eth0
```

### Route Breakdown

#### 1. **Default Route**
```
Destination: 0.0.0.0/0
Gateway: 10.10.20.1
Interface: eth0
```
- All traffic not matching other routes goes to the default gateway
- Used for external/internet traffic

#### 2. **Remote Pod Network Routes (via IPIP tunnel)**

**Worker-2 Pod Network:**
```
Destination: 10.8.94.64/26
Gateway: 10.10.20.5 (k8s-w2 node IP)
Interface: tunl0
```
- Routes traffic to Pods on Worker-2
- Traffic is encapsulated via IPIP tunnel to node 10.10.20.5

**Worker-1 Pod Network:**
```
Destination: 10.8.247.192/26
Gateway: 10.10.20.4 (k8s-w1 node IP)
Interface: tunl0
```
- Routes traffic to Pods on Worker-1
- Traffic is encapsulated via IPIP tunnel to node 10.10.20.4

#### 3. **Local Pod Routes (direct veth pairs)**
```
10.8.170.65 → calif86b4c07487
10.8.170.66 → cali51a8a41be5f
10.8.170.67 → cali1a7063df1d7
```
- Each Pod on this node has a /32 route to its veth pair
- Traffic goes directly to the veth interface (no encapsulation needed)

#### 4. **Node Network Route**
```
Destination: 10.10.20.0/22
Interface: eth0
```
- Local network route for node-to-node communication
- Used for direct communication between Kubernetes nodes

## Traffic Flow Examples

### Example 1: Pod-to-Pod on Same Node

**Scenario**: Pod 10.8.170.65 (on k8s-cp1) → Pod 10.8.170.66 (on k8s-cp1)

```
┌──────────────────────────────────────────────────────────────────┐
│                          k8s-cp1 Node                             │
│                                                                    │
│  ┌─────────────┐                              ┌─────────────┐    │
│  │   Pod A     │                              │   Pod B     │    │
│  │ 10.8.170.65 │                              │ 10.8.170.66 │    │
│  └──────┬──────┘                              └──────▲──────┘    │
│         │ eth0                                  eth0 │            │
│         │                                            │            │
│         ▼                                            │            │
│  calif86b4c07487 ─────── routing ────────► cali51a8a41be5f       │
│                                                                    │
└──────────────────────────────────────────────────────────────────┘

Flow:
1. Pod A sends packet to 10.8.170.66
2. Exits via Pod A's eth0 interface
3. Arrives at calif86b4c07487 (veth pair host side)
4. Host routing table routes to cali51a8a41be5f
5. Enters Pod B's network namespace via eth0
6. Arrives at Pod B
```

### Example 2: Pod-to-Pod on Different Nodes (IPIP Encapsulation)

**Scenario**: Pod 10.8.170.65 (on k8s-cp1) → Pod 10.8.247.196 (on k8s-w1)

```
┌─────────────────────────────────┐           ┌─────────────────────────────────┐
│         k8s-cp1 Node             │           │          k8s-w1 Node            │
│                                  │           │                                 │
│  ┌─────────────┐                 │           │                ┌─────────────┐  │
│  │   Pod A     │                 │           │                │   Pod B     │  │
│  │ 10.8.170.65 │                 │           │                │10.8.247.196 │  │
│  └──────┬──────┘                 │           │                └──────▲──────┘  │
│         │                        │           │                       │         │
│         ▼                        │           │                       │         │
│  calif86b4c07487                 │           │                  cali*         │
│         │                        │           │                       ▲         │
│         ▼                        │           │                       │         │
│  ┌─────────────────┐             │           │              ┌─────────────┐   │
│  │ Routing Table   │             │           │              │   tunl0     │   │
│  │ 10.8.247.192/26 │             │  Physical │              │             │   │
│  │ via 10.10.20.4  │             │  Network  │              │             │   │
│  └────────┬────────┘             │           │              └─────────────┘   │
│           │                      │           │                                │
│           ▼                      │           │                                │
│  ┌─────────────────┐             │           │                                │
│  │     tunl0       │             │           │                                │
│  │  (IPIP Tunnel)  │             │           │                                │
│  └────────┬────────┘             │           │                                │
│           │                      │           │                                │
│           ▼                      │           │                                │
│  ┌─────────────────┐             │           │              ┌─────────────┐   │
│  │      eth0       │             │ Outer IP: │              │    eth0     │   │
│  │  10.10.20.3     ├─────────────┼─Src:10.10.20.3──────────►│ 10.10.20.4  │   │
│  │                 │             │ Dst:10.10.20.4           │             │   │
│  └─────────────────┘             │ Inner IP:                └─────────────┘   │
│                                  │  Src:10.8.170.65                           │
│                                  │  Dst:10.8.247.196                          │
└──────────────────────────────────┘           └─────────────────────────────────┘

Flow:
1. Pod A sends packet: Src=10.8.170.65, Dst=10.8.247.196
2. Exits Pod A via calif86b4c07487
3. Host routing table matches 10.8.247.192/26 → via 10.10.20.4 (tunl0)
4. Packet is encapsulated with IPIP:
   - Outer IP header: Src=10.10.20.3, Dst=10.10.20.4
   - Inner IP header: Src=10.8.170.65, Dst=10.8.247.196
5. Encapsulated packet sent via eth0 to Worker-1 node
6. Worker-1's tunl0 decapsulates packet
7. Worker-1 routes to local Pod via cali* interface
8. Packet arrives at Pod B
```

## Calico IPAM Block Allocation

From the routing table, we can observe Calico's dynamic IPAM allocation:

```
Node          | IPAM Block       | Observed Pod IPs
------------- | ---------------- | -----------------
k8s-cp1       | 10.8.170.64/26   | .65, .66, .67
k8s-w1        | 10.8.247.192/26  | .196 (observed)
k8s-w2        | 10.8.94.64/26    | .70 (observed)
```

**Key Observations:**

1. **Non-Sequential Allocation**: Blocks are allocated dynamically from anywhere in the 10.8.0.0/16 range, not sequentially
2. **Block Size**: Each block is /26 (62 usable IPs)
3. **Per-Node Blocks**: Each node has at least one block allocated
4. **Dynamic Growth**: Nodes can request additional blocks when current blocks are exhausted

## Network Verification Commands

### View Pod IPs and Nodes
```bash
kubectl get pods -A -o wide | grep -E "10.8.170|10.8.247|10.8.94"
```

### Check Calico IP Pools
```bash
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o yaml
```

### View Calico IPAM Blocks
```bash
kubectl get ipamblocks.crd.projectcalico.org
```

### Check Node IPAM Allocations
```bash
kubectl get ipamblocks.crd.projectcalico.org -o custom-columns=\
NAME:.metadata.name,\
CIDR:.spec.cidr,\
AFFINITY:.spec.affinity
```

## Troubleshooting Tips

### 1. Verify IPIP Tunnel
```bash
# Should see tunl0 interface with a Pod CIDR IP
ip addr show tunl0
```

### 2. Check Route Propagation
```bash
# Should see routes for all nodes' Pod CIDRs
route -n | grep tunl0
```

### 3. Verify Veth Pairs
```bash
# Should match the number of Pods on the node
ip link | grep cali
```

### 4. Test Pod-to-Pod Connectivity
```bash
# From inside a Pod
kubectl exec -it <pod-name> -- ping <another-pod-ip>
```

## Summary

This real-world example demonstrates:

1. **Calico's IPIP Encapsulation**: Using `tunl0` interface for cross-node Pod traffic
2. **Dynamic IPAM**: Non-sequential block allocation from the Pod CIDR range
3. **Veth Pairs**: Direct connectivity for Pods on the same node
4. **Routing Intelligence**: Different paths for local vs. remote Pod traffic
5. **Network Efficiency**: No encapsulation overhead for same-node Pod communication

The configuration shows a healthy Calico network with proper IPAM allocation, routing table entries, and interface configuration for both local and cross-node Pod communication.
