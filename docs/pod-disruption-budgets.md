# 🛡️ Pod Disruption Budgets: Surviving Voluntary Disruption

A practical guide to PodDisruptionBudgets: what they protect against, how the Eviction API enforces them, why they can deadlock a cluster upgrade, and how to write them so they never do.

## 📋 Table of Contents
- [Voluntary versus Involuntary Disruption](#voluntary-versus-involuntary-disruption)
- [The PodDisruptionBudget Object](#the-poddisruptionbudget-object)
- [minAvailable versus maxUnavailable](#minavailable-versus-maxunavailable)
- [Percentages and Rounding](#percentages-and-rounding)
- [unhealthyPodEvictionPolicy](#unhealthypodevictionpolicy)
- [The Eviction API](#the-eviction-api)
- [What Ignores a PDB](#what-ignores-a-pdb)
- [The Disruption Controller and Status Fields](#the-disruption-controller-and-status-fields)
- [Worked Example: A Three Replica Web App](#worked-example-a-three-replica-web-app)
- [Worked Example: A Quorum Based Datastore](#worked-example-a-quorum-based-datastore)
- [Worked Example: The Single Replica Deadlock](#worked-example-the-single-replica-deadlock)
- [The Classic Upgrade Failure](#the-classic-upgrade-failure)
- [Interaction with Workload Controllers](#interaction-with-workload-controllers)
- [Interaction with the Cluster Autoscaler](#interaction-with-the-cluster-autoscaler)
- [PDBs in an Upgrade Runbook](#pdbs-in-an-upgrade-runbook)
- [Verifying and Reading a PDB](#verifying-and-reading-a-pdb)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Voluntary versus Involuntary Disruption

A Pod disappears for one of two reasons, and a PodDisruptionBudget can only influence one of them.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Why did my Pod die?                             │
├────────────────────────────────────┬─────────────────────────────────────┤
│         VOLUNTARY                  │          INVOLUNTARY                │
│  Somebody decided to do it         │  The universe did it                │
│  There is a decision point where   │  There is nothing to ask permission │
│  permission can be asked           │  from, and no time to ask           │
├────────────────────────────────────┼─────────────────────────────────────┤
│  A PDB can BLOCK these             │  A PDB CANNOT block these           │
│                                    │  (but they still consume the budget)│
└────────────────────────────────────┴─────────────────────────────────────┘
```

| Event | Class | Blocked by a PDB? | Notes |
|-------|-------|-------------------|-------|
| `kubectl drain` on a node | Voluntary | ✅ Yes | The drain calls the Eviction API for each Pod |
| Any direct call to the Eviction API | Voluntary | ✅ Yes | This is the only enforcement path |
| Cluster Autoscaler scaling a node group down | Voluntary | ✅ Yes | It uses the Eviction API |
| The descheduler rebalancing Pods | Voluntary | ✅ Yes | It uses the Eviction API |
| A managed node pool upgrade by a cloud provider | Voluntary | ✅ Usually | Only if the provider drains rather than deletes; confirm with your provider |
| `kubectl delete pod` | Voluntary in spirit | ❌ **No** | A plain DELETE bypasses the Eviction API entirely |
| `kubectl delete deployment` | Voluntary in spirit | ❌ **No** | Deleting the owner cascades to the Pods |
| A Deployment rolling update | Voluntary in spirit | ❌ **No** | Governed by `maxUnavailable` on the Deployment, not by the PDB |
| Scaling a Deployment down | Voluntary in spirit | ❌ **No** | The ReplicaSet deletes Pods directly |
| Scheduler preemption for a higher priority Pod | Involuntary from the victim's view | ⚠️ Best effort only | Preemption prefers victim sets with fewer PDB violations, but proceeds regardless |
| kubelet node pressure eviction (out of memory or disk) | Involuntary | ❌ No | The kubelet is saving the node and cannot negotiate |
| A `NoExecute` taint applied to the node | Involuntary | ❌ No | The taint manager deletes Pods directly |
| Node hardware failure or kernel panic | Involuntary | ❌ No | Nothing to intercept |
| Network partition isolating the node | Involuntary | ❌ No | Pods are deleted after the unreachable toleration expires |
| Cloud instance terminated or preempted | Involuntary | ❌ No | The VM is already gone |
| The container OOMKilled by its own memory limit | Involuntary | ❌ No | This is a restart, not a Pod deletion |

Two consequences that people find counterintuitive:

1. **Involuntary disruptions still consume the budget.** If a node dies and takes one of your three replicas with it, the PDB now sees two healthy Pods, and it will refuse the next voluntary eviction until a replacement is Ready. The PDB does not prevent the failure; it prevents *compounding* the failure.
2. **A PDB is not a high availability feature by itself.** It is a coordination protocol between the application owner (who knows how much disruption is safe) and the cluster operator (who needs to drain nodes). Actual availability still comes from replicas, spread, probes and sensible rolling updates.

```bash
# Which of these hit your Pod? The DisruptionTarget condition names the cause.
kubectl get pod web-abc -o jsonpath='{.status.conditions[?(@.type=="DisruptionTarget")]}{"\n"}'
```

| `reason` on the `DisruptionTarget` condition | Meaning |
|----------------------------------------------|---------|
| `EvictionByEvictionAPI` | Someone called the Eviction API, for example `kubectl drain` |
| `PreemptionByScheduler` | A higher priority Pod needed the space |
| `DeletionByTaintManager` | A `NoExecute` taint the Pod did not tolerate |
| `DeletionByPodGC` | The Pod's node no longer exists |
| `TerminationByKubelet` | Node pressure eviction, graceful node shutdown, or critical Pod admission |

---

## The PodDisruptionBudget Object

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: production
spec:
  # Set EXACTLY ONE of minAvailable or maxUnavailable.
  minAvailable: 2
  # maxUnavailable: 1

  # Required. Which Pods this budget protects.
  # In policy/v1 an EMPTY selector matches EVERY Pod in the namespace.
  selector:
    matchLabels:
      app: web

  # IfHealthyBudget (default) or AlwaysAllow.
  unhealthyPodEvictionPolicy: AlwaysAllow
```

| Field | Type | Notes |
|-------|------|-------|
| `spec.selector` | Label selector | Required. Normally identical to the owning controller's `spec.selector` |
| `spec.minAvailable` | Integer or percentage string | How many Pods must remain **available** after an eviction |
| `spec.maxUnavailable` | Integer or percentage string | How many Pods may be **unavailable** at once |
| `spec.unhealthyPodEvictionPolicy` | Enum | Whether running but unready Pods can be evicted when the budget is already breached |

### Why Only One of the Two

`minAvailable` and `maxUnavailable` are two views of the same constraint, and the API rejects an object that sets both. Which one you choose changes how the budget behaves when the workload is **scaled**.

```
Deployment with replicas: 5

  minAvailable: 4        →  1 disruption allowed
  maxUnavailable: 1      →  1 disruption allowed
                            identical, today

Someone scales to 10 replicas:

  minAvailable: 4        →  6 disruptions allowed   (probably not intended)
  maxUnavailable: 1      →  1 disruption allowed    (scales correctly)

Someone scales to 3 replicas:

  minAvailable: 4        →  0 disruptions allowed, and every drain blocks
  maxUnavailable: 1      →  1 disruption allowed    (still sensible)
```

> 🔑 **Prefer `maxUnavailable` for ordinary replicated services.** It expresses "how much churn can I take", which is a property of the application, and it automatically tracks the replica count. Use `minAvailable` when the number is an absolute floor derived from the protocol, such as a quorum size.

### Where the Denominator Comes From

The "intended" number of Pods is not counted from running Pods. The disruption controller resolves it from the **owning workload resource**:

```
Pod  ──metadata.ownerReferences──►  ReplicaSet  ──►  spec.replicas
Pod  ──metadata.ownerReferences──►  StatefulSet ──►  spec.replicas
```

That is why the restrictions on unmanaged Pods exist:

| Pod ownership | `minAvailable` integer | `minAvailable` percentage | `maxUnavailable` |
|---------------|------------------------|---------------------------|------------------|
| Deployment, ReplicaSet, ReplicationController, StatefulSet | ✅ | ✅ | ✅ |
| A custom resource that implements the `scale` subresource | ✅ | ✅ | ✅ |
| An operator managed resource without `scale`, or bare Pods | ✅ | ❌ | ❌ |

Without a scale aware owner, Kubernetes cannot compute a total, so only an absolute floor is meaningful.

> ⚠️ **`maxUnavailable` requires that all selected Pods share one controller.** A selector spanning two Deployments makes the denominator ambiguous, and the budget will not behave the way you expect.

---

## minAvailable versus maxUnavailable

```
Deployment: 6 replicas, all healthy.

  minAvailable: 4
  ┌───┬───┬───┬───┬───┬───┐
  │ ✔ │ ✔ │ ✔ │ ✔ │ ✔ │ ✔ │   currentHealthy 6, desiredHealthy 4
  └───┴───┴───┴───┴───┴───┘   disruptionsAllowed = 6 - 4 = 2
     evict 2 → 4 remain → at the floor → disruptionsAllowed = 0

  maxUnavailable: 2
  ┌───┬───┬───┬───┬───┬───┐
  │ ✔ │ ✔ │ ✔ │ ✔ │ ✔ │ ✔ │   expectedPods 6, so desiredHealthy = 6 - 2 = 4
  └───┴───┴───┴───┴───┴───┘   disruptionsAllowed = 6 - 4 = 2

Internally both are converted to the same thing:
    desiredHealthy   = the number that must survive
    disruptionsAllowed = currentHealthy - desiredHealthy   (never below 0)
```

| Intent | Write |
|--------|-------|
| "Never drop below 90 percent of serving capacity" | `minAvailable: "90%"` |
| "Only ever take one Pod at a time" | `maxUnavailable: 1` |
| "Never lose quorum of 5" | `minAvailable: 3` |
| "Never voluntarily disrupt this at all" | `maxUnavailable: 0` (see the deadlock warning) |
| "I do not care, drain freely" | Do not create a PDB |

---

## Percentages and Rounding

Percentages are resolved against the intended replica count, and **Kubernetes rounds up in both cases**. The consequences differ, and one of them is genuinely surprising.

```
minAvailable: "50%"  with 7 replicas
    0.5 * 7 = 3.5  →  rounded UP  →  4 Pods must remain available
    disruptionsAllowed = 7 - 4 = 3
    Effect: rounding up makes the budget STRICTER. Safe.

maxUnavailable: "50%" with 7 replicas
    0.5 * 7 = 3.5  →  rounded UP  →  4 Pods may be unavailable
    Effect: rounding up makes the budget LOOSER. A disruption can exceed
    the percentage you wrote.

maxUnavailable: "30%" with 1 replica
    0.3 * 1 = 0.3  →  rounded UP  →  1 Pod may be unavailable
    Effect: 100 percent of the application can be disrupted, from a
    budget that says 30 percent.
```

> ⚠️ **`maxUnavailable` as a percentage on a small replica count is close to meaningless.** With one or two replicas the rounding swallows the intent. Use integers whenever the replica count is small, and reserve percentages for workloads with tens of replicas.

```bash
# Never trust the arithmetic in your head. Read the resolved numbers.
kubectl get pdb web-pdb -o jsonpath='{.status}{"\n"}' | python3 -m json.tool
# {
#   "currentHealthy": 7,
#   "desiredHealthy": 4,
#   "disruptionsAllowed": 3,
#   "expectedPods": 7,
#   "observedGeneration": 1
# }
```

---

## unhealthyPodEvictionPolicy

This field answers one specific question: **may a running but unready Pod be evicted when the budget is already exhausted?**

```yaml
spec:
  unhealthyPodEvictionPolicy: AlwaysAllow
```

| Policy | Behaviour for a Pod in `phase: Running` that is **not** `Ready` |
|--------|----------------------------------------------------------------|
| `IfHealthyBudget` (default when the field is omitted) | Evictable only if the guarded application is not already disrupted, that is `currentHealthy >= desiredHealthy` |
| `AlwaysAllow` | Always evictable, regardless of the budget |

Pods in `Pending`, `Succeeded` or `Failed` are always considered for eviction under either policy. "Healthy" means the Pod has a `Ready` condition with status `True`, which is what `status.currentHealthy` counts.

### Why This Field Exists

```
Deployment with 3 replicas. A bad image is rolled out. All 3 Pods are
Running but stuck in CrashLoopBackOff, so none of them are Ready.

    currentHealthy   = 0
    desiredHealthy   = 2
    disruptionsAllowed = 0

With IfHealthyBudget (the default):
    Eviction of a broken Pod is REFUSED, because currentHealthy (0)
    is below desiredHealthy (2).
    → kubectl drain hangs forever, on a completely broken application
      that has nothing left to protect.

With AlwaysAllow:
    Broken Pods are evicted immediately.
    → The drain completes. The Deployment recreates the Pods elsewhere,
      where they carry on crash looping, which is the application team's
      problem rather than the cluster operator's.
```

> 💡 **Recommendation: set `unhealthyPodEvictionPolicy: AlwaysAllow` on essentially every PDB.** The default exists to give unready Pods the best chance to become healthy, but in practice the failure mode it creates (a misbehaving application blocking every node drain in the cluster) is far more damaging than the protection it offers. The upstream documentation itself recommends `AlwaysAllow` to support node drains.

---

## The Eviction API

`kubectl drain` does not delete Pods. It creates `Eviction` objects against a Pod **subresource**, and the API server decides whether the eviction is permitted.

```yaml
# POST to /api/v1/namespaces/production/pods/web-abc123/eviction
apiVersion: policy/v1
kind: Eviction
metadata:
  name: web-abc123
  namespace: production
deleteOptions:
  gracePeriodSeconds: 30
```

```bash
kubectl proxy --port=8001 &
curl -s -X POST http://127.0.0.1:8001/api/v1/namespaces/production/pods/web-abc123/eviction \
  -H 'Content-Type: application/json' \
  -d '{"apiVersion":"policy/v1","kind":"Eviction",
       "metadata":{"name":"web-abc123","namespace":"production"}}'
```

### The Decision Path

```
POST .../pods/<name>/eviction
        │
        ▼
┌────────────────────────────────────────────────────────────┐
│ Does any PDB select this Pod?                              │
│   no  → allow, delete the Pod gracefully. Done.            │
└────────────────────┬───────────────────────────────────────┘
                     │ yes
                     ▼
┌────────────────────────────────────────────────────────────┐
│ Do MULTIPLE PDBs select this Pod?                          │
│   yes → REFUSE. Overlapping budgets are not resolvable.    │
└────────────────────┬───────────────────────────────────────┘
                     │ exactly one
                     ▼
┌────────────────────────────────────────────────────────────┐
│ Is the Pod healthy (Ready=True)?                           │
│   no  → apply unhealthyPodEvictionPolicy                   │
│   yes → continue                                           │
└────────────────────┬───────────────────────────────────────┘
                     ▼
┌────────────────────────────────────────────────────────────┐
│ Is status.disruptionsAllowed > 0 ?                         │
│   no  → REFUSE with HTTP 429 TooManyRequests               │
│   yes → decrement the budget, record the Pod in            │
│         status.disruptedPods, then delete gracefully       │
└────────────────────────────────────────────────────────────┘
```

The refusal is **HTTP 429 Too Many Requests**, deliberately chosen because it means "not now, try again", not "never". `kubectl drain` retries in a loop until it succeeds or hits `--timeout`.

```
error when evicting pods/"web-abc123" -n "production" (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
```

### Eviction Is a Graceful Delete

An accepted eviction deletes the Pod normally: `preStop` hooks run, `SIGTERM` is sent, and `terminationGracePeriodSeconds` is honoured. Eviction is not a kill.

### drain versus delete

| | `kubectl drain <node>` | `kubectl delete pod <name>` |
|---|------------------------|------------------------------|
| API path | `pods/<name>/eviction` | `DELETE pods/<name>` |
| Respects PDBs | ✅ Yes | ❌ No |
| Cordons the node first | ✅ Yes | Not applicable |
| Retries on refusal | ✅ Yes, until `--timeout` | Not applicable |
| Handles DaemonSet Pods | Refuses unless `--ignore-daemonsets` | Deletes, and the DaemonSet recreates it |
| Handles unmanaged Pods | Refuses unless `--force` | Deletes permanently |
| Handles `emptyDir` data | Refuses unless `--delete-emptydir-data` | Deletes, data is gone |
| Typical use | Node maintenance and upgrades | Restarting one Pod, incident response |

```bash
# The standard, safe drain
kubectl drain worker-2 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=15m

# See exactly what it would do, without doing it
kubectl drain worker-2 --ignore-daemonsets --dry-run=client

# The emergency escape hatch: skip the Eviction API entirely.
# This IGNORES every PodDisruptionBudget in the cluster. Know why you are
# doing it before you type it.
kubectl drain worker-2 --ignore-daemonsets --disable-eviction
```

> ⚠️ `--disable-eviction` makes `drain` use plain deletes. It is the correct tool when a node is dying and you need the Pods rescheduled immediately, and it is a serious mistake during a routine upgrade, because it silently discards every availability guarantee your teams wrote down.

---

## What Ignores a PDB

This list is worth memorising, because almost every "my PDB did not protect me" incident is on it.

| Actor | Respects PDB? | Why |
|-------|---------------|-----|
| Eviction API | ✅ Absolutely | It is the enforcement point |
| `kubectl drain` | ✅ Yes | It calls the Eviction API |
| Cluster Autoscaler scale down | ✅ Yes | It calls the Eviction API |
| Descheduler | ✅ Yes | It calls the Eviction API |
| **`kubectl delete pod`** | ❌ No | A plain DELETE never consults the disruption controller |
| **Deployment rolling update** | ❌ No | Availability during a rollout is `maxUnavailable` on the Deployment |
| **Scaling down a workload** | ❌ No | The controller deletes surplus Pods directly |
| **Scheduler preemption** | ⚠️ Best effort | It prefers candidate nodes with fewer PDB violations, then proceeds anyway |
| **Node pressure eviction (kubelet)** | ❌ No | The node is in trouble; there is no negotiation |
| **Taint manager (`NoExecute`)** | ❌ No | Direct deletion by the node lifecycle controller |
| **Pod garbage collection** | ❌ No | The node is already gone |
| **Node hardware failure** | ❌ No | Nothing to intercept |

```
The mental model:

   PDB protects the DECISION POINT, not the Pod.

   If some component is politely ASKING whether it may remove a Pod,
   the PDB gets a vote.
   If a component has already decided, or the machine has decided,
   the PDB is not consulted.
```

---

## The Disruption Controller and Status Fields

A controller inside `kube-controller-manager` watches PDBs, Pods and the workload resources that own them, and keeps `status` current. The API server reads that status when it decides an eviction.

```bash
kubectl get pdb web-pdb -o yaml
```

```yaml
status:
  observedGeneration: 1
  currentHealthy: 5        # Pods matching the selector with Ready=True
  desiredHealthy: 4        # how many must survive, resolved from min/max
  expectedPods: 6          # total intended, from the owner's spec.replicas
  disruptionsAllowed: 1    # currentHealthy - desiredHealthy, floored at 0
  disruptedPods:           # evictions granted but not yet completed
    web-abc123: "2026-03-04T09:41:12Z"
  conditions:
    - type: DisruptionAllowed
      status: "True"
      reason: SufficientPods
      observedGeneration: 1
```

| Field | Meaning | Diagnostic value |
|-------|---------|------------------|
| `expectedPods` | Intended replica count from the owning workload | `0` means the selector matches nothing, or no scale aware owner was found |
| `currentHealthy` | Matching Pods with `Ready=True` | Lower than `expectedPods` means Pods are failing or still starting |
| `desiredHealthy` | The resolved survival floor | This is where percentages and rounding become concrete numbers |
| `disruptionsAllowed` | How many evictions will be granted right now | `0` means every drain touching these Pods will block |
| `disruptedPods` | Pods whose eviction was granted, with a timestamp | An entry that persists is a Pod that is refusing to terminate |
| `conditions[DisruptionAllowed]` | `SufficientPods`, `InsufficientPods` or `SyncFailed` | `SyncFailed` points at a controller problem, not an application one |

`disruptedPods` entries exist so the controller does not hand out the same budget twice while a Pod is still terminating. Entries expire on their own if the eviction never completes, which is how a stuck termination eventually stops blocking others.

---

## Worked Example: A Three Replica Web App

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      terminationGracePeriodSeconds: 30
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: web }
      containers:
        - name: web
          image: nginx:1.27
          readinessProbe:
            httpGet: { path: /healthz, port: 80 }
            periodSeconds: 5
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: production
spec:
  maxUnavailable: 1
  selector:
    matchLabels: { app: web }
  unhealthyPodEvictionPolicy: AlwaysAllow
```

### Walking a Node Drain

```
Start: web-a on node-1, web-b on node-2, web-c on node-3. All Ready.
       currentHealthy 3, desiredHealthy 2, disruptionsAllowed 1

1. drain node-1 → evict web-a
     disruptionsAllowed 1 > 0 → GRANTED
     web-a enters Terminating, currentHealthy drops to 2
     disruptionsAllowed is now 0

2. The ReplicaSet notices and creates web-d.
   node-1 is cordoned, so web-d is scheduled to node-2 or node-3.

3. An impatient operator starts drain node-2 → evict web-b
     disruptionsAllowed 0 → REFUSED, HTTP 429
     kubectl retries every few seconds

4. web-d passes its readiness probe.
     currentHealthy 3, disruptionsAllowed 1

5. The retry of step 3 now succeeds. web-b is evicted.

The PDB has serialised the two drains automatically, with no coordination
between the two operators and no scripting.
```

### Why the Readiness Probe Is Part of the PDB

`currentHealthy` counts Pods with `Ready=True`. A Deployment with no readiness probe reports its Pods as Ready the moment the container process starts, long before the application can serve traffic. The PDB then cheerfully allows the next eviction while the replacement is still warming up.

> 🔑 **A PDB without an honest readiness probe is decorative.** The probe is what makes "healthy" mean something.

---

## Worked Example: A Quorum Based Datastore

For etcd, ZooKeeper, Consul or any Raft based system, availability is not a percentage. It is an integer derived from the protocol.

```
Quorum for N members = floor(N/2) + 1

  N = 3  →  quorum 2  →  may lose 1
  N = 5  →  quorum 3  →  may lose 2
  N = 7  →  quorum 4  →  may lose 3

Losing quorum does not degrade the cluster. It STOPS the cluster:
writes fail, leader election fails, and recovery may require manual
intervention. This is precisely the case where minAvailable is right,
because the number comes from the protocol, not from the replica count.
```

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: zk
  namespace: data
spec:
  serviceName: zk-headless
  replicas: 5
  selector:
    matchLabels: { app: zookeeper }
  template:
    metadata:
      labels: { app: zookeeper }
    spec:
      terminationGracePeriodSeconds: 120
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: zookeeper }
              topologyKey: kubernetes.io/hostname
      containers:
        - name: zk
          image: registry.k8s.io/kubernetes-zookeeper:1.0-3.4.10
          readinessProbe:
            exec:
              command: ["sh", "-c", "zookeeper-ready 2181"]
            initialDelaySeconds: 10
            periodSeconds: 5
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: zk-pdb
  namespace: data
spec:
  # Quorum for 5 members. Absolute, not a percentage, not derived
  # from the replica count.
  minAvailable: 3
  selector:
    matchLabels: { app: zookeeper }
  unhealthyPodEvictionPolicy: AlwaysAllow
```

```
5 healthy members:
    currentHealthy 5, desiredHealthy 3, disruptionsAllowed 2

Evicting 2 is permitted, leaving exactly quorum. That is legal but
uncomfortable: one involuntary failure during the maintenance window
then breaks the cluster.

Conservative alternative, if slower drains are acceptable:
    maxUnavailable: 1     with 5 replicas → disruptionsAllowed 1
This keeps 4 of 5 up at all times and tolerates one surprise.
```

| Requirement | PDB |
|-------------|-----|
| "Never lose quorum" | `minAvailable: <quorum>` |
| "Never lose quorum, and keep one spare failure budget" | `maxUnavailable: 1` |
| "The datastore is scaled by an operator and the size varies" | `minAvailable` as an integer maintained by that operator |

> ⚠️ For a StatefulSet, a Pod's replacement reuses the same name and the same PersistentVolumeClaim, and the StatefulSet controller will not create the replacement until the old Pod is **fully deleted**. Combine that with a long `terminationGracePeriodSeconds` and a slow startup, and each eviction can take minutes. Set the drain `--timeout` accordingly.

---

## Worked Example: The Single Replica Deadlock

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-app
spec:
  replicas: 1               # cannot be scaled: singleton, holds a lock
  selector:
    matchLabels: { app: legacy }
  template:
    metadata:
      labels: { app: legacy }
    spec:
      containers:
        - name: app
          image: example.com/legacy:1.0
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: legacy-pdb
spec:
  minAvailable: 1           # "this must always be up"
  selector:
    matchLabels: { app: legacy }
```

```
currentHealthy 1, desiredHealthy 1, disruptionsAllowed 0, permanently.

kubectl drain on the node running this Pod will retry forever:
  evicting pod default/legacy-app-6c9d... (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.

There is no state of the world in which this eviction is ever granted,
because the only way to get a second replica is to scale, and the
application cannot be scaled.
```

This is **not a bug**. It is the documented semantics: `maxUnavailable: 0` or `minAvailable` equal to the replica count means "zero voluntary evictions", and a drain of that node will never complete. Kubernetes permits you to say it because sometimes you mean it.

### The Legitimate Patterns for a Singleton

| Option | How it works | Cost |
|--------|--------------|------|
| **No PDB at all** | Accept a short outage during drains | Simplest, and usually correct |
| **`maxUnavailable: 1`** | Explicitly allow the single Pod to be disrupted | Documents the intent; the PDB then does nothing, which is honest |
| **`minAvailable: 1` plus a human protocol** | The drain blocks until a human deletes the PDB, performs the maintenance, and recreates it | Deliberate, and the upstream documented pattern for "talk to me before you touch this" |
| **Make it two replicas** | Add leader election so the standby is idle | The real fix, if the application supports it |

```bash
# The break glass procedure for the deliberate-block pattern
kubectl get pdb legacy-pdb -o yaml > /tmp/legacy-pdb.yaml   # save it first
kubectl delete pdb legacy-pdb
kubectl drain node-4 --ignore-daemonsets --delete-emptydir-data
# ... maintenance ...
kubectl uncordon node-4
kubectl apply -f /tmp/legacy-pdb.yaml
```

---

## The Classic Upgrade Failure

The single most common PDB incident, in narrative form.

```
A platform team upgrades a 20 node cluster, one node at a time,
with an automated runbook: cordon, drain, patch, reboot, uncordon, next.

Node 1 drains fine. Node 2 drains fine. Node 3 hangs.

  kubectl drain worker-3 --ignore-daemonsets
  evicting pod payments/api-7f4c9d...
  error when evicting pods/"api-7f4c9d" -n "payments" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
  [repeats forever]

Investigation:

  kubectl -n payments get pdb
  NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
  api-pdb    3               N/A               0                     214d

  kubectl -n payments get deploy api
  NAME   READY   UP-TO-DATE   AVAILABLE
  api    3/3     3            3

The PDB demands minAvailable 3. The Deployment runs exactly 3 replicas.
disruptionsAllowed is therefore permanently 0, and it has been for 214 days.
Nobody noticed, because nobody had drained a node holding an api Pod
since it was created.

The upgrade is now stuck at node 3 of 20, at 02:00, with 17 nodes to go.
```

### How to Detect It Before the Upgrade

```bash
# Every PDB in the cluster that currently permits nothing.
# Run this as a pre-flight check in the runbook, not during the outage.
kubectl get pdb -A -o json | python3 -c '
import json, sys
fmt = "%-20s %-28s %8s %8s %9s"
print(fmt % ("NAMESPACE", "PDB", "HEALTHY", "DESIRED", "EXPECTED"))
for p in json.load(sys.stdin)["items"]:
    s = p.get("status", {})
    if s.get("disruptionsAllowed", 0) == 0:
        print(fmt % (p["metadata"]["namespace"], p["metadata"]["name"],
                     s.get("currentHealthy"), s.get("desiredHealthy"),
                     s.get("expectedPods")))
'
```

```bash
# The quick version
kubectl get pdb -A
# NAMESPACE   NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
# payments    api-pdb    3               N/A               0            ← blocked
# production  web-pdb    N/A             1                 1            ← fine
# data        zk-pdb     3               N/A               2            ← fine
```

```bash
# Also catch PDBs that select nothing, which are silently useless
kubectl get pdb -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,EXPECTED:.status.expectedPods,ALLOWED:.status.disruptionsAllowed'
# EXPECTED 0 means the selector matches no Pods at all.
```

### How to Resolve It Safely, in Order of Preference

| Order | Action | Command | Risk |
|-------|--------|---------|------|
| 1 | **Scale the workload up temporarily** so the budget has slack | `kubectl -n payments scale deploy api --replicas=5` | None. The application stays fully available |
| 2 | **Fix the PDB** to be scale relative | Change `minAvailable: 3` to `maxUnavailable: 1` | None, and it prevents recurrence |
| 3 | **Set `unhealthyPodEvictionPolicy: AlwaysAllow`** if the blockage is unready Pods | `kubectl -n payments patch pdb api-pdb --type=merge -p '{"spec":{"unhealthyPodEvictionPolicy":"AlwaysAllow"}}'` | None for healthy applications |
| 4 | **Delete the PDB, drain, recreate it** | Save the YAML first | A window with no protection |
| 5 | **`kubectl drain --disable-eviction`** | Bypasses all PDBs | Real outage risk. Emergencies only |
| 6 | **`kubectl delete pod` directly** | Bypasses all PDBs | Same risk, less honest about it |

> 🔑 **Option 1 is almost always the right answer, and almost nobody thinks of it under pressure.** Scaling from 3 to 5 replicas gives `disruptionsAllowed: 2` instantly, the drain proceeds, and you scale back afterwards. Put it in the runbook.

---

## Interaction with Workload Controllers

### Deployment Rolling Updates

```
A Deployment rollout is NOT governed by the PDB.

  spec.strategy.rollingUpdate.maxUnavailable   ← controls the rollout
  spec.strategy.rollingUpdate.maxSurge         ← controls the rollout
  PodDisruptionBudget                          ← controls EVICTIONS

The ReplicaSet controller deletes old Pods directly. No Eviction API call
is made, so the PDB never gets a vote.

BUT: Pods that are down because of a rollout DO count against the budget,
because currentHealthy simply counts Ready Pods. So a rollout in progress
temporarily shrinks the eviction budget, and a drain running at the same
time will be refused.
```

| Concern | Set this |
|---------|----------|
| How much capacity is lost during a deploy | `spec.strategy.rollingUpdate.maxUnavailable` on the Deployment |
| How much capacity is lost during a node drain | `maxUnavailable` on the PDB |
| Both at once | Make sure the two numbers together are survivable, because they can overlap |

> 📖 Rollout mechanics are covered in [deployment-strategies.md](deployment-strategies.md) and [deployments.md](deployments.md).

### DaemonSets

DaemonSets have no `scale` subresource, so a PDB selecting DaemonSet Pods supports only an **integer `minAvailable`**. In practice this rarely matters, because:

```bash
# drain refuses to touch DaemonSet Pods unless told to ignore them,
# and --ignore-daemonsets means "leave them running", not "evict them".
kubectl drain worker-2 --ignore-daemonsets
```

The DaemonSet Pod stays on the node through the drain and is removed when the node itself goes away. A PDB on a DaemonSet is usually the wrong tool; if a node agent must not be interrupted, that is a node lifecycle concern, not an eviction concern.

### StatefulSets

StatefulSets do have a `scale` subresource, so percentages and `maxUnavailable` are supported. Two things make StatefulSet drains slower:

1. **Identity is serialised.** The replacement Pod reuses the ordinal name and the same PVC, and it cannot be created until the previous Pod is fully gone.
2. **Volumes must detach and reattach**, which on some storage backends takes minutes and can fail if the old node is unreachable.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: db-pdb
spec:
  maxUnavailable: 1          # one ordinal at a time, always
  selector:
    matchLabels: { app: postgres }
  unhealthyPodEvictionPolicy: AlwaysAllow
```

> 📖 See [statefulsets.md](statefulsets.md) for the identity and volume guarantees that make this slow.

### Jobs and CronJobs

A Job Pod that is evicted is simply retried by the Job controller, provided `spec.backoffLimit` allows it. **Do not put a PDB on a Job.** It will block drains to protect work that Kubernetes is perfectly happy to redo, and a long running Job will hold a node hostage for its entire duration.

The correct controls for batch work are `activeDeadlineSeconds`, `backoffLimit`, a Pod failure policy, and checkpointing in the application.

---

## Interaction with the Cluster Autoscaler

The Cluster Autoscaler removes underutilised nodes by draining them, which means it goes through the Eviction API and is fully bound by PDBs.

```
Autoscaler wants to remove node-7 (utilisation 20 percent).
  1. Simulate: can every Pod on node-7 be rescheduled elsewhere?
  2. Would evicting them violate any PDB?
       yes → node-7 is NOT removed. The node stays, and you keep paying.
  3. Evict via the Eviction API, honouring PDBs and grace periods.
  4. Delete the node.
```

Common reasons a node never scales down:

| Blocker | Fix |
|---------|-----|
| A PDB with `disruptionsAllowed: 0` | The detection and resolution steps above |
| A Pod with no controller (a bare Pod) | Give it a controller, or annotate it as safe to evict |
| A Pod using local storage (`emptyDir`, `hostPath`) | Annotate it as safe to evict, or move the data to a PV |
| kube-system Pods without a PDB | Autoscalers often refuse to evict system Pods by default; give the addon a PDB and confirm your autoscaler's flags |
| A Pod that cannot be rescheduled anywhere | Fix the affinity, taint or capacity constraint that pins it |

```bash
# The autoscaler explains itself. Read it before guessing.
kubectl -n kube-system logs deployment/cluster-autoscaler | grep -i "scale.down\|pdb\|not removable"
kubectl -n kube-system describe configmap cluster-autoscaler-status
```

> 🔑 A PDB that is too strict does not just block upgrades: it **costs money every hour**, by preventing the autoscaler from consolidating nodes. This is the least visible consequence of a bad budget.

---

## PDBs in an Upgrade Runbook

### Before the Upgrade

```bash
# 1. Inventory every PDB and its current headroom.
kubectl get pdb -A

# 2. Flag anything with ALLOWED DISRUPTIONS of 0.
kubectl get pdb -A -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    s=p.get("status",{})
    if s.get("disruptionsAllowed",0)==0:
        print("BLOCKED:", p["metadata"]["namespace"]+"/"+p["metadata"]["name"],
              "healthy",s.get("currentHealthy"),"desired",s.get("desiredHealthy"))
'

# 3. Flag workloads with NO PDB that probably need one.
kubectl get deploy -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas' \
  | awk 'NR>1 && $3>1'

# 4. Flag single replica Deployments: these WILL have an outage.
kubectl get deploy -A -o json | python3 -c '
import json,sys
for d in json.load(sys.stdin)["items"]:
    if d["spec"].get("replicas",1)==1:
        print("SINGLE REPLICA:", d["metadata"]["namespace"]+"/"+d["metadata"]["name"])
'

# 5. Confirm every important workload has a readiness probe, because
#    currentHealthy is meaningless without one.
```

### Per Node

```bash
NODE=worker-3

kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=20m

# ... patch, reboot, verify ...

kubectl uncordon "$NODE"

# Wait for the cluster to settle before the next node. Do not move on
# while replacements are still starting: the next drain will be refused
# and you will conclude, wrongly, that a PDB is broken.
kubectl get pods -A -o wide | grep -v Running | grep -v Completed
kubectl get pdb -A
```

### A Safe Default PDB for a Replicated Service

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: <app>-pdb
  namespace: <namespace>
spec:
  # Scales with the workload, never becomes a permanent zero.
  maxUnavailable: 1
  selector:
    matchLabels:
      app: <app>          # exactly the owning controller's selector
  # Never let a broken application block a node drain.
  unhealthyPodEvictionPolicy: AlwaysAllow
```

Preconditions for that template to be meaningful: at least two replicas, an honest readiness probe, and spread across nodes so that one node drain never takes two replicas at once.

---

## Verifying and Reading a PDB

```bash
kubectl get pdb -A
# NAMESPACE    NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# production   web-pdb   N/A             1                 1                     3d
# data         zk-pdb    3               N/A               2                     3d
# payments     api-pdb   3               N/A               0                     214d
```

| Column | Read it as |
|--------|-----------|
| `MIN AVAILABLE` | Your `spec.minAvailable`, or `N/A` |
| `MAX UNAVAILABLE` | Your `spec.maxUnavailable`, or `N/A` |
| **`ALLOWED DISRUPTIONS`** | `status.disruptionsAllowed`. **This is the only column that matters operationally** |

| Value | Meaning |
|-------|---------|
| A positive number | That many evictions will be granted right now |
| `0` | Every eviction of these Pods is refused. A drain will block |
| `0` **and** `expectedPods` is `0` | The selector matches nothing. The PDB is protecting an empty set |

```bash
kubectl -n production describe pdb web-pdb
# Name:             web-pdb
# Namespace:        production
# Max unavailable:  1
# Selector:         app=web
# Status:
#     Allowed disruptions:  1
#     Current:              3
#     Desired:              2
#     Total:                3

# Watch the budget move during a drain, in a second terminal
kubectl get pdb -A -w
```

```bash
# Prove enforcement without draining anything
POD=$(kubectl -n production get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl proxy --port=8001 &
for i in 1 2 3; do
  curl -s -o /dev/null -w "attempt $i: HTTP %{http_code}\n" \
    -X POST http://127.0.0.1:8001/api/v1/namespaces/production/pods/$POD/eviction \
    -H 'Content-Type: application/json' \
    -d "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"$POD\",\"namespace\":\"production\"}}"
done
# attempt 1: HTTP 201   ← granted
# attempt 2: HTTP 429   ← budget exhausted
```

---

## Troubleshooting

### A Drain That Hangs

```bash
kubectl drain worker-3 --ignore-daemonsets
# error when evicting pods/"api-7f4c9d" -n "payments" (will retry after 5s):
# Cannot evict pod as it would violate the pod's disruption budget.
```

Work through this in order:

```bash
# 1. Which Pod is blocking, and in which namespace? Read the error text.

# 2. Which PDB covers it?
kubectl -n payments get pdb

# 3. Why is the budget zero?
kubectl -n payments get pdb api-pdb -o jsonpath='{.status}{"\n"}' | python3 -m json.tool
```

| `status` pattern | Diagnosis | Fix |
|------------------|-----------|-----|
| `currentHealthy == desiredHealthy == expectedPods` | The budget is permanently zero by construction | Scale up, or change `minAvailable` to `maxUnavailable` |
| `currentHealthy < desiredHealthy` | Pods are unhealthy right now | Fix the application, or set `AlwaysAllow` |
| `currentHealthy < expectedPods` | Replacements are still starting | **Wait.** This usually resolves on its own |
| `expectedPods: 0` | The selector matches nothing | The PDB is misconfigured, but it is not what is blocking you; look again |
| `disruptedPods` has a stale entry | A previous eviction never completed | Find that Pod; it is probably stuck `Terminating` |
| Condition `SyncFailed` | The disruption controller could not compute the budget | Check `kube-controller-manager` logs |

```bash
# 4. Are replacements simply unable to schedule?
kubectl -n payments get pods -o wide
kubectl -n payments describe pod <pending-pod> | tail -20
# "0/5 nodes are available: ... Insufficient cpu" means the cluster has no
# room for the replacement, so the budget can never recover during a drain.
# You need spare capacity BEFORE you drain.
```

### A Pod Stuck Terminating During a Drain

```bash
kubectl -n payments get pod api-7f4c9d -o jsonpath='{.metadata.deletionTimestamp} {.spec.terminationGracePeriodSeconds}{"\n"}'
kubectl -n payments describe pod api-7f4c9d | grep -A5 Finalizers
```

| Cause | Evidence | Action |
|-------|----------|--------|
| A long `terminationGracePeriodSeconds` | The value is 300 or more | Wait, or lower it in the Pod template |
| A `preStop` hook that never returns | The container is still running past the grace period | Fix the hook; the kubelet will SIGKILL at the end of the grace period |
| A finalizer | `metadata.finalizers` is non empty | Find the controller that owns the finalizer. Removing it by hand risks leaking whatever it was protecting |
| A volume that will not unmount | kubelet logs mention `UnmountVolume` | Storage layer problem, not a PDB problem |

### A PDB That Protects Nothing

```bash
kubectl get pdb -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,EXPECTED:.status.expectedPods'
# EXPECTED 0 = the selector matches no Pods.
```

Almost always a selector that does not match the workload's labels:

```bash
kubectl -n production get pdb web-pdb -o jsonpath='{.spec.selector}{"\n"}'
kubectl -n production get deploy web -o jsonpath='{.spec.selector}{"\n"}'
# These two should be identical. If they are not, the PDB is decorative.
```

### Overlapping PDBs

```bash
# Find Pods covered by more than one PDB. The Eviction API refuses these.
kubectl -n production get pdb -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    print(p["metadata"]["name"], p["spec"].get("selector"))
'
```

The eviction API disallows eviction of any Pod covered by multiple PDBs, so overlapping selectors produce a permanent block that looks exactly like an exhausted budget but has a completely different cause. The one legitimate reason to have overlap is a brief transition while moving Pods from one budget to another.

### Evictions Are Being Granted but Availability Still Drops

Check whether the disruption was voluntary at all:

```bash
kubectl get events -A --field-selector reason=Evicted        # kubelet, node pressure
kubectl get events -A --field-selector reason=Preempted      # scheduler preemption
kubectl get pod <name> -o jsonpath='{.status.conditions[?(@.type=="DisruptionTarget")].reason}{"\n"}'
```

If the reason is `TerminationByKubelet` or `PreemptionByScheduler`, no PDB could have prevented it. The fix lives in [resource-management.md](resource-management.md) (requests, limits, QoS) and [scheduling.md](scheduling.md) (priority classes), not here.

---

## Exam and Interview Traps

1. **A PDB constrains the Eviction API and nothing else.** `kubectl delete pod` ignores it completely.
2. **Deployment rolling updates are not limited by PDBs.** Rollout availability is `spec.strategy.rollingUpdate.maxUnavailable` on the Deployment.
3. **Scaling a Deployment down ignores the PDB**, because the ReplicaSet deletes Pods directly.
4. **Node pressure eviction ignores PDBs**, always. It is an involuntary disruption.
5. **Scheduler preemption honours PDBs only as a tiebreaker** when choosing a victim node, and proceeds even when every candidate violates one.
6. **Involuntary disruptions cannot be blocked but do consume the budget**, because `currentHealthy` simply counts Ready Pods.
7. **You may set only one of `minAvailable` and `maxUnavailable`.** Setting both is rejected.
8. **`maxUnavailable` requires a scale aware owner** and all selected Pods sharing one controller. Bare Pods and operator managed Pods without a `scale` subresource support only an integer `minAvailable`.
9. **In `policy/v1` an empty selector matches every Pod in the namespace.** In the removed `policy/v1beta1` it matched none. This reversal has caused real outages.
10. **Percentages round up for both fields.** For `minAvailable` that makes the budget stricter; for `maxUnavailable` it makes it looser, so an actual disruption can exceed the percentage you wrote.
11. **`maxUnavailable: "30%"` with one replica allows 100 percent disruption**, because 0.3 rounds up to 1.
12. **`minAvailable` equal to the replica count, or `maxUnavailable: 0`, means zero voluntary evictions**, and any drain of that node blocks forever. This is documented, permitted behaviour, not a bug.
13. **`ALLOWED DISRUPTIONS` is the only column that matters.** A `0` there means every drain touching those Pods will hang.
14. **`expectedPods: 0` means the selector matches nothing.** The PDB is protecting an empty set.
15. **"Healthy" means `Ready=True`.** Without a real readiness probe the budget is protecting a number that has no relationship to whether the application works.
16. **The default `unhealthyPodEvictionPolicy` is `IfHealthyBudget`**, which refuses to evict unready Pods when the budget is already breached, so a CrashLoopBackOff application can block every drain. `AlwaysAllow` is the operationally safer choice and is what upstream recommends for drains.
17. **Pods in `Pending`, `Succeeded` or `Failed` are always evictable** regardless of the policy.
18. **A Pod covered by two PDBs cannot be evicted at all.** Avoid overlapping selectors.
19. **Eviction is graceful.** `preStop` hooks and `terminationGracePeriodSeconds` are honoured; it is not a kill.
20. **A refused eviction is HTTP 429, not 403.** It means "retry later", and `kubectl drain` does exactly that until `--timeout`.
21. **`kubectl drain --disable-eviction` bypasses every PDB in the cluster.** So does deleting Pods directly. Both are emergency tools.
22. **The fastest safe unblock is to scale the workload up**, not to delete the PDB.
23. **PDBs bind the Cluster Autoscaler too**, so an over strict budget silently prevents node consolidation and costs money continuously.
24. **Do not put a PDB on a Job.** Evicted Job Pods are retried by the Job controller, and the PDB will only hold nodes hostage.
25. **DaemonSets have no `scale` subresource**, so only integer `minAvailable` applies, and `kubectl drain --ignore-daemonsets` leaves their Pods in place anyway.
26. **A PDB is a coordination contract, not an availability mechanism.** Replicas, spread, probes and rollout settings provide availability; the PDB only stops an operator from removing too many at once.

---

## Related Topics

- [Scheduling](scheduling.md)
- [Resource Management](resource-management.md)
- [Deployments](deployments.md)
- [Deployment Strategies](deployment-strategies.md)
- [ReplicaSets](replicasets.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [Controllers](controllers.md)
- [Pods](pods.md)
- [Pod Lifecycle](pod-lifecycle.md)
- [Pod Operations](pod-operations.md)
- [kube-scheduler](kube-scheduler.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kubelet](kubelet.md)
- [kube-apiserver](kube-apiserver.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [Worker Node](worker-node.md)
- [Control Plane Node](control-plane-node.md)
- [Cgroups](cgroups.md)

---

## Key Takeaways

1. **A PodDisruptionBudget governs voluntary disruption only.** It is consulted when something politely asks permission through the Eviction API, and it is silent when a machine, a kernel or a direct DELETE has already decided.
2. **`kubectl drain` respects PDBs because it calls the Eviction API; `kubectl delete pod` does not.** That single distinction explains most confusion about PDBs.
3. **Involuntary disruptions still spend the budget.** A node failure reduces `currentHealthy`, which reduces `disruptionsAllowed`, which is exactly the behaviour you want: the cluster stops adding voluntary damage on top of an existing failure.
4. **Set exactly one of `minAvailable` and `maxUnavailable`.** Prefer `maxUnavailable` for ordinary replicated services because it tracks the replica count, and reserve `minAvailable` for protocol driven floors such as a quorum.
5. **The denominator comes from the owning workload's `spec.replicas`**, discovered through `ownerReferences`. Without a scale aware owner, only an integer `minAvailable` is supported.
6. **Percentages always round up.** That makes `minAvailable` stricter and `maxUnavailable` looser, and on small replica counts a percentage `maxUnavailable` can permit total disruption.
7. **`unhealthyPodEvictionPolicy: AlwaysAllow` should be your default.** The `IfHealthyBudget` default lets a CrashLoopBackOff application block every node drain in the cluster while protecting Pods that are not serving anything.
8. **"Healthy" means the Pod has `Ready=True`**, so a PDB is only as truthful as the readiness probe behind it.
9. **`ALLOWED DISRUPTIONS` is the operational number.** Zero means the next drain hangs; check it as a pre-flight step before any cluster upgrade, not during one.
10. **`expectedPods: 0` is a silently broken PDB.** The selector matches nothing, usually because it drifted from the controller's selector.
11. **A single replica plus `minAvailable: 1` deadlocks node drains forever**, by design. Either accept the outage with no PDB, state the intent with `maxUnavailable: 1`, use the documented delete-drain-recreate protocol, or add a second replica.
12. **The classic upgrade incident is a PDB whose budget has been zero for months** and was never exercised until someone drained the right node. Detect it with a cluster wide scan of `status.disruptionsAllowed`.
13. **The safest unblock is to scale the workload up temporarily.** Deleting the PDB, using `--disable-eviction` or deleting Pods directly all trade availability for progress, in ascending order of risk.
14. **A Pod matched by two PDBs cannot be evicted at all**, so overlapping selectors are a trap that looks like an exhausted budget.
15. **Rollouts and PDBs are separate systems that share one pool of healthy Pods.** A rollout in progress shrinks the eviction budget even though the rollout itself is not constrained by it.
16. **StatefulSet drains are slow** because identity and volumes are serialised, so pair `maxUnavailable: 1` with a generous drain `--timeout`.
17. **Do not budget Jobs, and rarely budget DaemonSets.** Evicted Job Pods are simply retried, and drains leave DaemonSet Pods alone.
18. **The Cluster Autoscaler is bound by PDBs too**, so an over strict budget prevents node consolidation and turns an availability policy into a permanent cost.
19. **A refused eviction returns HTTP 429**, meaning try again later, which is why `kubectl drain` loops rather than failing.
20. **PDBs are a contract between the application owner and the cluster operator.** They express how much simultaneous disruption an application can survive; the actual surviving is done by replicas, spread, probes and sensible termination handling.

---

## References

- [Disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [Specifying a Disruption Budget for your Application](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- [API-initiated Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/)
- [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [PodDisruptionBudget API reference (policy/v1)](https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/pod-disruption-budget-v1/)
- [Eviction API reference (policy/v1)](https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/eviction-v1/)
- [Node-pressure Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- [Pod Lifecycle: Termination of Pods](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
- [Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/)
- [Deployments: Updating a Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#updating-a-deployment)
- [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [DaemonSet](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/)
- [Node Autoscaling](https://kubernetes.io/docs/concepts/cluster-administration/node-autoscaling/)
- [kubectl drain reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#drain)
- [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
