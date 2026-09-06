# 🧱 Kubernetes Pods: The Atomic Unit of Deployment

A deep, field by field treatment of the Pod: why the abstraction exists, which Linux namespaces its containers share, how every part of the Pod spec behaves, and how the API server and kubelet report Pod state.

## 📋 Table of Contents

- [What Is a Pod](#what-is-a-pod)
- [Why the Pod Abstraction Exists](#why-the-pod-abstraction-exists)
- [The Shared Namespace Model](#the-shared-namespace-model)
- [The Pause Container and Namespace Ownership](#the-pause-container-and-namespace-ownership)
- [The Pod API Object](#the-pod-api-object)
- [The Pod Spec Field by Field](#the-pod-spec-field-by-field)
- [Container Fields in Depth](#container-fields-in-depth)
- [Init Containers](#init-containers)
- [Ephemeral Containers](#ephemeral-containers)
- [Volumes and the Mount Namespace](#volumes-and-the-mount-namespace)
- [Scheduling Fields](#scheduling-fields)
- [Identity, Security and Host Namespaces](#identity-security-and-host-namespaces)
- [DNS: dnsPolicy and dnsConfig](#dns-dnspolicy-and-dnsconfig)
- [Multi Container Patterns](#multi-container-patterns)
- [Static Pods and Mirror Pods](#static-pods-and-mirror-pods)
- [Pod Networking](#pod-networking)
- [Resources, Requests, Limits and QoS Classes](#resources-requests-limits-and-qos-classes)
- [Pod Status, Conditions and Container Statuses](#pod-status-conditions-and-container-statuses)
- [Pod Immutability: What You Can Actually Change](#pod-immutability-what-you-can-actually-change)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What Is a Pod

A **Pod** is the smallest deployable and schedulable object in the Kubernetes object model. It is not a container. It is a **co-scheduling and co-location boundary**: a group of one or more containers, plus a set of shared Linux namespaces, plus a set of shared storage volumes, plus a single network identity, all placed on exactly one node and treated as a single unit for scheduling, resource accounting and lifecycle.

```
┌───────────────────────────────────────────────────────────────┐
│                        Pod: web-app                            │
│                    Namespace: production                       │
│                    Pod IP: 10.244.2.17                         │
│                    Node: worker-02                             │
│                                                                │
│   ┌──────────────────────────────────────────────────────┐    │
│   │  Shared by all containers in this Pod:               │    │
│   │    • Network namespace  (one IP, one loopback)       │    │
│   │    • IPC namespace      (shm, semaphores, queues)    │    │
│   │    • UTS namespace      (one hostname)               │    │
│   │    • Volumes            (mounted per container)      │    │
│   │    • Cgroup parent      (pod level resource budget)  │    │
│   └──────────────────────────────────────────────────────┘    │
│                                                                │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│   │ app          │  │ log-shipper  │  │ proxy        │        │
│   │ own rootfs   │  │ own rootfs   │  │ own rootfs   │        │
│   │ own mount ns │  │ own mount ns │  │ own mount ns │        │
│   │ own PID ns * │  │ own PID ns * │  │ own PID ns * │        │
│   │ own cgroup   │  │ own cgroup   │  │ own cgroup   │        │
│   └──────────────┘  └──────────────┘  └──────────────┘        │
│                                                                │
│   * unless spec.shareProcessNamespace: true                    │
└───────────────────────────────────────────────────────────────┘
```

### The Precise Definition

| Property | Statement |
|----------|-----------|
| **API identity** | `apiVersion: v1`, `kind: Pod` (core group, no group prefix) |
| **Scope** | Namespaced |
| **Scheduling** | Scheduled as one unit to exactly one node; cannot span nodes |
| **Network** | Exactly one IP per address family, shared by all containers |
| **Storage** | Volumes declared once at Pod level, mounted independently per container |
| **Lifecycle** | Not repaired in place; a failed Pod is replaced by a new Pod with a new UID and usually a new IP |
| **Mutability** | Spec is almost entirely immutable after admission |
| **Restart** | Individual containers restart inside the same Pod (same sandbox, same IP) |

### The Critical Distinction: Container Restart vs Pod Replacement

This trips up almost everyone:

```
Container crashes inside a Pod:
  → kubelet restarts THAT container
  → Same Pod, same Pod UID, same Pod IP, same sandbox
  → RESTARTS column in kubectl get pods increments
  → Volumes and network are untouched

Pod is deleted / node fails / eviction:
  → Pod object is gone forever
  → A controller (Deployment, ReplicaSet, DaemonSet, StatefulSet, Job)
    creates a BRAND NEW Pod
  → New UID, new name (unless StatefulSet), new IP, fresh sandbox
  → RESTARTS resets to 0
```

A bare Pod (one you created directly with `kubectl apply -f pod.yaml`) has **no controller**. If its node dies, the Pod is gone and nothing recreates it. This is why production workloads are always fronted by a controller.

---

## Why the Pod Abstraction Exists

Docker gave the industry a container. Kubernetes deliberately refused to make the container its scheduling unit. There are five concrete reasons.

### 1. Tightly Coupled Helpers Need Co-location

A log shipper that tails `/var/log/app/*.log` must run on the same filesystem as the app. A service mesh proxy that intercepts traffic must live in the same network namespace. If these were separate schedulable units, you would need affinity rules, shared network plumbing and lifecycle coordination for every single pairing. The Pod makes co-location a structural guarantee instead of a scheduling hint.

### 2. Shared Namespaces Need an Owner With a Stable Lifetime

Linux namespaces exist as long as at least one process holds a reference. If container A created the network namespace and container B joined it, then a crash of A would destroy the namespace and strand B. The Pod introduces a dedicated namespace holder (the pause container) whose lifetime spans the whole Pod. See [Pause Containers](pause-containers.md).

### 3. Atomic Scheduling and Resource Accounting

The scheduler must reserve resources for the whole group at once. If the app needs 1 CPU and the sidecar needs 0.5 CPU, placing them independently could succeed for one and fail for the other, leaving a half functional workload. The Pod is the unit the scheduler fits into a node's allocatable capacity.

### 4. A Single Network Identity

Services, Endpoints, EndpointSlices, NetworkPolicies and DNS all target a single IP. If a group of collaborating containers had three IPs, every one of those abstractions would need to model container level addressing. One IP per Pod keeps the network model flat and simple. See [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md).

### 5. It Decouples Kubernetes From Any Single Runtime

The Pod is defined in terms of namespaces and cgroups, not in terms of Docker. This is precisely what allowed Kubernetes to move to CRI, containerd and CRI-O without changing the workload API. See [Container Runtime](container-runtime.md).

---

## The Shared Namespace Model

This is the single most important internals topic for Pods. Kubernetes does **not** share all namespaces. Get this table into muscle memory.

| Linux Namespace | Shared Across Containers in a Pod? | Controlled By | Effect |
|-----------------|-----------------------------------|---------------|--------|
| **Network** (`net`) | ✅ Always shared | Implicit (pause container owns it) | One IP, one loopback, one routing table, one set of listening ports |
| **IPC** (`ipc`) | ✅ Always shared | Implicit | POSIX/SysV shared memory, semaphores and message queues are visible across containers |
| **UTS** (`uts`) | ✅ Always shared | Implicit; `spec.hostname` sets the value | All containers see the same hostname and NIS domain |
| **PID** (`pid`) | ❌ Not shared by default | `spec.shareProcessNamespace: true` | When shared, containers see each other's processes and can signal them |
| **Mount** (`mnt`) | ❌ **Never shared** | Not configurable | Each container has its own root filesystem; sharing happens only through explicitly declared volumes |
| **User** (`user`) | ❌ Not shared by default | `spec.hostUsers: false` enables a user namespace for the Pod | UID/GID remapping for the whole Pod |
| **Cgroup** (`cgroup`) | ❌ Per container | Runtime managed | Each container sees its own cgroup root; the Pod has a shared parent cgroup slice |
| **Time** (`time`) | ❌ Not exposed | Not exposed by the Pod API | Kubernetes does not offer a time namespace field |

Cross reference: [Linux Namespaces](linux-namespaces.md) covers each namespace type in isolation with hands on `unshare` and `nsenter` examples.

### Network Namespace: Shared Always

```
┌──────────────────────────────────────────────────────────┐
│  Pod network namespace (owned by the pause container)     │
│                                                           │
│   eth0: 10.244.2.17/32   ← the Pod IP (veth to the node)  │
│   lo:   127.0.0.1/8      ← shared loopback                │
│                                                           │
│   ┌────────────┐   ┌────────────┐                        │
│   │ app        │   │ sidecar    │                        │
│   │ listens on │   │ curls      │                        │
│   │ :8080      │──▶│ localhost: │                        │
│   │            │   │ 8080       │                        │
│   └────────────┘   └────────────┘                        │
│                                                           │
│   ⚠ Port 8080 can be bound by ONE container only.         │
│     A second bind gets EADDRINUSE.                        │
└──────────────────────────────────────────────────────────┘
```

Consequences you must be able to state:

1. Containers in a Pod reach each other over `localhost` / `127.0.0.1`.
2. Port numbers are a **Pod wide** resource. Two containers cannot both bind `:8080`.
3. `iptables` rules installed by one container (for example an init container that sets up a mesh redirect) apply to every container in the Pod.
4. `/etc/hosts` is written into the Pod sandbox and shared. `spec.hostAliases` injects entries there.
5. A packet capture inside any container sees traffic for all containers.

### IPC Namespace: Shared Always

Two containers can communicate through SysV shared memory or POSIX message queues without any volume. The size of `/dev/shm` in a Pod defaults to a runtime chosen value (commonly 64 MiB), which frequently breaks databases and ML frameworks. The standard fix is an `emptyDir` with `medium: Memory` mounted at `/dev/shm`.

```yaml
    volumeMounts:
      - name: dshm
        mountPath: /dev/shm
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 2Gi
```

Note that a memory backed `emptyDir` counts against the Pod's memory limit.

### UTS Namespace: Shared Always

All containers see one hostname. By default the hostname is derived from the Pod name. You can override it:

```yaml
spec:
  hostname: db-0                 # sets the UTS hostname
  subdomain: mysql-headless      # with a headless Service of the same name,
                                 # gives db-0.mysql-headless.<ns>.svc.cluster.local
  setHostnameAsFQDN: false       # if true, `hostname` returns the FQDN
```

### PID Namespace: Opt In

```yaml
spec:
  shareProcessNamespace: true
```

When enabled:

- The pause container becomes **PID 1** for the Pod and reaps orphaned zombies.
- Every container's processes are visible in every other container's `/proc`.
- Containers can send signals to each other (subject to capabilities and user IDs).
- A container's own process is no longer PID 1, which changes signal handling semantics for applications that rely on being PID 1.
- Other containers' filesystems become reachable via `/proc/<pid>/root`, which is a security consideration.

`shareProcessNamespace: true` is incompatible with `hostPID: true`.

### Mount Namespace: Never Shared

This is the field that everyone gets wrong. Each container in a Pod has its **own mount namespace and its own root filesystem** derived from its own image. Container A cannot see `/app` in container B.

```
┌──────────────────────────────────────────────────────────────┐
│  What is NOT shared: the root filesystem                      │
│                                                               │
│  ┌───────────────────┐        ┌───────────────────┐          │
│  │ container: app    │        │ container: sidecar│          │
│  │ image: myapp:1.0  │        │ image: fluentbit  │          │
│  │                   │        │                   │          │
│  │ /  /bin /etc /app │   ✗    │ /  /bin /etc /fb  │          │
│  │        (own mnt)  │◀──────▶│        (own mnt)  │          │
│  └─────────┬─────────┘        └─────────┬─────────┘          │
│            │                            │                     │
│            │   ┌────────────────────┐   │                     │
│            └──▶│ volume: shared-logs│◀──┘                     │
│                │  emptyDir {}       │                         │
│                └────────────────────┘                         │
│      mounted at /var/log/app    mounted at /input             │
│                                                               │
│  Sharing only happens through DECLARED volumes,               │
│  and the mount path may differ per container.                 │
└──────────────────────────────────────────────────────────────┘
```

---

## The Pause Container and Namespace Ownership

Every Pod has a hidden **pause container** (also called the infra or sandbox container), started from `registry.k8s.io/pause`. It is a few hundred kilobytes, it calls `pause(2)` in a loop, and it reaps zombies when it is PID 1.

Its job is to be the **anchor for the shared namespaces**:

```
Sequence when a Pod starts:

 1. kubelet calls CRI RunPodSandbox
 2. Runtime creates the pause container
      → this creates the net / ipc / uts namespaces
 3. CNI plugin is invoked against the sandbox network namespace
      → veth pair created, Pod IP assigned, routes installed
 4. Init containers run, each joining the sandbox namespaces
 5. App containers start, each joining the sandbox namespaces
      → each with its OWN mount namespace and cgroup

 If an app container crashes:
      → only that container is recreated
      → it rejoins the still living sandbox namespaces
      → the Pod IP does not change
```

Inspect it on a node:

```bash
# containerd: list sandboxes
sudo crictl pods

# show the sandbox for a specific pod
sudo crictl pods --name web-app -o json | jq '.items[0].id'

# containers belonging to that sandbox
sudo crictl ps --pod <SANDBOX_ID>

# find the pause process PID and inspect its namespaces
sudo crictl inspectp <SANDBOX_ID> | jq '.info.pid'
sudo ls -l /proc/<PID>/ns/
```

Full detail lives in [Pause Containers](pause-containers.md).

---

## The Pod API Object

```yaml
apiVersion: v1
kind: Pod
metadata: {}      # identity: name, namespace, labels, annotations, ownerReferences
spec: {}          # DESIRED state, written by the user, almost entirely immutable
status: {}        # OBSERVED state, written by the kubelet and controllers
```

Three rules govern the object:

1. **You write `spec`. The system writes `status`.** Editing `status` by hand (possible via the `pods/status` subresource) is overwritten on the next kubelet sync.
2. **`spec` is immutable after admission**, apart from a very small allowlist covered later.
3. **`metadata.ownerReferences`** links the Pod to its controller and drives garbage collection. A Pod with no owner reference is a bare Pod.

---

## The Pod Spec Field by Field

The annotated manifest below is deliberately dense. It is not a manifest you would deploy as is; it is a reference sheet.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: reference-pod                    # DNS-1123 subdomain, unique in the namespace
  namespace: production
  labels:                                # selectable by Services, controllers, NetworkPolicies
    app: payments
    tier: backend
    version: v2.3.1
  annotations:                           # NOT selectable; arbitrary metadata for tools
    kubectl.kubernetes.io/default-container: app
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"

spec:
  # ---------- Scheduling ----------
  nodeSelector:                          # hard, simple node constraint (AND of labels)
    kubernetes.io/os: linux
    node-role.kubernetes.io/worker: ""
  # nodeName: worker-02                  # BYPASSES the scheduler entirely
  schedulerName: default-scheduler       # route to a custom scheduler
  priorityClassName: high-priority       # resolves to spec.priority; drives preemption
  preemptionPolicy: PreemptLowerPriority # or Never
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:               # OR across terms, AND across matchExpressions
          - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In             # In, NotIn, Exists, DoesNotExist, Gt, Lt
                values: ["us-east-1a", "us-east-1b"]
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 80                     # 1..100
          preference:
            matchExpressions:
              - key: node.kubernetes.io/instance-type
                operator: In
                values: ["m6i.2xlarge"]
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: payments
          topologyKey: kubernetes.io/hostname   # one payments Pod per node
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule   # or ScheduleAnyway (soft)
      labelSelector:
        matchLabels:
          app: payments
      minDomains: 3
      nodeAffinityPolicy: Honor          # Honor or Ignore
      nodeTaintsPolicy: Honor            # Honor or Ignore
      matchLabelKeys: ["pod-template-hash"]
  tolerations:
    - key: "dedicated"
      operator: "Equal"                  # Equal or Exists
      value: "payments"
      effect: "NoSchedule"               # NoSchedule, PreferNoSchedule, NoExecute
    - key: "node.kubernetes.io/not-ready"
      operator: "Exists"
      effect: "NoExecute"
      tolerationSeconds: 300             # only meaningful for NoExecute

  # ---------- Identity and security ----------
  serviceAccountName: payments-sa
  automountServiceAccountToken: true
  securityContext:                       # POD level
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 20000                       # group ownership applied to volume mounts
    fsGroupChangePolicy: OnRootMismatch  # Always or OnRootMismatch
    supplementalGroups: [30000]
    seccompProfile:
      type: RuntimeDefault               # RuntimeDefault, Localhost, Unconfined
    seLinuxOptions:
      level: "s0:c123,c456"
    sysctls:
      - name: net.ipv4.tcp_keepalive_time
        value: "600"
  hostNetwork: false
  hostPID: false
  hostIPC: false
  hostUsers: true                        # false enables a user namespace for the Pod
  shareProcessNamespace: false

  # ---------- Naming and DNS ----------
  hostname: reference-pod
  subdomain: payments-headless
  setHostnameAsFQDN: false
  dnsPolicy: ClusterFirst                # ClusterFirst, ClusterFirstWithHostNet, Default, None
  dnsConfig:
    nameservers: ["10.96.0.10"]
    searches: ["payments.svc.cluster.local"]
    options:
      - name: ndots
        value: "2"
      - name: single-request-reopen
  hostAliases:
    - ip: "10.0.0.50"
      hostnames: ["legacy-db.internal"]

  # ---------- Lifecycle ----------
  restartPolicy: Always                  # Always, OnFailure, Never
  terminationGracePeriodSeconds: 45
  activeDeadlineSeconds: 3600            # hard wall clock cap for the whole Pod
  enableServiceLinks: false              # stop injecting *_SERVICE_HOST env vars
  imagePullSecrets:
    - name: registry-creds
  readinessGates:
    - conditionType: "example.com/feature-flags-loaded"

  # ---------- Containers ----------
  initContainers:
    - name: wait-for-db
      image: busybox:1.36
      command: ["sh", "-c"]
      args: ["until nc -z db 5432; do sleep 2; done"]

  containers:
    - name: app
      image: registry.example.com/payments:v2.3.1
      imagePullPolicy: IfNotPresent      # Always, IfNotPresent, Never
      command: ["/usr/local/bin/payments"]   # overrides image ENTRYPOINT
      args: ["--config=/etc/app/config.yaml"] # overrides image CMD
      workingDir: /app
      ports:
        - name: http                     # <=15 chars, IANA_SVC_NAME
          containerPort: 8080
          protocol: TCP                  # TCP (default), UDP, SCTP
        - name: metrics
          containerPort: 9090
      env:
        - name: LOG_LEVEL
          value: "info"
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: MEM_LIMIT
          valueFrom:
            resourceFieldRef:
              containerName: app
              resource: limits.memory
              divisor: 1Mi
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: password
        - name: FEATURE_X
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: feature_x
              optional: true
      envFrom:
        - configMapRef:
            name: app-config
        - secretRef:
            name: app-secrets
          prefix: APP_
      resources:
        requests:
          cpu: "500m"
          memory: "512Mi"
          ephemeral-storage: "1Gi"
        limits:
          cpu: "1"
          memory: "1Gi"
          ephemeral-storage: "2Gi"
      volumeMounts:
        - name: config
          mountPath: /etc/app
          readOnly: true
        - name: cache
          mountPath: /var/cache/app
        - name: shared-logs
          mountPath: /var/log/app
      securityContext:                   # CONTAINER level, overrides Pod level
        allowPrivilegeEscalation: false
        privileged: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]
      terminationMessagePath: /dev/termination-log
      terminationMessagePolicy: File     # File or FallbackToLogsOnError
      stdin: false
      tty: false

    - name: log-shipper
      image: fluent/fluent-bit:3.0
      resources:
        requests: {cpu: "50m", memory: "64Mi"}
        limits:   {cpu: "200m", memory: "128Mi"}
      volumeMounts:
        - name: shared-logs
          mountPath: /input
          readOnly: true

  # ---------- Volumes ----------
  volumes:
    - name: config
      configMap:
        name: app-config
        defaultMode: 0444
    - name: cache
      emptyDir:
        sizeLimit: 500Mi
    - name: shared-logs
      emptyDir: {}
    - name: creds
      projected:
        sources:
          - serviceAccountToken:
              path: token
              audience: vault
              expirationSeconds: 3600
          - configMap:
              name: ca-bundle
```

### Field Semantics That Matter

| Field | Behaviour to remember |
|-------|----------------------|
| `metadata.labels` | Key/value pairs used by selectors. Value max 63 chars, must start and end alphanumeric. |
| `metadata.annotations` | Not selectable. No size limit per key beyond the total object size cap. Used by tooling. |
| `spec.restartPolicy` | Pod wide, applies to all containers. Defaults to `Always`. Immutable. |
| `spec.activeDeadlineSeconds` | Wall clock, counted from Pod start. On expiry the Pod moves to `Failed` with reason `DeadlineExceeded`. |
| `spec.enableServiceLinks` | Defaults to `true`. Injects Docker link style env vars for every Service in the namespace. Set to `false` in busy namespaces to avoid huge environments. |
| `spec.imagePullSecrets` | List of Secret names of type `kubernetes.io/dockerconfigjson` in the same namespace. |
| `spec.terminationGracePeriodSeconds` | Defaults to `30`. Countdown between SIGTERM and SIGKILL. |
| `spec.readinessGates` | Custom conditions that must be `True` in `status.conditions` before the Pod becomes `Ready`. Written by an external controller. |

---

## Container Fields in Depth

### image and imagePullPolicy

`imagePullPolicy` defaults are computed, not fixed:

| Image reference | Default `imagePullPolicy` |
|-----------------|---------------------------|
| `nginx` (no tag) | `Always` |
| `nginx:latest` | `Always` |
| `nginx:1.27.1` | `IfNotPresent` |
| `nginx@sha256:abc...` | `IfNotPresent` |

`Never` means the image must already exist on the node or the container fails with `ErrImageNeverPull`. Always pin a digest or an immutable tag in production; `:latest` combined with `Always` makes rollouts non deterministic.

### command and args vs ENTRYPOINT and CMD

This mapping is a guaranteed interview question:

| Kubernetes | Dockerfile equivalent | Behaviour |
|------------|----------------------|-----------|
| `command` | `ENTRYPOINT` | If set, **replaces** the image ENTRYPOINT |
| `args` | `CMD` | If set, **replaces** the image CMD |

```
command set? | args set? | What runs
-------------|-----------|--------------------------------------
no           | no        | image ENTRYPOINT + image CMD
yes          | no        | pod command only (image CMD discarded)
no           | yes       | image ENTRYPOINT + pod args
yes          | yes       | pod command + pod args
```

There is **no shell** unless you ask for one. `command: ["echo $HOME"]` prints the literal string. Use `command: ["sh", "-c", "echo $HOME"]`.

Kubernetes does expand its own environment variables in `command` and `args` using `$(VAR_NAME)` syntax, referring to variables defined earlier in the same container's `env` list. Use `$$(VAR)` to escape.

### env and envFrom

`env` entries are ordered and later entries can reference earlier ones with `$(VAR)`. `envFrom` pulls every key from a ConfigMap or Secret. Precedence: explicit `env` wins over `envFrom` on key collision.

Downward API paths that are valid in `fieldRef`:

```
metadata.name            metadata.namespace       metadata.uid
metadata.labels['<k>']   metadata.annotations['<k>']
spec.nodeName            spec.serviceAccountName
status.hostIP            status.hostIPs
status.podIP             status.podIPs
```

Valid `resourceFieldRef` resources:

```
requests.cpu    limits.cpu
requests.memory limits.memory
requests.ephemeral-storage  limits.ephemeral-storage
requests.hugepages-<size>   limits.hugepages-<size>
```

Note that `metadata.labels` and `metadata.annotations` as a whole map are only available through a `downwardAPI` **volume**, not through `env`. Through `env` you may only reference a single key.

### ports

`ports` is **purely informational** for the vast majority of cases. Not declaring a port does not block traffic; a container listening on 8080 is reachable on 8080 regardless. What `ports` gives you:

- A **name** that a Service `targetPort` can reference symbolically.
- Documentation for humans and tooling.
- `hostPort`, which is **not** informational: it makes the runtime program a port mapping on the node and it consumes a real node port, constraining scheduling.

```yaml
ports:
  - name: http
    containerPort: 8080
    protocol: TCP
    hostPort: 8080      # AVOID: limits the Pod to one replica per node
    hostIP: 0.0.0.0
```

`hostPort` should be reserved for infrastructure DaemonSets (ingress controllers, node agents). Ordinary workloads should use a Service.

### securityContext Precedence

```
Pod securityContext  ──▶ applies to all containers as a default
                          │
Container securityContext ─┴─▶ OVERRIDES the Pod value for that container
```

Fields that exist **only** at Pod level: `fsGroup`, `fsGroupChangePolicy`, `supplementalGroups`, `sysctls`.
Fields that exist **only** at container level: `allowPrivilegeEscalation`, `privileged`, `readOnlyRootFilesystem`, `capabilities`, `procMount`.
Fields available at both: `runAsUser`, `runAsGroup`, `runAsNonRoot`, `seLinuxOptions`, `seccompProfile`, `appArmorProfile`.

A hardened baseline that satisfies the `restricted` Pod Security Standard:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

### terminationMessagePath and terminationMessagePolicy

The kubelet reads up to 4096 bytes from `terminationMessagePath` (default `/dev/termination-log`) when a container terminates and surfaces it in `status.containerStatuses[].state.terminated.message`. With `terminationMessagePolicy: FallbackToLogsOnError`, if the file is empty and the container exited non zero, the kubelet uses the tail of the container log instead. This is an excellent, underused debugging aid.

---

## Init Containers

Init containers run **to completion, one at a time, in declaration order**, before any regular container starts.

```
┌────────────────────────────────────────────────────────────┐
│ Pod start sequence with init containers                     │
│                                                             │
│  sandbox ready                                              │
│      │                                                      │
│      ▼                                                      │
│  init[0] ──run──▶ exit 0 ──▶ init[1] ──run──▶ exit 0        │
│      │                          │                           │
│      │ exit != 0                │ exit != 0                 │
│      ▼                          ▼                           │
│  restartPolicy Always/OnFailure → retry with backoff        │
│  restartPolicy Never            → Pod phase = Failed        │
│      │                                                      │
│      ▼ all init containers succeeded                        │
│  condition Initialized = True                               │
│      │                                                      │
│      ▼                                                      │
│  ALL regular containers start in PARALLEL                   │
└────────────────────────────────────────────────────────────┘
```

Properties:

- Init containers support all container fields **except** `lifecycle`, `livenessProbe`, `readinessProbe` and `startupProbe`. (The exception is a native sidecar, described below.)
- They have their own image, so they can carry tools that the app image does not, which is the standard way to keep the app image distroless.
- Their resource requests participate in the Pod's **effective request** calculation as a max, not a sum. See the QoS section.
- Their statuses appear in `status.initContainerStatuses`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: init-example
spec:
  initContainers:
    - name: wait-for-postgres
      image: busybox:1.36
      command: ['sh', '-c', 'until nc -z postgres 5432; do echo waiting; sleep 2; done']
    - name: run-migrations
      image: registry.example.com/migrator:v1.4
      command: ['/migrate', 'up']
      env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef: {name: db-credentials, key: url}
    - name: fix-permissions
      image: busybox:1.36
      command: ['sh', '-c', 'chown -R 10001:10001 /data']
      securityContext:
        runAsUser: 0
      volumeMounts:
        - name: data
          mountPath: /data
  containers:
    - name: app
      image: registry.example.com/app:v3.0
      securityContext:
        runAsUser: 10001
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: app-data
```

### Native Sidecar Containers

An entry in `initContainers` that carries `restartPolicy: Always` is a **native sidecar**. The `SidecarContainers` feature graduated through alpha and beta and is stable in modern Kubernetes releases.

```yaml
spec:
  initContainers:
    - name: log-shipper
      image: fluent/fluent-bit:3.0
      restartPolicy: Always            # <-- makes it a native sidecar
      volumeMounts:
        - name: logs
          mountPath: /input
  containers:
    - name: app
      image: myapp:1.0
      volumeMounts:
        - name: logs
          mountPath: /var/log/app
  volumes:
    - name: logs
      emptyDir: {}
```

Why this matters:

| Behaviour | Regular sidecar in `containers` | Native sidecar in `initContainers` |
|-----------|-------------------------------|-----------------------------------|
| Start order | Parallel with the app | **Before** the app, and the app waits for it to be started |
| Probes allowed | Yes | Yes (unlike a plain init container) |
| Shutdown order | Arbitrary | **After** all regular containers terminate |
| Effect on Job completion | Blocks Job completion forever | Does not block; terminated when main containers finish |
| Counts toward `Ready` | Yes | Yes |

The native sidecar solves two long standing problems: a mesh proxy that was not ready before the app tried to make its first call, and a log shipper that kept a Job from ever reaching `Succeeded`.

Lifecycle details are covered in [Pod Lifecycle](pod-lifecycle.md).

---

## Ephemeral Containers

An **ephemeral container** is a temporary container injected into a **running** Pod for debugging. It is the answer to "my image is distroless and has no shell".

Constraints, all of which are enforced by the API server:

- Cannot be added by editing `spec`. They are written through the `pods/ephemeralcontainers` subresource only.
- Cannot be removed or restarted once added.
- Have **no** `ports`, **no** `resources`, **no** `probes`, **no** `lifecycle` hooks.
- Do not affect the Pod's QoS class or its scheduling.
- Appear in `status.ephemeralContainerStatuses`.

```bash
# attach a debug container that shares the target container's process namespace
kubectl debug -it payments-7d9f8-abcde \
  --image=busybox:1.36 \
  --target=app \
  -- sh
```

`--target` requires runtime support for process namespace targeting; without it the ephemeral container gets the Pod's network and IPC but not the target's PID namespace, so `ps` will not show the app's processes.

Practical usage is expanded in [Pod Operations](pod-operations.md).

---

## Volumes and the Mount Namespace

Volumes are declared once under `spec.volumes` and mounted independently by each container. A volume that no container mounts still exists and is still set up by the kubelet.

### Volume Lifetime

```
emptyDir            → lives as long as the POD lives on the node.
                      Survives container restarts. Destroyed on Pod deletion.
configMap / secret  → tmpfs backed projection, read only, updated in place
                      (with a propagation delay) unless subPath is used.
persistentVolumeClaim → outlives the Pod entirely.
hostPath            → the node's filesystem; survives everything; a security risk.
projected           → combines serviceAccountToken, configMap, secret, downwardAPI.
downwardAPI         → files containing Pod metadata, including whole label/annotation maps.
```

### volumeMounts Fields

```yaml
volumeMounts:
  - name: config
    mountPath: /etc/app          # path inside THIS container
    subPath: app.conf            # mount a single key/file instead of the directory
    readOnly: true
  - name: data
    mountPath: /data
    subPathExpr: $(POD_NAME)     # subPath with env var expansion
  - name: host-mounts
    mountPath: /mnt/host
    mountPropagation: HostToContainer   # None (default), HostToContainer, Bidirectional
```

Two behaviours worth memorising:

1. **`subPath` breaks live updates.** A ConfigMap or Secret mounted with `subPath` is copied once and never refreshed. Without `subPath`, the kubelet atomically swaps a symlink and the container sees updated content (though the application must reload it).
2. **Mounting a directory hides the image's content at that path.** Mounting an empty `emptyDir` at `/usr/share/nginx/html` gives you an empty document root, not a merged view.

### fsGroup and Volume Ownership

`spec.securityContext.fsGroup` causes the kubelet to `chown` and `chmod` the volume contents (group ownership plus setgid) so a non root container can write. On very large volumes this recursive walk delays Pod start, which is exactly why `fsGroupChangePolicy: OnRootMismatch` exists: the change is skipped when the top level directory already has the expected ownership.

---

## Scheduling Fields

### nodeName: The Scheduler Bypass

```yaml
spec:
  nodeName: worker-02
```

Setting `nodeName` means the scheduler never sees the Pod; the kubelet on `worker-02` picks it up directly from its API watch. There is **no resource fit check and no taint check**. If the node lacks capacity the Pod is admitted and then rejected by the kubelet with reason `OutOfcpu` or `OutOfmemory`. Use this only for debugging and for static pods.

### nodeSelector vs nodeAffinity

| | `nodeSelector` | `nodeAffinity` |
|---|---|---|
| Expressiveness | Exact label equality only, ANDed | `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt` |
| Soft preference | Not possible | `preferredDuringSchedulingIgnoredDuringExecution` with weights |
| OR logic | Not possible | Multiple `nodeSelectorTerms` are ORed |

Both are `IgnoredDuringExecution`: once a Pod is running, changing node labels does not evict it.

### podAffinity and podAntiAffinity

`topologyKey` defines the domain. `kubernetes.io/hostname` means "per node", `topology.kubernetes.io/zone` means "per zone".

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values: ["payments"]
        topologyKey: kubernetes.io/hostname
```

Required pod anti affinity is computationally expensive; the scheduler must evaluate every candidate node against every matching Pod. On very large clusters prefer `topologySpreadConstraints`.

### topologySpreadConstraints

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: payments
```

`maxSkew` is the maximum permitted difference between the number of matching Pods in the most populated domain and the least populated domain. `whenUnsatisfiable: ScheduleAnyway` downgrades the constraint to a scoring preference.

### tolerations and Taints

Taints repel; tolerations permit. A toleration does not attract a Pod to a node, it only removes an objection.

```yaml
tolerations:
  - operator: "Exists"          # tolerate EVERY taint. Dangerous but used by DaemonSets.
```

The three built in `NoExecute` taints matter for lifecycle:

```
node.kubernetes.io/not-ready            added when the node condition Ready is False
node.kubernetes.io/unreachable          added when the node controller loses contact
node.kubernetes.io/out-of-service       added by an admin to force detach and reschedule
```

Kubernetes automatically adds tolerations with `tolerationSeconds: 300` for `not-ready` and `unreachable` to every Pod that does not already have them. That 300 seconds is why a Pod on a dead node takes about five minutes to be rescheduled.

### priorityClassName and Preemption

```yaml
spec:
  priorityClassName: high-priority
  preemptionPolicy: PreemptLowerPriority   # or Never
```

Admission resolves `priorityClassName` into the numeric `spec.priority`. Higher priority Pods are scheduled first and may evict lower priority Pods when the cluster is full. `preemptionPolicy: Never` means the Pod jumps the scheduling queue but never evicts anyone.

---

## Identity, Security and Host Namespaces

### serviceAccountName and automountServiceAccountToken

Every Pod runs as a ServiceAccount; if you do not name one, it is `default`. When `automountServiceAccountToken` is `true` (the default), the kubelet injects a projected volume at:

```
/var/run/secrets/kubernetes.io/serviceaccount/
├── token        # a short lived, audience bound, auto rotated JWT
├── ca.crt       # the cluster CA bundle
└── namespace    # the Pod's namespace
```

Modern clusters use **bound service account tokens**: the token is tied to the Pod's UID, has an expiry, and is invalidated when the Pod is deleted. Disable the mount for workloads that never talk to the API server:

```yaml
spec:
  automountServiceAccountToken: false
```

The setting can also be placed on the ServiceAccount object; the Pod level value wins.

### Host Namespaces

```yaml
spec:
  hostNetwork: true    # use the NODE's network namespace
  hostPID: true        # see all processes on the node
  hostIPC: true        # share the node's IPC namespace
```

Each of these is a privilege escalation vector and each is blocked by the `baseline` and `restricted` Pod Security Standards.

`hostNetwork: true` in particular changes several behaviours at once:

1. The Pod has the node's IP, not a CNI assigned IP. `status.podIP` equals `status.hostIP`.
2. `containerPort` becomes a real node port. Two such Pods cannot bind the same port on one node.
3. The default `dnsPolicy` of `ClusterFirst` will make the Pod use the **node's** resolver, so cluster DNS breaks. You must set `dnsPolicy: ClusterFirstWithHostNet` to keep cluster DNS.

---

## DNS: dnsPolicy and dnsConfig

| `dnsPolicy` | Resolver used |
|-------------|---------------|
| `ClusterFirst` | **Default.** Cluster DNS (CoreDNS) with the cluster search domains; queries that do not match cluster suffixes are forwarded upstream by CoreDNS. |
| `ClusterFirstWithHostNet` | Same as above, but required when `hostNetwork: true`. |
| `Default` | Inherit `/etc/resolv.conf` from the node. No cluster DNS. |
| `None` | Ignore everything; `dnsConfig` must be supplied and is used verbatim. |

A generated `/etc/resolv.conf` in a Pod typically looks like:

```
nameserver 10.96.0.10
search production.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

`ndots:5` means any name with fewer than five dots is first tried against every search domain. Resolving `api.example.com` (two dots) therefore issues four failing queries before the correct one. Lowering `ndots` through `dnsConfig` is a standard latency optimisation for workloads that mostly call external hosts:

```yaml
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
```

See [CoreDNS](coredns.md).

---

## Multi Container Patterns

The default should always be **one container per Pod**. Add a second only when the two processes must share a namespace or a volume and must live and die together.

### 1. Sidecar

Augments the main container: log shipping, metrics export, config reloading, certificate renewal.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-logging
spec:
  initContainers:
    - name: log-shipper
      image: fluent/fluent-bit:3.0
      restartPolicy: Always              # native sidecar
      volumeMounts:
        - name: applogs
          mountPath: /input
          readOnly: true
        - name: fb-config
          mountPath: /fluent-bit/etc
  containers:
    - name: app
      image: registry.example.com/app:v1
      volumeMounts:
        - name: applogs
          mountPath: /var/log/app
  volumes:
    - name: applogs
      emptyDir: {}
    - name: fb-config
      configMap:
        name: fluent-bit-config
```

The link is the shared `emptyDir`. Note the mount paths differ per container because mount namespaces are not shared.

### 2. Ambassador (Proxy)

The app talks to `localhost` and the ambassador handles discovery, sharding, TLS or failover to the real backend.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ambassador-redis
spec:
  containers:
    - name: app
      image: registry.example.com/app:v1
      env:
        - name: REDIS_URL
          value: "redis://127.0.0.1:6379"   # always localhost
    - name: twemproxy
      image: registry.example.com/twemproxy:0.5
      ports:
        - containerPort: 6379
      volumeMounts:
        - name: proxy-config
          mountPath: /etc/nutcracker
  volumes:
    - name: proxy-config
      configMap:
        name: twemproxy-config
```

The link is the shared **network namespace**. The app has no idea there are six Redis shards behind the proxy.

### 3. Adapter

Normalises the main container's output into a format an external system expects. Classic case: an app that exposes a bespoke stats endpoint and a translator that publishes Prometheus format.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: adapter-metrics
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9187"
spec:
  containers:
    - name: postgres
      image: postgres:16
      ports:
        - containerPort: 5432
      env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef: {name: pg-secret, key: password}
    - name: exporter
      image: quay.io/prometheuscommunity/postgres-exporter:v0.15.0
      ports:
        - name: metrics
          containerPort: 9187
      env:
        - name: DATA_SOURCE_NAME
          value: "postgresql://postgres@127.0.0.1:5432/postgres?sslmode=disable"
```

### 4. Init

Setup work that must finish before the app starts, using tools the app image must not carry.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: init-clone-repo
spec:
  initContainers:
    - name: git-clone
      image: alpine/git:2.45.2
      args: ["clone", "--depth=1", "https://example.com/site.git", "/site"]
      volumeMounts:
        - name: web-content
          mountPath: /site
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      volumeMounts:
        - name: web-content
          mountPath: /usr/share/nginx/html
          readOnly: true
  volumes:
    - name: web-content
      emptyDir: {}
```

### Pattern Comparison

| Pattern | Shared resource that makes it work | Runs when | Typical example |
|---------|-----------------------------------|-----------|-----------------|
| **Init** | Volume | Before the app, to completion | Schema migration, fetch assets, wait for a dependency |
| **Sidecar** | Volume and/or network | Alongside the app | Log shipper, cert renewer, config reloader |
| **Ambassador** | Network namespace | Alongside the app | Connection proxy, sharding proxy, TLS terminator |
| **Adapter** | Network namespace and/or volume | Alongside the app | Metrics format translator, log reformatter |

---

## Static Pods and Mirror Pods

A **static pod** is managed directly by a kubelet, with no API server involvement in its lifecycle. This is how the control plane bootstraps itself: `kube-apiserver` cannot be created by `kube-apiserver`.

```
┌──────────────────────────────────────────────────────────────┐
│  Control plane node                                           │
│                                                               │
│  /etc/kubernetes/manifests/                                   │
│    ├── kube-apiserver.yaml                                    │
│    ├── kube-controller-manager.yaml                           │
│    ├── kube-scheduler.yaml                                    │
│    └── etcd.yaml                                              │
│              │                                                │
│              │ kubelet watches this directory                 │
│              ▼                                                │
│      kubelet starts the pods directly via CRI                 │
│              │                                                │
│              │ then reports them upward                       │
│              ▼                                                │
│      API server holds a read only MIRROR POD                  │
│        name: kube-apiserver-cp-01                             │
│        (pod name + "-" + node name)                           │
└──────────────────────────────────────────────────────────────┘
```

Key facts:

- The manifest directory is set by `staticPodPath` in the kubelet configuration file (historically the `--pod-manifest-path` flag). The kubeadm default is `/etc/kubernetes/manifests`.
- The kubelet polls the directory; dropping a file in creates the Pod, removing it deletes the Pod.
- The **mirror pod** in the API server exists so that `kubectl get pods -A` shows the control plane. It carries the annotation `kubernetes.io/config.mirror`.
- `kubectl delete pod <mirror-pod>` deletes the mirror object; the kubelet immediately recreates it because the manifest file is still on disk. The only way to remove a static pod is to remove or move its file.
- Static pods cannot reference ConfigMaps, Secrets or ServiceAccounts, because those require API server lookups that may not be available.
- The scheduler is not involved. `spec.nodeName` is set by the kubelet.

```bash
# Where does this kubelet read static pods from?
sudo grep staticPodPath /var/lib/kubelet/config.yaml

# Create a static pod
sudo tee /etc/kubernetes/manifests/nginx-static.yaml >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nginx-static
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
EOF

# It appears as nginx-static-<nodename>
kubectl get pods -o wide | grep nginx-static

# Remove it (the ONLY correct way)
sudo rm /etc/kubernetes/manifests/nginx-static.yaml
```

---

## Pod Networking

Kubernetes mandates a flat network model with three rules:

1. Every Pod gets its own IP address.
2. Pods can reach every other Pod without NAT.
3. Agents on a node (kubelet, system daemons) can reach all Pods on that node.

```
┌────────────────────────────────────────────────────────────────┐
│  Node A  10.0.1.10                  Node B  10.0.1.11           │
│  ┌──────────────────────┐           ┌──────────────────────┐   │
│  │ Pod web  10.244.1.5  │           │ Pod api  10.244.2.9  │   │
│  │  ┌──────┐ ┌───────┐  │           │  ┌──────┐            │   │
│  │  │ app  │ │sidecar│  │           │  │ app  │            │   │
│  │  │:8080 │ │       │  │           │  │:9000 │            │   │
│  │  └───┬──┘ └───┬───┘  │           │  └──────┘            │   │
│  │      └─localhost┘    │           │                      │   │
│  │        eth0          │           │        eth0          │   │
│  └─────────┬────────────┘           └─────────┬────────────┘   │
│         veth pair                          veth pair            │
│            │                                  │                 │
│         cni0 / bridge                      cni0 / bridge        │
│            │                                  │                 │
│      ──────┴──────── node network / overlay ──┴──────           │
│                                                                 │
│  web → api:  10.244.1.5 → 10.244.2.9   NO NAT                   │
│  app → sidecar: 127.0.0.1              same netns               │
└────────────────────────────────────────────────────────────────┘
```

Implications:

- The Pod IP is assigned by the CNI plugin when the sandbox is created, not by Kubernetes itself. See [CNI](cni.md) and [IPAM](ipam.md).
- The Pod IP is **not stable**. A replacement Pod almost always gets a different IP. Never hardcode Pod IPs; use a Service.
- `status.podIPs` is a list to support dual stack. `status.podIP` is always `podIPs[0]`.
- Pod to Pod traffic bypasses `kube-proxy` entirely. `kube-proxy` only handles Service virtual IPs. See [kube-proxy](kube-proxy.md).
- NetworkPolicies act on Pod labels and are enforced by the CNI plugin. See [Network Policy](network-policy.md).

Full treatment: [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md).

---

## Resources, Requests, Limits and QoS Classes

### What Requests and Limits Actually Do

| | `requests` | `limits` |
|---|---|---|
| **Consumer** | The **scheduler** | The **kubelet and the kernel** (via cgroups) |
| **CPU effect** | Sets `cpu.weight` / `cpu.shares`, the relative share under contention | Sets `cpu.max` / CFS quota. Exceeding it causes **throttling**, never a kill |
| **Memory effect** | No kernel enforcement; used for placement only | Sets `memory.max` / `memory.limit_in_bytes`. Exceeding it causes an **OOM kill** |
| **If omitted** | Scheduler assumes 0, so the node can be massively oversubscribed | The container may consume all node capacity |

The crucial asymmetry: **CPU is compressible, memory is not.** A container over its CPU limit is slowed down. A container over its memory limit is killed by the kernel OOM killer, and the container status shows `OOMKilled` with exit code 137.

CPU units: `1` = one core = `1000m`. `250m` is a quarter core. Fractional values below `1m` are not allowed.
Memory units: plain bytes, SI suffixes `k, M, G, T, P, E`, or binary suffixes `Ki, Mi, Gi, Ti, Pi, Ei`. Note `128M` (128,000,000) is not `128Mi` (134,217,728).

⚠ A very common YAML bug: `memory: 128m` means 0.128 bytes, which the API accepts and which will make the container fail instantly. The correct value is `128Mi` or `128M`.

### The Effective Pod Request

The scheduler does not simply sum every container. Because init containers run sequentially and regular containers run in parallel:

```
effective_request(resource) = max(
    max(init_containers[i].requests[resource]),   # the largest single init container
    sum(regular_containers[i].requests[resource]) # plus sidecars in initContainers
                                                  # with restartPolicy: Always, which
                                                  # ARE summed because they keep running
)
```

Plus any Pod overhead contributed by the RuntimeClass (`spec.overhead`).

### The Three QoS Classes

The kubelet computes `status.qosClass` at admission. It is not settable and it is not changeable.

```
┌─────────────────────────────────────────────────────────────────┐
│ Guaranteed                                                       │
│   EVERY container (including init containers) has BOTH           │
│   a cpu limit and a memory limit, AND                            │
│   requests == limits for both.                                   │
│   → Last to be evicted. oom_score_adj = -997.                    │
│   → Eligible for exclusive CPUs with the static CPU manager      │
│     policy when the CPU request is a whole integer.              │
├─────────────────────────────────────────────────────────────────┤
│ Burstable                                                        │
│   Not Guaranteed, but at least one container sets a cpu or       │
│   memory request or limit.                                       │
│   → Evicted after BestEffort. oom_score_adj computed from the    │
│     memory request relative to node capacity: a Pod using much   │
│     more than it requested is killed first.                      │
├─────────────────────────────────────────────────────────────────┤
│ BestEffort                                                       │
│   NO container sets ANY request or limit.                        │
│   → First to be evicted under node pressure.                     │
│     oom_score_adj = 1000, the maximum, so the kernel picks       │
│     these first.                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Worked examples:

```yaml
# QoS: Guaranteed
resources:
  requests: {cpu: "500m", memory: "512Mi"}
  limits:   {cpu: "500m", memory: "512Mi"}
```

```yaml
# QoS: Burstable  (requests != limits)
resources:
  requests: {cpu: "250m", memory: "256Mi"}
  limits:   {cpu: "1",    memory: "1Gi"}
```

```yaml
# QoS: Burstable  (memory is fully specified but cpu limit is missing)
resources:
  requests: {memory: "256Mi"}
  limits:   {memory: "256Mi"}
```

```yaml
# QoS: BestEffort
resources: {}
```

```yaml
# QoS: Burstable, NOT Guaranteed.
# Container A is fully specified with requests == limits, but container B
# is not, and Guaranteed requires EVERY container to qualify.
containers:
  - name: a
    resources:
      requests: {cpu: "100m", memory: "128Mi"}
      limits:   {cpu: "100m", memory: "128Mi"}
  - name: b
    resources: {}
```

```bash
kubectl get pod myapp -o jsonpath='{.status.qosClass}{"\n"}'
```

### LimitRange and ResourceQuota Interaction

A `LimitRange` in the namespace can inject default `requests` and `limits` into containers that omit them, which silently changes the QoS class from BestEffort to Burstable. A `ResourceQuota` that constrains `requests.cpu` or `limits.memory` makes those fields **mandatory**: a Pod that omits them is rejected at admission with a message naming the quota.

### Ephemeral Storage

`ephemeral-storage` requests and limits cover the container writable layer, `emptyDir` volumes and container logs. Exceeding the limit causes the kubelet to **evict** the Pod with reason `Evicted` and a message about local ephemeral storage usage. This surprises people because it is not an OOM kill and there is no signal to the process.

Cgroup mechanics are covered in [Cgroups](cgroups.md).

---

## Pod Status, Conditions and Container Statuses

Three different layers report health and they answer different questions. Confusing them is the single most common source of bad troubleshooting.

```
┌──────────────────────────────────────────────────────────────────┐
│ status.phase          "Where is this Pod in its overall life?"    │
│                       ONE value: Pending|Running|Succeeded|       │
│                                  Failed|Unknown                   │
│                       COARSE. Never use it alone for automation.  │
├──────────────────────────────────────────────────────────────────┤
│ status.conditions[]   "Which specific gates have been passed?"    │
│                       PodScheduled, PodReadyToStartContainers,    │
│                       Initialized, ContainersReady, Ready,        │
│                       DisruptionTarget, plus readinessGates       │
│                       Each has status True|False|Unknown,         │
│                       plus reason, message, lastTransitionTime.   │
├──────────────────────────────────────────────────────────────────┤
│ status.containerStatuses[]  "What is each container doing?"       │
│                       state: waiting|running|terminated           │
│                       lastState, ready, started, restartCount,    │
│                       image, imageID, containerID                 │
│                       THIS is where the real error message lives. │
└──────────────────────────────────────────────────────────────────┘
```

### Phases

| Phase | Meaning |
|-------|---------|
| `Pending` | Accepted by the cluster but not all containers are running. Covers waiting for scheduling, image pulls, volume attach and init containers. |
| `Running` | Bound to a node, all containers created, at least one container running or starting or restarting. |
| `Succeeded` | All containers terminated with success and will not be restarted. Only reachable with `restartPolicy` `OnFailure` or `Never`. |
| `Failed` | All containers terminated and at least one exited non zero or was terminated by the system. |
| `Unknown` | The state could not be obtained, usually because the node is unreachable. |

A Pod with `restartPolicy: Always` can **never** reach `Succeeded` or `Failed` by exiting; it will loop in `Running` with a growing restart count.

### Conditions

| Condition | Set True when |
|-----------|---------------|
| `PodScheduled` | The scheduler has bound the Pod to a node. |
| `PodReadyToStartContainers` | The sandbox exists and networking is configured. (Earlier releases named this `PodHasNetwork`.) |
| `Initialized` | All init containers have completed successfully. |
| `ContainersReady` | All containers report `ready: true`. |
| `Ready` | `ContainersReady` is True **and** every `readinessGate` condition is True. This is what makes the Pod an eligible Service endpoint. |
| `DisruptionTarget` | Present with status True when the Pod is about to be terminated by preemption, node pressure eviction or API initiated eviction. `reason` says which. |

```bash
kubectl get pod myapp -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
```

Example output:

```
PodReadyToStartContainers   True
Initialized                 True
Ready                       False   ContainersNotReady
ContainersReady             False   ContainersNotReady
PodScheduled                True
```

That tells you instantly: scheduling and init succeeded, the app is up but failing its readiness probe.

### Container States

```yaml
status:
  containerStatuses:
    - name: app
      ready: false
      started: false
      restartCount: 7
      image: registry.example.com/app:v1
      imageID: registry.example.com/app@sha256:9f2c...
      containerID: containerd://3a91b0...
      state:
        waiting:
          reason: CrashLoopBackOff
          message: "back-off 2m40s restarting failed container=app pod=app-xyz(...)"
      lastState:
        terminated:
          exitCode: 1
          reason: Error
          startedAt: "2026-09-05T10:14:02Z"
          finishedAt: "2026-09-05T10:14:03Z"
          containerID: containerd://3a91b0...
```

`state` is now. `lastState` is the **previous** incarnation and it is where the real cause of a crash loop lives. `ready` reflects the readiness probe. `started` reflects the startup probe.

Reason strings are enumerated with their fixes in [Pod Lifecycle](pod-lifecycle.md).

---

## Pod Immutability: What You Can Actually Change

Once a Pod is admitted, the API server rejects almost every spec change with `Pod updates may not change fields other than ...`.

| Field | Mutable? | Notes |
|-------|----------|-------|
| `metadata.labels` | ✅ | Always. Changing a label can add or remove the Pod from a Service. |
| `metadata.annotations` | ✅ | Always. |
| `spec.containers[*].image` | ✅ | This is what `kubectl set image` uses. Triggers a container restart. |
| `spec.initContainers[*].image` | ✅ | Same. |
| `spec.activeDeadlineSeconds` | ✅ | Can be set from unset to a positive value, or decreased. Cannot be unset. |
| `spec.tolerations` | ✅ | **Additions only.** Existing entries cannot be modified or removed. |
| `spec.terminationGracePeriodSeconds` | Partial | Only settable to `1` as part of a delete request. |
| `spec.containers[*].resources` | Feature gated | In place vertical scaling (`InPlacePodVerticalScaling`) permits CPU and memory resize on running Pods; availability depends on your cluster version and gates. |
| Everything else | ❌ | `env`, `volumes`, `volumeMounts`, `command`, `args`, `nodeSelector`, `restartPolicy`, `securityContext`, probes, resources without the gate. |

The practical consequence: to change a Pod you replace it. This is exactly why controllers exist. A Deployment rolls out a new ReplicaSet with a new Pod template rather than editing live Pods. See [Controllers](controllers.md) and [Deployments](deployments.md).

`kubectl replace --force -f pod.yaml` works only because it deletes and recreates the object.

---

## Troubleshooting

### Systematic First Pass

```bash
# 1. Overall picture with node placement and IPs
kubectl get pod <pod> -o wide

# 2. Events and the full container status breakdown
kubectl describe pod <pod>

# 3. Namespace wide events, newest last
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -30

# 4. Current logs, then the logs of the PREVIOUS crashed incarnation
kubectl logs <pod> -c <container>
kubectl logs <pod> -c <container> --previous

# 5. The raw truth
kubectl get pod <pod> -o yaml | less
```

### Symptom Table

| Symptom | Where to look first | Common causes |
|---------|--------------------|----------------|
| `Pending`, no node assigned | `kubectl describe pod`, Events, `FailedScheduling` | Insufficient cpu/memory, unsatisfied nodeSelector or affinity, untolerated taint, unbound PVC, topology spread cannot be satisfied |
| `Pending`, node assigned | Events, kubelet logs on that node | Image pull in progress, volume attach or mount failure, `CreateContainerConfigError` |
| `ContainerCreating` stuck | `describe`, then `journalctl -u kubelet` on the node | CNI failure (no IP available), volume mount timeout, missing ConfigMap or Secret |
| `ImagePullBackOff` | `describe` Events | Wrong image name or tag, private registry with no `imagePullSecrets`, registry rate limit, node has no route to the registry |
| `CrashLoopBackOff` | `kubectl logs --previous` | Application error, missing config, bad `command`, immediate exit, failing liveness probe |
| `OOMKilled` | `lastState.terminated.reason` | Memory limit too low, or a real leak. Check the JVM/Node heap settings against the limit |
| `Running` but `0/1` READY | `describe`, readiness probe config | Probe path wrong, probe port wrong, `initialDelaySeconds` too short, dependency not reachable |
| Terminating forever | `kubectl get pod -o yaml`, look at `metadata.finalizers` | A finalizer whose controller is gone, unresponsive process ignoring SIGTERM, node unreachable |
| `Evicted` | `describe`, node conditions | Node memory or disk pressure; BestEffort and over request Burstable Pods go first |
| `CreateContainerConfigError` | `describe` Events | Referenced ConfigMap or Secret key does not exist |
| `InvalidImageName` | `describe` | Malformed image reference, for example an uppercase repository name |

### Inspecting the Shared Namespaces on a Node

```bash
# Find the node
kubectl get pod <pod> -o jsonpath='{.spec.nodeName}{"\n"}'

# On that node: find the sandbox
sudo crictl pods --name <pod> -q

# Container IDs in the pod
sudo crictl ps --pod <SANDBOX_ID> -q

# The PID of a container's main process
sudo crictl inspect <CONTAINER_ID> | jq '.info.pid'

# Compare namespace inode numbers between two containers in the SAME pod.
# net, ipc and uts must match. mnt must differ. pid differs unless shared.
sudo ls -Li /proc/<PID_A>/ns/{net,ipc,uts,pid,mnt}
sudo ls -Li /proc/<PID_B>/ns/{net,ipc,uts,pid,mnt}

# Enter the pod's network namespace from the node
sudo nsenter -t <PID> -n ip addr
sudo nsenter -t <PID> -n ss -lntp
```

### Verifying Shared Networking From Inside

```bash
# Both containers must report the same IP
kubectl exec <pod> -c app     -- hostname -i
kubectl exec <pod> -c sidecar -- hostname -i

# Both must report the same hostname (shared UTS)
kubectl exec <pod> -c app     -- hostname
kubectl exec <pod> -c sidecar -- hostname

# Mount namespaces differ: this file exists only in the container that made it
kubectl exec <pod> -c app     -- sh -c 'touch /tmp/proof'
kubectl exec <pod> -c sidecar -- ls /tmp/proof     # No such file or directory
```

### Resource and QoS Checks

```bash
# What QoS class did this Pod get?
kubectl get pod <pod> -o jsonpath='{.status.qosClass}{"\n"}'

# Requests and limits per container
kubectl get pod <pod> -o jsonpath=\
'{range .spec.containers[*]}{.name}{"\treq="}{.resources.requests}{"\tlim="}{.resources.limits}{"\n"}{end}'

# Node allocatable vs allocated
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'

# Live usage (requires metrics-server)
kubectl top pod <pod> --containers
```

### Debugging a Distroless Image

```bash
# No shell in the image? Attach an ephemeral container sharing the PID namespace
kubectl debug -it <pod> --image=busybox:1.36 --target=app -- sh

# Inside, the app's filesystem is reachable via /proc/<pid>/root
ps aux
ls /proc/1/root/app
```

---

## Exam and Interview Traps

1. **Mount namespaces are NOT shared.** Network, IPC and UTS are. PID is opt in via `shareProcessNamespace`. If someone says "containers in a Pod share the filesystem", they are wrong: they share **declared volumes**, and even then at possibly different mount paths.

2. **A container restart is not a Pod restart.** There is no such thing as "restarting a Pod". The `RESTARTS` column counts container restarts inside the same sandbox, with the same Pod IP.

3. **`restartPolicy` is Pod wide and immutable**, and it defaults to `Always`. A Pod with `restartPolicy: Always` can never reach `Succeeded`.

4. **`imagePullPolicy` default depends on the tag.** No tag or `:latest` gives `Always`; any other tag gives `IfNotPresent`.

5. **`command` maps to ENTRYPOINT, `args` maps to CMD.** Not the other way round. And setting `command` discards the image's CMD.

6. **`ports` is informational.** Omitting it does not block traffic. `hostPort` is the exception and it is a real constraint.

7. **Guaranteed QoS requires EVERY container** (including init containers) to set both a CPU limit and a memory limit with requests equal to limits. One unconstrained sidecar downgrades the whole Pod to Burstable.

8. **`128m` of memory is 0.128 bytes.** You meant `128Mi`. The API will accept the typo.

9. **Exceeding a CPU limit throttles; exceeding a memory limit kills.** CPU is compressible, memory is not.

10. **`nodeName` bypasses the scheduler entirely**, including all fit and taint checks. `nodeSelector` does not.

11. **`hostNetwork: true` with the default `dnsPolicy: ClusterFirst` breaks cluster DNS.** You need `ClusterFirstWithHostNet`.

12. **Deleting a mirror pod does nothing permanent.** Remove the manifest file from `staticPodPath` on the node.

13. **The Pod spec is essentially immutable.** Only `image`, `activeDeadlineSeconds`, added `tolerations`, labels and annotations can change. You cannot `kubectl edit` a Pod's `env` or `resources` (absent the in place resize feature gate).

14. **`status.phase` is not `Ready`.** A Pod can be `Running` and `0/1 READY` and receive zero Service traffic. Automation must look at the `Ready` condition, not the phase.

15. **`subPath` freezes ConfigMap and Secret updates.** Drop `subPath` if you need live refresh.

16. **A bare Pod is not self healing.** If the node dies, nothing recreates it. That is a controller's job.

17. **`/dev/shm` defaults to a small size** (commonly 64 MiB). Mount a memory backed `emptyDir` to enlarge it, and remember that memory counts against the Pod limit.

18. **Init containers do not sum for scheduling.** The effective init request is the **maximum** of the init containers, not the sum, because they run one at a time. Native sidecars in `initContainers` are the exception: they are summed with the regular containers.

19. **`kubectl run` creates a Pod, not a Deployment**, in current kubectl versions. Use `kubectl create deployment` for a Deployment.

20. **`enableServiceLinks` defaults to true**, injecting an environment variable pair for every Service in the namespace. In large namespaces this bloats the environment and can break `exec` on some shells.

---

## Related Topics

- [Pod Lifecycle](pod-lifecycle.md)
- [Pod Operations](pod-operations.md)
- [Pause Containers](pause-containers.md)
- [Linux Namespaces](linux-namespaces.md)
- [Cgroups](cgroups.md)
- [Containers](containers.md)
- [Container Runtime](container-runtime.md)
- [Kubelet](kubelet.md)
- [kube-scheduler](kube-scheduler.md)
- [Kubernetes API](k8s-api.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
- [CNI](cni.md)
- [IPAM](ipam.md)
- [Network Policy](network-policy.md)
- [CoreDNS](coredns.md)
- [Controllers](controllers.md)
- [Deployments](deployments.md)
- [ReplicaSets](replicasets.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [Jobs](jobs.md)

---

## Key Takeaways

1. A Pod is a **co-location and co-scheduling boundary**, not a container. It exists so that tightly coupled processes can share namespaces, volumes and a single network identity while being scheduled atomically.
2. Containers in a Pod **always** share the network, IPC and UTS namespaces, **optionally** share the PID namespace, and **never** share the mount namespace. Sharing files requires an explicit volume.
3. The **pause container** owns the shared namespaces so that they survive individual container crashes, which is why a container restart never changes the Pod IP.
4. `command` is ENTRYPOINT and `args` is CMD. Setting `command` discards the image CMD, and there is no shell unless you invoke one.
5. `requests` drive **scheduling**; `limits` drive **kernel enforcement**. CPU over limit is throttled, memory over limit is OOM killed with exit code 137.
6. The three QoS classes are computed, not declared. **Guaranteed** requires every container to set CPU and memory limits equal to their requests.
7. Init containers run sequentially to completion; an init container with `restartPolicy: Always` is a **native sidecar** that starts before, and shuts down after, the main containers.
8. **Ephemeral containers** are the supported way to debug images with no shell, and they can only be added through the `pods/ephemeralcontainers` subresource.
9. **Static pods** are owned by the kubelet on disk; the mirror pod in the API server is read only and recreating it is pointless.
10. The Pod spec is **effectively immutable**. Changing a workload means replacing Pods, which is precisely the job of controllers.
11. `status.phase`, `status.conditions` and `status.containerStatuses` answer three different questions. The actual error message almost always lives in `containerStatuses[].state` or `lastState`.
12. Prefer **one container per Pod**. Add a sidecar, ambassador or adapter only when a shared namespace or volume is genuinely required.

---

## References

- [Pods](https://kubernetes.io/docs/concepts/workloads/pods/)
- [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)
- [Sidecar Containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/)
- [Ephemeral Containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/)
- [Static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
- [Share Process Namespace Between Containers in a Pod](https://kubernetes.io/docs/tasks/configure-pod-container/share-process-namespace/)
- [Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Pod Quality of Service Classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/)
- [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- [Volumes](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Downward API](https://kubernetes.io/docs/concepts/workloads/pods/downward-api/)
- [Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/)
- [Pod API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
