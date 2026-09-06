# 🎢 Deployment Strategies: Rollouts, Rollbacks and Scaling

A deep guide to how Kubernetes actually moves traffic from one version to the next: maxSurge and maxUnavailable arithmetic worked through concrete numbers, the Recreate strategy, blue green and canary patterns built from plain Deployments and Services, probe interaction, PodDisruptionBudgets, and every rollout control you have.

## 📋 Table of Contents
- [Strategy Overview](#strategy-overview)
- [Update Strategies](#update-strategies)
- [Rolling Updates](#rolling-updates)
- [Controlling Rollout Rate](#controlling-rollout-rate)
- [The Recreate Strategy](#the-recreate-strategy)
- [Readiness Probes](#readiness-probes)
- [Rollbacks](#rollbacks)
- [Restarting Deployments](#restarting-deployments)
- [Scaling](#scaling)
- [Blue Green Deployments](#blue-green-deployments)
- [Canary Deployments](#canary-deployments)
- [PodDisruptionBudget Interaction](#poddisruptionbudget-interaction)
- [Graceful Termination During a Rollout](#graceful-termination-during-a-rollout)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Strategy Overview

Kubernetes ships exactly **two** built in Deployment strategies. Blue green and canary are not API values; they are patterns you assemble from Deployments, Services and labels.

```
┌─────────────────────────────────────────────────────────────────────┐
│  BUILT IN (spec.strategy.type)                                      │
│    RollingUpdate   default. Incremental replacement. Zero downtime  │
│                    if configured correctly. Two versions run at     │
│                    the same time.                                   │
│    Recreate        kill everything, then start everything. Downtime │
│                    is guaranteed. Only one version ever runs.       │
│                                                                     │
│  PATTERNS (you build these)                                         │
│    Blue Green      two full Deployments, one Service, flip the      │
│                    Service selector to cut over instantly           │
│    Canary          two Deployments sharing one Service selector,    │
│                    traffic split by replica ratio                   │
│    A/B, weighted   requires an ingress controller or service mesh   │
│                    that can split by header or weight               │
└─────────────────────────────────────────────────────────────────────┘
```

| Strategy | Downtime | Both versions live | Extra capacity needed | Rollback speed | Good for |
|----------|----------|--------------------|-----------------------|----------------|----------|
| RollingUpdate | none (if tuned) | yes | up to `maxSurge` | one rollout | stateless HTTP services |
| Recreate | yes | no | none | one rollout | singleton apps, incompatible schema changes, `ReadWriteOnce` volumes |
| Blue Green | none | yes, but only one gets traffic | 100 percent | instant, flip the selector back | high risk releases, hard cutovers |
| Canary | none | yes, both get traffic | small | scale the canary to 0 | progressive delivery with real traffic validation |

---

## Update Strategies

```yaml
spec:
  strategy:
    type: RollingUpdate          # RollingUpdate (default) or Recreate
    rollingUpdate:
      maxSurge: 25%              # default 25%
      maxUnavailable: 25%        # default 25%
```

```yaml
spec:
  strategy:
    type: Recreate               # the rollingUpdate block is not allowed here
```

### The two knobs

| Field | Type | Default | Rounding | Meaning |
|-------|------|---------|----------|---------|
| `maxSurge` | integer or percentage string | `25%` | **rounded UP** | How many pods above `spec.replicas` may exist during the rollout |
| `maxUnavailable` | integer or percentage string | `25%` | **rounded DOWN** | How many pods below `spec.replicas` may be unavailable during the rollout |

The rounding directions are deliberate and asymmetric: surge rounds up so you always get at least one extra pod, unavailable rounds down so you never accidentally take out more capacity than intended.

```
Percentages are resolved against spec.replicas, not against the
current pod count.

  replicas: 10, maxSurge: 25%       ──► ceil(2.5)  = 3
  replicas: 10, maxUnavailable: 25% ──► floor(2.5) = 2

  replicas: 3,  maxSurge: 25%       ──► ceil(0.75) = 1
  replicas: 3,  maxUnavailable: 25% ──► floor(0.75)= 0

  replicas: 1,  maxSurge: 25%       ──► ceil(0.25) = 1
  replicas: 1,  maxUnavailable: 25% ──► floor(0.25)= 0
```

That last case is worth noting: with a single replica and the defaults, Kubernetes surges to 2 pods and never drops below 1, so even a single replica Deployment rolls without downtime by default.

### The invariants the controller enforces every sync

```
  total pods across ALL ReplicaSets   <=  spec.replicas + maxSurge
  available pods across ALL ReplicaSets >=  spec.replicas - maxUnavailable
```

Both must hold at all times. Every scaling decision the controller makes is the largest step that keeps both true.

### Both zero is illegal

```bash
kubectl patch deployment web --type=merge -p \
  '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":0}}}}'
# The Deployment "web" is invalid:
# spec.strategy.rollingUpdate.maxUnavailable: Invalid value: intstr.IntOrString{...}:
# may not be 0 when `maxSurge` is 0
```

With both at zero there is no room to add a new pod and no room to remove an old one, so the rollout could never make a single step.

### Common presets

| Goal | `maxSurge` | `maxUnavailable` | Behaviour |
|------|-----------|------------------|-----------|
| Never lose capacity (default choice for prod) | `1` or `25%` | `0` | Add first, then remove. Needs spare cluster capacity. |
| Never exceed capacity (fixed licence count, tight quota) | `0` | `1` | Remove first, then add. Capacity dips. |
| Fastest possible | `100%` | `100%` | Effectively a big bang with overlap. Very spiky. |
| Slowest and safest | `1` | `0` | One pod at a time, capacity never dips. |
| Kubernetes default | `25%` | `25%` | Balanced |

```bash
kubectl patch deployment web --type=merge -p \
  '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'

kubectl get deploy web -o jsonpath='{.spec.strategy}{"\n"}' | jq
```

> `maxUnavailable: 0` is the right default for anything serving user traffic, but it requires the cluster to have room for `maxSurge` extra pods. If the cluster is full, the new pod stays `Pending` and the rollout blocks forever, which is much better than serving errors.

---

## Rolling Updates

### What actually happens, in order

```
kubectl set image deployment/web nginx=nginx:1.27
        │
        ▼
 1. API server writes spec.template, increments metadata.generation
        │
        ▼
 2. deployment controller wakes up, hashes the new template
        ▼
 3. no owned ReplicaSet has that hash ──► CREATE ReplicaSet
    web-<newhash> with spec.replicas: 0, revision = max+1,
    pod-template-hash injected into its selector and template labels
        ▼
 4. LOOP, once per reconcile, until done:
      a. how much surge budget is left?
           allowed = spec.replicas + maxSurge - (total pods now)
           if allowed > 0: scale the NEW ReplicaSet up by allowed
      b. how much unavailability budget is left?
           allowed = (available pods now) - (spec.replicas - maxUnavailable)
           if allowed > 0: scale the OLD ReplicaSet down by allowed
      c. write status, return. Wait for the next pod event.
        ▼
 5. new ReplicaSet at spec.replicas, all old ReplicaSets at 0
    Progressing condition ──► True, reason NewReplicaSetAvailable
        ▼
 6. prune old ReplicaSets beyond revisionHistoryLimit
```

Notice step 4c: the controller **returns** after each budget step. It is level triggered. Progress resumes when a pod becomes Available, which re-enqueues the Deployment key.

### Worked example: replicas 4, maxSurge 1, maxUnavailable 1

```
Budget: total <= 5,  available >= 3

step  old   new   total  avail  action
────  ───   ───   ─────  ─────  ────────────────────────────────────────
  0    4     0      4      4    start. surge room = 5-4 = 1 ──► new +1
  1    4     1      5      4    total at cap. avail 4 >= 3, room = 1
                                ──► old -1
  2    3     1      4      3    new pod not Available yet. avail 3 == min.
                                surge room = 5-4 = 1 ──► new +1
  3    3     2      5      3    waiting on readiness of new pods
  ...  first new pod becomes Available (Ready + minReadySeconds)
  4    3     2      5      4    avail 4 > 3, room = 1 ──► old -1
  5    2     2      4      4    surge room = 1 ──► new +1
  6    2     3      5      4    second new pod Available ──► old -1
  7    1     3      4      4    surge room = 1 ──► new +1
  8    1     4      5      4    third new pod Available ──► old -1
  9    0     4      4      4    DONE. old RS at 0, kept as a revision.

Worst case capacity during the rollout: 3 of 4 available (75 percent).
Peak pod count: 5.
```

### Worked example: replicas 4, maxSurge 1, maxUnavailable 0

```
Budget: total <= 5,  available >= 4     (never lose a single pod)

step  old   new   total  avail  action
────  ───   ───   ─────  ─────  ────────────────────────────────────────
  0    4     0      4      4    surge room = 1 ──► new +1
  1    4     1      5      4    total at cap. avail 4, min is 4,
                                room to scale down = 0. MUST WAIT.
  ...  new pod becomes Available
  2    4     1      5      5    avail 5 > 4, room = 1 ──► old -1
  3    3     1      4      4    surge room = 1 ──► new +1
  4    3     2      5      4    wait for Available
  5    3     2      5      5    ──► old -1
  6    2     2      4      4    ──► new +1
  ...  repeat
  N    0     4      4      4    DONE

Capacity NEVER drops below 4. Exactly one pod is replaced at a time.
Slowest of the safe configurations, and the correct production default.
```

### Worked example: replicas 4, maxSurge 0, maxUnavailable 1

```
Budget: total <= 4,  available >= 3     (never exceed capacity)

step  old   new   total  avail  action
────  ───   ───   ─────  ─────  ────────────────────────────────────────
  0    4     0      4      4    surge room = 0. Must scale DOWN first.
                                avail 4, min 3, room = 1 ──► old -1
  1    3     0      3      3    surge room = 4-3 = 1 ──► new +1
  2    3     1      4      3    wait for the new pod
  3    3     1      4      4    room = 1 ──► old -1
  4    2     1      3      3    ──► new +1
  ...  repeat
  N    0     4      4      4    DONE

Capacity dips to 3 of 4 for the whole rollout.
Total pod count never exceeds 4. Use when quota or licences are fixed.
```

### Worked example: replicas 10 with the defaults

```
maxSurge: 25% ──► ceil(2.5)  = 3
maxUnavailable: 25% ──► floor(2.5) = 2
Budget: total <= 13, available >= 8

step  old   new   total  avail  action
────  ───   ───   ─────  ─────  ─────────────────────────────────────────
  0   10     0     10     10    surge room = 3 ──► new +3
  1   10     3     13     10    total at cap. avail room = 10-8 = 2
                                ──► old -2
  2    8     3     11      8    surge room = 2 ──► new +2
  3    8     5     13      8    at cap, avail at min. WAIT for readiness.
  ...  3 new pods become Available
  4    8     5     13     11    avail room = 3 ──► old -3
  5    5     5     10      8    surge room = 3 ──► new +3
  ...  converges in a handful of waves
  N    0    10     10     10    DONE

Rollouts move in WAVES, not one pod at a time, whenever
maxSurge or maxUnavailable resolve to more than 1.
```

### Watching it live

```bash
# Terminal 1
kubectl get rs -l app=web -w

# Terminal 2
kubectl get pods -l app=web -w -L pod-template-hash

# Terminal 3
kubectl set image deployment/web nginx=nginx:1.27
kubectl rollout status deployment/web

# Afterwards, the controller's own narration
kubectl describe deployment web | sed -n '/Events:/,$p'
# Normal  ScalingReplicaSet  deployment-controller  Scaled up   replica set web-6b8d94c7f to 1
# Normal  ScalingReplicaSet  deployment-controller  Scaled down replica set web-59c4d7f8b to 3
# Normal  ScalingReplicaSet  deployment-controller  Scaled up   replica set web-6b8d94c7f to 2
```

Each `ScalingReplicaSet` line is one budget step of one reconcile pass. Reading them in order reconstructs the exact arithmetic above.

```bash
# Live snapshot of the counters
watch -n1 "kubectl get deploy web -o jsonpath='desired={.spec.replicas} total={.status.replicas} updated={.status.updatedReplicas} ready={.status.readyReplicas} avail={.status.availableReplicas}'"
```

---

## Controlling Rollout Rate

You have five levers. Use them together.

```
┌───────────────────────────────────────────────────────────────────────┐
│ LEVER                       EFFECT ON RATE                            │
├───────────────────────────────────────────────────────────────────────┤
│ maxSurge                    how many new pods start per wave          │
│ maxUnavailable              how many old pods die per wave            │
│ minReadySeconds             a mandatory pause after each pod is Ready │
│ readinessProbe timing       when a pod is allowed to count at all     │
│ rollout pause / resume      a manual, indefinite stop                 │
└───────────────────────────────────────────────────────────────────────┘
```

### 1 and 2: the surge and unavailable budgets

```bash
# One pod at a time, capacity never dips: the safest configuration
kubectl patch deployment web --type=merge -p \
  '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'

# Aggressive: replace half the fleet per wave
kubectl patch deployment web --type=merge -p \
  '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":"50%","maxUnavailable":"50%"}}}}'
```

### 3: minReadySeconds

```yaml
spec:
  minReadySeconds: 30
```

A pod that is Ready is not yet Available. The rollout only advances on Available pods, so `minReadySeconds` inserts a hard 30 second pause into every wave. It is your best defence against a build that starts cleanly and then dies ten seconds later.

```
replicas 4, maxSurge 1, maxUnavailable 0, minReadySeconds 30

Minimum wall clock:
  4 waves x (pod startup + readiness pass + 30s) + scheduling overhead
  With a 5 second startup: 4 x 35s = about 140 seconds.
```

```bash
kubectl patch deployment web --type=merge -p '{"spec":{"minReadySeconds":30}}'
```

### 4: readiness probe timing

The probe decides *when* a pod is Ready, so it is directly on the rollout critical path.

```yaml
readinessProbe:
  httpGet:
    path: /readyz
    port: http
  initialDelaySeconds: 5     # dead time before the first check
  periodSeconds: 5           # gap between checks
  timeoutSeconds: 2          # a check taking longer than this is a failure
  successThreshold: 1        # consecutive successes to become Ready
  failureThreshold: 3        # consecutive failures to become NotReady
```

```
Fastest possible time to Ready
  = initialDelaySeconds + (successThreshold x periodSeconds)
  = 5 + (1 x 5) = 10 seconds

Time to be declared NOT Ready after the app breaks
  = failureThreshold x periodSeconds
  = 3 x 5 = 15 seconds
```

A generous `initialDelaySeconds` adds that dead time to **every single pod** in the rollout. Prefer a `startupProbe` with a high `failureThreshold` and a small `periodSeconds`, so slow starters get the time they need without penalising fast ones.

### 5: pause and resume

```bash
kubectl rollout pause deployment/web
# make several template edits, none of them start a rollout
kubectl set image deployment/web nginx=nginx:1.27
kubectl set resources deployment/web -c=nginx --requests=cpu=200m
kubectl rollout resume deployment/web     # ONE rollout for all edits
```

### Manual canary using pause

```bash
kubectl set image deployment/web nginx=nginx:1.27
kubectl rollout pause deployment/web        # freeze partway through

kubectl get pods -L pod-template-hash
# a mix of old and new hashes, both serving traffic

# observe error rate and latency for the new hash, then either:
kubectl rollout resume deployment/web       # continue
# or
kubectl rollout resume deployment/web && kubectl rollout undo deployment/web
```

Remember: you **cannot** `undo` while paused. Resume first.

### Rollout duration estimate

```
waves           = ceil(replicas / max(maxSurge, maxUnavailable))
time per wave   = pod start + time to Ready + minReadySeconds
total (roughly) = waves x time per wave

replicas 20, maxSurge 25% (=5), maxUnavailable 25% (=5),
pod ready in 10s, minReadySeconds 15:
  waves = ceil(20 / 5) = 4
  per wave = 10 + 15 = 25s
  total = about 100 seconds
```

---

## The Recreate Strategy

```yaml
spec:
  strategy:
    type: Recreate       # no rollingUpdate block allowed
```

```
 t=0   spec.template changes
       │
 t=0   scale EVERY old ReplicaSet to 0
       │
 t=0   kubelet sends SIGTERM to every pod
       │
 t=0.. terminationGracePeriodSeconds elapses, SIGKILL if needed
       │
 t=g   *** ZERO PODS RUNNING. FULL OUTAGE. ***
       │   The controller waits for every old pod to be fully gone.
       │
 t=g   scale the new ReplicaSet to spec.replicas
       │
 t=g.. pods schedule, pull images, start, pass readiness
       │
 t=g+s service restored
```

The outage is `terminationGracePeriodSeconds` plus full cold start time. For a 30 second grace period and a 20 second startup, that is roughly a minute of hard downtime.

### When Recreate is the correct choice

| Situation | Why rolling update fails |
|-----------|--------------------------|
| `ReadWriteOnce` PVC shared by all replicas | The new pod cannot mount the volume while the old pod holds it, so the rollout deadlocks |
| Backwards incompatible schema migration | Old and new code cannot both talk to the same database safely |
| Singleton with an exclusive lock or licence | Two instances corrupt state or fail licence checks |
| A leader election that cannot tolerate two candidates | Split brain |
| Dev and test environments | Simpler, and downtime does not matter |

```bash
kubectl patch deployment web --type=merge -p '{"spec":{"strategy":{"type":"Recreate"}}}'

# Verify the rollingUpdate block was cleared
kubectl get deploy web -o jsonpath='{.spec.strategy}{"\n"}'
# {"type":"Recreate"}
```

```bash
# Switching back requires supplying the rollingUpdate block again
kubectl patch deployment web --type=merge -p \
  '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
```

> The RWO PVC deadlock is worth internalising. With RollingUpdate the new pod is created first, gets stuck in `ContainerCreating` with a `FailedAttachVolume` or `Multi-Attach error`, the old pod is never scaled down because `maxUnavailable` will not allow it, and the rollout hangs until `progressDeadlineSeconds`. Recreate is the fix, not a longer timeout.

---

## Readiness Probes

Readiness is the mechanism that makes a rolling update safe. Without it, Kubernetes cannot distinguish "the container process started" from "the application can serve requests".

### The three probes, and what each one does

| Probe | On failure | Affects Service endpoints | Affects rollout progress | Runs when |
|-------|-----------|---------------------------|--------------------------|-----------|
| `startupProbe` | Kills the container (per `failureThreshold`) | indirectly, it holds Ready off | yes, it delays everything | Until it first succeeds, then never again |
| `readinessProbe` | Removes the pod from Endpoints | **yes, directly** | **yes, directly** | Continuously, after the startup probe passes |
| `livenessProbe` | Restarts the container in place | indirectly, via Ready | indirectly | Continuously, after the startup probe passes |

```
┌────────────────────────────────────────────────────────────────────┐
│                     Pod startup sequence                           │
│                                                                    │
│  container starts                                                  │
│       │                                                            │
│       ├─ startupProbe runs. liveness and readiness are SUSPENDED.  │
│       │  A slow starting app cannot be killed by liveness here.    │
│       │                                                            │
│       ├─ startupProbe succeeds (once)                              │
│       │                                                            │
│       ├─ readinessProbe and livenessProbe both begin               │
│       │                                                            │
│       ├─ readinessProbe passes ──► pod condition Ready=True        │
│       │       ├─► endpointslice controller adds the pod IP         │
│       │       │   to the EndpointSlice ──► kube-proxy programs it  │
│       │       │   ──► TRAFFIC ARRIVES NOW                          │
│       │       └─► minReadySeconds countdown begins                 │
│       │                                                            │
│       └─ minReadySeconds elapses ──► pod counts as AVAILABLE       │
│               └─► the rolling update is allowed to take the        │
│                   next step                                        │
└────────────────────────────────────────────────────────────────────┘
```

### Why a missing readiness probe breaks rolling updates

```
WITHOUT a readinessProbe
  A pod is considered Ready as soon as its containers are running.
  A container "running" means the process was exec'd, nothing more.
  ──► the controller immediately counts it as available
  ──► it immediately scales down an old pod
  ──► the Service sends traffic to a process that has not finished
      loading config, warming caches, or opening its listen socket
  ──► connection refused, 502s, and a rollout that reports success

WITH a correct readinessProbe
  ──► the pod is Ready only when it can actually serve
  ──► only then does the old pod go away
  ──► zero dropped requests
```

### Probe types

```yaml
# HTTP: 200 to 399 is success. Anything else, including a timeout, fails.
readinessProbe:
  httpGet:
    path: /readyz
    port: 8080
    scheme: HTTP           # or HTTPS; certificate verification is skipped
    httpHeaders:
    - name: X-Probe
      value: readiness
```

```yaml
# TCP: success means the connection was established. Weak but useful
# for non HTTP servers.
readinessProbe:
  tcpSocket:
    port: 5432
```

```yaml
# Exec: exit code 0 is success. The most expensive: it spawns a process
# in the container on every period.
readinessProbe:
  exec:
    command: ["/bin/sh", "-c", "pg_isready -U postgres"]
```

```yaml
# gRPC: uses the standard grpc.health.v1 Health service.
readinessProbe:
  grpc:
    port: 9090
    service: myservice     # optional; empty means overall server health
```

### A probe set that behaves correctly during a rollout

```yaml
spec:
  minReadySeconds: 15
  template:
    spec:
      containers:
      - name: api
        image: myapp:2.0
        ports:
        - name: http
          containerPort: 8080

        # Slow start tolerance: up to 30 x 2s = 60 seconds to come up.
        # Liveness and readiness do not run until this passes.
        startupProbe:
          httpGet: { path: /healthz, port: http }
          periodSeconds: 2
          failureThreshold: 30

        # Cheap, dependency free, answers "can I serve right now".
        # Fast failureThreshold so a bad pod leaves rotation quickly.
        readinessProbe:
          httpGet: { path: /readyz, port: http }
          periodSeconds: 5
          timeoutSeconds: 2
          successThreshold: 1
          failureThreshold: 2

        # Answers "am I deadlocked". Deliberately more forgiving
        # than readiness so a transient blip does not cause a restart.
        livenessProbe:
          httpGet: { path: /healthz, port: http }
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
```

### Probe design rules

| Rule | Reason |
|------|--------|
| `/healthz` (liveness) must not check dependencies | A database outage would restart every pod in the fleet at once and turn a partial outage into a total one |
| `/readyz` (readiness) may check critical dependencies | A pod that cannot reach its database should leave rotation, not be killed |
| Liveness must be more forgiving than readiness | Otherwise a slow moment becomes a restart storm |
| Never use the same aggressive settings for both | Restarting is far more destructive than de-registering |
| Use `startupProbe` instead of a large `initialDelaySeconds` | `initialDelaySeconds` is dead time added to every pod in every rollout |
| Probes must be cheap | They run on every pod, every period, forever |
| `timeoutSeconds` must be well under `periodSeconds` | Otherwise checks overlap and the results are meaningless |

```bash
# Inspect probe configuration and current condition
kubectl get pod <pod> -o jsonpath='{.spec.containers[0].readinessProbe}' | jq
kubectl get pod <pod> -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq

# Probe failures appear as Events on the pod
kubectl describe pod <pod> | grep -A5 -i "Unhealthy"
# Warning  Unhealthy  kubelet  Readiness probe failed: HTTP probe failed
#                              with statuscode: 503

# Test the endpoint the way the kubelet does
kubectl exec <pod> -- wget -qO- --timeout=2 http://localhost:8080/readyz
kubectl port-forward pod/<pod> 8080:8080 &
curl -i http://localhost:8080/readyz

# Which pods are actually in the Service
kubectl get endpointslices -l kubernetes.io/service-name=web-svc -o yaml
```

### Readiness gates

For conditions the kubelet cannot know about, such as an external load balancer finishing its own health check, a pod can require extra conditions before it is Ready:

```yaml
spec:
  template:
    spec:
      readinessGates:
      - conditionType: "example.com/lb-registered"
```

An external controller then patches `status.conditions` with that type. The pod is Ready only when the container readiness probes pass **and** every readiness gate condition is `True`. This is how cloud load balancer controllers avoid declaring a pod ready before the LB has actually registered it.

---

## Rollbacks

### The commands

```bash
kubectl rollout history deployment/web
# REVISION  CHANGE-CAUSE
# 1         Initial deployment, nginx 1.25
# 2         Bump to 1.26 for HTTP/3
# 3         Upgrade to 1.27

kubectl rollout history deployment/web --revision=2   # full template of rev 2

kubectl rollout undo deployment/web                   # back one revision
kubectl rollout undo deployment/web --to-revision=1   # to a specific revision
kubectl rollout undo deployment/web --to-revision=0   # explicit "previous"

kubectl rollout status deployment/web
```

### What actually happens internally

This is the part most people get wrong in interviews.

```
kubectl rollout undo deployment/web --to-revision=1

  1. kubectl lists the ReplicaSets owned by the Deployment and finds
     the one annotated deployment.kubernetes.io/revision: "1".

  2. kubectl copies that ReplicaSet's spec.template back into the
     Deployment's spec.template, with pod-template-hash stripped out,
     and PATCHes the Deployment. That is the entire client side.

  3. From the deployment controller's point of view this is an
     ORDINARY TEMPLATE CHANGE. It hashes the new template.

  4. The hash matches an EXISTING owned ReplicaSet, the one that
     served revision 1. So the controller does NOT create anything.
     It marks that ReplicaSet as the new ReplicaSet, bumps its
     revision annotation to max(existing)+1, and records the old
     number in deployment.kubernetes.io/revision-history.

  5. A normal rolling update runs, from the current ReplicaSet down
     to zero and the revived ReplicaSet up to spec.replicas, honouring
     maxSurge, maxUnavailable, readiness and minReadySeconds.
```

```
BEFORE undo                        AFTER `undo --to-revision=1`
  RS web-7d9f8b6c5  rev 1  desired 0    RS web-7d9f8b6c5  rev 4  desired 3
  RS web-59c4d7f8b  rev 2  desired 0    RS web-59c4d7f8b  rev 2  desired 0
  RS web-6b8d94c7f  rev 3  desired 3    RS web-6b8d94c7f  rev 3  desired 0

The SAME ReplicaSet object serves revision 1 and revision 4.
The revision counter never decreases.
```

Key consequences:

1. **A rollback is a rollout.** It obeys the same strategy, budgets, probes and `minReadySeconds`. It is not instant and it is not special cased.
2. **Pods are recreated, not resurrected.** New pod objects with new names, new IPs and new UIDs. Old pod IPs never come back.
3. **Rolling back is not free of risk.** If revision 1 also has a bug that revision 3 was fixing, you have just reintroduced it.
4. **Only the pod template is rolled back.** `spec.replicas`, `spec.strategy`, `spec.minReadySeconds` and `spec.revisionHistoryLimit` are **not** part of the template and are **not** reverted.

### What rollback does not restore

```
NOT part of spec.template, therefore NOT rolled back:
  spec.replicas                current scale is preserved
  spec.strategy                current strategy is preserved
  spec.minReadySeconds
  spec.progressDeadlineSeconds
  spec.revisionHistoryLimit

NOT owned by the Deployment at all, therefore NOT rolled back:
  ConfigMaps and Secrets referenced by the template
  PersistentVolume contents and database schema
  the container image tag CONTENTS if the tag was overwritten
    in the registry (this is why mutable tags like :latest are unsafe;
    a rollback to "revision 1 = myapp:latest" pulls TODAY's :latest)
  CRDs, RBAC, Services, Ingress
```

That third one is the trap that ruins real rollbacks. **Pin image digests or immutable tags** if you want rollback to mean anything:

```yaml
image: myapp@sha256:5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f
```

### There is no automatic rollback

`progressDeadlineSeconds` sets `Progressing=False` with reason `ProgressDeadlineExceeded`. It does nothing else. Automation is your job:

```bash
#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f web.yaml

if ! kubectl rollout status deployment/web --timeout=10m; then
  echo "rollout failed, rolling back"
  kubectl rollout undo deployment/web
  kubectl rollout status deployment/web --timeout=5m
  exit 1
fi
echo "rollout succeeded"
```

### Rollback failure modes

```bash
kubectl rollout undo deployment/web
# error: no rollout history found for deployment "web"
```

| Message | Cause | Fix |
|---------|-------|-----|
| `no rollout history found` | `revisionHistoryLimit: 0`, old ReplicaSets deleted, or this is revision 1 | Apply the previous manifest from git |
| `unable to find specified revision N` | That revision was pruned by `revisionHistoryLimit` | `kubectl rollout history` to see what survives |
| `you cannot rollback a paused deployment` | `spec.paused: true` | `kubectl rollout resume deployment/web` first |
| Rollback runs but the pods still fail | Revision 1 depends on a ConfigMap or Secret that has since changed | Roll back the configuration too |

```bash
# Check what is still available to roll back to
kubectl get rs -l app=web -o custom-columns=\
NAME:.metadata.name,\
REV:.metadata.annotations.deployment\\.kubernetes\\.io/revision,\
DESIRED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image
```

---

## Restarting Deployments

Sometimes nothing about the spec should change, but every pod must be replaced: a rotated Secret, a changed ConfigMap consumed at startup, a stuck connection pool, a leaked file descriptor.

```bash
kubectl rollout restart deployment/web
kubectl rollout status deployment/web
```

### How it works

```bash
kubectl get deploy web -o jsonpath='{.spec.template.metadata.annotations}' | jq
# {
#   "kubectl.kubernetes.io/restartedAt": "2025-01-14T09:12:03Z"
# }
```

`kubectl` patches an annotation **inside `spec.template.metadata.annotations`**. Because the annotation is part of the pod template, the template hash changes, a new ReplicaSet is created, and a **completely normal rolling update** runs under the current strategy, budgets and probes.

```
kubectl rollout restart
        │
        ▼
patch spec.template.metadata.annotations
      kubectl.kubernetes.io/restartedAt = <now, RFC3339>
        │
        ▼
new template hash ──► new ReplicaSet ──► standard rolling update
        │
        ▼
every pod replaced, zero downtime, new revision in rollout history
```

### What it is not

| Not this | Reason |
|----------|--------|
| `kubectl delete pod` in a loop | That kills pods with no surge budget and no ordering. Restart is a governed rollout. |
| A container restart | The whole pod is replaced: new name, new IP, new UID, new node possibly. |
| Free of a revision | It produces a new revision, and you can `rollout undo` it. |
| Instant | It takes exactly as long as any other rolling update of the same size. |

### Restarting other workload kinds

```bash
kubectl rollout restart deployment/web
kubectl rollout restart daemonset/fluent-bit -n logging
kubectl rollout restart statefulset/postgres      # honours ordered pod management
```

### The better pattern: make config changes trigger their own rollout

Instead of remembering to restart after every ConfigMap edit, hash the config into the pod template annotation so the rollout happens automatically:

```yaml
spec:
  template:
    metadata:
      annotations:
        checksum/config: "8f14e45fceea167a5a36dedd4bea2543"   # sha of the ConfigMap
```

Any templating tool can compute this. When the ConfigMap content changes the checksum changes, the template hash changes, and a rolling update happens on its own.

```bash
# Compute it in a pipeline
CFG_SUM=$(kubectl get cm web-config -o jsonpath='{.data}' | sha256sum | cut -c1-32)
kubectl patch deployment web --type=merge -p \
  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$CFG_SUM\"}}}}}"
```

> ConfigMaps and Secrets mounted as **volumes** are updated in place by the kubelet after a short propagation delay, so a restart is not strictly required if your app re-reads the file. Values injected through `env` or `envFrom` are baked in at container start and **never** update without a restart.

---

## Scaling

### Manual scaling

```bash
kubectl scale deployment web --replicas=10

# Optimistic concurrency: only act if the current count is exactly 4.
# Prevents you from stomping on an autoscaler or another operator.
kubectl scale deployment web --current-replicas=4 --replicas=10

# Guard on a specific object version
kubectl scale deployment web --replicas=6 --resource-version=1234567

# By label selector, across many Deployments at once
kubectl scale deployment --replicas=0 -l tier=batch

# Park the workload without deleting it
kubectl scale deployment web --replicas=0
```

Scaling is **not** a rollout:

```bash
kubectl scale deployment web --replicas=10
kubectl get deploy web -o jsonpath='{.metadata.generation}{"\n"}'   # incremented
kubectl rollout history deployment/web                              # unchanged
kubectl get rs -l app=web                                           # no new RS
```

The Deployment controller just writes a new `spec.replicas` on the **active** ReplicaSet. The ReplicaSet controller creates or deletes the difference.

### Scaling during a rollout

If you scale while a rollout is in flight, the controller proportionally redistributes the new count across the old and new ReplicaSets so the surge and unavailability budgets stay respected, then continues the rollout to completion.

```
Mid rollout: old RS at 3, new RS at 2, spec.replicas 5.
You run: kubectl scale deployment web --replicas=10

The controller scales BOTH ReplicaSets roughly in proportion,
recomputes maxSurge and maxUnavailable against the new 10,
and continues shifting replicas toward the new ReplicaSet.
```

This is why the `deployment.kubernetes.io/desired-replicas` and `deployment.kubernetes.io/max-replicas` annotations exist on each ReplicaSet: they record the Deployment's replica count and surge ceiling at the time the ReplicaSet was last scaled, so the proportional math is reproducible.

### The scale subresource

```bash
kubectl get --raw /apis/apps/v1/namespaces/default/deployments/web/scale | jq
```

```json
{
  "kind": "Scale",
  "apiVersion": "autoscaling/v1",
  "spec":   { "replicas": 4 },
  "status": { "replicas": 4, "selector": "app=web" }
}
```

RBAC can grant scaling without granting general edit rights:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scaler
  namespace: production
rules:
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  verbs: ["get", "update", "patch"]
```

### HorizontalPodAutoscaler

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70      # percent of the CPU REQUEST, not the limit
  - type: Resource
    resource:
      name: memory
      target:
        type: AverageValue
        averageValue: 500Mi
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "100"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      - type: Pods
        value: 4
        periodSeconds: 15
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
      selectPolicy: Min
```

```bash
kubectl autoscale deployment web --min=3 --max=20 --cpu-percent=70
kubectl get hpa
kubectl describe hpa web
kubectl get hpa web -o jsonpath='{.status}' | jq
```

The core formula:

```
desiredReplicas = ceil( currentReplicas x ( currentMetricValue / desiredMetricValue ) )

Example: 4 replicas at 90 percent CPU, target 70 percent
  ceil( 4 x (90 / 70) ) = ceil(5.14) = 6 replicas

A tolerance band (0.1 by default) suppresses changes when the ratio is
within 10 percent of 1.0, which prevents constant one pod oscillation.
```

| Aspect | Behaviour |
|--------|-----------|
| Evaluation interval | Controlled by `--horizontal-pod-autoscaler-sync-period` on the controller manager, default `15s` |
| CPU utilisation basis | Percentage of the container **request**, not the limit. **A pod with no CPU request cannot be autoscaled on CPU utilisation.** |
| Metrics source | `metrics.k8s.io` served by metrics-server for Resource metrics; `custom.metrics.k8s.io` and `external.metrics.k8s.io` via an adapter |
| Scale down damping | `behavior.scaleDown.stabilizationWindowSeconds`, default `300`, uses the highest recommendation in the window |
| Scale up damping | `behavior.scaleUp.stabilizationWindowSeconds`, default `0`, so scale up is immediate |
| Not ready pods | Excluded from the metric average so a starting pod's low usage does not suppress scale up |
| Interaction with rollouts | The HPA writes `/scale` on the Deployment; the Deployment controller distributes across ReplicaSets. They coexist. |

### Never set replicas in a manifest that an HPA manages

```
THE FIGHT

  HPA writes:  spec.replicas = 12   (load is high)
       ▼
  CI runs `kubectl apply -f web.yaml` where the file says replicas: 3
       ▼
  apply sets spec.replicas = 3
       ▼
  12 pods are terminated during peak traffic
       ▼
  HPA notices utilisation spike on 3 pods, scales back to 12
       ▼
  pods start again, cold caches, latency spike, possible cascade
       ▼
  next CI run repeats the whole cycle
```

Three correct fixes, best first:

```yaml
# 1. OMIT spec.replicas from the manifest entirely.
#    Client side apply leaves fields it has never owned alone,
#    so the HPA's value is preserved on every apply.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  # no replicas field at all
  selector:
    matchLabels:
      app: web
  template:
    ...
```

```bash
# 2. Server side apply with explicit field ownership.
#    The HPA owns spec.replicas; your manager never claims it.
kubectl apply --server-side --field-manager=ci -f web.yaml
# If your file DOES contain replicas, SSA returns a conflict error
# instead of silently overwriting. That error is the feature.
```

```yaml
# 3. If you must keep the field for readability, at least make the
#    HPA's minReplicas equal to it so the blast radius is bounded.
#    This is a mitigation, not a fix.
```

> If `spec.replicas` is already in the manifest and in `last-applied-configuration`, simply deleting it from the file and running `apply` **does** remove it, because the three way merge deletes fields that were previously applied and are now absent. After that, subsequent applies leave the HPA alone.

```bash
# Detect the problem before it bites you
kubectl get hpa -A -o custom-columns=\
NS:.metadata.namespace,HPA:.metadata.name,\
TARGET:.spec.scaleTargetRef.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,\
CURRENT:.status.currentReplicas,DESIRED:.status.desiredReplicas

# Does the manifest for an HPA managed Deployment pin replicas?
grep -n "replicas:" web.yaml
```

### Scaling to zero

```bash
kubectl scale deployment web --replicas=0
kubectl get deploy web
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    0/0     0            0           3h
```

The Deployment, its ReplicaSets, its Service, its ConfigMaps and its PVCs all survive. Only the pods are gone. `minReplicas: 0` on an HPA requires a feature gate and is not enabled by default in a standard cluster, so plain HPAs cannot scale to zero.

### Vertical scaling

Changing `resources.requests` or `resources.limits` is a **pod template change**, so it triggers a full rolling update. In place resizing of pod resources without a restart exists as a newer, gated capability; on a standard cluster assume a resource change means a rollout.

```bash
kubectl set resources deployment/web -c=nginx \
  --requests=cpu=500m,memory=512Mi --limits=memory=1Gi
kubectl rollout status deployment/web
```

---

## Blue Green Deployments

Two complete Deployments exist simultaneously. One Service points at exactly one of them. The cutover is a single label change and is effectively instant.

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                  │
│                     Service/web-svc                              │
│                selector: app=web, slot=blue                      │
│                            │                                     │
│              ┌─────────────┘                                     │
│              ▼                              (no traffic)         │
│   ┌────────────────────────┐      ┌────────────────────────┐    │
│   │ Deployment web-blue    │      │ Deployment web-green   │    │
│   │ labels: app=web        │      │ labels: app=web        │    │
│   │         slot=blue      │      │         slot=green     │    │
│   │ image: myapp:1.0       │      │ image: myapp:2.0       │    │
│   │ replicas: 4  ◄ LIVE    │      │ replicas: 4  ◄ WARM    │    │
│   └────────────────────────┘      └────────────────────────┘    │
│                                                                  │
│   CUTOVER: patch the Service selector slot: blue ──► green       │
│   ROLLBACK: patch it back. Under a second, no pod churn.         │
└──────────────────────────────────────────────────────────────────┘
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-blue
spec:
  replicas: 4
  selector:
    matchLabels:
      app: web
      slot: blue
  template:
    metadata:
      labels:
        app: web
        slot: blue
    spec:
      containers:
      - name: app
        image: myapp:1.0
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet: { path: /readyz, port: 8080 }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-green
spec:
  replicas: 4
  selector:
    matchLabels:
      app: web
      slot: green
  template:
    metadata:
      labels:
        app: web
        slot: green
    spec:
      containers:
      - name: app
        image: myapp:2.0
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet: { path: /readyz, port: 8080 }
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web
    slot: blue          # THE SWITCH
  ports:
  - port: 80
    targetPort: 8080
---
# A second Service that always points at green, for smoke testing
# the inactive slot before you cut over.
apiVersion: v1
kind: Service
metadata:
  name: web-preview
spec:
  selector:
    app: web
    slot: green
  ports:
  - port: 80
    targetPort: 8080
```

```bash
# 1. Deploy green alongside blue and wait for it to be healthy
kubectl apply -f web-green.yaml
kubectl rollout status deployment/web-green

# 2. Smoke test through the preview Service, with no production traffic
kubectl run smoke --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' http://web-preview/readyz

# 3. Cut over
kubectl patch service web-svc -p '{"spec":{"selector":{"app":"web","slot":"green"}}}'
kubectl get endpointslices -l kubernetes.io/service-name=web-svc

# 4. Roll back instantly if anything is wrong
kubectl patch service web-svc -p '{"spec":{"selector":{"app":"web","slot":"blue"}}}'

# 5. Once confident, reclaim the capacity
kubectl scale deployment web-blue --replicas=0
# or: kubectl delete deployment web-blue
```

| Trade off | Detail |
|-----------|--------|
| Cost | 200 percent of production capacity during the overlap |
| Rollback | Effectively instant, and no pods need to start |
| Blast radius | 100 percent of traffic moves at once. There is no partial exposure. |
| In flight connections | Existing keep alive connections to blue pods are **not** severed by the selector change. Long lived connections drain only when the client reconnects or you scale blue down. |
| Databases | Both versions must tolerate the same schema during the overlap |

---

## Canary Deployments

Two Deployments share the label the Service selects on. Traffic splits in proportion to the **replica counts**, because kube-proxy load balances roughly evenly across all endpoints.

```
┌──────────────────────────────────────────────────────────────────┐
│                     Service/web-svc                              │
│                     selector: app=web                            │
│                            │                                     │
│              ┌─────────────┴─────────────┐                       │
│              ▼                           ▼                       │
│   ┌────────────────────────┐  ┌────────────────────────┐        │
│   │ Deployment web-stable  │  │ Deployment web-canary  │        │
│   │ labels:                │  │ labels:                │        │
│   │   app=web              │  │   app=web              │        │
│   │   track=stable         │  │   track=canary         │        │
│   │ image: myapp:1.0       │  │ image: myapp:2.0       │        │
│   │ replicas: 9            │  │ replicas: 1            │        │
│   └────────────────────────┘  └────────────────────────┘        │
│                                                                  │
│   Traffic split = 9 : 1 = 90 percent stable, 10 percent canary   │
│   Both carry app=web, so BOTH are in the Service endpoints.      │
└──────────────────────────────────────────────────────────────────┘
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-stable
spec:
  replicas: 9
  selector:
    matchLabels:
      app: web
      track: stable
  template:
    metadata:
      labels:
        app: web          # selected by the Service
        track: stable     # NOT in the Service selector
    spec:
      containers:
      - name: app
        image: myapp:1.0
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
      track: canary
  template:
    metadata:
      labels:
        app: web
        track: canary
    spec:
      containers:
      - name: app
        image: myapp:2.0
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web             # deliberately matches BOTH tracks
  ports:
  - port: 80
    targetPort: 8080
```

```bash
# Confirm both tracks are in the endpoints
kubectl get endpointslices -l kubernetes.io/service-name=web-svc \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.targetRef.name}{"\n"}{end}'

# Progressive shift: 10% ──► 30% ──► 60% ──► 100%
kubectl scale deployment web-canary --replicas=3 && kubectl scale deployment web-stable --replicas=7
kubectl scale deployment web-canary --replicas=6 && kubectl scale deployment web-stable --replicas=4
kubectl scale deployment web-canary --replicas=10 && kubectl scale deployment web-stable --replicas=0

# Abort at any point
kubectl scale deployment web-canary --replicas=0
```

### Observing the two tracks separately

```bash
kubectl logs -l app=web,track=canary --tail=100 --prefix
kubectl top pods -l track=canary
kubectl get pods -l app=web -L track
```

Because `track` is a real label on the pods, your metrics pipeline can group by it and compare error rate and latency between the two versions on identical real traffic.

### Limits of replica ratio canaries

| Limitation | Consequence |
|-----------|-------------|
| Granularity is `1/total replicas` | With 4 total replicas the smallest slice is 25 percent |
| No header or cookie based routing | You cannot send only internal users to the canary |
| No session stickiness | The same user hits stable and canary on different requests |
| Manual promotion | Someone must run the scale commands and watch the dashboards |
| Both versions share the Service | Any client that caches a connection stays pinned to whichever pod it reached |

For finer control you need an ingress controller with canary annotations, or a service mesh with weighted routing, or a progressive delivery controller. Those are all built on top of exactly this pattern.

### Canary versus a paused rolling update

| | Replica ratio canary | Paused RollingUpdate |
|---|---|---|
| Objects | Two Deployments | One Deployment |
| Traffic split control | Precise, via replica counts | Whatever the rollout happened to reach |
| Can you label and observe the new version separately | Yes, `track=canary` | Only via `pod-template-hash`, which changes every release |
| Rollback | Scale canary to 0 | `resume` then `undo` |
| Complexity | Two manifests to keep in sync | One |

---

## PodDisruptionBudget Interaction

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: production
spec:
  minAvailable: 3            # OR maxUnavailable, never both
  selector:
    matchLabels:
      app: web
  unhealthyPodEvictionPolicy: IfHealthyBudget   # or AlwaysAllow
```

```bash
kubectl get pdb
# NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# web-pdb   3               N/A               1                     5m

kubectl get pdb web-pdb -o jsonpath='{.status}' | jq
# {
#   "currentHealthy": 4,
#   "desiredHealthy": 3,
#   "disruptionsAllowed": 1,
#   "expectedPods": 4,
#   "observedGeneration": 1
# }
```

### The rule everyone gets wrong

```
┌────────────────────────────────────────────────────────────────────┐
│  A PodDisruptionBudget is enforced ONLY by the Eviction API.       │
│                                                                    │
│  HONOURS a PDB (goes through POST .../pods/<name>/eviction):       │
│    kubectl drain                                                   │
│    the descheduler                                                 │
│    cluster autoscaler node scale down                              │
│    node upgrade tooling that drains                                │
│    the API initiated eviction endpoint in general                  │
│                                                                    │
│  IGNORES a PDB (issues a plain DELETE on the pod):                 │
│    a Deployment RollingUpdate                                      │
│    kubectl delete pod                                              │
│    the ReplicaSet controller scaling down                          │
│    kubelet eviction under node memory or disk pressure             │
│    taint based eviction after a node goes NotReady                 │
│    a node that simply loses power                                  │
└────────────────────────────────────────────────────────────────────┘
```

**A PDB does not protect you during a rolling update.** `maxUnavailable` on the Deployment strategy is what protects you there. They are separate mechanisms that happen to use a confusingly similar word.

```
Rolling update availability floor  ──► spec.strategy.rollingUpdate.maxUnavailable
Voluntary disruption floor         ──► PodDisruptionBudget
Involuntary disruption             ──► nothing protects you; design for it
```

### Making the two consistent

```yaml
# Deployment: never drop below 3 of 4 during a rollout
spec:
  replicas: 4
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
---
# PDB: never drop below 3 of 4 during a drain
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app: web
```

### The deadlock

```bash
kubectl drain worker2 --ignore-daemonsets
# evicting pod production/web-x4k2p
# error when evicting pod "web-x4k2p" (will retry after 5s):
#   Cannot evict pod as it would violate the pod's disruption budget.
```

```bash
kubectl get pdb web-pdb
# NAME      MIN AVAILABLE   ALLOWED DISRUPTIONS
# web-pdb   3               0
```

`ALLOWED DISRUPTIONS: 0` means the drain will retry forever. Causes and fixes:

| Cause | Fix |
|-------|-----|
| `minAvailable` equals `spec.replicas` | Lower `minAvailable`, or raise `replicas`. A PDB with `minAvailable == replicas` blocks every drain permanently. |
| `minAvailable: 100%` | Same problem stated as a percentage |
| Pods are unhealthy, so `currentHealthy < desiredHealthy` | Fix the pods, or set `unhealthyPodEvictionPolicy: AlwaysAllow` so unhealthy pods can always be evicted |
| Replicas are all on the node being drained | Add topology spread constraints or anti affinity so they land on different nodes |
| The PDB selector matches nothing | `kubectl get pdb -o wide` and check `expectedPods` is not 0 |

```bash
# Emergency escape hatch, understand the consequence first
kubectl drain worker2 --ignore-daemonsets --disable-eviction
# This issues plain DELETEs and BYPASSES all PDBs. Use only when you
# have accepted the availability hit.
```

### unhealthyPodEvictionPolicy

| Value | Behaviour |
|-------|-----------|
| `IfHealthyBudget` (default) | Running but unhealthy pods can be evicted only while `currentHealthy >= desiredHealthy`. Safe, but a fleet that is already unhealthy cannot be drained. |
| `AlwaysAllow` | Running but unhealthy pods are always evictable. Prevents the "broken app blocks the node upgrade" deadlock. |

This field is available in recent Kubernetes releases; check `kubectl explain pdb.spec.unhealthyPodEvictionPolicy` on your cluster.

---

## Graceful Termination During a Rollout

Every rolling update deletes pods, so the shutdown path is part of the strategy.

```
Pod is selected for deletion
        │
        ├──────────────────────┬──────────────────────────────┐
        │ ASYNCHRONOUS AND     │                              │
        │ CONCURRENT           ▼                              ▼
        │            endpointslice controller        kubelet begins
        │            removes the pod IP              termination
        │                    │                              │
        │                    ▼                              ├─ preStop hook runs
        │            kube-proxy on EVERY node               │  (blocking, counts
        │            reprogrames iptables/IPVS              │   against the grace
        │            (takes time: hundreds of ms            │   period)
        │             to seconds on a large cluster)        │
        │                                                   ├─ SIGTERM to PID 1
        │                                                   │
        │                                                   ├─ wait up to
        │                                                   │  terminationGrace-
        │                                                   │  PeriodSeconds
        │                                                   │
        │                                                   └─ SIGKILL if still
        │                                                      alive
        ▼
   THE RACE: the pod may still receive new connections for a short
   window AFTER SIGTERM, because endpoint propagation is not atomic.
```

### The fix

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 45
      containers:
      - name: app
        lifecycle:
          preStop:
            exec:
              # Sleep long enough for endpoint removal to propagate to
              # every kube-proxy, THEN let SIGTERM start the real drain.
              command: ["/bin/sh", "-c", "sleep 10"]
```

```
t=0    pod marked for deletion, endpoint removal begins
t=0    preStop starts: sleep 10.  The container is STILL SERVING.
t=0-5  kube-proxy rules updated everywhere. New connections stop arriving.
t=10   preStop returns. SIGTERM delivered.
t=10.. the app finishes in flight requests and exits cleanly
t<=45  if it has not exited, SIGKILL
```

| Requirement | Detail |
|-------------|--------|
| `terminationGracePeriodSeconds` must exceed preStop plus real drain time | Otherwise SIGKILL truncates the drain |
| The app must handle SIGTERM | A process that ignores SIGTERM always eats the full grace period, making every rollout slow |
| PID 1 must forward signals | A shell form `CMD` in a Dockerfile makes `/bin/sh` PID 1 and it does not forward SIGTERM. Use exec form or a tiny init. |
| `preStop` counts against the grace period | It is not additional time |
| Long grace periods slow rollouts | With `maxUnavailable: 0` the controller waits for terminations before the next wave |

```bash
kubectl get deploy web -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'

# Watch a rollout and time the terminations
kubectl get pods -l app=web -w

# Emergency only: skip the grace period entirely
kubectl delete pod web-x4k2p --grace-period=0 --force
```

---

## Troubleshooting

### Rollout stuck, new pods never become Ready

```bash
kubectl rollout status deployment/web --timeout=60s
kubectl get pods -l app=web -o wide
kubectl describe pod <newest-pod> | sed -n '/Events:/,$p'
kubectl logs <newest-pod> --previous
kubectl get deploy web -o jsonpath='{.status.conditions}' | jq
```

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ImagePullBackOff` | Bad tag, private registry, missing pull secret | Fix the reference, add `imagePullSecrets` |
| `CrashLoopBackOff` | The app exits at start | `kubectl logs --previous`; check config and secrets |
| `Pending`, `FailedScheduling` | No node fits with the surge budget | Free capacity, or use `maxSurge: 0` and `maxUnavailable: 1` |
| `Running` but `0/1` for a long time | Readiness probe failing | Check path, port, scheme; exec the probe manually |
| `ContainerCreating` with `Multi-Attach error` | RWO PVC held by the old pod | Switch to `strategy.type: Recreate` |
| `ProgressDeadlineExceeded` | Any of the above, for `progressDeadlineSeconds` | Diagnose the pod, then `kubectl rollout undo` |

### Rollout stuck with no new pods at all

```bash
kubectl get deploy web -o jsonpath='paused={.spec.paused} strategy={.spec.strategy}{"\n"}'
kubectl get rs -l app=web
kubectl describe deployment web | sed -n '/Events:/,$p'
```

| Cause | Fix |
|-------|-----|
| `spec.paused: true` | `kubectl rollout resume deployment/web` |
| `ReplicaFailure` on the new ReplicaSet | Quota, RBAC, Pod Security or a failing webhook. `kubectl describe rs <new-rs>` |
| `maxSurge: 0` and every existing pod is unavailable | There is no unavailability budget to scale down. Raise `maxSurge` to 1. |
| Cluster has no room for the surge pod | Free capacity, or set `maxSurge: 0` with `maxUnavailable: 1` |

### Requests fail during an otherwise successful rollout

```bash
kubectl get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}{"\n"}'
kubectl get deploy web -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'
kubectl get deploy web -o jsonpath='{.spec.strategy.rollingUpdate}{"\n"}'
```

Checklist, in the order these actually cause outages:

1. **No readiness probe.** Pods enter rotation before they can serve. Add one.
2. **No `preStop` sleep.** Pods leave rotation after they stop serving. Add `sleep 5` to `10`.
3. **`maxUnavailable` too high.** Capacity dips below what the traffic needs. Set `0`.
4. **App ignores SIGTERM.** In flight requests are killed at the grace period. Fix signal handling.
5. **`minReadySeconds: 0`** with an app that is Ready before its caches are warm. Raise it.

### Rollback did not fix the problem

```bash
kubectl rollout history deployment/web
kubectl get rs -l app=web -o custom-columns=\
NAME:.metadata.name,REV:.metadata.annotations.deployment\\.kubernetes\\.io/revision,\
IMAGE:.spec.template.spec.containers[0].image
```

Rollback reverts only `spec.template`. If the real change was a ConfigMap, a Secret, a database migration, or an overwritten mutable image tag, the rollback restored nothing that mattered. Pin image digests and version your configuration alongside your Deployment.

### HPA and apply are fighting

```bash
kubectl get hpa web -o jsonpath='{.status.desiredReplicas}{"\n"}'
kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
kubectl describe hpa web | sed -n '/Events:/,$p'
grep -n "replicas:" web.yaml
```

Remove `replicas` from the manifest and re-apply, or switch that pipeline to `kubectl apply --server-side`.

### HPA reports unknown metrics

```bash
kubectl describe hpa web
# Warning  FailedGetResourceMetric  missing request for cpu

kubectl top pods                 # does metrics-server work at all?
kubectl get apiservices | grep metrics
# v1beta1.metrics.k8s.io   kube-system/metrics-server   True
```

| Cause | Fix |
|-------|-----|
| metrics-server not installed or unhealthy | Install it; check its logs and its APIService status |
| Containers have no `resources.requests.cpu` | Utilisation is a percentage of the request. No request means no percentage. Add one. |
| Custom metric adapter missing | Install the adapter for `custom.metrics.k8s.io` |

### Drain blocked by a PDB

```bash
kubectl get pdb -A
kubectl get pdb web-pdb -o jsonpath='{.status}' | jq
kubectl get pods -l app=web -o wide
```

See the [PodDisruptionBudget Interaction](#poddisruptionbudget-interaction) table above for the fix matrix.

### Both old and new pods serving after the rollout "finished"

```bash
kubectl get pods -l app=web -L pod-template-hash
kubectl get rs -l app=web
```

If old ReplicaSets still show non zero `DESIRED`, the rollout is not actually finished. If they show `0` but pods with old hashes persist, those pods were orphaned, most likely by a `--cascade=orphan` delete or a manual label edit. Delete them explicitly.

---

## Exam and Interview Traps

1. **`maxSurge` rounds up, `maxUnavailable` rounds down.** With `replicas: 3` and the 25 percent defaults that is surge 1 and unavailable 0.
2. **Percentages resolve against `spec.replicas`**, not the current pod count.
3. **`maxSurge: 0` and `maxUnavailable: 0` together is rejected** because no step could ever be taken.
4. **`maxUnavailable: 0` requires spare cluster capacity.** If the surge pod cannot schedule, the rollout blocks indefinitely, which is the correct and safe outcome.
5. **A single replica Deployment with defaults still rolls without downtime**, because surge rounds up to 1 and unavailable rounds down to 0.
6. **Recreate causes guaranteed downtime.** It scales old to zero and *waits for full termination* before scaling up the new ReplicaSet.
7. **An RWO PVC plus RollingUpdate deadlocks.** Recreate is the answer, not a longer `progressDeadlineSeconds`.
8. **Readiness controls Service endpoints AND rollout progress. Liveness restarts the container and does neither directly.** Confusing the two is the most common probe question.
9. **`minReadySeconds` delays Available, not Ready.** Traffic reaches the pod during the window; only the rollout waits.
10. **`startupProbe` suspends liveness and readiness until it first succeeds.** It is the correct fix for slow starters, not a huge `initialDelaySeconds`.
11. **`kubectl rollout undo` creates a new, higher revision.** The counter never decreases, and the same ReplicaSet object can serve two revision numbers.
12. **Rollback reuses the old ReplicaSet rather than building pods from scratch**, because the reverted template hashes to the same value.
13. **Rollback reverts only `spec.template`.** `replicas`, `strategy`, `minReadySeconds` and `revisionHistoryLimit` are untouched.
14. **Rollback does not restore ConfigMaps, Secrets, database schema, or the contents of a mutable image tag.**
15. **There is no automatic rollback.** `progressDeadlineSeconds` only sets a condition.
16. **You cannot `rollout undo` a paused Deployment.** Resume first.
17. **`kubectl rollout restart` works by stamping `kubectl.kubernetes.io/restartedAt` into `spec.template.metadata.annotations`**, which changes the template hash and triggers a normal rolling update.
18. **Scaling is not a revision.** `kubectl scale` bumps `metadata.generation` but adds nothing to `kubectl rollout history` and creates no ReplicaSet.
19. **A PodDisruptionBudget is enforced only by the Eviction API.** It does **not** constrain a rolling update, `kubectl delete pod`, kubelet pressure eviction, or a node losing power.
20. **`minAvailable` equal to `spec.replicas` blocks every drain forever.** `ALLOWED DISRUPTIONS: 0` is the tell.
21. **HPA CPU utilisation is a percentage of the CPU *request*, not the limit.** A container with no CPU request cannot be autoscaled on utilisation.
22. **Never pin `replicas` in a manifest managed by an HPA.** Omit the field, or use server side apply so the HPA owns it.
23. **Blue green needs 200 percent capacity** during the overlap, and the selector flip does not sever existing keep alive connections.
24. **Canary traffic split granularity is `1 / total replicas`.** You cannot get a 5 percent canary out of 4 replicas.
25. **`pod-template-hash` must never appear in a Service selector.** It changes on every rollout and the Service would lose all endpoints.
26. **`preStop` runs *inside* `terminationGracePeriodSeconds`**, it does not extend it.
27. **Endpoint removal and SIGTERM happen concurrently**, which is why a `preStop` sleep is required for genuinely zero error rollouts.
28. **`kubectl drain --disable-eviction` bypasses PDBs entirely** by issuing plain DELETEs.

---

## Related Topics

- [Deployments](deployments.md)
- [ReplicaSets](replicasets.md)
- [Controllers](controllers.md)
- [Pods](pods.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-proxy](kube-proxy.md)
- [kube-scheduler](kube-scheduler.md)
- [kubelet](kubelet.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [Network Policy](network-policy.md)
- [Cgroups](cgroups.md)
- [Microservices](microservices.md)
- [Kubernetes Architecture](k8s-architecture.md)

---

## Key Takeaways

1. Kubernetes ships exactly two Deployment strategies, `RollingUpdate` and `Recreate`. Blue green and canary are patterns you build from Deployments, Services and labels, not API values.
2. `maxSurge` rounds up and `maxUnavailable` rounds down, and both resolve against `spec.replicas`. The controller enforces `total <= replicas + maxSurge` and `available >= replicas - maxUnavailable` on every sync.
3. Setting both `maxSurge` and `maxUnavailable` to zero is rejected, because no rollout step would be possible.
4. `maxSurge: 1` with `maxUnavailable: 0` is the safest production configuration: capacity never dips, one pod is replaced at a time, and a full cluster blocks the rollout instead of degrading service.
5. Rollouts move in waves, not one pod at a time, whenever the budgets resolve to more than one pod.
6. `Recreate` guarantees downtime and is the correct choice for `ReadWriteOnce` volumes, singletons, and incompatible schema changes.
7. Readiness probes control both Service endpoints and rollout progress. Without one, Kubernetes cannot tell a started process from a serving application, and a rolling update will happily replace healthy pods with broken ones.
8. `startupProbe` suspends liveness and readiness until it first succeeds, which is the correct way to accommodate slow starting applications.
9. `minReadySeconds` inserts a mandatory pause between Ready and Available, slowing the rollout without delaying traffic, and it is the main defence against a build that crashes shortly after starting.
10. Rollback is an ordinary rolling update. `kubectl` copies an old ReplicaSet's template back into the Deployment, the hash matches an existing zero scaled ReplicaSet, and that object is revived under a new, higher revision number.
11. Rollback reverts only the pod template. Replica count, strategy, ConfigMaps, Secrets, database schema and mutable image tag contents are not restored.
12. There is no automatic rollback. `progressDeadlineSeconds` only flips a condition so your pipeline can decide.
13. `kubectl rollout restart` stamps a timestamp annotation inside the pod template, changing the hash and triggering a governed rolling update rather than deleting pods.
14. Scaling changes `metadata.generation` but creates no revision and no new ReplicaSet.
15. Never pin `spec.replicas` in a manifest managed by an HPA. Omit the field or use server side apply, otherwise every deploy terminates pods at peak load.
16. HPA CPU utilisation is measured against the CPU **request**, so a container without a request cannot be autoscaled on utilisation.
17. Blue green gives instant rollback at the cost of double capacity; canary gives real traffic validation at replica ratio granularity.
18. PodDisruptionBudgets are enforced only by the Eviction API, so they govern drains and autoscaler scale down, never rolling updates or involuntary disruptions.
19. A PDB whose `minAvailable` equals `spec.replicas` blocks every node drain forever.
20. Endpoint removal and SIGTERM are concurrent, so a `preStop` sleep of a few seconds is required for genuinely error free rollouts, and it consumes part of `terminationGracePeriodSeconds` rather than extending it.

---

## References

- [Deployments: Updating a Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#updating-a-deployment)
- [Deployments: Rolling Back a Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-back-a-deployment)
- [Deployments: Deployment Strategy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy)
- [Deployments: Scaling a Deployment](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#scaling-a-deployment)
- [Deployment API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/deployment-v1/)
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Pod Lifecycle: Container Probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes)
- [Pod Lifecycle: Termination of Pods](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
- [Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HorizontalPodAutoscaler Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
- [Disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [Specifying a Disruption Budget for your Application](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [Canary Deployments](https://kubernetes.io/docs/concepts/workloads/management/#canary-deployments)
- [Service and EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
- [Server Side Apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
