# ⏰ CronJobs: Scheduled Workloads

A deep dive into the CronJob controller: schedule syntax, timezone handling, concurrency policy, missed schedule accounting, the CronJob to Job to Pod ownership chain, and how to run scheduled work that is actually reliable.

## 📋 Table of Contents
- [What Is a CronJob?](#what-is-a-cronjob)
- [The Ownership Chain](#the-ownership-chain)
- [Cron Schedule Syntax](#cron-schedule-syntax)
- [Timezone Handling](#timezone-handling)
- [Creating CronJobs](#creating-cronjobs)
- [Concurrency Policy](#concurrency-policy)
- [startingDeadlineSeconds and Missed Schedules](#startingdeadlineseconds-and-missed-schedules)
- [Suspending CronJobs](#suspending-cronjobs)
- [History Limits](#history-limits)
- [Idempotency Requirements](#idempotency-requirements)
- [Manually Triggering a CronJob](#manually-triggering-a-cronjob)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Inspecting CronJobs](#inspecting-cronjobs)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What Is a CronJob?

A **CronJob** creates [Jobs](jobs.md) on a repeating schedule. It is the Kubernetes equivalent of a crontab entry, with the important difference that it produces API objects you can inspect, retry and audit.

```
┌───────────────────────────────────────────────────────────────────┐
│                    CronJob Mental Model                           │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   Linux crontab                    Kubernetes CronJob             │
│   ─────────────                    ──────────────────             │
│   Runs on ONE machine              Runs somewhere in the cluster  │
│   Output goes to mail or /dev/null Output is pod logs             │
│   No retry semantics               Job backoffLimit gives retries │
│   No record of past runs           Job history objects retained   │
│   Silent failure is the norm       Failures are queryable objects │
│                                                                   │
│   A CronJob does NOT run containers itself.                       │
│   It creates a Job. The Job creates the Pods.                     │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

The API group is **`batch/v1`**, the same as Job:

```yaml
apiVersion: batch/v1
kind: CronJob
```

Typical workloads: nightly backups, log rotation and archival, report generation, cache warming, certificate renewal checks, data synchronisation, cleanup of stale records, and periodic health verification.

---

## The Ownership Chain

Three object kinds, two owner references, one cascade.

```
┌───────────────────────────────────────────────────────────────────┐
│               CronJob ──► Job ──► Pod Ownership                   │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   CronJob "nightly-backup"  (batch/v1)                            │
│      │  spec.schedule fires                                       │
│      │  controller creates a Job from spec.jobTemplate            │
│      ▼                                                            │
│   Job "nightly-backup-28901234"  (batch/v1)                       │
│      │  ownerReferences: [CronJob nightly-backup, controller:true]│
│      │  Job controller creates pods from spec.template            │
│      ▼                                                            │
│   Pod "nightly-backup-28901234-x7f2k"  (v1)                       │
│         ownerReferences: [Job nightly-backup-28901234]            │
│         labels: batch.kubernetes.io/job-name=...                  │
│                                                                   │
│   Delete the CronJob ──► its Jobs are garbage collected           │
│                      ──► their Pods are garbage collected         │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

```bash
# Walk the chain
kubectl get cronjob nightly-backup
kubectl get jobs --sort-by=.metadata.creationTimestamp | grep nightly-backup
kubectl get pods -l job-name=nightly-backup-28901234

# Confirm the owner references
kubectl get job nightly-backup-28901234 \
  -o jsonpath='{.metadata.ownerReferences}' | jq
kubectl get pod nightly-backup-28901234-x7f2k \
  -o jsonpath='{.metadata.ownerReferences}' | jq
```

### Generated Job Names

The Job name is the CronJob name plus a suffix derived from the scheduled time:

```
nightly-backup-28901234
└──── cronjob name ────┘└─ time derived suffix ─┘
```

This has a hard consequence: **a CronJob name must be no longer than 52 characters.** The generated Job name must fit within the 63 character DNS label limit, and the appended suffix consumes 11 characters.

```bash
# This is rejected
kubectl create cronjob a-really-very-extremely-long-cronjob-name-that-exceeds \
  --image=busybox --schedule="* * * * *" -- date
# must be no more than 52 characters
```

The deterministic naming also gives you idempotency at the controller level: if the controller tries to create the same scheduled Job twice, the second create collides on the name and is rejected, so one schedule tick cannot spawn two Jobs.

---

## Cron Schedule Syntax

```yaml
spec:
  schedule: "0 2 * * *"
```

Five space separated fields, in this order:

```
┌───────────── minute        (0 - 59)
│ ┌───────────── hour        (0 - 23)
│ │ ┌───────────── day of month (1 - 31)
│ │ │ ┌───────────── month     (1 - 12)
│ │ │ │ ┌───────────── day of week (0 - 6, Sunday = 0)
│ │ │ │ │
* * * * *
```

There is **no seconds field**. The finest granularity is one minute.

### Special Characters

| Character | Name | Meaning | Example |
|-----------|------|---------|---------|
| `*` | Asterisk | Every valid value for this field | `* * * * *` every minute |
| `?` | Question mark | Same meaning as `*` | `0 2 ? * *` same as `0 2 * * *` |
| `,` | Comma | List of values | `0 2,14 * * *` at 02:00 and 14:00 |
| `-` | Hyphen | Inclusive range | `0 9-17 * * *` hourly from 09:00 to 17:00 |
| `/` | Slash | Step value | `*/15 * * * *` every 15 minutes |

Ranges and steps combine: `0 9-17/2 * * *` means every two hours between 09:00 and 17:00.

### Schedule Examples

| Schedule | Meaning |
|----------|---------|
| `* * * * *` | Every minute |
| `*/5 * * * *` | Every 5 minutes |
| `*/30 * * * *` | Every 30 minutes (at :00 and :30) |
| `0 * * * *` | Every hour, on the hour |
| `0 */6 * * *` | Every 6 hours: 00:00, 06:00, 12:00, 18:00 |
| `30 2 * * *` | Daily at 02:30 |
| `0 2 * * *` | Daily at 02:00 |
| `0 0 * * *` | Daily at midnight |
| `0 2 * * 0` | Weekly, Sunday at 02:00 |
| `0 2 * * 1-5` | Weekdays only, at 02:00 |
| `0 2 * * 6,0` | Weekends only, at 02:00 |
| `0 3 1 * *` | Monthly, on the 1st at 03:00 |
| `0 3 1 1,4,7,10 *` | Quarterly, on the 1st at 03:00 |
| `0 3 1 1 *` | Yearly, 1 January at 03:00 |
| `15 14 1 * *` | 14:15 on the 1st of every month |
| `0 22 * * 1-5` | 22:00 on every weekday |
| `23 0-20/2 * * *` | At minute 23 past every 2nd hour from 0 to 20 |
| `5 0 * 8 *` | 00:05 every day in August |

### Macros

| Macro | Equivalent | Meaning |
|-------|-----------|---------|
| `@yearly` (or `@annually`) | `0 0 1 1 *` | Once a year, 1 January at midnight |
| `@monthly` | `0 0 1 * *` | Once a month, on the 1st at midnight |
| `@weekly` | `0 0 * * 0` | Once a week, Sunday at midnight |
| `@daily` (or `@midnight`) | `0 0 * * *` | Once a day at midnight |
| `@hourly` | `0 * * * *` | Once an hour, on the hour |

```yaml
spec:
  schedule: "@daily"
```

Macros are readable but less precise. `@daily` puts every scheduled workload in the cluster at exactly midnight, producing a thundering herd. Explicit staggered times (`7 0 * * *`, `19 0 * * *`) are better operational practice.

### The Day of Month and Day of Week OR Rule

This is the single most misread piece of cron syntax anywhere, and it long predates Kubernetes.

**When both day-of-month and day-of-week are restricted (neither is `*`), the schedule fires when EITHER matches, not both.**

```
┌───────────────────────────────────────────────────────────────────┐
│                 Day Fields: AND or OR?                            │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  "0 2 * * 1"     dom = *, dow = Monday                            │
│      ──► every Monday at 02:00.        (only dow restricted)      │
│                                                                   │
│  "0 2 15 * *"    dom = 15, dow = *                                │
│      ──► the 15th of every month.      (only dom restricted)      │
│                                                                   │
│  "0 2 15 * 1"    dom = 15, dow = Monday   BOTH restricted         │
│      ──► the 15th of the month, OR any Monday.                    │
│          NOT "only when the 15th falls on a Monday".              │
│                                                                   │
│  To get an AND you must handle it in the job itself:              │
│    schedule: "0 2 15 * *"     (fire on the 15th)                  │
│    then in the container: [ "$(date +%u)" = "1" ] || exit 0       │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Validating a Schedule

The API server validates the syntax on create, so an unparseable schedule is rejected up front:

```bash
kubectl apply -f bad-cron.yaml
# The CronJob "x" is invalid: spec.schedule: Invalid value: "0 25 * * *":
# end of range (25) above maximum (23): 25
```

It cannot validate your *intent*, though. Verify what a schedule really means before trusting it in production, and prefer the explicit five field form over macros for anything important.

---

## Timezone Handling

### The Historical Default

Historically, a CronJob's schedule was interpreted in the **time zone of the kube-controller-manager process**. That is an unfortunate default for several reasons:

- The controller runs on a control plane node whose time zone you may not control.
- In a highly available control plane, the active controller can move between nodes.
- The time zone is invisible from the CronJob object itself, so the manifest does not say when it actually runs.
- Most managed and kubeadm control planes run in UTC, so schedules silently mean UTC while the team writes them in local time.

```bash
# What time zone does the controller actually think it is in?
kubectl exec -n kube-system kube-controller-manager-cp-01 -- date
# or, if the container has no shell, check the node
date
cat /etc/timezone 2>/dev/null || readlink -f /etc/localtime
```

### The timeZone Field

The `spec.timeZone` field makes the intent explicit by naming an IANA time zone:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-report
spec:
  schedule: "0 2 * * *"
  timeZone: "Europe/London"      # IANA name, not an abbreviation
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: report
            image: registry.example.com/reporter:2.4
```

Valid values are IANA time zone database names:

| Valid | Invalid |
|-------|---------|
| `Etc/UTC` | `UTC+0` |
| `America/New_York` | `EST` |
| `Europe/London` | `GMT+1` |
| `Asia/Kolkata` | `IST` |
| `Australia/Sydney` | `AEST` |

Abbreviations like `EST` and `IST` are ambiguous (`IST` alone maps to at least three different offsets worldwide), which is why only full IANA names are accepted.

Verify support and behaviour on your cluster:

```bash
kubectl explain cronjob.spec.timeZone

# Confirm what the controller resolved
kubectl get cronjob nightly-report -o jsonpath='{.spec.timeZone}{"\n"}'
kubectl get cronjob nightly-report -o jsonpath='{.status.lastScheduleTime}{"\n"}'
```

If the name cannot be loaded, the CronJob is rejected or reports an error rather than silently falling back, which is the behaviour you want.

### Daylight Saving Time

Using a zone with DST introduces two annual hazards:

```
┌───────────────────────────────────────────────────────────────────┐
│              DST Hazards with timeZone: Europe/London             │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  SPRING FORWARD (clocks jump 01:00 ──► 02:00)                     │
│    schedule "0 1 * * *"  ──► 01:00 does not exist that day        │
│    Result: the run is SKIPPED.                                    │
│                                                                   │
│  FALL BACK (clocks repeat 01:00 ──► 01:00)                        │
│    schedule "30 1 * * *" ──► 01:30 occurs twice                   │
│    Result: risk of a DUPLICATE run.                               │
│                                                                   │
│  MITIGATIONS                                                      │
│    • Use timeZone: "Etc/UTC" for anything that must not skip      │
│      or double. UTC has no DST transitions.                       │
│    • If local time is a business requirement, schedule outside    │
│      the transition window (avoid 00:00 to 04:00 local).          │
│    • Make the job idempotent so a duplicate run is harmless.      │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

**Recommendation: use `timeZone: "Etc/UTC"` unless a human facing business requirement forces local time.** Being explicit about UTC is still better than omitting the field, because it documents the intent in the manifest.

### A Note on the Container's Time Zone

`spec.timeZone` affects **when the Job is created**. It does not change the time zone inside the container. A script that formats dates sees the container's own zone, which is UTC in most base images.

```yaml
          containers:
          - name: report
            image: registry.example.com/reporter:2.4
            env:
            - name: TZ
              value: "Europe/London"      # affects date formatting inside
```

Note that `TZ` only works if the image actually ships the tzdata database. Minimal and distroless images often do not.

---

## Creating CronJobs

### Imperative

```bash
# Create directly
kubectl create cronjob heartbeat \
  --image=busybox:1.36 \
  --schedule="*/5 * * * *" \
  -- /bin/sh -c 'date; echo alive'

# Generate a manifest to edit
kubectl create cronjob nightly-backup \
  --image=registry.example.com/backup:1.2 \
  --schedule="0 2 * * *" \
  --dry-run=client -o yaml > cronjob.yaml
```

### Full Declarative Manifest

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-backup
  namespace: batch
  labels:
    app.kubernetes.io/name: nightly-backup
spec:
  # WHEN to run.
  schedule: "17 2 * * *"          # 02:17, staggered off the hour
  timeZone: "Etc/UTC"

  # WHAT to do about overlaps: Allow | Forbid | Replace
  concurrencyPolicy: Forbid

  # How late a missed start may be and still run. Keep it modest.
  startingDeadlineSeconds: 300

  # Set true to stop scheduling without deleting the object.
  suspend: false

  # How many finished Jobs to keep for inspection.
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3

  jobTemplate:
    # NOTE: this is a JobSpec, so no apiVersion/kind here.
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 3600
      ttlSecondsAfterFinished: 86400

      template:
        metadata:
          labels:
            app.kubernetes.io/name: nightly-backup
        spec:
          restartPolicy: OnFailure
          serviceAccountName: backup-runner

          containers:
          - name: backup
            image: registry.example.com/backup:1.2
            command: ["/app/backup"]
            args: ["--target=s3://bucket/nightly", "--verify"]
            env:
            - name: DB_HOST
              value: postgres.database.svc.cluster.local
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
            resources:
              requests:
                cpu: 200m
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

### The Nesting Trap

The manifest nests four `spec` levels deep. Getting the depth wrong is the most common CronJob authoring error.

```
CronJob
└── spec                          (CronJobSpec)
    ├── schedule
    ├── timeZone
    ├── concurrencyPolicy
    ├── startingDeadlineSeconds
    ├── suspend
    ├── successfulJobsHistoryLimit
    ├── failedJobsHistoryLimit
    └── jobTemplate               (JobTemplateSpec)
        └── spec                  (JobSpec)  ◄── Job settings live HERE
            ├── backoffLimit
            ├── completions
            ├── parallelism
            ├── activeDeadlineSeconds
            ├── ttlSecondsAfterFinished
            └── template           (PodTemplateSpec)
                └── spec           (PodSpec)  ◄── Pod settings live HERE
                    ├── restartPolicy
                    └── containers
```

`backoffLimit` at the CronJob spec level is silently meaningless or rejected; it belongs under `jobTemplate.spec`. `restartPolicy` belongs at `jobTemplate.spec.template.spec`.

```bash
# Navigate the schema instead of guessing
kubectl explain cronjob.spec
kubectl explain cronjob.spec.jobTemplate.spec
kubectl explain cronjob.spec.jobTemplate.spec.template.spec
```

```bash
kubectl apply -f cronjob.yaml
kubectl get cronjob -n batch
# NAME             SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# nightly-backup   17 2 * * *    Etc/UTC    False     0        8h              3d
```

---

## Concurrency Policy

What should happen when a scheduled run arrives while the previous one is still going?

```yaml
spec:
  concurrencyPolicy: Forbid     # Allow (default) | Forbid | Replace
```

| Policy | Behaviour when the previous Job is still active |
|--------|------------------------------------------------|
| `Allow` (default) | Create the new Job anyway; both run concurrently |
| `Forbid` | Skip this run entirely; the previous Job continues |
| `Replace` | Delete the still running Job, then create the new one |

```
┌───────────────────────────────────────────────────────────────────┐
│      schedule "*/5 * * * *", job takes 12 minutes to run          │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ALLOW                                                            │
│   t=00 ├──────── job A ────────┤                                  │
│   t=05      ├──────── job B ────────┤                             │
│   t=10           ├──────── job C ────────┤                        │
│         3 concurrent jobs, and it keeps growing.                  │
│         Pile up risk: resource exhaustion, duplicate work.        │
│                                                                   │
│  FORBID                                                           │
│   t=00 ├──────── job A ────────┤                                  │
│   t=05      (skipped, A still active)                             │
│   t=10      (skipped, A still active)                             │
│   t=15 ├──────── job D ────────┤                                  │
│         At most one at a time. Runs are SILENTLY skipped.         │
│                                                                   │
│  REPLACE                                                          │
│   t=00 ├──── job A ──X (deleted)                                  │
│   t=05 ├──── job B ──X (deleted)                                  │
│   t=10 ├──── job C ──X (deleted)                                  │
│         Nothing ever finishes. Only the newest run survives.      │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Choosing a Policy

| Situation | Policy | Reasoning |
|-----------|--------|-----------|
| Backups, ETL, migrations | `Forbid` | Two concurrent runs would conflict or duplicate work |
| Cache warming, "latest snapshot" jobs | `Replace` | Only the newest result matters; kill the stale run |
| Independent, sharded, idempotent work | `Allow` | Concurrency is genuinely harmless and speeds throughput |

**`Forbid` is the right default for most real workloads.** `Allow` combined with a Job that occasionally runs long is how clusters end up with fifty concurrent backup Pods at 3am.

### The Forbid Blind Spot

`Forbid` skips silently. If a job hangs, every subsequent run is skipped indefinitely and the CronJob looks healthy in `kubectl get cronjob` because `ACTIVE` shows 1.

```bash
# ACTIVE stuck at 1 with an old LAST SCHEDULE is a red flag
kubectl get cronjob -n batch nightly-backup
# NAME             SCHEDULE     SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# nightly-backup   17 2 * * *   False     1        3d              30d

# Which job is stuck?
kubectl get cronjob -n batch nightly-backup -o jsonpath='{.status.active}' | jq
kubectl get jobs -n batch --sort-by=.metadata.creationTimestamp | tail -5
```

The countermeasure is `activeDeadlineSeconds` in the `jobTemplate.spec`, so a hung run kills itself and lets the schedule resume:

```yaml
  jobTemplate:
    spec:
      activeDeadlineSeconds: 3600     # nothing may run past an hour
```

### Concurrency Policy Is Per CronJob Only

`Forbid` prevents overlap **within one CronJob**. It does nothing about a manually triggered Job or a different CronJob doing the same work. Application level locking (an advisory lock in the database, a lease object) is the only defence against those.

---

## startingDeadlineSeconds and Missed Schedules

### What It Does

```yaml
spec:
  startingDeadlineSeconds: 300
```

If the controller cannot start a Job at its scheduled time (the controller was down, the API server was unreachable, an admission webhook rejected the create), `startingDeadlineSeconds` says how late it may still start.

```
┌───────────────────────────────────────────────────────────────────┐
│              startingDeadlineSeconds: 300 (5 minutes)             │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  02:00 scheduled time                                             │
│  02:00 ─────────────────────► 02:05    deadline window            │
│                                                                   │
│  Controller recovers at 02:03 ──► job STARTS (3 min late)         │
│  Controller recovers at 02:07 ──► run is SKIPPED (past deadline)  │
│                                                                   │
│  Field NOT set ──► no deadline; a recovering controller will      │
│                    start a missed run no matter how late,         │
│                    subject to the 100 missed schedule rule.       │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### The 100 Missed Schedules Rule

Every time it evaluates a CronJob, the controller counts how many scheduled start times have been missed. If that count exceeds **100**, it gives up and records an error instead of starting anything:

```
Cannot determine if job needs to be started. Too many missed start time (> 100).
Set or decrease .spec.startingDeadlineSeconds or check clock skew.
```

The counting window depends on `startingDeadlineSeconds`:

| `startingDeadlineSeconds` | Counting window | Practical effect |
|--------------------------|-----------------|------------------|
| Not set | From `status.lastScheduleTime` to now | A long outage on a frequent schedule easily exceeds 100 |
| Set to `N` | The last `N` seconds only | Bounded; the count can never blow past 100 for sane values |

```
┌───────────────────────────────────────────────────────────────────┐
│      Why the field matters: schedule "*/1 * * * *"                │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  WITHOUT startingDeadlineSeconds                                  │
│    Controller down for 2 hours ──► 120 missed schedules           │
│    120 > 100 ──► CronJob is now WEDGED. It will not fire again    │
│    until you intervene, even after the controller recovers.       │
│                                                                   │
│  WITH startingDeadlineSeconds: 120                                │
│    Only the last 120 seconds are examined ──► 2 missed schedules  │
│    2 < 100 ──► one run starts immediately, schedule resumes.      │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

**Always set `startingDeadlineSeconds`** on frequent schedules. A value comfortably larger than one schedule interval, but far smaller than the interval times 100, is the sweet spot.

| Schedule | Suggested `startingDeadlineSeconds` |
|----------|-------------------------------------|
| `* * * * *` (1 min) | 60 to 180 |
| `*/5 * * * *` | 300 to 600 |
| `0 * * * *` (hourly) | 600 to 1800 |
| `0 2 * * *` (daily) | 3600 |

### Unwedging a Stuck CronJob

```bash
# The error appears in events
kubectl describe cronjob -n batch frequent-task | sed -n '/Events/,$p'
# Warning  FailedNeedsStart  Cannot determine if job needs to be started:
#          Too many missed start time (> 100)...

# Fix 1: set a bounded deadline so the count window shrinks
kubectl patch cronjob -n batch frequent-task \
  -p '{"spec":{"startingDeadlineSeconds":200}}'

# Fix 2: clear the stale lastScheduleTime by recreating the object
kubectl get cronjob -n batch frequent-task -o yaml > cj.yaml
kubectl delete cronjob -n batch frequent-task
kubectl apply -f cj.yaml
```

Also check for **clock skew**. The error message mentions it explicitly because a node whose clock is far ahead makes the controller believe an enormous number of schedules were missed.

```bash
# Compare clocks across nodes
for n in $(kubectl get nodes -o name); do echo "$n"; done
timedatectl status          # run on each node
chronyc tracking            # if chrony is the NTP client
```

### A Deadline Is Not a Timeout

`startingDeadlineSeconds` bounds **how late a Job may start**. It says nothing about how long the Job may run. That is `jobTemplate.spec.activeDeadlineSeconds`. Confusing the two is extremely common.

---

## Suspending CronJobs

```yaml
spec:
  suspend: true
```

`suspend: true` stops the controller from creating **new** Jobs. Jobs that are already running are **not** touched.

```bash
# Pause scheduling
kubectl patch cronjob -n batch nightly-backup -p '{"spec":{"suspend":true}}'

kubectl get cronjob -n batch
# NAME             SCHEDULE     SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# nightly-backup   17 2 * * *   True      0        8h              30d

# Resume
kubectl patch cronjob -n batch nightly-backup -p '{"spec":{"suspend":false}}'

# Suspend every cronjob in a namespace (maintenance window)
kubectl get cronjobs -n batch -o name | \
  xargs -I{} kubectl patch {} -n batch -p '{"spec":{"suspend":true}}'
```

Note the difference from Job suspension: a suspended **Job** has its active Pods deleted, whereas a suspended **CronJob** simply stops scheduling and leaves any in-flight Job alone.

On resume, missed schedules are subject to `startingDeadlineSeconds` and the 100 missed schedule rule. Suspending a `* * * * *` CronJob for two hours without a starting deadline set will wedge it exactly as an outage would.

Use suspension for maintenance windows, incident response (stop a job that is hammering a dependency), and for staging a CronJob that should exist but not yet run.

---

## History Limits

```yaml
spec:
  successfulJobsHistoryLimit: 3     # default 3
  failedJobsHistoryLimit: 1         # default 1
```

The controller keeps this many finished Jobs of each outcome and deletes older ones. Deleting a Job cascades to its Pods, which takes the logs with it.

```
┌───────────────────────────────────────────────────────────────────┐
│         successfulJobsHistoryLimit: 3, failed: 1 (defaults)       │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  Retained:                                                        │
│    backup-28901234  Complete   (newest success)                   │
│    backup-28900794  Complete                                      │
│    backup-28900354  Complete   (oldest retained success)          │
│    backup-28899914  Failed     (newest failure)                   │
│                                                                   │
│  Deleted automatically:                                           │
│    everything older, plus their pods, plus their LOGS             │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Tuning

| Setting | Effect | Use when |
|---------|--------|----------|
| `successfulJobsHistoryLimit: 0` | Successful Jobs deleted immediately | High frequency schedules, logs shipped externally |
| `successfulJobsHistoryLimit: 3` | Default; a few recent successes kept | General purpose |
| `failedJobsHistoryLimit: 1` | Default; only the most recent failure kept | Often too few for debugging |
| `failedJobsHistoryLimit: 5` to `10` | Several failures retained | Anything you need to diagnose after the fact |

**Raise `failedJobsHistoryLimit`.** The default of 1 means a failure that recurs every five minutes leaves you with only the most recent instance, which may not be the informative one. Failures are exactly what you want to keep.

A `* * * * *` schedule with the defaults creates and deletes Job and Pod objects continuously, which is real churn against the API server and etcd. For very frequent schedules, set `successfulJobsHistoryLimit: 0` and rely on external log aggregation.

### History Limits vs ttlSecondsAfterFinished

Two independent cleanup mechanisms with different triggers:

| Mechanism | Where it is set | Trigger | Scope |
|-----------|-----------------|---------|-------|
| `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` | CronJob spec | Count based; the oldest is deleted when the limit is exceeded | Jobs of this CronJob only |
| `ttlSecondsAfterFinished` | `jobTemplate.spec` | Time based; deleted N seconds after finishing | Any Job |

They can be combined. Setting `ttlSecondsAfterFinished: 86400` alongside `successfulJobsHistoryLimit: 3` means "keep at most 3, and in any case delete after a day". Whichever fires first wins.

---

## Idempotency Requirements

The CronJob controller provides **at least once** semantics for schedule ticks, not exactly once. The official guidance is explicit: a CronJob creates a Job approximately once per execution time of its schedule, and under some circumstances it may create two Jobs or none.

```
┌───────────────────────────────────────────────────────────────────┐
│             Why a Run Can Happen Twice or Zero Times              │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  TWICE                                                            │
│    • A controller restart between creating the Job and updating   │
│      status could re-attempt the same tick.                       │
│    • A DST fall-back repeats a local wall clock time.             │
│    • Someone manually triggers a run that overlaps a scheduled    │
│      one, and concurrencyPolicy is Allow.                         │
│    • Job-level retries re-run the same work after a partial       │
│      failure.                                                     │
│                                                                   │
│  ZERO TIMES                                                       │
│    • Controller outage longer than startingDeadlineSeconds.       │
│    • concurrencyPolicy: Forbid with the previous run still going. │
│    • More than 100 missed schedules.                              │
│    • A DST spring-forward erases the scheduled local time.        │
│    • suspend was left true.                                       │
│                                                                   │
│  THEREFORE: the workload MUST be idempotent, and you MUST         │
│  alert on runs that did not happen.                               │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Designing Idempotent Scheduled Work

**1. Derive a deterministic key from the logical period, not from "now".**

```bash
# Fragile: two runs at 23:59:59 and 00:00:01 produce different keys
OUTPUT="report-$(date +%Y%m%d-%H%M%S).csv"

# Robust: both runs of the same nightly tick target the same object
PERIOD="$(date -u +%Y-%m-%d)"
OUTPUT="report-${PERIOD}.csv"
if aws s3 ls "s3://bucket/reports/${OUTPUT}" >/dev/null 2>&1; then
  echo "Report for ${PERIOD} already exists, nothing to do"
  exit 0
fi
```

**2. Prefer upserts and conditional writes over blind inserts.**

```sql
INSERT INTO daily_rollup (period, total)
VALUES ('2025-09-05', 41220)
ON CONFLICT (period) DO UPDATE SET total = EXCLUDED.total;
```

**3. Take an application level lock for work that truly cannot overlap.**

`concurrencyPolicy: Forbid` protects you from the CronJob's own overlap. It does not protect you from a manual trigger, a second cluster, or a human running the script by hand. A Lease object or a database advisory lock does.

```yaml
# The job's ServiceAccount needs RBAC to manage a Lease for locking
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: backup-lock
  namespace: batch
rules:
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "create", "update"]
```

**4. Make partial progress resumable.** Write a checkpoint, and on start, resume from it. A Job that is killed by `activeDeadlineSeconds` or a preemption must not have to redo everything.

**5. Never assume the previous run succeeded.** Read the actual state rather than an implied one.

### Idempotency Checklist

| Question | If the answer is no |
|----------|---------------------|
| Does running it twice produce the same result? | Add a deterministic key and an existence check |
| Does it tolerate being killed halfway? | Add checkpointing |
| Does it tolerate the previous run having been skipped? | Process a range, not just "since last run" |
| Does it tolerate concurrent execution? | Add a lease or advisory lock |
| Does it fail loudly on a bad result? | Fix the exit codes; silent success is worse than failure |

---

## Manually Triggering a CronJob

The supported way to run a CronJob's workload immediately is to create a Job from its template.

```bash
# Create a one-off job from the cronjob's jobTemplate
kubectl create job manual-backup-001 --from=cronjob/nightly-backup -n batch

# Watch it
kubectl get job -n batch manual-backup-001 -w
kubectl logs -n batch job/manual-backup-001 -f

# Clean up when done
kubectl delete job -n batch manual-backup-001
```

Important properties of `--from`:

| Property | Behaviour |
|----------|-----------|
| Job template | Copied from `cronjob.spec.jobTemplate` at the moment of creation |
| Ownership | The new Job is **not** owned by the CronJob |
| History limits | Do not apply; the manual Job is never auto-deleted by the CronJob controller |
| `concurrencyPolicy` | Does **not** apply; a manual run can overlap a scheduled one |
| `status.active` | The manual Job does not appear there |
| Name | You choose it; use a timestamp so repeat triggers do not collide |

```bash
# Unique name pattern for repeated manual runs
kubectl create job "manual-backup-$(date +%s)" \
  --from=cronjob/nightly-backup -n batch
```

Because `concurrencyPolicy` is bypassed, a manual trigger during a scheduled run gives you two concurrent executions even with `Forbid`. Check first:

```bash
kubectl get cronjob -n batch nightly-backup -o jsonpath='{.status.active}' | jq
```

### Testing a Schedule Quickly

To validate that the manifest works without waiting for 02:00:

```bash
# 1. Manual trigger validates the job template and the workload
kubectl create job test-run --from=cronjob/nightly-backup -n batch

# 2. Temporarily accelerate the schedule to validate the SCHEDULING path
kubectl patch cronjob -n batch nightly-backup -p '{"spec":{"schedule":"*/1 * * * *"}}'
kubectl get jobs -n batch -w
# ... observe, then restore
kubectl patch cronjob -n batch nightly-backup -p '{"spec":{"schedule":"17 2 * * *"}}'
```

Do the accelerated test in a non production namespace when the workload has side effects.

---

## Monitoring and Alerting

A CronJob that stops running produces **no signal at all** by default. Absence of an event is not an event. Monitoring scheduled work therefore has to be built around two questions: did the run happen, and did it succeed.

### The Status Fields to Watch

```bash
kubectl get cronjob -n batch nightly-backup -o jsonpath='{.status}' | jq
# {
#   "active": [],
#   "lastScheduleTime": "2025-09-05T02:17:00Z",
#   "lastSuccessfulTime": "2025-09-05T02:23:41Z"
# }
```

| Field | Meaning | Alert on |
|-------|---------|----------|
| `status.lastScheduleTime` | When a Job was last **created** | Too old relative to the schedule: the CronJob is not firing |
| `status.lastSuccessfulTime` | When a Job last **completed successfully** | Too old, or much older than `lastScheduleTime`: runs are failing |
| `status.active` | Jobs currently running | Non empty for far longer than a normal run: a hang |

The gap between `lastScheduleTime` and `lastSuccessfulTime` is the single most useful derived signal. If they diverge, jobs are being created but not succeeding.

### Practical Checks

```bash
# Any cronjob whose last successful run is older than 26 hours
kubectl get cronjobs -A -o json | jq -r --arg cutoff \
  "$(date -u -d '26 hours ago' +%Y-%m-%dT%H:%M:%SZ)" '
  .items[]
  | select((.status.lastSuccessfulTime // "1970-01-01T00:00:00Z") < $cutoff)
  | "\(.metadata.namespace)/\(.metadata.name) last_success=\(.status.lastSuccessfulTime // "never")"'

# Any cronjob that has never scheduled anything
kubectl get cronjobs -A -o json | jq -r '
  .items[] | select(.status.lastScheduleTime == null)
  | "\(.metadata.namespace)/\(.metadata.name) NEVER SCHEDULED"'

# Suspended cronjobs (often suspended for an incident and forgotten)
kubectl get cronjobs -A -o json | jq -r '
  .items[] | select(.spec.suspend == true)
  | "\(.metadata.namespace)/\(.metadata.name) SUSPENDED"'

# Failed jobs owned by a cronjob
kubectl get jobs -A -o json | jq -r '
  .items[]
  | select((.status.failed // 0) > 0)
  | select(.metadata.ownerReferences[]? .kind == "CronJob")
  | "\(.metadata.namespace)/\(.metadata.name) failed=\(.status.failed)"'
```

### Events

```bash
kubectl get events -n batch \
  --field-selector involvedObject.kind=CronJob \
  --sort-by=.lastTimestamp
```

| Event reason | Meaning |
|--------------|---------|
| `SuccessfulCreate` | A Job was created for a schedule tick |
| `SuccessfulDelete` | An old Job was pruned by the history limits, or replaced |
| `JobAlreadyActive` | A run was skipped because of `concurrencyPolicy: Forbid` |
| `MissingJob` | A Job listed in `status.active` no longer exists |
| `FailedNeedsStart` | The controller could not determine whether to start; usually the 100 missed schedules error |
| `UnexpectedJob` | A Job matched the CronJob but was not created by it |

Events are short lived (typically one hour of retention). Ship them to a log system if you want to reason about them after the fact.

### Metrics

If you run kube-state-metrics, the relevant series are:

| Metric | Use |
|--------|-----|
| `kube_cronjob_status_last_schedule_time` | Detect a CronJob that stopped firing |
| `kube_cronjob_status_active` | Detect a run stuck active |
| `kube_cronjob_spec_suspend` | Detect a forgotten suspension |
| `kube_job_status_failed` | Detect failing runs |
| `kube_job_status_succeeded` | Confirm successful runs |
| `kube_job_complete` / `kube_job_failed` | Job completion conditions |

Two alert shapes are worth building:

1. **Freshness alert.** `time() - kube_cronjob_status_last_schedule_time > expected_interval * 2`. Catches a CronJob that silently stopped.
2. **Failure alert.** A failed Job owned by a CronJob within the last N minutes. Catches runs that happen but do not work.

### Dead Man's Switch

The most robust pattern for critical scheduled work is a **push based heartbeat**: the job itself reports success to an external watchdog, and the watchdog alerts on the **absence** of that report.

```yaml
          containers:
          - name: backup
            image: registry.example.com/backup:1.2
            command:
            - /bin/sh
            - -c
            - |
              set -euo pipefail
              /app/backup --target="${TARGET}" --verify
              # Only reached if the backup genuinely succeeded.
              curl -fsS --retry 3 --max-time 15 "${HEARTBEAT_URL}"
```

This inverts the failure mode. Cluster wide problems (controller down, namespace deleted, quota exhausted, CronJob suspended and forgotten) all produce the same observable symptom: no heartbeat. In-cluster monitoring cannot detect a CronJob that no longer exists; an external watchdog can.

---

## Inspecting CronJobs

```bash
# Overview
kubectl get cronjobs -A
# NAMESPACE  NAME             SCHEDULE     TIMEZONE  SUSPEND  ACTIVE  LAST SCHEDULE  AGE
# batch      nightly-backup   17 2 * * *   Etc/UTC   False    0       8h             30d
# batch      hourly-sync      0 * * * *    Etc/UTC   False    1       12m            30d

# Full detail plus events
kubectl describe cronjob -n batch nightly-backup

# Effective configuration
kubectl get cronjob -n batch nightly-backup -o jsonpath='
schedule:  {.spec.schedule}
timeZone:  {.spec.timeZone}
concurrency: {.spec.concurrencyPolicy}
deadline:  {.spec.startingDeadlineSeconds}
suspend:   {.spec.suspend}
{"\n"}'
```

### Finding a CronJob's Jobs and Pods

There is no label linking a Job back to its CronJob, so use the owner reference:

```bash
# Jobs owned by a specific cronjob
kubectl get jobs -n batch -o json | jq -r '
  .items[]
  | select(.metadata.ownerReferences[]? .name == "nightly-backup")
  | "\(.metadata.name) \(.status.succeeded // 0)/\(.spec.completions // 1)"'

# Newest job of that cronjob, then its logs
JOB=$(kubectl get jobs -n batch -o json | jq -r '
  [.items[] | select(.metadata.ownerReferences[]? .name == "nightly-backup")]
  | sort_by(.metadata.creationTimestamp) | last | .metadata.name')
kubectl logs -n batch "job/${JOB}"

# All pods from that job
kubectl get pods -n batch -l "job-name=${JOB}"
```

### Schedule History

```bash
# Jobs in creation order gives you the run history
kubectl get jobs -n batch --sort-by=.metadata.creationTimestamp
# NAME                      STATUS      COMPLETIONS   DURATION   AGE
# nightly-backup-28899914   Failed      0/1           11m        3d
# nightly-backup-28900354   Complete    1/1           6m12s      2d
# nightly-backup-28900794   Complete    1/1           5m47s      1d
# nightly-backup-28901234   Complete    1/1           6m41s      8h
```

Remember this history is truncated by `successfulJobsHistoryLimit` and `failedJobsHistoryLimit`. It is a recent window, not an audit trail.

---

## Troubleshooting

### Symptom 1: CronJob Never Fires

```bash
kubectl get cronjob -n batch my-cron
# NAME      SCHEDULE     SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# my-cron   0 2 * * *    False     0        <none>          5d
```

`LAST SCHEDULE` of `<none>` after more than one interval means nothing has ever been created. Work through this list in order:

```bash
# 1. Is it suspended?
kubectl get cronjob -n batch my-cron -o jsonpath='{.spec.suspend}{"\n"}'

# 2. Is the schedule what you think it is, in the timezone you think?
kubectl get cronjob -n batch my-cron -o jsonpath='{.spec.schedule} {.spec.timeZone}{"\n"}'

# 3. What does the controller say?
kubectl describe cronjob -n batch my-cron | sed -n '/Events/,$p'

# 4. Is the controller manager healthy?
kubectl get pods -n kube-system -l component=kube-controller-manager
kubectl logs -n kube-system -l component=kube-controller-manager --tail=200 | grep -i cronjob

# 5. Clock skew on control plane nodes?
kubectl get nodes -o wide
# then on each control plane node:
timedatectl status
```

| Finding | Fix |
|---------|-----|
| `suspend: true` | Patch it to false |
| Schedule means something else than intended | Correct the expression; watch the dom/dow OR rule |
| Timezone is not what you assumed | Set `spec.timeZone` explicitly |
| `FailedNeedsStart` / too many missed start times | Set `startingDeadlineSeconds`, or recreate the object |
| Controller manager not running | Fix the control plane; nothing schedules without it |
| Clock skew | Fix NTP on the control plane nodes |

### Symptom 2: FailedNeedsStart, Too Many Missed Start Times

```bash
kubectl describe cronjob -n batch frequent-task | sed -n '/Events/,$p'
# Warning  FailedNeedsStart  Cannot determine if job needs to be started:
#          Too many missed start time (> 100). Set or decrease
#          .spec.startingDeadlineSeconds or check clock skew
```

The CronJob is wedged and will not recover on its own. Fix it as described in [startingDeadlineSeconds and Missed Schedules](#startingdeadlineseconds-and-missed-schedules): set a bounded `startingDeadlineSeconds`, and if `status.lastScheduleTime` is still far in the past, recreate the object to clear it.

### Symptom 3: Jobs Are Created but Pods Never Appear

```bash
kubectl get jobs -n batch --sort-by=.metadata.creationTimestamp | tail -3
# my-cron-28901234   0/1   3m   3m

kubectl describe job -n batch my-cron-28901234 | sed -n '/Events/,$p'
```

The problem is at the Job to Pod boundary, not the schedule. Usual causes:

| Event | Cause | Fix |
|-------|-------|-----|
| `FailedCreate ... exceeded quota` | ResourceQuota exhausted | Raise the quota, or reduce requests |
| `FailedCreate ... violates PodSecurity` | Pod Security Admission rejects the Pod spec | Fix the `securityContext`, or change the namespace label |
| `FailedCreate ... admission webhook denied` | A validating or mutating webhook | Read the webhook's message; check the webhook is healthy |
| `FailedCreate ... serviceaccount not found` | The named ServiceAccount does not exist | Create it |

```bash
kubectl describe resourcequota -n batch
kubectl get ns batch --show-labels | grep pod-security
kubectl get validatingwebhookconfigurations
```

### Symptom 4: Pods Created but Immediately Failing

```bash
kubectl get pods -n batch -l job-name=my-cron-28901234
# my-cron-28901234-x7f2k   0/1   CreateContainerConfigError   0   1m

kubectl describe pod -n batch my-cron-28901234-x7f2k | sed -n '/Events/,$p'
kubectl logs -n batch my-cron-28901234-x7f2k
kubectl logs -n batch my-cron-28901234-x7f2k --previous
```

Apply the Job troubleshooting playbook from [jobs.md](jobs.md#troubleshooting). The most frequent CronJob specific version is a missing Secret or ConfigMap that was renamed after the CronJob was written: the CronJob object stays valid, and only the runs fail.

```bash
kubectl get cronjob -n batch my-cron -o json \
  | jq -r '.spec.jobTemplate.spec.template.spec.containers[].env[]?
           | select(.valueFrom) | .valueFrom'
kubectl get secret,configmap -n batch
```

### Symptom 5: ACTIVE Stuck at 1, No New Runs

```bash
kubectl get cronjob -n batch nightly-backup
# NAME             SCHEDULE     SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# nightly-backup   17 2 * * *   False     1        3d              60d
```

With `concurrencyPolicy: Forbid`, one hung Job blocks every subsequent run, silently.

```bash
# Identify the stuck job
kubectl get cronjob -n batch nightly-backup -o jsonpath='{.status.active}' | jq
kubectl get jobs -n batch --sort-by=.metadata.creationTimestamp | tail -3

# Look at what it is doing
kubectl logs -n batch job/nightly-backup-28899914 --tail=100
kubectl get pods -n batch -l job-name=nightly-backup-28899914 -o wide

# Unblock: delete the stuck job
kubectl delete job -n batch nightly-backup-28899914

# Prevent recurrence: give every run a hard time limit
kubectl patch cronjob -n batch nightly-backup \
  -p '{"spec":{"jobTemplate":{"spec":{"activeDeadlineSeconds":3600}}}}'
```

Also check `status.active` for entries pointing at Jobs that no longer exist, which shows up as a `MissingJob` event and can leave a phantom active count.

### Symptom 6: Runs Happening Twice

```bash
kubectl get jobs -n batch --sort-by=.metadata.creationTimestamp | tail -6
```

Check, in order:

- Is `concurrencyPolicy` set to `Allow` (the default) with a job that runs longer than the interval?
- Was a manual `kubectl create job --from=` run alongside a scheduled one? Manual Jobs bypass `concurrencyPolicy`.
- Is the same CronJob deployed in two namespaces or two clusters pointing at the same backend?
- Is it a DST fall-back duplicate on a local time zone?
- Is `backoffLimit` retrying after a partial success, so the work is repeated?

```bash
kubectl get cronjob -n batch my-cron -o jsonpath='{.spec.concurrencyPolicy}{"\n"}'
kubectl get cronjobs -A | grep my-cron
```

The durable fix is idempotency, not just tightening the policy.

### Symptom 7: Runs Silently Skipped

```bash
kubectl describe cronjob -n batch my-cron | grep -i -E 'JobAlreadyActive|FailedNeedsStart'
```

Two mechanisms skip silently:

- `concurrencyPolicy: Forbid` with a previous run still active, producing `JobAlreadyActive`.
- A missed schedule outside `startingDeadlineSeconds`, producing no event at all in some cases.

Because these are silent, the only reliable detection is monitoring `status.lastScheduleTime` freshness, or an external dead man's switch.

### Symptom 8: Logs Disappeared Before Investigation

```bash
kubectl logs -n batch job/my-cron-28899914
# Error from server (NotFound): jobs.batch "my-cron-28899914" not found
```

The Job was pruned by `failedJobsHistoryLimit` (default 1) or by `ttlSecondsAfterFinished`.

```bash
kubectl get cronjob -n batch my-cron \
  -o jsonpath='{.spec.successfulJobsHistoryLimit} {.spec.failedJobsHistoryLimit}{"\n"}'

# Retain more failures for debugging
kubectl patch cronjob -n batch my-cron \
  -p '{"spec":{"failedJobsHistoryLimit":10}}'
```

The real fix is log aggregation. Pod logs are ephemeral by design; if a scheduled job's output matters, it must leave the cluster.

### Symptom 9: Job Name Rejected as Too Long

```bash
kubectl apply -f cronjob.yaml
# The CronJob "..." is invalid: metadata.name: Invalid value: ...
# must be no more than 52 characters
```

Shorten the CronJob name. The 11 character time suffix appended to the generated Job name must fit within the 63 character DNS label limit.

### Symptom 10: Wrong Time of Day

```bash
kubectl get cronjob -n batch my-cron \
  -o jsonpath='{.spec.schedule} tz={.spec.timeZone}{"\n"}'
kubectl get cronjob -n batch my-cron -o jsonpath='{.status.lastScheduleTime}{"\n"}'
```

`status.lastScheduleTime` is reported in UTC. Convert it and compare against what you expected:

```bash
date -u -d "2025-09-05T02:17:00Z"
date    -d "2025-09-05T02:17:00Z"    # in your local zone
```

If `spec.timeZone` is unset, the schedule is interpreted in the controller's time zone, which is very often UTC while the author was thinking in local time. Set `timeZone` explicitly to remove the ambiguity.

---

## Exam and Interview Traps

1. **`apiVersion: batch/v1`** for CronJob, the same group and version as Job.
2. **Cron has five fields and no seconds field.** One minute is the finest resolution.
3. **Day of week: Sunday is 0.** Some implementations also accept 7 for Sunday, but 0 is the portable value.
4. **When both day-of-month and day-of-week are restricted, they are OR'd, not AND'd.** `0 2 15 * 1` fires on the 15th **or** on Mondays.
5. **`?` means the same as `*`** in the day fields.
6. **The nesting is `spec.jobTemplate.spec.template.spec`.** `backoffLimit` goes under `jobTemplate.spec`; `restartPolicy` goes under `jobTemplate.spec.template.spec`.
7. **`jobTemplate` has no `apiVersion` or `kind`.** It is a bare `JobTemplateSpec`.
8. **`concurrencyPolicy` defaults to `Allow`**, which lets runs pile up. `Forbid` skips the new run; `Replace` kills the old one.
9. **`Forbid` skips silently**, so a hung Job blocks the schedule forever unless `activeDeadlineSeconds` is set on the job template.
10. **`concurrencyPolicy` does not apply to manually created Jobs.** `kubectl create job --from=cronjob/x` bypasses it entirely.
11. **`startingDeadlineSeconds` bounds how late a run may START.** It is not a run duration timeout; that is `jobTemplate.spec.activeDeadlineSeconds`.
12. **More than 100 missed schedules wedges the CronJob** with a `FailedNeedsStart` error. Setting `startingDeadlineSeconds` bounds the counting window and prevents it.
13. **`successfulJobsHistoryLimit` defaults to 3 and `failedJobsHistoryLimit` defaults to 1.** Raise the failed limit; one retained failure is rarely enough to debug with.
14. **Deleting a Job deletes its Pods and therefore its logs.** History limits and `ttlSecondsAfterFinished` both do this.
15. **The CronJob name must be 52 characters or fewer**, because the generated Job name appends an 11 character suffix inside a 63 character limit.
16. **Suspending a CronJob stops new Jobs but does not stop a running one.** Contrast with `suspend` on a Job, which deletes its active Pods.
17. **Without `spec.timeZone`, the schedule uses the kube-controller-manager's time zone**, which is usually UTC. Always set it explicitly.
18. **`timeZone` takes IANA names** such as `America/New_York`, never abbreviations such as `EST`.
19. **CronJobs give at least once semantics.** A run can happen twice or not at all, so the workload must be idempotent.
20. **`kubectl create job --from=cronjob/<name>` is the supported manual trigger**, and the resulting Job is not owned by the CronJob and is not pruned by its history limits.
21. **There is no label linking a Job to its CronJob.** Use `metadata.ownerReferences` to find them.
22. **A CronJob that stops firing emits no alert of its own.** Monitor `status.lastScheduleTime` freshness, or use an external dead man's switch.

---

## Related Topics

- [Jobs](jobs.md)
- [Pods](pods.md)
- [Controllers](controllers.md)
- [DaemonSets](daemonsets.md)
- [StatefulSets](statefulsets.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-apiserver](kube-apiserver.md)
- [kubectl](kubectl.md)
- [Imperative Kubernetes](imperative-kubernetes.md)
- [Kubernetes API](k8s-api.md)
- [Control Plane Node](control-plane-node.md)
- [CoreDNS](coredns.md)

---

## Key Takeaways

1. A CronJob creates **Jobs**, which create **Pods**. Understanding that three level ownership chain is the key to debugging: the failure is at the schedule level, the Job level, or the Pod level, and each has different diagnostics.
2. The schedule is standard five field cron with **no seconds field**, supports `*`, `?`, `,`, `-` and `/`, and accepts the `@yearly`, `@monthly`, `@weekly`, `@daily` and `@hourly` macros.
3. **When both day-of-month and day-of-week are restricted, they are combined with OR**, which is the most misread rule in cron syntax anywhere.
4. Without `spec.timeZone`, schedules are interpreted in the **kube-controller-manager's time zone**. Set `timeZone` explicitly with an IANA name, and prefer `Etc/UTC` to avoid daylight saving skips and duplicates.
5. `concurrencyPolicy` defaults to **`Allow`**, which lets long running jobs pile up. `Forbid` is the right default for backups and migrations; `Replace` suits jobs where only the newest result matters.
6. **`Forbid` skips silently.** A single hung Job blocks every subsequent run indefinitely, so always set `activeDeadlineSeconds` in the job template.
7. `startingDeadlineSeconds` bounds how late a missed run may still start, and critically it also bounds the **missed schedule counting window**. Exceeding 100 missed schedules wedges the CronJob with `FailedNeedsStart`.
8. `suspend: true` stops new Jobs being created but leaves any running Job alone, unlike `suspend` on a Job which deletes active Pods.
9. `successfulJobsHistoryLimit` (default 3) and `failedJobsHistoryLimit` (default 1) prune old Jobs and take their Pods and logs with them. Raise the failed limit, and ship logs off cluster.
10. The CronJob name is limited to **52 characters** because the generated Job name appends a time derived suffix within the 63 character DNS label limit.
11. CronJobs provide **at least once** semantics: a run can occur twice or not at all. Scheduled work must be idempotent, using deterministic period keys, upserts, application level locks and resumable checkpoints.
12. `kubectl create job <name> --from=cronjob/<name>` is the supported manual trigger. The resulting Job is independent: not owned by the CronJob, not pruned by its history limits, and **not** subject to `concurrencyPolicy`.
13. Jobs carry no label pointing back at their CronJob; use `metadata.ownerReferences` to correlate them.
14. Monitor the gap between `status.lastScheduleTime` and `status.lastSuccessfulTime`, alert on staleness of both, and for anything business critical add an external dead man's switch, because a CronJob that silently stops firing produces no in-cluster signal at all.

---

## References

- [CronJob concept](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
- [Running Automated Tasks with a CronJob](https://kubernetes.io/docs/tasks/job/automated-tasks-with-cron-jobs/)
- [Jobs concept](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [Automatic Cleanup for Finished Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/)
- [Garbage Collection and Owner References](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
- [Object Names and IDs](https://kubernetes.io/docs/concepts/overview/working-with-objects/names/)
- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [kubectl create job reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-job-em-)
- [CronJob API reference (batch/v1)](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/cron-job-v1/)
