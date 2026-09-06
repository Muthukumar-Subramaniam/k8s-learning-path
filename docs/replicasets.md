# 🧬 Kubernetes ReplicaSets: Guaranteeing Pod Count

A deep guide to the ReplicaSet controller: how it counts, adopts, orphans and deletes Pods, why the selector is immutable, and exactly what happens to your replicas when a node dies.

## 📋 Table of Contents
- [What Is a ReplicaSet?](#what-is-a-replicaset)
- [Relationship to Deployment](#relationship-to-deployment)
- [Anatomy of a ReplicaSet Manifest](#anatomy-of-a-replicaset-manifest)
- [Creating ReplicaSets](#creating-replicasets)
- [Labels and Selectors](#labels-and-selectors)
- [Why the Selector Is Immutable](#why-the-selector-is-immutable)
- [Replica Reconciliation Math](#replica-reconciliation-math)
- [Adoption and Orphaning](#adoption-and-orphaning)
- [Editing a Pod Out of the Selector](#editing-a-pod-out-of-the-selector)
- [Scale Down Ordering and Pod Deletion Cost](#scale-down-ordering-and-pod-deletion-cost)
- [The Scale Subresource](#the-scale-subresource)
- [ReplicaSet Status Fields](#replicaset-status-fields)
- [Handling Failures](#handling-failures)
- [ReplicaSet vs ReplicationController](#replicaset-vs-replicationcontroller)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What Is a ReplicaSet?

A **ReplicaSet** (`apps/v1`, kind `ReplicaSet`, short name `rs`) has exactly one job: make the number of running Pods matching its selector equal `spec.replicas`.

That is the whole contract. It does not do rolling updates. It does not do versioning. It does not do rollbacks. It counts.

```
┌──────────────────────────────────────────────────────────────┐
│                  ReplicaSet Responsibility                    │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│   spec.replicas: 3                                            │
│   spec.selector: app=web                                      │
│                                                               │
│   Pods with label app=web currently alive: 2                  │
│                                                               │
│           3 - 2 = 1  ──►  CREATE one Pod from spec.template   │
│                                                               │
│   Pods with label app=web currently alive: 5                  │
│                                                               │
│           3 - 5 = -2 ──►  DELETE two Pods (lowest priority)   │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### What "matching" means

A Pod counts toward the ReplicaSet if **all** of the following hold:

1. It is in the same namespace as the ReplicaSet.
2. Its labels satisfy `spec.selector`.
3. It is **active**: `metadata.deletionTimestamp` is nil and `status.phase` is not `Succeeded` or `Failed`.

Point 3 is important. A Pod that is `Terminating` still exists in the API but no longer counts, so the controller immediately creates a replacement rather than waiting for the object to disappear. That is why `kubectl delete pod` on a managed Pod produces a replacement almost instantly, before the old one finishes its grace period.

```bash
kubectl delete pod web-7d9f8b6c5-x4k2p
kubectl get pods -w
# NAME                    READY   STATUS        AGE
# web-7d9f8b6c5-x4k2p     1/1     Terminating   9m
# web-7d9f8b6c5-q8n1z     0/1     Pending       0s     <-- replacement already exists
```

---

## Relationship to Deployment

You will rarely create a ReplicaSet directly. In production the ownership chain is always:

```
┌───────────────┐  creates and scales   ┌───────────────┐  creates  ┌────────┐
│  Deployment   │──────────────────────►│  ReplicaSet   │──────────►│  Pod   │
│               │                       │  (one per pod │           │        │
│  strategy,    │                       │   template    │           │        │
│  history,     │                       │   revision)   │           │        │
│  rollback     │                       │               │           │        │
└───────────────┘                       └───────────────┘           └────────┘
   deployment                              replicaset            kube-scheduler
   controller                              controller            then kubelet
```

| Capability | ReplicaSet | Deployment |
|-----------|-----------|-----------|
| Keep N pods running | ✅ | ✅ (via its ReplicaSets) |
| Self heal on pod or node loss | ✅ | ✅ |
| Scale up and down | ✅ | ✅ |
| Rolling update of the pod template | ❌ | ✅ |
| Recreate strategy | ❌ | ✅ |
| Revision history | ❌ | ✅ |
| Rollback | ❌ | ✅ |
| Pause and resume a rollout | ❌ | ✅ |
| `kubectl rollout` support | ❌ | ✅ |

**A Deployment updates a pod template by creating a second ReplicaSet and shifting replicas between them.** The old ReplicaSet is not deleted; it is scaled to zero and kept as a revision. This is the mechanism behind every rollback.

```bash
kubectl create deployment web --image=nginx:1.25 --replicas=3
kubectl set image deployment/web nginx=nginx:1.26
kubectl get rs -l app=web

# NAME             DESIRED   CURRENT   READY   AGE
# web-7d9f8b6c5    0         0         0       4m    <-- old revision, kept
# web-59c4d7f8b    3         3         3       30s   <-- new revision, active
```

> Legitimate reasons to write a bare ReplicaSet are rare: teaching, controllers you write yourself that manage revisions their own way, or a workload that must never be updated in place. If you are unsure, use a Deployment.

---

## Anatomy of a ReplicaSet Manifest

```yaml
apiVersion: apps/v1              # ReplicaSet lives in the apps group, v1
kind: ReplicaSet
metadata:
  name: web                      # child pods are named <rs-name>-<random5>
  namespace: default
  labels:                        # labels ON the ReplicaSet object itself.
    app: web                     # These are NOT used for matching pods.
    tier: frontend
spec:
  replicas: 3                    # desired count. Defaults to 1 if omitted.
  minReadySeconds: 10            # a pod must stay Ready this long before it
                                 # counts toward status.availableReplicas
  selector:                      # REQUIRED and IMMUTABLE in apps/v1
    matchLabels:
      app: web
      tier: frontend
  template:                      # the PodTemplateSpec used for new pods
    metadata:
      labels:                    # MUST be a superset of selector.matchLabels
        app: web
        tier: frontend
        version: "1.25"          # extra labels are allowed and encouraged
    spec:
      terminationGracePeriodSeconds: 30
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports:
        - name: http
          containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
          limits:
            memory: 128Mi
        readinessProbe:          # drives status.readyReplicas
          httpGet:
            path: /
            port: http
          initialDelaySeconds: 3
          periodSeconds: 5
        livenessProbe:           # restarts the container in place, does not
          httpGet:               # create a new pod and does not change counts
            path: /
            port: http
          periodSeconds: 10
```

### Field by field

| Field | Required | Mutable | Notes |
|-------|----------|---------|-------|
| `spec.replicas` | no (default `1`) | yes | Set to `0` to park the workload without deleting it |
| `spec.selector` | **yes** | **no** | Rejected at admission if it does not match `spec.template.metadata.labels` |
| `spec.template` | yes | yes | Changing it does **not** restart existing pods. Only new pods use the new template. |
| `spec.minReadySeconds` | no (default `0`) | yes | Gate between Ready and Available |

> ⚠️ **The single biggest ReplicaSet gotcha:** editing `spec.template` on a ReplicaSet does nothing to running pods. There is no rollout logic. The new template applies only to pods created after the edit. If you want existing pods replaced, you must delete them, or use a Deployment.

---

## Creating ReplicaSets

### Declaratively (the normal way)

```bash
kubectl apply -f replicaset.yaml
kubectl get rs
kubectl get rs web -o wide
kubectl describe rs web
```

```bash
# NAME   DESIRED   CURRENT   READY   AGE   CONTAINERS   IMAGES              SELECTOR
# web    3         3         3       12s   nginx        nginx:1.25-alpine   app=web,tier=frontend
```

| Column | Source field | Meaning |
|--------|--------------|---------|
| `DESIRED` | `spec.replicas` | What you asked for |
| `CURRENT` | `status.replicas` | Pods that exist and are owned |
| `READY` | `status.readyReplicas` | Pods passing their readiness probe |
| `AGE` | `metadata.creationTimestamp` | |

### Imperatively

There is **no `kubectl create replicaset`** subcommand. This surprises people in exams. Your options:

```bash
# Option 1: generate a Deployment manifest and convert it by hand.
kubectl create deployment web --image=nginx:1.25 --replicas=3 \
  --dry-run=client -o yaml > rs.yaml
# then edit: kind: Deployment -> ReplicaSet, and delete the
# spec.strategy block, which ReplicaSet does not have.

# Option 2: create a Deployment and let it produce the ReplicaSet for you.
kubectl create deployment web --image=nginx:1.25 --replicas=3

# Option 3: write it from scratch. For exams, memorise the skeleton:
#   apiVersion/kind/metadata.name/spec.replicas/spec.selector.matchLabels/spec.template
```

```bash
# Verify what subcommands actually exist before you waste exam minutes
kubectl create --help | grep -i replica       # only "kubectl create deployment" exists
kubectl api-resources | grep -i replicaset
# replicasets   rs   apps/v1   true   ReplicaSet
```

### Explaining the schema without leaving the terminal

```bash
kubectl explain replicaset.spec
kubectl explain replicaset.spec.selector
kubectl explain replicaset.spec.template.spec.containers --recursive | head -50
kubectl explain rs.status
```

### Watching the controller do its work

```bash
kubectl apply -f replicaset.yaml
kubectl get pods -l app=web -w

kubectl describe rs web | sed -n '/Events:/,$p'
# Events:
#   Type    Reason            Age   From                   Message
#   ----    ------            ----  ----                   -------
#   Normal  SuccessfulCreate  8s    replicaset-controller  Created pod: web-x4k2p
#   Normal  SuccessfulCreate  8s    replicaset-controller  Created pod: web-q8n1z
#   Normal  SuccessfulCreate  8s    replicaset-controller  Created pod: web-m2v7t
```

The `From` column names `replicaset-controller`. That is the ServiceAccount identity of the controller, and it is your proof of which component acted.

### Deleting

```bash
# Default cascade: pods are deleted too
kubectl delete rs web

# Keep the pods running, strip their ownerReferences
kubectl delete rs web --cascade=orphan
kubectl get pods -l app=web              # still Running
kubectl get pod web-x4k2p -o jsonpath='{.metadata.ownerReferences}'   # empty
```

Orphaned pods are now unmanaged. Nothing will replace them if they die. Creating a new ReplicaSet with a matching selector will **adopt** them, which is a useful trick and a dangerous accident.

---

## Labels and Selectors

The selector is the only link between a ReplicaSet and its pods. Names are irrelevant to matching.

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│   ReplicaSet "web"                                             │
│     spec.selector.matchLabels: { app: web, tier: frontend }    │
│                     │                                          │
│                     │  matches pods by LABEL, never by name    │
│         ┌───────────┼───────────┬──────────────┐               │
│         ▼           ▼           ▼              ▼               │
│   ┌──────────┐┌──────────┐┌──────────┐  ┌──────────────┐      │
│   │ web-x4k2p││ web-q8n1z││ web-m2v7t│  │ legacy-pod-1 │      │
│   │ app=web  ││ app=web  ││ app=web  │  │ app=web      │      │
│   │ tier=    ││ tier=    ││ tier=    │  │ tier=        │      │
│   │ frontend ││ frontend ││ frontend │  │ frontend     │      │
│   └──────────┘└──────────┘└──────────┘  └──────────────┘      │
│      OWNED       OWNED       OWNED        ADOPTED if it has    │
│                                           no controller owner  │
└────────────────────────────────────────────────────────────────┘
```

### matchLabels: equality based

```yaml
spec:
  selector:
    matchLabels:
      app: web
      tier: frontend
```

All entries are ANDed. A pod must carry `app=web` **and** `tier=frontend`. Extra labels on the pod are ignored for matching.

### matchExpressions: set based

```yaml
spec:
  selector:
    matchLabels:
      app: web
    matchExpressions:
    - key: tier
      operator: In
      values: ["frontend", "edge"]
    - key: environment
      operator: NotIn
      values: ["canary"]
    - key: track
      operator: Exists
    - key: deprecated
      operator: DoesNotExist
```

| Operator | Requires `values` | Meaning |
|----------|-------------------|---------|
| `In` | yes, non empty | Label value is one of the listed values |
| `NotIn` | yes, non empty | Label key is absent, or its value is not listed |
| `Exists` | must be empty | Label key is present, any value |
| `DoesNotExist` | must be empty | Label key is absent |

`matchLabels` and `matchExpressions` are **ANDed together**. Every requirement must hold.

> An empty selector object (`selector: {}`) is not the same as an omitted one. In `apps/v1` the selector is required, and an empty `matchLabels` would match every pod in the namespace, which is why the API rejects a template whose labels do not satisfy the selector.

### The validation rule you will hit

```
spec.template.metadata.labels MUST satisfy spec.selector
```

If it does not, the API server rejects the object:

```bash
kubectl apply -f bad-rs.yaml
# The ReplicaSet "web" is invalid: spec.template.metadata.labels:
# Invalid value: map[string]string{"app":"nginx"}:
# `selector` does not match template `labels`
```

The reason is a safety check against an infinite loop: the ReplicaSet would create a pod, that pod would not match the selector, the count would stay at zero, and the controller would create another pod forever.

### Working with labels from the CLI

```bash
# Show labels
kubectl get pods --show-labels
kubectl get pods -L app,tier,pod-template-hash

# Equality based selection
kubectl get pods -l app=web
kubectl get pods -l app=web,tier=frontend
kubectl get pods -l 'app!=web'

# Set based selection
kubectl get pods -l 'tier in (frontend,edge)'
kubectl get pods -l 'environment notin (canary)'
kubectl get pods -l 'track'                 # Exists
kubectl get pods -l '!deprecated'           # DoesNotExist

# Which selector does this ReplicaSet use
kubectl get rs web -o jsonpath='{.spec.selector}{"\n"}'

# Add, change and remove a label on a live pod
kubectl label pod web-x4k2p canary=true
kubectl label pod web-x4k2p app=quarantined --overwrite
kubectl label pod web-x4k2p canary-
```

---

## Why the Selector Is Immutable

In `apps/v1`, `spec.selector` cannot be changed after creation.

```bash
kubectl patch rs web --type=merge -p '{"spec":{"selector":{"matchLabels":{"app":"web2"}}}}'
# The ReplicaSet "web" is invalid: spec.selector: Invalid value: ...
# field is immutable
```

### The reasoning

```
Suppose selectors were mutable.

  t0:  RS/web  selector app=web   ──► owns 3 pods labelled app=web
  t1:  you change selector to app=web2
  t2:  the 3 existing pods no longer match. They are released as orphans.
       Nothing owns them. Nothing will ever delete them.
  t3:  the controller sees 0 matching pods, creates 3 new ones with the
       new template labels.

  Result: 6 pods, 3 of them permanently unmanaged, and the ReplicaSet
  status reports 3. Every consumer of that status is now lying.
```

Immutability makes ownership stable for the lifetime of the object. To change a selector you must delete and recreate, which forces you to decide consciously what happens to the existing pods (`--cascade=orphan` or not).

The same immutability applies to `Deployment.spec.selector`, `StatefulSet.spec.selector` and `DaemonSet.spec.selector` in `apps/v1`. It was mutable in the long removed `extensions/v1beta1` versions, which is the source of most stale blog posts on the subject.

---

## Replica Reconciliation Math

Every sync computes one number:

```
diff = len(activePods) - *rs.Spec.Replicas
```

```
┌───────────────────────────────────────────────────────────────┐
│  diff < 0   Too few pods                                      │
│             CREATE (-diff) pods from spec.template            │
│             Each new pod gets:                                │
│               metadata.generateName = "<rs-name>-"            │
│               metadata.labels       = template labels         │
│               metadata.ownerReferences = [RS, controller:true]│
│                                                               │
│  diff > 0   Too many pods                                     │
│             DELETE (diff) pods, chosen by the deletion        │
│             priority ordering described below                 │
│                                                               │
│  diff == 0  Nothing to do, only recompute status              │
└───────────────────────────────────────────────────────────────┘
```

### Slow start batching

The controller does **not** fire off 500 creates at once. It uses a slow start: 1 pod, then 2, then 4, then 8, doubling each batch, and it aborts the remaining batches if a create fails.

```
Want 100 new pods:
  batch 1:   1 pod   ─► all succeed ─► continue
  batch 2:   2 pods  ─► all succeed ─► continue
  batch 3:   4 pods  ─► all succeed ─► continue
  batch 4:   8 pods
  batch 5:  16 pods
  batch 6:  32 pods
  batch 7:  37 pods  (remaining)

If batch 1 fails with "exceeded quota", the controller stops immediately
instead of generating 100 identical failures and 100 identical Events.
```

There is also a hard per sync cap (`burstReplicas`, 500 in upstream) so a single sync never issues an unbounded number of API calls.

### Expectations: why a stale cache does not cause a pod storm

The controller's informer cache is eventually consistent. Without protection, this happens:

```
sync 1: cache shows 0 pods, want 3 ──► create 3 pods
sync 2: (200ms later, cache has not caught up) shows 0 pods ──► create 3 more
sync 3: shows 2 pods ──► create 1 more
Result: 7 pods for spec.replicas: 3
```

To prevent this, the controller records **expectations**: "I issued 3 creates for key default/web". Until it observes 3 corresponding Add events, or a timeout of roughly 5 minutes elapses, it refuses to issue more creates for that key.

```bash
# Symptom of expectations working: a brief pause after a large scale up
# before the next batch appears. This is correct behaviour, not a stall.
kubectl -n kube-system logs -l component=kube-controller-manager \
  | grep -i "expectation"
```

---

## Adoption and Orphaning

Every sync, before counting, the controller runs a **claim** pass over all pods in the namespace that match its selector.

```
For each pod P matching rs.spec.selector:

  P has NO controller ownerReference?
      └─► ADOPT: patch P to add
            ownerReferences: [{kind: ReplicaSet, name: web, uid: <rs uid>,
                               controller: true, blockOwnerDeletion: true}]

  P has a controller ownerReference pointing at THIS rs (matching uid)?
      └─► already ours, count it

  P has a controller ownerReference pointing at SOMETHING ELSE?
      └─► SKIP. Never steal another controller's pod.

For each pod P owned by this rs that NO LONGER matches the selector:
      └─► ORPHAN: patch P to remove our ownerReference
```

### Demonstrating adoption

```bash
# 1. Create a bare pod with labels that a future ReplicaSet will select
kubectl run orphan-web --image=nginx:1.25 --labels="app=web,tier=frontend"
kubectl get pod orphan-web -o jsonpath='{.metadata.ownerReferences}{"\n"}'
# (empty)

# 2. Now create a ReplicaSet with replicas: 3 and selector app=web,tier=frontend
kubectl apply -f replicaset.yaml

# 3. The bare pod is adopted and COUNTS toward the 3
kubectl get pods -l app=web
# NAME          READY   STATUS    AGE
# orphan-web    1/1     Running   2m      <-- adopted
# web-q8n1z     1/1     Running   5s      <-- only 2 new pods created
# web-m2v7t     1/1     Running   5s

kubectl get pod orphan-web -o jsonpath='{.metadata.ownerReferences}' | jq
# [{"apiVersion":"apps/v1","kind":"ReplicaSet","name":"web",
#   "uid":"...","controller":true,"blockOwnerDeletion":true}]
```

The adopted pod keeps its **original image and spec**. It was not created from `spec.template`, so it may be running a completely different container. The ReplicaSet does not care; it only counts. This is a genuine production hazard when someone runs `kubectl run` with production labels.

### Demonstrating orphaning

```bash
# Change a label so the pod stops matching
kubectl label pod orphan-web app=quarantined --overwrite

kubectl get pod orphan-web -o jsonpath='{.metadata.ownerReferences}{"\n"}'
# (empty) -- released

kubectl get pods -l app=web
# a replacement was created immediately to restore the count to 3
```

### UID, not name

Adoption compares the **UID** in the ownerReference against the ReplicaSet's UID.

```bash
kubectl get rs web -o jsonpath='{.metadata.uid}{"\n"}'
```

If you delete the ReplicaSet with `--cascade=orphan` and recreate it with the same name, the new object has a **new UID**. The old pods have no controller ownerRef at that point (orphaning stripped it), so they are adopted. But if you delete the ReplicaSet in a way that leaves a *stale* ownerRef pointing at the old UID, the garbage collector deletes those pods because their owner no longer exists.

---

## Editing a Pod Out of the Selector

This is the classic "quarantine a misbehaving pod for debugging" technique and a very common exam scenario.

```
BEFORE
  RS/web  replicas: 3   selector: app=web
  pods:  web-aaa(app=web)  web-bbb(app=web)  web-ccc(app=web)
  status.replicas: 3   ✓ steady state

ACTION
  kubectl label pod web-bbb app=debug --overwrite

WHAT THE CONTROLLER SEES, IN ORDER
  1. Pod update event ──► enqueue "default/web"
  2. Claim pass: web-bbb no longer matches selector, and we own it
       ──► PATCH web-bbb to REMOVE our ownerReference
  3. Count active matching pods: web-aaa, web-ccc = 2
  4. diff = 2 - 3 = -1
  5. CREATE one pod: web-ddd
  6. status.replicas: 3

AFTER
  RS/web  replicas: 3   owns: web-aaa, web-ccc, web-ddd
  web-bbb: still Running, no owner, no one will ever replace or delete it
```

```bash
# Full walkthrough
kubectl get pods -l app=web --show-labels
kubectl label pod web-bbb app=debug --overwrite

kubectl get pods --show-labels
kubectl get pod web-bbb -o jsonpath='{.metadata.ownerReferences}{"\n"}'   # empty
kubectl get rs web                     # DESIRED 3, CURRENT 3

# Debug the quarantined pod at leisure
kubectl exec -it web-bbb -- sh
kubectl logs web-bbb --previous

# Clean up when done. Nothing else will.
kubectl delete pod web-bbb
```

### Bringing it back

```bash
kubectl label pod web-bbb app=web --overwrite
```

Now four pods match and `diff = 4 - 3 = +1`, so the controller deletes one. It may or may not be the one you just relabelled; the deletion ordering decides.

---

## Scale Down Ordering and Pod Deletion Cost

When `diff > 0`, the controller sorts candidate pods and deletes from the front. The ordering is an implementation detail that has been stable for a long time and is documented alongside the pod deletion cost feature:

```
Deleted FIRST  ──────────────────────────────────────────►  Deleted LAST

 1. Pods that are not yet assigned to a node (no spec.nodeName)
 2. Pods in phase Pending, then Unknown, then Running
 3. Pods that are NOT Ready before pods that are Ready
 4. Pods with a LOWER controller.kubernetes.io/pod-deletion-cost value
 5. Pods on nodes that host MORE replicas of this same ReplicaSet
    (spreads the survivors across nodes)
 6. Pods that have been Ready for a SHORTER time
 7. Pods with MORE container restarts
 8. Pods created MORE recently (newer creationTimestamp)
```

The intuition: throw away the cheapest, least proven, least spread out pods first.

### Pod deletion cost

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-important
  annotations:
    controller.kubernetes.io/pod-deletion-cost: "100"
```

- The value is a **string containing a signed 32 bit integer**. Negative values are legal.
- **Lower cost is deleted first.** The default when the annotation is absent is `0`.
- It applies to ReplicaSet scale down only. It is a hint, not a guarantee, and it is best effort with respect to ordering against the other criteria.
- It has no effect on which pods a rolling update replaces, on node drains, or on eviction under node pressure.

```bash
# Protect the pod currently holding a long lived session
kubectl annotate pod web-x4k2p controller.kubernetes.io/pod-deletion-cost=1000 --overwrite

# Mark a pod as the preferred victim
kubectl annotate pod web-q8n1z controller.kubernetes.io/pod-deletion-cost=-100 --overwrite

kubectl scale rs web --replicas=2
kubectl get pods -l app=web
```

Typical use: an application controller annotates pods based on how much in flight work they hold, so scaling down sheds idle capacity first.

---

## The Scale Subresource

ReplicaSet exposes `/scale`, which is what makes `kubectl scale` and the HorizontalPodAutoscaler work against it.

```bash
kubectl get --raw /apis/apps/v1/namespaces/default/replicasets/web/scale | jq
```

```json
{
  "kind": "Scale",
  "apiVersion": "autoscaling/v1",
  "metadata": { "name": "web", "namespace": "default" },
  "spec":   { "replicas": 3 },
  "status": { "replicas": 3, "selector": "app=web,tier=frontend" }
}
```

```bash
# Straight scale
kubectl scale rs web --replicas=5

# Conditional scale: only act if the current count is exactly 5.
# This is optimistic concurrency and prevents you from stomping on
# an autoscaler or another operator.
kubectl scale rs web --current-replicas=5 --replicas=2

# Guard on a specific object version
kubectl scale rs web --replicas=4 --resource-version=1234567

# Scale by label selector
kubectl scale rs --replicas=0 -l tier=frontend

# Park the workload entirely without losing the object
kubectl scale rs web --replicas=0
kubectl get rs web
# NAME   DESIRED   CURRENT   READY   AGE
# web    0         0         0       31m
```

Because `/scale` is a distinct subresource, RBAC can grant scaling without granting general edit rights:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scaler
  namespace: default
rules:
- apiGroups: ["apps"]
  resources: ["replicasets/scale", "deployments/scale"]
  verbs: ["get", "update", "patch"]
```

> If a Deployment owns the ReplicaSet, scaling the ReplicaSet directly is pointless. The deployment controller recomputes the desired replica split on its next sync and reverts you. Scale the Deployment.

---

## ReplicaSet Status Fields

```yaml
status:
  observedGeneration: 2
  replicas: 3               # owned, active pods
  fullyLabeledReplicas: 3   # owned pods whose labels exactly match ALL of
                            # spec.template.metadata.labels
  readyReplicas: 3          # owned pods with Ready condition True
  availableReplicas: 3      # ready for at least spec.minReadySeconds
  conditions:
  - type: ReplicaFailure
    status: "True"
    reason: FailedCreate
    message: 'pods "web-" is forbidden: exceeded quota: compute-quota'
```

| Field | Meaning | Typical divergence cause |
|-------|---------|--------------------------|
| `replicas` | Pods that exist and are owned | Should equal `spec.replicas` at steady state |
| `fullyLabeledReplicas` | Pods carrying every label in the template | Lower than `replicas` means an **adopted** pod that was not created from the template |
| `readyReplicas` | Pods passing readiness | Lower means probes failing, or containers still starting |
| `availableReplicas` | Ready for `minReadySeconds` | Lower means the pods are new, or flapping in and out of Ready |
| `conditions[ReplicaFailure]` | Set when pod creation or deletion is being rejected | Quota, RBAC, admission webhooks, Pod Security |

```bash
kubectl get rs web -o jsonpath='{.status}' | jq

# fullyLabeledReplicas below replicas is the fingerprint of an adopted pod
kubectl get rs web -o custom-columns=\
NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,\
LABELED:.status.fullyLabeledReplicas,READY:.status.readyReplicas,\
AVAIL:.status.availableReplicas
```

### ReplicaFailure in detail

```bash
kubectl get rs web -o jsonpath='{.status.conditions[?(@.type=="ReplicaFailure")]}' | jq
kubectl describe rs web | sed -n '/Events:/,$p'
kubectl get events --field-selector reason=FailedCreate,involvedObject.name=web
```

`ReplicaFailure` means the API server is **refusing** the controller's create or delete calls. The pods never reach `Pending`, so `kubectl get pods` shows nothing at all. That combination, `DESIRED 3 / CURRENT 0` with no pods anywhere, always means look at the ReplicaSet conditions, not at the scheduler.

---

## Handling Failures

### Failure mode 1: a container crashes

The kubelet restarts the container in place according to `restartPolicy`. The Pod object survives, its name and IP are unchanged, `status.containerStatuses[].restartCount` increments. **The ReplicaSet does nothing**, because the pod is still active and still matching.

```bash
kubectl get pods -l app=web
# NAME        READY   STATUS             RESTARTS      AGE
# web-x4k2p   0/1     CrashLoopBackOff   5 (68s ago)   4m

kubectl logs web-x4k2p --previous
kubectl describe pod web-x4k2p | sed -n '/Last State/,/Ready/p'
```

`readyReplicas` drops, `replicas` does not. A crash looping pod is never replaced by the ReplicaSet controller. It stays and keeps crashing until you fix it.

### Failure mode 2: a pod is deleted

```
t0  kubectl delete pod web-x4k2p
t0  API server sets deletionTimestamp, pod becomes "Terminating"
t0  Pod is no longer counted as active by the RS controller
t0  diff = 2 - 3 = -1  ──►  CREATE replacement immediately
t0  kubelet sends SIGTERM to containers in the old pod
t0+ grace period (default 30s) ──► SIGKILL if still alive
t0+ kubelet confirms, API server removes the object
```

The replacement exists before the original is gone. That is deliberate and it is why `terminationGracePeriodSeconds` does not delay recovery.

### Failure mode 3: a node dies

This is the important one, and the timeline is exam material.

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Node Failure Timeline                             │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│ t=0s     Node powers off. kubelet stops renewing its Lease in the    │
│          kube-node-lease namespace.                                  │
│          (kubelet renews roughly every --node-status-update-frequency,│
│           default 10s)                                               │
│                                                                      │
│ t=0..40s node-lifecycle-controller polls every --node-monitor-period │
│          (default 5s) and sees a stale renewTime, but the grace      │
│          period has not elapsed. Node still shows Ready.             │
│                                                                      │
│ t≈40s    --node-monitor-grace-period elapses (long standing default  │
│          40s; verify with kube-controller-manager --help).           │
│          Controller sets node condition Ready=Unknown.               │
│          Controller applies the taint:                               │
│            node.kubernetes.io/unreachable:NoExecute                  │
│          kubectl get nodes now shows NotReady.                       │
│                                                                      │
│ t≈40s    Pods on that node do NOT die yet. Every pod carries         │
│          tolerations injected by the DefaultTolerationSeconds        │
│          admission plugin:                                           │
│            node.kubernetes.io/not-ready:NoExecute  for 300s          │
│            node.kubernetes.io/unreachable:NoExecute for 300s         │
│          (controlled by the kube-apiserver flags                     │
│           --default-not-ready-toleration-seconds and                 │
│           --default-unreachable-toleration-seconds, default 300)     │
│                                                                      │
│ t≈340s   Toleration expires. The taint eviction manager issues       │
│          DELETE on each pod. deletionTimestamp is set.               │
│                                                                      │
│ t≈340s   The pods are no longer "active" ──► the ReplicaSet          │
│          controller creates replacements on healthy nodes.           │
│                                                                      │
│ t≈340s+  The old pod objects remain in "Terminating" indefinitely.   │
│          Confirmation of deletion normally comes from the kubelet,   │
│          and that kubelet is unreachable.                            │
│                                                                      │
│ Resolution paths:                                                    │
│   a) node comes back ──► kubelet cleans up ──► objects removed       │
│   b) node object is deleted ──► podgc removes pods bound to a        │
│      nonexistent node                                                │
│   c) admin applies node.kubernetes.io/out-of-service:NoExecute to    │
│      a confirmed dead node ──► pods are force deleted and volumes    │
│      detached, without waiting for the kubelet                       │
└──────────────────────────────────────────────────────────────────────┘
```

**Total time to replacement is roughly 40s + 300s, about 5 to 6 minutes with defaults.** People expect seconds and are shocked. The tunables are:

| Where | Flag | Default | Effect |
|-------|------|---------|--------|
| kubelet | `--node-status-update-frequency` | `10s` | Heartbeat interval |
| kube-controller-manager | `--node-monitor-period` | `5s` | How often node health is inspected |
| kube-controller-manager | `--node-monitor-grace-period` | `40s` | Silence before `Ready=Unknown` |
| kube-apiserver | `--default-not-ready-toleration-seconds` | `300` | Grace before eviction on NotReady |
| kube-apiserver | `--default-unreachable-toleration-seconds` | `300` | Grace before eviction on Unreachable |

Per workload, you override the toleration in the pod template instead of changing cluster wide flags:

```yaml
spec:
  template:
    spec:
      tolerations:
      - key: node.kubernetes.io/not-ready
        operator: Exists
        effect: NoExecute
        tolerationSeconds: 30      # evict after 30s instead of 300s
      - key: node.kubernetes.io/unreachable
        operator: Exists
        effect: NoExecute
        tolerationSeconds: 30
```

```bash
# See the injected tolerations on any pod
kubectl get pod web-x4k2p -o jsonpath='{.spec.tolerations}' | jq

# Watch a node degrade
kubectl get nodes -w
kubectl describe node worker2 | sed -n '/Taints:/,/Unschedulable/p'
kubectl describe node worker2 | sed -n '/Conditions:/,/Addresses:/p'

# Which pods are stranded
kubectl get pods -A -o wide --field-selector spec.nodeName=worker2

# Confirmed dead hardware: unblock volume detach and pod deletion
kubectl taint node worker2 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
# Remove the taint once the node is genuinely gone or has returned healthy
kubectl taint node worker2 node.kubernetes.io/out-of-service-
```

> ⚠️ **Never `kubectl delete pod --force --grace-period=0` on a StatefulSet pod on an unreachable node.** It removes the API object without any confirmation that the container stopped. If the node is merely partitioned, you now have two processes claiming the same identity and the same volume. For a ReplicaSet backed stateless pod it is usually safe, but it is still the wrong first instinct.

### Failure mode 4: no node can take the pod

```bash
kubectl get pods -l app=web
# web-q8n1z   0/1   Pending   0/1

kubectl describe pod web-q8n1z | sed -n '/Events:/,$p'
# Warning  FailedScheduling  default-scheduler
#   0/3 nodes are available: 1 node(s) had untolerated taint
#   {node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu.
```

The ReplicaSet's job is done: the pod object exists and `status.replicas` is correct. `readyReplicas` is what is short. Fix the scheduling constraint, do not touch the ReplicaSet.

### Failure mode 5: node drain

```bash
kubectl drain worker2 --ignore-daemonsets --delete-emptydir-data
```

`drain` uses the **Eviction API**, so PodDisruptionBudgets are honoured. Each successful eviction deletes a pod, the ReplicaSet notices the shortfall, and replacements land on other nodes. If a PDB would be violated, the eviction is rejected with `429 Too Many Requests` and `drain` retries.

---

## ReplicaSet vs ReplicationController

`ReplicationController` (`v1`, kind `ReplicationController`, short name `rc`) is the original Kubernetes controller. It still exists in the core API for compatibility.

| Aspect | ReplicationController (`v1`) | ReplicaSet (`apps/v1`) |
|--------|------------------------------|------------------------|
| API group | core (`v1`) | `apps/v1` |
| Selector field | `spec.selector` as a flat `map[string]string` | `spec.selector` as a `LabelSelector` object |
| Selector expressiveness | Equality only | `matchLabels` plus `matchExpressions` (`In`, `NotIn`, `Exists`, `DoesNotExist`) |
| Selector required | No; defaults to `spec.template.metadata.labels` | **Yes**, always explicit |
| Selector mutable | Yes | **No** |
| Used by Deployment | No | **Yes** |
| Update mechanism | The removed `kubectl rolling-update` client side command | Managed by the Deployment controller |
| Status conditions | `ReplicaFailure` | `ReplicaFailure` |
| Recommended today | No | Only via Deployment |

```yaml
# ReplicationController: note the flat selector and the core apiVersion
apiVersion: v1
kind: ReplicationController
metadata:
  name: web-legacy
spec:
  replicas: 3
  selector:              # flat map, equality only, may be omitted
    app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
```

```bash
kubectl api-resources | grep -E 'replicationcontroller|replicaset'
# replicationcontrollers   rc   v1        true   ReplicationController
# replicasets              rs   apps/v1   true   ReplicaSet
```

The practical takeaway: set based selectors and mandatory, immutable selectors are the reasons ReplicaSet replaced ReplicationController. `kubectl rolling-update` was a client side loop that died with your terminal session; the Deployment controller does the same work server side and survives.

---

## Troubleshooting

### DESIRED 3, CURRENT 0, and no pods exist at all

```bash
kubectl get rs web
kubectl describe rs web | sed -n '/Conditions:/,$p'
kubectl get events --field-selector reason=FailedCreate -n default
```

| `ReplicaFailure` message | Cause | Fix |
|--------------------------|-------|-----|
| `exceeded quota: compute-quota` | ResourceQuota | Raise the quota, or lower `resources.requests` in the template |
| `is forbidden: User "system:serviceaccount:kube-system:replicaset-controller" cannot create` | Broken `system:controller:replicaset-controller` RBAC | Restore the ClusterRole and binding |
| `violates PodSecurity "restricted"` | Pod Security admission on the namespace | Fix the template `securityContext`, or change the namespace enforce label |
| `failed calling webhook ... connection refused` | A mutating or validating webhook backend is down | `kubectl get mutatingwebhookconfigurations` and fix or remove the webhook |
| `must specify a container image` | Malformed template | Validate with `kubectl apply --dry-run=server -f` |

### CURRENT 3 but READY 0

```bash
kubectl get pods -l app=web
kubectl describe pod <pod> | sed -n '/Events:/,$p'
kubectl logs <pod>
kubectl logs <pod> --previous
```

| Pod STATUS | Meaning | Next step |
|-----------|---------|-----------|
| `Pending` | Not scheduled | `kubectl describe pod` for the `FailedScheduling` reason |
| `ContainerCreating` | Image pull, volume mount, or CNI | `kubectl describe pod`, then the kubelet journal on the node |
| `ImagePullBackOff` / `ErrImagePull` | Bad tag, private registry, no `imagePullSecrets` | Fix the image reference or add the pull secret |
| `CrashLoopBackOff` | The process exits | `kubectl logs --previous` |
| `Running` but `0/1` | Readiness probe failing | `kubectl describe pod`, check the probe path, port and `initialDelaySeconds` |

### More pods than spec.replicas

```bash
kubectl get pods -l app=web --show-labels
kubectl get pods -l app=web -o custom-columns=\
NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,\
KIND:.metadata.ownerReferences[0].kind
```

Almost always one of:
1. **Two ReplicaSets with overlapping selectors.** Both count the same pods, both fight. `kubectl get rs -o wide` and compare the `SELECTOR` column.
2. **A bare pod carrying matching labels** was adopted, or a second controller is creating pods that match.
3. **The ReplicaSet is owned by a Deployment mid rollout**, and you are looking at pods from two revisions. Check the `pod-template-hash` label.

```bash
# Find every controller whose selector could match a given pod's labels
kubectl get rs -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SELECTOR:.spec.selector.matchLabels
```

### The ReplicaSet keeps recreating a pod I want gone

You are deleting the wrong object. Find the top of the chain:

```bash
kubectl get pod <pod> -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
kubectl get rs <rs> -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

Then delete the Deployment, or scale it to zero.

### Selector edit is rejected

```
The ReplicaSet "web" is invalid: spec.selector: Invalid value: ... field is immutable
```

Recreate it. Decide first whether the existing pods should survive:

```bash
kubectl delete rs web --cascade=orphan   # keep pods, adopt them with the new RS
kubectl delete rs web                    # take the downtime
kubectl apply -f replicaset-v2.yaml
```

### Old ReplicaSets accumulating

If they are owned by a Deployment, this is `revisionHistoryLimit` doing its job (default 10 kept). Lower it:

```bash
kubectl patch deployment web --type=merge -p '{"spec":{"revisionHistoryLimit":3}}'
kubectl get rs -l app=web
```

Zero replica ReplicaSets consume no compute. They only consume etcd space and list latency.

### fullyLabeledReplicas is lower than replicas

An adopted pod is running something other than your template.

```bash
kubectl get pods -l app=web -o custom-columns=\
NAME:.metadata.name,IMAGE:.spec.containers[0].image --show-labels
```

Find the odd one out, confirm it was not created from the template, and delete it.

---

## Exam and Interview Traps

1. **There is no `kubectl create replicaset`.** Generate a Deployment manifest with `--dry-run=client -o yaml` and edit the `kind`, or write it by hand.
2. **`spec.selector` is required in `apps/v1` and immutable.** Both were different in the removed `extensions/v1beta1`. Old blog posts will mislead you.
3. **The template labels must satisfy the selector**, otherwise the API server rejects the object with `selector does not match template labels`.
4. **Editing `spec.template` on a ReplicaSet does not restart anything.** No rollout logic exists. Only future pods use the new template. This is the single most tested ReplicaSet fact.
5. **A ReplicaSet adopts any matching, unowned pod in its namespace**, including pods created by `kubectl run` that happen to share labels. The adopted pod's actual image is irrelevant to the count.
6. **Relabelling a pod out of the selector orphans it and triggers a replacement.** The orphan keeps running forever and nothing manages it.
7. **Ownership is by UID, not name.** Recreating an object with the same name does not restore the old ownership.
8. **`replicas` counts existing pods, `readyReplicas` counts passing probes, `availableReplicas` adds `minReadySeconds`.** A crash looping pod keeps `replicas` at 3 while `readyReplicas` is 0.
9. **A crash looping pod is never replaced by the ReplicaSet.** The kubelet restarts the container in place. Only pod *deletion* triggers a new pod.
10. **`fullyLabeledReplicas < replicas` is the fingerprint of an adopted foreign pod.**
11. **`ReplicaFailure` with zero pods means admission is rejecting the create.** Look at ResourceQuota, RBAC, Pod Security and webhooks, never at the scheduler.
12. **Node failure takes roughly 5 to 6 minutes to produce replacements** with defaults: about 40s for `Ready=Unknown`, then 300s of toleration.
13. **Pods on an unreachable node stay `Terminating` forever** until the node returns, the Node object is deleted, or the `node.kubernetes.io/out-of-service` taint is applied.
14. **`--default-not-ready-toleration-seconds` is a kube-apiserver flag**, not a controller manager flag, because the DefaultTolerationSeconds admission plugin injects the tolerations.
15. **`controller.kubernetes.io/pod-deletion-cost` is a string annotation, lower is deleted first**, and it only affects ReplicaSet scale down.
16. **Scaling a Deployment owned ReplicaSet directly is reverted** on the next deployment controller sync.
17. **ReplicationController uses a flat, optional, mutable selector; ReplicaSet uses a `LabelSelector` that is required and immutable.** That plus set based operators is the whole difference worth memorising.
18. **`kubectl delete rs --cascade=orphan` leaves the pods running** and strips their ownerReferences. A new ReplicaSet with a matching selector will adopt them.
19. **The `pod-template-hash` label is added by the Deployment controller, not the ReplicaSet controller.** A hand written ReplicaSet has no such label.
20. **Slow start batching (1, 2, 4, 8, ...) means a large scale up appears in waves.** That is not a stall.

---

## Related Topics

- [Controllers](controllers.md)
- [Deployments](deployments.md)
- [Deployment Strategies](deployment-strategies.md)
- [Pods](pods.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-scheduler](kube-scheduler.md)
- [kubelet](kubelet.md)
- [Worker Node](worker-node.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [Imperative Kubernetes](imperative-kubernetes.md)
- [Kubernetes Architecture](k8s-architecture.md)

---

## Key Takeaways

1. A ReplicaSet does exactly one thing: keep the number of active pods matching `spec.selector` equal to `spec.replicas`. It has no concept of versions, rollouts or rollbacks.
2. In production you almost never write a ReplicaSet. A Deployment creates one per pod template revision and shifts replicas between them.
3. `spec.selector` is required and immutable in `apps/v1`, and `spec.template.metadata.labels` must satisfy it or the API server rejects the object.
4. Immutability of the selector exists to keep ownership stable; a mutable selector would silently orphan pods while the status kept reporting them.
5. Editing `spec.template` on a ReplicaSet changes nothing about running pods. Only newly created pods use the new template.
6. The reconcile is a single subtraction, `len(activePods) - spec.replicas`, recomputed from scratch every sync, with slow start batching and expectations to avoid create storms.
7. A pod is "active" if it has no `deletionTimestamp` and is not `Succeeded` or `Failed`, which is why a replacement appears the instant you delete a pod rather than after the grace period.
8. The controller adopts any matching pod that has no controller owner, and orphans any owned pod that stops matching. Ownership is compared by UID.
9. Relabelling a pod out of the selector is the standard quarantine technique: the pod survives unmanaged and a replacement is created immediately.
10. Scale down ordering prefers to delete unscheduled, Pending, not Ready, low deletion cost, densely packed, newest, most restarted pods first.
11. `controller.kubernetes.io/pod-deletion-cost` is a signed integer string annotation where lower values are deleted first, applying only to ReplicaSet scale down.
12. `/scale` is a separate subresource, which is what lets `kubectl scale`, `--current-replicas` optimistic concurrency, and HPA work, and lets RBAC grant scaling without full edit rights.
13. `replicas`, `fullyLabeledReplicas`, `readyReplicas` and `availableReplicas` each answer a different question; `fullyLabeledReplicas` below `replicas` reveals an adopted foreign pod.
14. `ReplicaFailure` means the API server is rejecting pod creation, so no pods exist at all. Check quota, RBAC, Pod Security and admission webhooks.
15. Node failure recovery is roughly 40 seconds to mark the node unreachable plus 300 seconds of default toleration, so about 5 to 6 minutes before replacements appear.
16. Pods on an unreachable node remain `Terminating` until the node returns, the Node object is deleted, or the `node.kubernetes.io/out-of-service` taint forces cleanup.
17. ReplicationController is the legacy equivalent with an optional, mutable, equality only selector; ReplicaSet added set based selectors and mandatory immutable selectors.

---

## References

- [ReplicaSet Concept](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/)
- [ReplicationController Concept](https://kubernetes.io/docs/concepts/workloads/controllers/replicationcontroller/)
- [Labels and Selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/)
- [Owners and Dependents](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)
- [Garbage Collection](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
- [Pod Deletion Cost](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/#pod-deletion-cost)
- [Taints and Tolerations: Taint Based Evictions](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/#taint-based-evictions)
- [Node Status, Heartbeats and Condition Monitoring](https://kubernetes.io/docs/concepts/architecture/nodes/)
- [Non Graceful Node Shutdown](https://kubernetes.io/docs/concepts/architecture/nodes/#non-graceful-node-shutdown)
- [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [Pod Lifecycle: Termination of Pods](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
- [kubectl scale Reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#scale)
- [ReplicaSet API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/replica-set-v1/)
