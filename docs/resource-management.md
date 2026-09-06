# ⚖️ Resource Management: Requests, Limits, QoS and Quotas

A complete guide to CPU and memory requests and limits, the QoS classes they produce, node allocatable arithmetic, eviction, LimitRange and ResourceQuota, and how to right size a workload.

## 📋 Table of Contents
- [The Two Numbers That Run Kubernetes](#the-two-numbers-that-run-kubernetes)
- [The Unit System](#the-unit-system)
- [What a Request Actually Does](#what-a-request-actually-does)
- [What a Limit Actually Does](#what-a-limit-actually-does)
- [Compressible and Incompressible Resources](#compressible-and-incompressible-resources)
- [The CPU Throttling Problem](#the-cpu-throttling-problem)
- [Quality of Service Classes](#quality-of-service-classes)
- [Node Allocatable](#node-allocatable)
- [Node Pressure Eviction](#node-pressure-eviction)
- [LimitRange](#limitrange)
- [ResourceQuota](#resourcequota)
- [Right Sizing Methodology](#right-sizing-methodology)
- [In Place Pod Resize](#in-place-pod-resize)
- [Extended Resources and Device Plugins](#extended-resources-and-device-plugins)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The Two Numbers That Run Kubernetes

Every container may declare two numbers per resource, and those numbers drive scheduling, cgroup configuration, QoS classification, eviction order and quota accounting.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: resource-demo
spec:
  containers:
    - name: app
      image: nginx:1.27
      resources:
        requests:              # what the scheduler reserves for you
          cpu: "250m"
          memory: "256Mi"
          ephemeral-storage: "1Gi"
        limits:                # what the kernel refuses to let you exceed
          cpu: "1"
          memory: "512Mi"
          ephemeral-storage: "2Gi"
```

```
┌───────────────────────────────────────────────────────────────────────────┐
│                    Where each number is consumed                          │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  requests.cpu ─────┬──► kube-scheduler: NodeResourcesFit feasibility       │
│                    ├──► kube-scheduler: NodeResourcesFit / Balanced score  │
│                    ├──► kubelet:  cgroup cpu.shares (v1) / cpu.weight (v2) │
│                    ├──► QoS classification                                │
│                    └──► ResourceQuota accounting (requests.cpu)            │
│                                                                           │
│  requests.memory ──┬──► kube-scheduler: NodeResourcesFit feasibility       │
│                    ├──► QoS classification                                │
│                    ├──► oom_score_adj for Burstable containers            │
│                    ├──► node pressure eviction ranking (usage vs request) │
│                    └──► ResourceQuota accounting (requests.memory)         │
│                                                                           │
│  limits.cpu ───────┬──► kubelet:  cgroup cpu.max / cfs_quota_us           │
│                    ├──► QoS classification                                │
│                    └──► ResourceQuota accounting (limits.cpu)              │
│                                                                           │
│  limits.memory ────┬──► kubelet:  cgroup memory.max / limit_in_bytes      │
│                    ├──► QoS classification                                │
│                    ├──► kernel OOM killer trigger point                   │
│                    └──► ResourceQuota accounting (limits.memory)           │
│                                                                           │
│  The scheduler NEVER looks at limits for feasibility, and NEVER looks at   │
│  actual usage at all. Only requests decide whether a Pod fits.             │
└───────────────────────────────────────────────────────────────────────────┘
```

Two rules follow immediately and explain most surprises:

1. **A node can be 5 percent busy and still refuse a Pod**, because the sum of *requests* already equals allocatable.
2. **A node can be 300 percent oversubscribed on limits and be perfectly healthy**, because limits are ceilings, not reservations.

```bash
# Requests is the column that gates scheduling. Limits over 100% is normal.
kubectl describe node worker-1 | sed -n '/Allocated resources/,/^Events/p'
# Resource    Requests      Limits
# cpu         3200m (80%)   6 (150%)
# memory      5Gi (65%)     8Gi (104%)
```

> 📖 This document explains the Kubernetes layer. The kernel mechanics of the cgroup files named here (hierarchy, controllers, v1 versus v2, `/sys/fs/cgroup` layout, how to read them on a live node) are covered in depth in [cgroups.md](cgroups.md). This page does not repeat them.

---

## The Unit System

### CPU

CPU is measured in **CPU units**, where `1` means one full core: one hyperthread on bare metal, one vCPU on a cloud instance.

| Written as | Meaning | Notes |
|------------|---------|-------|
| `1` | 1 core | Integer form |
| `0.5` | Half a core | Legal but discouraged, it is stored as `500m` |
| `500m` | 500 millicores, half a core | The canonical form. `m` means one thousandth |
| `100m` | One tenth of a core | The typical small sidecar request |
| `1500m` | 1.5 cores | Same as `1.5` |
| `1m` | The smallest expressible quantity | Anything finer is rejected |

CPU is **absolute, not relative to the node**. `500m` means the same amount of compute on a 4 core node and on a 64 core node. It does not mean "half of one specific core"; the scheduler and the kernel are free to spread that time across every core.

### Memory

Memory is measured in bytes, with two independent suffix families. Confusing them is the single most common resource mistake.

| Suffix | Multiplier | Exact value |
|--------|-----------|-------------|
| `Ki` | 2^10 | 1024 |
| `Mi` | 2^20 | 1 048 576 |
| `Gi` | 2^30 | 1 073 741 824 |
| `Ti` | 2^40 | 1 099 511 627 776 |
| `Pi` | 2^50 | 1 125 899 906 842 624 |
| `Ei` | 2^60 | 1 152 921 504 606 846 976 |
| `k` | 10^3 | 1 000 |
| `M` | 10^6 | 1 000 000 |
| `G` | 10^9 | 1 000 000 000 |
| `T` | 10^12 | 1 000 000 000 000 |
| `P` | 10^15 | 1 000 000 000 000 000 |
| `E` | 10^18 | 1 000 000 000 000 000 000 |

```
128974848  =  129e6  =  129M  =  123Mi     ← all the same object, four spellings

1G  = 1 000 000 000 bytes
1Gi = 1 073 741 824 bytes
Difference: 73 741 824 bytes, about 7 percent.

A JVM told "-Xmx1G" inside a container limited to "1G" is fine.
A JVM told "-Xmx1G" inside a container limited to "1000M" will be OOMKilled,
because 1G > 1000M by 4.9 percent.
```

> ⚠️ **`m` on a memory value is a trap, not an error.** `memory: 400m` is valid YAML and valid Kubernetes: it means 0.4 **bytes**, which rounds to essentially nothing and makes every allocation fail. The API server accepts it. Always write `400Mi` or `400M`.

Kubernetes normalises quantities on write, so what you get back is not always what you typed:

```bash
kubectl get pod resource-demo -o jsonpath='{.spec.containers[0].resources}{"\n"}'
# {"limits":{"cpu":"1","memory":"512Mi"},"requests":{"cpu":"250m","memory":"256Mi"}}

# Prove the normalisation
kubectl create --dry-run=client -o yaml -f - <<'EOF' | grep -A4 resources
apiVersion: v1
kind: Pod
metadata: { name: q }
spec:
  containers:
    - name: c
      image: busybox
      resources:
        requests: { cpu: "0.5", memory: "1024Mi" }
EOF
# requests:
#   cpu: 500m
#   memory: 1Gi
```

### ephemeral-storage

`ephemeral-storage` covers local writable space consumed by a Pod: the container writable layer, `emptyDir` volumes that are not memory backed, and container logs.

```yaml
      resources:
        requests:
          ephemeral-storage: "2Gi"
        limits:
          ephemeral-storage: "4Gi"
```

| Property | Behaviour |
|----------|-----------|
| Requested at scheduling | Yes, `NodeResourcesFit` filters on it |
| Enforced by a cgroup | No. The kubelet **polls** usage periodically |
| Exceeding the limit | The Pod is **evicted**, not throttled and not OOMKilled |
| Counted against | The container writable layer, non memory `emptyDir`, and logs |
| Not counted | PersistentVolumes, `hostPath`, memory backed `emptyDir` |

Because enforcement is by polling, a container that writes a 20 GiB file in two seconds can overrun a 4 GiB limit before the kubelet notices. Ephemeral storage limits protect the node from slow leaks, not from bursts.

### hugepages

```yaml
      resources:
        limits:
          hugepages-2Mi: "512Mi"     # 256 pages of 2 MiB
          memory: "1Gi"
        requests:
          hugepages-2Mi: "512Mi"     # must equal the limit
          memory: "1Gi"
```

| Rule | Detail |
|------|--------|
| Resource name | `hugepages-<size>`, for example `hugepages-2Mi` and `hugepages-1Gi` |
| Request and limit | Must be **equal**. Hugepages are never overcommitted |
| Node advertisement | The kubelet reports pre-allocated hugepages in `node.status.capacity` |
| Consumption | Through an `emptyDir` with `medium: HugePages`, or through a runtime that requests them directly |
| Accounting | Hugepage memory is **separate** from `memory`; it is not deducted from the `memory` limit |

```bash
# What the node advertises
kubectl get node worker-1 -o jsonpath='{.status.allocatable}{"\n"}' | python3 -m json.tool
# {
#   "cpu": "4",
#   "ephemeral-storage": "47233297124",
#   "hugepages-1Gi": "0",
#   "hugepages-2Mi": "512Mi",
#   "memory": "7900848Ki",
#   "pods": "110"
# }
```

---

## What a Request Actually Does

A request does exactly two things. Nothing more.

### 1. Scheduler Admission

```
For every node N and every resource R:

    sum(requests[R] of all non-terminated Pods on N) + this Pod's requests[R]
        must be <= N.status.allocatable[R]

If that fails for any R, the NodeResourcesFit filter rejects N and the event
says "Insufficient <R>".
```

The scheduler's arithmetic is pure bookkeeping against `allocatable`. It never reads a metric, never asks the kubelet what is actually happening, and never considers limits.

```bash
# The bookkeeping, done by hand for one node
kubectl get pods -A --field-selector spec.nodeName=worker-1 \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].resources.requests.cpu}{"\n"}{end}'
```

### 2. A Proportional Share of Contended CPU

`requests.cpu` becomes the container's **weight** in the kernel's CPU scheduler.

```
cgroup v1:   cpu.shares  =  milliCPU * 1024 / 1000        (minimum 2)
             250m  -> 256 shares
             1000m -> 1024 shares
             2000m -> 2048 shares

cgroup v2:   cpu.weight, which the container runtime derives from the same
             shares value using the standard OCI conversion.
```

Shares are meaningful **only when the CPU is saturated**. On an idle node every container can use as much CPU as it wants regardless of its request.

```
Node with 4 cores, fully contended, three containers wanting all the CPU:

  container A   requests 1000m   -> 1024 shares
  container B   requests  500m   ->  512 shares
  container C   requests  500m   ->  512 shares
                                    ----
                             total  2048 shares

  A gets 1024/2048 = 50%  of 4 cores = 2.0 cores
  B gets  512/2048 = 25%  of 4 cores = 1.0 core
  C gets  512/2048 = 25%  of 4 cores = 1.0 core

Same node, only A is busy:
  A gets all 4 cores. Its 1000m request is a floor, not a ceiling.
```

> 🔑 **`requests.memory` has no runtime enforcement at all.** There is no cgroup file that reserves memory. It is used by the scheduler, by QoS classification, by the `oom_score_adj` calculation for Burstable containers, and by the eviction ranking. A container may use far more memory than it requested, right up to its limit or the node's capacity.

---

## What a Limit Actually Does

A limit is written into the container's cgroup, which means the **kernel** enforces it, not Kubernetes.

| Limit | cgroup v1 file | cgroup v2 file | Enforcement |
|-------|----------------|----------------|-------------|
| `limits.cpu` | `cpu.cfs_quota_us`, `cpu.cfs_period_us` | `cpu.max` | Bandwidth throttling |
| `limits.memory` | `memory.limit_in_bytes` | `memory.max` | Allocation failure, then the OOM killer |
| `limits.ephemeral-storage` | none | none | kubelet polling, then eviction |
| `limits.hugepages-*` | `hugetlb.<size>.limit_in_bytes` | `hugetlb.<size>.max` | Allocation failure |

### CPU Limit

```
limits.cpu: "1"     ->   period = 100000 us (100 ms), quota = 100000 us
limits.cpu: "500m"  ->   period = 100000 us,          quota =  50000 us
limits.cpu: "2500m" ->   period = 100000 us,          quota = 250000 us

cgroup v2:   cat cpu.max
             250000 100000        ← "quota period", both in microseconds
             max 100000           ← no limit set
```

Every 100 ms the kernel gives the cgroup its quota of CPU time. When the quota is exhausted, **every thread in the cgroup is stopped** until the next period begins. Nothing is killed and nothing errors; the application simply stops running for a while.

### Memory Limit

```
limits.memory: "512Mi"  ->  memory.max = 536870912

When usage would exceed memory.max:
  1. The kernel tries to reclaim: drop page cache, write back dirty pages.
  2. If reclaim is not enough, the cgroup OOM killer runs INSIDE the cgroup.
  3. It kills the process with the worst oom_score in that cgroup.
  4. If that was PID 1, the container dies with exit code 137 (128 + SIGKILL 9)
     and the Pod status reason becomes OOMKilled.
  5. The kubelet restarts it according to the Pod restartPolicy, with the
     usual CrashLoopBackOff delay if it keeps happening.
```

```bash
# The signature of a memory limit violation
kubectl describe pod hungry
#   Last State:     Terminated
#     Reason:       OOMKilled
#     Exit Code:    137

kubectl get pod hungry -o jsonpath='{.status.containerStatuses[0].lastState.terminated}{"\n"}'
```

> 🔑 **Exit code 137 is not always a container memory limit.** The same code appears when the node ran out of memory globally and the kernel picked your process, and when anything else sends `SIGKILL`. The distinguishing evidence is `reason: OOMKilled` on the container status plus the absence of a Pod level `Evicted` status. A node level OOM produces kernel log lines you can find with `dmesg -T | grep -i oom`.

---

## Compressible and Incompressible Resources

This one distinction explains why CPU and memory behave so differently.

| | **CPU** | **Memory** |
|---|---------|-----------|
| Classification | Compressible | Incompressible |
| Can be taken back? | Yes, instantly, by not scheduling the threads | No, a page in use cannot be reclaimed without breaking the process |
| Over limit behaviour | **Throttled**: the app runs slower | **Killed**: the process is SIGKILLed |
| Over request, under limit | Allowed and normal | Allowed and normal |
| Node under pressure | Everyone slows down proportionally to shares | The kubelet evicts Pods, then the kernel OOM killer runs |
| Failure mode | Latency, timeouts, missed health checks | Crash, data loss for in-flight work, CrashLoopBackOff |
| Recovery | Automatic when load drops | Requires a restart |

```
       CPU limit exceeded                    Memory limit exceeded
┌────────────────────────────┐        ┌────────────────────────────┐
│  quota exhausted           │        │  allocation cannot be met  │
│         ▼                  │        │         ▼                  │
│  threads descheduled       │        │  reclaim attempted         │
│         ▼                  │        │         ▼                  │
│  latency rises             │        │  cgroup OOM killer         │
│         ▼                  │        │         ▼                  │
│  next 100 ms period starts │        │  SIGKILL, exit 137         │
│         ▼                  │        │         ▼                  │
│  app continues, alive      │        │  container restart         │
└────────────────────────────┘        └────────────────────────────┘
     Degraded but correct                    Dead and restarted
```

**Practical consequence**: set memory limits close to reality and treat them as safety fuses, because being wrong is fatal. Treat CPU limits with much more suspicion, because being wrong is invisible in every metric except latency.

---

## The CPU Throttling Problem

### The Arithmetic

```
period = 100 ms (100000 us)  ← cpu.cfs_period_us, the kubelet default
quota  = limit_cores * period

limits.cpu: 1     -> quota = 100 ms of CPU time per 100 ms of wall clock
limits.cpu: 500m  -> quota =  50 ms of CPU time per 100 ms of wall clock
limits.cpu: 4     -> quota = 400 ms of CPU time per 100 ms of wall clock
```

The subtlety: **quota is consumed by all threads together**. A 4 threaded process with `limits.cpu: 1` burns its 100 ms quota in 25 ms of wall clock time, then stalls for 75 ms.

### Worked Example: Throttled While Looking Idle

A service with a pool of 8 worker threads and `limits.cpu: "1"`. Each incoming request is fanned out across all 8 threads and needs 40 ms of CPU time in total. Requests arrive once per second.

```
Quota per 100 ms period with limits.cpu: 1  =  100 ms of CPU time.

One request, served by 8 threads in parallel:
  CPU time needed   = 40 ms
  Wall clock if unthrottled = 40/8 = 5 ms      <- the fast path
  Quota consumed    = 40 ms out of 100 ms      <- fits comfortably

Now 4 requests arrive inside the same 100 ms period:
  CPU time needed   = 160 ms
  Quota available   = 100 ms
  Result: after 100 ms of CPU time is spent (about 12.5 ms of wall clock
  with 8 threads running), ALL 8 threads are stopped until the next
  period begins, roughly 87 ms later.

  Latency for those requests jumps from about 5 ms to about 100 ms,
  a twentyfold regression, with no error and no restart.

What the dashboards show over that same second:
  CPU used  = 160 ms out of 1000 ms of wall clock = 0.16 cores
  kubectl top says 160m against a 1000m limit, that is 16 percent.
  The container looks almost idle while it is spending most of its
  active time frozen.
```

The pathology: **average CPU utilisation is bounded above by the limit**, and bursty work is throttled inside a period even when the period average is low. A throttled container always *looks* comfortable. The only honest signal is the throttling counter itself.

### Measuring Throttling

```bash
# cgroup v2, from inside the container or from the node
cat /sys/fs/cgroup/cpu.stat
# usage_usec 128374652
# nr_periods 84213
# nr_throttled 20517          <-- periods in which the quota ran out
# throttled_usec 913245000    <-- total time spent stopped

# cgroup v1
cat /sys/fs/cgroup/cpu/cpu.stat
# nr_periods 84213
# nr_throttled 20517
# throttled_time 913245000000
```

```promql
# The Prometheus form, from cAdvisor metrics exposed by the kubelet
rate(container_cpu_cfs_throttled_periods_total{pod="my-pod"}[5m])
  /
rate(container_cpu_cfs_periods_total{pod="my-pod"}[5m])
```

| Throttled period ratio | Interpretation |
|------------------------|----------------|
| Under 1 percent | Noise, ignore |
| 1 to 5 percent | Occasional bursts hitting the ceiling, usually acceptable |
| 5 to 25 percent | Real latency impact, raise the limit |
| Over 25 percent | The limit is badly wrong; the application is spending a quarter of its life stopped |

> 📖 [cgroups.md](cgroups.md) shows how to locate a specific container's cgroup path under `/sys/fs/cgroup/kubepods.slice/...` so you can read `cpu.stat` for one Pod on a live node.

### Should You Set CPU Limits At All?

| Argument for CPU limits | Argument against CPU limits |
|-------------------------|-----------------------------|
| Deterministic, reproducible performance across environments | Throttling wastes idle CPU that nobody else wants |
| Prevents one runaway process from starving everything on the node | Multi threaded runtimes, JVM garbage collectors and Go runtimes throttle badly at low limits |
| Required to reach the Guaranteed QoS class | Latency damage is invisible in utilisation dashboards |
| Makes capacity planning honest | `cpu.shares` from requests already guarantees fair sharing under contention |
| Needed to fit under a `limits.cpu` ResourceQuota | Setting the limit too low is a common, silent production incident |

The pragmatic consensus that has emerged in production Kubernetes:

- **Always set CPU requests.** They are the only thing the scheduler sees and the only thing that guarantees a share under contention.
- **Always set memory requests and memory limits**, and set them close together.
- **Consider omitting CPU limits** for latency sensitive services on nodes you control, letting `cpu.shares` handle contention.
- **Do set CPU limits** for untrusted or multi tenant workloads, for batch jobs that should not steal from interactive work, and anywhere you need Guaranteed QoS.
- If you set a CPU limit, **set it generously**, typically well above the observed peak, not at the observed average.

---

## Quality of Service Classes

The QoS class is **derived**, never declared. Kubernetes computes it at admission from the requests and limits of every container in the Pod and writes it to `status.qosClass`.

```bash
kubectl get pods -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass
kubectl get pod my-pod -o jsonpath='{.status.qosClass}{"\n"}'
```

### The Three Classes

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Guaranteed                                                               │
│   EVERY container (including init containers) has:                       │
│     - a CPU request AND a CPU limit, and they are EQUAL                  │
│     - a memory request AND a memory limit, and they are EQUAL            │
│   Note: if you set only limits, Kubernetes copies them into requests,     │
│   which is a legitimate way to reach Guaranteed with less YAML.          │
├──────────────────────────────────────────────────────────────────────────┤
│ Burstable                                                                │
│   NOT Guaranteed, AND at least one container in the Pod has at least     │
│   one request or limit for CPU or memory.                                │
│   This is where the overwhelming majority of real Pods land.             │
├──────────────────────────────────────────────────────────────────────────┤
│ BestEffort                                                               │
│   NO container in the Pod sets ANY request or limit for CPU or memory.   │
│   One single request anywhere in the Pod disqualifies it.                │
└──────────────────────────────────────────────────────────────────────────┘
```

### Worked Classifications

```yaml
# GUARANTEED: requests equal limits for both resources, in every container.
spec:
  containers:
    - name: app
      resources:
        requests: { cpu: "1", memory: "1Gi" }
        limits:   { cpu: "1", memory: "1Gi" }
```

```yaml
# GUARANTEED: limits only. The defaulting step copies limits into requests.
spec:
  containers:
    - name: app
      resources:
        limits:   { cpu: "1", memory: "1Gi" }
```

```yaml
# BURSTABLE: memory matches but CPU does not.
spec:
  containers:
    - name: app
      resources:
        requests: { cpu: "500m", memory: "1Gi" }
        limits:   { cpu: "2",    memory: "1Gi" }
```

```yaml
# BURSTABLE: the first container would be Guaranteed on its own, but the
# sidecar has no resources at all, so the whole Pod drops to Burstable.
spec:
  containers:
    - name: app
      resources:
        requests: { cpu: "1", memory: "1Gi" }
        limits:   { cpu: "1", memory: "1Gi" }
    - name: log-shipper
      # no resources block at all
```

```yaml
# BURSTABLE, not Guaranteed: ephemeral-storage and other resources do not
# participate in the QoS calculation, but an unmatched CPU/memory pair does.
spec:
  containers:
    - name: app
      resources:
        requests: { cpu: "1", memory: "1Gi", ephemeral-storage: "1Gi" }
        limits:   { cpu: "1", memory: "1Gi", ephemeral-storage: "4Gi" }
# This one IS Guaranteed: only cpu and memory are considered.
```

```yaml
# BESTEFFORT: nothing anywhere.
spec:
  containers:
    - name: app
      image: busybox
```

| | Guaranteed | Burstable | BestEffort |
|---|-----------|-----------|------------|
| CPU request | Set, equals limit | Any | None |
| Memory request | Set, equals limit | Any | None |
| Can burst above request? | No, it is already at the limit | Yes, up to the limit or the node | Yes, until the node is exhausted |
| `oom_score_adj` | **-997** | Computed, between 2 and 999 | **1000** |
| Evicted under memory pressure | Last | Middle | **First** |
| Eligible for exclusive CPUs (static CPU manager policy) | Yes, with integer CPU values | No | No |
| Typical use | Databases, latency critical services, anything stateful | Almost everything | Throwaway jobs, and honestly almost nothing in production |

### QoS and the OOM Score

When the **node** runs out of memory globally, the kernel OOM killer chooses a victim by `oom_score`, which the kubelet biases per container using `oom_score_adj`.

```
Guaranteed   : oom_score_adj = -997     (nearly immune; only kernel and
                                         critical daemons score lower)
BestEffort   : oom_score_adj = 1000     (first to die, always)
Burstable    : oom_score_adj = 1000 - (1000 * memoryRequest / nodeMemoryCapacity)
               clamped into the range [2, 999]

Worked example, node with 8 GiB of memory:
  request 4Gi  -> 1000 - (1000 * 4/8)   = 500
  request 1Gi  -> 1000 - (1000 * 1/8)   = 875
  request 16Mi -> 1000 - (1000 * 0.002) = 998
  request 8Gi  -> 1000 - 1000 = 0, clamped up to 2
```

The design intent is elegant: **a Burstable container that asked for more memory is proportionally more protected**. A container that requested almost nothing is treated almost like BestEffort.

```bash
# Read it for a running container
kubectl exec my-pod -- cat /proc/1/oom_score_adj
kubectl exec my-pod -- cat /proc/1/oom_score
```

> ⚠️ Note the difference between the **cgroup OOM killer** (a container exceeded its own `memory.max`, only that container's processes are candidates, `oom_score_adj` is irrelevant across containers) and the **node OOM killer** (the machine is out of memory, every process on the node is a candidate, `oom_score_adj` decides). A Guaranteed Pod is nearly immune to the second and completely exposed to the first.

---

## Node Allocatable

Not all of a node's memory and CPU is available to Pods. The kubelet carves the machine up.

```
┌────────────────────────────────────────────────────────────────────────┐
│                     node.status.capacity                               │
│                    (what the machine has)                              │
├─────────────┬────────────────┬─────────────────┬───────────────────────┤
│ kube-       │ system-        │ eviction-hard   │  node.status.         │
│ reserved    │ reserved       │ threshold       │  allocatable          │
│             │                │                 │                       │
│ kubelet,    │ sshd, systemd, │ headroom kept   │  everything the       │
│ container   │ kernel,        │ free so the     │  scheduler is         │
│ runtime,    │ udev, agents   │ kubelet can act │  allowed to give      │
│ node        │ outside        │ before the      │  to Pods              │
│ problem     │ Kubernetes     │ kernel OOM      │                       │
│ detector    │                │ killer does     │                       │
└─────────────┴────────────────┴─────────────────┴───────────────────────┘

allocatable = capacity - kube-reserved - system-reserved - eviction-hard
```

### Configuration

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
  pid: "1000"

systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
  pid: "1000"

evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"

# Which slices are actually CAPPED with a cgroup, as opposed to merely
# being subtracted from allocatable on paper.
enforceNodeAllocatable: ["pods"]

# Only needed when enforcing the reserved slices too.
kubeReservedCgroup: "/kube.slice"
systemReservedCgroup: "/system.slice"
```

The equivalent legacy command line flags are `--kube-reserved`, `--system-reserved`, `--eviction-hard`, `--enforce-node-allocatable`, `--kube-reserved-cgroup` and `--system-reserved-cgroup`. Modern clusters configure them in the kubelet configuration file.

### Worked Arithmetic

```
Machine: 8 vCPU, 32 GiB RAM, 200 GiB disk

capacity:
  cpu                 8
  memory              32Gi   (33554432Ki, minus a little firmware reserve)
  ephemeral-storage   200Gi

kubeReserved:        cpu 500m,  memory 1Gi,  ephemeral-storage 2Gi
systemReserved:      cpu 500m,  memory 1Gi,  ephemeral-storage 2Gi
evictionHard:        memory.available 500Mi, nodefs.available 10% (20Gi)

allocatable.cpu     = 8    - 0.5  - 0.5           = 7
allocatable.memory  = 32Gi - 1Gi  - 1Gi  - 500Mi  = 29.5Gi
allocatable.storage = 200Gi - 2Gi - 2Gi  - 20Gi   = 176Gi

The scheduler will pack Pod requests up to 7 CPU and 29.5Gi of memory
on this node, and not one millicore more.
```

```bash
kubectl get node worker-1 -o jsonpath='{.status.capacity}{"\n"}' | python3 -m json.tool
kubectl get node worker-1 -o jsonpath='{.status.allocatable}{"\n"}' | python3 -m json.tool
kubectl describe node worker-1 | sed -n '/^Capacity:/,/^System Info/p'
```

### enforceNodeAllocatable

| Value | Effect |
|-------|--------|
| `pods` (default) | A cgroup limit is applied to the whole `kubepods` slice, so **all Pods together** cannot exceed allocatable. This is the mechanism that actually protects the system daemons |
| `kube-reserved` | Cap the kubelet and runtime slice at `kubeReserved`. Requires `kubeReservedCgroup` |
| `system-reserved` | Cap the system slice at `systemReserved`. Requires `systemReservedCgroup` |
| `none` (empty list) | Reservations are subtracted from allocatable for the scheduler, but nothing is capped by a cgroup |

> ⚠️ Enforcing `system-reserved` is risky: if the value is too low, the kernel OOM killer starts killing `sshd` and `systemd` units, and you lose the node entirely. Enforce `pods` (the default), reserve generously, and leave the other two unenforced unless you have measured the system slice carefully.

### Two Warnings About Reservations

1. **Under reserving is the default failure.** A node with no `kubeReserved` and no `systemReserved` will happily schedule Pods into memory the kubelet needs, and the first symptom is the kubelet itself becoming unresponsive, which turns the node `NotReady` and triggers a cascade.
2. **Changing reservations shrinks allocatable**, which can instantly make already running Pods "over committed" relative to the new allocatable. Kubernetes does not evict them, but the node becomes a scheduling dead end until enough Pods leave.

> 📖 The `kubepods.slice` cgroup hierarchy that implements all of this, including the `kubepods-burstable.slice` and `kubepods-besteffort.slice` children, is walked through in [cgroups.md](cgroups.md).

---

## Node Pressure Eviction

When a node runs low on a resource, the **kubelet** proactively evicts Pods rather than letting the kernel make a random decision. This is a completely different mechanism from scheduler preemption and from the Eviction API.

### Eviction Signals

| Signal | Meaning | Node condition it sets |
|--------|---------|------------------------|
| `memory.available` | Memory available on the node | `MemoryPressure` |
| `nodefs.available` | Free space on the kubelet root filesystem, which holds `emptyDir` volumes and logs | `DiskPressure` |
| `nodefs.inodesFree` | Free inodes on the kubelet root filesystem | `DiskPressure` |
| `imagefs.available` | Free space on the filesystem holding container images and writable layers | `DiskPressure` |
| `imagefs.inodesFree` | Free inodes on the image filesystem | `DiskPressure` |
| `pid.available` | Available process IDs | `PIDPressure` |

Thresholds may be absolute quantities (`500Mi`) or percentages (`10%`) of the corresponding total.

### Hard versus Soft

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# HARD: crossing the threshold triggers IMMEDIATE eviction with NO grace
# period. The Pod is killed with grace period 0.
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"

# SOFT: the threshold must be exceeded continuously for the grace period
# before anything is evicted, and then the Pod gets a graceful shutdown.
evictionSoft:
  memory.available: "1Gi"
  nodefs.available: "15%"
evictionSoftGracePeriod:
  memory.available: "1m30s"
  nodefs.available: "2m"

# Cap on the graceful termination given to a Pod evicted by a SOFT threshold.
# The Pod's own terminationGracePeriodSeconds is capped at this value.
evictionMaxPodGracePeriod: 60

# How much must be reclaimed beyond the threshold before pressure is cleared,
# so the kubelet does not oscillate around the line.
evictionMinimumReclaim:
  memory.available: "0Mi"
  nodefs.available: "500Mi"

# The node condition is kept for at least this long after pressure clears,
# to avoid flapping. Default 5m.
evictionPressureTransitionPeriod: "5m"
```

| | Hard threshold | Soft threshold |
|---|---------------|----------------|
| Grace period before acting | None | `evictionSoftGracePeriod` per signal |
| Pod termination grace | **Zero**, immediate SIGKILL | Up to `evictionMaxPodGracePeriod` |
| Configured by | `evictionHard` | `evictionSoft` plus `evictionSoftGracePeriod` |
| Subtracted from allocatable | **Yes** | No |
| Typical use | Last line of defence | Early, polite reaction |

The documented defaults on Linux, when you configure nothing, are `memory.available<100Mi`, `nodefs.available<10%`, `nodefs.inodesFree<5%` and `imagefs.available<15%`, with no soft thresholds at all.

### How the kubelet Picks Victims

```
Memory pressure. The kubelet ranks Pods, worst first:

  1. Is the Pod's memory usage ABOVE its memory request?
        Pods over their request are always evicted before Pods under it.
        A BestEffort Pod is over its request (of zero) by definition.

  2. Among Pods in the same over/under group: Pod PRIORITY, lowest first.
        spec.priority from the PriorityClass. This is where a
        system-cluster-critical Pod earns its protection.

  3. Among equal priority: how much memory the Pod is using ABOVE its
     request, largest excess first.

Effective ordering in practice:

  BestEffort (always over request)
        ▼
  Burstable using more than it requested, low priority, biggest overshoot
        ▼
  Burstable using more than it requested, higher priority
        ▼
  Burstable using LESS than it requested
        ▼
  Guaranteed (usage can never exceed request, since request == limit)
```

Disk pressure follows the same shape but ranks on local ephemeral storage usage relative to requests, and the kubelet first tries to reclaim without evicting anything, by garbage collecting dead containers and unused images.

### The Result of an Eviction

```bash
kubectl get pods
# NAME        READY   STATUS    RESTARTS   AGE
# hungry-1    0/1     Evicted   0          4m

kubectl describe pod hungry-1
# Status:   Failed
# Reason:   Evicted
# Message:  The node was low on resource: memory. Container app was using
#           1250Mi, which exceeds its request of 512Mi.
```

| Property | Behaviour |
|----------|-----------|
| Pod phase | `Failed` with `reason: Evicted` |
| PodDisruptionBudgets | **Ignored completely**. This is not a voluntary disruption |
| The Pod object | Remains on the node as a tombstone until garbage collected or deleted |
| Replacement | Created by the owning controller, and it will not be scheduled back to a node under pressure because of the pressure taint |
| Node condition | `MemoryPressure`, `DiskPressure` or `PIDPressure` set to `True` |
| Node taint | `node.kubernetes.io/memory-pressure`, `node.kubernetes.io/disk-pressure` or `node.kubernetes.io/pid-pressure`, with effect `NoSchedule` |

```bash
# Clean up the tombstones
kubectl get pods -A --field-selector status.phase=Failed
kubectl delete pods -A --field-selector status.phase=Failed

# Check node conditions and pressure taints
kubectl get nodes -o custom-columns='NAME:.metadata.name,CONDITIONS:.status.conditions[?(@.status=="True")].type'
kubectl describe node worker-1 | grep -A8 Conditions
```

> 📖 The pressure taints and how Pods tolerate them are covered in [scheduling.md](scheduling.md).

---

## LimitRange

`LimitRange` is a **namespace scoped admission time** policy. It injects defaults into Pods that omit resources, and rejects Pods whose values fall outside a permitted band.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: resource-policy
  namespace: team-a
spec:
  limits:
    # ---------------------------------------------------------------- #
    # Per CONTAINER rules. This is the type that supports defaulting.   #
    # ---------------------------------------------------------------- #
    - type: Container
      # Injected as limits when a container specifies none.
      default:
        cpu: "500m"
        memory: "512Mi"
        ephemeral-storage: "1Gi"
      # Injected as requests when a container specifies none.
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
        ephemeral-storage: "256Mi"
      # A container may not request less than this.
      min:
        cpu: "50m"
        memory: "64Mi"
      # A container's limit may not exceed this.
      max:
        cpu: "4"
        memory: "8Gi"
      # limit / request may not exceed this ratio, per resource.
      # cpu 4 means a container requesting 250m may not have a limit above 1.
      maxLimitRequestRatio:
        cpu: "4"
        memory: "2"

    # ---------------------------------------------------------------- #
    # Per POD rules: the SUM across all containers in one Pod.          #
    # NOTE: the Pod type supports only min, max and                     #
    # maxLimitRequestRatio. There is NO default or defaultRequest here. #
    # ---------------------------------------------------------------- #
    - type: Pod
      min:
        cpu: "100m"
        memory: "128Mi"
      max:
        cpu: "8"
        memory: "16Gi"
      maxLimitRequestRatio:
        cpu: "8"

    # ---------------------------------------------------------------- #
    # Per PVC rules, applied to spec.resources.requests.storage.        #
    # ---------------------------------------------------------------- #
    - type: PersistentVolumeClaim
      min:
        storage: "1Gi"
      max:
        storage: "100Gi"
```

### The Defaulting Algorithm

```
For each container, at admission time:

  1. If the container has NO limit for resource R:
         limit[R] = LimitRange.default[R]           (if defined)

  2. If the container has NO request for resource R:
         request[R] = LimitRange.defaultRequest[R]  (if defined)
     ...UNLESS the container has an explicit limit for R and no
        defaultRequest is defined, in which case:
         request[R] = limit[R]

  3. Validate min <= request, limit <= max, limit/request <= maxLimitRequestRatio
     for every resource, at both Container and Pod scope.
     A single violation REJECTS the whole Pod.
```

```bash
# The Pod as written
kubectl -n team-a run demo --image=nginx:1.27
# The Pod as stored, after LimitRange defaulting
kubectl -n team-a get pod demo -o jsonpath='{.spec.containers[0].resources}{"\n"}'
# {"limits":{"cpu":"500m","ephemeral-storage":"1Gi","memory":"512Mi"},
#  "requests":{"cpu":"100m","ephemeral-storage":"256Mi","memory":"128Mi"}}

kubectl -n team-a describe limitrange resource-policy
```

### Behaviour Notes

| Question | Answer |
|----------|--------|
| Does it apply to existing Pods? | **No.** It is admission time only. Pods created before the LimitRange keep their values |
| Multiple LimitRanges in one namespace? | Allowed, but defaulting becomes order dependent and hard to reason about. Use exactly one |
| Does it stop a Pod from having no resources? | Only if you set `min`, or rely on `defaultRequest` to fill them in |
| Does it interact with ResourceQuota? | Yes, and this is the point: a quota that requires requests is unusable without a LimitRange to supply defaults |
| Namespace or cluster scoped? | Namespace |

---

## ResourceQuota

`ResourceQuota` caps the **aggregate** consumption of a namespace. Where a LimitRange constrains one object, a quota constrains the sum of all of them.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:
    # ---------------- compute ----------------
    requests.cpu: "20"
    requests.memory: "40Gi"
    limits.cpu: "40"
    limits.memory: "80Gi"
    requests.ephemeral-storage: "100Gi"
    limits.ephemeral-storage: "200Gi"
    # Extended resources use the requests. prefix and nothing else.
    requests.nvidia.com/gpu: "4"

    # ---------------- storage ----------------
    requests.storage: "500Gi"
    persistentvolumeclaims: "20"
    # Per StorageClass storage and claim caps.
    fast-ssd.storageclass.storage.k8s.io/requests.storage: "200Gi"
    fast-ssd.storageclass.storage.k8s.io/persistentvolumeclaims: "5"

    # ------------- object counts -------------
    pods: "100"
    services: "20"
    services.loadbalancers: "2"
    services.nodeports: "5"
    secrets: "50"
    configmaps: "50"
    replicationcontrollers: "20"
    # The generic count/ syntax works for any resource, including CRDs.
    count/deployments.apps: "30"
    count/statefulsets.apps: "10"
    count/jobs.batch: "50"
    count/cronjobs.batch: "20"
    count/ingresses.networking.k8s.io: "10"
```

### The Rule Everyone Learns the Hard Way

> ⚠️ **Once a quota constrains `requests.cpu` or `limits.memory` (or any other compute resource), every new Pod in that namespace must set the corresponding value.** A Pod that omits it is rejected at admission with a message like `must specify limits.memory`.

```bash
kubectl -n team-a run nores --image=nginx:1.27
# Error from server (Forbidden): pods "nores" is forbidden: failed quota:
# team-a-quota: must specify limits.cpu,limits.memory,requests.cpu,requests.memory
```

The fix is not to loosen the quota. The fix is a `LimitRange` in the same namespace supplying `default` and `defaultRequest`, so bare Pods get values automatically and pass the quota check. **LimitRange and ResourceQuota are designed to be deployed together.**

### Scopes

A scope restricts which Pods the quota counts.

| Scope | Matches |
|-------|---------|
| `Terminating` | Pods with `spec.activeDeadlineSeconds` set, that is Job style workloads with a deadline |
| `NotTerminating` | Pods with no `activeDeadlineSeconds`, that is long running services |
| `BestEffort` | Pods in the BestEffort QoS class |
| `NotBestEffort` | Pods in the Burstable or Guaranteed classes |
| `PriorityClass` | Pods matching a `scopeSelector` on their priority class name |
| `CrossNamespacePodAffinity` | Pods using cross namespace Pod affinity terms |

```yaml
# Batch jobs get a small, separate budget from long running services.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: batch-quota
  namespace: team-a
spec:
  hard:
    requests.cpu: "10"
    requests.memory: "20Gi"
    pods: "50"
  scopes:
    - Terminating
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: services-quota
  namespace: team-a
spec:
  hard:
    requests.cpu: "20"
    requests.memory: "40Gi"
  scopes:
    - NotTerminating
    - NotBestEffort
```

```yaml
# scopeSelector is the only way to scope on PriorityClass, and it is also
# the mechanism that gates use of system-cluster-critical outside kube-system.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: high-priority-budget
  namespace: team-a
spec:
  hard:
    pods: "5"
    requests.cpu: "8"
    requests.memory: "16Gi"
  scopeSelector:
    matchExpressions:
      - scopeName: PriorityClass
        operator: In
        values: ["high-priority", "system-cluster-critical"]
```

`scopeSelector` operators are `In`, `NotIn`, `Exists` and `DoesNotExist`. Only the `PriorityClass` scope uses `values`; the others are used with `Exists`.

> ⚠️ `BestEffort` and `Terminating` scopes may only constrain object counts and, for `Terminating`, compute resources. Combining a `BestEffort` scope with `requests.cpu` is rejected, because a BestEffort Pod has no requests by definition.

### Reading Usage

```bash
kubectl -n team-a get resourcequota
# NAME           AGE   REQUEST                                      LIMIT
# team-a-quota   3d    requests.cpu: 12/20, requests.memory: 22Gi/40Gi   limits.cpu: 25/40

kubectl -n team-a describe resourcequota team-a-quota
# Name:              team-a-quota
# Namespace:         team-a
# Resource           Used    Hard
# --------           ----    ----
# count/deployments.apps  11   30
# limits.cpu              25   40
# limits.memory           44Gi 80Gi
# persistentvolumeclaims  7    20
# pods                    43   100
# requests.cpu            12   20
# requests.memory         22Gi 40Gi

# Machine readable
kubectl -n team-a get resourcequota team-a-quota -o jsonpath='{.status}{"\n"}' | python3 -m json.tool
```

`status.used` is maintained by the quota controller in kube-controller-manager and is recomputed periodically as well as on each admission, so a brief lag between deleting Pods and seeing usage drop is normal.

### Quota Behaviour Notes

| Question | Answer |
|----------|--------|
| Does a quota affect existing objects? | No. It only rejects **new** objects. Exceeding a quota by lowering it leaves everything running |
| Multiple quotas in one namespace? | Yes, and **all** of them must be satisfied. Scoped quotas are the intended way to use several |
| What about Pods that terminate? | Terminated Pods (`Succeeded`, `Failed`) do not count against compute quota, but their Pod objects still count against a `pods` object count quota until deleted |
| Who can bypass it? | Nobody through the normal API path. Quota is enforced by an admission controller in the API server |
| Does it constrain node capacity? | No. A quota is an accounting cap, and you can grant a namespace far more quota than the cluster physically has |

---

## Right Sizing Methodology

### Step 1: Measure What Is Actually Happening

```bash
# Requires metrics-server. Instantaneous, from the last scrape.
kubectl top nodes
kubectl top pods -n team-a
kubectl top pods -n team-a --containers --sort-by=memory
kubectl top pod my-pod --containers
```

`kubectl top` is a snapshot from a short sliding window. It is enough to catch an obviously wrong number and useless for sizing a bursty workload, because it will never show you the peak you missed.

### Step 2: Get History

```promql
# Peak memory over a week, per container. Memory should be sized on the PEAK,
# because exceeding it is fatal.
max_over_time(
  container_memory_working_set_bytes{namespace="team-a", container!=""}[7d]
)

# 95th percentile CPU over a week. CPU can be sized on a high percentile,
# because exceeding it is only slow.
quantile_over_time(0.95,
  rate(container_cpu_usage_seconds_total{namespace="team-a", container!=""}[5m])[7d:5m]
)

# Requests versus actual usage, the waste ratio
sum(kube_pod_container_resource_requests{resource="cpu"}) by (namespace)
  /
sum(rate(container_cpu_usage_seconds_total[5m])) by (namespace)

# Throttling, the signal that a CPU limit is too low
sum(rate(container_cpu_cfs_throttled_periods_total[5m])) by (pod)
  /
sum(rate(container_cpu_cfs_periods_total[5m])) by (pod)
```

> 🔑 Use `container_memory_working_set_bytes`, not `container_memory_usage_bytes`. The working set excludes reclaimable page cache and is the number the kubelet itself uses for eviction decisions. Sizing against `usage_bytes` will make every container look far larger than it is.

### Step 3: Let VPA Recommend, Without Letting It Act

The Vertical Pod Autoscaler is a separate project from the Kubernetes autoscaler repository. Its most valuable mode is the one that changes nothing.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: web-vpa
  namespace: team-a
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  updatePolicy:
    # "Off" means: observe, compute recommendations, change nothing.
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
      - containerName: "*"
        minAllowed:
          cpu: "50m"
          memory: "64Mi"
        maxAllowed:
          cpu: "4"
          memory: "8Gi"
        controlledResources: ["cpu", "memory"]
```

```bash
kubectl -n team-a describe vpa web-vpa
# Recommendation:
#   Container Recommendations:
#     Container Name:  web
#     Lower Bound:     cpu: 120m,  memory: 262144k
#     Target:          cpu: 350m,  memory: 419430k
#     Uncapped Target: cpu: 350m,  memory: 419430k
#     Upper Bound:     cpu: 1200m, memory: 1073741824
```

| VPA field | Meaning |
|-----------|---------|
| `Target` | The recommendation. Use this as your request |
| `Lower Bound` | Below this, the container will probably be starved |
| `Upper Bound` | Above this is certainly waste |
| `Uncapped Target` | What VPA would recommend ignoring your `maxAllowed` |

| `updateMode` | Behaviour |
|--------------|-----------|
| `Off` | Recommendations only. **Start here, and often stay here** |
| `Initial` | Apply recommendations to newly created Pods only |
| `Recreate` | Evict and recreate Pods to apply new values |
| `Auto` | Currently behaves like `Recreate`; intended to use in place resize as that matures |

> ⚠️ **Do not run VPA and HPA on the same resource for the same workload.** HPA scaling out on CPU while VPA raises the CPU request produces oscillation. HPA on a custom metric plus VPA on memory is a workable combination.

### Step 4: Apply the Heuristics

| Resource | Set request to | Set limit to |
|----------|----------------|--------------|
| **Memory** | The observed peak working set, plus roughly 20 to 30 percent headroom | The same as the request, or slightly above. Being killed is worse than being denied a burst |
| **CPU** | The p95 of observed usage, or the steady state average for bursty services | Generously above the peak, or omit entirely for trusted latency sensitive services |
| **ephemeral-storage** | Measured log and scratch usage | Two to three times the request |

```
Anti pattern gallery

  requests.cpu: 2000m for a service that idles at 30m
      → 66 nodes worth of phantom capacity across 100 replicas.
        The cluster autoscaler buys machines for nothing.

  limits.memory: 128Mi for a JVM with default heap sizing
      → the JVM sizes its heap from the container limit if it is
        container aware, or from the HOST memory if it is not.
        Either way, OOMKilled during the first garbage collection.

  No requests at all in production
      → BestEffort QoS, first evicted, no scheduling guarantee,
        and invisible in every capacity report.

  requests == limits everywhere, at the observed peak
      → Guaranteed QoS, but the cluster is sized for simultaneous peaks
        that never actually coincide. Extremely expensive.
```

---

## In Place Pod Resize

Historically, changing a container's CPU or memory required replacing the Pod, because `spec.containers[].resources` was immutable. Kubernetes has been adding the ability to change some resources on a **running** container without a restart.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: resizable
spec:
  containers:
    - name: app
      image: nginx:1.27
      resizePolicy:
        # NotRequired: apply the new value to the running container.
        - resourceName: cpu
          restartPolicy: NotRequired
        # RestartContainer: restart the container to apply the new value.
        # Many runtimes and applications cannot cope with a memory limit
        # shrinking underneath them, so this is the conservative choice.
        - resourceName: memory
          restartPolicy: RestartContainer
      resources:
        requests: { cpu: "250m", memory: "256Mi" }
        limits:   { cpu: "500m", memory: "512Mi" }
```

The shape of the feature:

- Changes are made through a dedicated **`resize` subresource** of the Pod, not by a plain update of the Pod spec.
- `resizePolicy` is declared per resource, with `NotRequired` (patch the cgroup live) or `RestartContainer` (restart to apply).
- The Pod's `status` reports progress, so a resize that the node cannot satisfy is visible as pending rather than silently dropped.
- The QoS class of a Pod is **not** allowed to change as a result of a resize.
- CPU, being compressible, resizes far more comfortably than memory. Shrinking a memory limit below current usage is inherently dangerous.

> ⚠️ Availability, feature gate status and exact semantics have changed across releases. Check the documentation for **your** cluster version before designing around it, and confirm behaviour on a test cluster. Treat this section as conceptual.

```bash
# Whether your cluster exposes the subresource at all
kubectl api-resources --api-group='' -o wide | grep -i '^pods'
kubectl explain pod.spec.containers.resizePolicy
```

---

## Extended Resources and Device Plugins

Beyond `cpu`, `memory`, `ephemeral-storage` and `hugepages-*`, a node can advertise arbitrary countable resources.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-job
spec:
  restartPolicy: Never
  containers:
    - name: cuda
      image: nvidia/cuda:12.2.0-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        limits:
          # Integer only. Requests are set equal to limits automatically.
          nvidia.com/gpu: 2
```

### How They Differ From CPU and Memory

| Property | `cpu` and `memory` | Extended resources |
|----------|--------------------|--------------------|
| Fractional values | Yes (`250m`, `1.5Gi`) | **No**, integers only |
| Request different from limit | Yes | **No**, they must be equal (specifying only the limit is the idiom) |
| Overcommit | Yes, limits may exceed capacity across Pods | **No**, never |
| Enforced by | cgroups | The device plugin and the runtime, by handing over specific devices |
| Affects QoS class | Yes | No |
| Quota syntax | `requests.cpu`, `limits.cpu` | `requests.<name>` only |
| Advertised by | The kubelet from machine introspection | A device plugin, or a manual patch of `node.status.capacity` |

### Advertising a Resource Manually

```bash
# Extended resources on the node object must live under a domain prefix.
kubectl proxy --port=8001 &
curl -s --header "Content-Type: application/json-patch+json" \
  --request PATCH \
  --data '[{"op":"add","path":"/status/capacity/example.com~1dongle","value":"4"}]' \
  http://localhost:8001/api/v1/nodes/worker-1/status
# Note ~1 is the JSON Patch escape for a literal "/" inside the path.

kubectl get node worker-1 -o jsonpath='{.status.capacity}{"\n"}' | python3 -m json.tool
```

### Device Plugins

A device plugin is a DaemonSet that registers with the kubelet over a gRPC socket in `/var/lib/kubelet/device-plugins/` and then:

```
┌──────────────┐   1. register over kubelet.sock   ┌──────────────┐
│    device    │ ────────────────────────────────► │   kubelet    │
│    plugin    │                                   │              │
│  (DaemonSet) │   2. ListAndWatch: here are my    │              │
│              │      healthy device IDs           │              │
│              │ ────────────────────────────────► │              │
│              │                                   │              │
│              │   3. Allocate(deviceIDs):         │              │
│              │      returns device nodes, mounts │              │
│              │      and env vars for the runtime │              │
│              │ ◄──────────────────────────────── │              │
└──────────────┘                                   └──────┬───────┘
                                                          │
                          4. kubelet reports the resource │
                             in node.status.capacity      ▼
                                                   ┌──────────────┐
                                                   │  API server  │
                                                   └──────────────┘
```

```bash
# Is the plugin healthy?
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

# Which Pods are holding GPUs?
kubectl get pods -A -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    for c in p["spec"]["containers"]:
        g = c.get("resources",{}).get("limits",{}).get("nvidia.com/gpu")
        if g: print(p["metadata"]["namespace"], p["metadata"]["name"], c["name"], g)
'
```

> ⚠️ If the device plugin DaemonSet is not running, the node advertises **zero** of the resource, and every Pod requesting it stays `Pending` with `Insufficient nvidia.com/gpu`. That is the first thing to check, before suspecting the scheduler.

---

## Troubleshooting

### OOMKilled

```bash
kubectl describe pod app | sed -n '/Last State/,/Ready/p'
#   Last State:     Terminated
#     Reason:       OOMKilled
#     Exit Code:    137
kubectl logs app --previous          # the logs of the killed container
```

| Check | Command or evidence | Meaning |
|-------|---------------------|---------|
| Is the limit simply too low? | Compare `limits.memory` with `max_over_time(container_memory_working_set_bytes[7d])` | Raise the limit |
| Is it a leak? | Working set climbing monotonically between restarts | Fix the application; a higher limit only delays the crash |
| Is it a runtime heap misconfiguration? | JVM without container aware heap sizing, Node.js without `--max-old-space-size`, Go without `GOMEMLIMIT` | The runtime sized itself from host memory, not the limit |
| Was it the container or the node? | `reason: OOMKilled` on the container versus `dmesg -T \| grep -i oom` on the node | Container cgroup OOM versus node level OOM |
| Which process died? | Container status shows the container; `dmesg` names the process | If a child died but PID 1 survived, the container keeps running while silently broken |

```yaml
# Size the runtime from the limit, not from the host.
        env:
          - name: MEMORY_LIMIT
            valueFrom:
              resourceFieldRef:
                containerName: app
                resource: limits.memory
                divisor: 1Mi
          - name: JAVA_TOOL_OPTIONS
            value: "-XX:MaxRAMPercentage=70.0"
```

> 📖 The `resourceFieldRef` mechanism, its `divisor` behaviour and the trap where an unset limit reports the node's allocatable are covered in [downward-api.md](downward-api.md).

### CPU Throttling

```bash
# Symptom: latency is bad, kubectl top shows usage well under the limit.
kubectl top pod app --containers
kubectl exec app -- cat /sys/fs/cgroup/cpu.stat        # cgroup v2
kubectl exec app -- cat /sys/fs/cgroup/cpu/cpu.stat    # cgroup v1
```

If `nr_throttled / nr_periods` is materially above zero, raise `limits.cpu` or remove it. Do not raise the replica count first: more replicas each with the same tight limit reproduce the same throttling per replica.

### Evicted Pods

```bash
kubectl get pods -A --field-selector status.phase=Failed
kubectl describe pod evicted-one | grep -A3 Message
# The node was low on resource: ephemeral-storage. Container app was using
# 5Gi, which exceeds its request of 1Gi.
```

| Message names | Real cause | Fix |
|---------------|------------|-----|
| `memory` | The node crossed a memory eviction threshold | Raise requests so the Pod ranks better, raise node reservations, or add capacity |
| `ephemeral-storage` | Logs, `emptyDir` or the writable layer grew | Set a limit, rotate logs, use a PersistentVolume for real data |
| `nodefs` or `imagefs` | The node's disks filled | Image garbage collection, larger disks, prune unused images |
| `pids` | Process explosion, often a fork bomb or a leaking subprocess | Set `pid` reservations and investigate the app |

### Quota Rejections

```bash
kubectl -n team-a describe resourcequota
kubectl -n team-a get events --field-selector reason=FailedCreate

# A Deployment whose Pods are rejected shows nothing at the Pod level,
# because the Pods were never created. Look at the ReplicaSet.
kubectl -n team-a describe replicaset web-7d9f8c
#   Warning  FailedCreate  ...  Error creating: pods "web-..." is forbidden:
#   exceeded quota: team-a-quota, requested: requests.cpu=2,
#   used: requests.cpu=19, limited: requests.cpu=20
```

> 🔑 A quota rejection at the ReplicaSet level is invisible with `kubectl get pods`, because no Pod object exists. Always look at the controller's events when replicas simply do not appear.

### Pending Due to Insufficient Resources

```bash
kubectl describe pod pending-one | tail -5
# 0/5 nodes are available: 5 Insufficient memory.

# Where has the memory gone? Requests, not usage.
kubectl describe node worker-1 | sed -n '/Allocated resources/,/^Events/p'

# The biggest requesters in the cluster
kubectl get pods -A -o json | python3 -c '
import json,sys
rows=[]
for p in json.load(sys.stdin)["items"]:
    for c in p["spec"]["containers"]:
        r=c.get("resources",{}).get("requests",{})
        if r.get("memory"): rows.append((r["memory"], p["metadata"]["namespace"], p["metadata"]["name"]))
for r in sorted(rows, reverse=True)[:15]: print(r)
'
```

| Situation | Action |
|-----------|--------|
| Requests are far above real usage | Right size. This is the most common cause by a wide margin |
| Requests are honest, the cluster is full | Add nodes, or use a PriorityClass so this Pod preempts less important work |
| One huge Pod does not fit any node | Shard the workload, or add a larger node. The scheduler cannot split a Pod |
| Only some nodes are full | Check for a `nodeSelector`, affinity or taint restricting the Pod to those nodes |

---

## Exam and Interview Traps

1. **The scheduler uses requests only.** It never reads limits and never reads actual usage. A quiet node can still say `Insufficient cpu`.
2. **`requests.memory` reserves nothing at runtime.** There is no cgroup field for it. It only drives scheduling, QoS, `oom_score_adj` and eviction ranking.
3. **`requests.cpu` becomes `cpu.shares` or `cpu.weight`**, which matters only when the CPU is contended. On an idle node a container can exceed its request freely.
4. **CPU limits throttle, memory limits kill.** Compressible versus incompressible is the whole explanation.
5. **`memory: 400m` means 0.4 bytes.** It is accepted and it will destroy the Pod. Write `400Mi`.
6. **`1G` is not `1Gi`.** The difference is about 7 percent, which is exactly enough to OOM a carefully tuned JVM.
7. **QoS is computed, not declared**, and it is a **Pod** level property derived from **every** container, including init containers.
8. **One resourceless sidecar drops a Guaranteed Pod to Burstable.**
9. **Setting only limits produces Guaranteed**, because requests are defaulted to equal the limits.
10. **Only `cpu` and `memory` count for QoS.** Mismatched `ephemeral-storage` values do not prevent Guaranteed.
11. **`oom_score_adj` is -997 for Guaranteed and 1000 for BestEffort**, with Burstable computed from the memory request as a fraction of node capacity, clamped to the range 2 to 999.
12. **Allocatable equals capacity minus kube-reserved minus system-reserved minus the hard eviction threshold.** Soft thresholds are not subtracted.
13. **`enforceNodeAllocatable` defaults to `["pods"]`**, so the reserved slices are subtracted on paper but only the Pods slice is actually capped by a cgroup.
14. **Node pressure eviction ignores PodDisruptionBudgets** entirely. It is an involuntary disruption.
15. **Hard eviction gives zero grace period.** Soft eviction gives a grace period capped by `evictionMaxPodGracePeriod`.
16. **BestEffort Pods are evicted first** because their usage is over their request of zero by definition.
17. **An evicted Pod leaves a `Failed` tombstone object** that still consumes an object count quota until it is deleted.
18. **LimitRange defaults are applied at admission and never retroactively.** Existing Pods are untouched.
19. **The `Pod` type in a LimitRange supports only `min`, `max` and `maxLimitRequestRatio`.** There is no `default` or `defaultRequest` at Pod scope.
20. **Once a compute ResourceQuota exists, every Pod must set the matching request or limit** or be rejected. Deploy a LimitRange alongside it.
21. **A quota never touches existing objects**, so lowering a quota below current usage is legal and leaves everything running.
22. **All quotas in a namespace must be satisfied simultaneously.**
23. **Extended resources are integers only, cannot be overcommitted, and require request to equal limit.**
24. **Exit code 137 is SIGKILL**, which is consistent with a container OOM, a node OOM, or a hard eviction. Check `reason` before concluding.
25. **Use `container_memory_working_set_bytes`, not `container_memory_usage_bytes`**, when sizing memory; the latter includes reclaimable page cache.
26. **`kubectl top` needs metrics-server**, reports a short window, and can never show a value above a container's CPU limit, which is why it hides throttling.

---

## Related Topics

- [Cgroups](cgroups.md)
- [Scheduling](scheduling.md)
- [Pod Disruption Budgets](pod-disruption-budgets.md)
- [kube-scheduler](kube-scheduler.md)
- [kubelet](kubelet.md)
- [Pods](pods.md)
- [Pod Lifecycle](pod-lifecycle.md)
- [Pod Operations](pod-operations.md)
- [Downward API](downward-api.md)
- [Linux Namespaces](linux-namespaces.md)
- [Containers](containers.md)
- [Container Runtime](container-runtime.md)
- [Deployments](deployments.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [ConfigMaps](configmaps.md)
- [Secrets](secrets.md)
- [Controllers](controllers.md)
- [Worker Node](worker-node.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)

---

## Key Takeaways

1. **Requests are for the scheduler and for fair sharing; limits are for the kernel.** The scheduler reads only requests, never limits and never real usage, which is why a nearly idle node can legitimately refuse a Pod.
2. **`requests.cpu` becomes a cgroup weight** (`cpu.shares` in v1, `cpu.weight` in v2) and only matters under contention. `requests.memory` has no runtime enforcement whatsoever.
3. **`limits.cpu` becomes a bandwidth quota** over a 100 ms period, and the whole cgroup stops once the quota is spent. `limits.memory` becomes `memory.max`, and crossing it invokes the cgroup OOM killer.
4. **CPU is compressible, memory is not.** Exceeding a CPU limit costs latency; exceeding a memory limit costs the process. Size memory on the peak and CPU on a high percentile.
5. **Throttling is invisible in utilisation graphs**, because a throttled container can never report more than its limit. `nr_throttled / nr_periods` from `cpu.stat` is the only honest signal.
6. **Always set CPU requests; consider omitting CPU limits** for trusted latency sensitive services, since shares already provide fairness. Always set memory requests and limits, close together.
7. **Units bite.** `Mi` is 2^20 and `M` is 10^6; `1G` is roughly 7 percent smaller than `1Gi`; and `memory: 400m` silently means 0.4 bytes.
8. **QoS is derived from every container in the Pod**: Guaranteed needs matching requests and limits for both CPU and memory everywhere, Burstable is anything in between, BestEffort is nothing at all. One resourceless sidecar downgrades the whole Pod.
9. **QoS drives survival**: `oom_score_adj` is -997 for Guaranteed, 1000 for BestEffort, and proportional to the memory request for Burstable, and the kubelet evicts BestEffort first, then Burstable over its request, and Guaranteed last.
10. **Allocatable is capacity minus kube-reserved, system-reserved and the hard eviction threshold.** Under reserving is how a busy node kills its own kubelet, and `enforceNodeAllocatable` decides which of those carve outs is actually enforced by a cgroup rather than just subtracted on paper.
11. **Node pressure eviction is the kubelet acting on signals** (`memory.available`, `nodefs.available`, `nodefs.inodesFree`, `imagefs.available`, `imagefs.inodesFree`, `pid.available`); hard thresholds act immediately with no grace, soft thresholds wait out a grace period, and neither one respects PodDisruptionBudgets.
12. **Eviction sets a node condition and a matching `NoSchedule` pressure taint**, which is what stops replacements from landing straight back on the sick node.
13. **LimitRange is per object and admission time**: `default` and `defaultRequest` fill gaps, `min`, `max` and `maxLimitRequestRatio` reject outliers, and the `Pod` type supports only the validation fields, not the defaulting ones.
14. **ResourceQuota is per namespace and aggregate**, covering compute, storage, per StorageClass storage and object counts, with `scopes` and `scopeSelector` to carve out batch, BestEffort or priority specific budgets.
15. **A compute quota makes requests mandatory for every new Pod**, so a LimitRange supplying defaults is effectively a prerequisite. Deploy the two together.
16. **Quotas and LimitRanges never touch existing objects.** They only reject or mutate new ones.
17. **Right size from history, not from intuition**: peak `container_memory_working_set_bytes` for memory, the p95 of CPU rate for CPU, and VPA in `updateMode: "Off"` as a free second opinion.
18. **Extended resources such as GPUs are a different species**: integers only, request must equal limit, never overcommitted, advertised by a device plugin, and irrelevant to QoS. If the plugin DaemonSet is down, the node advertises zero.
19. **In place pod resize changes some resources without a restart**, governed by `resizePolicy` per resource and applied through the Pod `resize` subresource, but the details have moved between releases; verify against your cluster version.
20. **Cross reference the kernel layer.** Everything in this document ultimately lands in a cgroup file, and [cgroups.md](cgroups.md) is where those files, their hierarchy and their v1 versus v2 differences are explained.

---

## References

- [Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Pod Quality of Service Classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/)
- [Resource Quantities in the API](https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/quantity/)
- [Assign Memory Resources to Containers and Pods](https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/)
- [Assign CPU Resources to Containers and Pods](https://kubernetes.io/docs/tasks/configure-pod-container/assign-cpu-resource/)
- [Configure a Pod Quality of Service](https://kubernetes.io/docs/tasks/configure-pod-container/quality-service-pod/)
- [Reserve Compute Resources for System Daemons](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
- [Node-pressure Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Configure Default CPU Requests and Limits for a Namespace](https://kubernetes.io/docs/tasks/administer-cluster/manage-resources/cpu-default-namespace/)
- [Configure Minimum and Maximum Memory Constraints for a Namespace](https://kubernetes.io/docs/tasks/administer-cluster/manage-resources/memory-constraint-namespace/)
- [Configure Memory and CPU Quotas for a Namespace](https://kubernetes.io/docs/tasks/administer-cluster/manage-resources/quota-memory-cpu-namespace/)
- [Local Ephemeral Storage](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage)
- [Manage HugePages](https://kubernetes.io/docs/tasks/manage-hugepages/scheduling-hugepages/)
- [Schedule GPUs](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)
- [Device Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
- [Resize CPU and Memory Resources Assigned to Containers](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/)
- [Vertical Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/vertical-pod-autoscale/)
- [Resource Metrics Pipeline](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/)
- [kubelet Configuration (v1beta1) API reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- [Pod API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
