# 🎯 Kubernetes Scheduling: How a Pod Gets Placed

A deep guide to the scheduling framework, the placement controls that steer it (node selectors, affinity, taints, topology spread, priority and preemption) and how to debug a Pending Pod.

## 📋 Table of Contents
- [The Scheduling Contract](#the-scheduling-contract)
- [The Scheduling Queue](#the-scheduling-queue)
- [The Scheduling Framework](#the-scheduling-framework)
- [Filter Plugins Reference](#filter-plugins-reference)
- [Score Plugins Reference](#score-plugins-reference)
- [The Bind Operation](#the-bind-operation)
- [Placement Controls Overview](#placement-controls-overview)
- [nodeName: Bypassing the Scheduler](#nodename-bypassing-the-scheduler)
- [nodeSelector: The Simple Filter](#nodeselector-the-simple-filter)
- [Node Affinity](#node-affinity)
- [Inter Pod Affinity and Anti Affinity](#inter-pod-affinity-and-anti-affinity)
- [Taints and Tolerations](#taints-and-tolerations)
- [Topology Spread Constraints](#topology-spread-constraints)
- [Pod Priority and Preemption](#pod-priority-and-preemption)
- [Custom Scheduling](#custom-scheduling)
- [The Descheduler](#the-descheduler)
- [Static Pods and Manual Scheduling](#static-pods-and-manual-scheduling)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Quick Reference](#quick-reference)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The Scheduling Contract

A Pod created through the API server has an empty `spec.nodeName`. That single empty field is the entire job description of the scheduler.

```
┌──────────────────────────────────────────────────────────────────────┐
│                    The One Field That Matters                        │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   kubectl create -f pod.yaml                                         │
│            │                                                         │
│            ▼                                                         │
│   ┌───────────────────────┐                                          │
│   │  Pod object in etcd   │   spec.nodeName: ""     ← unscheduled    │
│   │  status.phase Pending │                                          │
│   └───────────────────────┘                                          │
│            │                                                         │
│            │  kube-scheduler watches for Pods where                  │
│            │  spec.nodeName == "" and spec.schedulerName == mine     │
│            ▼                                                         │
│   ┌───────────────────────┐                                          │
│   │  scheduling cycle     │   filter, score, reserve, permit         │
│   │  binding cycle        │   preBind, bind, postBind                │
│   └───────────────────────┘                                          │
│            │                                                         │
│            │  POST /api/v1/namespaces/<ns>/pods/<name>/binding       │
│            ▼                                                         │
│   ┌───────────────────────┐                                          │
│   │  Pod object in etcd   │   spec.nodeName: "worker-2"              │
│   │  status.phase Pending │   (still Pending; nothing runs yet)      │
│   └───────────────────────┘                                          │
│            │                                                         │
│            │  kubelet on worker-2 watches for Pods bound to itself   │
│            ▼                                                         │
│   ┌───────────────────────┐                                          │
│   │  containers created   │   status.phase Running                   │
│   └───────────────────────┘                                          │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

Three facts fall out of this diagram and they explain most confusing scheduler behaviour:

1. **The scheduler never starts a container.** It writes a node name. The kubelet on that node does everything else: pulling images, mounting volumes, calling the CRI runtime. A Pod that is bound but never Running is a kubelet problem, not a scheduler problem.
2. **Scheduling is a one time decision.** Once `spec.nodeName` is set it is effectively immutable. Kubernetes never moves a running Pod. Rebalancing means deleting a Pod so its controller creates a new one that gets scheduled afresh.
3. **The scheduler only considers the current cluster state.** It has no memory of yesterday and no plan for tomorrow. Two Pods submitted one second apart are scheduled independently, which is why anti affinity and topology spread exist.

> 📖 **See also**: [kube-scheduler.md](kube-scheduler.md) for the component overview, and [pod-lifecycle.md](pod-lifecycle.md) for what happens after binding.

### Who Else Writes nodeName

| Writer | Mechanism | Scheduler involved |
|--------|-----------|--------------------|
| kube-scheduler | Binding subresource | Yes |
| A user or manifest | `spec.nodeName` set directly | No, scheduler skips the Pod |
| kubelet (static Pods) | Pod read from a local manifest directory | No, mirror Pod is created already bound |
| A custom scheduler | Binding subresource, matched by `spec.schedulerName` | Yes, a different one |
| DaemonSet controller | Sets node affinity, the default scheduler binds | Yes, since the DaemonSet controller moved to scheduler based placement |

---

## The Scheduling Queue

Before any filtering happens, a Pod lives in the scheduler's internal queue. The queue is three data structures, not one, and understanding them explains why an unschedulable Pod sometimes retries instantly and sometimes sits idle for a minute.

```
┌────────────────────────────────────────────────────────────────────────┐
│                     kube-scheduler internal queue                      │
│                                                                        │
│   New Pod ──► PreEnqueue plugins ──► pass? ──yes──┐                    │
│                       │                           │                    │
│                       no                          ▼                    │
│                       │                  ┌──────────────────┐          │
│                       │                  │    activeQ       │          │
│                       │                  │  (priority heap, │          │
│                       │                  │   QueueSort)     │          │
│                       │                  └────────┬─────────┘          │
│                       │                           │ Pop()              │
│                       │                           ▼                    │
│                       │                  ┌──────────────────┐          │
│                       │                  │ scheduling cycle │          │
│                       │                  └────┬────────┬────┘          │
│                       │            success    │        │  failure      │
│                       │           ◄───────────┘        └──────────►    │
│                       │                                          │     │
│                       ▼                                          ▼     │
│              ┌──────────────────┐                   ┌──────────────────┐│
│              │ unschedulablePods│◄──────────────────│  is it retryable?││
│              │  (a map, not a   │   no cluster      └────────┬─────────┘│
│              │   queue)         │   change yet               │          │
│              └────────┬─────────┘                            ▼          │
│                       │                             ┌──────────────────┐│
│      cluster event or │                             │    backoffQ      ││
│      flush timer      │                             │ (exponential     ││
│                       │                             │  backoff heap)   ││
│                       └────────────────┐            └────────┬─────────┘│
│                                        ▼                     │          │
│                                    back to activeQ ◄─────────┘          │
│                                    when backoff expires                 │
└────────────────────────────────────────────────────────────────────────┘
```

| Queue | What lives here | How a Pod leaves |
|-------|-----------------|------------------|
| **activeQ** | Pods ready to be scheduled right now, ordered by the QueueSort plugin | Popped by the scheduling loop, one at a time |
| **backoffQ** | Pods that recently failed a scheduling attempt | Moved to activeQ when the exponential backoff timer expires |
| **unschedulablePods** | Pods that failed and for which nothing in the cluster has changed | Moved to activeQ or backoffQ when a relevant cluster event occurs, or on a periodic flush |

Key behaviours:

- **QueueSort is a single plugin.** Only one QueueSort plugin can be enabled at a time, and all profiles in one scheduler process must use the same one, because there is only one queue. The default is `PrioritySort`, which orders by `spec.priority` descending and then by the Pod's queue timestamp, so higher priority Pods are attempted first.
- **Backoff is exponential.** A Pod that keeps failing is retried less and less often, which stops one impossible Pod from burning the scheduling loop.
- **Cluster events wake Pods up.** Adding a node, deleting a Pod, updating a PVC or changing a node label are events that can make a previously unschedulable Pod schedulable. Plugins declare which events matter to them, so only the Pods that could plausibly benefit are requeued.
- **PreEnqueue gates entry.** A Pod that fails a PreEnqueue plugin never enters the activeQ at all. The best known use is scheduling gates (`spec.schedulingGates`), which hold a Pod out of scheduling until an external controller removes the gate.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gated-pod
spec:
  # The Pod is not even considered for scheduling until every gate is removed.
  schedulingGates:
    - name: example.com/quota-approval
  containers:
    - name: app
      image: registry.k8s.io/pause:3.9
```

```bash
# A gated Pod shows a distinctive status
kubectl get pod gated-pod
# NAME         READY   STATUS             RESTARTS   AGE
# gated-pod    0/1     SchedulingGated    0          10s

# Removing the gate is the only way forward; gates can be removed but never added
kubectl patch pod gated-pod --type=json -p='[{"op":"remove","path":"/spec/schedulingGates"}]'
```

### Scheduler Throughput Knobs

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
# Number of nodes evaluated in parallel inside a single scheduling cycle.
parallelism: 16
# Percentage of nodes the scheduler will look at before it stops searching for
# feasible nodes. 0 means "choose adaptively", which is the default.
percentageOfNodesToScore: 0
```

`percentageOfNodesToScore` is a latency versus quality trade. Once the scheduler has found enough feasible nodes it stops filtering and scores only those. With the default adaptive setting the fraction shrinks as the cluster grows, with a documented floor of 5 percent, and the implementation also refuses to stop below a small absolute number of nodes. Setting it to `100` gives you the best placement decision and the slowest scheduler; setting it very low gives fast but potentially lopsided placement.

---

## The Scheduling Framework

Every scheduling attempt for one Pod is split into a **scheduling cycle** (choose a node) and a **binding cycle** (make it real). Together they are called a scheduling context.

> Scheduling cycles run **serially**, one Pod at a time. Binding cycles run **concurrently**, because binding can involve slow work such as volume provisioning.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SCHEDULING CYCLE (serial)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Pop Pod from activeQ                                                       │
│         │                                                                   │
│         ▼                                                                   │
│  ┌──────────────┐  Pre-process the Pod, compute state shared by later       │
│  │  PreFilter   │  phases, or reject the Pod outright.                      │
│  └──────┬───────┘  Error here aborts the cycle.                             │
│         ▼                                                                   │
│  ┌──────────────┐  Run once per node, in configured order, nodes in         │
│  │    Filter    │  parallel. First plugin to say "no" short circuits        │
│  └──────┬───────┘  that node. Output: the feasible node list.               │
│         │                                                                   │
│         ├───────────── feasible list empty? ──────────┐                     │
│         │                                             ▼                     │
│         │                                     ┌──────────────┐              │
│         │                                     │  PostFilter  │ preemption   │
│         │                                     └──────┬───────┘ lives here   │
│         │                                            │                      │
│         │                        made schedulable? ──┴── no ──► Unschedulable│
│         ▼                                                                   │
│  ┌──────────────┐  Informational. Build shared state for scoring            │
│  │   PreScore   │  (for example the topology map for spread).               │
│  └──────┬───────┘                                                           │
│         ▼                                                                   │
│  ┌──────────────┐  Each plugin scores every feasible node.                  │
│  │    Score     │  Raw scores may use any integer range.                    │
│  └──────┬───────┘                                                           │
│         ▼                                                                   │
│  ┌──────────────┐  Rescale a plugin's own raw scores into the framework     │
│  │NormalizeScore│  range 0..100. Called once per plugin per cycle.          │
│  └──────┬───────┘                                                           │
│         ▼                                                                   │
│      Σ (score × weight) per node ──► pick the highest; ties broken randomly │
│         │                                                                   │
│         ▼                                                                   │
│  ┌──────────────┐  Stateful plugins record "these resources are taken"      │
│  │   Reserve    │  so concurrent binds do not double book. Failure here     │
│  └──────┬───────┘  triggers Unreserve on every plugin, in reverse order.    │
│         ▼                                                                   │
│  ┌──────────────┐  approve / deny / wait(timeout).                          │
│  │    Permit    │  "wait" parks the Pod and blocks its binding cycle.       │
│  └──────┬───────┘  This is how gang scheduling is implemented.              │
│         │                                                                   │
└─────────┼───────────────────────────────────────────────────────────────────┘
          │  Pod is now "assumed" to be on the node in the scheduler cache
          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          BINDING CYCLE (concurrent)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  Slow prerequisite work: bind PVCs, provision volumes.    │
│  │   PreBind    │  Failure returns the Pod to the queue and unreserves.     │
│  └──────┬───────┘                                                           │
│         ▼                                                                   │
│  ┌──────────────┐  Write the Binding object. Plugins run in order; the      │
│  │     Bind     │  first one that handles the Pod wins. At least one bind   │
│  └──────┬───────┘  plugin is required. Default is DefaultBinder.            │
│         ▼                                                                   │
│  ┌──────────────┐  Informational only. Cleanup, metrics, logging.           │
│  │   PostBind   │  Nothing can fail the scheduling decision here.           │
│  └──────────────┘                                                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Extension Point Cheat Sheet

| Extension point | Can it reject? | Runs per node? | Typical use |
|-----------------|----------------|----------------|-------------|
| `PreEnqueue` | Yes, keeps the Pod out of activeQ | No | Scheduling gates |
| `QueueSort` | No | No | Order the queue, exactly one plugin allowed |
| `PreFilter` | Yes, aborts the cycle | No | Compute Pod level state, cheap early rejection |
| `Filter` | Yes, removes a node | Yes | Feasibility: resources, taints, ports, volumes |
| `PostFilter` | It can rescue the Pod | No | Preemption |
| `PreScore` | Yes, aborts the cycle | No | Build shared state for Score |
| `Score` | No | Yes | Rank feasible nodes |
| `NormalizeScore` | Yes, aborts the cycle | No | Rescale a plugin's own scores to 0..100 |
| `Reserve` / `Unreserve` | Reserve can fail | No | Reserve in-memory state, Unreserve must not fail |
| `Permit` | Yes, or delays | No | Gang scheduling, external approval |
| `PreBind` | Yes | No | Volume binding, network setup |
| `Bind` | Yes | No | Write the Binding, one winner |
| `PostBind` | No | No | Cleanup and notification |

Two subtleties worth memorising:

- **`Unreserve` must be idempotent and must never fail.** It is the rollback path, and there is no rollback for the rollback.
- **A single plugin usually implements several extension points.** `NodeResourcesFit` is a PreFilter, a Filter and a Score plugin. `VolumeBinding` is PreFilter, Filter, Reserve, PreBind and Score. That is why `multiPoint` exists in the configuration API.

---

## Filter Plugins Reference

Filters answer one question per node: **can this Pod run here at all?** The answer is boolean. There is no partial credit.

| Plugin | What it rejects | Common failure message fragment |
|--------|-----------------|---------------------------------|
| **NodeResourcesFit** | Nodes whose allocatable minus already requested is less than this Pod's requests, for any resource | `Insufficient cpu`, `Insufficient memory`, `Insufficient nvidia.com/gpu` |
| **NodeAffinity** | Nodes that fail `nodeSelector` or `requiredDuringSchedulingIgnoredDuringExecution` node affinity | `node(s) didn't match Pod's node affinity/selector` |
| **NodeName** | Every node except the one named in `spec.nodeName` | `node(s) didn't match the requested node name` |
| **NodePorts** | Nodes where a requested `hostPort` and protocol combination is already taken | `node(s) didn't have free ports for the requested pod ports` |
| **NodeUnschedulable** | Nodes with `spec.unschedulable: true`, that is, cordoned nodes | `node(s) were unschedulable` |
| **TaintToleration** | Nodes carrying a `NoSchedule` or `NoExecute` taint the Pod does not tolerate | `node(s) had untolerated taint {key: value}` |
| **PodTopologySpread** | Nodes whose domain is already at or beyond `maxSkew` for a `DoNotSchedule` constraint | `node(s) didn't match pod topology spread constraints` |
| **VolumeBinding** | Nodes where the Pod's PVCs cannot be bound or provisioned, including topology constrained volumes | `node(s) had volume node affinity conflict`, `didn't find available persistent volumes to bind` |
| **VolumeRestrictions** | Nodes that violate volume provider specific rules, for example read write once conflicts | `node(s) had volume restrictions` |
| **InterPodAffinity** | Nodes that fail required Pod affinity or violate required Pod anti affinity | `node(s) didn't satisfy existing pods anti-affinity rules` |
| **VolumeZone** | Nodes in the wrong zone for a zone bound volume | `node(s) had volume node affinity conflict` |
| **NodeVolumeLimits** and the cloud specific `EBSLimits`, `GCEPDLimits`, `AzureDiskLimits` | Nodes already at their maximum attached volume count | `node(s) exceed max volume count` |

Ordering matters for performance, not for correctness: cheap filters run first so expensive ones evaluate fewer nodes. `InterPodAffinity` is one of the expensive ones because it needs to look at other Pods, not just the node.

```bash
# Watch which filters are rejecting nodes, live
kubectl get events --field-selector reason=FailedScheduling -w

# The same information, per Pod
kubectl describe pod my-pod | sed -n '/Events:/,$p'
```

---

## Score Plugins Reference

Once the feasible list exists, scoring answers **which of these nodes is best?** Each plugin returns a score per node, `NormalizeScore` rescales it into the framework range of 0 to 100, then the scheduler computes a weighted sum and picks the maximum.

```
final_score(node) = Σ  weight(plugin) × normalized_score(plugin, node)
                  plugins
```

| Plugin | Prefers | Notes |
|--------|---------|-------|
| **NodeResourcesFit** | Depends on `scoringStrategy` | `LeastAllocated` (default) spreads load, `MostAllocated` bin packs, `RequestedToCapacityRatio` follows a user supplied shape function |
| **NodeResourcesBalancedAllocation** | Nodes where CPU and memory utilisation end up close to each other | Prevents a node from being full of CPU but empty of memory; it does not decide how full a node gets, only how balanced |
| **ImageLocality** | Nodes that already have the container images cached locally | Scaled by image size and by how many nodes already have the image, so a very widely present image gives little advantage |
| **InterPodAffinity** | Nodes satisfying `preferredDuringSchedulingIgnoredDuringExecution` Pod affinity and anti affinity | Each preference carries its own `weight` from 1 to 100 |
| **NodeAffinity** | Nodes satisfying preferred node affinity terms | Same 1 to 100 per term weight |
| **TaintToleration** | Nodes with fewer untolerated `PreferNoSchedule` taints | This is the only place `PreferNoSchedule` has any effect |
| **PodTopologySpread** | Nodes in domains that currently hold fewer matching Pods | Applies to `ScheduleAnyway` constraints and to cluster level default constraints |
| **VolumeBinding** | Nodes with more suitable storage capacity, when capacity scoring is enabled | Applies to CSI drivers that publish storage capacity |

Each plugin also has a **weight** in the profile. Weights are configurable per profile, and re-declaring a plugin in the `score` section with a new weight is the supported way to change the balance without disabling anything.

### Bin Packing versus Spreading

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
  - schedulerName: default-scheduler
    pluginConfig:
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            # MostAllocated packs Pods onto the fullest node that still fits,
            # which is what you want when a cluster autoscaler charges per node.
            type: MostAllocated
            resources:
              - name: cpu
                weight: 1
              - name: memory
                weight: 1
```

```yaml
# RequestedToCapacityRatio lets you draw the utilisation curve yourself.
# Here, a node scores best when it is 100% utilised (aggressive bin packing),
# and worst when it is empty.
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
  - schedulerName: default-scheduler
    pluginConfig:
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: RequestedToCapacityRatio
            resources:
              - name: cpu
                weight: 3
              - name: memory
                weight: 1
              - name: nvidia.com/gpu
                weight: 5
            requestedToCapacityRatio:
              shape:
                - utilization: 0
                  score: 0
                - utilization: 100
                  score: 10
```

| Strategy | Node utilisation outcome | Best for | Risk |
|----------|--------------------------|----------|------|
| `LeastAllocated` | Even spread across nodes | Latency sensitive workloads, noisy neighbour avoidance | Many half empty nodes, expensive in cloud |
| `MostAllocated` | Nodes filled before new ones are used | Cost optimisation with a cluster autoscaler | Correlated blast radius, one node failure hits more Pods |
| `RequestedToCapacityRatio` | Whatever the shape says | GPU packing, custom cost models | Easy to write a shape that behaves unexpectedly at the extremes |

> ⚠️ Scoring only ever chooses among nodes that already passed filtering. No score can rescue an infeasible node, and no score is consulted if exactly one node is feasible.

---

## The Bind Operation

Binding is not a magic internal call. It is an ordinary API write to a **subresource**.

```yaml
# This is the object the scheduler POSTs to
# /api/v1/namespaces/default/pods/nginx/binding
apiVersion: v1
kind: Binding
metadata:
  name: nginx
  namespace: default
target:
  apiVersion: v1
  kind: Node
  name: worker-2
```

```bash
# You can perform a bind by hand. This is the classic "manual scheduling" exercise.
cat <<'EOF' > /tmp/binding.json
{
  "apiVersion": "v1",
  "kind": "Binding",
  "metadata": { "name": "nginx", "namespace": "default" },
  "target": { "apiVersion": "v1", "kind": "Node", "name": "worker-2" }
}
EOF

kubectl proxy --port=8001 &
curl -s -X POST http://127.0.0.1:8001/api/v1/namespaces/default/pods/nginx/binding \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/binding.json
```

What happens on the API server side:

1. The Binding write sets `spec.nodeName` on the Pod. The field is immutable afterwards, so a second bind of the same Pod fails.
2. The scheduler emits a `Scheduled` event: `Successfully assigned default/nginx to worker-2`.
3. The Pod is still `Pending`. Nothing has been pulled or started.
4. The kubelet on `worker-2`, which watches Pods filtered by node name, picks the Pod up, admits it locally, sets up the sandbox and starts containers.

> 🔑 **The kubelet has its own admission checks.** A Pod can be bound successfully and still be rejected by the kubelet, giving `status.phase: Failed` with a reason such as `OutOfcpu`, `OutOfmemory` or `NodeAffinity`. That happens when the node's real state diverged from the scheduler's cached view. Those Pods stay on the node as failed objects until garbage collected, which is why you sometimes see a long list of `OutOfcpu` Pods after a burst.

---

## Placement Controls Overview

The controls form a ladder. Each rung is more expressive and more expensive to reason about than the one below.

```
Power / complexity
      ▲
      │  ┌──────────────────────────────────────────────────────────────┐
      │  │ 7. Custom scheduler / profile   full control, you own the code │
      │  ├──────────────────────────────────────────────────────────────┤
      │  │ 6. Priority + preemption        can evict other people's Pods  │
      │  ├──────────────────────────────────────────────────────────────┤
      │  │ 5. Topology spread              even distribution across zones │
      │  ├──────────────────────────────────────────────────────────────┤
      │  │ 4. Inter pod (anti) affinity    placement relative to Pods     │
      │  ├──────────────────────────────────────────────────────────────┤
      │  │ 3. Taints + tolerations         node repels, Pod opts in       │
      │  ├──────────────────────────────────────────────────────────────┤
      │  │ 2. Node affinity                expressive node label matching │
      │  ├──────────────────────────────────────────────────────────────┤
      │  │ 1. nodeSelector                 exact label equality only      │
      │  ├──────────────────────────────────────────────────────────────┤
      │  │ 0. nodeName                     no scheduler at all            │
      │  └──────────────────────────────────────────────────────────────┘
      └──────────────────────────────────────────────────────────────────►
```

| Control | Direction | Enforced at | Survives label change? |
|---------|-----------|-------------|------------------------|
| `nodeName` | Pod picks node | Nowhere, it is a bypass | Not applicable |
| `nodeSelector` | Pod picks nodes | Filter (NodeAffinity plugin) | Yes, running Pods are unaffected |
| Node affinity `required` | Pod picks nodes | Filter | Yes, `IgnoredDuringExecution` |
| Node affinity `preferred` | Pod prefers nodes | Score | Yes |
| Pod affinity / anti affinity `required` | Pod picks nodes relative to Pods | Filter | Yes |
| Pod affinity / anti affinity `preferred` | Pod prefers | Score | Yes |
| Taint `NoSchedule` | Node repels Pods | Filter | Yes, existing Pods stay |
| Taint `PreferNoSchedule` | Node discourages Pods | Score | Yes |
| Taint `NoExecute` | Node repels and **evicts** | Filter plus the taint manager | **No, running Pods are evicted** |
| Topology spread `DoNotSchedule` | Pod spreads itself | Filter | Yes |
| Topology spread `ScheduleAnyway` | Pod prefers to spread | Score | Yes |

**Rule of thumb**: use the lowest rung that solves the problem. `nodeSelector` plus taints solves the majority of real dedicated node pool requirements without any of the cost of inter pod affinity.

---

## nodeName: Bypassing the Scheduler

Setting `spec.nodeName` in the manifest means the Pod is created already bound. The scheduler never sees it, because the scheduler only watches Pods with an empty node name.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pinned-debug
spec:
  # No filtering, no scoring, no taint checks, no resource checks by the scheduler.
  nodeName: worker-3
  containers:
    - name: debug
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 100m
          memory: 64Mi
```

### Worked Scenario

You need a shell on `worker-3` to inspect a disk problem, and `worker-3` is cordoned and tainted so nothing normal will land there.

```bash
kubectl apply -f pinned-debug.yaml
kubectl get pod pinned-debug -o wide
# It lands on worker-3 despite the cordon, because NodeUnschedulable is a
# scheduler filter and the scheduler was never consulted.
```

### What You Lose

| Check | Performed for a `nodeName` Pod? |
|-------|--------------------------------|
| Node has enough allocatable CPU and memory | ❌ Not by the scheduler. The kubelet may reject the Pod with `OutOfcpu` |
| Node taints | ❌ Ignored entirely, including `NoSchedule` |
| Cordon (`spec.unschedulable`) | ❌ Ignored |
| Node affinity, topology spread | ❌ Ignored by the scheduler, though the kubelet re-checks node affinity at admission |
| Node actually exists | ❌ The Pod is accepted and stays `Pending` forever if the node name is wrong |

> ⚠️ **Never use `nodeName` in a Deployment or DaemonSet.** Every replica lands on one node, and if that node dies the Pods are stuck. It is a debugging and bootstrap tool, not a placement strategy.

---

## nodeSelector: The Simple Filter

`nodeSelector` is a map of exact label equality requirements. All of them must match. There is no OR, no negation, no ranges.

```bash
# Label the nodes first
kubectl label node worker-1 disktype=ssd
kubectl label node worker-2 disktype=hdd
kubectl label node worker-1 hardware=gpu-a100

# Inspect what is already there
kubectl get nodes --show-labels
kubectl get nodes -L disktype,topology.kubernetes.io/zone,node.kubernetes.io/instance-type
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ssd-only
spec:
  nodeSelector:
    disktype: ssd
    hardware: gpu-a100     # implicit AND
  containers:
    - name: app
      image: nginx:1.27
```

### Well Known Labels Worth Knowing

| Label | Meaning | Set by |
|-------|---------|--------|
| `kubernetes.io/hostname` | The node's own name | kubelet |
| `kubernetes.io/os` | `linux` or `windows` | kubelet |
| `kubernetes.io/arch` | `amd64`, `arm64` and others | kubelet |
| `topology.kubernetes.io/zone` | Failure zone | Cloud controller manager or the administrator |
| `topology.kubernetes.io/region` | Region | Cloud controller manager or the administrator |
| `node.kubernetes.io/instance-type` | Machine type | Cloud controller manager |

> 🔒 The kubelet is **not** allowed to set arbitrary labels on itself. The NodeRestriction admission plugin limits self labelling to a known safe prefix set, so `topology.kubernetes.io/zone` on a bare metal cluster is normally applied by an administrator with `kubectl label`.

### Worked Scenario

A mixed architecture cluster runs both `amd64` and `arm64` workers, and one image is `amd64` only.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-amd64-app
spec:
  replicas: 3
  selector:
    matchLabels: { app: legacy }
  template:
    metadata:
      labels: { app: legacy }
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      containers:
        - name: app
          image: example.com/legacy:1.4
```

Without the selector, roughly half the replicas would land on `arm64` nodes and crash loop with an exec format error. This is the single most common real world use of `nodeSelector`.

---

## Node Affinity

Node affinity is `nodeSelector` with an expression language and an optional soft mode.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: affinity-demo
spec:
  affinity:
    nodeAffinity:
      # HARD: evaluated by the Filter phase. No matching node, no scheduling.
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          # Terms are OR'ed with each other.
          - matchExpressions:
              # Expressions inside one term are AND'ed.
              - key: topology.kubernetes.io/zone
                operator: In
                values: ["eu-west-1a", "eu-west-1b"]
              - key: node.kubernetes.io/instance-type
                operator: NotIn
                values: ["t3.micro"]
          - matchExpressions:
              - key: hardware
                operator: Exists
      # SOFT: evaluated by the Score phase. Never blocks scheduling.
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 80
          preference:
            matchExpressions:
              - key: disktype
                operator: In
                values: ["ssd"]
        - weight: 20
          preference:
            matchExpressions:
              - key: cpu-generation
                operator: Gt
                values: ["3"]        # string form of an integer
  containers:
    - name: app
      image: nginx:1.27
```

### Operators

| Operator | Meaning | `values` required? |
|----------|---------|--------------------|
| `In` | Label value is one of the listed values | Yes, one or more |
| `NotIn` | Label value is not any of the listed values, **and the label exists** for the term to be evaluated as a mismatch of value | Yes |
| `Exists` | Label key is present, value irrelevant | No, must be empty |
| `DoesNotExist` | Label key is absent | No, must be empty |
| `Gt` | Label value parsed as an integer is greater than the single supplied value | Yes, exactly one |
| `Lt` | Label value parsed as an integer is less than the single supplied value | Yes, exactly one |

> ⚠️ `Gt` and `Lt` take a **single** value, and both the node label and the value must parse as integers. `Gt` with `values: ["3.5"]` is invalid. They are not available for `matchFields`.

### AND, OR and the Nesting Rules

```
nodeSelectorTerms:            ← OR between list items
  - matchExpressions:         ← AND between list items
      - key: a ...            }
      - key: b ...            } both must match
  - matchExpressions:
      - key: c ...            ← this term alone can satisfy the requirement
```

The mirror image applies to `preferredDuringScheduling...`: it is a list of `{weight, preference}` pairs, each preference is a single term whose expressions are AND'ed, and the weights of all satisfied preferences are summed into the node's affinity score.

### matchFields

`nodeSelectorTerms` also supports `matchFields`, which selects on node object fields rather than labels. In practice there is exactly one useful field:

```yaml
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchFields:
              - key: metadata.name
                operator: In
                values: ["worker-2"]
```

This is what the DaemonSet controller writes into each of its Pods so that the normal scheduler places one Pod per node without the DaemonSet controller doing its own binding.

### The Meaning of IgnoredDuringExecution

Every node affinity form ends in `IgnoredDuringExecution`, and it means exactly what it says:

```
t=0   node worker-1 has disktype=ssd
      Pod with required affinity disktype In [ssd] is scheduled to worker-1   ✅

t=1   kubectl label node worker-1 disktype=hdd --overwrite

t=2   The Pod is STILL RUNNING on worker-1.
      Kubernetes does not re-evaluate node affinity for running Pods.
      Only a NoExecute taint can evict a running Pod for placement reasons.
```

`RequiredDuringSchedulingRequiredDuringExecution` has been discussed for years and does not exist. If you need eviction on label change, express the rule as a `NoExecute` taint instead.

### Worked Scenario: Zone Restricted Licensed Software

A vendor licence is tied to specific physical hosts, and there is a strong preference for SSD backed hosts inside that set.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: licensed-app
spec:
  replicas: 4
  selector:
    matchLabels: { app: licensed }
  template:
    metadata:
      labels: { app: licensed }
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: licence.example.com/vendor-x
                    operator: Exists
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: disktype
                    operator: In
                    values: ["ssd"]
      containers:
        - name: app
          image: example.com/vendor-x:2.1
```

Result: the Pod will only ever run on licensed nodes; among licensed nodes, SSD nodes get a large scoring bonus but an HDD licensed node is still used when the SSD ones are full. Exactly the intended behaviour, and it is impossible to express with `nodeSelector`.

---

## Inter Pod Affinity and Anti Affinity

Node affinity places a Pod relative to **node labels**. Inter pod affinity places it relative to **other Pods that are already running**.

### The topologyKey Is the Whole Idea

```yaml
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: web
          topologyKey: kubernetes.io/hostname
```

Read that as: *find every node that already runs a Pod labelled `app=web`; take the value of the `kubernetes.io/hostname` label on each of those nodes; that set of values is the forbidden domain set; reject any candidate node whose `kubernetes.io/hostname` value is in that set.*

```
topologyKey: kubernetes.io/hostname          → each node is its own domain
┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
│ node-1  │ │ node-2  │ │ node-3  │ │ node-4  │
│ domain A│ │ domain B│ │ domain C│ │ domain D│
└─────────┘ └─────────┘ └─────────┘ └─────────┘
   anti affinity here ⇒ at most one Pod per NODE

topologyKey: topology.kubernetes.io/zone     → each zone is one domain
┌───────────────────────┐ ┌───────────────────────┐
│      zone eu-1a       │ │      zone eu-1b       │
│  node-1     node-2    │ │  node-3     node-4    │
│      domain A         │ │      domain B         │
└───────────────────────┘ └───────────────────────┘
   anti affinity here ⇒ at most one Pod per ZONE (only 2 replicas fit!)
```

| topologyKey | Domain granularity | Anti affinity meaning |
|-------------|--------------------|----------------------|
| `kubernetes.io/hostname` | One node | One Pod per node |
| `topology.kubernetes.io/zone` | One availability zone | One Pod per zone |
| `topology.kubernetes.io/region` | One region | One Pod per region |
| A custom label such as `rack` | One rack | One Pod per rack |

> ⚠️ **Nodes missing the topologyKey label are simply not eligible.** If half your nodes lack `topology.kubernetes.io/zone`, a Pod with a zone based required rule can never be placed on them, and the failure message is a generic affinity mismatch.

### Required High Availability Spread

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: web
              topologyKey: kubernetes.io/hostname
      containers:
        - name: web
          image: nginx:1.27
```

Worked outcome on a four node cluster:

```
replica 1 → node-1   (no web Pods anywhere yet)
replica 2 → node-2   (node-1 excluded)
replica 3 → node-3   (node-1, node-2 excluded)
scale to 5 → replicas 4 and 5:
   replica 4 → node-4
   replica 5 → PENDING FOREVER
              "0/4 nodes are available: 4 node(s) didn't satisfy existing
               pods anti-affinity rules"
```

That is the classic trap. A **required** hostname anti affinity caps your replica count at the node count, and a rolling update can deadlock because the new Pod cannot be placed until the old one on that node is gone, while the Deployment is waiting for the new Pod to become ready. Use `preferred` unless you genuinely need the hard guarantee, or pair `required` with `maxUnavailable: 1` and enough nodes.

### Preferred Spread, the Safer Default

```yaml
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: web
                topologyKey: kubernetes.io/hostname
            - weight: 50
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: web
                topologyKey: topology.kubernetes.io/zone
```

Note the shape difference: the preferred form wraps the term in `podAffinityTerm` and adds `weight`; the required form is a bare list of terms. Getting these two shapes confused is a very common YAML error.

### Co-location with Pod Affinity

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-client
  labels: { app: api }
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: ["redis"]
          # Same node as a redis Pod, for unix-socket-speed locality.
          topologyKey: kubernetes.io/hostname
          # Restrict the search to specific namespaces (default: the Pod's own).
          namespaces: ["cache"]
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels: { app: api }
            topologyKey: kubernetes.io/hostname
  containers:
    - name: api
      image: example.com/api:3.0
```

Namespace scoping options for a term:

| Field | Behaviour |
|-------|-----------|
| omitted | Only the Pod's own namespace is searched |
| `namespaces: ["a","b"]` | Exactly those namespaces |
| `namespaceSelector: {}` | **All** namespaces |
| `namespaceSelector: {matchLabels: {tier: prod}}` | Namespaces carrying that label |

`namespaces` and `namespaceSelector` are unioned when both are set.

### The Performance Warning

Inter pod affinity is the most expensive placement feature in Kubernetes, and the cost is structural, not an implementation defect.

```
Node affinity cost:      O(nodes)            look at each node's labels
Taint filtering cost:    O(nodes × taints)   cheap, small constants
Inter pod affinity cost: O(nodes × pods)     for each candidate node, examine
                                             the Pods in its topology domain
```

Consequences to plan for:

- The upstream documentation explicitly warns against inter pod affinity in clusters of **several hundred nodes or more**.
- A required rule with `topologyKey: topology.kubernetes.io/zone` forces the scheduler to consider the Pods of an entire zone for every candidate node.
- The scheduler evaluates these rules for **every** scheduling attempt of **every** Pod that has them, so a large Deployment with anti affinity multiplies the cost by its replica count.
- `PodTopologySpread` solves the "spread my replicas out" problem far more cheaply and with a tunable skew instead of an all or nothing rule. **Prefer topology spread constraints for spreading, and reserve inter pod affinity for genuine co-location requirements.**

---

## Taints and Tolerations

Node affinity is the Pod choosing nodes. Taints are the **node rejecting Pods**, and a toleration is the Pod's opt in.

```bash
# Add a taint: key=value:effect
kubectl taint nodes worker-1 workload=gpu:NoSchedule

# A taint with no value is legal and common
kubectl taint nodes worker-1 maintenance:NoSchedule

# Remove a taint by repeating it with a trailing minus
kubectl taint nodes worker-1 workload=gpu:NoSchedule-

# See them all
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
kubectl describe node worker-1 | grep -A5 Taints
```

### The Three Effects

| Effect | Scheduling of new Pods | Running Pods without a toleration | Enforced by |
|--------|------------------------|-----------------------------------|-------------|
| `NoSchedule` | Blocked | Left alone | `TaintToleration` filter plugin |
| `PreferNoSchedule` | Discouraged, still allowed | Left alone | `TaintToleration` score plugin |
| `NoExecute` | Blocked | **Evicted**, subject to `tolerationSeconds` | Filter plugin plus the taint manager in kube-controller-manager |

```
                    ┌───────────────────────────────────────────┐
                    │              Node taint                   │
                    │       workload=gpu:NoSchedule             │
                    └───────────────────────────────────────────┘
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        ▼                            ▼                            ▼
┌────────────────┐          ┌────────────────┐          ┌────────────────┐
│ Pod A          │          │ Pod B          │          │ Pod C          │
│ no toleration  │          │ tolerates      │          │ tolerates      │
│                │          │ workload=gpu   │          │ everything     │
│  ❌ rejected   │          │  ✅ allowed    │          │  ✅ allowed    │
└────────────────┘          └────────────────┘          └────────────────┘

A toleration does NOT attract a Pod. It only removes an obstacle.
Pod B may still be scheduled to a completely different, untainted node.
```

### Toleration Syntax

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: toleration-demo
spec:
  tolerations:
    # 1. Equal: key, value and effect must all match the taint.
    - key: "workload"
      operator: "Equal"
      value: "gpu"
      effect: "NoSchedule"

    # 2. Exists: key and effect match, value is irrelevant.
    #    Note: with operator Exists you MUST NOT set value.
    - key: "maintenance"
      operator: "Exists"
      effect: "NoSchedule"

    # 3. Empty effect matches ALL effects for that key.
    - key: "workload"
      operator: "Exists"

    # 4. Empty key with operator Exists tolerates EVERY taint on every node.
    #    Use only for true cluster infrastructure such as node level agents.
    - operator: "Exists"

    # 5. NoExecute with a grace period: stay for 600 seconds after the taint
    #    appears, then be evicted.
    - key: "node.kubernetes.io/unreachable"
      operator: "Exists"
      effect: "NoExecute"
      tolerationSeconds: 600
  containers:
    - name: app
      image: nginx:1.27
```

| Rule | Detail |
|------|--------|
| `operator` default | `Equal` |
| `operator: Exists` | `value` must be empty, otherwise the object is rejected |
| Empty `key` | Only valid with `operator: Exists`, and it matches every key |
| Empty `effect` | Matches all three effects for the given key |
| `tolerationSeconds` | Only meaningful with `effect: NoExecute`. Unset means tolerate forever; `0` means evict immediately |

### Built In Node Condition Taints

The node lifecycle controller applies these automatically. Knowing them by heart pays off during any incident.

| Taint key | Applied when | Usual effect |
|-----------|--------------|--------------|
| `node.kubernetes.io/not-ready` | Node `Ready` condition is `False` | `NoSchedule` and `NoExecute` |
| `node.kubernetes.io/unreachable` | Node `Ready` condition is `Unknown`, the node controller lost contact | `NoSchedule` and `NoExecute` |
| `node.kubernetes.io/memory-pressure` | kubelet reports `MemoryPressure` | `NoSchedule` |
| `node.kubernetes.io/disk-pressure` | kubelet reports `DiskPressure` | `NoSchedule` |
| `node.kubernetes.io/pid-pressure` | kubelet reports `PIDPressure` | `NoSchedule` |
| `node.kubernetes.io/unschedulable` | `kubectl cordon`, that is `spec.unschedulable: true` | `NoSchedule` |
| `node.kubernetes.io/network-unavailable` | Node network is not correctly configured | `NoSchedule` |
| `node.cloudprovider.kubernetes.io/uninitialized` | External cloud controller manager has not yet initialised the node | `NoSchedule` |

Two behaviours follow from this table:

1. **Every Pod already has tolerations you did not write.** The `DefaultTolerationSeconds` admission controller injects tolerations for `not-ready` and `unreachable` with `tolerationSeconds: 300`. That is exactly why Pods on a node that goes silent are not deleted for about five minutes.

```bash
# Prove it on any Pod you did not write tolerations for
kubectl get pod my-pod -o jsonpath='{.spec.tolerations}' | python3 -m json.tool
# [
#   { "effect": "NoExecute", "key": "node.kubernetes.io/not-ready",
#     "operator": "Exists", "tolerationSeconds": 300 },
#   { "effect": "NoExecute", "key": "node.kubernetes.io/unreachable",
#     "operator": "Exists", "tolerationSeconds": 300 }
# ]
```

2. **DaemonSet Pods get broad tolerations automatically**, including the pressure taints and `unschedulable`, so that node agents keep running on a node that is cordoned or under pressure. This is why `kubectl drain` needs `--ignore-daemonsets`.

### The Control Plane Taint

```bash
# Standard on a kubeadm control plane node
kubectl describe node cp-1 | grep -i taints
# Taints: node-role.kubernetes.io/control-plane:NoSchedule

# Single node lab: allow ordinary workloads on the control plane
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-

# Put it back when you add real workers
kubectl taint nodes cp-1 node-role.kubernetes.io/control-plane:NoSchedule
```

Note the distinction between the **taint** `node-role.kubernetes.io/control-plane` (which repels Pods) and the **label** of the same name (which is what `kubectl get nodes` prints in the ROLES column). Removing the label changes only the display; removing the taint changes scheduling.

To place a specific Pod on the control plane without removing the taint:

```yaml
spec:
  tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
```

### Dedicated Node Pool Pattern

The complete pattern needs **both** a taint and a node affinity or selector. Each alone is insufficient.

```bash
kubectl taint nodes gpu-1 gpu-2 dedicated=gpu-workloads:NoSchedule
kubectl label nodes gpu-1 gpu-2 dedicated=gpu-workloads
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: training-job
spec:
  replicas: 2
  selector:
    matchLabels: { app: training }
  template:
    metadata:
      labels: { app: training }
    spec:
      # Half 1: permission to enter the tainted pool.
      tolerations:
        - key: "dedicated"
          operator: "Equal"
          value: "gpu-workloads"
          effect: "NoSchedule"
      # Half 2: obligation to stay inside the pool.
      nodeSelector:
        dedicated: gpu-workloads
      containers:
        - name: trainer
          image: example.com/trainer:1.0
          resources:
            limits:
              nvidia.com/gpu: 1
```

| You set | Result |
|---------|--------|
| Taint only | Other Pods stay out ✅, but your GPU Pods may wander onto ordinary nodes ❌ |
| Label plus selector only | Your Pods stay in the pool ✅, but any other Pod can also land there ❌ |
| **Both** | Exclusive, bidirectional pool ✅ |

> 💡 The `nvidia.com/gpu` limit in that manifest is itself a strong filter, because only nodes advertising that extended resource can pass `NodeResourcesFit`. In a homogeneous GPU cluster that alone may be enough. See [resource-management.md](resource-management.md) for extended resources.

---

## Topology Spread Constraints

Anti affinity is binary: allowed or forbidden. Topology spread is **quantitative**: it lets you say "no domain may hold more than N more Pods than the emptiest domain".

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-demo
spec:
  replicas: 9
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: web
          # Do not consider a zone "present" unless there are at least 3 domains.
          minDomains: 3
          # Honor: only nodes matching this Pod's node affinity count as domains.
          nodeAffinityPolicy: Honor
          # Honor: nodes with taints this Pod does not tolerate are excluded.
          nodeTaintsPolicy: Honor
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: web
      containers:
        - name: web
          image: nginx:1.27
```

### Field Reference

| Field | Meaning | Notes |
|-------|---------|-------|
| `maxSkew` | Maximum permitted difference between the most and least populated matching domains | Must be greater than 0 |
| `topologyKey` | Node label defining a domain | Nodes without the label are excluded from the calculation |
| `whenUnsatisfiable` | `DoNotSchedule` (Filter) or `ScheduleAnyway` (Score) | Default `DoNotSchedule` |
| `labelSelector` | Which existing Pods are counted | **Must be set explicitly**; it does not default to the Pod's own labels |
| `minDomains` | Treat the domain count as at least this number, padding with zero counts | Only valid with `DoNotSchedule` |
| `matchLabelKeys` | Extra Pod label keys whose values are read from the incoming Pod and AND'ed into the selector | The standard way to scope a spread to one Deployment revision using `pod-template-hash` |
| `nodeAffinityPolicy` | `Honor` or `Ignore`, whether the Pod's node affinity and selector restrict which nodes count | Default `Honor` |
| `nodeTaintsPolicy` | `Honor` or `Ignore`, whether untolerated taints exclude a node | Default `Ignore` |

### Worked Skew Calculation

Three zones, `maxSkew: 1`, `topologyKey: topology.kubernetes.io/zone`, `whenUnsatisfiable: DoNotSchedule`, `labelSelector: app=web`.

```
Skew for a candidate domain D  =  (matching Pods in D, after placing this Pod)
                                 minus (matching Pods in the globally least
                                        populated eligible domain)

Start:  zoneA=0  zoneB=0  zoneC=0     min = 0

Pod 1 -> any zone is fine (0+1 - 0 = 1 <= 1). Say zoneA.
        zoneA=1  zoneB=0  zoneC=0     min = 0

Pod 2 -> zoneA would give 2 - 0 = 2 > 1  (rejected)
        zoneB gives 1 - 0 = 1 <= 1      (accepted, zoneC equally valid)
        zoneA=1  zoneB=1  zoneC=0     min = 0

Pod 3 -> zoneA: 2 - 0 = 2 no   zoneB: 2 - 0 = 2 no   zoneC: 1 - 0 = 1 yes
        zoneA=1  zoneB=1  zoneC=1     min = 1

Pod 4 -> every zone gives 2 - 1 = 1 yes.  Say zoneA.
        zoneA=2  zoneB=1  zoneC=1     min = 1

Pod 5 -> zoneA: 3 - 1 = 2 no   zoneB: 2 - 1 = 1 yes
        zoneA=2  zoneB=2  zoneC=1     min = 1

Pod 6 -> only zoneC: 2 - 1 = 1 yes
        zoneA=2  zoneB=2  zoneC=2

Pods 7, 8, 9 → the pattern repeats.
Final:  zoneA=3  zoneB=3  zoneC=3      perfectly even
```

Now break a zone. Suppose `zoneC` has no capacity left:

```
zoneA=3  zoneB=3  zoneC=3, scale to 10.
Pod 10 -> zoneA: 4 - 3 = 1 ok by skew, but no CPU left in zoneA
          zoneB: 4 - 3 = 1 ok by skew, but no CPU left in zoneB
          zoneC: 4 - 3 = 1 ok by skew, no capacity either
         Result: Pending with a mixed message combining Insufficient cpu
                 and topology spread rejections.
```

With `whenUnsatisfiable: ScheduleAnyway`, Pod 10 would be placed on the least bad node instead of staying Pending. **That single field is the difference between an outage and a temporary imbalance**, which is why availability critical Deployments usually use `ScheduleAnyway` for hostname spread and `DoNotSchedule` only for zone spread when they truly have spare zone capacity.

### minDomains in Practice

```
Two zones exist today, minDomains: 3, maxSkew: 1, replicas 4.

Without minDomains: domains = {zoneA, zoneB}, min count is real.
With minDomains: 3, the calculation behaves as though a third empty
domain exists, so the "global minimum" is 0 until three domains hold Pods.

Effect: placement stalls at 1 Pod per zone rather than filling two zones,
which keeps capacity free for the third zone that is expected to appear.
```

`minDomains` is therefore a way to say "I intend to have at least N failure domains; do not let the scheduler pretend that N-1 is normal". It has no effect with `ScheduleAnyway`.

### matchLabelKeys and Rolling Updates

Without `matchLabelKeys`, a spread constraint counts Pods from **both** the old and the new ReplicaSet during a rolling update, because both carry `app: web`. The result is a lopsided final distribution.

```yaml
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: web
          # Only count Pods of the SAME Deployment revision.
          matchLabelKeys:
            - pod-template-hash
```

### Cluster Level Default Constraints

A Pod with no `topologySpreadConstraints` can still be spread, using the scheduler's default constraints.

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
  - schedulerName: default-scheduler
    pluginConfig:
      - name: PodTopologySpread
        args:
          defaultConstraints:
            - maxSkew: 2
              topologyKey: topology.kubernetes.io/zone
              whenUnsatisfiable: ScheduleAnyway
            - maxSkew: 3
              topologyKey: kubernetes.io/hostname
              whenUnsatisfiable: ScheduleAnyway
          # List = use defaultConstraints above.
          # System = use the built-in cluster level defaults instead.
          defaultingType: List
```

| `defaultingType` | Behaviour |
|------------------|-----------|
| `System` | Apply the built in cluster level default constraints, which spread on hostname and zone with `ScheduleAnyway` |
| `List` | Apply exactly the `defaultConstraints` you wrote |

Default constraints derive their `labelSelector` from the Pod's owning workload object (Service, ReplicaSet, ReplicationController or StatefulSet); a Pod with no such owner is not spread by them. Any Pod that defines its own `topologySpreadConstraints` opts out of the defaults entirely.

### Topology Spread versus Anti Affinity

| Aspect | `podAntiAffinity` required | `topologySpreadConstraints` |
|--------|---------------------------|-----------------------------|
| Granularity | All or nothing, one Pod per domain | Tunable via `maxSkew` |
| Soft mode | `preferred` with weights | `whenUnsatisfiable: ScheduleAnyway` |
| Scale ceiling | Replicas cannot exceed domain count | Replicas can exceed domain count freely |
| Cost | High, O(nodes × pods) | Much lower, domain counting |
| Handles empty domains | No concept | `minDomains` |
| Respects taints in the calculation | Not applicable | `nodeTaintsPolicy` |
| Recommended for spreading | ❌ | ✅ |
| Recommended for co-location | ✅ (`podAffinity`) | Not supported |

---

## Pod Priority and Preemption

Priority makes the scheduler care about **which Pod goes first**. Preemption lets a high priority Pod **evict** lower priority Pods to make room.

### PriorityClass

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
# At most one PriorityClass in the cluster may set this to true.
globalDefault: false
description: "Customer facing services. May preempt batch workloads."
# PreemptLowerPriority (default) or Never.
preemptionPolicy: PreemptLowerPriority
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch-priority
value: 100
globalDefault: false
description: "Analytics and batch. Never evicts anything."
# This Pod jumps the queue but never evicts another Pod.
preemptionPolicy: Never
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: important
spec:
  priorityClassName: high-priority
  containers:
    - name: app
      image: nginx:1.27
```

| Field | Rules |
|-------|-------|
| `value` | Signed 32 bit integer. Higher is more important. User defined classes should stay at or below 1000000000 |
| `globalDefault` | Applied to Pods with no `priorityClassName`. Only one class may set it. If none does, the default priority is 0 |
| `preemptionPolicy` | `PreemptLowerPriority` is the default. `Never` means the Pod is queued ahead of lower priority Pods but never triggers preemption |
| `description` | Free text, purely for humans |

The Priority admission controller resolves `priorityClassName` into the integer `spec.priority` at admission time. Changing a PriorityClass value later does **not** retroactively change existing Pods.

### Built In System Classes

| Name | Value | Intended for |
|------|-------|--------------|
| `system-node-critical` | 2000001000 | Pods that must run for the node to function, such as the CNI agent and kube-proxy |
| `system-cluster-critical` | 2000000000 | Cluster wide critical addons, such as CoreDNS and the metrics server |

Both are created automatically. By default, a Pod may only use them in the `kube-system` namespace, enforced by a ResourceQuota with a `PriorityClass` scope; a cluster administrator can grant other namespaces access by creating a matching quota. See [resource-management.md](resource-management.md) for quota scopes.

### The Preemption Algorithm

Preemption runs in **PostFilter**, that is only after normal filtering found no feasible node.

```
Pod P is unschedulable, P.priority = 1000000
              │
              ▼
┌────────────────────────────────────────────────────────────────────┐
│ 1. Is P.preemptionPolicy == Never ?  → stop. P stays Pending.      │
├────────────────────────────────────────────────────────────────────┤
│ 2. For every node, simulate removing all Pods with a strictly      │
│    lower priority than P. Would P then fit and pass every filter?  │
│    Nodes where the answer is no are discarded.                     │
├────────────────────────────────────────────────────────────────────┤
│ 3. For each surviving node, compute the MINIMAL victim set:        │
│    put back the highest priority removable Pods, one at a time,    │
│    as long as P still fits. Fewer and less important victims win.  │
├────────────────────────────────────────────────────────────────────┤
│ 4. Choose ONE node among the candidates, preferring in order:      │
│      a. fewest PodDisruptionBudget violations                      │
│      b. lowest "highest priority" among its victims                │
│      c. smallest sum of victim priorities                          │
│      d. fewest victims                                             │
│      e. victim with the latest start time (kill the youngest work) │
├────────────────────────────────────────────────────────────────────┤
│ 5. Set P.status.nominatedNodeName = chosen node.                   │
├────────────────────────────────────────────────────────────────────┤
│ 6. Delete the victims gracefully, honouring their                  │
│    terminationGracePeriodSeconds. Victims get a DisruptionTarget   │
│    condition with reason PreemptionByScheduler.                    │
├────────────────────────────────────────────────────────────────────┤
│ 7. P returns to the queue and is retried. It is NOT guaranteed to  │
│    get the nominated node.                                         │
└────────────────────────────────────────────────────────────────────┘
```

Critical details that surprise people:

- **PDBs are a preference, not a rule.** Step 4a merely prefers nodes with fewer PDB violations. If every candidate violates a PDB, preemption proceeds anyway. Only the Eviction API respects PDBs absolutely. See [pod-disruption-budgets.md](pod-disruption-budgets.md).
- **Victims are terminated gracefully.** They are deleted with their normal grace period, which is why a high priority Pod can wait tens of seconds after preemption before it actually starts.
- **`nominatedNodeName` is a hint, not a reservation.** During the graceful termination window, another Pod can legitimately take the freed space. The preemptor is retried and may end up somewhere else, or may preempt again.
- **Cross node preemption does not exist.** The scheduler will not evict Pods on node X to make a Pod fit on node Y. Everything happens within one node's accounting.
- **Inter pod affinity limits preemption.** The scheduler does not support preempting a Pod on one node in order to satisfy a Pod affinity rule that a lower priority Pod on another node was providing.

```bash
# See the nomination
kubectl get pod important -o jsonpath='{.status.nominatedNodeName}{"\n"}'

# See the preemption from the victim's side
kubectl get events --field-selector reason=Preempted
# Preempted by pod 5f2c... on node worker-2

# See the effective numeric priority actually stored on a Pod
kubectl get pod important -o jsonpath='{.spec.priority}{"\n"}'
```

### Priority and Eviction Are Different Systems

| Mechanism | Trigger | Uses `spec.priority`? | Respects PDB? |
|-----------|---------|-----------------------|---------------|
| Scheduler preemption | A pending high priority Pod does not fit | Yes, centrally | Best effort only |
| Node pressure eviction (kubelet) | Node is low on memory, disk or PIDs | Yes, as one ranking input after QoS | ❌ No |
| API initiated eviction (`kubectl drain`) | A human or controller calls the Eviction API | No | ✅ Yes |
| Taint manager `NoExecute` | A taint the Pod does not tolerate | No | ❌ No |

---

## Custom Scheduling

### schedulerName

Every Pod carries `spec.schedulerName`, defaulting to `default-scheduler`. A scheduler process only picks up Pods whose name matches one of its profiles.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-scheduled
spec:
  schedulerName: my-scheduler
  containers:
    - name: app
      image: nginx:1.27
```

> ⚠️ If no running scheduler claims that name, the Pod stays `Pending` **with no events at all**. A Pending Pod with an empty Events section is almost always a `schedulerName` typo or a dead scheduler.

### Multiple Profiles in One Process

The cheapest form of "custom scheduling" needs no new binary at all: run the standard scheduler with two profiles.

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: /etc/kubernetes/scheduler.conf
leaderElection:
  leaderElect: true
profiles:
  # Profile 1: normal behaviour, spread the load.
  - schedulerName: default-scheduler

  # Profile 2: aggressive bin packing for batch work.
  - schedulerName: binpacking-scheduler
    pluginConfig:
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: MostAllocated
            resources:
              - name: cpu
                weight: 1
              - name: memory
                weight: 1
    plugins:
      score:
        disabled:
          - name: NodeResourcesBalancedAllocation

  # Profile 3: no scoring at all, first feasible node wins. Fastest possible.
  - schedulerName: fast-scheduler
    plugins:
      preScore:
        disabled:
          - name: '*'
      score:
        disabled:
          - name: '*'
```

Rules for multiple profiles:

- Every profile needs a **unique** `schedulerName`.
- A profile named `default-scheduler` should exist, because the API server defaults Pods to that name.
- All profiles share one queue, so they must all use the same `queueSort` plugin with identical configuration.
- `'*'` in a `disabled` list disables every default plugin at that extension point, and is also the way to re-order plugins.

### multiPoint

```yaml
profiles:
  - schedulerName: multipoint-scheduler
    plugins:
      # Enable MyPlugin at every extension point it implements.
      multiPoint:
        enabled:
          - name: MyPlugin
      # ...except Score, which we exclude explicitly.
      score:
        disabled:
          - name: '*'
```

Precedence, highest first: a specific extension point section, then `multiPoint`, then the built in defaults.

### Running a Second Scheduler as a Deployment

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-scheduler-config
  namespace: kube-system
data:
  my-scheduler-config.yaml: |
    apiVersion: kubescheduler.config.k8s.io/v1
    kind: KubeSchedulerConfiguration
    profiles:
      - schedulerName: my-scheduler
    leaderElection:
      leaderElect: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-scheduler
  namespace: kube-system
  labels:
    component: my-scheduler
spec:
  replicas: 1
  selector:
    matchLabels:
      component: my-scheduler
  template:
    metadata:
      labels:
        component: my-scheduler
    spec:
      serviceAccountName: my-scheduler
      priorityClassName: system-cluster-critical
      containers:
        - name: kube-scheduler
          image: registry.k8s.io/kube-scheduler:v1.31.0
          command:
            - /usr/local/bin/kube-scheduler
            - --config=/etc/kubernetes/my-scheduler-config.yaml
            - --v=2
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: config
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: my-scheduler-config
```

The ServiceAccount needs substantial RBAC. The pragmatic starting point is to bind the built in `system:kube-scheduler` ClusterRole plus permissions on `pods/binding`, and to grant leases in `kube-system` if leader election is enabled.

```bash
kubectl -n kube-system create serviceaccount my-scheduler
kubectl create clusterrolebinding my-scheduler-role \
  --clusterrole=system:kube-scheduler \
  --serviceaccount=kube-system:my-scheduler
kubectl create clusterrolebinding my-scheduler-volume \
  --clusterrole=system:volume-scheduler \
  --serviceaccount=kube-system:my-scheduler
```

> ⚠️ **Two schedulers can race.** If both claim the same Pod, one bind succeeds and the other gets a conflict error, and the losing scheduler's Reserve state has to be unwound. Always partition work by `schedulerName`; never run two processes serving the same profile name without leader election.

### Scheduler Extenders

An extender is a **webhook**, not a compiled plugin. The scheduler calls out over HTTP at chosen phases.

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
  - schedulerName: default-scheduler
extenders:
  - urlPrefix: "https://scheduler-extender.kube-system.svc:8443/scheduler"
    filterVerb: "filter"
    prioritizeVerb: "prioritize"
    preemptVerb: "preempt"
    bindVerb: ""            # empty means the extender does not bind
    weight: 1
    enableHTTPS: true
    nodeCacheCapable: true  # send node names only, not full node objects
    # Resources only this extender knows about; the scheduler will not try
    # to account for them itself.
    managedResources:
      - name: "example.com/fpga"
        ignoredByScheduler: true
    # If true, an extender failure does not fail the scheduling attempt.
    ignorable: true
    httpTimeout: 5s
```

| Aspect | Plugin (in tree or out of tree) | Extender (webhook) |
|--------|--------------------------------|--------------------|
| Language | Go, compiled into a scheduler binary | Any language, any process |
| Latency | In process, microseconds | Network round trip per scheduling attempt |
| Extension points | All of them | Filter, Prioritize, Preempt, Bind only |
| Failure handling | Standard framework semantics | `ignorable` decides whether failures are fatal |
| Deployment | Build and ship your own scheduler image | Deploy an ordinary Service |
| Recommended today | ✅ Preferred | Legacy, use only when you cannot ship a Go binary |

Extenders predate the scheduling framework. New work should use framework plugins, ideally starting from the `kubernetes-sigs/scheduler-plugins` repository, which packages community plugins such as coscheduling and capacity scheduling.

---

## The Descheduler

The scheduler makes a decision once, with the information available at that moment. The cluster then drifts.

```
t=0  Cluster is balanced, 3 nodes, 9 Pods, nicely spread.

t=1  node-3 is drained for maintenance.
     Its 3 Pods are rescheduled onto node-1 and node-2.

t=2  node-3 returns, empty.

t=3  Kubernetes does NOTHING. The scheduler never revisits a placed Pod.
     node-1 and node-2 are hot, node-3 is idle, forever.
```

The **descheduler** (`kubernetes-sigs/descheduler`) is a separate, optional component that fixes this. It never places Pods. It only **evicts** them, through the Eviction API, and lets the normal scheduler place the replacements.

```
┌────────────┐   evicts via Eviction API   ┌──────────────┐   places   ┌──────┐
│ descheduler│ ──────────────────────────► │ Pod recreated│ ─────────► │ node │
└────────────┘   (respects PDBs)           │ by controller│            └──────┘
                                           └──────────────┘
```

Commonly used descheduler plugins:

| Plugin | Evicts Pods when |
|--------|------------------|
| `RemoveDuplicates` | More than one Pod of the same ReplicaSet, ReplicationController, StatefulSet or Job sits on a single node |
| `LowNodeUtilization` | Some nodes are under a utilisation threshold while others are over a target; Pods are moved off the over utilised nodes |
| `HighNodeUtilization` | The opposite goal: consolidate onto fewer nodes so the autoscaler can remove the empty ones |
| `RemovePodsViolatingInterPodAntiAffinity` | An anti affinity rule became violated after the fact |
| `RemovePodsViolatingNodeAffinity` | Node labels changed so a running Pod no longer matches its own required node affinity (the fix for `IgnoredDuringExecution`) |
| `RemovePodsViolatingNodeTaints` | A `NoSchedule` taint was added that the Pod does not tolerate |
| `RemovePodsViolatingTopologySpreadConstraint` | The actual skew now exceeds `maxSkew` |
| `RemovePodsHavingTooManyRestarts` | A Pod has restarted more than a configured number of times |
| `PodLifeTime` | A Pod is older than a configured age, useful for forcing periodic recycling |

Operational cautions:

- Run it as a **CronJob** at first, not a Deployment, so you can observe what it does before letting it run continuously.
- It respects PodDisruptionBudgets, so a badly written PDB stops it silently.
- It can fight your workloads: evicting a Pod that will immediately be scheduled back to the same node produces an eviction loop. Configure `nodeFit` so it only evicts Pods that can actually land somewhere better.
- It is **not** part of Kubernetes and must be version matched to your cluster.

---

## Static Pods and Manual Scheduling

### Static Pods

A static Pod is defined by a file on the node, read directly by the kubelet. The API server, the scheduler and every controller are bypassed.

```bash
# The directory comes from the kubelet config, commonly:
grep staticPodPath /var/lib/kubelet/config.yaml
# staticPodPath: /etc/kubernetes/manifests

sudo ls /etc/kubernetes/manifests/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

```yaml
# /etc/kubernetes/manifests/node-agent.yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-agent
  namespace: kube-system
spec:
  # A static Pod is bound implicitly to the node whose kubelet read the file.
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
    - name: agent
      image: example.com/node-agent:1.2
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
```

| Property | Static Pod |
|----------|------------|
| Created by | kubelet, from a local file |
| Visible in the API? | Yes, as a read only **mirror Pod** named `<pod-name>-<node-name>` |
| Deleted by `kubectl delete pod`? | The mirror Pod is recreated immediately. Delete the file instead |
| Scheduled by kube-scheduler? | No |
| Survives an API server outage? | Yes, which is precisely why the control plane itself uses them |
| Managed by a controller? | No, there is no ReplicaSet or DaemonSet involved |

This is how kubeadm bootstraps a cluster: the kubelet starts `kube-apiserver` as a static Pod, which is the only way to run the API server before there is an API server.

### Manual Scheduling in a Broken Cluster

If the scheduler is down and you must place a Pod, you have three options, in increasing order of intrusiveness:

```bash
# 1. Set nodeName in the manifest (works for new Pods).
#    See the nodeName section above.

# 2. Bind an existing Pending Pod with the Binding subresource.
#    See the bind operation section above.

# 3. Convert the workload to a static Pod on the node.
sudo cp emergency.yaml /etc/kubernetes/manifests/
```

```bash
# Find Pods nobody has scheduled
kubectl get pods -A --field-selector spec.nodeName=""
# Or, equivalently
kubectl get pods -A --field-selector status.phase=Pending
```

---

## Troubleshooting

### Step 1: Read the Event, Not the Status

```bash
kubectl describe pod my-pod
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  32s   default-scheduler  0/5 nodes are available:
           3 Insufficient cpu, 2 node(s) had untolerated taint {workload: gpu}.
           preemption: 0/5 nodes are available: 3 No preemption victims found
           for incoming pod, 2 Preemption is not helpful for scheduling.
```

### Decoding the Message

```
0/5 nodes are available: 3 Insufficient cpu, 2 node(s) had untolerated taint
│  │                     │                   │
│  │                     │                   └─ 2 nodes were rejected by the
│  │                     │                      TaintToleration filter
│  │                     └───────────────────── 3 nodes were rejected by the
│  │                                            NodeResourcesFit filter
│  └─────────────────────────────────────────── total nodes considered
└────────────────────────────────────────────── nodes that passed ALL filters

The counts always add up to the total. If they do not, the message was
truncated: the scheduler summarises when there are many distinct reasons.
```

### Reason Catalogue

| Message fragment | Real cause | First thing to check |
|------------------|------------|----------------------|
| `Insufficient cpu` / `Insufficient memory` | Sum of **requests** on the node plus this Pod exceeds allocatable | `kubectl describe node <n>` and read the Allocated resources table |
| `Insufficient nvidia.com/gpu` | Extended resource unavailable or the device plugin is not running | `kubectl get node <n> -o jsonpath='{.status.allocatable}'` |
| `node(s) had untolerated taint {key: value}` | Missing toleration | `kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints` |
| `node(s) were unschedulable` | The node is cordoned | `kubectl uncordon <node>` if that is correct |
| `node(s) didn't match Pod's node affinity/selector` | Label mismatch, often a typo or a missing zone label | `kubectl get nodes --show-labels` |
| `node(s) didn't match pod topology spread constraints` | A `DoNotSchedule` constraint is at `maxSkew` | Count Pods per domain; consider `ScheduleAnyway` |
| `node(s) didn't satisfy existing pods anti-affinity rules` | Required anti affinity, usually replicas exceeding node count | Compare replica count with eligible node count |
| `node(s) had volume node affinity conflict` | The PV is pinned to a zone or node the Pod cannot use | `kubectl get pv <pv> -o yaml` and read `nodeAffinity` |
| `didn't find available persistent volumes to bind` | No PV matches the PVC and no dynamic provisioner ran | `kubectl get pvc,sc` |
| `node(s) exceed max volume count` | Node is at its attachable volume limit | Spread the Pods or use fewer volumes per Pod |
| `node(s) didn't have free ports for the requested pod ports` | Two Pods want the same `hostPort` | Stop using `hostPort`, or use a DaemonSet |
| `pod has unbound immediate PersistentVolumeClaims` | PVC with `Immediate` binding mode is still unbound | Check the provisioner logs |
| **No events at all** | Nothing is watching this Pod | Check `spec.schedulerName`, check the scheduler is running, check `spec.schedulingGates` |

### Step 2: Confirm With Node Data

```bash
# What the scheduler thinks each node has left
kubectl describe node worker-1 | sed -n '/Allocated resources/,/^Events/p'
# Allocated resources:
#   Resource           Requests      Limits
#   cpu                3200m (80%)   6 (150%)
#   memory             5Gi (65%)     8Gi (104%)
#
# Requests is the number that matters for scheduling. Limits over 100% is
# normal and merely means the node is overcommitted.

# Sum of requests across every Pod on a node, computed yourself
kubectl get pods -A --field-selector spec.nodeName=worker-1 \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CPU:.spec.containers[*].resources.requests.cpu,MEM:.spec.containers[*].resources.requests.memory'

# Actual usage, which is a completely different question
kubectl top nodes
kubectl top pods -A --sort-by=cpu
```

### Step 3: Simulate

```bash
# Would this Pod be allowed at all? (admission only, not scheduling)
kubectl apply -f pod.yaml --dry-run=server

# What does the scheduler actually log?
kubectl -n kube-system logs -l component=kube-scheduler --tail=200
# Or, on a kubeadm control plane node:
kubectl -n kube-system logs kube-scheduler-cp-1 | grep -i "my-pod"

# Raise verbosity temporarily by editing the static Pod manifest and
# adding --v=4. The kubelet restarts the scheduler automatically.
sudo vi /etc/kubernetes/manifests/kube-scheduler.yaml
```

### Useful Scheduler Metrics

```bash
kubectl -n kube-system port-forward pod/kube-scheduler-cp-1 10259:10259 &
curl -sk https://127.0.0.1:10259/metrics | grep -E \
  'scheduler_pending_pods|scheduler_schedule_attempts_total|scheduler_scheduling_attempt_duration_seconds|scheduler_preemption'
```

| Metric | Tells you |
|--------|-----------|
| `scheduler_pending_pods{queue=...}` | How many Pods sit in `active`, `backoff` and `unschedulable`. A growing `unschedulable` count is a capacity or constraint problem |
| `scheduler_schedule_attempts_total{result=...}` | Ratio of `scheduled`, `unschedulable` and `error` |
| `scheduler_scheduling_attempt_duration_seconds` | End to end latency per attempt. Watch this when you enable inter pod affinity |
| `scheduler_preemption_attempts_total` | How often preemption is being used, which is usually higher than people expect |
| `scheduler_pod_scheduling_duration_seconds` | Total time from Pod creation to bind, including all retries |

### Decision Tree for a Pending Pod

```
Pod is Pending
  │
  ├─ Does `kubectl describe pod` show FailedScheduling events?
  │    ├─ NO  → Check spec.schedulerName, spec.schedulingGates,
  │    │        and whether kube-scheduler is running at all.
  │    └─ YES → read the counts in the message
  │             │
  │             ├─ "Insufficient <resource>"
  │             │     → capacity problem. Reduce requests, add nodes,
  │             │       or use priority so this Pod preempts.
  │             │
  │             ├─ "untolerated taint"
  │             │     → add a toleration, or remove the taint.
  │             │
  │             ├─ "didn't match Pod's node affinity/selector"
  │             │     → label mismatch. Compare with kubectl get nodes --show-labels.
  │             │
  │             ├─ "topology spread" or "anti-affinity"
  │             │     → too strict for the current cluster shape.
  │             │       Switch DoNotSchedule → ScheduleAnyway, or
  │             │       required → preferred, or add nodes/domains.
  │             │
  │             └─ volume related
  │                   → PV, PVC, StorageClass or zone problem. See install-csi-*.md.
  │
  └─ Is spec.nodeName already set but the Pod is still Pending?
       → NOT a scheduler problem. Go and look at that node's kubelet.
```

---

## Exam and Interview Traps

1. **The scheduler does not start Pods.** It writes `spec.nodeName` via the Binding subresource. The kubelet on the target node does everything visible.
2. **A Pod with `spec.nodeName` set is never seen by the scheduler**, so taints, cordons, topology spread and resource fit are all skipped. The kubelet may still reject it with `OutOfcpu`.
3. **`kubectl cordon` sets `spec.unschedulable: true`**, which produces the taint `node.kubernetes.io/unschedulable:NoSchedule`. Running Pods are untouched. `kubectl drain` is cordon plus eviction.
4. **A toleration does not attract.** It only removes a barrier. To pull a Pod towards a pool you need `nodeSelector` or node affinity as well.
5. **`operator: Exists` in a toleration forbids `value`.** `operator: Exists` in a node affinity expression forbids `values`. Setting them is a validation error, not a silent no-op.
6. **An empty `key` with `operator: Exists` tolerates every taint**, including `NoExecute` node condition taints. That is almost never what an application Pod wants.
7. **`tolerationSeconds` only applies to `NoExecute`.** On a `NoSchedule` toleration it is ignored.
8. **Everything is `IgnoredDuringExecution`.** Changing a node label never evicts a running Pod. Only `NoExecute` taints do.
9. **`nodeSelectorTerms` are OR'ed, `matchExpressions` within one term are AND'ed.** Reversing this is the most common node affinity mistake.
10. **`Gt` and `Lt` take exactly one integer value** and are not available in `matchFields`.
11. **The required and preferred forms have different shapes.** Required is a list of terms; preferred is a list of `{weight, podAffinityTerm}` for Pod affinity and `{weight, preference}` for node affinity.
12. **`topologySpreadConstraints[].labelSelector` has no default.** Omitting it means no Pods are counted and the constraint does nothing.
13. **Nodes lacking the `topologyKey` label are excluded** from both topology spread and inter pod affinity calculations.
14. **Required hostname anti affinity caps replicas at the node count** and can deadlock rolling updates.
15. **`whenUnsatisfiable: DoNotSchedule` is the default** for topology spread. If you wanted a soft hint you must say `ScheduleAnyway`.
16. **`minDomains` only works with `DoNotSchedule`.**
17. **Preemption respects PodDisruptionBudgets only as a tiebreaker.** The Eviction API respects them absolutely. Node pressure eviction ignores them completely.
18. **`preemptionPolicy: Never` still gives queue priority.** The Pod jumps ahead of lower priority Pods in the queue but evicts nobody.
19. **`nominatedNodeName` is not a reservation.** The preemptor can lose the space it created.
20. **Only one PriorityClass may have `globalDefault: true`**, and changing a PriorityClass value does not update Pods already admitted.
21. **Preemption is within a single node.** There is no cross node consolidation.
22. **A Pending Pod with no events** points to `schedulerName`, scheduling gates, or a scheduler that is not running, never to capacity.
23. **DaemonSet Pods are scheduled by the default scheduler** using node affinity written by the DaemonSet controller, and they carry broad automatic tolerations.
24. **All profiles in one scheduler share one queue** and therefore one `queueSort` plugin.
25. **`Unreserve` must never fail.** It is the rollback of last resort in the framework.
26. **Scoring never rescues an infeasible node.** Filtering is absolute.

---

## Quick Reference

```bash
# ---------- Nodes ----------
kubectl get nodes --show-labels
kubectl get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
kubectl describe node worker-1 | sed -n '/Allocated resources/,/^Events/p'

# ---------- Labels and taints ----------
kubectl label node worker-1 disktype=ssd
kubectl label node worker-1 disktype-                 # remove
kubectl taint node worker-1 dedicated=team-a:NoSchedule
kubectl taint node worker-1 dedicated=team-a:NoSchedule-   # remove
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-

# ---------- Cordon and drain ----------
kubectl cordon worker-1
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
kubectl uncordon worker-1

# ---------- Scheduling state ----------
kubectl get pods -A --field-selector spec.nodeName=""
kubectl get events --field-selector reason=FailedScheduling -A
kubectl get pod my-pod -o jsonpath='{.status.nominatedNodeName}{"\n"}'
kubectl get pod my-pod -o jsonpath='{.spec.priority}{"\n"}'
kubectl get pod my-pod -o jsonpath='{.spec.schedulerName}{"\n"}'

# ---------- Priority ----------
kubectl get priorityclass
kubectl get priorityclass -o custom-columns=NAME:.metadata.name,VALUE:.value,DEFAULT:.globalDefault

# ---------- Placement audit ----------
kubectl get pods -o wide --sort-by=.spec.nodeName
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
```

### Field Location Map

| Field | Path |
|-------|------|
| Node name chosen | `pod.spec.nodeName` |
| Scheduler to use | `pod.spec.schedulerName` |
| Simple label match | `pod.spec.nodeSelector` |
| Node affinity | `pod.spec.affinity.nodeAffinity` |
| Pod affinity | `pod.spec.affinity.podAffinity` |
| Pod anti affinity | `pod.spec.affinity.podAntiAffinity` |
| Tolerations | `pod.spec.tolerations` |
| Topology spread | `pod.spec.topologySpreadConstraints` |
| Priority class name | `pod.spec.priorityClassName` |
| Resolved priority | `pod.spec.priority` |
| Scheduling gates | `pod.spec.schedulingGates` |
| Preemption nomination | `pod.status.nominatedNodeName` |
| Node taints | `node.spec.taints` |
| Cordon flag | `node.spec.unschedulable` |
| Node capacity and allocatable | `node.status.capacity`, `node.status.allocatable` |

---

## Related Topics

- [kube-scheduler](kube-scheduler.md)
- [Resource Management](resource-management.md)
- [Pod Disruption Budgets](pod-disruption-budgets.md)
- [Cgroups](cgroups.md)
- [Pods](pods.md)
- [Pod Lifecycle](pod-lifecycle.md)
- [Pod Operations](pod-operations.md)
- [Deployments](deployments.md)
- [Deployment Strategies](deployment-strategies.md)
- [ReplicaSets](replicasets.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [Controllers](controllers.md)
- [kubelet](kubelet.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-apiserver](kube-apiserver.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [Worker Node](worker-node.md)
- [Control Plane Node](control-plane-node.md)
- [Kubernetes Architecture](k8s-architecture.md)
- [Downward API](downward-api.md)

---

## Key Takeaways

1. **Scheduling is the act of writing one field.** The scheduler chooses a node and POSTs a `Binding` to `pods/binding`, which sets `spec.nodeName`. The kubelet on that node, not the scheduler, pulls images and starts containers.
2. **Every attempt is a scheduling cycle plus a binding cycle.** Scheduling cycles are serial; binding cycles run concurrently. Between them the Pod is "assumed" onto the node in the scheduler's cache so concurrent decisions do not double book capacity.
3. **The queue is three structures.** `activeQ` for ready Pods ordered by `PrioritySort`, `backoffQ` for recently failed Pods with exponential backoff, and `unschedulablePods` for Pods waiting on a cluster change. Cluster events, not polling, are what wake a Pod up.
4. **Filtering is boolean, scoring is a weighted sum.** No score can rescue a node that a filter rejected, and no filter cares how good a node is.
5. **`NodeResourcesFit` filters on requests, never on actual usage.** A node running at 5 percent CPU can still be rejected for `Insufficient cpu` if its Pods have large requests.
6. **`NodeResourcesFit` also decides bin packing versus spreading** through `scoringStrategy`: `LeastAllocated` by default, `MostAllocated` for consolidation and `RequestedToCapacityRatio` for a custom curve.
7. **`nodeName` bypasses the entire scheduler**, including taints, cordons and capacity checks. It belongs in debugging and bootstrap, never in a Deployment.
8. **Node affinity is `nodeSelector` with expressions and a soft mode.** Terms are OR'ed, expressions inside a term are AND'ed, `Gt` and `Lt` take exactly one integer, and `Exists` and `DoesNotExist` must have no values.
9. **`IgnoredDuringExecution` is universal.** Changing a node label never moves a running Pod. Only a `NoExecute` taint, node pressure eviction, preemption or a deliberate eviction can.
10. **`topologyKey` defines the failure domain**, and a node missing that label is invisible to the rule. `kubernetes.io/hostname` means per node, `topology.kubernetes.io/zone` means per zone.
11. **Required hostname anti affinity is a replica cap.** Replicas cannot exceed the number of eligible nodes, and rolling updates can deadlock. Prefer `preferred`, or prefer topology spread.
12. **Inter pod affinity costs O(nodes × pods)** and is explicitly discouraged in large clusters. Use `topologySpreadConstraints` for spreading and reserve `podAffinity` for genuine co-location.
13. **Taints repel, tolerations permit, and neither attracts.** A dedicated node pool needs a taint plus a toleration plus a label plus a selector, all four.
14. **The three effects are `NoSchedule`, `PreferNoSchedule` and `NoExecute`**, and only `NoExecute` touches running Pods. `tolerationSeconds` applies only to `NoExecute`.
15. **Every Pod silently tolerates `not-ready` and `unreachable` for 300 seconds**, injected by the `DefaultTolerationSeconds` admission controller. That is the five minute delay you see when a node goes offline.
16. **Topology spread is quantitative anti affinity.** `maxSkew` sets how uneven the distribution may get, `whenUnsatisfiable` decides whether the rule is a filter or a score, `minDomains` prevents pretending a missing domain does not exist, and `matchLabelKeys: [pod-template-hash]` stops old and new ReplicaSets from being counted together.
17. **Set `labelSelector` on every topology spread constraint.** It has no default, and an omitted selector makes the constraint do nothing.
18. **Priority orders the queue; preemption frees space.** Preemption runs only in PostFilter, only within one node, prefers victim sets with fewest PDB violations and lowest priority, terminates victims gracefully, and records `status.nominatedNodeName` as a hint rather than a reservation.
19. **`preemptionPolicy: Never` keeps the queue advantage without the evictions**, which is the right setting for important but non urgent workloads.
20. **PDBs bind the Eviction API absolutely, preemption only as a tiebreaker, and node pressure eviction not at all.**
21. **Custom scheduling has three levels**: a second profile in the existing scheduler (cheapest), a second scheduler process selected by `spec.schedulerName`, or framework plugins compiled into your own binary. Extenders are the legacy webhook option, limited to Filter, Prioritize, Preempt and Bind.
22. **A Pending Pod with no events means nobody is watching it.** Check `schedulerName`, scheduling gates and whether the scheduler is alive, before you look at capacity.
23. **`FailedScheduling` messages are structured.** `0/5 nodes are available: 3 Insufficient cpu, 2 node(s) had untolerated taint` names every filter that rejected nodes, with counts that sum to the total.
24. **Kubernetes never rebalances by itself.** The descheduler is the optional complement that evicts drifted Pods through the Eviction API so the scheduler can place them again; it respects PDBs and needs `nodeFit` to avoid eviction loops.
25. **Static Pods are the escape hatch below all of this.** The kubelet reads them from disk, binds them implicitly, and keeps them running with no API server, which is exactly how the control plane bootstraps itself.

---

## References

- [Kubernetes Scheduler](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)
- [Scheduling Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/)
- [Scheduler Configuration](https://kubernetes.io/docs/reference/scheduling/config/)
- [kube-scheduler Configuration (v1) API reference](https://kubernetes.io/docs/reference/config-api/kube-scheduler-config.v1/)
- [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- [Pod Scheduling Readiness](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-scheduling-readiness/)
- [Scheduler Performance Tuning](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduler-perf-tuning/)
- [Resource Bin Packing](https://kubernetes.io/docs/concepts/scheduling-eviction/resource-bin-packing/)
- [Configure Multiple Schedulers](https://kubernetes.io/docs/tasks/extend-kubernetes/configure-multiple-schedulers/)
- [Assign Pods to Nodes using Node Affinity](https://kubernetes.io/docs/tasks/configure-pod-container/assign-pods-nodes-using-node-affinity/)
- [Well-Known Labels, Annotations and Taints](https://kubernetes.io/docs/reference/labels-annotations-taints/)
- [Static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
- [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [API-initiated Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/)
- [Node-pressure Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Pod API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
- [PriorityClass API reference (scheduling.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/priority-class-v1/)
- [Descheduler for Kubernetes](https://github.com/kubernetes-sigs/descheduler)
- [Scheduler Plugins](https://github.com/kubernetes-sigs/scheduler-plugins)
