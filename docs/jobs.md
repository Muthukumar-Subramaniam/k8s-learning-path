# ⚙️ Jobs: Run to Completion Workloads

A deep dive into the Job controller: run to completion semantics, the completions and parallelism matrix, indexed jobs, failure handling, back-off timing, and the operational details that decide whether a batch workload is reliable or merely lucky.

## 📋 Table of Contents
- [What Is a Job?](#what-is-a-job)
- [Run to Completion Semantics](#run-to-completion-semantics)
- [Executing Jobs](#executing-jobs)
- [Completions and Parallelism](#completions-and-parallelism)
- [Parallel Jobs](#parallel-jobs)
- [Completion Mode: NonIndexed and Indexed](#completion-mode-nonindexed-and-indexed)
- [Handling Failures](#handling-failures)
- [restartPolicy: Never vs OnFailure](#restartpolicy-never-vs-onfailure)
- [backoffLimit and Exponential Back-off](#backofflimit-and-exponential-back-off)
- [activeDeadlineSeconds](#activedeadlineseconds)
- [Pod Failure Policy](#pod-failure-policy)
- [Suspending Jobs](#suspending-jobs)
- [Cleanup with ttlSecondsAfterFinished](#cleanup-with-ttlsecondsafterfinished)
- [Job Labels, Selectors and Ownership](#job-labels-selectors-and-ownership)
- [Inspecting Jobs](#inspecting-jobs)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What Is a Job?

A **Job** creates one or more Pods and continues to retry execution until a specified number of them **successfully terminate**. Unlike a Deployment, which wants its Pods to run forever, a Job wants its Pods to finish and stay finished.

```
┌───────────────────────────────────────────────────────────────────┐
│              Long Running vs Run to Completion                    │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  DEPLOYMENT                        JOB                            │
│  ──────────                        ───                            │
│  Desired state: N running          Desired state: N SUCCEEDED     │
│  Pod exits ──► restart it          Pod exits 0 ──► count it       │
│  Never "done"                      Pod exits !=0 ──► retry it     │
│  restartPolicy: Always             Reaches N ──► Job Complete     │
│                                    restartPolicy: Never|OnFailure │
│                                                                   │
│  Success = "still running"         Success = "finished cleanly"   │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

Typical workloads: database migrations, batch ETL, report generation, backups, one-off maintenance, image processing pipelines, machine learning training runs, and cluster bootstrap tasks.

The API group is **`batch/v1`**:

```yaml
apiVersion: batch/v1
kind: Job
```

---

## Run to Completion Semantics

The Job controller tracks Pods through their terminal phases.

```
┌───────────────────────────────────────────────────────────────────┐
│                        Pod Phases for a Job                       │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│    Pending ──► Running ──┬──► Succeeded   (all containers exit 0) │
│                          │                                        │
│                          └──► Failed      (a container exit != 0, │
│                                            or evicted, deadline,  │
│                                            node lost)             │
│                                                                   │
│  status.succeeded ++  on Succeeded                                │
│  status.failed    ++  on Failed                                   │
│  status.active        = pods currently Pending or Running         │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Terminal Job Conditions

A Job ends in exactly one of two terminal conditions:

| Condition | Set when |
|-----------|----------|
| `Complete` | `status.succeeded` reaches the required number of completions |
| `Failed` | `backoffLimit` is exceeded, or `activeDeadlineSeconds` elapses, or a pod failure policy rule takes the `FailJob` action |

There is also a non terminal `Suspended` condition, covered in [Suspending Jobs](#suspending-jobs).

```bash
kubectl get job data-migration -o jsonpath='{.status.conditions}' | jq
# [
#   {
#     "type": "Complete",
#     "status": "True",
#     "lastTransitionTime": "2025-09-05T10:14:22Z",
#     "reason": "",
#   }
# ]

# Block a script until the job finishes, one way or the other
kubectl wait --for=condition=complete job/data-migration --timeout=30m
kubectl wait --for=condition=failed   job/data-migration --timeout=30m
```

Once terminal, a Job stops creating Pods. Its finished Pods are **retained** so you can read their logs, which is a deliberate design choice and also a source of accumulated clutter. See [Cleanup with ttlSecondsAfterFinished](#cleanup-with-ttlsecondsafterfinished).

### Mostly Immutable Spec

A Job's spec is largely frozen once created. The fields you can update on a live Job are:

| Mutable | Notes |
|---------|-------|
| `parallelism` | Scale the running width up or down |
| `suspend` | Pause and resume |
| `activeDeadlineSeconds` | Extend or shorten the wall clock budget |
| `ttlSecondsAfterFinished` | Change cleanup timing |

`spec.template`, `spec.completions` and `spec.selector` are effectively immutable. Editing the template requires deleting and recreating the Job.

```bash
# This fails
kubectl set image job/data-migration migrate=migrate:v2
# The Job "data-migration" is invalid: spec.template: Invalid value: ...
# field is immutable

# Correct approach
kubectl delete job data-migration
kubectl apply -f data-migration-v2.yaml
```

---

## Executing Jobs

### Imperative Creation

Unlike DaemonSets, Jobs **do** have a `kubectl create` generator.

```bash
# Simplest possible job
kubectl create job pi --image=perl:5.34 -- \
  perl -Mbignum=bpi -wle 'print bpi(2000)'

# Generate the manifest instead of creating it
kubectl create job pi --image=perl:5.34 --dry-run=client -o yaml -- \
  perl -Mbignum=bpi -wle 'print bpi(2000)' > pi.yaml

# Create a job from an existing CronJob's template (the manual trigger)
kubectl create job manual-backup-001 --from=cronjob/nightly-backup
```

Note the `--` separator: everything after it becomes the container `command`, not kubectl flags.

### Declarative Manifest

A complete, annotated Job:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: data-migration
  namespace: batch
  labels:
    app.kubernetes.io/name: data-migration
spec:
  # How many successful pod completions are required. Default 1.
  completions: 1

  # How many pods may run at once. Default 1.
  parallelism: 1

  # Retries before the Job is marked Failed. Default 6.
  backoffLimit: 4

  # Wall clock budget for the whole Job, counted from startTime.
  activeDeadlineSeconds: 3600

  # Delete the Job (and its pods) this many seconds after it finishes.
  ttlSecondsAfterFinished: 600

  # NonIndexed (default) or Indexed.
  completionMode: NonIndexed

  # Set true to create the Job without starting any pods.
  suspend: false

  template:
    metadata:
      labels:
        app.kubernetes.io/name: data-migration
    spec:
      # MUST be Never or OnFailure. Always is rejected.
      restartPolicy: Never

      serviceAccountName: migrator

      containers:
      - name: migrate
        image: registry.example.com/migrate:1.7.3
        command: ["/app/migrate"]
        args: ["--target=head", "--verbose"]
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: url
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
          limits:
            memory: 1Gi
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
```

```bash
kubectl apply -f data-migration.yaml
kubectl get job -n batch data-migration -w
kubectl logs -n batch job/data-migration -f
```

### Watching a Job Execute

```bash
# Job level view
kubectl get jobs -n batch
# NAME             STATUS     COMPLETIONS   DURATION   AGE
# data-migration   Running    0/1           14s        14s

# Pod level view
kubectl get pods -n batch -l job-name=data-migration -w

# Live status counters
kubectl get job -n batch data-migration -o jsonpath='{.status}' | jq
# {
#   "active": 1,
#   "ready": 1,
#   "startTime": "2025-09-05T10:00:00Z",
#   "uncountedTerminatedPods": {}
# }
```

### Running a One-Off Command Without a Job

For a genuinely interactive one-off, `kubectl run` with `--restart=Never` creates a bare Pod, not a Job, and gives you no retry semantics:

```bash
kubectl run adhoc --rm -it --restart=Never --image=busybox:1.36 -- sh
```

Use a Job whenever you want retries, completion tracking, or a record of the outcome.

---

## Completions and Parallelism

Two fields produce three distinct execution patterns. This matrix is the conceptual core of Jobs.

| Pattern | `completions` | `parallelism` | Completion rule |
|---------|---------------|---------------|-----------------|
| **Single job** | unset or `1` | unset or `1` | One Pod succeeds |
| **Fixed completion count** | `N` | `M` (1 to N) | `N` Pods succeed in total |
| **Work queue** | **unset** | `M` | At least one Pod succeeds **and** all Pods have terminated |

```
┌───────────────────────────────────────────────────────────────────┐
│                   The completions/parallelism Matrix              │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  completions: 1     parallelism: 1                                │
│    [pod] ──► Succeeded ──► Job Complete                           │
│    "Run this once."                                               │
│                                                                   │
│  completions: 6     parallelism: 2                                │
│    [pod][pod]                                                     │
│         [pod][pod]                                                │
│              [pod][pod] ──► 6 successes ──► Job Complete          │
│    "Run this 6 times, 2 at a time."                               │
│                                                                   │
│  completions: unset parallelism: 3                                │
│    [pod][pod][pod]  all pulling from an external queue            │
│    First pod to exit 0 signals "queue is empty".                  │
│    Controller stops creating NEW pods and waits for the rest.     │
│    "Run 3 workers until the work runs out."                       │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Pattern 1: Single Job

The default. Omit both fields entirely.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: schema-upgrade
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: upgrade
        image: registry.example.com/schema-tool:2.1
        args: ["upgrade", "--yes"]
```

### Pattern 2: Fixed Completion Count

Set `completions` to the total amount of work and `parallelism` to the concurrency you can afford.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: render-frames
spec:
  completions: 100      # 100 successful pods required
  parallelism: 10       # at most 10 running concurrently
  backoffLimit: 20
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: render
        image: registry.example.com/renderer:4.2
        args: ["--claim-next-frame"]
```

The controller keeps `active` at `min(parallelism, remaining)`. As it approaches the end it naturally ramps down:

```
completions: 10, parallelism: 4

  succeeded: 0  ──► active 4   (10 remaining, cap 4)
  succeeded: 4  ──► active 4   (6 remaining, cap 4)
  succeeded: 8  ──► active 2   (2 remaining, cap 4 ──► 2)
  succeeded: 10 ──► active 0   Complete
```

In `NonIndexed` mode the Pods are anonymous: nothing tells Pod number 7 that it is number 7. Each Pod must obtain its own work item externally (from a queue, a database claim, or a lock). If you need the Pod to know its index, use `Indexed` mode.

### Pattern 3: Work Queue

Omit `completions` entirely and set `parallelism`. This is the classic consumer pool.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: queue-workers
spec:
  # completions deliberately NOT set
  parallelism: 5
  backoffLimit: 10
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: worker
        image: registry.example.com/queue-worker:1.4
        env:
        - name: QUEUE_URL
          value: amqp://rabbit.messaging.svc.cluster.local:5672/work
```

Completion rule, precisely: the Job is `Complete` once **at least one Pod has terminated successfully and all Pods have terminated**. The semantics are "a worker exiting 0 means the queue is drained".

```
┌───────────────────────────────────────────────────────────────────┐
│                     Work Queue Job Lifecycle                      │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   Queue: [item][item][item][item][item][item]                     │
│              ▲       ▲       ▲                                    │
│              │       │       │                                    │
│          worker-1 worker-2 worker-3     (parallelism: 3)          │
│                                                                   │
│   t1  all 3 pulling and processing                                │
│   t2  queue empties; worker-2 finds nothing, exits 0              │
│   t3  controller stops creating replacements                      │
│   t4  worker-1 and worker-3 finish their last item, exit 0        │
│   t5  all pods terminated, at least one succeeded ──► Complete    │
│                                                                   │
│   CONTRACT the workers must honour:                               │
│     exit 0  ONLY when the queue is genuinely empty                │
│     exit !=0 on a transient error, so the pod is retried          │
│   A worker that exits 0 on an error ends the Job prematurely.     │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

That contract is the whole risk of this pattern. Getting it wrong silently truncates the batch.

---

## Parallel Jobs

### Choosing parallelism

`parallelism` is a **ceiling**, not a guarantee. The actual number of running Pods can be lower because of:

- Node capacity: Pods that do not fit stay `Pending`.
- ResourceQuota in the namespace.
- The remaining work: near the end, `completions - succeeded` caps it.
- `suspend: true`, which drives it to zero.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: batch-quota
  namespace: batch
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    count/jobs.batch: "50"
```

A parallelism of 50 inside a quota that only allows 20 CPUs of requests means the surplus Pods sit `Pending` until capacity frees up. That is usually fine, but it makes `kubectl get pods` look alarming.

### Scaling Parallelism Live

`parallelism` is one of the few mutable fields:

```bash
# Widen a running job
kubectl scale job/render-frames --replicas=20
# (kubectl scale maps --replicas onto spec.parallelism for Jobs)

# Or patch explicitly
kubectl patch job render-frames -p '{"spec":{"parallelism":20}}'

# Throttle down to zero without cancelling the job:
# existing pods are allowed to finish, no new ones are created
kubectl patch job render-frames -p '{"spec":{"parallelism":0}}'
```

Setting `parallelism: 0` is a soft pause that lets in-flight Pods complete. `suspend: true` is a hard pause that deletes them. Choose according to whether your work items are resumable.

### Parallelism and Node Spread

Nothing spreads Job Pods across nodes by default. For heavy parallel Jobs, add topology spread constraints so one node does not absorb the whole batch:

```yaml
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            job-name: render-frames
      restartPolicy: OnFailure
```

`ScheduleAnyway` keeps the spread as a preference. `DoNotSchedule` makes it a hard requirement, which can leave Pods `Pending` if the topology cannot satisfy it.

### Parallel Job Comparison

| Aspect | Fixed completion count | Work queue |
|--------|-----------------------|------------|
| `completions` | Set to N | Not set |
| Work assignment | External, or by index in Indexed mode | Pods pull from a queue |
| Progress visibility | `COMPLETIONS` column shows `x/N` | Shows `x/1 of ?` style progress only |
| Handles uneven item cost | Poorly, one slow index blocks the tail | Well, fast workers take more items |
| Needs external coordinator | Only in NonIndexed mode | Yes, the queue |
| Premature completion risk | Low | High, if a worker exits 0 wrongly |
| Retry granularity | Per completion | Per worker Pod |

---

## Completion Mode: NonIndexed and Indexed

```yaml
spec:
  completionMode: Indexed     # or NonIndexed (default)
  completions: 8
  parallelism: 4
```

### NonIndexed (default)

Pods are fungible. Any `completions` successful Pods satisfy the Job. There is no notion of "which one".

### Indexed

Each Pod is assigned a unique **completion index** from `0` to `completions - 1`. The Job is complete only when there is a successful Pod for **every** index.

`completionMode: Indexed` **requires** `spec.completions` to be set. A work queue Job (no `completions`) cannot be Indexed.

### How a Pod Learns Its Index

The index is exposed in several places:

| Mechanism | Value |
|-----------|-------|
| Pod annotation | `batch.kubernetes.io/job-completion-index` |
| Pod label | `batch.kubernetes.io/job-completion-index` |
| Environment variable | `JOB_COMPLETION_INDEX`, injected automatically |
| Pod name suffix | `<job-name>-<index>-<random>` |
| Pod hostname | `<job-name>-<index>` |

The `JOB_COMPLETION_INDEX` environment variable is set for you; you do not have to wire it up. You can also read it explicitly through the downward API from the annotation, which is useful when you want it under a different name:

```yaml
        env:
        # Automatically present, shown here for clarity:
        # - name: JOB_COMPLETION_INDEX
        # Custom name via the downward API:
        - name: SHARD_ID
          valueFrom:
            fieldRef:
              fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index']
```

### Worked Indexed Job

Eight shards, four at a time, each Pod processing exactly its own shard:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: shard-processor
  namespace: batch
spec:
  completionMode: Indexed
  completions: 8
  parallelism: 4
  backoffLimit: 8
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          set -eu
          echo "Processing shard ${JOB_COMPLETION_INDEX} of 8"
          # Deterministic, repeatable work assignment with no coordinator.
          case "${JOB_COMPLETION_INDEX}" in
            0) RANGE="a-c" ;;
            1) RANGE="d-f" ;;
            2) RANGE="g-i" ;;
            3) RANGE="j-l" ;;
            4) RANGE="m-o" ;;
            5) RANGE="p-r" ;;
            6) RANGE="s-u" ;;
            *) RANGE="v-z" ;;
          esac
          echo "Key range: ${RANGE}"
          sleep 10
          echo "Shard ${JOB_COMPLETION_INDEX} done"
```

```bash
kubectl apply -f shard-processor.yaml

# Pod names carry the index
kubectl get pods -n batch -l job-name=shard-processor
# shard-processor-0-9x2kd   0/1   Completed
# shard-processor-1-p4mzt   0/1   Completed
# shard-processor-2-h7wqr   1/1   Running
# ...

# Read the index off a pod
kubectl get pod -n batch shard-processor-2-h7wqr \
  -o jsonpath='{.metadata.annotations.batch\.kubernetes\.io/job-completion-index}'

# Which indexes have completed?
kubectl get job -n batch shard-processor \
  -o jsonpath='{.status.completedIndexes}'
# 0-1,3,5     <-- compressed range notation
```

`status.completedIndexes` uses compressed interval notation (`0-1,3,5` means indexes 0, 1, 3 and 5). This is genuinely useful for progress reporting on large indexed Jobs.

### Indexed Jobs With a Headless Service

Because the Pod hostname is the deterministic `<job-name>-<index>`, an Indexed Job plus a headless Service gives Pods stable, resolvable names within the run. That enables MPI style workloads where rank 0 must contact rank 1.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: trainers
  namespace: batch
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    job-name: distributed-training
---
apiVersion: batch/v1
kind: Job
metadata:
  name: distributed-training
  namespace: batch
spec:
  completionMode: Indexed
  completions: 4
  parallelism: 4
  template:
    spec:
      subdomain: trainers          # links the pod to the headless Service
      restartPolicy: Never
      containers:
      - name: trainer
        image: registry.example.com/trainer:2.0
        env:
        - name: WORLD_SIZE
          value: "4"
        - name: MASTER_ADDR
          value: distributed-training-0.trainers
        command: ["/app/train", "--rank=$(JOB_COMPLETION_INDEX)"]
```

### Mode Comparison

| Aspect | NonIndexed | Indexed |
|--------|-----------|---------|
| `completions` required | No | **Yes** |
| Pod knows its identity | No | Yes, `JOB_COMPLETION_INDEX` |
| Deterministic work split | Needs an external coordinator | Built in |
| Stable hostname | No | Yes, `<job>-<index>` |
| Retry semantics | Any pod satisfies any completion | A failed index is retried as that index |
| Progress detail | Count only | `status.completedIndexes` |
| Good for | Homogeneous retryable tasks, queue consumers | Sharding, partitioned data, MPI ranks |

---

## Handling Failures

Failure handling in Jobs has several interacting layers. Understanding which layer fires first is what separates a working batch platform from a mysteriously stuck one.

```
┌───────────────────────────────────────────────────────────────────┐
│                 Job Failure Handling Layers                       │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  Layer 1: restartPolicy  (kubelet, INSIDE the pod)                │
│     OnFailure ──► kubelet restarts the CONTAINER in place         │
│     Never     ──► pod goes to Failed, kubelet does nothing more   │
│                                                                   │
│  Layer 2: podFailurePolicy  (Job controller, per failure)         │
│     Classify the failure: FailJob | Ignore | Count | FailIndex    │
│                                                                   │
│  Layer 3: backoffLimit  (Job controller, cumulative)              │
│     Count the failures; exceed the limit ──► Job Failed           │
│     Recreates use exponential back-off                            │
│                                                                   │
│  Layer 4: activeDeadlineSeconds  (Job controller, wall clock)     │
│     Overrides everything; terminates the Job as DeadlineExceeded  │
│                                                                   │
│  Precedence: activeDeadlineSeconds wins over backoffLimit.        │
│              podFailurePolicy decides what even COUNTS as a       │
│              failure for backoffLimit.                            │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### What Counts as a Pod Failure

- A container exits with a non zero status (and `restartPolicy: Never`, or the restart limit is reached with `OnFailure`).
- The Pod is **evicted** by the kubelet under node pressure.
- The Pod is preempted by a higher priority Pod.
- The node is drained, deleted, or becomes unreachable long enough for eviction.
- The Job's `activeDeadlineSeconds` elapses while the Pod is running.
- An admission or runtime error prevents the container from ever starting (for example `CreateContainerConfigError`).

Notably, **infrastructure disruptions count against `backoffLimit` by default**. A batch Job with `backoffLimit: 0` running on preemptible nodes will fail on the first preemption, which has nothing to do with your code. Pod failure policy exists to fix exactly that.

---

## restartPolicy: Never vs OnFailure

A Job Pod template must set `restartPolicy` to `Never` or `OnFailure`. **`Always` is rejected by API validation**, because a Pod that always restarts can never reach a terminal phase, and a Job that can never observe a terminal phase can never complete.

```bash
kubectl apply -f bad-job.yaml
# The Job "bad-job" is invalid: spec.template.spec.restartPolicy:
# Unsupported value: "Always": supported values: "OnFailure", "Never"
```

Note the direction of the trap versus DaemonSets, where `Always` is the *only* permitted value.

### The Practical Difference

```
┌───────────────────────────────────────────────────────────────────┐
│              restartPolicy: Never (new pod per attempt)           │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   attempt 1  job-abc12  exit 1  ──► Pod phase Failed  (kept)      │
│   attempt 2  job-de34f  exit 1  ──► Pod phase Failed  (kept)      │
│   attempt 3  job-gh56k  exit 0  ──► Pod phase Succeeded           │
│                                                                   │
│   kubectl get pods shows THREE pods.                              │
│   Each failed attempt's logs are still readable.                  │
│   status.failed = 2                                               │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

```
┌───────────────────────────────────────────────────────────────────┐
│           restartPolicy: OnFailure (container restarts)           │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   job-abc12  container exit 1 ──► kubelet restarts container      │
│   job-abc12  container exit 1 ──► kubelet restarts container      │
│   job-abc12  container exit 0 ──► Pod phase Succeeded             │
│                                                                   │
│   kubectl get pods shows ONE pod, RESTARTS = 2.                   │
│   Logs of earlier attempts need --previous, and only the          │
│   immediately preceding attempt is retrievable.                   │
│   status.failed may stay 0 even though work failed twice.         │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

```bash
# Never: inspect each attempt independently
kubectl get pods -l job-name=data-migration
kubectl logs data-migration-abc12
kubectl logs data-migration-de34f

# OnFailure: restart count on a single pod
kubectl get pods -l job-name=data-migration
# NAME                   READY   STATUS    RESTARTS   AGE
# data-migration-abc12   1/1     Running   2          3m
kubectl logs data-migration-abc12 --previous
```

### Choosing Between Them

| Consideration | `Never` | `OnFailure` |
|---------------|---------|-------------|
| Debuggability | Excellent, every attempt's logs preserved | Poor, only the previous attempt |
| Rescheduling | Retry may land on a different node | Retry stays on the same node |
| Recovery from node problems | Yes, new Pod can move | No, stuck with the bad node |
| Pod object churn | High, one Pod per attempt | Low, one Pod |
| Retry speed | Slower, full Pod creation and image pull | Faster, container restart only |
| Interaction with `backoffLimit` | Each failed Pod counts | Restarts are counted too, via the pod back-off |
| Recommended for | Most production Jobs | Fast retries where node affinity is irrelevant |

**Default recommendation: `restartPolicy: Never`.** The debuggability and the ability to reschedule away from a sick node are worth the extra Pod objects. Pair it with `ttlSecondsAfterFinished` so the objects do not accumulate.

### Interaction With Container Restart Back-off

With `OnFailure`, the kubelet applies its own exponential back-off between container restarts, which is what surfaces as `CrashLoopBackOff`. That back-off is separate from, and additional to, the Job controller's back-off. A Job with `OnFailure` and a fast failing container can therefore appear to hang for minutes between attempts.

---

## backoffLimit and Exponential Back-off

```yaml
spec:
  backoffLimit: 6     # default
```

`backoffLimit` is the number of retries before the Job is marked `Failed`. The default is **6**.

### The Back-off Timing

The Job controller does not retry immediately. It applies exponential back-off between Pod recreations:

```
retry 1:   10 seconds
retry 2:   20 seconds
retry 3:   40 seconds
retry 4:   80 seconds
retry 5:  160 seconds
retry 6:  320 seconds
retry 7+: capped at 360 seconds (6 minutes)
```

The delay starts at 10 seconds, doubles each time, and is capped at 6 minutes.

```
┌───────────────────────────────────────────────────────────────────┐
│         Cumulative time with backoffLimit: 6 (default)            │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  t=0      attempt 1 fails                                         │
│  +10s     attempt 2 fails      cumulative   10s                   │
│  +20s     attempt 3 fails      cumulative   30s                   │
│  +40s     attempt 4 fails      cumulative   70s                   │
│  +80s     attempt 5 fails      cumulative  150s                   │
│  +160s    attempt 6 fails      cumulative  310s                   │
│  +320s    attempt 7 fails      cumulative  630s  ≈ 10.5 minutes   │
│           backoffLimit exceeded ──► Job condition Failed          │
│                                                                   │
│  Plus the runtime of each attempt. A job whose container takes    │
│  2 minutes to fail takes roughly 25 minutes to give up.           │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

This matters operationally: **a "failing" Job does not report failure quickly**. If you need fast feedback, lower `backoffLimit` or set `activeDeadlineSeconds`.

### Choosing a Value

| Value | Behaviour | Use when |
|-------|-----------|----------|
| `0` | No retries at all; first failure fails the Job | Non idempotent work, fail-fast pipelines |
| `1` to `3` | A couple of quick retries | Transient network or dependency flakiness |
| `6` (default) | Generous retry window over roughly 10 minutes | General purpose |
| High (20+) | Long grinding retries | Parallel Jobs where individual Pod failures are expected |

For parallel Jobs, remember `backoffLimit` counts **total failures across all Pods**, not per Pod. A Job with `parallelism: 20` and `backoffLimit: 6` fails the entire Job after just six individual Pod failures, which on a large batch can be a tiny fraction of the work.

### backoffLimitPerIndex

For Indexed Jobs, a per index back-off limit exists so that one bad shard does not fail the whole Job. It is paired with `maxFailedIndexes`. This capability has been feature gated, so verify availability on your cluster before designing around it:

```bash
kubectl explain job.spec.backoffLimitPerIndex
kubectl explain job.spec.maxFailedIndexes
```

```yaml
spec:
  completionMode: Indexed
  completions: 50
  parallelism: 10
  backoffLimitPerIndex: 2     # each index gets its own retry budget
  maxFailedIndexes: 5         # tolerate up to 5 permanently failed indexes
```

When available, `status.failedIndexes` reports which indexes gave up.

---

## activeDeadlineSeconds

A wall clock budget for the entire Job, measured from `status.startTime`.

```yaml
spec:
  activeDeadlineSeconds: 1800     # 30 minutes
```

When the deadline passes:

1. All running Pods are terminated.
2. The Job gets condition `Failed` with reason `DeadlineExceeded`.
3. No further Pods are created, **regardless of remaining `backoffLimit`**.

```bash
kubectl get job stuck-job -o jsonpath='{.status.conditions}' | jq
# [{"type":"Failed","status":"True","reason":"DeadlineExceeded",
#   "message":"Job was active longer than specified deadline"}]
```

**`activeDeadlineSeconds` takes precedence over `backoffLimit`.** A Job with `backoffLimit: 100` and `activeDeadlineSeconds: 60` stops after 60 seconds no matter how many retries remain.

### Two Different activeDeadlineSeconds

This is a genuine and frequently missed distinction:

| Field | Scope | Effect |
|-------|-------|--------|
| `spec.activeDeadlineSeconds` (Job) | The whole Job | Job marked `Failed` with `DeadlineExceeded`; no more retries |
| `spec.template.spec.activeDeadlineSeconds` (Pod) | Each individual Pod | That Pod is terminated; the Job may still create a replacement |

```yaml
spec:
  activeDeadlineSeconds: 3600        # whole job: 1 hour
  template:
    spec:
      activeDeadlineSeconds: 600     # each pod: 10 minutes
      restartPolicy: Never
```

The combination "each attempt gets 10 minutes, the whole thing gets 1 hour" is a very useful shape for batch work with an unreliable dependency.

`activeDeadlineSeconds` is mutable on a live Job:

```bash
# Give a long running job more time
kubectl patch job long-etl -p '{"spec":{"activeDeadlineSeconds":7200}}'

# Kill a runaway job immediately by setting a tiny deadline
kubectl patch job runaway -p '{"spec":{"activeDeadlineSeconds":1}}'
```

That last trick is a clean way to cancel a Job while leaving the object in place with an explanatory condition, instead of deleting it and losing the record.

---

## Pod Failure Policy

`spec.podFailurePolicy` lets the Job controller **classify** failures instead of treating them all identically. It is the answer to "my Job failed because a node was preempted, not because my code is broken".

Requirements to be aware of: pod failure policy has been feature gated, and using `onExitCodes` requires `restartPolicy: Never`. Check availability first:

```bash
kubectl explain job.spec.podFailurePolicy
```

### The Actions

| Action | Effect |
|--------|--------|
| `FailJob` | Fail the entire Job immediately, skipping remaining retries |
| `Ignore` | Do not increment the back-off counter; the Pod is replaced "for free" |
| `Count` | Default behaviour: increment the counter toward `backoffLimit` |
| `FailIndex` | Mark this index as failed and stop retrying it (Indexed Jobs, requires `backoffLimitPerIndex`) |

### The Matchers

Rules match on either the container exit code or a Pod condition:

```yaml
spec:
  backoffLimit: 6
  podFailurePolicy:
    rules:
    # Non retryable application errors: give up immediately.
    - action: FailJob
      onExitCodes:
        containerName: worker
        operator: In
        values: [42, 43]

    # Infrastructure disruption: do not spend a retry on it.
    - action: Ignore
      onPodConditions:
      - type: DisruptionTarget

    # Everything else falls through to normal counting.
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: worker
        image: registry.example.com/worker:3.1
```

`onExitCodes` supports operators `In` and `NotIn`, and can target a specific `containerName` or omit it to match any container.

`onPodConditions` matches Pod conditions by `type` and `status`. The `DisruptionTarget` condition is added when a Pod is being deleted because of a disruption such as preemption, node pressure eviction or a graceful node shutdown, which is exactly the class of failure you usually want to `Ignore`.

### Why This Matters

```
┌───────────────────────────────────────────────────────────────────┐
│         Without vs With podFailurePolicy on spot nodes            │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  WITHOUT (backoffLimit: 6)                                        │
│    preemption 1..6  ──► backoffLimit exhausted ──► Job Failed     │
│    Zero application errors. The batch never ran.                  │
│                                                                   │
│  WITH   (Ignore on DisruptionTarget)                              │
│    preemption 1..N  ──► pods replaced, counter untouched          │
│    Real app error   ──► counted, and the budget is still intact   │
│    The batch eventually completes.                                │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

Combine `FailJob` on a well known "bad input" exit code with `Ignore` on disruptions, and your `backoffLimit` finally measures what you actually care about: genuine, retryable application failures.

---

## Suspending Jobs

```yaml
spec:
  suspend: true
```

Setting `suspend: true` on a Job:

- Prevents any Pods from being created if the Job has not started.
- **Deletes** all active Pods if the Job is already running.
- Adds the `Suspended` condition.
- Resets `status.startTime` when the Job is later resumed, so `activeDeadlineSeconds` restarts its count.

```bash
# Create a job that does not run yet
kubectl apply -f big-batch.yaml    # with suspend: true

kubectl get job big-batch
# NAME        STATUS      COMPLETIONS   DURATION   AGE
# big-batch   Suspended   0/50                     8s

# Release it
kubectl patch job big-batch -p '{"spec":{"suspend":false}}'

# Pause a running job (active pods are DELETED)
kubectl patch job big-batch -p '{"spec":{"suspend":true}}'
kubectl get job big-batch -o jsonpath='{.status.conditions}' | jq
```

Deleting active Pods is the critical detail: **suspension is not a freeze, it is a stop**. Partially completed work in those Pods is lost unless your workload checkpoints. Completions that already succeeded are retained in `status.succeeded`.

Use cases:

- **Queueing systems.** A batch scheduler admits Jobs by flipping `suspend` to false when quota and capacity allow. This is the primary reason the field exists.
- **Maintenance windows.** Create the Job now, release it during the window.
- **Emergency stop** for a Job that is hammering a dependency.

Compare with `parallelism: 0`, which stops new Pods but lets in-flight ones finish. For non checkpointing workloads, `parallelism: 0` is usually the kinder pause.

---

## Cleanup with ttlSecondsAfterFinished

Finished Jobs and their Pods are kept forever by default. On a busy cluster this accumulates thousands of objects, bloats etcd, and slows down `kubectl get pods`.

```yaml
spec:
  ttlSecondsAfterFinished: 3600     # delete 1 hour after finishing
```

The **TTL after finished controller**, part of kube-controller-manager, watches Jobs that have reached a terminal condition and deletes them once the TTL elapses since `status.completionTime` (or the failure time).

```
┌───────────────────────────────────────────────────────────────────┐
│                   TTL Controller Behaviour                        │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   Job reaches Complete or Failed                                  │
│              │                                                    │
│              ▼  wait ttlSecondsAfterFinished                      │
│   TTL controller DELETES the Job object                           │
│              │                                                    │
│              ▼  cascading delete via ownerReferences              │
│   The Job's Pods are deleted too                                  │
│                                                                   │
│   ttlSecondsAfterFinished: 0  ──► eligible immediately            │
│   field not set               ──► kept forever                    │
│                                                                   │
│   The TTL clock starts when the job FINISHES, not when it starts. │
│   Deleting the Job deletes the logs. Ship logs elsewhere first.   │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

```bash
# Retrofit a TTL onto an existing job
kubectl patch job old-report -p '{"spec":{"ttlSecondsAfterFinished":300}}'

# Manual cleanup of everything already finished in a namespace
kubectl delete jobs -n batch --field-selector status.successful=1

# Broader sweep
kubectl get jobs -n batch -o json | jq -r '
  .items[] | select(.status.succeeded == 1) | .metadata.name' \
  | xargs -r kubectl delete job -n batch
```

Pick a TTL long enough for a human to investigate a failure. An hour is a reasonable floor; a day is common for anything business critical. Zero is only appropriate when logs are shipped to an external system.

---

## Job Labels, Selectors and Ownership

The Job controller generates a selector automatically. **Do not write one yourself.**

```bash
kubectl get job data-migration -o jsonpath='{.spec.selector}' | jq
# { "matchLabels": { "batch.kubernetes.io/controller-uid": "3f2a...-..." } }

kubectl get pods -l job-name=data-migration
kubectl get pods --show-labels -l job-name=data-migration
```

Labels applied to Job Pods:

| Label | Value |
|-------|-------|
| `batch.kubernetes.io/job-name` | The Job name |
| `job-name` | The Job name (legacy alias, still present) |
| `batch.kubernetes.io/controller-uid` | The Job's UID |
| `controller-uid` | The Job's UID (legacy alias) |
| `batch.kubernetes.io/job-completion-index` | Index, for Indexed Jobs only |

Because the selector keys off the Job's **UID**, deleting and recreating a Job with the same name produces a different UID and therefore a different selector, so the new Job never adopts the old Pods. That is the design intent.

`spec.manualSelector: true` disables the automatic selector so you can supply your own. Do not use it unless you are migrating legacy objects and fully understand the consequences: overlapping selectors cause two Jobs to fight over the same Pods and miscount completions.

### Ownership Chain

```
Job (batch/v1)
  └── ownerReference on each Pod, controller: true, blockOwnerDeletion: true
        └── Pod (v1)
```

```bash
kubectl get pod data-migration-abc12 -o jsonpath='{.metadata.ownerReferences}' | jq
```

Deleting the Job cascades to the Pods. To keep them:

```bash
kubectl delete job data-migration --cascade=orphan
```

---

## Inspecting Jobs

```bash
# All jobs, with completion counts and duration
kubectl get jobs -A

# NAME              STATUS      COMPLETIONS   DURATION   AGE
# data-migration    Complete    1/1           47s        2h
# render-frames     Running     63/100        12m        12m
# nightly-backup-1  Failed      0/1           11m        1h

# Full detail including events
kubectl describe job render-frames -n batch

# Raw status counters
kubectl get job render-frames -n batch -o jsonpath='{.status}' | jq
# {
#   "active": 10, "succeeded": 63, "failed": 2,
#   "startTime": "...", "completedIndexes": "0-62"
# }
```

### Logs

```bash
# Logs from ONE pod of the job (kubectl picks one)
kubectl logs job/render-frames -n batch

# Follow
kubectl logs job/render-frames -n batch -f

# Logs from ALL pods of the job, prefixed with the pod name
kubectl logs -n batch -l job-name=render-frames --prefix --tail=-1

# Logs from a specific failed attempt
kubectl logs -n batch render-frames-abc12

# Previous container instance (restartPolicy: OnFailure)
kubectl logs -n batch render-frames-abc12 --previous
```

`kubectl logs job/<name>` selecting a single arbitrary Pod surprises people on parallel Jobs. Use the label selector form when you need everything.

### Events

```bash
# Events for a specific job, newest last
kubectl get events -n batch --field-selector involvedObject.name=render-frames \
  --sort-by=.lastTimestamp

# All job related events in a namespace
kubectl get events -n batch --field-selector involvedObject.kind=Job
```

Job controller event reasons worth recognising:

| Reason | Meaning |
|--------|---------|
| `SuccessfulCreate` | A Pod was created |
| `SuccessfulDelete` | A Pod was deleted (suspension, deadline, cleanup) |
| `BackoffLimitExceeded` | The retry budget ran out; Job is Failed |
| `DeadlineExceeded` | `activeDeadlineSeconds` elapsed |
| `Completed` | The Job reached its required completions |
| `Suspended` / `Resumed` | The `suspend` field was toggled |

### Useful One-Liners

```bash
# Failed jobs across the cluster
kubectl get jobs -A -o json | jq -r '
  .items[] | select(.status.failed // 0 > 0) |
  "\(.metadata.namespace)/\(.metadata.name) failed=\(.status.failed)"'

# Jobs that are still active after an hour
kubectl get jobs -A -o json | jq -r '
  .items[] | select(.status.active // 0 > 0) |
  "\(.metadata.namespace)/\(.metadata.name) started=\(.status.startTime)"'

# Pods left behind by finished jobs
kubectl get pods -A --field-selector status.phase=Succeeded
kubectl get pods -A --field-selector status.phase=Failed
```

---

## Troubleshooting

### Symptom 1: Job Never Completes, Pods Are Pending

```bash
kubectl get jobs -n batch
# render-frames   Running   0/100   18m   18m

kubectl get pods -n batch -l job-name=render-frames
# render-frames-abc12   0/1   Pending   0   18m

kubectl describe pod -n batch render-frames-abc12 | sed -n '/Events/,$p'
```

| Event | Cause | Fix |
|-------|-------|-----|
| `Insufficient cpu` / `Insufficient memory` | Requests exceed available capacity | Lower requests, lower `parallelism`, or add nodes |
| `exceeded quota` | ResourceQuota in the namespace | Raise the quota or reduce `parallelism` |
| `didn't match Pod's node affinity/selector` | Selector matches no node | Fix the selector or label nodes |
| `had untolerated taint` | Node taints not tolerated | Add tolerations |
| `pod has unbound immediate PersistentVolumeClaims` | Volume not bound | Debug the PVC |

```bash
kubectl describe resourcequota -n batch
kubectl top nodes
```

### Symptom 2: Job Never Completes, Pods Are Running Forever

The container does not exit. A Job Pod whose process runs indefinitely will never satisfy the completion count.

```bash
kubectl logs -n batch job/long-etl --tail=50
kubectl exec -n batch long-etl-abc12 -- ps aux
```

Common causes:

- The image's entrypoint is a server (`nginx`, `sleep infinity`, a shell waiting on stdin). A Job needs a command that terminates.
- The process is blocked on a network call with no timeout.
- The script waits on stdin because it was written for interactive use.
- A background child process holds the container open even though the main work finished.

Always set `activeDeadlineSeconds` so a hung Job fails loudly instead of running until someone notices the bill.

```bash
# Confirm the container command
kubectl get job long-etl -o jsonpath='{.spec.template.spec.containers[0]}' | jq '{command,args}'
```

### Symptom 3: Job Failed with BackoffLimitExceeded

```bash
kubectl describe job -n batch data-migration | sed -n '/Events/,$p'
# Warning  BackoffLimitExceeded  Job has reached the specified backoff limit

# Every attempt is preserved with restartPolicy: Never
kubectl get pods -n batch -l job-name=data-migration
kubectl logs -n batch data-migration-abc12
kubectl logs -n batch data-migration-de34f

# Exit code and reason of a specific attempt
kubectl get pod -n batch data-migration-abc12 \
  -o jsonpath='{.status.containerStatuses[0].state.terminated}' | jq
```

| Exit code | Usual meaning |
|-----------|---------------|
| `1` | Generic application error; read the logs |
| `2` | Shell misuse, or an application specific error |
| `126` | Command found but not executable |
| `127` | Command not found in the image |
| `137` | SIGKILL, usually OOMKilled |
| `139` | SIGSEGV |
| `143` | SIGTERM, often the deadline or a preemption |

If `reason: OOMKilled` appears, raise the memory limit:

```bash
kubectl get pod -n batch data-migration-abc12 \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
```

> 📖 **See Also**: [cgroups.md](cgroups.md) for how memory limits and OOM kills work.

### Symptom 4: Job Failed with DeadlineExceeded

```bash
kubectl get job -n batch long-etl -o jsonpath='{.status.conditions}' | jq
# reason: "DeadlineExceeded"
```

Either the work genuinely takes longer than the budget, or it is stuck. Distinguish them by checking how far it got:

```bash
kubectl logs -n batch -l job-name=long-etl --tail=100
kubectl get job -n batch long-etl -o jsonpath='{.status.succeeded}{"/"}{.spec.completions}{"\n"}'
```

If it was making steady progress, raise the deadline. If it stalled at a fixed point, that point is your bug.

### Symptom 5: CreateContainerConfigError or ImagePullBackOff

```bash
kubectl get pods -n batch -l job-name=data-migration
# data-migration-abc12   0/1   CreateContainerConfigError   0   2m

kubectl describe pod -n batch data-migration-abc12 | sed -n '/Events/,$p'
```

| Status | Cause | Fix |
|--------|-------|-----|
| `CreateContainerConfigError` | Missing Secret or ConfigMap referenced by env or volume | Create it, or fix the name |
| `ImagePullBackOff` | Bad image name/tag, or missing registry credentials | Verify the reference; add `imagePullSecrets` |
| `CreateContainerError` | Bad command path, or a `securityContext` conflict | Verify the entrypoint exists in the image |

```bash
# Verify the referenced objects exist
kubectl get secret db-credentials -n batch
kubectl get configmap migration-config -n batch
```

These failures still burn `backoffLimit`, so a typo in a Secret name eventually fails the whole Job rather than hanging forever.

### Symptom 6: Work Queue Job Completed Too Early

The Job reports `Complete` but the queue still has items.

Root cause is almost always the worker contract: a Pod exited `0` when it should have exited non zero. Common triggers:

- The worker treats "no message available right now" (a poll timeout) as "queue empty".
- An unhandled exception path falls through to a `return 0`.
- A shell script without `set -e` where the last command happened to succeed.

```bash
kubectl logs -n batch -l job-name=queue-workers --prefix --tail=-1 | grep -i -E 'empty|exit|done'
```

Fixes: require several consecutive empty polls before exiting 0, use `set -euo pipefail` in shell workers, and make the exit code explicit rather than implicit.

### Symptom 7: Completed Pods Piling Up

```bash
kubectl get pods -A --field-selector status.phase=Succeeded | wc -l
```

Expected: Jobs retain their Pods. Set `ttlSecondsAfterFinished` on new Jobs and clean up the backlog:

```bash
kubectl patch job old-job -n batch -p '{"spec":{"ttlSecondsAfterFinished":600}}'
kubectl delete pods -n batch --field-selector status.phase=Succeeded
```

If the TTL is set but nothing is being deleted, verify the TTL controller is running:

```bash
kubectl get pods -n kube-system -l component=kube-controller-manager
kubectl logs -n kube-system -l component=kube-controller-manager --tail=100 | grep -i ttl
```

### Symptom 8: Job Shows No Pods At All

```bash
kubectl get job -n batch big-batch
# NAME        STATUS      COMPLETIONS   DURATION   AGE
# big-batch   Suspended   0/50                     4m
```

Check `suspend` and `parallelism` first, before anything else:

```bash
kubectl get job -n batch big-batch -o jsonpath='{.spec.suspend}{"\n"}{.spec.parallelism}{"\n"}'
kubectl get job -n batch big-batch -o jsonpath='{.status.conditions}' | jq
```

Also check for an admission webhook rejecting Pod creation:

```bash
kubectl describe job -n batch big-batch | sed -n '/Events/,$p'
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
```

A `FailedCreate` event mentioning a webhook or a Pod Security Admission violation points straight at the cause.

### Symptom 9: Cannot Update a Running Job

```bash
kubectl edit job data-migration
# error: Job.batch "data-migration" is invalid: spec.template: Invalid value: ...
# field is immutable
```

Expected. Only `parallelism`, `suspend`, `activeDeadlineSeconds` and `ttlSecondsAfterFinished` are mutable. To change anything else, delete and recreate:

```bash
kubectl delete job data-migration -n batch
kubectl apply -f data-migration.yaml
```

For CronJob owned Jobs, edit the CronJob's `jobTemplate` instead; the next run picks it up.

---

## Exam and Interview Traps

1. **`apiVersion: batch/v1`** for both Job and CronJob. Not `apps/v1`, which is for Deployment, DaemonSet, StatefulSet and ReplicaSet.
2. **`restartPolicy` must be `Never` or `OnFailure`.** `Always` is rejected. This is the exact inverse of a DaemonSet, where `Always` is required.
3. **`backoffLimit` defaults to 6**, and the back-off is exponential starting at 10 seconds, doubling, capped at 6 minutes. A failing Job takes roughly ten minutes plus attempt runtimes to report `Failed`.
4. **`backoffLimit` counts failures across the whole Job**, not per Pod. On a highly parallel Job that budget is consumed very fast.
5. **`activeDeadlineSeconds` beats `backoffLimit`.** Once the deadline hits, the Job fails with `DeadlineExceeded` and no further retries happen.
6. **There are two `activeDeadlineSeconds` fields.** `spec.activeDeadlineSeconds` bounds the Job; `spec.template.spec.activeDeadlineSeconds` bounds each Pod.
7. **Work queue pattern means omitting `completions`**, not setting it to 0. With `completions` unset, the Job completes when at least one Pod succeeds and all Pods have terminated.
8. **`completionMode: Indexed` requires `completions` to be set.** A work queue Job cannot be Indexed.
9. **The index environment variable is `JOB_COMPLETION_INDEX`**, and the annotation and label key is `batch.kubernetes.io/job-completion-index`.
10. **`status.completedIndexes` uses compressed range notation**, for example `0-4,7,9-11`.
11. **`restartPolicy: Never` creates a new Pod per attempt; `OnFailure` restarts the container in the same Pod.** With `Never` you keep every attempt's logs; with `OnFailure` you get one Pod with a rising `RESTARTS` count and only `--previous` logs.
12. **Finished Pods are not deleted automatically** unless `ttlSecondsAfterFinished` is set. Deleting the Job deletes the logs, so ship them out first.
13. **Most of a Job's spec is immutable.** Only `parallelism`, `suspend`, `activeDeadlineSeconds` and `ttlSecondsAfterFinished` can be changed in place.
14. **`suspend: true` deletes running Pods**, it does not freeze them. In-flight work is lost. `parallelism: 0` is the gentler pause.
15. **`kubectl logs job/<name>` reads one arbitrary Pod.** For a parallel Job, use `kubectl logs -l job-name=<name> --prefix`.
16. **Never write `spec.selector` yourself.** The controller generates one from the Job UID; `manualSelector: true` exists but invites overlapping selector bugs.
17. **`kubectl scale job/<name> --replicas=N` sets `parallelism`**, not `completions`.
18. **Infrastructure disruptions count against `backoffLimit` by default.** `podFailurePolicy` with `action: Ignore` on the `DisruptionTarget` Pod condition is the fix.
19. **`onExitCodes` in a pod failure policy requires `restartPolicy: Never`.**
20. **Job Pods stay in `Succeeded` or `Failed` phase**, which is why `kubectl get pods` shows `Completed` rather than the Pod disappearing.

---

## Related Topics

- [CronJobs](cronjobs.md)
- [Pods](pods.md)
- [Controllers](controllers.md)
- [DaemonSets](daemonsets.md)
- [StatefulSets](statefulsets.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-scheduler](kube-scheduler.md)
- [kubectl](kubectl.md)
- [Imperative Kubernetes](imperative-kubernetes.md)
- [Cgroups](cgroups.md)
- [Kubernetes API](k8s-api.md)
- [CoreDNS](coredns.md)

---

## Key Takeaways

1. A Job runs Pods **to completion**: it counts successful terminations rather than maintaining a running replica count, and it ends in exactly one terminal condition, `Complete` or `Failed`.
2. `completions` and `parallelism` generate three patterns: **single job** (both unset), **fixed completion count** (`completions: N`, `parallelism: M`), and **work queue** (`completions` omitted, `parallelism: M`).
3. The work queue pattern completes when at least one Pod exits 0 **and** all Pods have terminated, which makes the worker's exit code contract safety critical: exit 0 must mean "the queue is genuinely empty".
4. `completionMode: Indexed` gives each Pod a unique index via `JOB_COMPLETION_INDEX`, the `batch.kubernetes.io/job-completion-index` annotation and label, a deterministic hostname `<job>-<index>`, and progress reporting through `status.completedIndexes`. It requires `completions` to be set.
5. `restartPolicy` must be `Never` or `OnFailure`; **`Always` is rejected** because a perpetually restarting Pod can never reach a terminal phase.
6. `Never` produces a fresh Pod per attempt (better debugging, can reschedule off a bad node); `OnFailure` restarts the container in place (faster, but only the previous attempt's logs survive). Prefer `Never` for production batch work.
7. `backoffLimit` defaults to 6 and retries use exponential back-off of 10s, 20s, 40s, 80s, 160s, 320s, capped at 6 minutes, so a doomed Job takes roughly ten minutes plus attempt runtimes to be declared `Failed`.
8. `backoffLimit` is a **whole Job** budget shared across all Pods, which is easy to exhaust on parallel Jobs; `backoffLimitPerIndex` with `maxFailedIndexes` addresses this for Indexed Jobs where supported.
9. `activeDeadlineSeconds` is a hard wall clock limit that **takes precedence over `backoffLimit`**, and it exists at both Job and Pod scope with different meanings.
10. `podFailurePolicy` classifies failures with `FailJob`, `Ignore`, `Count` and `FailIndex`, matching on `onExitCodes` or `onPodConditions`. Ignoring `DisruptionTarget` stops preemptions from consuming your retry budget.
11. `suspend: true` stops the Job and **deletes** its active Pods; it is the hook that external batch schedulers use to gate admission. `parallelism: 0` is the softer alternative that lets running Pods finish.
12. Finished Jobs and their Pods persist indefinitely unless `ttlSecondsAfterFinished` is set; the TTL controller then deletes the Job and cascades to the Pods, taking the logs with it.
13. A Job's spec is almost entirely immutable. Only `parallelism`, `suspend`, `activeDeadlineSeconds` and `ttlSecondsAfterFinished` can be patched on a live Job.
14. Selectors are generated from the Job UID; write your own only with `manualSelector` and a very good reason. Pods carry `batch.kubernetes.io/job-name` and `job-name` labels for querying.
15. The two most common "Job never completes" causes are Pods stuck `Pending` (capacity, quota, selectors) and containers that simply never exit. Setting `activeDeadlineSeconds` turns the second one from a silent hang into a clear failure.

---

## References

- [Jobs concept](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [Indexed Job for Parallel Processing with Static Work Assignment](https://kubernetes.io/docs/tasks/job/indexed-parallel-processing-static/)
- [Parallel Processing using Expansions](https://kubernetes.io/docs/tasks/job/parallel-processing-expansion/)
- [Coarse Parallel Processing Using a Work Queue](https://kubernetes.io/docs/tasks/job/coarse-parallel-processing-work-queue/)
- [Fine Parallel Processing Using a Work Queue](https://kubernetes.io/docs/tasks/job/fine-parallel-processing-work-queue/)
- [Handling Retriable and Non-Retriable Pod Failures](https://kubernetes.io/docs/tasks/job/pod-failure-policy/)
- [Automatic Cleanup for Finished Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/)
- [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Job API reference (batch/v1)](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/job-v1/)
