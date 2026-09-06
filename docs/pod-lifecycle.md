# 🔄 Kubernetes Pod Lifecycle

The complete birth to death sequence of a Pod: admission, scheduling, sandbox creation, image pulls, init ordering, probes, hooks, graceful shutdown, eviction and preemption, with the exact phases, conditions, states and reason strings the system reports along the way.

## 📋 Table of Contents

- [The Big Picture](#the-big-picture)
- [Stage 1: Admission Through the API Server](#stage-1-admission-through-the-api-server)
- [Stage 2: Scheduling](#stage-2-scheduling)
- [Stage 3: The Kubelet Sync Loop](#stage-3-the-kubelet-sync-loop)
- [Stage 4: Sandbox Creation via CRI](#stage-4-sandbox-creation-via-cri)
- [Stage 5: Image Pulling](#stage-5-image-pulling)
- [Stage 6: Init Containers](#stage-6-init-containers)
- [Stage 7: Main Containers and postStart](#stage-7-main-containers-and-poststart)
- [Stage 8: Running Steady State](#stage-8-running-steady-state)
- [Pod Phases](#pod-phases)
- [Pod Conditions](#pod-conditions)
- [Container States and Reason Strings](#container-states-and-reason-strings)
- [restartPolicy and CrashLoopBackOff](#restartpolicy-and-crashloopbackoff)
- [Probes in Full Depth](#probes-in-full-depth)
- [Init Containers vs Native Sidecars](#init-containers-vs-native-sidecars)
- [Lifecycle Hooks: postStart and preStop](#lifecycle-hooks-poststart-and-prestop)
- [Graceful Shutdown End to End](#graceful-shutdown-end-to-end)
- [Force Deletion and Its Dangers](#force-deletion-and-its-dangers)
- [Node Pressure Eviction](#node-pressure-eviction)
- [API Initiated Eviction and PodDisruptionBudget](#api-initiated-eviction-and-poddisruptionbudget)
- [Preemption](#preemption)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The Big Picture

```
                      POD LIFECYCLE: BIRTH TO DEATH

  ┌───────────────────────────────────────────────────────────────────┐
  │ CONTROL PLANE                                                      │
  │                                                                    │
  │  kubectl apply ──▶ kube-apiserver                                  │
  │                      │ 1. AuthN / AuthZ                            │
  │                      │ 2. Mutating admission webhooks              │
  │                      │ 3. Schema validation + defaulting           │
  │                      │ 4. Validating admission webhooks            │
  │                      │ 5. Persist to etcd                          │
  │                      ▼                                             │
  │                   Pod object exists                                │
  │                   phase = Pending, spec.nodeName = ""              │
  │                      │                                             │
  │                      ▼                                             │
  │  kube-scheduler ──▶ Filter (predicates) ──▶ Score (priorities)     │
  │                      │                                             │
  │                      ▼ Bind: POST /pods/<name>/binding             │
  │                   spec.nodeName = worker-02                        │
  │                   condition PodScheduled = True                    │
  └──────────────────────────────┬────────────────────────────────────┘
                                 │ watch event
  ┌──────────────────────────────▼────────────────────────────────────┐
  │ NODE: worker-02                                                    │
  │                                                                    │
  │  kubelet syncLoop                                                  │
  │    ├─ admission checks (capacity, OS, sysctls, AppArmor)           │
  │    ├─ create pod cgroup slice                                      │
  │    ├─ mount volumes (volume manager: attach, WaitForAttach, mount) │
  │    ├─ CRI: PullImage (sandbox image if absent)                     │
  │    ├─ CRI: RunPodSandbox ─▶ pause container                        │
  │    │        └─ CNI ADD ─▶ veth, Pod IP, routes                     │
  │    │        condition PodReadyToStartContainers = True             │
  │    ├─ init containers, SEQUENTIALLY, each to exit 0                │
  │    │        condition Initialized = True                           │
  │    ├─ regular containers, IN PARALLEL                              │
  │    │        CRI: CreateContainer ─▶ StartContainer                 │
  │    │        postStart hook (concurrent with ENTRYPOINT)            │
  │    ├─ startup probe ─▶ then liveness + readiness probes            │
  │    │        condition ContainersReady = True                       │
  │    │        condition Ready = True  ─▶ eligible Service endpoint   │
  │    │                                                               │
  │    ├──────── STEADY STATE: probes, restarts, status updates ───────│
  │    │                                                               │
  │  DELETE arrives                                                    │
  │    ├─ deletionTimestamp set, phase still Running, STATUS Terminating│
  │    ├─ EndpointSlice controller removes the Pod (in parallel!)      │
  │    ├─ preStop hook per container                                   │
  │    ├─ SIGTERM to PID 1 of each container                           │
  │    ├─ terminationGracePeriodSeconds countdown                      │
  │    ├─ SIGKILL to anything still alive                              │
  │    ├─ native sidecars terminated last, in reverse order            │
  │    ├─ CRI: RemovePodSandbox ─▶ CNI DEL ─▶ IP released              │
  │    ├─ volumes unmounted, cgroup slice removed                      │
  │    └─ kubelet sends delete with gracePeriod=0                      │
  │              ▼                                                     │
  │        API server removes the object from etcd                     │
  └────────────────────────────────────────────────────────────────────┘
```

---

## Stage 1: Admission Through the API Server

Before a Pod exists as an object, the request passes through a fixed pipeline. Each step can reject it.

```
POST /api/v1/namespaces/production/pods
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Authentication      client certs, bearer tokens, OIDC     │
│                        → 401 if it fails                     │
├─────────────────────────────────────────────────────────────┤
│ 2. Authorization       RBAC (or ABAC / Node / Webhook)       │
│                        → 403 if the verb/resource is denied  │
├─────────────────────────────────────────────────────────────┤
│ 3. Mutating admission  built in plugins, then                │
│                        MutatingAdmissionWebhooks             │
│    Common mutations:                                         │
│      • ServiceAccount plugin injects serviceAccountName,     │
│        the projected token volume and imagePullSecrets       │
│      • DefaultStorageClass, DefaultTolerationSeconds         │
│      • LimitRanger injects default requests/limits           │
│      • Sidecar injectors (service mesh) add containers       │
├─────────────────────────────────────────────────────────────┤
│ 4. Schema validation   OpenAPI structural validation,        │
│                        field defaulting                      │
│    Defaults applied here include:                            │
│      restartPolicy: Always                                   │
│      dnsPolicy: ClusterFirst                                 │
│      terminationGracePeriodSeconds: 30                       │
│      schedulerName: default-scheduler                        │
│      imagePullPolicy (from the tag)                          │
│      terminationMessagePath: /dev/termination-log             │
├─────────────────────────────────────────────────────────────┤
│ 5. Validating admission  ResourceQuota, Pod Security         │
│                          admission, ValidatingAdmission-     │
│                          Webhooks / ValidatingAdmissionPolicy│
├─────────────────────────────────────────────────────────────┤
│ 6. Persist to etcd     the object now has a UID,             │
│                        resourceVersion and creationTimestamp │
└─────────────────────────────────────────────────────────────┘
```

At the end of this stage the Pod exists with `status.phase: Pending` and no `spec.nodeName`. Nothing is running anywhere.

```bash
# See exactly what admission changed
kubectl apply -f pod.yaml --dry-run=server -o yaml | diff - <(cat pod.yaml) | head -50

# Failures at this stage produce an immediate error, not a Pending Pod:
#   Error from server (Forbidden): pods "x" is forbidden:
#     violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false
```

See [Kubernetes API](k8s-api.md) and [kube-apiserver](kube-apiserver.md).

---

## Stage 2: Scheduling

The scheduler watches for Pods with an empty `spec.nodeName` and a `schedulerName` it owns.

```
┌──────────────────────────────────────────────────────────────┐
│  Scheduling cycle (one Pod at a time, from the queue)         │
│                                                               │
│  PreFilter ─▶ Filter ─▶ PostFilter ─▶ PreScore ─▶ Score       │
│                 │           │                        │        │
│                 │           │ (only if Filter left   │        │
│                 │           │  zero feasible nodes:  │        │
│                 │           │  preemption runs here) │        │
│                 ▼                                    ▼        │
│      Nodes that CANNOT run the Pod           Rank survivors    │
│      are eliminated:                         0..100 per        │
│        • insufficient allocatable            plugin, weighted  │
│        • taint not tolerated                                   │
│        • nodeSelector / nodeAffinity mismatch                  │
│        • hostPort conflict                                     │
│        • volume zone / topology conflict                       │
│        • node not Ready, unschedulable                         │
│        • pod anti-affinity violated                            │
│        • topology spread maxSkew exceeded                      │
│                                                               │
│  ─▶ Reserve ─▶ Permit ─▶ PreBind ─▶ Bind ─▶ PostBind          │
│                                      │                        │
│                                      ▼                        │
│                       POST /api/v1/namespaces/<ns>/pods/      │
│                            <name>/binding                     │
└──────────────────────────────────────────────────────────────┘
```

On success the API server sets `spec.nodeName` and the Pod gains:

```yaml
status:
  conditions:
    - type: PodScheduled
      status: "True"
```

On failure the Pod stays `Pending` and gains:

```yaml
status:
  conditions:
    - type: PodScheduled
      status: "False"
      reason: Unschedulable
      message: "0/5 nodes are available: 3 Insufficient cpu,
                2 node(s) had untolerated taint {dedicated: gpu}."
```

That `message` is the single most useful diagnostic for a `Pending` Pod, and it is visible with `kubectl describe pod` as a `FailedScheduling` event.

The scheduler is skipped entirely when `spec.nodeName` is set in the manifest, and for static pods. See [kube-scheduler](kube-scheduler.md).

---

## Stage 3: The Kubelet Sync Loop

The kubelet on the target node receives the Pod through its watch and enters its sync loop.

```
┌───────────────────────────────────────────────────────────────┐
│  kubelet syncLoop: three sources merged into one channel       │
│                                                                │
│    API server watch  ──┐                                       │
│    static pod files  ──┼──▶ PodConfig ──▶ syncLoop            │
│    HTTP endpoint     ──┘                                       │
│                                     │                          │
│                                     ▼                          │
│              dispatch to a per-Pod goroutine (podWorker)       │
│                                     │                          │
│                                     ▼                          │
│                                 syncPod()                      │
│                                                                │
│  Also feeding syncLoop:                                        │
│    PLEG (Pod Lifecycle Event Generator)                        │
│      relists containers from CRI on a short interval and       │
│      emits ContainerStarted / ContainerDied / ContainerRemoved │
│      → this is how the kubelet notices a crash                 │
│    housekeeping ticker  → cleans up orphaned pods/volumes      │
│    periodic full resync → reconciles drift                     │
└───────────────────────────────────────────────────────────────┘
```

`syncPod` is idempotent and reconciles the observed state against the spec:

1. **Pod admission on the node.** Rejects the Pod if the node lacks capacity (`OutOfcpu`, `OutOfmemory`, `OutOfpods`), the OS does not match, requested sysctls are not allowed, or the node is being drained. A rejected Pod goes to phase `Failed` with reason `OutOfcpu` and stays there; it is never retried on that node.
2. **Create the Pod cgroup.** A slice under `kubepods.slice` matching the QoS class, for example `kubepods-burstable-pod<uid>.slice`. See [Cgroups](cgroups.md).
3. **Wait for volumes.** The volume manager attaches (for attachable volumes), waits for the device, formats if needed, and mounts. Failures surface as `FailedAttachVolume` or `FailedMount` events and the Pod is stuck in `ContainerCreating`.
4. **Fetch secrets and configmaps** referenced by the Pod.
5. **Ensure the sandbox exists**, creating it if not.
6. **Compute the container actions**: which to start, which to kill, which to restart.
7. **Update status** back to the API server through the `pods/status` subresource.

A well known kubelet failure mode is `PLEG is not healthy`, reported as a node condition. It means the relist call to the container runtime has not completed within its threshold, usually because the runtime is overloaded or hung. Every Pod on that node then appears frozen.

See [Kubelet](kubelet.md).

---

## Stage 4: Sandbox Creation via CRI

```
kubelet                          container runtime (containerd / CRI-O)
   │
   │── RunPodSandbox(config) ──────────▶
   │                                     create the pause container
   │                                       → new net, ipc, uts namespaces
   │                                       → apply the pod cgroup parent
   │                                     invoke the CNI plugin (ADD)
   │                                       → veth pair, move one end in
   │                                       → IPAM allocates the Pod IP
   │                                       → routes, iptables/eBPF program
   │◀───────────── sandboxID, IP ────────
   │
   │  condition PodReadyToStartContainers = True
   │  status.podIP / status.podIPs populated
```

Everything before this point is invisible in `kubectl logs` because no application container exists yet. The Pod shows `STATUS: ContainerCreating`.

The sandbox is what makes container restarts cheap: only `CreateContainer` and `StartContainer` are repeated. `RunPodSandbox` happens once per Pod (or again after a sandbox is destroyed, for example on a node reboot, which is why the Pod IP can change after a node restart).

Common failure signatures at this stage:

```
FailedCreatePodSandBox  ... failed to setup network for sandbox ...
                            plugin type="calico" failed: ...
FailedCreatePodSandBox  ... no IP addresses available in range set ...
FailedCreatePodSandBox  ... failed to get sandbox image "registry.k8s.io/pause:3.x" ...
```

The last one is a classic air gapped cluster problem: the sandbox image is pulled by the runtime using the runtime's own configuration, not the Pod's `imagePullSecrets`.

See [Pause Containers](pause-containers.md), [CNI](cni.md), [Container Runtime](container-runtime.md).

---

## Stage 5: Image Pulling

```
For each container image, in the order the containers are started:
   │
   ├─ imagePullPolicy == Never       → use local, else ErrImageNeverPull
   ├─ imagePullPolicy == IfNotPresent→ ImageStatus; pull only if absent
   ├─ imagePullPolicy == Always      → always contact the registry
   │                                   (a matching digest still avoids
   │                                    re-downloading layers)
   │
   ├─ credentials resolved from:
   │     spec.imagePullSecrets
   │     the ServiceAccount's imagePullSecrets
   │     node level credential providers / config
   │
   ├─ Event: Pulling  "Pulling image \"nginx:1.27\""
   ├─ Event: Pulled   "Successfully pulled image ... in 4.12s"
   │
   └─ on failure:  ErrImagePull  ──(retry with backoff)──▶ ImagePullBackOff
```

Notes that matter:

- Image pulls are serialised per node by default. `--serialize-image-pulls=false` in the kubelet config allows parallel pulls, bounded by `--max-parallel-image-pulls`.
- A failing pull retries with the same exponential backoff used for container restarts, which is why the reason flips from `ErrImagePull` to `ImagePullBackOff`.
- `ImagePullBackOff` is a **waiting** state, so the Pod stays `Pending`.
- Large images are the number one cause of slow Pod starts. Requests and limits do not apply to the pull, but `ephemeral-storage` pressure does.

---

## Stage 6: Init Containers

```
┌──────────────────────────────────────────────────────────────────┐
│  sandbox ready                                                    │
│        │                                                          │
│        ▼                                                          │
│  ┌───────────┐  exit 0   ┌───────────┐  exit 0   ┌───────────┐   │
│  │ init[0]   │──────────▶│ init[1]   │──────────▶│ init[2]   │   │
│  └─────┬─────┘           └─────┬─────┘           └─────┬─────┘   │
│        │ exit != 0             │ exit != 0             │ exit 0  │
│        ▼                       ▼                       ▼         │
│  restartPolicy:          restartPolicy:          Initialized=True│
│    Always    → restart with backoff                    │         │
│    OnFailure → restart with backoff                    ▼         │
│    Never     → Pod phase = Failed          regular containers    │
│                (no retry at all)           start IN PARALLEL     │
└──────────────────────────────────────────────────────────────────┘
```

Rules:

- Strictly sequential, in declaration order. There is no parallelism.
- Each must exit `0`. A non zero exit is a failure.
- With `restartPolicy: Never`, one failed init container ends the Pod. `kubectl get pods` shows `Init:Error` or `Init:CrashLoopBackOff`.
- The `STATUS` column reads `Init:0/3`, `Init:1/3` and so on while they run, then `PodInitializing` in the gap before regular containers report.
- Init container restarts also count in the `RESTARTS` column.
- Init containers cannot have `livenessProbe`, `readinessProbe`, `startupProbe` or `lifecycle` hooks, unless they carry `restartPolicy: Always` and are therefore native sidecars.

```bash
# Watch init progress
kubectl get pod myapp -w
# NAME    READY   STATUS     RESTARTS   AGE
# myapp   0/1     Init:0/2   0          3s
# myapp   0/1     Init:1/2   0          12s
# myapp   0/1     PodInitializing  0    18s
# myapp   1/1     Running    0          21s

# Logs of a specific init container
kubectl logs myapp -c wait-for-db

# Init container statuses in full
kubectl get pod myapp -o jsonpath='{.status.initContainerStatuses}' | jq
```

---

## Stage 7: Main Containers and postStart

Once `Initialized` is True, **all** regular containers are created and started in parallel. There is no ordering guarantee between them; that is precisely the gap native sidecars close.

```
For each regular container:
   CRI: CreateContainer  (rootfs, mounts, env, cgroup, security context)
   CRI: StartContainer   (exec the ENTRYPOINT/command)
        │
        ├──────────────▶ container process runs
        │
        └──────────────▶ postStart hook fires
                          • runs CONCURRENTLY with the ENTRYPOINT
                          • NO guarantee it runs before the entrypoint
                          • the container is NOT marked Running until
                            the hook completes
                          • if the hook fails, the container is KILLED
                            and restarted per restartPolicy
                          • hook output is not in kubectl logs;
                            failures appear as a FailedPostStartHook event
```

Failures at container creation, before the process ever starts:

| Reason | Meaning |
|--------|---------|
| `CreateContainerConfigError` | A referenced ConfigMap, Secret or key does not exist |
| `CreateContainerError` | The runtime rejected the container config (bad mount, bad device, bad user) |
| `RunContainerError` | The process could not be executed (bad `command`, missing binary, not executable) |
| `InvalidImageName` | The image reference is malformed |

---

## Stage 8: Running Steady State

```
┌────────────────────────────────────────────────────────────────┐
│  Steady state loops running per Pod                             │
│                                                                 │
│  probe workers (one goroutine per probe per container)          │
│     startup  → gates liveness and readiness until it succeeds   │
│     liveness → failure means RESTART the container              │
│     readiness→ failure means REMOVE from Service endpoints      │
│                                                                 │
│  PLEG relist → detects exits and emits events                   │
│                                                                 │
│  status manager → PATCHes pods/status when anything changed     │
│                                                                 │
│  cgroup enforcement (kernel, continuous)                        │
│     cpu.max      → throttling when over the CPU limit           │
│     memory.max   → OOM kill when over the memory limit          │
│                                                                 │
│  eviction manager → watches node signals, may evict this Pod    │
└────────────────────────────────────────────────────────────────┘
```

---

## Pod Phases

`status.phase` is a single coarse value. It is a **summary**, not a health signal.

| Phase | Definition | Typical STATUS strings you will see |
|-------|-----------|-------------------------------------|
| `Pending` | Accepted by the cluster but not all containers are running. Includes waiting for scheduling, image pull, volume mount, and init containers. | `Pending`, `ContainerCreating`, `Init:0/2`, `ImagePullBackOff`, `CreateContainerConfigError` |
| `Running` | Bound to a node, all containers created, at least one is running, starting or restarting. | `Running`, `CrashLoopBackOff`, `Error`, `Terminating` |
| `Succeeded` | All containers terminated successfully and none will be restarted. | `Completed` |
| `Failed` | All containers terminated and at least one failed (non zero exit or terminated by the system). | `Error`, `OOMKilled`, `DeadlineExceeded`, `Evicted` |
| `Unknown` | The Pod state could not be obtained, typically a communication failure with the node. | `Unknown` |

```
       ┌─────────┐
       │ Pending │
       └────┬────┘
            │ sandbox + init + containers started
            ▼
       ┌─────────┐
   ┌───│ Running │───┐
   │   └─────────┘   │
   │                 │
   ▼                 ▼
┌───────────┐   ┌────────┐
│ Succeeded │   │ Failed │      terminal, no transitions out
└───────────┘   └────────┘

  restartPolicy: Always   → Succeeded and Failed are UNREACHABLE by exit
  restartPolicy: OnFailure→ Succeeded reachable; Failed only via the
                            system (deadline, eviction, node shutdown)
  restartPolicy: Never    → both reachable
```

⚠ **`CrashLoopBackOff` is not a phase.** The Pod is in phase `Running`; the container is in state `waiting` with reason `CrashLoopBackOff`. Likewise `Terminating` is not a phase; it is what `kubectl` prints when `metadata.deletionTimestamp` is set.

---

## Pod Conditions

Conditions are the fine grained, machine readable gates. Each has `type`, `status` (`True`/`False`/`Unknown`), `reason`, `message` and `lastTransitionTime`.

| Type | True when | Who sets it |
|------|-----------|-------------|
| `PodScheduled` | The Pod is bound to a node | kube-scheduler |
| `PodReadyToStartContainers` | The sandbox exists and network is configured (formerly named `PodHasNetwork`) | kubelet |
| `Initialized` | All init containers completed successfully | kubelet |
| `ContainersReady` | Every container reports `ready: true` | kubelet |
| `Ready` | `ContainersReady` is True **and** all `readinessGates` are True | kubelet |
| `DisruptionTarget` | The Pod is about to be terminated by disruption. `reason` is one of `PreemptionByScheduler`, `DeletionByTaintManager`, `EvictionByEvictionAPI`, `DeletionByPodGC`, `TerminationByKubelet` | scheduler, node controller, eviction API, kubelet |

### Phase vs Condition: Why They Are Different

```
Pod phase says:      "Running"        ← the container process exists
Pod condition says:  Ready = False    ← but it must not receive traffic

Only the CONDITION drives Service endpoints.
`kubectl get pods` READY column shows 1/1 only when ContainersReady is True.
```

A Pod that is `Running 0/1` is up but excluded from every Service. Automation that waits on `status.phase == Running` will send traffic to a broken app. Correct waits:

```bash
kubectl wait --for=condition=Ready pod/myapp --timeout=120s
kubectl wait --for=condition=Initialized pod/myapp --timeout=60s
```

### Readiness Gates

```yaml
spec:
  readinessGates:
    - conditionType: "example.com/load-balancer-registered"
```

An external controller writes that condition into `status.conditions`. Until it is `True`, `Ready` stays `False` even if every container passes its readiness probe. Cloud load balancer controllers use this so that a Pod is only considered Ready after the external LB has actually registered and health checked it.

---

## Container States and Reason Strings

Each entry in `status.containerStatuses[]` has exactly one of three states.

```yaml
state:
  waiting:   {reason: ..., message: ...}
  # or
  running:   {startedAt: ...}
  # or
  terminated: {exitCode: ..., reason: ..., signal: ...,
               startedAt: ..., finishedAt: ..., containerID: ...,
               message: ...}
```

`lastState` holds the **previous** termination, which is where a crash loop's real cause lives.

### Waiting Reasons

| Reason | Meaning | First thing to do |
|--------|---------|-------------------|
| `ContainerCreating` | Sandbox or container is being set up | `describe` for volume/CNI events |
| `PodInitializing` | Init containers finished, regular containers starting | Usually transient |
| `ErrImagePull` | The pull just failed | Check image name, tag, registry auth |
| `ImagePullBackOff` | Retrying the pull with backoff | Same, plus check `imagePullSecrets` |
| `ErrImageNeverPull` | `imagePullPolicy: Never` and the image is not on the node | Preload the image or change the policy |
| `InvalidImageName` | Malformed reference (uppercase repo, bad characters) | Fix the string |
| `CrashLoopBackOff` | The container keeps exiting; kubelet is waiting before the next restart | `kubectl logs --previous` |
| `CreateContainerConfigError` | Missing ConfigMap, Secret or key | `describe` names the missing object |
| `CreateContainerError` | Runtime rejected the config | Bad mount path, bad user, bad device |
| `RunContainerError` | Could not exec the entrypoint | Wrong `command`, binary missing, wrong arch |
| `CreateContainerConfigError` | Also raised for an invalid `securityContext` combination | Check `runAsNonRoot` vs an image whose USER is root |

### Terminated Reasons and Exit Codes

| Reason | exitCode | Meaning |
|--------|----------|---------|
| `Completed` | `0` | Clean exit |
| `Error` | non zero | The application failed |
| `OOMKilled` | `137` | The kernel killed it for exceeding the memory limit (128 + SIGKILL 9) |
| `Error` | `143` | Terminated by SIGTERM (128 + 15), usually a normal shutdown that the app reported as failure |
| `Error` | `139` | SIGSEGV (128 + 11), segmentation fault |
| `Error` | `126` | Command found but not executable |
| `Error` | `127` | Command not found. Check `command` and the image contents |
| `ContainerStatusUnknown` | n/a | The kubelet lost track of the container, typically after a node problem |
| `DeadlineExceeded` | n/a | `activeDeadlineSeconds` expired (Pod level reason) |
| `Evicted` | n/a | Node pressure eviction (Pod level reason) |
| `Shutdown` | n/a | Graceful node shutdown terminated the Pod (Pod level reason) |
| `NodeAffinity` | n/a | The Pod no longer matches the node, cleaned up by Pod GC |

```bash
# The exact reason and exit code for the CURRENT state
kubectl get pod myapp -o jsonpath='{.status.containerStatuses[0].state}' | jq

# The reason for the PREVIOUS crash, which is what you actually want
kubectl get pod myapp -o jsonpath='{.status.containerStatuses[0].lastState}' | jq
```

---

## restartPolicy and CrashLoopBackOff

### restartPolicy Semantics

`spec.restartPolicy` is Pod wide, immutable, and defaults to `Always`.

| Value | Container exits 0 | Container exits non zero |
|-------|-------------------|--------------------------|
| `Always` | Restart | Restart |
| `OnFailure` | Do **not** restart | Restart |
| `Never` | Do **not** restart | Do **not** restart |

Which controllers permit which values:

| Controller | Allowed `restartPolicy` |
|------------|------------------------|
| Deployment / ReplicaSet / DaemonSet / StatefulSet / ReplicationController | `Always` only |
| Job / CronJob | `OnFailure` or `Never` (`Always` is rejected) |
| Bare Pod | Any of the three |

"Restart" always means **recreate the container inside the existing sandbox**. The Pod keeps its name, UID and IP. `emptyDir` contents survive. The container's writable layer does **not** survive; it is a fresh container from the image.

### The Backoff Schedule

The kubelet applies exponential backoff to restarts of a failing container:

```
Restart #   Delay before the next start attempt
─────────   ───────────────────────────────────
    1        10s
    2        20s
    3        40s
    4        80s     (1m20s)
    5       160s     (2m40s)
    6       300s     (5m0s)   ← CAP
    7+      300s     (stays at the 5 minute cap)
```

The delay starts at 10 seconds, doubles each time, and is capped at 5 minutes. The counter resets after the container has run successfully for 10 minutes. Some recent Kubernetes releases expose feature gates to reduce the initial delay and to make the maximum tunable per node; check your cluster's kubelet configuration before assuming the classic values.

`CrashLoopBackOff` is the **waiting state during that delay**, not the crash itself. The container is not running and no new logs are produced, which is exactly why `--previous` is essential.

```
timeline of a crash loop
────────────────────────────────────────────────────────────────
run(2s) crash │ wait 10s │ run(2s) crash │ wait 20s │ run crash │
              └ backoff ─┘               └ backoff ─┘
STATUS:  Error → CrashLoopBackOff → Error → CrashLoopBackOff → ...
RESTARTS: 1                          2                         3
```

```bash
# The RESTARTS column carries the age of the last restart
kubectl get pods
# NAME    READY   STATUS             RESTARTS        AGE
# myapp   0/1     CrashLoopBackOff   7 (2m41s ago)   23m
```

`7 (2m41s ago)` means seven restarts and the most recent one was 2 minutes 41 seconds ago, which lines up with the 5 minute cap being in effect.

### Common Causes, Ranked

1. The application exits immediately (bad config, missing env var, unreachable dependency at startup).
2. The container has no long running process. A Pod running `busybox` with no `command` exits instantly with code 0, and with `restartPolicy: Always` that becomes a crash loop of successful exits.
3. A failing **liveness probe** restarting a healthy but slow application.
4. `OOMKilled`, visible in `lastState.terminated.reason`.
5. A failing `postStart` hook.
6. Wrong CPU architecture (`exec format error`).

---

## Probes in Full Depth

### The Three Probe Types

```
┌──────────────────────────────────────────────────────────────────┐
│ startupProbe                                                      │
│   Question: "Has this container finished booting?"                │
│   On failure (after failureThreshold): KILL the container,        │
│     then restartPolicy applies.                                   │
│   While it is running: liveness and readiness probes are          │
│     DISABLED and do not count failures.                           │
│   Purpose: give slow starting apps a long boot window WITHOUT     │
│     weakening the liveness probe for the rest of their life.      │
├──────────────────────────────────────────────────────────────────┤
│ livenessProbe                                                     │
│   Question: "Is this container wedged and beyond recovery?"       │
│   On failure: KILL the container, then restartPolicy applies.     │
│   NOT for dependency checking. A liveness probe that fails        │
│     because the database is down restarts every replica in a      │
│     loop and turns a partial outage into a total one.             │
├──────────────────────────────────────────────────────────────────┤
│ readinessProbe                                                    │
│   Question: "Should this container receive traffic right now?"    │
│   On failure: REMOVE the Pod from Service endpoints. The          │
│     container is NOT restarted.                                   │
│   Recovers automatically when the probe succeeds again.           │
│   THIS is where dependency checks belong.                         │
└──────────────────────────────────────────────────────────────────┘
```

### Handler Types

```yaml
# 1. exec: success == exit code 0. Runs INSIDE the container, costs a process.
livenessProbe:
  exec:
    command: ["/bin/sh", "-c", "test -f /tmp/healthy"]

# 2. httpGet: success == HTTP status >= 200 and < 400.
readinessProbe:
  httpGet:
    path: /readyz
    port: 8080            # number or a named containerPort
    scheme: HTTP          # HTTP (default) or HTTPS
    host: ""              # defaults to the Pod IP; rarely set
    httpHeaders:
      - name: X-Probe
        value: kubelet

# 3. tcpSocket: success == the kubelet can open a TCP connection.
livenessProbe:
  tcpSocket:
    port: 5432

# 4. grpc: uses the standard gRPC Health Checking Protocol.
readinessProbe:
  grpc:
    port: 9000
    service: "readiness"   # optional; the service name in the health request
```

Important detail: `httpGet` and `tcpSocket` probes are executed **by the kubelet from the node**, targeting the Pod IP. They do not traverse a Service and they are not subject to the Pod's own `dnsPolicy`. `exec` probes run inside the container namespace and are the most expensive; a busy Pod with a 1 second `exec` probe period can spend measurable CPU on forking.

An `httpGet` probe with `scheme: HTTPS` does **not** validate the certificate.

### Every Timing Field

| Field | Default | Minimum | Meaning |
|-------|---------|---------|---------|
| `initialDelaySeconds` | `0` | `0` | Wait this long after the container starts before the first probe |
| `periodSeconds` | `10` | `1` | Interval between probes |
| `timeoutSeconds` | `1` | `1` | How long a single probe may take before it counts as a failure |
| `successThreshold` | `1` | `1` | Consecutive successes needed to flip from failure to success. **Must be 1** for liveness and startup probes |
| `failureThreshold` | `3` | `1` | Consecutive failures needed to declare failure |
| `terminationGracePeriodSeconds` | inherits the Pod value | `1` | Probe level override used when the probe kills the container |

### Worked Timing Example

```yaml
livenessProbe:
  httpGet: {path: /healthz, port: 8080}
  initialDelaySeconds: 15
  periodSeconds: 10
  timeoutSeconds: 2
  failureThreshold: 3
```

```
t=0s    container process starts
t=15s   probe #1  (first probe, after initialDelaySeconds)
t=25s   probe #2
t=35s   probe #3
...
Suppose the app wedges just after t=35s:
t=45s   probe #4  FAIL (1/3)
t=55s   probe #5  FAIL (2/3)
t=65s   probe #6  FAIL (3/3)  → threshold reached
t=65s   kubelet kills the container, event "Liveness probe failed"
        restartPolicy applies; backoff schedule starts

WORST CASE detection latency after the app wedges:
  periodSeconds * failureThreshold + timeoutSeconds
  = 10 * 3 + 2 = 32 seconds
(plus up to periodSeconds of jitter before the first failing probe)
```

For a **startup probe**, the maximum permitted boot time is:

```
maximum_startup_time = failureThreshold * periodSeconds
```

```yaml
startupProbe:
  httpGet: {path: /healthz, port: 8080}
  failureThreshold: 30
  periodSeconds: 10
# → the app gets up to 300 seconds to boot.
# After the FIRST success, the startup probe stops running forever and
# liveness/readiness take over with their own aggressive settings.
```

### The Complete Recommended Pattern

```yaml
containers:
  - name: app
    image: registry.example.com/app:v2
    ports:
      - name: http
        containerPort: 8080

    # Slow boot: JVM warmup, cache load, migrations.
    startupProbe:
      httpGet: {path: /healthz, port: http}
      failureThreshold: 30
      periodSeconds: 10          # up to 5 minutes to start

    # Cheap, dependency free liveness check. Only detects a wedged process.
    livenessProbe:
      httpGet: {path: /healthz, port: http}
      periodSeconds: 10
      timeoutSeconds: 2
      failureThreshold: 3

    # Dependency aware. Removes from endpoints, never restarts.
    readinessProbe:
      httpGet: {path: /readyz, port: http}
      periodSeconds: 5
      timeoutSeconds: 2
      failureThreshold: 2
      successThreshold: 1
```

### Probe Antipatterns

| Antipattern | Why it hurts | Fix |
|-------------|-------------|-----|
| Liveness probe checks the database | One DB blip restarts every replica simultaneously, guaranteeing a full outage | Dependencies belong in the **readiness** probe |
| Liveness and readiness point at the same endpoint | Any dependency failure becomes a restart loop | Two endpoints: `/healthz` (self only) and `/readyz` (dependencies) |
| Huge `initialDelaySeconds` on the liveness probe | The window applies for the container's whole life, so real hangs go undetected for minutes | Use a `startupProbe` instead |
| `timeoutSeconds: 1` on a slow endpoint | Random false failures under load, restarts under exactly the conditions where you need stability | Raise the timeout, and make the endpoint cheap |
| `failureThreshold: 1` on liveness | A single transient blip restarts the container | Keep at least 3 |
| No readiness probe at all | Traffic arrives before the app can serve, giving 502s on every rollout | Always define readiness for anything behind a Service |
| Readiness probe that reports the app's dependencies as unready forever | The Deployment rollout stalls and never completes | Bound the check; do not fail on optional dependencies |
| `exec` probe running a heavyweight script every second | Measurable CPU cost and PID churn | Prefer `httpGet` or `tcpSocket` |
| Probes on a container that also has `hostNetwork: true` and a duplicated port | Probe hits the wrong process | Verify the port actually belongs to this container |

---

## Init Containers vs Native Sidecars

A **native sidecar** is an entry in `spec.initContainers` with `restartPolicy: Always`.

```
Ordinary init container                 Native sidecar
────────────────────────                ─────────────────────────
runs, exits 0, is gone                  starts, KEEPS RUNNING
blocks the next init container          the next init container
until it EXITS                            starts once it is STARTED
no probes allowed                       startup/liveness/readiness allowed
no lifecycle hooks                      postStart and preStop allowed
request counted as max(inits)           request SUMMED with regular containers
n/a                                     terminated AFTER all regular
                                          containers, in reverse order
n/a                                     does NOT block Job completion
```

```
┌────────────────────────────────────────────────────────────────┐
│  Startup order with a native sidecar                            │
│                                                                 │
│  init[0] "migrate"   ──run to exit 0──┐                         │
│                                        ▼                        │
│  init[1] "proxy" (restartPolicy: Always)                        │
│      started, startupProbe succeeds ───┐                        │
│                                         ▼                       │
│  containers: "app"  starts (proxy already serving)              │
│                                                                 │
│  Shutdown order (exact reverse for sidecars)                    │
│                                                                 │
│  "app" gets preStop + SIGTERM ─▶ exits                          │
│                                  ▼                              │
│  "proxy" gets preStop + SIGTERM ─▶ exits                        │
└────────────────────────────────────────────────────────────────┘
```

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: batch-with-sidecar
spec:
  template:
    spec:
      restartPolicy: OnFailure
      initContainers:
        - name: log-shipper
          image: fluent/fluent-bit:3.0
          restartPolicy: Always          # native sidecar
          volumeMounts:
            - {name: logs, mountPath: /input}
      containers:
        - name: worker
          image: registry.example.com/worker:v1
          volumeMounts:
            - {name: logs, mountPath: /var/log/worker}
      volumes:
        - name: logs
          emptyDir: {}
```

Before native sidecars, this Job would never complete: the Job controller waits for **all** containers to terminate, and the log shipper never exits. With the sidecar in `initContainers`, the kubelet terminates it once `worker` finishes and the Job reaches `Succeeded`.

The `SidecarContainers` feature progressed through alpha and beta and is stable in modern Kubernetes releases; on older clusters verify the feature gate before relying on it.

---

## Lifecycle Hooks: postStart and preStop

```yaml
lifecycle:
  postStart:
    exec:
      command: ["/bin/sh", "-c", "echo started > /tmp/ready"]
  preStop:
    exec:
      command: ["/bin/sh", "-c", "nginx -s quit; sleep 5"]
```

Handler types: `exec`, `httpGet`, and `sleep` (a dedicated sleep action added in recent releases behind the `PodLifecycleSleepAction` feature gate; use the `exec` + `sleep` form if your cluster does not have it). `tcpSocket` exists in the API for historical reasons but is not usefully supported for hooks.

| | `postStart` | `preStop` |
|---|---|---|
| When | Immediately after `StartContainer` | Immediately before SIGTERM is sent |
| Concurrency | Runs **concurrently** with the ENTRYPOINT; no ordering guarantee | Runs **before** SIGTERM, blocking it |
| Blocking effect | The container is not marked `Running` until it returns | Consumes the termination grace period |
| On failure | The container is killed and restarted per `restartPolicy`; event `FailedPostStartHook` | Event `FailedPreStopHook`; termination continues |
| Delivery | **At least once**: it may execute more than once | **At least once**, and it is skipped entirely if the container has already terminated |
| Logs | Not in `kubectl logs`; only Events | Not in `kubectl logs`; only Events |

### The preStop Sleep Trick

This is the single most valuable operational pattern in this document.

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 15"]
```

or, with the dedicated action:

```yaml
lifecycle:
  preStop:
    sleep:
      seconds: 15
```

Why it is needed: when a Pod is deleted, **two independent things happen in parallel**, and neither waits for the other.

```
       t=0  DELETE received
             │
   ┌─────────┴──────────────────────────────┐
   │                                        │
   ▼ CONTROL PLANE PATH                     ▼ NODE PATH
 EndpointSlice controller removes         kubelet starts termination
 the Pod's endpoint                       immediately
   │                                        │
   ▼                                        ▼
 kube-proxy on EVERY node must            preStop hook, then SIGTERM
 observe the change and rewrite            │
 its iptables / IPVS / eBPF rules          ▼
   │                                      app stops accepting
   ▼                                      connections
 external LBs and ingress controllers
 must also converge
   │
   ▼
 T + (hundreds of ms to several seconds)

 ⚠ RACE: during that window, traffic is still being sent to a Pod
   that has already begun shutting down  →  connection refused / 502
```

The `preStop` sleep holds SIGTERM back long enough for endpoint removal to propagate everywhere. The container keeps serving during the sleep because its process is untouched. 5 to 20 seconds is the usual range.

Crucially: **the sleep must be shorter than `terminationGracePeriodSeconds`**, and the grace period must also cover the app's own drain time.

```yaml
spec:
  terminationGracePeriodSeconds: 60    # 15s sleep + up to 45s to drain
  containers:
    - name: app
      lifecycle:
        preStop:
          exec: {command: ["/bin/sh", "-c", "sleep 15"]}
```

---

## Graceful Shutdown End to End

```
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 0   kubectl delete pod myapp                                     │
│          (or a rollout, a scale down, a drain, an eviction)           │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 1   API server sets metadata.deletionTimestamp and               │
│          metadata.deletionGracePeriodSeconds.                         │
│          The object is NOT removed. kubectl now prints "Terminating". │
│          The Pod's phase is still Running.                            │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 2   TWO THINGS HAPPEN IN PARALLEL                                │
│                                                                       │
│   (a) EndpointSlice controller removes the Pod from all Services.     │
│       kube-proxy on each node reprograms its rules. Ingress           │
│       controllers and cloud LBs converge on their own schedule.       │
│                                                                       │
│   (b) The kubelet begins Pod termination. It does NOT wait for (a).   │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 3   The grace period countdown STARTS NOW.                       │
│          Default 30s, from spec.terminationGracePeriodSeconds,        │
│          overridable per delete request with --grace-period.          │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 4   preStop hook runs in each regular container (if defined).    │
│          This consumes the grace period.                              │
│          If it is still running when the period expires, the kubelet  │
│          grants a one off 2 second extension, then proceeds.          │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 5   SIGTERM is delivered to PID 1 of each container.             │
│          ⚠ If PID 1 is a shell (`sh -c "..."`), the shell usually     │
│            does NOT forward the signal to your app. Use exec form.    │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 6   The application should now:                                  │
│            • stop accepting new connections                           │
│            • finish in flight requests                                │
│            • flush buffers, close DB connections, release locks       │
│            • exit 0                                                   │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 7   Grace period expires. SIGKILL to anything still alive.       │
│          SIGKILL cannot be caught. Exit code 137.                     │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 8   Native sidecars are terminated AFTER all regular containers, │
│          in reverse declaration order, each with its own preStop.     │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 9   CRI: StopContainer for each, then RemovePodSandbox.          │
│          CNI DEL releases the Pod IP. Volumes unmounted and detached. │
│          The pod cgroup slice is removed.                             │
├──────────────────────────────────────────────────────────────────────┤
│ STEP 10  kubelet issues a delete with gracePeriodSeconds=0.           │
│          Any remaining finalizers must be cleared.                    │
│          The API server removes the object from etcd. It is gone.     │
└──────────────────────────────────────────────────────────────────────┘
```

### The Signal Forwarding Problem

```yaml
# ❌ BAD: PID 1 is /bin/sh. It does not forward SIGTERM to the app.
#         The app never drains and is SIGKILLed after 30 seconds.
command: ["/bin/sh", "-c", "/usr/bin/myapp --serve"]

# ✅ GOOD: exec replaces the shell, so the app IS PID 1.
command: ["/bin/sh", "-c", "exec /usr/bin/myapp --serve"]

# ✅ BEST: no shell at all.
command: ["/usr/bin/myapp"]
args: ["--serve"]
```

Verify:

```bash
kubectl exec myapp -- ps -o pid,comm
#   PID COMMAND
#     1 myapp        ← correct
#     1 sh           ← broken, the app is a child
```

### Testing Graceful Shutdown

```bash
# Watch the whole sequence
kubectl get pod myapp -w &

# Delete and observe how long termination actually takes
time kubectl delete pod myapp

# If it takes exactly terminationGracePeriodSeconds, your app is being
# SIGKILLed and is NOT handling SIGTERM.

# Check the exit code of the previous instance
kubectl get pod myapp -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq
# exitCode 137 after a delete → SIGKILL → shutdown was not graceful
# exitCode 0                  → clean exit → correct
```

---

## Force Deletion and Its Dangers

```bash
kubectl delete pod myapp --grace-period=0 --force
```

What this actually does:

1. Sets the grace period to 0.
2. The API server removes the Pod object from etcd **immediately**, without waiting for the kubelet to confirm anything.
3. `kubectl` prints a warning: the Pod may continue to run on the node.

```
┌────────────────────────────────────────────────────────────────┐
│  ⚠ THE DANGER                                                   │
│                                                                 │
│  API server view:            Node reality:                      │
│    Pod is GONE                 container may still be RUNNING   │
│                                still holding a volume            │
│                                still writing to a database       │
│                                still holding a distributed lock  │
│                                                                 │
│  Meanwhile the controller sees the Pod as gone and creates a     │
│  REPLACEMENT immediately.                                        │
│                                                                 │
│  For a StatefulSet this is the classic split brain:              │
│    mysql-0 (old, still alive, node unreachable)                  │
│    mysql-0 (new, scheduled elsewhere, same PVC identity)         │
│  Two writers, one volume. Data corruption.                       │
└────────────────────────────────────────────────────────────────┘
```

Legitimate uses:

- The node is confirmed powered off or destroyed and will never come back.
- You are removing a Pod stuck in `Terminating` because a finalizer's controller no longer exists, and you have already accepted the consequences.

For an unreachable node, the correct modern approach is the `node.kubernetes.io/out-of-service` taint, which lets the controllers safely detach volumes and reschedule, rather than force deleting Pods.

### Pods Stuck in Terminating

```bash
# 1. Is a finalizer holding it?
kubectl get pod myapp -o jsonpath='{.metadata.finalizers}{"\n"}'

# 2. Is the node healthy?
kubectl get node $(kubectl get pod myapp -o jsonpath='{.spec.nodeName}')

# 3. Is the process ignoring SIGTERM? Check on the node:
sudo crictl ps | grep myapp
sudo crictl inspect <id> | jq '.info.pid'

# 4. Removing a stuck finalizer (LAST RESORT, understand why it is there)
kubectl patch pod myapp -p '{"metadata":{"finalizers":null}}' --type=merge
```

The three usual causes: a finalizer whose controller is gone, an application ignoring SIGTERM with a very long grace period, and an unreachable node (which resolves itself once the node controller acts, or via the out-of-service taint).

---

## Node Pressure Eviction

The kubelet monitors node resources and proactively evicts Pods to keep the node usable. This is **kubelet driven** and does **not** respect PodDisruptionBudgets.

### Eviction Signals

| Signal | Derived from |
|--------|--------------|
| `memory.available` | Node memory capacity minus working set |
| `nodefs.available` | Free space on the kubelet root filesystem |
| `nodefs.inodesFree` | Free inodes on the kubelet root filesystem |
| `imagefs.available` | Free space on the filesystem holding images and container writable layers |
| `imagefs.inodesFree` | Free inodes on the image filesystem |
| `pid.available` | Available process IDs on the node |

### Hard vs Soft Thresholds

```
HARD eviction  (--eviction-hard)
  Crossed → the kubelet evicts IMMEDIATELY, with NO grace period.
  Typical Linux defaults:
      memory.available  < 100Mi
      nodefs.available  < 10%
      imagefs.available < 15%
      nodefs.inodesFree < 5%

SOFT eviction  (--eviction-soft + --eviction-soft-grace-period)
  Crossed → the kubelet waits for the configured grace period, and only
  evicts if the condition persists. The Pod's own
  terminationGracePeriodSeconds is honoured, capped by
  --eviction-max-pod-grace-period.
  No soft thresholds are configured by default.
```

Before evicting for `imagefs` or `nodefs` pressure the kubelet first tries to **reclaim** node level resources by garbage collecting dead containers and unused images.

### Eviction Ordering

When memory pressure forces a choice, the kubelet ranks Pods by:

```
1. Is the Pod's usage of the starved resource ABOVE its request?
      Pods over their request are sorted before Pods under it.
      BestEffort Pods request nothing, so they are ALWAYS over.
2. Pod Priority  (spec.priority, lower goes first)
3. How far usage exceeds the request
```

Practical ranking, which is what an exam will ask:

```
Evicted FIRST  ──▶  BestEffort           (no requests at all)
                    Burstable, over its request
                    Burstable, under its request
Evicted LAST   ──▶  Guaranteed           (requests == limits)
```

Setting `requests` correctly is therefore an availability feature, not just a scheduling one.

### What Eviction Looks Like

```bash
kubectl get pods
# NAME       READY   STATUS    RESTARTS   AGE
# worker-1   0/1     Evicted   0          1h

kubectl describe pod worker-1
# Status:  Failed
# Reason:  Evicted
# Message: The node was low on resource: memory.
#          Container app was using 1524Mi, which exceeds its request of 256Mi.
```

Evicted Pods stay in the API as `Failed` objects until garbage collected (bounded by the controller manager's `--terminated-pod-gc-threshold`). Their controller replaces them, which is why a badly sized Deployment can leave dozens of `Evicted` corpses.

```bash
# Clean them up
kubectl get pods -A --field-selector=status.phase=Failed \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,REASON:.status.reason \
  | grep Evicted

kubectl delete pods -A --field-selector=status.phase=Failed
```

### Node Conditions Driven by Pressure

```bash
kubectl describe node worker-02 | sed -n '/Conditions/,/Addresses/p'
# MemoryPressure   True    KubeletHasInsufficientMemory
# DiskPressure     False   KubeletHasNoDiskPressure
# PIDPressure      False   KubeletHasSufficientPID
# Ready            True    KubeletReady
```

`MemoryPressure: True` also causes the scheduler to stop placing BestEffort Pods on that node (via the corresponding taint).

### OOM Kill vs Eviction

These are different mechanisms and mixing them up is a classic error.

| | Container OOM kill | Node pressure eviction |
|---|---|---|
| Who acts | The Linux kernel OOM killer | The kubelet |
| Trigger | The container exceeded its **own** `memory` limit | The **node** crossed an eviction threshold |
| Scope | One container | The whole Pod |
| Visible as | `containerStatuses[].lastState.terminated.reason: OOMKilled`, exit 137 | `status.phase: Failed`, `status.reason: Evicted` |
| Restart behaviour | The container restarts in the same Pod | The Pod is gone; a controller makes a new one |
| Graceful | No | Yes for soft thresholds, no for hard |

---

## API Initiated Eviction and PodDisruptionBudget

API initiated eviction is a **request** to delete a Pod, submitted to the `pods/eviction` subresource. `kubectl drain` is built on it.

```bash
# Under the hood, kubectl drain does this per Pod:
curl -X POST .../api/v1/namespaces/prod/pods/web-0/eviction \
  -d '{"apiVersion":"policy/v1","kind":"Eviction",
       "metadata":{"name":"web-0","namespace":"prod"},
       "deleteOptions":{"gracePeriodSeconds":30}}'
```

The API server checks PodDisruptionBudgets. If evicting the Pod would violate one, it returns **429 Too Many Requests** and the eviction is refused. `kubectl drain` retries.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-pdb
  namespace: production
spec:
  minAvailable: 2              # or maxUnavailable: 1 (mutually exclusive)
  selector:
    matchLabels:
      app: payments
  unhealthyPodEvictionPolicy: IfHealthyBudget   # or AlwaysAllow
```

| Field | Behaviour |
|-------|-----------|
| `minAvailable` | Absolute number or percentage that must remain Ready |
| `maxUnavailable` | Absolute number or percentage that may be down at once |
| `unhealthyPodEvictionPolicy` | `IfHealthyBudget` (default) only allows evicting an unhealthy Pod when the budget is currently satisfied. `AlwaysAllow` permits evicting non Ready Pods regardless, which prevents a broken workload from blocking a drain forever |

```bash
kubectl get pdb -n production
# NAME           MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# payments-pdb   2               N/A               1                     10d
```

`ALLOWED DISRUPTIONS: 0` means a drain will hang. That is the intended behaviour and it is also the most common cause of a stuck node drain.

### Voluntary vs Involuntary Disruption

```
VOLUNTARY  (PDB applies)              INVOLUNTARY  (PDB does NOT apply)
──────────────────────────            ─────────────────────────────────
kubectl drain                          node hardware failure
API eviction from an autoscaler        kernel panic
kubectl delete pod                     network partition
                                       node pressure eviction (kubelet)
                                       OOM kill
                                       VM preemption by the cloud provider
```

Note that a plain `kubectl delete pod` is **not** checked against a PDB. PDBs only guard the eviction API.

---

## Preemption

When the scheduler cannot place a high priority Pod, `PostFilter` runs preemption.

```
┌────────────────────────────────────────────────────────────────┐
│  1. Pod P (priority 1000000) is Unschedulable                   │
│  2. The scheduler looks for a node where removing one or more   │
│     LOWER priority Pods would make P fit                        │
│  3. It picks the node that minimises the damage:                │
│       • fewest PDB violations                                   │
│       • lowest priority victims                                 │
│       • fewest victims                                          │
│       • most recently started victims                           │
│  4. status.nominatedNodeName is set on P                        │
│  5. Victims are DELETED GRACEFULLY, honouring their own         │
│     terminationGracePeriodSeconds and preStop hooks             │
│     They receive condition DisruptionTarget with                │
│     reason PreemptionByScheduler                                │
│  6. P is scheduled once the resources free up.                  │
│     ⚠ The nominated node is a HINT, not a reservation.          │
│       Another Pod may take the space in the meantime.           │
└────────────────────────────────────────────────────────────────┘
```

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority   # or Never
description: "Latency critical production services."
```

Two built in classes exist in every cluster: `system-cluster-critical` and `system-node-critical`. Do not use them for application workloads.

`preemptionPolicy: Never` gives a Pod scheduling queue priority without allowing it to evict anyone. This is the right setting for large batch jobs that should get resources first but must never disturb running services.

Preemption respects PDBs on a **best effort** basis: the scheduler prefers victims that do not violate a PDB, but it will violate one if there is no alternative.

---

## Troubleshooting

### Decision Flow

```
Pod not working
   │
   ├─ STATUS Pending?
   │    ├─ No node assigned  → describe → FailedScheduling message
   │    │                      resources? taints? affinity? PVC unbound?
   │    └─ Node assigned     → image pull? volume mount? CNI?
   │
   ├─ STATUS ContainerCreating (stuck > 60s)?
   │    → describe events: FailedMount, FailedAttachVolume,
   │      FailedCreatePodSandBox
   │    → journalctl -u kubelet on that node
   │
   ├─ STATUS ImagePullBackOff / ErrImagePull?
   │    → image name, tag, registry reachability, imagePullSecrets
   │
   ├─ STATUS CrashLoopBackOff?
   │    → kubectl logs --previous     ← ALWAYS start here
   │    → lastState.terminated.reason and exitCode
   │    → 137? OOMKilled. 127? command not found. 1? app error.
   │    → is a livenessProbe doing the killing? check Events.
   │
   ├─ STATUS Running but READY 0/1?
   │    → readiness probe. describe shows "Readiness probe failed: ..."
   │    → curl the probe path from inside the pod
   │
   ├─ STATUS Terminating forever?
   │    → finalizers? node reachable? app ignoring SIGTERM?
   │
   └─ STATUS Evicted?
        → describe → which resource? which node?
        → set requests properly; check node capacity
```

### Command Sequence

```bash
POD=myapp; NS=production

# 1. Phase, conditions, container states in one shot
kubectl get pod $POD -n $NS -o json | jq '{
  phase: .status.phase,
  reason: .status.reason,
  conditions: [.status.conditions[] | {type, status, reason}],
  containers: [.status.containerStatuses[]? |
    {name, ready, restartCount, state, lastState}]
}'

# 2. Events for this Pod only, in chronological order
kubectl get events -n $NS --field-selector involvedObject.name=$POD \
  --sort-by=.lastTimestamp

# 3. Logs, current and previous
kubectl logs $POD -n $NS --all-containers --timestamps --tail=200
kubectl logs $POD -n $NS -c app --previous

# 4. Probe configuration
kubectl get pod $POD -n $NS -o jsonpath=\
'{range .spec.containers[*]}{.name}{"\n  startup: "}{.startupProbe}{"\n  live: "}{.livenessProbe}{"\n  ready: "}{.readinessProbe}{"\n"}{end}'

# 5. Test the probe endpoint from inside the Pod
kubectl exec $POD -n $NS -c app -- wget -qO- --timeout=2 http://127.0.0.1:8080/readyz

# 6. Test it from the node's perspective (how the kubelet actually probes)
kubectl run probe-test --rm -it --image=curlimages/curl:8.8.0 --restart=Never -- \
  curl -sv "http://$(kubectl get pod $POD -n $NS -o jsonpath='{.status.podIP}'):8080/readyz"

# 7. On the node
NODE=$(kubectl get pod $POD -n $NS -o jsonpath='{.spec.nodeName}')
kubectl describe node $NODE | sed -n '/Conditions/,/Allocated/p'
# then, on that node:
#   journalctl -u kubelet -f --since "10 min ago" | grep -i $POD
#   sudo crictl ps -a --name $POD
#   sudo crictl logs <container-id>
```

### Diagnosing a Liveness Probe Restart Loop

```bash
kubectl describe pod $POD | grep -A3 -i "liveness\|killing\|unhealthy"
# Warning  Unhealthy  2m (x9 over 8m)  kubelet
#   Liveness probe failed: HTTP probe failed with statuscode: 503
# Normal   Killing    2m (x3 over 8m)  kubelet
#   Container app failed liveness probe, will be restarted
```

If the app logs show it working normally right up to each kill, the probe is the problem, not the app. Temporarily raise `failureThreshold` and `timeoutSeconds` to confirm, then fix the endpoint.

### Confirming an OOM Kill

```bash
kubectl get pod $POD -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# OOMKilled

kubectl get pod $POD -o jsonpath='{.spec.containers[0].resources.limits.memory}{"\n"}'
# 256Mi

kubectl top pod $POD --containers
# NAME    CONTAINER   CPU(cores)   MEMORY(bytes)
# myapp   app         12m          248Mi        ← right at the limit

# On the node, the kernel's own record
sudo dmesg -T | grep -i "killed process"
```

---

## Exam and Interview Traps

1. **`CrashLoopBackOff` is not a phase.** The phase is `Running`; the container `state` is `waiting` with that reason. Similarly `Terminating` is not a phase; it is a `kubectl` rendering of `deletionTimestamp` being set.

2. **`kubectl logs` shows nothing during `CrashLoopBackOff`** because the container is not running. Use `--previous`.

3. **The backoff sequence is 10s, 20s, 40s, 80s, 160s, 300s, capped at 5 minutes**, and it resets after 10 minutes of successful running.

4. **A liveness probe restarts the container. A readiness probe does not.** Readiness only removes the Pod from Service endpoints.

5. **While a startup probe is running, liveness and readiness are suspended.** Maximum boot window is `failureThreshold * periodSeconds`.

6. **`successThreshold` must be 1 for liveness and startup probes.** Only readiness may set it higher.

7. **Probe defaults**: `periodSeconds: 10`, `timeoutSeconds: 1`, `failureThreshold: 3`, `successThreshold: 1`, `initialDelaySeconds: 0`. The 1 second timeout catches people constantly.

8. **`postStart` runs concurrently with the ENTRYPOINT.** It is not a "before start" hook. There is no ordering guarantee.

9. **`preStop` consumes the termination grace period.** A 40 second `preStop` under a 30 second grace period gets cut off (with a 2 second courtesy extension) and the app is SIGKILLed.

10. **Endpoint removal and SIGTERM happen in parallel.** That race is why a `preStop` sleep is a best practice, not a hack.

11. **If PID 1 is a shell, SIGTERM is usually not forwarded.** Use `exec` form or no shell at all.

12. **Init containers run sequentially; regular containers start in parallel.** There is no ordering between regular containers, only native sidecars provide start ordering.

13. **A native sidecar is an init container with `restartPolicy: Always`.** It starts before regular containers, shuts down after them, supports probes, and does not block Job completion.

14. **`restartPolicy: Always` makes `Succeeded` unreachable.** Jobs must use `OnFailure` or `Never`; `Always` is rejected on a Job template.

15. **Exit code 137 is SIGKILL (128 + 9)**, usually OOM or grace period expiry. 143 is SIGTERM (128 + 15). 127 is command not found.

16. **OOM kill is a kernel action against one container; eviction is a kubelet action against a whole Pod.** Different mechanism, different remedy.

17. **Node pressure eviction ignores PodDisruptionBudgets.** Only the eviction API honours them, so `kubectl drain` respects a PDB while the kubelet does not.

18. **`kubectl delete pod` is not an eviction and bypasses PDBs entirely.**

19. **BestEffort Pods are evicted first** because their usage is by definition above their (zero) request. Setting requests is an availability control.

20. **`--grace-period=0 --force` removes the API object without confirming the container stopped.** For StatefulSets this risks two Pods with the same identity writing to the same volume.

21. **`spec.nodeName` set manually skips the scheduler**, so a Pod can be admitted onto a node that cannot fit it and then fail with `OutOfcpu`.

22. **`nominatedNodeName` is a hint, not a reservation.** A preemptor may still end up elsewhere.

23. **`ImagePullBackOff` leaves the Pod in phase `Pending`**, not `Running` or `Failed`.

24. **`activeDeadlineSeconds` is wall clock for the whole Pod** and produces reason `DeadlineExceeded`, distinct from a probe or an OOM.

---

## Related Topics

- [Pods](pods.md)
- [Pod Operations](pod-operations.md)
- [Pause Containers](pause-containers.md)
- [Kubelet](kubelet.md)
- [kube-scheduler](kube-scheduler.md)
- [kube-apiserver](kube-apiserver.md)
- [kube-controller-manager](kube-controller-manager.md)
- [Container Runtime](container-runtime.md)
- [Cgroups](cgroups.md)
- [Linux Namespaces](linux-namespaces.md)
- [CNI](cni.md)
- [Kubernetes API](k8s-api.md)
- [Controllers](controllers.md)
- [Deployments](deployments.md)
- [Deployment Strategies](deployment-strategies.md)
- [StatefulSets](statefulsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)

---

## Key Takeaways

1. A Pod's life runs through a fixed pipeline: **admission, scheduling, kubelet sync, sandbox, images, init containers, main containers, steady state, termination**. Knowing which stage you are in tells you which component's logs to read.
2. **`RunPodSandbox` happens once**; container restarts reuse the sandbox, which is why a restart never changes the Pod IP but a node reboot can.
3. **Phase, conditions and container states are three different layers.** The phase is coarse, the conditions are the machine readable gates, and the container state holds the actual error message.
4. **`Ready` is the condition that matters**, not the phase. It gates Service endpoints and is the only correct thing to wait on in automation.
5. **CrashLoopBackOff is the waiting period between restarts**, following 10s, 20s, 40s, 80s, 160s and then a 5 minute cap. `--previous` is how you read the cause.
6. **Liveness restarts, readiness de-registers, startup gates the other two.** Dependency checks belong in readiness, never in liveness.
7. **Native sidecars** (init containers with `restartPolicy: Always`) fix start ordering, shutdown ordering and Job completion in one feature.
8. **Endpoint removal races SIGTERM.** A `preStop` sleep of 5 to 20 seconds, inside a sufficiently large grace period, is the standard fix for 502s during rollouts.
9. **SIGTERM must reach your process.** A shell as PID 1 swallows it and turns every graceful shutdown into a 30 second SIGKILL.
10. **OOM kill and eviction are different.** One is the kernel enforcing a container limit; the other is the kubelet protecting the node.
11. **Node pressure eviction ignores PDBs; API initiated eviction honours them.** Correct `requests` are what keep a Pod out of the eviction queue.
12. **Force deletion lies to the control plane.** Use it only when you are certain the workload is truly gone.

---

## References

- [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Container Lifecycle Hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/)
- [Attach Handlers to Container Lifecycle Events](https://kubernetes.io/docs/tasks/configure-pod-container/attach-handler-lifecycle-event/)
- [Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)
- [Sidecar Containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/)
- [Node-pressure Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [API-initiated Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/)
- [Disruptions](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [Specifying a Disruption Budget for your Application](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- [Kubernetes Scheduler](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)
- [Scheduling Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/)
- [Container Runtime Interface](https://kubernetes.io/docs/concepts/architecture/cri/)
- [Graceful Node Shutdown](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/)
- [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [Pod API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
