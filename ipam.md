# 🔢 IPAM - IP Address Management in Kubernetes

> **IPAM (IP Address Management)** is the system responsible for allocating, tracking, and managing IP addresses for Pods in a Kubernetes cluster.

---

## 📋 Table of Contents

1. [What is IPAM?](#what-is-ipam)
2. [Why IPAM Matters](#why-ipam-matters)
3. [IPAM in Kubernetes](#ipam-in-kubernetes)
4. [CNI Plugin IPAM Behaviors](#cni-plugin-ipam-behaviors)
5. [Comparison Table](#comparison-table)
6. [Practical Examples](#practical-examples)

---

## 🤔 What is IPAM?

**IPAM = IP Address Management**

IPAM is the system that handles:

1. **IP Allocation** - Assigns unique IP addresses to Pods
2. **IP Tracking** - Maintains a database of used and available IPs
3. **Conflict Prevention** - Ensures no two Pods get the same IP
4. **Pool Management** - Organizes IP address space into manageable blocks
5. **IP Reclamation** - Releases IPs when Pods are deleted

### Simple Analogy

Think of a Pod network CIDR like `10.8.0.0/16` as a **parking lot with 65,536 parking spaces**:
- **IPAM** is the parking attendant system
- **Pods** are cars that need parking spots
- Each Pod gets a **unique spot (IP address)**
- When a Pod leaves, the spot becomes **available again**

---

## 💡 Why IPAM Matters

### Without IPAM (Chaos):
- ❌ Two Pods could get the same IP → Network conflicts
- ❌ No way to know which IPs are used
- ❌ Wasted IP addresses
- ❌ Manual intervention required

### With IPAM (Organized):
- ✅ Automatic IP assignment
- ✅ No conflicts
- ✅ Efficient IP space utilization
- ✅ Self-healing when Pods restart

---

## 🔧 IPAM in Kubernetes

Kubernetes has **two approaches** to IPAM, depending on the CNI plugin:

### 1. Kubernetes-Managed IPAM

**How it works:**
- Kubernetes controller-manager acts as the IPAM system
- When a node joins the cluster, K8s assigns it a `podCIDR` from the `--pod-network-cidr`
- This allocation is stored in `node.spec.podCIDR`
- CNI plugin reads this `podCIDR` and assigns Pod IPs from it

**CNI plugins that use this:**
- Flannel
- kube-router
- Azure CNI (in some modes)

```yaml
# Node object shows Kubernetes-assigned Pod CIDR
apiVersion: v1
kind: Node
metadata:
  name: worker-1
spec:
  podCIDR: 10.8.0.0/24      # Assigned by K8s controller-manager
  podCIDRs:
  - 10.8.0.0/24
```

### 2. CNI-Managed IPAM

**How it works:**
- CNI plugin has its own IPAM system
- **Ignores** `node.spec.podCIDR` completely
- Uses custom resources or its own datastore
- Allocates IP blocks dynamically as needed

**CNI plugins that use this:**
- Calico (uses IPPools and IPAM blocks)
- Cilium (uses CiliumNode resources)
- Weave

```yaml
# Calico IPPool defines available IP ranges
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: 10.8.0.0/16          # Total available range
  blockSize: 26              # Allocate /26 blocks (62 IPs)
  ipipMode: Always
  natOutgoing: true
```

---

## 🌐 CNI Plugin IPAM Behaviors

### Flannel IPAM

**Allocation Strategy: Sequential and Predictable**

```
Pod Network CIDR: 10.8.0.0/16

Node 1 → 10.8.0.0/24   (IPs: 10.8.0.1 - 10.8.0.254)
Node 2 → 10.8.1.0/24   (IPs: 10.8.1.1 - 10.8.1.254)
Node 3 → 10.8.2.0/24   (IPs: 10.8.2.1 - 10.8.2.254)
...sequential allocation...
```

**Characteristics:**
- ✅ **Predictable** - Easy to understand which node owns which IPs
- ✅ **Simple** - Straightforward allocation
- ⚠️ **Fixed size** - Each node gets one fixed `/24` block (254 IPs)
- ⚠️ **No flexibility** - Can't allocate more IPs to a busy node
- ⚠️ **Wastes IPs** - Unused IPs on underutilized nodes can't be used elsewhere

**IPAM Flow:**
1. Node joins cluster → Kubernetes assigns `podCIDR` from `--pod-network-cidr`
2. Flannel reads `node.spec.podCIDR`
3. When Pod is scheduled → Flannel assigns next available IP from that node's CIDR
4. Pod deleted → IP is freed and returned to that node's pool

**Verification Commands:**
```bash
# View Kubernetes-assigned Pod CIDR
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'

# Output example:
# worker-1    10.8.0.0/24
# worker-2    10.8.1.0/24
```

---

### Calico IPAM

**Allocation Strategy: Dynamic and On-Demand**

```
Pod Network CIDR: 10.8.0.0/16 (managed via IPPool)

Node 1 → 10.8.247.192/26   (62 IPs)  ← Allocated dynamically
Node 2 → 10.8.94.64/26     (62 IPs)  ← Non-sequential
Node 1 → 10.8.15.128/26    (62 IPs)  ← Second block for same node!
...sparse, dynamic allocation...
```

**Characteristics:**
- ✅ **Flexible** - Nodes can get multiple blocks as needed
- ✅ **Efficient** - Only allocates blocks when Pods are created
- ✅ **Scalable** - Smaller blocks mean more granular allocation
- ⚠️ **Less predictable** - IPs are allocated from anywhere in the range
- ⚠️ **Requires IPAM database** - More complexity

**IPAM Flow:**
1. Node joins cluster → No automatic CIDR assignment
2. First Pod scheduled on node → Calico IPAM allocates a `/26` block from IPPool
3. 62nd Pod scheduled → Still has IPs in current block
4. 63rd Pod scheduled → Calico allocates a new `/26` block to the same node
5. Pod deleted → IP is freed back to Calico's IPAM datastore

**Default Block Size: `/26` = 62 usable IPs**

**Why /26?**
- Smaller blocks = More flexible allocation
- Can allocate multiple blocks per node
- More efficient IP space utilization

**Real-World Example:**
```bash
kubectl get pods -o wide
# NAME                  IP              NODE
# web-app-xxx           10.8.247.196    worker-1
# web-app-yyy           10.8.94.70      worker-2
```

Notice the IPs are **not sequential** - they come from different `/26` blocks allocated dynamically.

> 💡 **Detailed Example**: For a comprehensive real-world example showing network interfaces, routing tables, and traffic flow on a Calico-enabled node, see [Calico Network Interfaces Example](calico-network-interfaces-example.md).

**Verification Commands:**
```bash
# View Calico IPPools
kubectl get ippools.crd.projectcalico.org -o yaml

# Check node.spec.podCIDR (will be empty or not used)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
# Output: May show nothing or values that Calico ignores
```

**Configuring Block Size:**
```yaml
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: 10.8.0.0/16
  blockSize: 26              # Change to 24, 25, 27 as needed
  ipipMode: Always
  natOutgoing: true
```

---

### Cilium IPAM

**Allocation Strategy: Configurable (Multiple Modes)**

Cilium supports **multiple IPAM modes**:

#### Mode 1: Cluster Scope (Default)
- Similar to Calico - dynamic allocation
- Uses CiliumNode custom resources

```yaml
apiVersion: cilium.io/v2
kind: CiliumNode
metadata:
  name: worker-1
spec:
  ipam:
    podCIDRs:
    - 10.8.0.0/24
```

#### Mode 2: Kubernetes Host Scope
- Uses Kubernetes-assigned `node.spec.podCIDR`
- Similar to Flannel

#### Mode 3: Azure/AWS/GCP IPAM
- Cloud provider native IPAM
- Pods get IPs directly from cloud VPC

**Characteristics:**
- ✅ **Most flexible** - Multiple IPAM modes
- ✅ **Cloud-native** - Integrates with cloud providers
- ✅ **Advanced** - Supports IPv6, dual-stack
- ⚠️ **Complex** - More configuration options

**Verification Commands:**
```bash
# View Cilium nodes
kubectl get ciliumnodes -o wide

# View Cilium IPAM status
kubectl exec -n kube-system ds/cilium -- cilium status --all-addresses
```

---

### Weave IPAM

**Allocation Strategy: Distributed Hash Table (DHT)**

```
Pod Network CIDR: 10.8.0.0/16

Weave creates a distributed IPAM database across all nodes
Each node can allocate IPs from any part of the range
Uses gossip protocol to sync IPAM state
```

**Characteristics:**
- ✅ **Distributed** - No single point of failure
- ✅ **Automatic** - No manual CIDR assignment needed
- ✅ **Simple setup** - Just install and go
- ⚠️ **Less efficient** - May have fragmentation
- ⚠️ **Gossip overhead** - Network chatter for IPAM sync

---

## 📊 Comparison Table

| Feature | Flannel | Calico | Cilium | Weave |
|---------|---------|--------|--------|-------|
| **IPAM Type** | Kubernetes-managed | CNI-managed | CNI-managed (multi-mode) | CNI-managed (DHT) |
| **Uses node.spec.podCIDR** | ✅ Yes | ❌ No | ⚠️ Optional | ❌ No |
| **Allocation Pattern** | Sequential | Dynamic | Configurable | Distributed |
| **Default Block Size** | /24 (254 IPs) | /26 (62 IPs) | /24 or configurable | Variable |
| **Multiple Blocks per Node** | ❌ No | ✅ Yes | ✅ Yes | ✅ Yes |
| **Predictability** | High | Low | Medium | Low |
| **Flexibility** | Low | High | Very High | High |
| **IP Efficiency** | Medium | High | High | Medium |
| **Complexity** | Low | Medium | High | Medium |

---

## 🛠️ Practical Examples

### Example 1: Checking Which IPAM Your Cluster Uses

```bash
# Method 1: Check CNI plugin
kubectl get ds -n kube-system | grep -E 'calico|flannel|cilium|weave'

# Method 2: Check if node.spec.podCIDR is populated
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'

# If populated and used → Likely Flannel (K8s-managed IPAM)
# If empty or not used → Likely Calico/Cilium (CNI-managed IPAM)

# Method 3: Check for CNI-specific resources
kubectl get ippools.crd.projectcalico.org    # Calico
kubectl get ciliumnodes                       # Cilium
```

### Example 2: Understanding Pod IP Allocation (Flannel)

```bash
# View node Pod CIDRs
kubectl get nodes -o custom-columns=NAME:.metadata.name,POD-CIDR:.spec.podCIDR

# Output:
# NAME       POD-CIDR
# worker-1   10.8.0.0/24
# worker-2   10.8.1.0/24

# View Pod IPs
kubectl get pods -A -o wide | awk '{print $1, $7, $8}'

# Pods on worker-1 will have IPs: 10.8.0.x
# Pods on worker-2 will have IPs: 10.8.1.x
```

### Example 3: Understanding Pod IP Allocation (Calico)

```bash
# View IPPool
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o yaml

# Output shows:
# cidr: 10.8.0.0/16
# blockSize: 26

# View Pod IPs
kubectl get pods -A -o wide

# Pods will have IPs from ANYWHERE in 10.8.0.0/16:
# Pod1: 10.8.247.196   (from block 10.8.247.192/26)
# Pod2: 10.8.94.70     (from block 10.8.94.64/26)
# Pod3: 10.8.15.130    (from block 10.8.15.128/26)
```

### Example 4: Troubleshooting IPAM Issues

```bash
# Check for IP exhaustion
kubectl describe nodes | grep -A 5 "Allocated resources"

# Calico: Check IP pool utilization
kubectl get ippools.crd.projectcalico.org -o yaml

# Check Pod IPs and their nodes
kubectl get pods -A -o custom-columns=NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName

# Look for duplicate IPs (should return nothing)
kubectl get pods -A -o json | jq -r '.items[] | .status.podIP' | sort | uniq -d
```

---

## 🎯 Key Takeaways

1. **IPAM is critical** - It prevents IP conflicts and manages Pod networking
2. **Two main approaches** - Kubernetes-managed (Flannel) vs CNI-managed (Calico, Cilium)
3. **Flannel = Simple & Predictable** - Sequential allocation, fixed blocks
4. **Calico = Flexible & Efficient** - Dynamic allocation, multiple blocks per node
5. **Cilium = Highly Configurable** - Multiple IPAM modes, cloud-native
6. **Choose based on needs** - Simplicity vs flexibility vs cloud integration

---

## 📚 Additional Resources

- [Kubernetes Network Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)
- [Calico IPAM Documentation](https://docs.tigera.io/calico/latest/networking/ipam/)
- [Flannel Documentation](https://github.com/flannel-io/flannel)
- [Cilium IPAM Modes](https://docs.cilium.io/en/stable/network/concepts/ipam/)

---

**Last Updated**: December 2025  
**Related**: [k8s-networking-fundamentals.md](k8s-networking-fundamentals.md)
