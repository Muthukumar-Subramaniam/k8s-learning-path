# 🚀 eBPF (Extended Berkeley Packet Filter)

## 📋 Table of Contents
1. [What is eBPF?](#what-is-ebpf)
2. [How eBPF Works](#how-ebpf-works)
3. [eBPF Architecture](#ebpf-architecture)
4. [eBPF in Kubernetes](#ebpf-in-kubernetes)
5. [eBPF vs Traditional Approaches](#ebpf-vs-traditional-approaches)
6. [Use Cases](#use-cases)

---

## 🔍 What is eBPF?

**eBPF (Extended Berkeley Packet Filter)** is a revolutionary Linux kernel technology that allows running sandboxed programs in the kernel without changing kernel source code or loading kernel modules. It enables developers to safely and efficiently extend kernel functionality.

### Key Characteristics

- **Kernel-level execution**: Programs run in the kernel space for maximum performance
- **Safety**: Verified by the kernel before execution (no crashes, no infinite loops)
- **Performance**: Near-native speed with JIT compilation
- **Versatility**: Can hook into various kernel subsystems
- **Dynamic**: Load and unload programs without rebooting

### Evolution

```
┌──────────────────────────────────────────────────────────────┐
│                  BPF/eBPF Evolution                          │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1992: BPF (Berkeley Packet Filter)                         │
│  └─► Original: Simple packet filtering in tcpdump           │
│      • Limited to network packet filtering                   │
│      • 2 registers, simple instruction set                   │
│                                                              │
│  2014: eBPF (Extended BPF)                                  │
│  └─► Modern: Programmable kernel extension                   │
│      • 11 registers (64-bit)                                 │
│      • Rich instruction set                                  │
│      • Maps for data storage                                 │
│      • Helper functions                                      │
│      • Multiple hook points                                  │
│                                                              │
│  Now: Cloud-Native Standard                                 │
│  └─► Used in: Cilium, Falco, Pixie, Hubble, etc.           │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## ⚙️ How eBPF Works

### Program Lifecycle

```
┌──────────────────────────────────────────────────────────────┐
│               eBPF Program Lifecycle                         │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Write Program                                            │
│  ┌────────────────────────┐                                 │
│  │  eBPF Program (C)      │                                 │
│  │  ├─ Packet processing  │                                 │
│  │  ├─ System calls       │                                 │
│  │  └─ Tracing hooks      │                                 │
│  └────────────┬───────────┘                                 │
│               │                                              │
│               ▼                                              │
│  2. Compile to eBPF Bytecode                                │
│  ┌────────────────────────┐                                 │
│  │  LLVM/Clang            │                                 │
│  │  Compiler              │                                 │
│  └────────────┬───────────┘                                 │
│               │                                              │
│               ▼                                              │
│  3. Load into Kernel                                        │
│  ┌────────────────────────┐                                 │
│  │  bpf() System Call     │                                 │
│  └────────────┬───────────┘                                 │
│               │                                              │
│               ▼                                              │
│  4. Verification                                            │
│  ┌────────────────────────┐                                 │
│  │  eBPF Verifier         │                                 │
│  │  ├─ Safety checks      │                                 │
│  │  ├─ Bounds checking    │                                 │
│  │  ├─ Loop detection     │                                 │
│  │  └─ Memory access      │                                 │
│  └────────────┬───────────┘                                 │
│               │                                              │
│               ▼                                              │
│  5. JIT Compilation                                         │
│  ┌────────────────────────┐                                 │
│  │  Just-In-Time          │                                 │
│  │  Compiler              │                                 │
│  │  (Bytecode→Native)     │                                 │
│  └────────────┬───────────┘                                 │
│               │                                              │
│               ▼                                              │
│  6. Execute                                                 │
│  ┌────────────────────────┐                                 │
│  │  Kernel Space          │                                 │
│  │  Program Execution     │                                 │
│  └────────────────────────┘                                 │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### eBPF Verifier

The verifier ensures safety before execution:

```
┌──────────────────────────────────────────────────────────────┐
│                  eBPF Verifier Checks                        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ✅ Checks Performed:                                        │
│                                                              │
│  1. Control Flow Validation                                 │
│     • No unreachable code                                    │
│     • No infinite loops (bounded loops only)                 │
│     • Program must terminate                                 │
│                                                              │
│  2. Memory Access Safety                                    │
│     • Bounds checking for all memory access                  │
│     • Valid pointer dereferences                             │
│     • No null pointer access                                 │
│                                                              │
│  3. Type Safety                                             │
│     • Correct data types                                     │
│     • Valid register usage                                   │
│     • Proper context access                                  │
│                                                              │
│  4. Size Limits                                             │
│     • Max 1 million instructions (complexity limit)          │
│     • Stack size limit (512 bytes)                           │
│     • Map size restrictions                                  │
│                                                              │
│  ❌ Rejected Programs:                                       │
│     • Unbounded loops                                        │
│     • Out-of-bounds memory access                            │
│     • Unsafe pointer arithmetic                              │
│     • Programs that could crash the kernel                   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 🏗️ eBPF Architecture

### Components

```
┌──────────────────────────────────────────────────────────────┐
│                  eBPF Architecture                           │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                    User Space                                │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                                                        │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │  │
│  │  │  Application │  │  Loader      │  │  Tools     │  │  │
│  │  │  (Cilium)    │  │  (libbpf)    │  │  (bpftool) │  │  │
│  │  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘  │  │
│  │         │                 │                 │         │  │
│  └─────────┼─────────────────┼─────────────────┼─────────┘  │
│            │                 │                 │            │
│ ═══════════╪═════════════════╪═════════════════╪═══════════ │
│            │    bpf() syscall│                 │            │
│            ▼                 ▼                 ▼            │
│                    Kernel Space                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                                                        │  │
│  │  ┌──────────────────────────────────────────────┐     │  │
│  │  │         eBPF Virtual Machine                 │     │  │
│  │  │  ┌────────────┐  ┌──────────┐  ┌─────────┐  │     │  │
│  │  │  │  Verifier  │  │   JIT    │  │  Maps   │  │     │  │
│  │  │  └────────────┘  └──────────┘  └─────────┘  │     │  │
│  │  └──────────────────────────────────────────────┘     │  │
│  │                                                        │  │
│  │  ┌──────────────────────────────────────────────┐     │  │
│  │  │              Hook Points                     │     │  │
│  │  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌──────┐  │     │  │
│  │  │  │Network │ │Tracing │ │Security│ │...   │  │     │  │
│  │  │  │(XDP/TC)│ │(kprobe)│ │(LSM)   │ │      │  │     │  │
│  │  │  └────────┘ └────────┘ └────────┘ └──────┘  │     │  │
│  │  └──────────────────────────────────────────────┘     │  │
│  │                                                        │  │
│  │           ┌──────────────────────────┐                │  │
│  │           │   Linux Kernel           │                │  │
│  │           │   Networking, Storage... │                │  │
│  │           └──────────────────────────┘                │  │
│  │                                                        │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Hook Points

eBPF programs can attach to various kernel subsystems:

| Hook Type | Description | Use Case |
|-----------|-------------|----------|
| **XDP (eXpress Data Path)** | Earliest point in network stack | DDoS protection, load balancing |
| **TC (Traffic Control)** | After XDP, before network stack | Packet filtering, QoS |
| **Socket Operations** | Socket-level operations | Connection tracking, load balancing |
| **kprobes/uprobes** | Kernel/user function tracing | Performance monitoring, debugging |
| **Tracepoints** | Static kernel tracing points | Observability, metrics |
| **LSM (Linux Security Module)** | Security policy enforcement | Access control, security |
| **Cgroups** | Control group operations | Resource management |

### eBPF Maps

Maps are data structures for sharing data between eBPF programs and user space:

```
┌──────────────────────────────────────────────────────────────┐
│                      eBPF Maps                               │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Purpose: Store and share data                              │
│                                                              │
│  Map Types:                                                  │
│  ┌────────────────────────────────────────────────────┐     │
│  │  BPF_MAP_TYPE_HASH         │  Hash table           │     │
│  │  BPF_MAP_TYPE_ARRAY        │  Array (index-based)  │     │
│  │  BPF_MAP_TYPE_LRU_HASH     │  LRU cache            │     │
│  │  BPF_MAP_TYPE_PERCPU_ARRAY │  Per-CPU array        │     │
│  │  BPF_MAP_TYPE_PROG_ARRAY   │  Program array (tail) │     │
│  │  BPF_MAP_TYPE_QUEUE        │  FIFO queue           │     │
│  │  BPF_MAP_TYPE_STACK        │  LIFO stack           │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  Usage:                                                      │
│  • Connection state tracking                                 │
│  • Statistics and metrics                                    │
│  • Configuration data                                        │
│  • Passing data to user space                                │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 🐝 eBPF in Kubernetes

eBPF is transforming Kubernetes networking, observability, and security:

### 1. Cilium (CNI with eBPF)

Cilium uses eBPF for high-performance networking and security:

```
┌──────────────────────────────────────────────────────────────┐
│              Cilium eBPF Architecture                        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Node                                                        │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                                                         │ │
│  │  Pod A                       Pod B                      │ │
│  │  ┌──────────┐               ┌──────────┐               │ │
│  │  │ eth0     │               │ eth0     │               │ │
│  │  └────┬─────┘               └────┬─────┘               │ │
│  │       │                          │                      │ │
│  │  ┌────▼──────────────────────────▼────┐                │ │
│  │  │      eBPF Programs (cilium)        │                │ │
│  │  │  ┌──────────────────────────────┐  │                │ │
│  │  │  │  XDP/TC hooks                │  │                │ │
│  │  │  │  • Packet forwarding         │  │                │ │
│  │  │  │  • Load balancing            │  │                │ │
│  │  │  │  • Network policy            │  │                │ │
│  │  │  │  • Observability             │  │                │ │
│  │  │  └──────────────────────────────┘  │                │ │
│  │  └─────────────────┬──────────────────┘                │ │
│  │                    │                                    │ │
│  │  ┌─────────────────▼──────────────────┐                │ │
│  │  │  eBPF Maps                         │                │ │
│  │  │  • Connection tracking             │                │ │
│  │  │  • Service endpoints               │                │ │
│  │  │  • Policy rules                    │                │ │
│  │  │  • Statistics                      │                │ │
│  │  └────────────────────────────────────┘                │ │
│  │                                                         │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Benefits**:
- **Performance**: Direct packet processing in kernel, no iptables overhead
- **Scalability**: Efficient connection tracking with eBPF maps
- **Observability**: Deep visibility with Hubble (eBPF-based)
- **Security**: L7-aware network policies

**How it works**:
1. eBPF programs attach to network interfaces (XDP/TC)
2. Packets processed directly in kernel space
3. Policy decisions made at kernel level
4. Statistics collected in eBPF maps
5. User-space agent (Cilium) manages eBPF programs

See [cni.md](cni.md#cilium) for detailed Cilium configuration.

### 2. kube-proxy eBPF Mode

Modern alternative to iptables/IPVS for service routing:

```
┌──────────────────────────────────────────────────────────────┐
│          kube-proxy: iptables vs eBPF Mode                   │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Traditional (iptables):                                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Packet → Netfilter → iptables rules (1000s)           │ │
│  │         → NAT → DNAT → Backend Pod                      │ │
│  │                                                         │ │
│  │  Issues:                                                │ │
│  │  • O(n) rule traversal                                  │ │
│  │  • Performance degrades with scale                      │ │
│  │  • Connection tracking overhead                         │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Modern (eBPF):                                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Packet → XDP/TC eBPF → Map lookup (O(1))              │ │
│  │         → Load balance → Backend Pod                    │ │
│  │                                                         │ │
│  │  Benefits:                                              │ │
│  │  • O(1) lookup in maps                                  │ │
│  │  • Consistent performance at scale                      │ │
│  │  • Lower CPU usage                                      │ │
│  │  • Better latency                                       │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Performance comparison**:
- **Latency**: 30-40% lower with eBPF
- **CPU usage**: 50-60% reduction
- **Throughput**: 2-3x improvement
- **Scale**: Handles 10,000+ services efficiently

See [kube-proxy.md](kube-proxy.md) for kube-proxy modes.

### 3. eBPF-based Observability

Tools like Hubble (Cilium) and Pixie use eBPF for deep observability:

```
┌──────────────────────────────────────────────────────────────┐
│              eBPF Observability Stack                        │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  What eBPF Can Observe:                                      │
│                                                              │
│  Network Layer:                                              │
│  • Every packet (source, dest, protocol)                     │
│  • TCP handshakes, retransmits                               │
│  • DNS queries and responses                                 │
│  • HTTP requests/responses (L7)                              │
│  • TLS handshakes                                            │
│                                                              │
│  Application Layer:                                          │
│  • Function calls and returns                                │
│  • System calls                                              │
│  • File operations                                           │
│  • Database queries                                          │
│                                                              │
│  Without:                                                    │
│  • Changing application code                                 │
│  • Installing agents in containers                           │
│  • Adding sidecars                                           │
│  • Significant overhead                                      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 4. eBPF for Security

Security tools use eBPF for runtime protection:

- **Falco**: Runtime security using eBPF syscall monitoring
- **Tetragon**: eBPF-based security observability and enforcement
- **Tracee**: Runtime security and forensics

---

## 🔄 eBPF vs Traditional Approaches

### Networking

| Aspect | iptables | eBPF |
|--------|----------|------|
| **Performance** | O(n) rule traversal | O(1) map lookup |
| **Scalability** | Degrades with rules | Constant performance |
| **Latency** | Higher | 30-40% lower |
| **CPU Usage** | High | 50-60% lower |
| **Flexibility** | Rule-based | Programmable logic |
| **Kernel Changes** | Netfilter hooks | Dynamic programs |

### Packet Processing Path

```
┌──────────────────────────────────────────────────────────────┐
│            Packet Processing: iptables vs eBPF               │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  iptables:                                                   │
│  ┌─────┐  ┌────────┐  ┌─────────┐  ┌──────┐  ┌──────┐     │
│  │ NIC │→│ Driver │→│ Netfilter│→│ iptbl│→│ App  │     │
│  └─────┘  └────────┘  └─────────┘  └──────┘  └──────┘     │
│                                                              │
│  eBPF/XDP:                                                   │
│  ┌─────┐  ┌────────┐  ┌──────┐  ┌──────┐                   │
│  │ NIC │→│ eBPF   │→│ Stack│→│ App  │                   │
│  └─────┘  │ (XDP)  │  └──────┘  └──────┘                   │
│            └────────┘                                        │
│            ↑ Earliest packet processing point                │
│                                                              │
│  XDP can:                                                    │
│  • Drop packets (DDoS mitigation)                            │
│  • Redirect to other interfaces                              │
│  • Modify packets                                            │
│  • Pass to stack                                             │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Service Mesh

| Feature | Sidecar (Envoy) | eBPF (Cilium) |
|---------|-----------------|---------------|
| **Resource Usage** | High (sidecar per pod) | Low (kernel-level) |
| **Latency** | Added hop | Minimal |
| **Complexity** | Higher | Lower |
| **L7 Features** | Rich | Growing |
| **Adoption** | Mature | Emerging |

---

## 💡 Use Cases

### Kubernetes-Specific

1. **High-Performance Networking**
   - Cilium CNI for pod networking
   - Service load balancing without iptables
   - Direct routing with minimal overhead

2. **Network Security**
   - L3/L4/L7 network policies
   - Identity-based security
   - Real-time threat detection

3. **Observability**
   - Service mesh observability (Hubble)
   - Application performance monitoring
   - Network flow visualization

4. **Service Mesh**
   - Sidecar-less service mesh
   - Protocol-aware load balancing
   - Traffic encryption (WireGuard)

### General Use Cases

1. **DDoS Protection**: XDP-based packet filtering
2. **Load Balancing**: Kernel-level load balancing (Katran by Facebook)
3. **Monitoring**: System-wide observability without overhead
4. **Security**: Runtime security monitoring and enforcement

---

## 🛠️ Working with eBPF

### Development Tools

```bash
# bpftool - Inspect and manage eBPF programs
bpftool prog list           # List loaded programs
bpftool map list            # List eBPF maps
bpftool prog dump xlated id 123  # Dump program

# bpftrace - High-level tracing language
bpftrace -e 'tracepoint:syscalls:sys_enter_open { @[comm] = count(); }'

# cilium - Manage Cilium eBPF programs
cilium bpf lb list          # List load balancer entries
cilium bpf ct list global   # Connection tracking
cilium monitor              # Real-time event monitoring
```

### Example: Simple eBPF Program

```c
// Simple packet counter
#include <linux/bpf.h>
#include <linux/if_ether.h>

SEC("xdp")
int packet_counter(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    // Bounds checking (required by verifier)
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    
    // Increment counter in map (not shown)
    // ... map operations ...
    
    return XDP_PASS;  // Pass packet to network stack
}
```

---

## 📊 eBPF Adoption in Kubernetes

```
┌──────────────────────────────────────────────────────────────┐
│           eBPF Adoption in Cloud Native Ecosystem            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Production-Ready:                                           │
│  ✅ Cilium (CNI)                                             │
│  ✅ Falco (Security)                                         │
│  ✅ Pixie (Observability)                                    │
│  ✅ Katran (Load Balancer)                                   │
│  ✅ Hubble (Network Observability)                           │
│                                                              │
│  Major Adopters:                                             │
│  • Google (GKE with Cilium)                                  │
│  • AWS (EKS with Cilium option)                              │
│  • Azure (AKS with Cilium)                                   │
│  • Meta/Facebook (Katran)                                    │
│  • Netflix (Production observability)                        │
│  • Capital One (Security)                                    │
│                                                              │
│  Kernel Requirements:                                        │
│  • Minimum: Linux 4.8+                                       │
│  • Recommended: Linux 5.10+ (full feature set)               │
│  • Most cloud providers: Support eBPF out-of-box             │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 🎯 Why eBPF Matters for Kubernetes

1. **Performance**: Native kernel-level processing with minimal overhead
2. **Efficiency**: Reduced CPU and memory usage compared to traditional approaches
3. **Scalability**: Constant-time operations (O(1)) regardless of cluster size
4. **Observability**: Deep visibility without changing applications
5. **Security**: Runtime protection with minimal performance impact
6. **Future-Proof**: Modern approach adopted by major cloud providers

eBPF represents the future of cloud-native infrastructure, providing the performance, efficiency, and capabilities needed for modern Kubernetes deployments.

---

## 📚 Additional Resources

- [eBPF.io](https://ebpf.io) - Official eBPF portal
- [Cilium Documentation](https://docs.cilium.io)
- [BPF and XDP Reference Guide](https://docs.cilium.io/en/stable/bpf/)
- [Linux Kernel BPF Documentation](https://www.kernel.org/doc/html/latest/bpf/)
- [eBPF Summit](https://ebpf.io/summit/) - Annual conference

---

## 🔗 Related Topics

- [Container Network Interface (CNI)](cni.md)
- [kube-proxy](kube-proxy.md)
- [Linux Networking](linux-networking.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
