# 🎛️ Kubernetes Controllers: The Reconciliation Engine

A deep guide to the controller pattern that makes Kubernetes declarative, covering the reconcile loop, informers, work queues, owner references, finalizers, leader election, and every built in controller shipped inside `kube-controller-manager`.

## 📋 Table of Contents
- [What Is a Controller?](#what-is-a-controller)
- [The Declarative Model](#the-declarative-model)
- [Desired State vs Observed State](#desired-state-vs-observed-state)
- [The Reconciliation Loop](#the-reconciliation-loop)
- [Level Triggered vs Edge Triggered](#level-triggered-vs-edge-triggered)
- [Inside kube-controller-manager](#inside-kube-controller-manager)
- [Informers, Watches, Caches and Work Queues](#informers-watches-caches-and-work-queues)
- [Resync Periods](#resync-periods)
- [Owner References and Garbage Collection](#owner-references-and-garbage-collection)
- [Finalizers](#finalizers)
- [The Status Subresource](#the-status-subresource)
- [Generation and observedGeneration](#generation-and-observedgeneration)
- [Leader Election](#leader-election)
- [System Controllers](#system-controllers)
- [Inspecting Controllers](#inspecting-controllers)
- [Controller Manager Flags](#controller-manager-flags)
- [Writing Your Own Controller](#writing-your-own-controller)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What Is a Controller?

A **controller** is a non terminating control loop that watches the state of the cluster through the API server and makes changes to move the current state toward the desired state.

Kubernetes is not an imperative orchestrator that executes your commands once. It is a **collection of controllers**, each responsible for one resource type, each running the same three step algorithm forever.

```
┌──────────────────────────────────────────────────────────────┐
│                  The Universal Controller Loop                │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│    ┌────────────────────────────────────────────────┐        │
│    │                                                 │        │
│    ▼                                                 │        │
│  ┌──────────┐    ┌──────────┐    ┌──────────────┐   │        │
│  │ OBSERVE  │───►│ COMPARE  │───►│     ACT      │───┘        │
│  │ read     │    │ desired  │    │ create/patch │            │
│  │ current  │    │   vs     │    │ /delete via  │            │
│  │  state   │    │ observed │    │  API server  │            │
│  └──────────┘    └──────────┘    └──────────────┘            │
│                                                               │
│   Runs forever. Never assumes it caused the last change.     │
│   Idempotent: running it twice produces the same result.     │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### The Thermostat Analogy

| Thermostat | Kubernetes Controller |
|------------|-----------------------|
| Target temperature: 21 C | `spec.replicas: 3` |
| Thermometer reading: 18 C | `status.replicas: 2` |
| Turn on the heater | Create one Pod object |
| Keeps sampling forever | Watches the API server forever |
| Does not care who opened the window | Does not care who deleted the Pod |

The last row is the important one. A controller never asks *why* the state drifted. It only asks *what is different right now*, and fixes that.

---

## The Declarative Model

You do not tell Kubernetes **how** to do something. You record **what you want** in `spec`, and a controller figures out the how.

```
Imperative (what most tools do):
  1. ssh node1 && docker run nginx
  2. ssh node2 && docker run nginx
  3. ssh node3 && docker run nginx
  ... node2 reboots, nobody notices, you are down to 2 replicas

Declarative (what Kubernetes does):
  1. POST /apis/apps/v1/namespaces/default/deployments
     { spec: { replicas: 3, template: {...} } }
  2. Controllers take over, forever
     ... node2 reboots, node lifecycle controller notices,
         replicaset controller creates a replacement Pod
```

### The Contract

Every Kubernetes object is split into three parts:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:                 # identity, labels, annotations, ownerRefs, finalizers
  name: web
  namespace: default
  generation: 4           # bumped by the API server when spec changes
spec:                     # DESIRED STATE. Written by humans and controllers.
  replicas: 3
status:                   # OBSERVED STATE. Written ONLY by controllers.
  replicas: 3
  readyReplicas: 3
  observedGeneration: 4
```

| Section | Written by | Read by |
|---------|-----------|---------|
| `metadata` | user and controllers | everything |
| `spec` | user (usually) | the owning controller |
| `status` | the owning controller | users, other controllers, kubectl |

**Rule:** if you find yourself editing `status` by hand, you are fighting the model. The API server exposes `status` as a separate subresource specifically so RBAC can forbid users from touching it.

---

## Desired State vs Observed State

```
┌────────────────────────────────────────────────────────────────┐
│                    etcd (single source of truth)               │
│                                                                │
│   Deployment/web                                               │
│     spec.replicas: 5      ◄── DESIRED  (what you asked for)   │
│     status.replicas: 3    ◄── OBSERVED (what the controller    │
│     status.readyReplicas: 2            last measured)          │
└────────────────────────────────────────────────────────────────┘
                     │                       ▲
        watch/list   │                       │  update status
                     ▼                       │
        ┌────────────────────────────────────────────┐
        │      deployment controller goroutine       │
        │  diff = desired(5) - observed(3) = +2      │
        │  action: scale the new ReplicaSet up by 2  │
        └────────────────────────────────────────────┘
```

The **diff** is recomputed from scratch on every sync. The controller does not keep a private ledger of "I already created two pods". It re-reads the world. This is what makes controllers self healing after a crash, a leader election flip, or a rolling upgrade of the control plane.

---

## The Reconciliation Loop

Concretely, one reconcile pass of the ReplicaSet controller looks like this:

```
syncReplicaSet(key = "default/web-7d9f8b6c5")
 │
 ├─ 1. Split key into namespace + name
 ├─ 2. Get the ReplicaSet from the LOCAL CACHE (no API call)
 │      └─ NotFound? The object was deleted. Clean up expectations, return.
 ├─ 3. Check expectations: are we still waiting for creates/deletes
 │      we issued in a previous sync to show up in the cache?
 ├─ 4. List all Pods in the namespace from the LOCAL CACHE
 ├─ 5. Filter Pods whose labels match rs.spec.selector
 ├─ 6. Claim/adopt matching Pods with no controller ownerRef
 │      Release/orphan Pods that no longer match
 ├─ 7. diff = len(activePods) - *rs.Spec.Replicas
 │      diff < 0  ──► create (-diff) Pods   (slow start batching)
 │      diff > 0  ──► delete (diff) Pods    (sorted by deletion priority)
 │      diff == 0 ──► nothing to do
 ├─ 8. Recompute status: replicas, fullyLabeledReplicas,
 │      readyReplicas, availableReplicas, conditions
 └─ 9. If status changed, PUT /status  (the status subresource only)
```

### Properties Every Correct Controller Has

| Property | Meaning | Why it matters |
|----------|---------|----------------|
| **Idempotent** | Running the sync twice with the same input causes no extra change | Work queues deliver duplicates |
| **Level triggered** | Acts on current state, not on the event that woke it | Events can be missed or coalesced |
| **Stateless across syncs** | All needed state is read from the cache | Survives restart and leader failover |
| **Non blocking** | Never sleeps waiting for a result; requeues instead | One slow object must not stall the worker |
| **Rate limited** | Failures back off exponentially | Prevents hot looping against the API server |

### Requeue on Failure

A controller never retries in a tight loop. It returns the error and the work queue re-adds the key with exponential backoff (the default rate limiter starts around 5 ms and caps around 1000 s, combined with an overall bucket limiter):

```
attempt 1  ─► fail ─► requeue after ~5ms
attempt 2  ─► fail ─► requeue after ~10ms
attempt 3  ─► fail ─► requeue after ~20ms
...
attempt N  ─► fail ─► requeue capped at ~1000s
```

You see this in the wild as an object whose `status` slowly converges, plus repeating Warning Events with growing gaps between them.

---

## Level Triggered vs Edge Triggered

This is the single most important design decision in Kubernetes, and a very common interview question.

```
EDGE TRIGGERED  (what Kubernetes deliberately avoids)
──────────────────────────────────────────────────────
  "Pod deleted" event ──► create one replacement Pod

  Problem: if the event is lost (network blip, controller
  restart, watch bookmark gap, queue overflow) the
  replacement is NEVER created. State is permanently wrong.


LEVEL TRIGGERED  (what Kubernetes actually does)
──────────────────────────────────────────────────────
  Any event ──► "something about this ReplicaSet changed,
                 go look at the whole thing"
             ──► count pods, compare to spec.replicas,
                 create the difference

  If an event is lost, the next event, the next resync, or
  the next relist repairs it. State converges eventually.
```

**The events are hints, not instructions.** A controller uses the event only to decide *which object key to enqueue*. It never uses the event payload to decide *what action to take*. That is why:

- Deleting 10 pods at once and 1 pod ten times produce the same end state.
- A controller can start cold with an empty cache and still converge.
- A missed watch event is an availability delay, never a correctness bug.

---

## Inside kube-controller-manager

`kube-controller-manager` is a **single binary and a single process** that runs dozens of independent controllers as goroutines sharing one client, one informer factory, and one leader election lease.

```
┌───────────────────────────────────────────────────────────────────┐
│                     kube-controller-manager                       │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              Leader Election (Lease in kube-system)          │ │
│  │   Only the leader runs the controllers below.               │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                              │                                    │
│  ┌───────────────────────────▼─────────────────────────────────┐ │
│  │            SharedInformerFactory (one per process)          │ │
│  │                                                              │ │
│  │  Pod informer     Node informer    ReplicaSet informer  ... │ │
│  │  ┌──────────┐     ┌──────────┐     ┌──────────┐            │ │
│  │  │ Reflector│     │ Reflector│     │ Reflector│            │ │
│  │  │ DeltaFIFO│     │ DeltaFIFO│     │ DeltaFIFO│            │ │
│  │  │ Indexer  │     │ Indexer  │     │ Indexer  │            │ │
│  │  └────┬─────┘     └────┬─────┘     └────┬─────┘            │ │
│  └───────┼────────────────┼────────────────┼───────────────────┘ │
│          │ event handlers │                │                     │
│  ┌───────▼────────┐ ┌─────▼─────────┐ ┌────▼──────────┐         │
│  │ deployment ctrl│ │ node lifecycle│ │ replicaset ctl│  ...    │
│  │  workqueue     │ │   workqueue   │ │   workqueue   │         │
│  │  N workers     │ │   N workers   │ │   N workers   │         │
│  └────────────────┘ └───────────────┘ └───────────────┘         │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
                              │
                     HTTPS + client cert / SA token
                              ▼
                    ┌──────────────────┐
                    │   kube-apiserver │
                    └──────────────────┘
```

Key consequences of this architecture:

1. **One watch per resource type, not per controller.** The deployment controller and the ReplicaSet controller both read Pods, but only one Pod watch exists against the API server. This is why the shared informer exists at all.
2. **The cache is shared and read only.** Objects handed to a controller from the lister are pointers into the shared cache. Mutating them corrupts every other controller. Real controllers always call `DeepCopy()` before touching an object.
3. **A crash takes all controllers with it.** Leader election then hands the whole set to another replica.
4. **Controllers talk only through the API server.** The deployment controller does not call the ReplicaSet controller. It writes a ReplicaSet object, and the ReplicaSet controller notices.

```
The famous chain, entirely mediated by etcd:

  you ──► Deployment ──► ReplicaSet ──► Pod ──► (scheduler sets nodeName)
                                              ──► kubelet runs containers

  deployment ctrl        replicaset ctrl     kube-scheduler    kubelet
  watches Deployments    watches ReplicaSets watches Pods      watches Pods
  writes ReplicaSets     writes Pods         patches           bound to
                                             pod.spec.nodeName its own node
```

---

## Informers, Watches, Caches and Work Queues

### The Full Data Path

```
   kube-apiserver
        │
        │ (1) LIST  /api/v1/pods?limit=500&resourceVersion=0
        │     WATCH /api/v1/pods?resourceVersion=12345&allowWatchBookmarks=true
        ▼
 ┌─────────────┐
 │  Reflector  │  Runs ListAndWatch forever. On a 410 Gone
 │             │  ("resourceVersion too old") it relists from scratch.
 └──────┬──────┘
        │ (2) Added / Updated / Deleted / Sync deltas
        ▼
 ┌─────────────┐
 │  DeltaFIFO  │  Per key FIFO of deltas. Compresses repeated
 │             │  updates to the same key while they sit in the queue.
 └──────┬──────┘
        │ (3) HandleDeltas: pop and apply
        ▼
 ┌─────────────┐        ┌──────────────────────────────────────┐
 │   Indexer   │◄──────►│ Lister: GetByKey / List(selector)    │
 │ (thread safe│        │ Zero API calls. Sub millisecond.     │
 │  store with │        │ Default index: "namespace".          │
 │  indices)   │        └──────────────────────────────────────┘
 └──────┬──────┘
        │ (4) fan out to every registered ResourceEventHandler
        ▼
 ┌──────────────────────────────────────────────────────────┐
 │ OnAdd / OnUpdate / OnDelete                              │
 │   handler does ONE thing: compute a key and enqueue it   │
 │   key = "namespace/name" of the object to reconcile      │
 └──────┬───────────────────────────────────────────────────┘
        │ (5)
        ▼
 ┌──────────────────────────────────────────────────────────┐
 │ RateLimitingInterface workqueue                          │
 │   • dedupes: same key queued twice is processed once     │
 │   • guarantees a key is not processed by 2 workers       │
 │     concurrently                                         │
 │   • exponential backoff on AddRateLimited                │
 │   • delayed adds via AddAfter                            │
 └──────┬───────────────────────────────────────────────────┘
        │ (6) N worker goroutines
        ▼
 ┌──────────────────────────────────────────────────────────┐
 │ syncHandler(key)  ── the reconcile function              │
 │   reads from the Indexer, writes through the API client  │
 └──────────────────────────────────────────────────────────┘
```

### Why the Handler Must Not Do Work

The event handler runs on the informer's single processing goroutine. If it blocks, **the entire cache stops updating** for that resource type. So the handler does exactly one thing: turn an object into a key and push it into the queue.

### Key Mapping Is Where the Logic Lives

The subtle part of any controller is mapping a *changed object* to the *object that owns the reconcile*.

```
Pod changed  ──► look at pod.metadata.ownerReferences
                 find the one with controller: true
                 if kind == ReplicaSet: enqueue "ns/rs-name"

Pod has no owner ──► list all ReplicaSets in the namespace
                     enqueue every RS whose selector matches the pod
                     (this is how adoption of bare pods is triggered)

ReplicaSet changed ──► look at rs.metadata.ownerReferences
                       enqueue the owning Deployment
```

### Cache Staleness Is Normal

The informer cache is **eventually consistent**. A controller can read a Pod that was deleted 50 ms ago. Correct controllers handle this by:

- Being idempotent, so a duplicate create attempt returns `AlreadyExists` and is ignored.
- Using **expectations**: the ReplicaSet controller records "I asked for 3 creates" and refuses to act again until those 3 pods appear in the cache or a timeout (around 5 minutes) expires. Without this, a slow cache would cause a runaway pod creation storm.

---

## Resync Periods

A **resync** replays every object currently in the cache through the event handlers as a synthetic update. No API traffic occurs. It exists as a safety net for missed events and for controllers whose desired state depends on something outside the watched object.

```
Relist  vs  Resync  ── do not confuse them

RELIST: real LIST call to the API server. Happens when the watch
        breaks with 410 Gone, or the connection drops. Expensive.

RESYNC: purely local. The DeltaFIFO emits a "Sync" delta for every
        cached object. Handlers fire, keys get enqueued, reconcile
        runs. Cheap in API terms, but N reconciles at once.
```

- `--min-resync-period` on `kube-controller-manager` defaults to `12h`.
- Each controller's actual period is jittered between the minimum and twice the minimum, so all controllers do not resync at the same instant.
- Setting a very short resync period is an anti pattern. It masks a missing watch or a missing key mapping, and it turns into a periodic thundering herd on large clusters.

```bash
# Resync storms show up as a periodic spike in these metrics
kubectl -n kube-system port-forward pod/kube-controller-manager-cp1 10257:10257
curl -sk https://localhost:10257/metrics | grep -E 'workqueue_depth|workqueue_adds_total'
```

---

## Owner References and Garbage Collection

### The ownerReferences Field

Every object created by a controller carries a back pointer to its creator:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-7d9f8b6c5-x4k2p
  namespace: default
  labels:
    app: web
    pod-template-hash: 7d9f8b6c5
  ownerReferences:
  - apiVersion: apps/v1
    kind: ReplicaSet
    name: web-7d9f8b6c5
    uid: 3f2a1b90-8c4e-4d1a-9f77-0b5c2e6a1d33   # UID, not just name
    controller: true              # exactly one owner may set this
    blockOwnerDeletion: true      # foreground deletion waits for me
```

| Field | Purpose |
|-------|---------|
| `uid` | Identity check. A new object with the same name but a different UID is **not** the owner. This prevents a recreated parent from adopting the old children. |
| `controller: true` | Marks the single *managing* controller. Only one owner reference may set it. Controllers refuse to adopt an object that already has a controller owner. |
| `blockOwnerDeletion: true` | Under foreground deletion, the owner cannot be removed from etcd until this dependent is gone. |

### The Garbage Collector Controller

The `garbagecollector` controller builds an in memory **graph** of every object in the cluster and its owners. When a node in that graph loses all its owners, the object is deleted.

```
┌──────────────────────────────────────────────────────────────┐
│                  GC Ownership Graph                          │
│                                                              │
│   Deployment/web (uid A)                                     │
│         ▲                                                    │
│         │ ownerRef(controller=true, uid=A)                   │
│   ReplicaSet/web-7d9f8b6c5 (uid B)                           │
│         ▲                                                    │
│         │ ownerRef(controller=true, uid=B)                   │
│   Pod/web-7d9f8b6c5-x4k2p                                    │
│                                                              │
│  Delete Deployment ──► RS becomes ownerless ──► RS deleted   │
│                    ──► Pods become ownerless ──► Pods deleted│
└──────────────────────────────────────────────────────────────┘
```

Two rules that trip people up:

1. **Cross namespace ownership is not allowed.** A namespaced dependent may only be owned by an object in its own namespace, or by a cluster scoped object. Violating this makes the GC mark the dependent's ownerRef invalid and eventually delete the dependent.
2. **A cluster scoped object cannot be owned by a namespaced object.**

### Cascading Deletion Policies

```bash
# Background (the kubectl default for most resources):
# owner is deleted immediately, dependents are cleaned up asynchronously
kubectl delete deployment web --cascade=background

# Foreground: owner gets a deletionTimestamp and the
# foregroundDeletion finalizer; it stays visible until every
# blockOwnerDeletion dependent is gone, then the owner is removed
kubectl delete deployment web --cascade=foreground

# Orphan: dependents survive, their ownerReference to this owner
# is stripped. The ReplicaSet and Pods keep running.
kubectl delete deployment web --cascade=orphan
```

```
BACKGROUND
  t0: DELETE Deployment ──► gone from the API immediately
  t1: GC notices RS is ownerless ──► DELETE ReplicaSet
  t2: GC notices Pods are ownerless ──► DELETE Pods
  Observation: `kubectl get deploy` is empty while pods still terminate.

FOREGROUND
  t0: DELETE Deployment ──► deletionTimestamp set,
      finalizer "foregroundDeletion" added, object still listed
  t1: GC deletes dependents that set blockOwnerDeletion: true
  t2: last dependent gone ──► finalizer removed ──► owner removed
  Observation: the Deployment lingers in Terminating. That is correct.

ORPHAN
  t0: DELETE Deployment ──► "orphan" finalizer added
  t1: GC strips the ownerRef from the ReplicaSet
  t2: finalizer removed, Deployment gone, ReplicaSet still serving
```

```bash
# Prove orphaning works
kubectl create deployment web --image=nginx:1.25 --replicas=3
kubectl delete deployment web --cascade=orphan
kubectl get rs        # still there
kubectl get pods      # still Running
kubectl get rs -o jsonpath='{.items[0].metadata.ownerReferences}'   # empty
```

---

## Finalizers

A **finalizer** is a string in `metadata.finalizers` that turns a delete into a two phase operation.

```
DELETE request arrives
   │
   ├─ metadata.finalizers is EMPTY?
   │     └─► object removed from etcd. Done.
   │
   └─ metadata.finalizers is NON EMPTY?
         └─► API server sets metadata.deletionTimestamp
             object stays in etcd, now visible as "Terminating"
             │
             ├─ each responsible controller does its cleanup
             ├─ each removes its own string from the list
             │
             └─ list becomes empty ──► API server removes the object
```

### Finalizers You Will Meet

| Finalizer | Owner | Purpose |
|-----------|-------|---------|
| `kubernetes.io/pvc-protection` | pvc-protection controller | Blocks PVC deletion while a Pod still mounts it |
| `kubernetes.io/pv-protection` | pv-protection controller | Blocks PV deletion while it is Bound |
| `foregroundDeletion` | garbage collector | Implements foreground cascading deletion |
| `orphan` | garbage collector | Implements orphan cascading deletion |
| `kubernetes` (on Namespace) | namespace controller | Blocks namespace removal until all contained objects are purged |
| `batch.kubernetes.io/job-tracking` | job controller | Historical, tracked finished pods with finalizers |

```bash
# The classic "namespace stuck in Terminating"
kubectl get ns stuck-ns -o jsonpath='{.spec.finalizers}{"\n"}'
kubectl get ns stuck-ns -o jsonpath='{.status.conditions}' | jq

# Find what is actually left inside it
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 kubectl get --show-kind --ignore-not-found -n stuck-ns
```

> ⚠️ Force removing a finalizer with `kubectl patch ... -p '{"metadata":{"finalizers":null}}'` deletes the object without running its cleanup. That is how you end up with orphaned cloud load balancers, leaked disks, and unreferenced CRD data. Fix the controller that is failing to remove the finalizer first, and only strip it as a last resort on a cluster you own.

---

## The Status Subresource

`/status` is a **separate HTTP endpoint** with separate RBAC and separate write semantics.

```
PUT /apis/apps/v1/namespaces/default/deployments/web
     ──► writes spec + metadata, IGNORES the status you send

PUT /apis/apps/v1/namespaces/default/deployments/web/status
     ──► writes status, IGNORES the spec you send
```

Why it matters:

1. **Users cannot lie about reality.** Grant `update` on `deployments` and the user still cannot forge `status.readyReplicas`.
2. **Controllers cannot accidentally clobber spec.** A controller writing status through the subresource can never overwrite a concurrent user edit to `spec`.
3. **`metadata.generation` is only incremented on spec changes**, which requires the split to be enforced at the API layer.

### Conditions: the standard status vocabulary

```yaml
status:
  observedGeneration: 4
  conditions:
  - type: Available
    status: "True"
    lastUpdateTime: "2025-01-14T09:12:03Z"
    lastTransitionTime: "2025-01-14T09:12:03Z"
    reason: MinimumReplicasAvailable
    message: Deployment has minimum availability.
  - type: Progressing
    status: "True"
    reason: NewReplicaSetAvailable
    message: ReplicaSet "web-7d9f8b6c5" has successfully progressed.
```

| Field | Meaning |
|-------|---------|
| `type` | The aspect being reported, for example `Available` |
| `status` | `"True"`, `"False"` or `"Unknown"`. It is a string, not a bool. |
| `reason` | A machine readable CamelCase token. Safe to match on in scripts. |
| `message` | Human readable. Never parse this. |
| `lastTransitionTime` | Only changes when `status` flips. Use it to measure how long something has been broken. |

```bash
# Machine friendly condition check
kubectl get deploy web -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'

# Wait on a condition instead of sleeping
kubectl wait --for=condition=Available deployment/web --timeout=120s
```

---

## Generation and observedGeneration

```
  You edit spec
        │
        ▼
  API server increments metadata.generation   (4 ──► 5)
        │
        ▼
  Controller reconciles, finishes, writes
  status.observedGeneration = 5
```

| Comparison | Meaning |
|------------|---------|
| `observedGeneration == generation` | The status you are reading reflects the current spec |
| `observedGeneration < generation` | The controller has not caught up. **Any status you read is stale.** |
| `observedGeneration` missing | The controller does not report it, you cannot trust freshness |

This is the correct way to answer "is my change applied yet?" and it is why `kubectl rollout status` does not report success on a stale status.

```bash
kubectl get deploy web -o jsonpath='gen={.metadata.generation} observed={.status.observedGeneration}{"\n"}'
```

---

## Leader Election

In an HA control plane you run 3 `kube-controller-manager` replicas, but **only one may reconcile at a time**. Two deployment controllers acting on the same object would double create pods.

```
┌──────────────────────────────────────────────────────────────┐
│         Lease object: kube-system/kube-controller-manager    │
│                                                              │
│  spec:                                                       │
│    holderIdentity: cp1_5f2a...                               │
│    leaseDurationSeconds: 15                                  │
│    acquireTime: ...                                          │
│    renewTime: 2025-01-14T09:12:03.123456Z                    │
│    leaseTransitions: 2                                       │
└──────────────────────────────────────────────────────────────┘

  cp1 (LEADER)   renews renewTime every retryPeriod (2s)
                 must succeed within renewDeadline (10s) or it
                 STOPS its controllers and usually exits

  cp2, cp3       poll the Lease every retryPeriod
                 if now - renewTime > leaseDuration (15s)
                 they attempt an optimistic-concurrency update
                 to claim holderIdentity. First writer wins.
```

```bash
kubectl -n kube-system get lease
kubectl -n kube-system get lease kube-controller-manager -o yaml
kubectl -n kube-system get lease kube-scheduler -o yaml

# Who is the leader right now
kubectl -n kube-system get lease kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}{"\n"}'
```

Relevant flags (defaults shown are the long standing upstream defaults; confirm with `--help` for your build):

| Flag | Default | Effect |
|------|---------|--------|
| `--leader-elect` | `true` | Enable leader election |
| `--leader-elect-lease-duration` | `15s` | How stale a lease must be before a challenger may take it |
| `--leader-elect-renew-deadline` | `10s` | Leader gives up if it cannot renew within this window |
| `--leader-elect-retry-period` | `2s` | How often to renew or poll |
| `--leader-elect-resource-lock` | `leases` | Resource type used for the lock |

The invariant is `renewDeadline < leaseDuration` and `retryPeriod < renewDeadline`. If you tune these, keep that ordering or you will get split brain.

> Note: `kubelet` also writes a Lease per node into the `kube-node-lease` namespace. That is a **heartbeat**, not leader election, and it is what the node lifecycle controller watches.

---

## System Controllers

Everything below runs inside `kube-controller-manager` unless noted. Recent Kubernetes releases renamed the internal identifiers to a canonical `<name>-controller` form while keeping the historical names as aliases; run `kube-controller-manager --help` on your build to see the exact list.

### Workload Controllers

| Controller | Watches | Writes | Reconciles |
|-----------|---------|--------|-----------|
| **deployment** | Deployments, ReplicaSets, Pods | ReplicaSets, Deployment status | Creates one ReplicaSet per pod template revision; scales old and new RSes according to the update strategy |
| **replicaset** | ReplicaSets, Pods | Pods, RS status | Keeps `len(matching active pods) == spec.replicas`; adopts and orphans pods |
| **replicationcontroller** | ReplicationControllers, Pods | Pods | Legacy equivalent of the ReplicaSet controller for the `v1` ReplicationController |
| **statefulset** | StatefulSets, Pods, PVCs | Pods, PVCs | Ordered, identity stable pod creation and deletion; creates PVCs from `volumeClaimTemplates` |
| **daemonset** | DaemonSets, Pods, Nodes | Pods | Ensures exactly one matching pod per eligible node; adds node affinity and default tolerations to each pod it creates |
| **job** | Jobs, Pods | Pods, Job status | Runs pods until `completions` succeed, honours `parallelism`, `backoffLimit`, `activeDeadlineSeconds` |
| **cronjob** | CronJobs, Jobs | Jobs | Creates a Job when the schedule fires, applies `concurrencyPolicy`, `startingDeadlineSeconds`, history limits |
| **horizontalpodautoscaling** | HPAs, Scale subresources, metrics | `/scale` on targets | Periodically computes a desired replica count from metrics and writes it |
| **disruption** | PDBs, Pods, controllers | PDB status | Computes `status.disruptionsAllowed` so the Eviction API can allow or deny evictions |

### Node and Scheduling Controllers

| Controller | Reconciles |
|-----------|-----------|
| **nodelifecycle** | Watches node Leases and node status. Marks `Ready=Unknown` when heartbeats stop, applies `node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable` NoExecute taints, and runs the taint manager that evicts pods whose tolerations have expired. |
| **nodeipam** | Allocates a Pod CIDR range per node from `--cluster-cidr` and writes `node.spec.podCIDRs`. Only active with `--allocate-node-cidrs`. |
| **podgc** | Deletes terminated pods above `--terminated-pod-gc-threshold`, and deletes pods bound to nodes that no longer exist or that are out of service. |
| **ttl** | Maintains the `node.alpha.kubernetes.io/ttl` annotation used by kubelets to tune ConfigMap and Secret cache TTLs based on cluster size. |
| **ttl-after-finished** | Deletes finished Jobs once `spec.ttlSecondsAfterFinished` elapses. |
| **taint-eviction** | The eviction half of node lifecycle handling; deletes pods that do not tolerate a NoExecute taint, honouring `tolerationSeconds`. |

### Service and Networking Controllers

| Controller | Reconciles |
|-----------|-----------|
| **endpoint** | Maintains the legacy `Endpoints` object for each Service by listing pods matching `service.spec.selector` and filtering on readiness |
| **endpointslice** | Maintains `discovery.k8s.io/v1` EndpointSlices, the scalable replacement for Endpoints; packs addresses into slices with a bounded size |
| **endpointslicemirroring** | Mirrors manually created `Endpoints` (Services with no selector) into EndpointSlices so consumers only need one API |
| **service** | Reconciles cloud LoadBalancer Services. In modern clusters this lives in the external cloud controller manager, not in kube-controller-manager. |
| **route** | Programs cloud routes for pod CIDRs. Also a cloud controller manager responsibility today. |

### Storage Controllers

| Controller | Reconciles |
|-----------|-----------|
| **persistentvolume-binder** | Matches PVCs to suitable PVs, sets `claimRef` and `volumeName`, drives dynamic provisioning via StorageClass, and handles the PV reclaim policy |
| **attachdetach** | Creates and deletes `VolumeAttachment` objects so volumes are attached to the node a pod was scheduled on, and detached when no longer needed |
| **persistentvolume-expander** | Drives PVC resize once `spec.resources.requests.storage` is increased on an expandable StorageClass |
| **pvc-protection** | Adds and removes the `kubernetes.io/pvc-protection` finalizer to stop in use claims from vanishing |
| **pv-protection** | Same idea for PersistentVolumes |
| **ephemeral-volume** | Creates a PVC for each `pod.spec.volumes[].ephemeral` entry, owned by the pod |

### Identity, Policy and Housekeeping Controllers

| Controller | Reconciles |
|-----------|-----------|
| **namespace** | On namespace deletion, discovers every namespaced API resource and deletes all objects in it, then removes the `kubernetes` finalizer |
| **serviceaccount** | Ensures a `default` ServiceAccount exists in every namespace |
| **serviceaccount-token** | Legacy controller that generated Secret backed tokens for ServiceAccounts; modern clusters use short lived projected tokens issued by the API server via TokenRequest |
| **garbagecollector** | Owns the ownership graph and deletes orphaned dependents |
| **resourcequota** | Recomputes `ResourceQuota.status.used` from the objects in the namespace, feeding the quota admission plugin |
| **clusterrole-aggregation** | Fills in `rules` on ClusterRoles that define `aggregationRule`, by unioning matching ClusterRoles |
| **csrsigning** | Signs approved CertificateSigningRequests with the cluster CA |
| **csrapproving** | Auto approves CSRs that match built in kubelet bootstrap and serving policies |
| **csrcleaner** | Deletes old, expired CSR objects |
| **root-ca-cert-publisher** | Publishes the `kube-root-ca.crt` ConfigMap into every namespace so pods can verify the API server |
| **bootstrapsigner** / **tokencleaner** | Sign the `cluster-info` ConfigMap and delete expired bootstrap token Secrets, supporting `kubeadm join` |

```
┌────────────────────────────────────────────────────────────────┐
│        Who creates the object you are looking at?              │
├────────────────────────────────────────────────────────────────┤
│  Pod with ownerRef ReplicaSet   ──► replicaset controller      │
│  Pod with ownerRef Job          ──► job controller             │
│  Pod with ownerRef DaemonSet    ──► daemonset controller       │
│  Pod with ownerRef StatefulSet  ──► statefulset controller     │
│  Pod with ownerRef Node         ──► static pod mirrored by     │
│                                     the kubelet                │
│  Pod with NO ownerRef           ──► a human ran kubectl run    │
└────────────────────────────────────────────────────────────────┘
```

---

## Inspecting Controllers

### Where the controller manager actually runs

On a `kubeadm` cluster it is a **static pod**, defined by a manifest on disk, started directly by the kubelet, not by any controller.

```bash
# The pod object (a mirror pod created by the kubelet)
kubectl -n kube-system get pods -l component=kube-controller-manager -o wide

# The manifest on the control plane node, this is the real source of truth
sudo cat /etc/kubernetes/manifests/kube-controller-manager.yaml

# Live flags of the running process
kubectl -n kube-system get pod kube-controller-manager-cp1 \
  -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n'
```

### Logs

```bash
kubectl -n kube-system logs -l component=kube-controller-manager --tail=200

# Follow a single controller's decisions
kubectl -n kube-system logs kube-controller-manager-cp1 | grep -i replicaset

# Raise verbosity temporarily by editing the static pod manifest and adding -v=4
# The kubelet restarts the pod as soon as the file changes.
sudo vi /etc/kubernetes/manifests/kube-controller-manager.yaml
```

### Events: the controller's own explanation of what it did

```bash
# Everything, newest last
kubectl get events --sort-by=.lastTimestamp -A

# Only what controllers said about one object
kubectl describe deployment web | sed -n '/Events:/,$p'

# Structured, filtered
kubectl get events --field-selector involvedObject.kind=ReplicaSet,type=Warning
kubectl get events -o custom-columns=\
TIME:.lastTimestamp,SRC:.source.component,OBJ:.involvedObject.name,REASON:.reason,MSG:.message
```

| Event source component | Emitted by |
|------------------------|-----------|
| `deployment-controller` | deployment controller |
| `replicaset-controller` | replicaset controller |
| `default-scheduler` | kube-scheduler |
| `kubelet` | the node agent |
| `node-controller` | node lifecycle controller |
| `persistentvolume-controller` | PV binder |

> Events are stored in etcd with a TTL (one hour by default). A quiet `kubectl describe` does not mean nothing happened, it may mean it happened too long ago.

### Metrics

```bash
kubectl -n kube-system port-forward pod/kube-controller-manager-cp1 10257:10257 &
curl -sk https://localhost:10257/healthz
curl -sk https://localhost:10257/metrics | grep -E \
  'workqueue_depth|workqueue_adds_total|workqueue_queue_duration_seconds|rest_client_requests_total'
```

| Metric | What a bad value means |
|--------|------------------------|
| `workqueue_depth` climbing and not draining | Workers are too few or reconciles are failing |
| `workqueue_retries_total` climbing fast | A reconcile is erroring in a loop; check the logs |
| `workqueue_queue_duration_seconds` p99 high | Backlog; consider raising `--concurrent-*-syncs` |
| `rest_client_requests_total` with code `429` | You are being throttled by API priority and fairness |

---

## Controller Manager Flags

```bash
kube-controller-manager --help | less
```

| Flag | Typical default | What it does |
|------|-----------------|--------------|
| `--controllers` | `*` | Which controllers to run. `*` means all enabled by default. Prefix with `-` to disable one, for example `--controllers=*,-nodeipam`. Some, like `bootstrapsigner` and `tokencleaner`, are off unless named explicitly. |
| `--concurrent-deployment-syncs` | `5` | Worker goroutines for the deployment controller |
| `--concurrent-replicaset-syncs` | `5` | Worker goroutines for the ReplicaSet controller |
| `--concurrent-endpoint-syncs` | `5` | Worker goroutines for the endpoints controller |
| `--concurrent-gc-syncs` | `20` | Worker goroutines for the garbage collector |
| `--concurrent-service-syncs` | `1` | Worker goroutines for the service controller |
| `--kube-api-qps` / `--kube-api-burst` | `20` / `30` | Client side rate limit against the API server. The first thing to raise on a large cluster. |
| `--min-resync-period` | `12h` | Lower bound for informer resync, jittered up to 2x |
| `--node-monitor-period` | `5s` | How often node lifecycle inspects node health |
| `--node-monitor-grace-period` | `40s` | How long a node may go without a heartbeat before `Ready=Unknown`. Defaults have shifted between releases; verify with `--help`. |
| `--terminated-pod-gc-threshold` | `12500` | Number of terminated pods to keep before podgc prunes |
| `--horizontal-pod-autoscaler-sync-period` | `15s` | HPA evaluation interval |
| `--use-service-account-credentials` | `true` on kubeadm | Each controller uses its own ServiceAccount, so RBAC failures name the exact controller |
| `--leader-elect` | `true` | Leader election, see above |
| `--allocate-node-cidrs` / `--cluster-cidr` | off / unset | Enables nodeipam and the pod CIDR range it carves up |
| `--bind-address` | `127.0.0.1` on kubeadm | Metrics and health endpoint address. Loopback by default for safety. |

```bash
# Disable a single controller on a kubeadm control plane node
sudo vi /etc/kubernetes/manifests/kube-controller-manager.yaml
#   - --controllers=*,bootstrapsigner,tokencleaner,-nodeipam
# Save. The kubelet detects the file change and restarts the static pod.
kubectl -n kube-system get pod kube-controller-manager-cp1 -w
```

> ⚠️ `--use-service-account-credentials=true` is why an RBAC error reads `system:serviceaccount:kube-system:replicaset-controller cannot create pods`. That message tells you exactly which controller is blocked, which is far more useful than a generic `system:kube-controller-manager` denial.

---

## Writing Your Own Controller

The built in controllers are not special. They use the same client library and the same API you do. A custom controller is the foundation of the **operator pattern**.

### The Skeleton

```
1. Define the API
     Use an existing type, or add a CustomResourceDefinition with
     an OpenAPI v3 schema and a `subresources: { status: {} }` block
     so your CR gets its own /status endpoint.

2. Build a client and an informer factory
     informerFactory := informers.NewSharedInformerFactory(client, 30*time.Minute)

3. Register event handlers that ONLY enqueue keys
     AddFunc:    enqueue(obj)
     UpdateFunc: enqueue(new)   // skip if resourceVersion is unchanged
     DeleteFunc: enqueue(tombstone-aware key)

4. Map dependents back to owners
     A Pod change must enqueue the owning CR, via ownerReferences.

5. Wait for cache sync before starting workers
     cache.WaitForCacheSync(stopCh, informer.HasSynced)

6. Run N workers, each looping:
     key := queue.Get()
     err := reconcile(key)
     if err != nil { queue.AddRateLimited(key) } else { queue.Forget(key) }

7. reconcile(key):
     obj := lister.Get(key)                    // from cache, DeepCopy it
     if NotFound                    -> nothing to clean, return
     if obj.DeletionTimestamp != nil -> run finalizer cleanup, remove
                                        our finalizer, return
     desired := render(obj.Spec)
     actual  := lister.Get(childKey)
     create / patch / delete to make actual match desired
     set ownerReferences on everything we create
     update obj.Status, including observedGeneration = obj.Generation
```

### Non Negotiable Rules

| Rule | Reason |
|------|--------|
| Never mutate an object from the lister; `DeepCopy()` first | The cache is shared with every other controller in the process |
| Set `ownerReferences` on every child you create | Otherwise you must write your own garbage collection |
| Write status through the `/status` subresource | Prevents clobbering concurrent spec edits |
| Always set `status.observedGeneration` | Consumers cannot detect staleness without it |
| Emit Events for decisions a human would want to know about | `kubectl describe` is the primary debugging surface |
| Reconcile the whole object, never a delta | Level triggered correctness |
| Use `Patch` or optimistic concurrency, not blind `Update` | Avoids lost updates and `Conflict` retry storms |
| Add a finalizer only if you have external state to clean up | Every finalizer is a potential stuck object |

### A Minimal CRD to Reconcile

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: caches.example.com
spec:
  group: example.com
  scope: Namespaced
  names:
    plural: caches
    singular: cache
    kind: Cache
    shortNames: ["ch"]
  versions:
  - name: v1alpha1
    served: true
    storage: true
    subresources:
      status: {}                 # gives you /status and generation tracking
      scale:                     # gives you `kubectl scale` and HPA support
        specReplicasPath: .spec.replicas
        statusReplicasPath: .status.replicas
        labelSelectorPath: .status.selector
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: ["replicas"]
            properties:
              replicas:
                type: integer
                minimum: 1
              image:
                type: string
          status:
            type: object
            properties:
              replicas:
                type: integer
              selector:
                type: string
              observedGeneration:
                type: integer
              conditions:
                type: array
                items:
                  type: object
                  properties:
                    type:    { type: string }
                    status:  { type: string }
                    reason:  { type: string }
                    message: { type: string }
    additionalPrinterColumns:
    - name: Replicas
      type: integer
      jsonPath: .spec.replicas
    - name: Ready
      type: integer
      jsonPath: .status.replicas
```

### RBAC Your Controller Needs

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cache-controller
rules:
- apiGroups: ["example.com"]
  resources: ["caches"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["example.com"]
  resources: ["caches/status", "caches/finalizers"]
  verbs: ["get", "update", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
```

Note the `caches/status` and `caches/finalizers` subresources. Forgetting them is the most common reason a freshly written controller cannot update status or remove its own finalizer.

An **operator** is exactly this, plus domain knowledge: backup schedules, version aware upgrades, failover, quorum management. There is no separate API or runtime for operators; it is a naming convention for a controller that encodes human operational expertise.

---

## Troubleshooting

### Symptom: I applied a change and nothing happened

```bash
kubectl get deploy web -o jsonpath='gen={.metadata.generation} obs={.status.observedGeneration}{"\n"}'
```

- `obs < gen`: the controller has not processed it. Continue below.
- `obs == gen`: the controller *did* process it and decided nothing was needed. Diff your manifest against the live object.

```bash
kubectl diff -f deployment.yaml
```

### Symptom: no controller is reconciling anything, cluster wide

```bash
kubectl -n kube-system get pods -l component=kube-controller-manager
kubectl -n kube-system describe pod kube-controller-manager-cp1
kubectl -n kube-system logs kube-controller-manager-cp1 --tail=100

# Is anyone actually the leader?
kubectl -n kube-system get lease kube-controller-manager -o yaml
```

| Cause | Fix |
|-------|-----|
| Pod is `CrashLoopBackOff` | Read the logs; usually a bad flag after a manual manifest edit, or an unreadable certificate |
| Pod does not exist at all | The static pod manifest is missing or malformed YAML; the kubelet silently ignores unparsable files. Check `journalctl -u kubelet`. |
| Lease `renewTime` is frozen minutes ago | No leader. All replicas are failing to reach the API server. Check API server health and the controller manager kubeconfig. |
| Lease flips every few seconds | Leader thrashing. API latency exceeds `--leader-elect-renew-deadline`. Check etcd latency. |

### Symptom: an object is stuck in Terminating forever

```bash
kubectl get <kind> <name> -o jsonpath='{.metadata.finalizers}{"\n"}'
kubectl get <kind> <name> -o jsonpath='{.metadata.deletionTimestamp}{"\n"}'
kubectl describe <kind> <name> | sed -n '/Events:/,$p'
```

The finalizer string names the controller that owes you a cleanup. Find that controller and read its logs. Only strip the finalizer manually once you understand what will leak.

### Symptom: pods keep getting recreated after I delete them

```bash
kubectl get pod <pod> -o jsonpath='{.metadata.ownerReferences}' | jq
```

Follow the chain up. Delete the top level owner (usually a Deployment), not the pods.

### Symptom: controller emits FailedCreate events

```bash
kubectl describe rs <rs-name> | sed -n '/Events:/,$p'
kubectl get events --field-selector reason=FailedCreate -A
```

| Message contains | Cause | Fix |
|------------------|-------|-----|
| `exceeded quota` | ResourceQuota in the namespace | Raise the quota or lower requests |
| `forbidden` / `cannot create` | RBAC or a PodSecurity admission label on the namespace | Grant the verb, or relax the `pod-security.kubernetes.io/enforce` level |
| `is forbidden: ... spec.containers[0].securityContext` | Pod Security Standards rejecting the template | Fix the pod template's securityContext |
| `no providers available` | Admission webhook failing | `kubectl get validatingwebhookconfigurations` and check the webhook backend |

### Symptom: everything is slow, reconciles lag by minutes

```bash
curl -sk https://localhost:10257/metrics | grep workqueue_depth
kubectl get --raw /metrics | grep apiserver_flowcontrol_current_inqueue_requests
```

Raise `--kube-api-qps` and `--kube-api-burst`, then `--concurrent-<controller>-syncs`. Check etcd write latency before blaming the controller manager; a slow etcd throttles every controller at once.

### Symptom: an RBAC denial names a controller

```
E0114 ... replicaset_controller.go: pods is forbidden:
User "system:serviceaccount:kube-system:replicaset-controller" cannot create
resource "pods" in API group "" in the namespace "prod"
```

```bash
kubectl get clusterrole system:controller:replicaset-controller -o yaml
kubectl get clusterrolebinding system:controller:replicaset-controller -o yaml
kubectl auth can-i create pods \
  --as=system:serviceaccount:kube-system:replicaset-controller -n prod
```

Someone edited or deleted a built in `system:controller:*` role. Restore it; those roles are auto reconciled on API server start unless they carry `rbac.authorization.kubernetes.io/autoupdate: "false"`.

---

## Exam and Interview Traps

1. **`kubectl` does not create pods.** It writes a Deployment. The deployment controller writes a ReplicaSet. The ReplicaSet controller writes Pods. Saying "kubectl creates the pods" is an instant tell.
2. **The scheduler is not a controller manager controller.** `kube-scheduler` is a separate binary with its own leader election lease. It watches unscheduled pods and patches `spec.nodeName`. It never creates pods.
3. **Level triggered, not edge triggered.** If asked what happens when a watch event is lost, the answer is "the next event or resync repairs it", not "state is corrupted".
4. **`status` is never authoritative input.** Controllers derive status from reality; they do not read it back as truth. Editing status by hand is overwritten on the next sync.
5. **`observedGeneration` is the freshness check**, not `resourceVersion`. `resourceVersion` changes on status writes too.
6. **Deleting a namespace is a controller action, not an etcd wipe.** The namespace controller enumerates every namespaced API resource and deletes objects individually. A single broken aggregated API server can hang the whole namespace deletion.
7. **Foreground deletion leaves the parent visible.** A Deployment sitting in `Terminating` under `--cascade=foreground` is working correctly, not stuck.
8. **UID, not name, defines ownership.** Recreate a Deployment with the same name and the old ReplicaSets are not adopted; they are orphans with a dangling `uid` and get garbage collected.
9. **Only one owner reference may have `controller: true`.** Other ownerRefs are allowed for GC purposes but do not confer management.
10. **Cross namespace owner references are invalid** and cause the dependent to be garbage collected, not to be preserved.
11. **`--controllers` uses `-` to disable.** `--controllers=*,-nodeipam` runs everything except nodeipam. `--controllers=deployment` runs *only* the deployment controller, which will break your cluster.
12. **Some controllers are off by default even under `*`.** `bootstrapsigner` and `tokencleaner` must be named explicitly, which is why kubeadm lists them.
13. **Cloud specific controllers moved out.** `service` (LoadBalancer) and `route` live in the cloud controller manager on modern clusters. Looking for them in `kube-controller-manager` logs on a cloud cluster will waste your time.
14. **Events expire.** The default TTL is one hour. An empty Events section proves nothing about the past.
15. **The controller manager on kubeadm is a static pod.** You cannot `kubectl edit` it meaningfully; edit `/etc/kubernetes/manifests/kube-controller-manager.yaml` on the node and the kubelet restarts it.
16. **`--bind-address` defaults to loopback on kubeadm**, so `curl` for metrics must be run on the node or via `kubectl port-forward`.
17. **A finalizer blocks deletion, it does not block updates.** You can still edit the spec of an object in `Terminating`.
18. **Expectations, not events, prevent double creation.** The ReplicaSet controller tracks in flight creates so a stale cache cannot cause a pod storm.

---

## Related Topics

- [Kubernetes Architecture](k8s-architecture.md)
- [Control Plane Node](control-plane-node.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-apiserver](kube-apiserver.md)
- [kube-scheduler](kube-scheduler.md)
- [Kubernetes API](k8s-api.md)
- [etcd](etcd.md)
- [Pods](pods.md)
- [ReplicaSets](replicasets.md)
- [Deployments](deployments.md)
- [Deployment Strategies](deployment-strategies.md)
- [kubelet](kubelet.md)
- [kubectl](kubectl.md)
- [Imperative Kubernetes](imperative-kubernetes.md)

---

## Key Takeaways

1. A controller is an infinite loop that observes current state, compares it to desired state, and acts to close the gap. Everything in Kubernetes is built from this one pattern.
2. Kubernetes is **level triggered**. Events only tell a controller *which object to look at*; the action is always derived from the full current state, which makes lost events harmless.
3. `spec` is desired state written by you, `status` is observed state written only by controllers, and the `/status` subresource enforces that split at the API layer.
4. `metadata.generation` versus `status.observedGeneration` is the correct and only reliable way to ask "has the controller seen my change yet?".
5. `kube-controller-manager` is one process running dozens of controllers over a shared informer factory, so there is one watch per resource type rather than one per controller.
6. The informer pipeline is Reflector, DeltaFIFO, Indexer, event handlers, rate limited work queue, worker goroutines. Handlers enqueue keys and nothing else.
7. Work queues deduplicate keys, guarantee single concurrent processing per key, and apply exponential backoff on failure.
8. Resync replays the local cache through the handlers as a safety net. It is not a relist and costs no API traffic, but it does cause a burst of reconciles.
9. `ownerReferences` with `controller: true` and a matching `uid` define the ownership graph that the garbage collector uses to cascade deletes.
10. Background, foreground and orphan are the three cascading deletion policies; foreground and orphan are implemented with finalizers.
11. Finalizers convert deletion into a two phase operation. An object stuck in `Terminating` always means a controller has not removed its finalizer yet.
12. Leader election over a Lease in `kube-system` ensures exactly one controller manager replica reconciles at a time; the invariant is `retryPeriod < renewDeadline < leaseDuration`.
13. Controllers never call each other. They communicate exclusively by writing objects to the API server and watching for the result.
14. `--use-service-account-credentials` gives each controller its own identity, which turns vague RBAC errors into precise ones.
15. Writing your own controller means following the same rules: deep copy from the cache, set owner references, write status through the subresource, set `observedGeneration`, and stay idempotent. That is the whole operator pattern.

---

## References

- [Kubernetes Controllers Concept](https://kubernetes.io/docs/concepts/architecture/controller/)
- [kube-controller-manager Command Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)
- [Owners and Dependents](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)
- [Garbage Collection](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
- [Using Finalizers to Control Deletion](https://kubernetes.io/blog/2021/05/14/using-finalizers-to-control-deletion/)
- [Kubernetes Object Management](https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/)
- [Kubernetes API Concepts: Efficient Detection of Changes](https://kubernetes.io/docs/reference/using-api/api-concepts/#efficient-detection-of-changes)
- [Coordinated Leader Election and Leases](https://kubernetes.io/docs/concepts/architecture/leases/)
- [Extend Kubernetes with the Operator Pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)
- [Custom Resources and CustomResourceDefinitions](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
- [Using RBAC Authorization: Controller Roles](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#controller-roles)
- [Node Status and Heartbeats](https://kubernetes.io/docs/concepts/architecture/nodes/)
