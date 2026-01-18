# 📊 Linux Cgroups: Resource Management in Containers

A comprehensive guide to understanding Linux Control Groups (cgroups) from the container runtime to Kubernetes resource management.

## 📋 Table of Contents
- [What Are Cgroups?](#what-are-cgroups)
- [Cgroups vs Namespaces](#cgroups-vs-namespaces)
- [Cgroup v1 vs v2](#cgroup-v1-vs-v2)
- [Cgroup Controllers](#cgroup-controllers)
- [Cgroups in Docker](#cgroups-in-docker)
- [Cgroups in Kubernetes](#cgroups-in-kubernetes)
- [Practical Visualization Guide](#practical-visualization-guide)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## What Are Cgroups?

**Control Groups (cgroups)** are a Linux kernel feature that limits, accounts for, and isolates the resource usage (CPU, memory, disk I/O, network) of process groups.

### Simple Concept

Think of cgroups like a **budget** for processes:
- You have limited resources (CPU, RAM, disk I/O)
- Cgroups allocate portions to different process groups
- Ensures no single process monopolizes resources
- Enables resource guarantees and limits

```
System Resources:
  CPU: 4 cores
  Memory: 16 GB
  Disk I/O: 1000 MB/s

Without cgroups:
  Process A can use all 16GB RAM → starves others
  Process B can use all 4 CPU cores → others wait

With cgroups:
  Container 1: Max 2GB RAM, 0.5 CPU cores
  Container 2: Max 4GB RAM, 1.0 CPU cores
  Container 3: Max 2GB RAM, 0.5 CPU cores
  → Fair resource allocation
  → Predictable performance
```

### Key Concepts

1. **Hierarchy**: Cgroups are organized in a tree structure
2. **Controllers**: Subsystems that manage specific resources (cpu, memory, io)
3. **Cgroup**: A collection of processes with resource limits
4. **Tasks**: Individual processes within a cgroup

```
Cgroup Hierarchy:
/sys/fs/cgroup/
├── system.slice/
│   ├── sshd.service/
│   ├── systemd-journald.service/
│   └── docker.service/
├── user.slice/
│   └── user-1000.slice/
└── kubepods.slice/
    ├── kubepods-burstable.slice/
    │   └── kubepods-burstable-pod123.slice/
    │       ├── cri-containerd-abc123.scope  ← Container 1
    │       └── cri-containerd-def456.scope  ← Container 2
    └── kubepods-besteffort.slice/
```

---

## Cgroups vs Namespaces

**Both work together to create containers**, but serve different purposes:

| Feature | **Namespaces** | **Cgroups** |
|---------|----------------|-------------|
| **Purpose** | Isolation | Resource control |
| **Question** | What can you **see**? | How much can you **use**? |
| **Examples** | PID, Network, Mount isolation | CPU, Memory, I/O limits |
| **Effect** | Container sees only its processes | Container can't exceed 2GB RAM |
| **Security** | Prevents access to other containers | Prevents resource starvation |
| **Kubernetes** | Pod network isolation | Pod resource requests/limits |

**Visual Comparison:**

```
Container without Namespaces + Cgroups:
  ❌ Can see all host processes
  ❌ Can use unlimited CPU/RAM
  ❌ Not isolated
  
Container with Namespaces only:
  ✅ Isolated view (can't see host)
  ❌ Can still use all CPU/RAM
  ⚠️  Partially isolated
  
Container with Namespaces + Cgroups:
  ✅ Isolated view (can't see host)
  ✅ Limited CPU/RAM usage
  ✅ Fully isolated and controlled
```

**Together they create containers:**

```
Container = Linux Process + Namespaces + Cgroups

Namespaces provide:
  - Private filesystem (mount ns)
  - Private network (net ns)
  - Private processes (pid ns)
  - Private hostname (uts ns)
  
Cgroups provide:
  - CPU limits (cpu controller)
  - Memory limits (memory controller)
  - I/O limits (io controller)
  - PID limits (pids controller)
```

---

## Cgroup v1 vs v2

Linux has two cgroup versions with different architectures.

### Cgroup v1 (Legacy)

```
/sys/fs/cgroup/
├── cpu/              ← Separate hierarchy per controller
│   └── docker/
│       └── abc123/
├── memory/           ← Another hierarchy
│   └── docker/
│       └── abc123/
├── blkio/            ← Yet another hierarchy
│   └── docker/
│       └── abc123/
└── ...
```

**Characteristics:**
- Multiple independent hierarchies (one per controller)
- Process can be in different cgroups for different controllers
- Complex to manage
- Still widely used

### Cgroup v2 (Unified Hierarchy)

```
/sys/fs/cgroup/
└── unified/          ← Single hierarchy
    ├── system.slice/
    ├── user.slice/
    └── kubepods.slice/
        └── pod-abc123/
            ├── cpu.max
            ├── memory.max
            ├── io.max
            └── cgroup.controllers  ← All controllers here
```

**Characteristics:**
- Single unified hierarchy
- Simpler and more consistent
- Better control delegation
- Default in modern systems (RHEL 9+, Ubuntu 22.04+)

### Check Your System

```bash
# Check which version is in use
stat -fc %T /sys/fs/cgroup/

# Output:
# tmpfs = cgroup v1
# cgroup2fs = cgroup v2

# Or check mount
mount | grep cgroup

# v1 shows: cgroup on /sys/fs/cgroup/cpu, /sys/fs/cgroup/memory, etc.
# v2 shows: cgroup2 on /sys/fs/cgroup
```

---

## Cgroup Controllers

Controllers manage specific resource types. Here are the main ones:

### 1. CPU Controller

Controls CPU time allocation.

**Key files:**
- `cpu.shares` (v1) / `cpu.weight` (v2): Relative CPU priority
- `cpu.cfs_quota_us` + `cpu.cfs_period_us` (v1) / `cpu.max` (v2): Absolute CPU limit

**Example:**
```bash
# Limit to 50% of one CPU core
# v1:
echo 50000 > /sys/fs/cgroup/cpu/mygroup/cpu.cfs_quota_us
echo 100000 > /sys/fs/cgroup/cpu/mygroup/cpu.cfs_period_us

# v2:
echo "50000 100000" > /sys/fs/cgroup/mygroup/cpu.max

# This means: 50ms of CPU time per 100ms period = 50% of 1 core
```

### 2. Memory Controller

Controls memory usage.

**Key files:**
- `memory.limit_in_bytes` (v1) / `memory.max` (v2): Hard memory limit
- `memory.usage_in_bytes` (v1) / `memory.current` (v2): Current usage
- `memory.oom_control`: OOM killer behavior

**Example:**
```bash
# Limit to 512MB
# v1:
echo 536870912 > /sys/fs/cgroup/memory/mygroup/memory.limit_in_bytes

# v2:
echo 536870912 > /sys/fs/cgroup/mygroup/memory.max

# Check current usage
# v1:
cat /sys/fs/cgroup/memory/mygroup/memory.usage_in_bytes

# v2:
cat /sys/fs/cgroup/mygroup/memory.current
```

**What happens when limit is reached:**
1. Kernel tries to reclaim memory (swap, cache eviction)
2. If can't reclaim enough → OOM (Out of Memory) killer
3. OOM killer terminates processes in the cgroup
4. In Kubernetes: Pod gets status `OOMKilled`

### 3. I/O Controller (blkio/io)

Controls disk I/O bandwidth and IOPS.

**Key files:**
- `blkio.throttle.read_bps_device` (v1) / `io.max` (v2): Read bandwidth limit
- `blkio.throttle.write_bps_device` (v1): Write bandwidth limit

**Example:**
```bash
# Limit read to 10MB/s on device 8:0 (sda)
# v1:
echo "8:0 10485760" > /sys/fs/cgroup/blkio/mygroup/blkio.throttle.read_bps_device

# v2:
echo "8:0 rbps=10485760" > /sys/fs/cgroup/mygroup/io.max
```

### 4. PIDs Controller

Limits number of processes/threads.

**Key files:**
- `pids.max`: Maximum number of PIDs
- `pids.current`: Current number of PIDs

**Example:**
```bash
# Limit to 100 processes
echo 100 > /sys/fs/cgroup/pids/mygroup/pids.max

# Prevent fork bombs!
```

### 5. CPUSet Controller

Pins processes to specific CPU cores and memory nodes.

**Key files:**
- `cpuset.cpus`: Which CPU cores to use
- `cpuset.mems`: Which memory nodes to use (NUMA)

**Example:**
```bash
# Pin to cores 0 and 1
echo "0-1" > /sys/fs/cgroup/cpuset/mygroup/cpuset.cpus

# Useful for:
# - Performance-sensitive workloads
# - NUMA systems
# - Kubernetes guaranteed QoS pods
```

---

## Cgroups in Docker

Docker uses cgroups to enforce container resource limits.

### How Docker Creates Cgroups

```bash
# Run a container with limits
docker run -d \
  --name test \
  --memory 512m \
  --cpus 0.5 \
  nginx

# Docker creates cgroup hierarchy:
# v1: /sys/fs/cgroup/memory/docker/<container-id>/
# v2: /sys/fs/cgroup/system.slice/docker-<container-id>.scope/
```

### View Docker Container Cgroups

```bash
# Get container ID
CONTAINER_ID=$(docker inspect -f '{{.Id}}' test)

# For cgroup v1:
# View memory limit
cat /sys/fs/cgroup/memory/docker/$CONTAINER_ID/memory.limit_in_bytes

# View CPU quota
cat /sys/fs/cgroup/cpu/docker/$CONTAINER_ID/cpu.cfs_quota_us
cat /sys/fs/cgroup/cpu/docker/$CONTAINER_ID/cpu.cfs_period_us

# For cgroup v2:
# Find the cgroup path
systemctl status docker-$CONTAINER_ID.scope

# View limits
cat /sys/fs/cgroup/system.slice/docker-$CONTAINER_ID.scope/memory.max
cat /sys/fs/cgroup/system.slice/docker-$CONTAINER_ID.scope/cpu.max
```

### Docker Resource Flags and Cgroup Mapping

| Docker Flag | Cgroup Controller | Cgroup File (v1) | Cgroup File (v2) |
|-------------|-------------------|------------------|------------------|
| `--memory 512m` | memory | `memory.limit_in_bytes` | `memory.max` |
| `--cpus 1.5` | cpu | `cpu.cfs_quota_us` | `cpu.max` |
| `--cpu-shares 512` | cpu | `cpu.shares` | `cpu.weight` |
| `--blkio-weight 500` | blkio | `blkio.weight` | `io.weight` |
| `--pids-limit 100` | pids | `pids.max` | `pids.max` |
| `--cpuset-cpus 0-3` | cpuset | `cpuset.cpus` | `cpuset.cpus` |

### Monitor Container Resource Usage

```bash
# Real-time stats
docker stats test

# Shows:
# - CPU % usage
# - Memory usage / limit
# - Network I/O
# - Block I/O

# This data comes from cgroups!
```

---

## Cgroups in Kubernetes

Kubernetes uses cgroups to enforce pod and container resource requests and limits.

### Kubernetes QoS Classes and Cgroups

Kubernetes assigns QoS classes based on resource specs:

```
┌─────────────────────────────────────────────────────────────────┐
│  QoS Class Hierarchy in cgroups                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  /sys/fs/cgroup/kubepods.slice/                                 │
│  │                                                               │
│  ├── kubepods-besteffort.slice/          ← Lowest priority     │
│  │   └── kubepods-besteffort-pod<uid>.slice/                    │
│  │       └── cri-containerd-<id>.scope                          │
│  │           No resource guarantees                             │
│  │           Can be killed first under pressure                 │
│  │                                                               │
│  ├── kubepods-burstable.slice/           ← Medium priority     │
│  │   └── kubepods-burstable-pod<uid>.slice/                     │
│  │       └── cri-containerd-<id>.scope                          │
│  │           requests < limits                                  │
│  │           Guaranteed requests, can burst to limits           │
│  │                                                               │
│  └── kubepods-pod<uid>.slice/            ← Highest priority    │
│      └── cri-containerd-<id>.scope       (Guaranteed)          │
│          requests = limits                                      │
│          Full resource guarantees                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Pod Resource Specs → Cgroup Settings

**Example Pod:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: resource-demo
spec:
  containers:
  - name: app
    image: nginx
    resources:
      requests:
        memory: "256Mi"
        cpu: "250m"
      limits:
        memory: "512Mi"
        cpu: "500m"
```

**Resulting Cgroup Settings:**

```bash
# QoS: Burstable (requests < limits)
# Cgroup path: /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/
#              kubepods-burstable-pod<uid>.slice/cri-containerd-<id>.scope/

# CPU settings:
cpu.shares = 256           # Based on requests (250m = 256 shares)
cpu.cfs_quota_us = 50000   # Based on limits (500m = 50% of 1 core)
cpu.cfs_period_us = 100000

# Memory settings:
memory.limit_in_bytes = 536870912  # 512Mi limit
```

### Understanding CPU Units

```
Kubernetes CPU units:
  1 CPU = 1000m (millicores)
  
  250m = 0.25 CPU = 25% of 1 core
  500m = 0.5 CPU  = 50% of 1 core
  1000m = 1 CPU   = 100% of 1 core
  2000m = 2 CPUs  = 200% = 2 full cores

Cgroup translation:
  cpu.cfs_quota_us = (CPU cores) × 100000
  
  0.5 CPU → 50000 quota / 100000 period = 50%
  1.0 CPU → 100000 quota / 100000 period = 100%
  2.0 CPU → 200000 quota / 100000 period = 200%
```

### Understanding Memory Units

```
Kubernetes memory units:
  Ki = Kibibyte = 1024 bytes
  Mi = Mebibyte = 1024 Ki = 1,048,576 bytes
  Gi = Gibibyte = 1024 Mi = 1,073,741,824 bytes
  
  256Mi = 268,435,456 bytes
  512Mi = 536,870,912 bytes
  1Gi   = 1,073,741,824 bytes

Direct mapping to cgroup memory.limit_in_bytes
```

---

## 🔍 Practical Visualization Guide

### Step-by-Step: Exploring Cgroups on Kubernetes

#### Step 1: Detect Cgroup Version

```bash
# On worker node
stat -fc %T /sys/fs/cgroup/

# If output is:
# - tmpfs → cgroup v1
# - cgroup2fs → cgroup v2

# Or check kernel
grep cgroup /proc/filesystems
```

#### Step 2: Create a Test Pod with Resource Limits

```bash
# Create pod with specific resource limits
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cgroup-demo
  labels:
    app: demo
spec:
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress"]
    args:
    - "--vm"
    - "1"
    - "--vm-bytes"
    - "150M"
    - "--vm-hang"
    - "1"
    resources:
      requests:
        memory: "200Mi"
        cpu: "250m"
      limits:
        memory: "400Mi"
        cpu: "500m"
EOF

# Wait for pod to start
kubectl wait --for=condition=ready pod/cgroup-demo
```

#### Step 3: Find Pod's Cgroup Path

```bash
# Get pod UID
POD_UID=$(kubectl get pod cgroup-demo -o jsonpath='{.metadata.uid}')
echo "Pod UID: $POD_UID"

# SSH to the node where pod is running
NODE=$(kubectl get pod cgroup-demo -o jsonpath='{.spec.nodeName}')
echo "Pod running on: $NODE"
ssh user@$NODE

# Find container ID
sudo crictl ps | grep cgroup-demo
CONTAINER_ID=$(sudo crictl ps | grep cgroup-demo | grep -v pause | awk '{print $1}')
echo "Container ID: $CONTAINER_ID"
```

#### Step 4: Locate Cgroup Directory (v1)

```bash
# For cgroup v1:
# Find the cgroup path
CGROUP_PATH=$(sudo find /sys/fs/cgroup/memory -name "*$CONTAINER_ID*")
echo "Cgroup path: $CGROUP_PATH"

# Or based on pod UID (more reliable)
POD_CGROUP=$(sudo find /sys/fs/cgroup/memory/kubepods.slice -name "*$POD_UID*" -type d | head -1)
echo "Pod cgroup: $POD_CGROUP"

# List cgroup files
ls -la $POD_CGROUP/
```

#### Step 5: Locate Cgroup Directory (v2)

```bash
# For cgroup v2:
# Pods are under kubepods.slice
ls -la /sys/fs/cgroup/kubepods.slice/

# Find by QoS class (this pod is Burstable)
ls -la /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/

# Find specific pod
POD_CGROUP=$(sudo find /sys/fs/cgroup/kubepods.slice -name "*$POD_UID*" -type d | head -1)
echo "Pod cgroup: $POD_CGROUP"

# List files
ls -la $POD_CGROUP/
```

#### Step 6: Inspect Memory Limits and Usage

```bash
# For cgroup v1:
echo "=== Memory Configuration ==="
echo -n "Memory Limit: "
cat $POD_CGROUP/memory.limit_in_bytes | numfmt --to=iec

echo -n "Current Usage: "
cat $POD_CGROUP/memory.usage_in_bytes | numfmt --to=iec

echo -n "Max Usage: "
cat $POD_CGROUP/memory.max_usage_in_bytes | numfmt --to=iec

echo "Memory Stats:"
cat $POD_CGROUP/memory.stat | head -10

# For cgroup v2:
echo "=== Memory Configuration ==="
echo -n "Memory Limit: "
cat $POD_CGROUP/memory.max | numfmt --to=iec

echo -n "Current Usage: "
cat $POD_CGROUP/memory.current | numfmt --to=iec

echo "Memory Stats:"
cat $POD_CGROUP/memory.stat | head -10
```

**Expected output:**
```
Memory Limit: 400M      ← Matches pod limit
Current Usage: 150M     ← stress command using 150M
Max Usage: 155M
```

#### Step 7: Inspect CPU Limits and Usage

```bash
# For cgroup v1:
echo "=== CPU Configuration ==="
echo -n "CPU Quota (microseconds): "
cat $POD_CGROUP/../cpu/cpu.cfs_quota_us
# Should be 50000 (0.5 CPU)

echo -n "CPU Period (microseconds): "
cat $POD_CGROUP/../cpu/cpu.cfs_period_us
# Should be 100000

echo "CPU Quota / Period = $(awk "BEGIN {print $(cat $POD_CGROUP/../cpu/cpu.cfs_quota_us) / $(cat $POD_CGROUP/../cpu/cpu.cfs_period_us)}")"
# Should be 0.5 (50% of 1 core)

echo -n "CPU Shares: "
cat $POD_CGROUP/../cpu/cpu.shares
# Based on requests (250m)

echo "CPU Stats:"
cat $POD_CGROUP/../cpu/cpu.stat

# For cgroup v2:
echo "=== CPU Configuration ==="
cat $POD_CGROUP/cpu.max
# Output: "50000 100000" = 50ms per 100ms = 0.5 CPU

cat $POD_CGROUP/cpu.weight
# Based on requests

cat $POD_CGROUP/cpu.stat
```

#### Step 8: Monitor Real-Time Usage

```bash
# Watch memory usage change
watch -n 1 "cat $POD_CGROUP/memory.current | numfmt --to=iec"

# Or create a monitoring script
while true; do
  clear
  echo "=== Real-Time Cgroup Stats ==="
  echo "Time: $(date)"
  echo ""
  echo "Memory:"
  echo "  Current: $(cat $POD_CGROUP/memory.current | numfmt --to=iec)"
  echo "  Limit: $(cat $POD_CGROUP/memory.max | numfmt --to=iec)"
  echo ""
  echo "CPU:"
  cat $POD_CGROUP/cpu.stat
  sleep 1
done
```

#### Step 9: Trigger OOM Kill

```bash
# Create pod that will exceed memory limit
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: oom-demo
spec:
  containers:
  - name: stress
    image: polinux/stress
    command: ["stress"]
    args:
    - "--vm"
    - "1"
    - "--vm-bytes"
    - "500M"  # More than limit!
    - "--vm-hang"
    - "0"
    resources:
      limits:
        memory: "256Mi"  # Limit: 256Mi
EOF

# Watch pod status
kubectl get pod oom-demo -w

# You'll see:
# OOMKilled status

# Check events
kubectl describe pod oom-demo | grep -A5 "Events"

# On node, check OOM kill in dmesg
sudo dmesg | grep -i "oom\|killed" | tail -20
```

#### Step 10: Compare QoS Classes

```bash
# Create pods with different QoS classes

# Guaranteed (requests = limits)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: qos-guaranteed
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        memory: "256Mi"
        cpu: "500m"
      limits:
        memory: "256Mi"
        cpu: "500m"
EOF

# Burstable (requests < limits)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: qos-burstable
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        memory: "128Mi"
        cpu: "250m"
      limits:
        memory: "256Mi"
        cpu: "500m"
EOF

# BestEffort (no requests/limits)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: qos-besteffort
spec:
  containers:
  - name: nginx
    image: nginx
EOF

# Check QoS class
kubectl get pod qos-guaranteed -o jsonpath='{.status.qosClass}'
kubectl get pod qos-burstable -o jsonpath='{.status.qosClass}'
kubectl get pod qos-besteffort -o jsonpath='{.status.qosClass}'

# On node, see where they are placed
ls -la /sys/fs/cgroup/kubepods.slice/
# You'll see:
# - kubepods-pod<uid>.slice/          ← Guaranteed
# - kubepods-burstable.slice/         ← Burstable
# - kubepods-besteffort.slice/        ← BestEffort
```

### Visualizing Cgroup Hierarchy

```bash
# Install tree (if not present)
sudo yum install tree -y  # or apt-get

# View kubepods hierarchy (v1)
sudo tree -L 4 /sys/fs/cgroup/memory/kubepods.slice/

# View kubepods hierarchy (v2)
sudo tree -L 4 /sys/fs/cgroup/kubepods.slice/

# See the QoS class hierarchy!
```

### Understanding kubectl top and Cgroups

```bash
# kubectl top reads from cgroups!
kubectl top pod cgroup-demo

# On node, this is equivalent to:
POD_CGROUP=$(sudo find /sys/fs/cgroup -name "*cgroup-demo*" -type d | head -1)

# CPU usage (from cpu.stat)
cat $POD_CGROUP/cpu.stat

# Memory usage (from memory.current)
cat $POD_CGROUP/memory.current
```

---

## Troubleshooting

### Common Issues and Solutions

#### Issue 1: Pod Getting OOMKilled

```bash
# Symptoms
kubectl get pod myapp
# STATUS: OOMKilled or CrashLoopBackOff

kubectl describe pod myapp
# Events show: OOMKilled

# Diagnosis
# 1. Check pod memory limit
kubectl get pod myapp -o jsonpath='{.spec.containers[*].resources.limits.memory}'

# 2. Check actual memory usage before kill
kubectl describe pod myapp | grep -i memory

# 3. On node, check cgroup memory stats
POD_CGROUP=$(sudo find /sys/fs/cgroup -name "*myapp*" -type d | head -1)
cat $POD_CGROUP/memory.max_usage_in_bytes | numfmt --to=iec
cat $POD_CGROUP/memory.limit_in_bytes | numfmt --to=iec

# Solution
# Increase memory limit in pod spec
resources:
  limits:
    memory: "1Gi"  # Increase from 512Mi
```

#### Issue 2: CPU Throttling

```bash
# Symptoms
# Application slow, but CPU usage below limit in kubectl top

# Diagnosis
# Check throttling statistics
POD_CGROUP=$(sudo find /sys/fs/cgroup -name "*myapp*" -type d | head -1)

# v1:
cat $POD_CGROUP/../cpu/cpu.stat | grep throttled
# Shows:
#   nr_throttled: 12543       ← Number of times throttled
#   throttled_time: 982374823 ← Nanoseconds throttled

# v2:
cat $POD_CGROUP/cpu.stat | grep throttled

# High throttle counts = CPU limit too low

# Solution
# Increase CPU limit
resources:
  limits:
    cpu: "1000m"  # Increase from 500m
```

#### Issue 3: Can't Find Pod's Cgroup

```bash
# Get pod UID
POD_UID=$(kubectl get pod myapp -o jsonpath='{.metadata.uid}')

# Search for it
sudo find /sys/fs/cgroup -name "*$POD_UID*"

# If empty, pod might not be running on this node
kubectl get pod myapp -o wide
# Check NODE column

# Or search by container ID
CONTAINER_ID=$(sudo crictl ps | grep myapp | grep -v pause | awk '{print $1}')
sudo find /sys/fs/cgroup -name "*$CONTAINER_ID*"
```

#### Issue 4: Cgroup v1 vs v2 Confusion

```bash
# Detect version first
stat -fc %T /sys/fs/cgroup/

# v1 commands:
cat /sys/fs/cgroup/memory/kubepods.slice/.../memory.limit_in_bytes
cat /sys/fs/cgroup/cpu/kubepods.slice/.../cpu.cfs_quota_us

# v2 commands:
cat /sys/fs/cgroup/kubepods.slice/.../memory.max
cat /sys/fs/cgroup/kubepods.slice/.../cpu.max

# Create helper function
cgversion() {
  if [ "$(stat -fc %T /sys/fs/cgroup/)" = "cgroup2fs" ]; then
    echo "v2"
  else
    echo "v1"
  fi
}
```

### Debugging Commands Reference

```bash
# List all cgroups
systemd-cgls

# List cgroups for a process
cat /proc/<PID>/cgroup

# View cgroup resource usage
systemd-cgtop

# Check container's cgroup
sudo crictl inspect <container-id> | jq -r '.info.runtimeSpec.linux.cgroupsPath'

# Monitor cgroup events
# v2 only:
cat /sys/fs/cgroup/kubepods.slice/.../memory.events
# Shows oom_kill count, etc.
```

---

## Quick Reference

### Cgroup File Cheat Sheet

| Resource | v1 File | v2 File | Description |
|----------|---------|---------|-------------|
| **Memory Limit** | `memory.limit_in_bytes` | `memory.max` | Hard memory limit |
| **Memory Usage** | `memory.usage_in_bytes` | `memory.current` | Current usage |
| **Memory Stats** | `memory.stat` | `memory.stat` | Detailed statistics |
| **CPU Limit** | `cpu.cfs_quota_us` | `cpu.max` | CPU time quota |
| **CPU Period** | `cpu.cfs_period_us` | (in cpu.max) | Quota period |
| **CPU Weight** | `cpu.shares` | `cpu.weight` | Relative CPU priority |
| **CPU Stats** | `cpu.stat` | `cpu.stat` | CPU usage statistics |
| **I/O Limit** | `blkio.throttle.*` | `io.max` | I/O bandwidth limits |
| **PID Limit** | `pids.max` | `pids.max` | Process count limit |

### Common Commands

```bash
# Find pod's cgroup
kubectl get pod <pod> -o jsonpath='{.metadata.uid}'
sudo find /sys/fs/cgroup -name "*<uid>*"

# View memory usage
cat /sys/fs/cgroup/.../memory.current | numfmt --to=iec

# View CPU stats
cat /sys/fs/cgroup/.../cpu.stat

# Monitor real-time
watch -n1 'cat /sys/fs/cgroup/.../memory.current | numfmt --to=iec'

# Check OOM events
cat /sys/fs/cgroup/.../memory.events | grep oom

# View hierarchy
systemd-cgls

# View resource usage
systemd-cgtop
```

---

## References

- [Linux Cgroups Documentation](https://www.kernel.org/doc/Documentation/cgroup-v1/)
- [Cgroup v2 Documentation](https://www.kernel.org/doc/Documentation/cgroup-v2.txt)
- [Kubernetes Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Docker Runtime Options](https://docs.docker.com/config/containers/resource_constraints/)
- [systemd Resource Control](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html)
- [Linux Namespaces](linux-namespaces.md)
- [Containers Overview](containers.md)
- [Kubernetes Pods](pods.md)

---

**Next Steps:**
1. Practice viewing cgroups for running containers
2. Understand QoS classes and their impact
3. Learn to troubleshoot OOMKilled pods
4. Monitor resource usage patterns
5. Tune resource requests and limits based on actual usage

**⚠️ Important Notes:**
- Cgroup v2 is the future; learn both but focus on v2
- Always set memory limits to prevent node exhaustion
- CPU throttling is common; monitor with `cpu.stat`
- QoS class determines eviction priority under pressure
- Use `kubectl top` and cgroups together for full picture
