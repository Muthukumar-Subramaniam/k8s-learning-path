# 🌐 kube-proxy – The Service Traffic Director

> **Reference**: [Kubernetes Official Documentation - kube-proxy](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/)

---

## 📋 Table of Contents

1. [What is kube-proxy?](#what-is-kube-proxy)
2. [Core Responsibilities](#core-responsibilities)
3. [How kube-proxy Works](#how-kube-proxy-works)
4. [Proxy Modes](#proxy-modes)
5. [Service Types and kube-proxy](#service-types-and-kube-proxy)
6. [Configuration and Operations](#configuration-and-operations)
7. [Troubleshooting](#troubleshooting)

---

## 🔍 What is kube-proxy?

**kube-proxy** is a **network proxy** that runs on **every node** in a Kubernetes cluster. It's responsible for implementing the Kubernetes Service abstraction by maintaining network rules that allow communication to Pods from inside or outside the cluster.

### The Problem It Solves

Pods in Kubernetes are ephemeral and can be created, destroyed, or moved at any time. Their IP addresses change frequently. Services provide a stable IP address and DNS name, but something needs to:
- Track which Pods are behind each Service
- Route traffic from the Service IP to the actual Pod IPs
- Load balance across multiple Pod replicas
- Handle health checks and remove unhealthy endpoints

**kube-proxy is that "something"** — it watches the Kubernetes API for Service and Endpoint changes and translates them into network rules on each node.

### Key Characteristics

```
┌────────────────────────────────────────────────────────────────┐
│                      Kubernetes Node                            │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                      kube-proxy                          │  │
│  │                    (DaemonSet Pod)                       │  │
│  │                                                          │  │
│  │  1. Watches API Server for Service/Endpoint changes     │  │
│  │  2. Programs node's network rules (iptables/IPVS/eBPF)  │  │
│  │  3. Doesn't proxy traffic itself (except userspace mode)│  │
│  └──────────────────────────────────────────────────────────┘  │
│                            │                                    │
│                            ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │             Linux Kernel Network Stack                   │  │
│  │                                                          │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐        │  │
│  │  │  iptables  │  │    IPVS    │  │    eBPF    │        │  │
│  │  │   rules    │  │   rules    │  │  programs  │        │  │
│  │  └────────────┘  └────────────┘  └────────────┘        │  │
│  │                                                          │  │
│  │         Actual traffic routing happens here              │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            │                                    │
│                            ▼                                    │
│                    ┌────────────────┐                           │
│                    │  Pods          │                           │
│                    │  10.8.0.5:8080 │                           │
│                    └────────────────┘                           │
└────────────────────────────────────────────────────────────────┘
```

> ⚠️ **Important**: Despite its name, kube-proxy is **not a traditional proxy** in most modes. It doesn't sit in the data path. Instead, it programs the kernel to route traffic directly using iptables/IPVS/eBPF.

---

## 🎯 Core Responsibilities

### 1. Service Abstraction Implementation

kube-proxy is the component that makes Services work. It translates the abstract concept of a Service into concrete network rules.

```yaml
# When you create a Service...
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  selector:
    app: web
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  clusterIP: 10.96.100.50
```

**kube-proxy on each node creates rules that:**
```
Traffic to 10.96.100.50:80
    ↓
    Route to one of:
    - 10.8.0.5:8080  (Pod 1)
    - 10.8.0.12:8080 (Pod 2)
    - 10.8.1.8:8080  (Pod 3)
```

### 2. Watch and Sync Loop

kube-proxy maintains a constant watch on the Kubernetes API server:

```
┌─────────────────────────────────────────────────────────────────┐
│                     kube-proxy Watch Loop                        │
│                                                                  │
│  1. Watch API Server                                            │
│     ├── Services (additions/updates/deletions)                  │
│     └── Endpoints/EndpointSlices (Pod IPs backing Services)     │
│                                                                  │
│  2. Detect Changes                                              │
│     ├── New Service created → Add rules                         │
│     ├── Service deleted → Remove rules                          │
│     ├── Endpoint added → Add Pod IP to load balancing           │
│     └── Endpoint removed → Remove Pod IP from load balancing    │
│                                                                  │
│  3. Sync Network Rules                                          │
│     └── Update iptables/IPVS/eBPF rules on local node           │
│                                                                  │
│  4. Repeat (continuous reconciliation)                          │
└─────────────────────────────────────────────────────────────────┘
```

### 3. Load Balancing

kube-proxy distributes traffic across multiple Pod replicas:

| Aspect | Behavior |
|--------|----------|
| **Algorithm** | Random selection by default (iptables mode), configurable in IPVS mode |
| **Session Affinity** | Supports `ClientIP` based session affinity (sticky sessions) |
| **Health Checking** | Uses Endpoint readiness from kubelet health checks |
| **Distribution** | Statistical distribution across backends |

### 4. Key Functions

| Function | Description | Example |
|----------|-------------|---------|
| **ClusterIP Routing** | Routes traffic to Service virtual IPs | Client → 10.96.0.1:80 → Pod |
| **NodePort Handling** | Opens ports on nodes and forwards traffic | External → NodeIP:30080 → Pod |
| **Load Balancer Support** | Handles traffic from LoadBalancer Services | LB → Node → Pod |
| **Endpoint Management** | Tracks healthy Pods backing each Service | Adds/removes Pods from rotation |
| **SNAT/DNAT** | Network address translation for traffic | Preserves source IP (configurable) |

---

## 🔌 How kube-proxy Works

### Traffic Flow Example

Let's trace a request to a Service with ClusterIP `10.96.100.50:80` backed by two Pods:

```
┌────────────────────────────────────────────────────────────────────┐
│  Step 1: Client Pod sends request                                  │
│                                                                     │
│  Client Pod (10.8.0.3)                                             │
│       │                                                             │
│       └─→ Destination: 10.96.100.50:80                             │
└────────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────────┐
│  Step 2: Packet hits node's network stack                          │
│                                                                     │
│  Linux Kernel checks iptables rules (or IPVS)                      │
│       │                                                             │
│       ├─→ Rule Match: 10.96.100.50:80 is a Service                 │
│       │                                                             │
│       └─→ kube-proxy installed rule says:                          │
│           "Route to one of these backends:"                        │
│           • 10.8.0.5:8080 (50% probability)                        │
│           • 10.8.0.12:8080 (50% probability)                       │
└────────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────────┐
│  Step 3: Kernel performs DNAT (Destination NAT)                    │
│                                                                     │
│  Original packet:    10.8.0.3:12345 → 10.96.100.50:80             │
│  Rewritten packet:   10.8.0.3:12345 → 10.8.0.5:8080               │
│                                                                     │
│  (Randomly selected Pod 1)                                         │
└────────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────────┐
│  Step 4: Packet routed to Pod                                      │
│                                                                     │
│  CNI network delivers packet to Pod 1 (10.8.0.5:8080)             │
│                                                                     │
│  Pod processes request and sends response                          │
└────────────────────────────────────────────────────────────────────┘
                              ↓
┌────────────────────────────────────────────────────────────────────┐
│  Step 5: Return traffic uses connection tracking                   │
│                                                                     │
│  Response packet:    10.8.0.5:8080 → 10.8.0.3:12345               │
│  Kernel's conntrack: "This is a reply to our Service request"     │
│  Rewritten response: 10.96.100.50:80 → 10.8.0.3:12345             │
│                                                                     │
│  Client receives response from Service IP (not Pod IP)            │
└────────────────────────────────────────────────────────────────────┘
```

### The Role of Connection Tracking

kube-proxy relies heavily on **conntrack** (connection tracking) in the Linux kernel:

- First packet: Kernel applies kube-proxy's rules, selects a backend Pod, creates conntrack entry
- Subsequent packets: Kernel uses conntrack entry, sends to same Pod (for that connection)
- This ensures all packets in a TCP connection go to the same Pod
- When connection ends, conntrack entry expires

---

## ⚙️ Proxy Modes

kube-proxy supports multiple modes, each with different implementation strategies:

### 1. iptables Mode (Default)

**How it works:**
- Creates iptables rules in the kernel's `nat` and `filter` tables
- Uses `-j DNAT` (Destination NAT) to rewrite Service IPs to Pod IPs
- Random selection of backend Pods (statistically distributed)

**Characteristics:**

| Aspect | Details |
|--------|---------|
| **Performance** | Good for most workloads |
| **Scalability** | Rules increase linearly: O(n) for n services |
| **Load Balancing** | Random selection, statistical distribution |
| **CPU Usage** | Low for rule updates, packet processing in kernel |
| **Compatibility** | Works on all Linux systems |

**Example iptables rules created:**
```bash
# Service ClusterIP rule
-A KUBE-SERVICES -d 10.96.100.50/32 -p tcp -m tcp --dport 80 -j KUBE-SVC-XXXXXXXX

# Load balancing rules (50% probability each)
-A KUBE-SVC-XXXXXXXX -m statistic --mode random --probability 0.5 -j KUBE-SEP-POD1
-A KUBE-SVC-XXXXXXXX -j KUBE-SEP-POD2

# Pod endpoint rules (DNAT)
-A KUBE-SEP-POD1 -p tcp -j DNAT --to-destination 10.8.0.5:8080
-A KUBE-SEP-POD2 -p tcp -j DNAT --to-destination 10.8.0.12:8080
```

**Pros:**
- ✅ Stable and well-tested
- ✅ Works everywhere
- ✅ Low memory overhead
- ✅ Built into kernel

**Cons:**
- ❌ Doesn't scale well beyond ~5,000 Services
- ❌ Rule updates can cause latency spikes
- ❌ No sophisticated load balancing algorithms
- ❌ Difficult to debug (complex iptables chains)

---

### 2. IPVS Mode (High Performance)

**How it works:**
- Uses Linux IPVS (IP Virtual Server) subsystem in the kernel
- Creates IPVS virtual servers and real servers
- Supports multiple load balancing algorithms

**Characteristics:**

| Aspect | Details |
|--------|---------|
| **Performance** | Excellent, uses hash tables internally |
| **Scalability** | Handles 10,000+ Services efficiently: O(1) lookup |
| **Load Balancing** | Multiple algorithms: rr, lc, dh, sh, sed, nq |
| **CPU Usage** | Very low for rule lookups |
| **Compatibility** | Requires IPVS kernel modules |

**Load Balancing Algorithms:**

| Algorithm | Description | Use Case |
|-----------|-------------|----------|
| `rr` (Round Robin) | Distributes connections sequentially | Equal capacity backends |
| `lc` (Least Connection) | Sends to server with fewest connections | Varying request durations |
| `dh` (Destination Hashing) | Hash destination IP | Cache servers |
| `sh` (Source Hashing) | Hash source IP | Session persistence |
| `sed` (Shortest Expected Delay) | Weighted least connection | Weighted backends |
| `nq` (Never Queue) | Improved sed algorithm | Low latency |

**Example IPVS configuration:**
```bash
# View IPVS services
$ ipvsadm -Ln
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.100.50:80 rr
  -> 10.8.0.5:8080                Masq    1      0          0
  -> 10.8.0.12:8080               Masq    1      0          0
```

**Enabling IPVS mode:**
```yaml
# kube-proxy ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
data:
  config.conf: |
    mode: "ipvs"
    ipvs:
      scheduler: "rr"  # Round-robin
      syncPeriod: 30s
```

**Pros:**
- ✅ Excellent performance at scale
- ✅ Rich load balancing algorithms
- ✅ Better observability (ipvsadm tool)
- ✅ Graceful handling of Service updates

**Cons:**
- ❌ Requires IPVS kernel modules
- ❌ Falls back to iptables if IPVS unavailable
- ❌ Still uses some iptables (for NodePort, LoadBalancer)
- ❌ More complex troubleshooting

---

### 3. eBPF Mode (Modern)

**How it works:**
- Uses eBPF (extended Berkeley Packet Filter) programs loaded into the kernel
- Intercepts packets at the network layer before traditional iptables
- Implemented by advanced CNI plugins (Cilium, Calico with eBPF mode)

**Characteristics:**

| Aspect | Details |
|--------|---------|
| **Performance** | Best-in-class, minimal overhead |
| **Scalability** | Excellent, efficient maps and programs |
| **Load Balancing** | Highly efficient with consistent hashing |
| **CPU Usage** | Minimal, XDP (eXpress Data Path) capable |
| **Compatibility** | Requires Linux kernel 4.19+ (5.x+ recommended) |

**Architecture:**
```
┌────────────────────────────────────────────────────────────────┐
│                      Network Packet Flow                        │
│                                                                 │
│  NIC → XDP/eBPF programs → kube-proxy logic in eBPF → Pod     │
│         (kernel space)                                          │
│                                                                 │
│  ✓ No userspace context switches                               │
│  ✓ No iptables rules traversal                                 │
│  ✓ Direct packet manipulation                                  │
└────────────────────────────────────────────────────────────────┘
```

**Pros:**
- ✅ Highest performance
- ✅ Low latency
- ✅ Better observability with BPF maps
- ✅ Programmable and extensible
- ✅ Can replace kube-proxy entirely (Cilium)

**Cons:**
- ❌ Requires modern kernel (4.19+)
- ❌ More complex to implement
- ❌ Debugging requires eBPF knowledge
- ❌ Not a standalone kube-proxy mode (needs CNI support)

---

### 4. userspace Mode (Legacy - Deprecated)

**How it works:**
- kube-proxy runs as actual proxy in userspace
- Packets go: Kernel → kube-proxy → Kernel → Pod

**Characteristics:**
- ⚠️ **Deprecated** - Don't use in production
- Very slow (context switches for every packet)
- Only used for compatibility with very old systems

---

### Mode Comparison

| Feature | iptables | IPVS | eBPF | userspace |
|---------|----------|------|------|-----------|
| **Performance** | Good | Excellent | Best | Poor |
| **Scalability** | ~5K Services | 10K+ Services | 10K+ Services | Poor |
| **Latency** | Low | Very Low | Lowest | High |
| **Load Balancing** | Random | 6 algorithms | Consistent hash | Round-robin |
| **Kernel Requirement** | Any | IPVS modules | 4.19+ | Any |
| **Production Ready** | ✅ Yes | ✅ Yes | ✅ Yes (with Cilium) | ❌ No |
| **Default** | ✅ Yes | No | No | No |

**Choosing a mode:**

```
Small/Medium clusters (< 1000 Services)
└─→ iptables mode (default) ✅

Large clusters (> 1000 Services)
└─→ IPVS mode ✅

High-performance requirements
└─→ eBPF with Cilium ✅

Legacy systems
└─→ userspace mode ⚠️ (avoid if possible)
```

---

## 🔄 Service Types and kube-proxy

### ClusterIP Services

**Default Service type** - Only accessible within the cluster

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
spec:
  type: ClusterIP  # Default, can be omitted
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 8080
```

**kube-proxy behavior:**
- Creates rules for Service's ClusterIP (e.g., 10.96.50.100)
- Routes internal cluster traffic to Pod IPs
- No external accessibility

---

### NodePort Services

**Exposes Service on each node's IP at a static port** (30000-32767 range)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp
spec:
  type: NodePort
  selector:
    app: webapp
  ports:
  - port: 80        # ClusterIP port
    targetPort: 8080  # Pod port
    nodePort: 30080   # Node port (optional, auto-assigned if omitted)
```

**kube-proxy behavior:**
- Creates ClusterIP rules (10.96.x.x)
- **Opens port 30080 on ALL nodes**
- Routes traffic from any Node:30080 → Pod
- Works even if Pod not on that node (routes across nodes)

**Access patterns:**
```bash
# From outside cluster
curl http://any-node-ip:30080

# From inside cluster
curl http://webapp:80              # ClusterIP
curl http://10.96.50.100:80        # Direct ClusterIP
curl http://node-ip:30080          # NodePort
```

---

### LoadBalancer Services

**Cloud-specific** - Provisions external load balancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: public-webapp
spec:
  type: LoadBalancer
  selector:
    app: webapp
  ports:
  - port: 80
    targetPort: 8080
```

**kube-proxy behavior:**
- Creates ClusterIP rules
- Creates NodePort rules (automatically assigned)
- Cloud controller provisions external LB
- External LB forwards to NodePorts

**Traffic flow:**
```
External Client
    ↓
Cloud Load Balancer (34.123.45.67:80)
    ↓
Routes to Node:NodePort (e.g., 10.10.20.4:31234)
    ↓
kube-proxy rules on node
    ↓
Pod (10.8.0.5:8080)
```

---

### ExternalName Services

**DNS-based** - Maps Service to external DNS name

```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-api
spec:
  type: ExternalName
  externalName: api.external-service.com
```

**kube-proxy behavior:**
- **Does NOT create any rules**
- CoreDNS returns CNAME record
- No load balancing or proxying

---

## ⚙️ Configuration and Operations

### Checking kube-proxy Mode

```bash
# Check kube-proxy logs
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep "Using"

# Output examples:
# Using iptables Proxier
# Using ipvs Proxier

# Check kube-proxy ConfigMap
kubectl get configmap kube-proxy -n kube-system -o yaml
```

### Viewing kube-proxy Configuration

```bash
# Get full configuration
kubectl describe configmap kube-proxy -n kube-system

# Key configuration fields:
# - mode: "iptables" | "ipvs" | "userspace"
# - clusterCIDR: Pod network CIDR
# - ipvs.scheduler: Load balancing algorithm (if IPVS mode)
# - iptables.syncPeriod: How often to sync rules
```

### Inspecting Network Rules

**For iptables mode:**
```bash
# View kube-proxy created chains
sudo iptables -t nat -L -n | grep KUBE

# View specific Service rules
sudo iptables -t nat -L KUBE-SERVICES -n

# View Service endpoints
sudo iptables -t nat -L KUBE-SVC-XXXXXXXX -n

# Count total rules
sudo iptables-save | wc -l
```

**For IPVS mode:**
```bash
# Install ipvsadm
sudo apt-get install ipvsadm  # Debian/Ubuntu
sudo yum install ipvsadm      # RHEL/CentOS

# View all IPVS services
sudo ipvsadm -Ln

# View specific service with stats
sudo ipvsadm -Ln --stats

# Monitor connections in real-time
watch -n 1 'sudo ipvsadm -Ln --rate'
```

### Common Configuration Changes

**Switch from iptables to IPVS:**

```bash
# 1. Ensure IPVS kernel modules loaded
sudo modprobe ip_vs
sudo modprobe ip_vs_rr
sudo modprobe ip_vs_wrr
sudo modprobe ip_vs_sh

# 2. Edit kube-proxy ConfigMap
kubectl edit configmap kube-proxy -n kube-system

# Change:
#   mode: ""  or  mode: "iptables"
# To:
#   mode: "ipvs"
#   ipvs:
#     scheduler: "rr"

# 3. Restart kube-proxy pods
kubectl rollout restart daemonset kube-proxy -n kube-system

# 4. Verify
kubectl logs -n kube-system -l k8s-app=kube-proxy | grep "Using ipvs"
```

**Enable session affinity (sticky sessions):**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: sticky-service
spec:
  selector:
    app: backend
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800  # 3 hours
  ports:
  - port: 80
    targetPort: 8080
```

---

## 🔧 Troubleshooting

### Common Issues and Solutions

#### 1. Service Not Reachable

**Symptoms:**
- Cannot connect to Service ClusterIP
- Timeouts or connection refused

**Diagnosis:**
```bash
# 1. Check if Service exists and has endpoints
kubectl get svc my-service
kubectl get endpoints my-service

# No endpoints? Check:
# - Pod selector matches
# - Pods are running and ready
# - Pod ports match Service targetPort

# 2. Check kube-proxy is running
kubectl get pods -n kube-system -l k8s-app=kube-proxy

# 3. Check kube-proxy logs for errors
kubectl logs -n kube-system <kube-proxy-pod>

# 4. Verify network rules exist
# For iptables:
sudo iptables -t nat -L -n | grep <service-clusterip>

# For IPVS:
sudo ipvsadm -Ln | grep <service-clusterip>
```

**Solutions:**
- Ensure Pod labels match Service selector
- Check Pod readiness probes
- Restart kube-proxy if rules missing
- Verify no NetworkPolicy blocking traffic

#### 2. NodePort Not Accessible Externally

**Symptoms:**
- Cannot connect to NodeIP:NodePort from outside cluster
- Connection timeout

**Diagnosis:**
```bash
# 1. Check Service has NodePort assigned
kubectl get svc my-service
# Should show: TYPE=NodePort, PORT(S)=80:30080/TCP

# 2. Verify firewall allows NodePort
sudo iptables -L -n | grep <nodeport>
# Or check cloud provider security groups

# 3. Test from inside cluster first
kubectl run test --rm -it --image=busybox -- sh
wget -O- http://<node-ip>:<nodeport>

# 4. Check if kube-proxy configured nodePortAddresses
kubectl get configmap kube-proxy -n kube-system -o yaml | grep nodePortAddresses
```

**Solutions:**
- Open NodePort in firewall/security groups
- Check `nodePortAddresses` in kube-proxy config
- Verify service type is actually NodePort
- Test connectivity from different network zones

#### 3. Uneven Load Balancing

**Symptoms:**
- Traffic goes mostly to one Pod
- Some Pods receive no traffic

**Diagnosis:**
```bash
# 1. Check if all Pods are endpoints
kubectl get endpoints my-service -o yaml

# 2. For IPVS, check connection distribution
sudo ipvsadm -Ln --stats

# 3. Check if session affinity enabled
kubectl get svc my-service -o yaml | grep sessionAffinity

# 4. Check Pod readiness
kubectl get pods -l app=my-app
```

**Solutions:**
- iptables mode uses statistical distribution (may seem uneven short-term)
- Disable session affinity if not needed
- Use IPVS mode for better algorithms
- Ensure long-lived connections eventually distribute

#### 4. High Latency / Slow Service Response

**Symptoms:**
- Services respond slowly
- Network latency increased

**Diagnosis:**
```bash
# 1. Check conntrack table size
sudo sysctl net.netfilter.nf_conntrack_count
sudo sysctl net.netfilter.nf_conntrack_max

# If count close to max, increase:
sudo sysctl -w net.netfilter.nf_conntrack_max=1000000

# 2. Check for iptables rule explosion
sudo iptables-save | wc -l
# > 10,000 rules? Consider IPVS mode

# 3. Check kube-proxy CPU usage
kubectl top pods -n kube-system -l k8s-app=kube-proxy

# 4. Check for iptables lock contention
dmesg | grep iptables
```

**Solutions:**
- Increase conntrack table size
- Switch to IPVS mode for large clusters
- Reduce service churn (frequent updates)
- Consider eBPF mode (Cilium)

#### 5. Services Break After kube-proxy Restart

**Symptoms:**
- Existing connections drop when kube-proxy restarts
- Brief service outage

**Explanation:**
- Connection tracking is in kernel, not kube-proxy
- **Should NOT break** existing connections
- If connections do break:
  - Check if iptables rules flushed
  - Verify kube-proxy not running in userspace mode
  - Check for custom network policies interfering

**Solutions:**
- iptables/IPVS modes: Connections survive kube-proxy restart
- userspace mode: Don't use (connections WILL break)
- Graceful rolling restart of kube-proxy DaemonSet

---

### Debugging Commands Reference

```bash
# === kube-proxy Status ===
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl logs -n kube-system <kube-proxy-pod> --tail=50

# === Service Investigation ===
kubectl get svc <service-name>
kubectl describe svc <service-name>
kubectl get endpoints <service-name>
kubectl get endpointslices -l kubernetes.io/service-name=<service-name>

# === iptables Mode ===
sudo iptables -t nat -L -n -v | grep <service-name>
sudo iptables -t nat -L KUBE-SERVICES -n --line-numbers
sudo iptables-save | grep <clusterip>

# === IPVS Mode ===
sudo ipvsadm -Ln
sudo ipvsadm -Ln --stats
sudo ipvsadm -Ln --rate
sudo ipvsadm -Ln -t <clusterip>:<port>

# === Connection Tracking ===
sudo conntrack -L | grep <clusterip>
sudo sysctl net.netfilter.nf_conntrack_count
sudo sysctl net.netfilter.nf_conntrack_max

# === Network Testing ===
# Test from Pod
kubectl run test --rm -it --image=nicolaka/netshoot -- bash
curl <service-name>:<port>
curl <clusterip>:<port>

# Test DNS resolution
nslookup <service-name>

# Trace network path
traceroute <clusterip>
```

---

## 📚 Summary

### Key Takeaways

1. **kube-proxy implements Services** - Translates Service abstractions into network rules
2. **Not a real proxy** (iptables/IPVS modes) - Programs kernel to route directly
3. **Runs on every node** - Deployed as DaemonSet
4. **Watches API server** - Constantly syncs Services and Endpoints
5. **Multiple modes available** - Choose based on scale and requirements:
   - **iptables**: Default, good for most clusters
   - **IPVS**: Best for large clusters (1000+ Services)
   - **eBPF**: Highest performance, requires modern setup

### Best Practices

✅ **Use IPVS for large clusters** (> 1000 Services)  
✅ **Monitor conntrack table** size and limits  
✅ **Tune session affinity** only when needed  
✅ **Check kube-proxy logs** during troubleshooting  
✅ **Consider eBPF mode** (Cilium) for new clusters  
✅ **Keep kube-proxy version** aligned with cluster version  
✅ **Test NodePort firewall rules** before exposing services  

### Related Documentation

- [k8s-networking-fundamentals.md](k8s-networking-fundamentals.md) - Comprehensive networking guide
- [pods.md](pods.md) - Understanding Pod networking
- [metallb.md](metallb.md) - LoadBalancer Services on-premises
- [k8s-architecture.md](k8s-architecture.md) - Overall cluster architecture

---

**Next Steps**: Explore [k8s-networking-fundamentals.md](k8s-networking-fundamentals.md) for the complete picture of Kubernetes networking, including CNI plugins, Services, Ingress, and Network Policies.
