# 🔧 Linux Networking (iptables & IPVS)

## 📋 Table of Contents
1. [Overview](#overview)
2. [Netfilter Framework](#netfilter-framework)
3. [iptables](#iptables)
4. [IPVS (IP Virtual Server)](#ipvs-ip-virtual-server)
5. [iptables vs IPVS](#iptables-vs-ipvs)
6. [In Kubernetes (kube-proxy)](#in-kubernetes-kube-proxy)
7. [nftables (Modern Alternative)](#nftables-modern-alternative)

---

## 🔍 Overview

Linux provides several kernel-level technologies for packet filtering, forwarding, and load balancing. The two most important for Kubernetes are **iptables** and **IPVS**.

```
┌──────────────────────────────────────────────────────────────┐
│          Linux Network Packet Processing Stack               │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                  Application Layer                           │
│  ┌──────────────────────────────────────────────────────┐   │
│  │        User Space Applications                       │   │
│  └────────────────────┬─────────────────────────────────┘   │
│                       │                                      │
│ ══════════════════════╪═══════════════════════════════════  │
│                       │ (syscalls)                           │
│                  Kernel Space                                │
│  ┌────────────────────▼─────────────────────────────────┐   │
│  │          Network Stack (TCP/IP)                      │   │
│  └────────────────────┬─────────────────────────────────┘   │
│                       │                                      │
│  ┌────────────────────▼─────────────────────────────────┐   │
│  │          Netfilter Hooks                             │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────┐   │   │
│  │  │  iptables   │  │    IPVS     │  │   nftables │   │   │
│  │  └─────────────┘  └─────────────┘  └────────────┘   │   │
│  └────────────────────┬─────────────────────────────────┘   │
│                       │                                      │
│  ┌────────────────────▼─────────────────────────────────┐   │
│  │          Network Drivers                             │   │
│  └────────────────────┬─────────────────────────────────┘   │
│                       │                                      │
│  ┌────────────────────▼─────────────────────────────────┐   │
│  │          Network Interface Card (NIC)                │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 🌐 Netfilter Framework

**Netfilter** is the packet filtering framework built into the Linux kernel. It provides hooks at various points in the network stack where packet processing can occur.

### Netfilter Hook Points

```
┌──────────────────────────────────────────────────────────────┐
│                  Netfilter Packet Flow                       │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                  Incoming Packet                             │
│                       │                                      │
│                       ▼                                      │
│              ┌────────────────┐                              │
│              │  PREROUTING    │ ◄─── Hook 1                  │
│              │  (DNAT, mark)  │                              │
│              └────────┬───────┘                              │
│                       │                                      │
│                  Routing                                     │
│                  Decision                                    │
│                       │                                      │
│            ┌──────────┴──────────┐                           │
│            │                     │                           │
│      For local?              Forward?                        │
│            │                     │                           │
│            ▼                     ▼                           │
│    ┌───────────────┐    ┌───────────────┐                   │
│    │   INPUT       │    │   FORWARD     │ ◄─── Hook 3       │
│    │   (filter)    │    │   (filter)    │                   │
│    └───────┬───────┘    └───────┬───────┘                   │
│            │                     │                           │
│            ▼                     ▼                           │
│    ┌───────────────┐    ┌───────────────┐                   │
│    │  Local        │    │  POSTROUTING  │ ◄─── Hook 4       │
│    │  Process      │    │  (SNAT, mark) │                   │
│    └───────┬───────┘    └───────┬───────┘                   │
│            │                     │                           │
│            ▼                     │                           │
│    ┌───────────────┐             │                           │
│    │   OUTPUT      │ ◄─── Hook 2 │                           │
│    │   (filter)    │             │                           │
│    └───────┬───────┘             │                           │
│            │                     │                           │
│            ▼                     │                           │
│    ┌───────────────┐             │                           │
│    │  POSTROUTING  │◄────────────┘                           │
│    │  (SNAT, mark) │                                         │
│    └───────┬───────┘                                         │
│            │                                                 │
│            ▼                                                 │
│     Outgoing Packet                                          │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Hook Points Explained

| Hook | When | Common Use |
|------|------|-----------|
| **PREROUTING** | Before routing decision | DNAT, port forwarding |
| **INPUT** | Packet destined for local system | Firewall, filtering |
| **FORWARD** | Packet being routed through system | Router firewall |
| **OUTPUT** | Packet leaving local system | Outbound filtering |
| **POSTROUTING** | After routing decision | SNAT, masquerading |

---

## 🔥 iptables

**iptables** is a user-space utility for configuring netfilter rules. It allows system administrators to set up, maintain, and inspect the tables of IP packet filter rules.

### iptables Tables

iptables organizes rules into different tables:

```
┌──────────────────────────────────────────────────────────────┐
│                     iptables Tables                          │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1. filter (Default)                                         │
│     Purpose: Packet filtering (allow/drop)                   │
│     Chains: INPUT, FORWARD, OUTPUT                           │
│     Use: Firewalls, access control                           │
│                                                              │
│  2. nat                                                      │
│     Purpose: Network Address Translation                     │
│     Chains: PREROUTING, OUTPUT, POSTROUTING                  │
│     Use: Port forwarding, masquerading, DNAT/SNAT            │
│                                                              │
│  3. mangle                                                   │
│     Purpose: Packet alteration (TTL, TOS, mark)              │
│     Chains: All five hooks                                   │
│     Use: QoS, advanced routing                               │
│                                                              │
│  4. raw                                                      │
│     Purpose: Bypass connection tracking                      │
│     Chains: PREROUTING, OUTPUT                               │
│     Use: Performance optimization                            │
│                                                              │
│  5. security                                                 │
│     Purpose: SELinux packet marking                          │
│     Chains: INPUT, FORWARD, OUTPUT                           │
│     Use: Mandatory Access Control                            │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### iptables Rule Structure

```
┌──────────────────────────────────────────────────────────────┐
│                   iptables Rule Anatomy                      │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  iptables -t TABLE -A CHAIN [match] -j TARGET               │
│           │      │   │      │         │  │                   │
│           │      │   │      │         │  └─ Action          │
│           │      │   │      │         └─ Jump to            │
│           │      │   │      └─ Match criteria               │
│           │      │   └─ Chain name                           │
│           │      └─ Append rule                              │
│           └─ Table name                                      │
│                                                              │
│  Example:                                                    │
│  iptables -t nat -A PREROUTING \                             │
│           -p tcp --dport 80 \                                │
│           -j DNAT --to-destination 10.244.1.5:8080           │
│                                                              │
│  Explanation:                                                │
│  • Table: nat                                                │
│  • Chain: PREROUTING                                         │
│  • Match: TCP traffic on port 80                             │
│  • Action: DNAT to 10.244.1.5:8080                           │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Common iptables Operations

```bash
# List all rules
iptables -L -n -v
iptables -t nat -L -n -v

# Add rule to allow SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Add DNAT rule (port forwarding)
iptables -t nat -A PREROUTING -p tcp --dport 80 \
  -j DNAT --to-destination 192.168.1.100:8080

# Add SNAT rule (masquerading)
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Delete rule by number
iptables -D INPUT 3

# Flush all rules
iptables -F
iptables -t nat -F

# Save rules (Debian/Ubuntu)
iptables-save > /etc/iptables/rules.v4

# Restore rules
iptables-restore < /etc/iptables/rules.v4
```

### iptables in Kubernetes

kube-proxy uses iptables to implement Services:

```
┌──────────────────────────────────────────────────────────────┐
│          kube-proxy iptables Mode                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Service: nginx (ClusterIP 10.96.10.100:80)                  │
│  Backends: 10.244.1.5:80, 10.244.2.8:80                      │
│                                                              │
│  iptables Rules Created:                                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  1. KUBE-SERVICES chain (entry point)                 │ │
│  │     Match: dst=10.96.10.100, dport=80                 │ │
│  │     Jump: KUBE-SVC-NGINX                              │ │
│  │                                                        │ │
│  │  2. KUBE-SVC-NGINX (service chain)                    │ │
│  │     50% probability → KUBE-SEP-1                      │ │
│  │     50% probability → KUBE-SEP-2                      │ │
│  │                                                        │ │
│  │  3. KUBE-SEP-1 (service endpoint 1)                   │ │
│  │     DNAT → 10.244.1.5:80                              │ │
│  │                                                        │ │
│  │  4. KUBE-SEP-2 (service endpoint 2)                   │ │
│  │     DNAT → 10.244.2.8:80                              │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Traffic Flow:                                               │
│  Pod → 10.96.10.100:80                                       │
│     → PREROUTING → KUBE-SERVICES                             │
│     → KUBE-SVC-NGINX → (random)                              │
│     → KUBE-SEP-1 or KUBE-SEP-2                               │
│     → DNAT to backend Pod                                    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Performance Characteristics**:
- **Rule Count**: O(n) - grows linearly with services
- **Lookup**: O(n) - sequential rule traversal
- **Updates**: Entire chain rewrite on changes
- **Scalability**: Performance degrades with 1000+ services

See [kube-proxy.md](kube-proxy.md) for detailed kube-proxy modes.

---

## ⚖️ IPVS (IP Virtual Server)

**IPVS** is a transport-layer load balancer built into the Linux kernel. It's part of the Linux Virtual Server (LVS) project and provides much better performance than iptables for load balancing.

### IPVS Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                  IPVS Architecture                           │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                 Client Request                               │
│                       │                                      │
│                       ▼                                      │
│              ┌─────────────────┐                             │
│              │  Virtual IP     │                             │
│              │  10.96.10.100:80│                             │
│              └────────┬────────┘                             │
│                       │                                      │
│                       ▼                                      │
│              ┌─────────────────┐                             │
│              │   IPVS          │                             │
│              │   Scheduler     │                             │
│              │   (Hash Table)  │                             │
│              └────────┬────────┘                             │
│                       │                                      │
│              ┌────────┴────────┐                             │
│              │                 │                             │
│              ▼                 ▼                             │
│       ┌────────────┐    ┌────────────┐                      │
│       │ Real Server│    │ Real Server│                      │
│       │ 10.244.1.5 │    │ 10.244.2.8 │                      │
│       └────────────┘    └────────────┘                      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### IPVS Scheduling Algorithms

| Algorithm | Description | Use Case |
|-----------|-------------|----------|
| **rr** | Round Robin | Equal weight servers |
| **lc** | Least Connection | Connection-oriented protocols |
| **wrr** | Weighted Round Robin | Servers with different capacity |
| **wlc** | Weighted Least Connection | Best general purpose |
| **sh** | Source Hashing | Session affinity |
| **dh** | Destination Hashing | Cache clusters |
| **sed** | Shortest Expected Delay | Minimize latency |
| **nq** | Never Queue | High throughput |

### IPVS Commands

```bash
# Install ipvsadm
apt-get install ipvsadm  # Debian/Ubuntu
yum install ipvsadm      # RHEL/CentOS

# List virtual services
ipvsadm -Ln

# Example output:
# IP Virtual Server version 1.2.1
# Prot LocalAddress:Port Scheduler Flags
#   -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
# TCP  10.96.10.100:80 rr
#   -> 10.244.1.5:80                Masq    1      0          0
#   -> 10.244.2.8:80                Masq    1      0          0

# Add virtual service
ipvsadm -A -t 10.96.10.100:80 -s rr

# Add real server
ipvsadm -a -t 10.96.10.100:80 -r 10.244.1.5:80 -m

# Delete virtual service
ipvsadm -D -t 10.96.10.100:80

# Clear all rules
ipvsadm -C

# Show connection table
ipvsadm -Lnc

# Show statistics
ipvsadm -Ln --stats
```

### IPVS in Kubernetes

```
┌──────────────────────────────────────────────────────────────┐
│            kube-proxy IPVS Mode                              │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Service: nginx (ClusterIP 10.96.10.100:80)                  │
│  Backends: 10.244.1.5:80, 10.244.2.8:80                      │
│                                                              │
│  IPVS Configuration:                                         │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Virtual Service:                                      │ │
│  │  • IP: 10.96.10.100:80                                 │ │
│  │  • Scheduler: rr (round-robin)                         │ │
│  │  • Mode: NAT (masquerade)                              │ │
│  │                                                        │ │
│  │  Real Servers:                                         │ │
│  │  • 10.244.1.5:80 (weight: 1)                           │ │
│  │  • 10.244.2.8:80 (weight: 1)                           │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Traffic Flow:                                               │
│  Pod → 10.96.10.100:80                                       │
│     → IPVS hash table lookup (O(1))                          │
│     → Load balancing algorithm (rr)                          │
│     → DNAT to selected backend                               │
│                                                              │
│  Benefits:                                                   │
│  ✅ O(1) lookup time (hash table)                            │
│  ✅ Scales to 10,000+ services                               │
│  ✅ More load balancing algorithms                           │
│  ✅ Better connection handling                               │
│  ✅ Lower CPU usage                                          │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Performance Characteristics**:
- **Rule Count**: O(1) - hash table, constant time
- **Lookup**: O(1) - direct hash table lookup
- **Updates**: Individual entry updates (not full rewrite)
- **Scalability**: Handles 10,000+ services efficiently

---

## 🔄 iptables vs IPVS

### Detailed Comparison

```
┌──────────────────────────────────────────────────────────────┐
│              iptables vs IPVS Comparison                     │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Performance:                                                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                         iptables    IPVS               │ │
│  │  Rule lookup:           O(n)        O(1)               │ │
│  │  CPU usage (1000 svc):  High        Low                │ │
│  │  Latency:               Higher      Lower              │ │
│  │  Throughput:            Lower       Higher             │ │
│  │  Memory:                High        Moderate           │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Scalability:                                                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Service Count     iptables Impact   IPVS Impact       │ │
│  │  100 services      OK                Excellent         │ │
│  │  1,000 services    Degraded          Good              │ │
│  │  5,000 services    Poor              Good              │ │
│  │  10,000+ services  Critical          Acceptable        │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Features:                                                   │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Feature              iptables        IPVS             │ │
│  │  Load balancing       Probability     8+ algorithms    │ │
│  │  Session affinity     Yes             Yes              │ │
│  │  Health checks        Via kube-proxy  Via kube-proxy   │ │
│  │  Connection tracking  Linux conntrack IPVS native      │ │
│  │  Flexibility          Very high       Moderate         │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### When to Use Each

```
┌──────────────────────────────────────────────────────────────┐
│                  Use Case Recommendations                    │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Use iptables when:                                          │
│  ✅ Small cluster (< 100 services)                           │
│  ✅ Need maximum flexibility                                 │
│  ✅ Default choice for most setups                           │
│  ✅ Kernel < 4.19 (better iptables support)                  │
│                                                              │
│  Use IPVS when:                                              │
│  ✅ Large cluster (1000+ services)                           │
│  ✅ Performance is critical                                  │
│  ✅ Need advanced load balancing algorithms                  │
│  ✅ High connection rate workloads                           │
│  ✅ Kernel 4.19+ with IPVS modules                           │
│                                                              │
│  Use eBPF when:                                              │
│  ✅ Need best performance                                    │
│  ✅ Modern kernel (5.10+)                                    │
│  ✅ Using Cilium or similar                                  │
│  ✅ Want sidecar-less service mesh                           │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

See [ebpf.md](ebpf.md) for modern eBPF-based alternatives.

---

## 🐝 In Kubernetes (kube-proxy)

kube-proxy can use iptables, IPVS, or [eBPF](ebpf.md) modes:

### Mode Configuration

```yaml
# kube-proxy ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
data:
  config.conf: |
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    mode: "ipvs"              # or "iptables", "ebpf"
    ipvs:
      scheduler: "rr"         # Round-robin
      syncPeriod: 30s
      minSyncPeriod: 5s
```

### Checking Current Mode

```bash
# Check kube-proxy mode
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep "Using"

# For iptables mode, check rules
iptables -t nat -L KUBE-SERVICES -n

# For IPVS mode, check virtual services
ipvsadm -Ln

# Check which mode is running
ps aux | grep kube-proxy
```

### Switching Modes

```bash
# Edit kube-proxy ConfigMap
kubectl edit cm kube-proxy -n kube-system

# Restart kube-proxy pods
kubectl rollout restart ds/kube-proxy -n kube-system

# Verify new mode
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep "Using"
```

For comprehensive kube-proxy documentation, see [kube-proxy.md](kube-proxy.md).

---

## 🚀 nftables (Modern Alternative)

**nftables** is the modern replacement for iptables, combining functionality of iptables, ip6tables, arptables, and ebtables.

### Key Improvements

```
┌──────────────────────────────────────────────────────────────┐
│              nftables vs iptables                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Architecture:                                               │
│  • Single kernel subsystem (not separate for IPv4/IPv6)      │
│  • Better performance (bytecode in kernel)                   │
│  • Simpler syntax                                            │
│                                                              │
│  Performance:                                                │
│  • Faster rule updates                                       │
│  • Better for large rulesets                                 │
│  • Lower memory usage                                        │
│                                                              │
│  Features:                                                   │
│  • Native IPv4 and IPv6                                      │
│  • Set operations (more efficient)                           │
│  • Verdict maps                                              │
│  • Better scripting support                                  │
│                                                              │
│  Kubernetes:                                                 │
│  • Not yet widely adopted                                    │
│  • Some CNIs exploring support                               │
│  • Future direction for packet filtering                     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Basic nftables Example

```bash
# List rules
nft list ruleset

# Add table
nft add table ip filter

# Add chain
nft add chain ip filter input { type filter hook input priority 0 \; }

# Add rule
nft add rule ip filter input tcp dport 22 accept

# Flush rules
nft flush ruleset
```

---

## 🛠️ Troubleshooting

### Common Commands

```bash
# iptables debugging
# List all rules with packet counts
iptables -t nat -L -n -v
iptables -t filter -L -n -v

# Trace packet path
iptables -t raw -A PREROUTING -p tcp --dport 80 -j TRACE
iptables -t raw -A OUTPUT -p tcp --sport 80 -j TRACE

# View trace logs
tail -f /var/log/kern.log | grep TRACE

# Connection tracking
conntrack -L
conntrack -L -p tcp --state ESTABLISHED

# IPVS debugging
# List services with statistics
ipvsadm -Ln --stats

# Show connection table
ipvsadm -Lnc

# Monitor IPVS
watch -n 1 'ipvsadm -Ln --stats'

# Check IPVS modules
lsmod | grep ip_vs
```

### Performance Monitoring

```bash
# iptables performance
# Count rules
iptables -L -n | wc -l
iptables -t nat -L -n | wc -l

# Benchmark rule lookup (estimated)
time iptables -C INPUT -p tcp --dport 22 -j ACCEPT

# IPVS performance
# Connection statistics
ipvsadm -Ln --rate

# Per-service statistics
ipvsadm -Ln --stats | grep <service-ip>
```

---

## 📚 Additional Resources

- [Netfilter Documentation](https://netfilter.org/documentation/)
- [iptables Tutorial](https://www.frozentux.net/iptables-tutorial/)
- [IPVS Documentation](http://www.linuxvirtualserver.org/software/ipvs.html)
- [nftables Wiki](https://wiki.nftables.org/)
- [kube-proxy Documentation](kube-proxy.md)

---

## 🔗 Related Topics

- [kube-proxy](kube-proxy.md)
- [eBPF (Modern Alternative)](ebpf.md)
- [NAT (Network Address Translation)](nat.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
