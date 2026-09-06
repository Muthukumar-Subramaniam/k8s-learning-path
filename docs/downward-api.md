# 📡 Downward API: Exposing Pod Metadata to Containers

A complete guide to the Downward API: how a container learns its own name, namespace, node, IP, labels, annotations and resource allocation, without a single API call and without any Kubernetes client library.

## 📋 Table of Contents
- [The Problem It Solves](#the-problem-it-solves)
- [The Two Mechanisms](#the-two-mechanisms)
- [Fields Available via fieldRef](#fields-available-via-fieldref)
- [resourceFieldRef and the Divisor](#resourcefieldref-and-the-divisor)
- [Environment Variables in Practice](#environment-variables-in-practice)
- [downwardAPI Volumes in Practice](#downwardapi-volumes-in-practice)
- [The Complete Manifest](#the-complete-manifest)
- [Exact Output From the Running Pod](#exact-output-from-the-running-pod)
- [Live Updates: What Refreshes and What Does Not](#live-updates-what-refreshes-and-what-does-not)
- [Practical Use Cases](#practical-use-cases)
- [Downward API vs ConfigMap vs Secret vs the API](#downward-api-vs-configmap-vs-secret-vs-the-api)
- [Combining Sources in a Projected Volume](#combining-sources-in-a-projected-volume)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The Problem It Solves

An application frequently needs to know things about itself that are decided **after** the image is built and often after the Pod spec is written:

- Which Pod am I? The name includes a ReplicaSet hash and a random suffix that nobody could have written down in advance.
- Which namespace am I in? The same Deployment manifest is applied to `dev`, `staging` and `production`.
- Which node am I on? Assigned by the scheduler, not by you.
- What is my Pod IP? Assigned by the CNI plugin at sandbox creation.
- How much memory am I actually allowed? The limit may be patched, defaulted by a `LimitRange`, or overridden per environment.

### The Bad Answers

```
┌─────────────────────────────────────────────────────────────────────┐
│                 Three Ways To Get This Wrong                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ❌ HARDCODE IT                                                      │
│     env:                                                             │
│     - name: POD_NAME                                                 │
│       value: "myapp-7d4b9c8f5-x2k9p"     ← wrong on every replica    │
│                                            and after every rollout   │
│                                                                      │
│  ❌ CALL THE API SERVER                                              │
│     The container needs a ServiceAccount token, RBAC granting        │
│     `get pods`, a Kubernetes client library, TLS trust for the       │
│     API server, retry logic, and it fails to start if the API        │
│     server is briefly unavailable. All to learn its own name.        │
│     Worse, `get pods` in a namespace is a meaningful privilege.      │
│                                                                      │
│  ❌ GUESS FROM THE ENVIRONMENT                                       │
│     hostname() returns the Pod name only by coincidence of the       │
│     default setup, and is wrong the moment `hostname` or             │
│     `setHostnameAsFQDN` or a subdomain is configured. The node       │
│     name, namespace and labels are simply not derivable at all.      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### The Good Answer

The **Downward API** projects selected fields from the Pod object into the container, either as environment variables or as files, at container creation time. The kubelet already has the Pod object in hand; no extra credential, no extra network call, no client library, no RBAC.

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Downward API Data Flow                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   kube-apiserver                                                     │
│         │                                                            │
│         │  the kubelet already watches Pods bound to its node,       │
│         │  so it holds the full Pod object locally                   │
│         ▼                                                            │
│      kubelet                                                         │
│         │                                                            │
│         ├──► env vars ──────► container process environment          │
│         │                     (set at execve, frozen thereafter)     │
│         │                                                            │
│         └──► downwardAPI ───► files in a volume                      │
│                volume         (labels and annotations refreshed)     │
│                                                                      │
│   No token. No RBAC. No API call from the container. No library.     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

The name is literal: information flows **downward** from the Pod object to the container running inside it. There is no upward equivalent; a container cannot modify its own Pod object through this mechanism.

---

## The Two Mechanisms

```
┌─────────────────────────────────────────────────────────────────────┐
│              Environment Variables      vs      Volume Files         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  env[].valueFrom.fieldRef          │  volumes[].downwardAPI.items[]  │
│  env[].valueFrom.resourceFieldRef  │    .fieldRef                    │
│                                    │    .resourceFieldRef            │
│  ──────────────────────────────────┼──────────────────────────────── │
│  set at container start            │  written at container start     │
│  FROZEN forever                    │  labels/annotations REFRESH     │
│  one value per variable            │  one value per file             │
│  cannot expose the full label set  │  CAN expose all labels and      │
│  cannot expose all annotations     │    all annotations              │
│  can expose spec.nodeName,         │  CANNOT expose nodeName,        │
│    status.podIP, status.hostIP,    │    podIP, hostIP or             │
│    spec.serviceAccountName         │    serviceAccountName           │
│  read with getenv()                │  read with open()/read()        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Neither mechanism is a superset of the other. That asymmetry is the single most important structural fact about the Downward API, and it is why real manifests almost always use both.

### Two Selector Types

Both mechanisms accept two kinds of selector:

| Selector | Selects from | Example |
|----------|--------------|---------|
| `fieldRef` | The Pod object itself | `metadata.name`, `spec.nodeName`, `status.podIP` |
| `resourceFieldRef` | A **container's** resource requests and limits | `limits.memory`, `requests.cpu` |

`fieldRef` uses a JSONPath style `fieldPath` against the Pod. `resourceFieldRef` names a container and a resource, plus an optional `divisor` controlling the unit.

---

## Fields Available via fieldRef

```
╔══════════════════════════════════════════════════════════════════════╗
║   The two field sets are DIFFERENT. This is examined constantly.     ║
╚══════════════════════════════════════════════════════════════════════╝
```

### Available in Environment Variables

| `fieldPath` | Value |
|-------------|-------|
| `metadata.name` | The Pod name |
| `metadata.namespace` | The Pod's namespace |
| `metadata.uid` | The Pod's UID |
| `spec.nodeName` | The node the Pod is scheduled on |
| `spec.serviceAccountName` | The Pod's ServiceAccount |
| `status.hostIP` | The node's IP address |
| `status.podIP` | The Pod's primary IP address |
| `status.podIPs` | The Pod's IP addresses, comma separated (dual stack) |
| `metadata.labels['<KEY>']` | The value of one named label |
| `metadata.annotations['<KEY>']` | The value of one named annotation |

### Available in a downwardAPI Volume

| `fieldPath` | Value |
|-------------|-------|
| `metadata.name` | The Pod name |
| `metadata.namespace` | The Pod's namespace |
| `metadata.uid` | The Pod's UID |
| `metadata.labels` | **All** labels, one `key="value"` line per label |
| `metadata.annotations` | **All** annotations, one `key="value"` line per annotation |
| `metadata.labels['<KEY>']` | The value of one named label |
| `metadata.annotations['<KEY>']` | The value of one named annotation |

### The Two Exclusive Sets, Side by Side

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│   ENV ONLY (not available in a volume):                              │
│     spec.nodeName                                                    │
│     spec.serviceAccountName                                          │
│     status.hostIP                                                    │
│     status.podIP                                                     │
│     status.podIPs                                                    │
│                                                                      │
│   VOLUME ONLY (not available as an env var):                         │
│     metadata.labels          (the COMPLETE set)                      │
│     metadata.annotations     (the COMPLETE set)                      │
│                                                                      │
│   BOTH:                                                              │
│     metadata.name                                                    │
│     metadata.namespace                                               │
│     metadata.uid                                                     │
│     metadata.labels['key']       (a SINGLE named label)              │
│     metadata.annotations['key']  (a SINGLE named annotation)         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Two consequences people trip over constantly:

1. **You cannot get the node name from a volume.** Attempting it is a validation error at Pod creation, not a runtime surprise.
2. **You cannot get the whole label set as an environment variable.** You can get one label at a time by name, and only if you know the name in advance. The complete, dynamic set requires a volume.

The status fields are also conceptually unsuited to a volume: they are populated after the Pod is bound and can change, and the volume field set is deliberately restricted to metadata that is either stable or genuinely mutable in a well defined way.

### Syntax: fieldRef in an Environment Variable

```yaml
    env:
    - name: POD_NAME
      valueFrom:
        fieldRef:
          apiVersion: v1              # optional, defaults to v1
          fieldPath: metadata.name
```

### Syntax: Selecting a Single Label or Annotation

The key goes inside single quotes, inside square brackets. The whole `fieldPath` must then be quoted in YAML because it contains characters YAML would otherwise interpret:

```yaml
    env:
    - name: APP_VERSION
      valueFrom:
        fieldRef:
          fieldPath: "metadata.labels['app.kubernetes.io/version']"
    - name: DEPLOY_REVISION
      valueFrom:
        fieldRef:
          fieldPath: "metadata.annotations['deployment.kubernetes.io/revision']"
```

```
┌────────────────────────────────────────────────────────────────────┐
│              Single Label Selection: Exact Syntax                   │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ✅ fieldPath: "metadata.labels['app']"                             │
│  ✅ fieldPath: "metadata.labels['app.kubernetes.io/name']"          │
│                                                                     │
│  ❌ fieldPath: metadata.labels[app]        no quotes inside         │
│  ❌ fieldPath: metadata.labels."app"       wrong bracket style      │
│  ❌ fieldPath: metadata.labels['app']      unquoted outer value;    │
│                                            YAML may mis-parse it    │
│                                                                     │
│  If the named label does not exist, the environment variable is     │
│  simply not set. It is NOT an error and the Pod starts normally.    │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### An Invalid fieldPath Is Rejected at Creation

```yaml
    env:
    - name: NODE
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeNmae        # typo
```

```
The Pod "demo" is invalid: spec.containers[0].env[0].valueFrom.fieldRef.fieldPath:
Invalid value: "spec.nodeNmae": error converting fieldPath: field label not
supported: spec.nodeNmae
```

This is a validation error, so the Pod is never created. You find out immediately, which is a real advantage over configuration that fails at runtime.

---

## resourceFieldRef and the Divisor

`resourceFieldRef` exposes a **container's** resource requests and limits. Unlike `fieldRef`, it is available in both environment variables and volumes with the same field set.

### Available Resources

```
requests.cpu                 limits.cpu
requests.memory              limits.memory
requests.ephemeral-storage   limits.ephemeral-storage
requests.hugepages-<size>    limits.hugepages-<size>
```

### Syntax

```yaml
    env:
    - name: MEMORY_LIMIT
      valueFrom:
        resourceFieldRef:
          containerName: app          # optional in env, defaults to this container
          resource: limits.memory
          divisor: 1Mi
```

In a **volume**, `containerName` is **required**, because a volume is defined at Pod level and has no implicit container context:

```yaml
  volumes:
  - name: podinfo
    downwardAPI:
      items:
      - path: "cpu_limit"
        resourceFieldRef:
          containerName: app          # REQUIRED here
          resource: limits.cpu
          divisor: 1m
```

### The Divisor

`divisor` controls the **unit** of the reported value. The reported number is the resource quantity divided by the divisor, **rounded up to the nearest integer**.

```
value_reported = ceil(resource_quantity / divisor)
```

The default divisor is `1`, meaning **cores** for CPU and **bytes** for memory and storage.

#### CPU Divisors

| `limits.cpu` | `divisor` | Reported |
|--------------|-----------|----------|
| `500m` | `1` (default) | `1` (ceil of 0.5) |
| `500m` | `1m` | `500` |
| `2` | `1` | `2` |
| `2` | `1m` | `2000` |
| `1500m` | `1` | `2` (ceil of 1.5) |
| `1500m` | `1m` | `1500` |
| `100m` | `1` | `1` (ceil of 0.1) |
| `2500m` | `1` | `3` |

```
╔══════════════════════════════════════════════════════════════════════╗
║  ⚠️  The default CPU divisor of 1 rounds UP to whole cores.          ║
║                                                                       ║
║      A container limited to 100m (one tenth of a core) reports 1.     ║
║      A container limited to 2500m reports 3.                          ║
║                                                                       ║
║      This is why setting GOMAXPROCS from limits.cpu with the          ║
║      default divisor massively over provisions threads on small       ║
║      containers, and why you should almost always use divisor: 1m     ║
║      and do the arithmetic yourself.                                  ║
╚══════════════════════════════════════════════════════════════════════╝
```

#### Memory Divisors

| `limits.memory` | `divisor` | Reported | Meaning |
|-----------------|-----------|----------|---------|
| `1Gi` | `1` (default) | `1073741824` | bytes |
| `1Gi` | `1Ki` | `1048576` | KiB |
| `1Gi` | `1Mi` | `1024` | MiB |
| `1Gi` | `1Gi` | `1` | GiB |
| `512Mi` | `1Mi` | `512` | MiB |
| `512Mi` | `1Gi` | `1` | ceil(0.5) GiB |
| `1500Mi` | `1Gi` | `2` | ceil(1.46) GiB |
| `1G` | `1Mi` | `954` | ceil(1000000000 / 1048576) |

Both binary suffixes (`Ki`, `Mi`, `Gi`, `Ti`, `Pi`, `Ei`) and decimal suffixes (`k`, `M`, `G`, `T`, `P`, `E`) are valid quantities. Mixing them is where arithmetic surprises come from: `1G` is 1,000,000,000 bytes while `1Gi` is 1,073,741,824 bytes.

#### Worked Example: Millicores

```yaml
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        cpu: 1500m
        memory: 1Gi
    env:
    - name: CPU_REQUEST_MILLICORES
      valueFrom:
        resourceFieldRef:
          resource: requests.cpu
          divisor: 1m
    - name: CPU_LIMIT_MILLICORES
      valueFrom:
        resourceFieldRef:
          resource: limits.cpu
          divisor: 1m
```

```bash
$ kubectl exec demo -- sh -c 'echo "$CPU_REQUEST_MILLICORES $CPU_LIMIT_MILLICORES"'
250 1500
```

From millicores you can compute whatever you need without losing precision:

```sh
# whole cores, rounded down, minimum 1: the sane GOMAXPROCS
CORES=$(( CPU_LIMIT_MILLICORES / 1000 ))
[ "$CORES" -lt 1 ] && CORES=1
export GOMAXPROCS="$CORES"
```

#### Worked Example: MiB

```yaml
    resources:
      limits:
        memory: 1Gi
    env:
    - name: MEM_LIMIT_MIB
      valueFrom:
        resourceFieldRef:
          resource: limits.memory
          divisor: 1Mi
```

```bash
$ kubectl exec demo -- printenv MEM_LIMIT_MIB
1024
```

```sh
# 75 percent of the limit for a JVM heap, leaving room for metaspace,
# thread stacks, code cache and native allocations
HEAP=$(( MEM_LIMIT_MIB * 75 / 100 ))
export JAVA_OPTS="-Xmx${HEAP}m -Xms${HEAP}m"
```

### When No Limit Is Set

```
┌─────────────────────────────────────────────────────────────────────┐
│           limits.* When the Container Has No Limit                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  If a container does not specify limits.cpu or limits.memory,        │
│  the Downward API reports the NODE'S ALLOCATABLE amount for that     │
│  resource instead.                                                   │
│                                                                      │
│  Consequence:                                                        │
│    A container with NO memory limit on a 64Gi node reports a         │
│    "limit" of roughly 64Gi. A JVM sizing its heap from that value    │
│    will try to use the whole node, get OOM killed by the kernel,     │
│    and take the node's other workloads down with it.                 │
│                                                                      │
│    The same container on a 4Gi node reports roughly 4Gi and behaves  │
│    completely differently. Same manifest, same image, wildly         │
│    different behaviour depending on which node it landed on.         │
│                                                                      │
│  ✅ RULE: if you size anything from limits.*, SET AN EXPLICIT LIMIT. │
│     Treat "no limit plus Downward API sizing" as a bug.              │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Note that "allocatable" is the node's capacity minus reservations for the kubelet, the container runtime and eviction thresholds, so it is somewhat less than the node's physical total. That does not make it safe to size from.

`requests.*` behaves differently: a container with no request has an effective request of zero for that resource, so the Downward API reports `0`. Dividing by that value in a startup script is a classic crash.

```sh
# always guard
: "${MEM_LIMIT_MIB:=512}"
[ "$MEM_LIMIT_MIB" -le 0 ] && MEM_LIMIT_MIB=512
```

### Init Containers and Sidecars

`resourceFieldRef.containerName` may name any container in the Pod, including an init container. This lets a sidecar size itself relative to the main application, or lets a startup script inspect the main container's budget:

```yaml
    - name: APP_MEM_LIMIT_MIB
      valueFrom:
        resourceFieldRef:
          containerName: app          # the sidecar reads the APP's limit
          resource: limits.memory
          divisor: 1Mi
```

Naming a container that does not exist is a validation error at Pod creation.

---

## Environment Variables in Practice

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: downward-env
  namespace: production
  labels:
    app: myapp
    tier: backend
    app.kubernetes.io/version: "1.4.2"
  annotations:
    build.example.com/commit: "a3f9c21"
spec:
  serviceAccountName: myapp
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "env | grep -E '^(POD|NODE|HOST|SA|CPU|MEM|APP|BUILD)' | sort; sleep 3600"]
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        cpu: 1500m
        memory: 1Gi
    env:
    # ── Pod identity ────────────────────────────────────────────────
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid

    # ── Placement and networking ────────────────────────────────────
    - name: NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
    - name: HOST_IP
      valueFrom:
        fieldRef:
          fieldPath: status.hostIP
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: POD_IPS
      valueFrom:
        fieldRef:
          fieldPath: status.podIPs

    # ── Identity ────────────────────────────────────────────────────
    - name: SA_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.serviceAccountName

    # ── Individual labels and annotations ───────────────────────────
    - name: APP_VERSION
      valueFrom:
        fieldRef:
          fieldPath: "metadata.labels['app.kubernetes.io/version']"
    - name: BUILD_COMMIT
      valueFrom:
        fieldRef:
          fieldPath: "metadata.annotations['build.example.com/commit']"

    # ── Resources ───────────────────────────────────────────────────
    - name: CPU_REQUEST_MILLICORES
      valueFrom:
        resourceFieldRef:
          resource: requests.cpu
          divisor: 1m
    - name: CPU_LIMIT_MILLICORES
      valueFrom:
        resourceFieldRef:
          resource: limits.cpu
          divisor: 1m
    - name: MEM_REQUEST_MIB
      valueFrom:
        resourceFieldRef:
          resource: requests.memory
          divisor: 1Mi
    - name: MEM_LIMIT_MIB
      valueFrom:
        resourceFieldRef:
          resource: limits.memory
          divisor: 1Mi
```

### Using the Values in command and args

```yaml
    command: ["/app/server"]
    args:
    - "--instance-id=$(POD_NAME)"
    - "--advertise-addr=$(POD_IP):8080"
    - "--namespace=$(POD_NAMESPACE)"
```

The same `$(VAR)` rules apply as everywhere else in a Pod spec: expansion is done by the kubelet, not a shell; only variables defined **earlier in the same `env` list** are available; and `$$(FOO)` escapes to a literal `$(FOO)`.

### Building a Composite Value

Later `env` entries can reference earlier ones, which is how you build a fully qualified DNS name or a connection string:

```yaml
    env:
    - name: POD_NAME
      valueFrom:
        fieldRef: {fieldPath: metadata.name}
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef: {fieldPath: metadata.namespace}
    - name: SERVICE_NAME
      value: "myapp-headless"
    # references the three above, all defined earlier
    - name: POD_FQDN
      value: "$(POD_NAME).$(SERVICE_NAME).$(POD_NAMESPACE).svc.cluster.local"
```

```bash
$ kubectl exec downward-env -- printenv POD_FQDN
myapp-0.myapp-headless.production.svc.cluster.local
```

Order matters absolutely. Referencing a variable defined **later** in the list does not expand; the literal text `$(POD_NAME)` ends up in the value, which produces a confusing runtime failure rather than an error.

> 📖 **See Also**: [StatefulSets](statefulsets.md), where this exact pattern gives each replica its stable DNS name.

---

## downwardAPI Volumes in Practice

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: downward-vol
  labels:
    app: myapp
    tier: backend
    environment: production
  annotations:
    build.example.com/commit: "a3f9c21"
    kubectl.kubernetes.io/last-applied-configuration: "{...}"
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    resources:
      limits:
        cpu: 1500m
        memory: 1Gi
    volumeMounts:
    - name: podinfo
      mountPath: /etc/podinfo
      readOnly: true
  volumes:
  - name: podinfo
    downwardAPI:
      defaultMode: 0444
      items:
      # every label, one key="value" line per label
      - path: "labels"
        fieldRef:
          fieldPath: metadata.labels
      # every annotation, same format
      - path: "annotations"
        fieldRef:
          fieldPath: metadata.annotations
      # scalars
      - path: "name"
        fieldRef:
          fieldPath: metadata.name
      - path: "namespace"
        fieldRef:
          fieldPath: metadata.namespace
      - path: "uid"
        fieldRef:
          fieldPath: metadata.uid
      # a single label, into a nested path, with its own mode
      - path: "meta/tier"
        mode: 0400
        fieldRef:
          fieldPath: "metadata.labels['tier']"
      # resources: containerName is MANDATORY in a volume
      - path: "limits/cpu_millicores"
        resourceFieldRef:
          containerName: app
          resource: limits.cpu
          divisor: 1m
      - path: "limits/mem_mib"
        resourceFieldRef:
          containerName: app
          resource: limits.memory
          divisor: 1Mi
```

### Volume Field Reference

| Field | Notes |
|-------|-------|
| `items[].path` | **Required.** Relative path inside the volume. May contain `/` to create subdirectories. Must not be absolute and must not contain `..`. |
| `items[].fieldRef.fieldPath` | The Pod field to project. Restricted to the metadata set. |
| `items[].resourceFieldRef` | `containerName` is **required** here, along with `resource` and optional `divisor`. |
| `items[].mode` | Octal permission bits for that one file, overriding `defaultMode`. |
| `defaultMode` | Octal permission bits for every file in the volume. Defaults to `0644`. |

Exactly one of `fieldRef` or `resourceFieldRef` must be set per item. Setting both, or neither, is a validation error.

### The labels and annotations File Format

```bash
$ kubectl exec downward-vol -- cat /etc/podinfo/labels
app="myapp"
environment="production"
tier="backend"
```

```
┌────────────────────────────────────────────────────────────────────┐
│                Format of the labels/annotations Files               │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  • One entry per line                                               │
│  • key="value"                                                      │
│  • The VALUE is quoted; the KEY is not                              │
│  • Entries are sorted by key                                        │
│  • Special characters in the value are escaped                      │
│  • Keys with a prefix appear in full:                               │
│        app.kubernetes.io/name="myapp"                               │
│  • An empty label set produces an EMPTY FILE, not a missing one     │
│                                                                     │
│  Parsing note: this is close to, but not exactly, a shell or        │
│  properties file. Use a real parser, or at minimum handle the       │
│  surrounding quotes and the '/' in prefixed keys.                   │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Annotations are noisier than labels, because Kubernetes and its tooling add their own:

```bash
$ kubectl exec downward-vol -- cat /etc/podinfo/annotations
build.example.com/commit="a3f9c21"
kubectl.kubernetes.io/last-applied-configuration="{\"apiVersion\":\"v1\",...}"
kubernetes.io/config.seen="2026-09-05T10:12:44.123456789Z"
kubernetes.io/config.source="api"
```

Two practical warnings:

1. **`last-applied-configuration` can be very large.** Projecting all annotations into a file may produce a surprisingly big file containing an entire embedded manifest. If you only need one annotation, select it by name.
2. **The kubelet adds its own annotations** such as `kubernetes.io/config.seen` and `kubernetes.io/config.source`. Do not assume the file contains only what you wrote.

### No Trailing Newline on Scalars

```bash
$ kubectl exec downward-vol -- cat /etc/podinfo/name
downward-vol$                      # note: no newline before the prompt

$ kubectl exec downward-vol -- wc -c /etc/podinfo/name
12 /etc/podinfo/name               # exactly len("downward-vol")
```

Scalar values are written with no trailing newline. The `labels` and `annotations` files do end with a newline after the last entry, because each entry is a line. Shell scripts that use `read` need to account for this:

```sh
# ✅ works with or without a trailing newline
NAME=$(cat /etc/podinfo/name)

# ⚠️ `read` returns non-zero at EOF without a newline; the variable IS set,
#    but under `set -e` the script exits.
read -r NAME < /etc/podinfo/name || true
```

---

## The Complete Manifest

Every option in one Pod, suitable for copying into a cluster and inspecting.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: downward-everything
  namespace: default
  labels:
    app: demo
    tier: backend
    environment: lab
    app.kubernetes.io/version: "1.4.2"
  annotations:
    build.example.com/commit: "a3f9c21e77b0"
    build.example.com/pipeline: "4711"
spec:
  serviceAccountName: default
  containers:
  - name: app
    image: busybox:1.36
    command:
    - /bin/sh
    - -c
    - |
      echo "===== ENVIRONMENT ====="
      env | grep -E '^(POD|NODE|HOST|SA|CPU|MEM|EPH|APP|BUILD)' | sort
      echo
      echo "===== VOLUME TREE ====="
      find /etc/podinfo | sort
      echo
      echo "===== VOLUME CONTENTS ====="
      for f in $(find /etc/podinfo -type l -o -type f | grep -v '/\.\.' | sort); do
        printf '%-40s : ' "$f"
        cat "$f"
        echo
      done
      sleep 3600
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
        ephemeral-storage: 100Mi
      limits:
        cpu: 1500m
        memory: 1Gi
        ephemeral-storage: 2Gi
    env:
    - name: POD_NAME
      valueFrom: {fieldRef: {fieldPath: metadata.name}}
    - name: POD_NAMESPACE
      valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
    - name: POD_UID
      valueFrom: {fieldRef: {fieldPath: metadata.uid}}
    - name: NODE_NAME
      valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
    - name: SA_NAME
      valueFrom: {fieldRef: {fieldPath: spec.serviceAccountName}}
    - name: HOST_IP
      valueFrom: {fieldRef: {fieldPath: status.hostIP}}
    - name: POD_IP
      valueFrom: {fieldRef: {fieldPath: status.podIP}}
    - name: POD_IPS
      valueFrom: {fieldRef: {fieldPath: status.podIPs}}
    - name: APP_VERSION
      valueFrom:
        fieldRef:
          fieldPath: "metadata.labels['app.kubernetes.io/version']"
    - name: BUILD_COMMIT
      valueFrom:
        fieldRef:
          fieldPath: "metadata.annotations['build.example.com/commit']"
    - name: CPU_REQUEST_MILLICORES
      valueFrom:
        resourceFieldRef: {resource: requests.cpu, divisor: 1m}
    - name: CPU_LIMIT_MILLICORES
      valueFrom:
        resourceFieldRef: {resource: limits.cpu, divisor: 1m}
    - name: CPU_LIMIT_CORES
      valueFrom:
        resourceFieldRef: {resource: limits.cpu, divisor: "1"}
    - name: MEM_REQUEST_MIB
      valueFrom:
        resourceFieldRef: {resource: requests.memory, divisor: 1Mi}
    - name: MEM_LIMIT_MIB
      valueFrom:
        resourceFieldRef: {resource: limits.memory, divisor: 1Mi}
    - name: MEM_LIMIT_BYTES
      valueFrom:
        resourceFieldRef: {resource: limits.memory, divisor: "1"}
    - name: EPH_LIMIT_MIB
      valueFrom:
        resourceFieldRef: {resource: limits.ephemeral-storage, divisor: 1Mi}
    volumeMounts:
    - name: podinfo
      mountPath: /etc/podinfo
      readOnly: true
  volumes:
  - name: podinfo
    downwardAPI:
      defaultMode: 0444
      items:
      - path: "labels"
        fieldRef: {fieldPath: metadata.labels}
      - path: "annotations"
        fieldRef: {fieldPath: metadata.annotations}
      - path: "name"
        fieldRef: {fieldPath: metadata.name}
      - path: "namespace"
        fieldRef: {fieldPath: metadata.namespace}
      - path: "uid"
        fieldRef: {fieldPath: metadata.uid}
      - path: "meta/tier"
        mode: 0400
        fieldRef: {fieldPath: "metadata.labels['tier']"}
      - path: "meta/commit"
        fieldRef: {fieldPath: "metadata.annotations['build.example.com/commit']"}
      - path: "limits/cpu_millicores"
        resourceFieldRef:
          containerName: app
          resource: limits.cpu
          divisor: 1m
      - path: "limits/mem_mib"
        resourceFieldRef:
          containerName: app
          resource: limits.memory
          divisor: 1Mi
      - path: "requests/cpu_millicores"
        resourceFieldRef:
          containerName: app
          resource: requests.cpu
          divisor: 1m
      - path: "requests/mem_mib"
        resourceFieldRef:
          containerName: app
          resource: requests.memory
          divisor: 1Mi
```

---

## Exact Output From the Running Pod

```bash
kubectl apply -f downward-everything.yaml
kubectl wait --for=condition=Ready pod/downward-everything
kubectl logs downward-everything
```

### Environment

```
===== ENVIRONMENT =====
APP_VERSION=1.4.2
BUILD_COMMIT=a3f9c21e77b0
CPU_LIMIT_CORES=2
CPU_LIMIT_MILLICORES=1500
CPU_REQUEST_MILLICORES=250
EPH_LIMIT_MIB=2048
HOST_IP=192.168.10.42
MEM_LIMIT_BYTES=1073741824
MEM_LIMIT_MIB=1024
MEM_REQUEST_MIB=256
NODE_NAME=worker-2
POD_IP=10.244.2.17
POD_IPS=10.244.2.17
POD_NAME=downward-everything
POD_NAMESPACE=default
POD_UID=6f3c1a29-8b74-4c0d-9e21-7a5f0b3d8c14
SA_NAME=default
```

Read those two CPU lines carefully:

```
CPU_LIMIT_MILLICORES=1500       divisor 1m  → exact
CPU_LIMIT_CORES=2               divisor 1   → ceil(1.5) = 2, NOT 1.5
```

The default divisor rounds up. `CPU_LIMIT_CORES` says the container may use two cores when it may in fact use one and a half. Anything sizing a thread pool from that value over provisions.

### Volume Tree

```
===== VOLUME TREE =====
/etc/podinfo
/etc/podinfo/..2026_09_05_10_12_44.1874265301
/etc/podinfo/..2026_09_05_10_12_44.1874265301/annotations
/etc/podinfo/..2026_09_05_10_12_44.1874265301/labels
/etc/podinfo/..2026_09_05_10_12_44.1874265301/limits
/etc/podinfo/..2026_09_05_10_12_44.1874265301/limits/cpu_millicores
/etc/podinfo/..2026_09_05_10_12_44.1874265301/limits/mem_mib
/etc/podinfo/..2026_09_05_10_12_44.1874265301/meta
/etc/podinfo/..2026_09_05_10_12_44.1874265301/meta/commit
/etc/podinfo/..2026_09_05_10_12_44.1874265301/meta/tier
/etc/podinfo/..2026_09_05_10_12_44.1874265301/name
/etc/podinfo/..2026_09_05_10_12_44.1874265301/namespace
/etc/podinfo/..2026_09_05_10_12_44.1874265301/requests
/etc/podinfo/..2026_09_05_10_12_44.1874265301/requests/cpu_millicores
/etc/podinfo/..2026_09_05_10_12_44.1874265301/requests/mem_mib
/etc/podinfo/..2026_09_05_10_12_44.1874265301/uid
/etc/podinfo/..data
/etc/podinfo/annotations
/etc/podinfo/labels
/etc/podinfo/limits
/etc/podinfo/meta
/etc/podinfo/name
/etc/podinfo/namespace
/etc/podinfo/requests
/etc/podinfo/uid
```

### Volume Contents

```
===== VOLUME CONTENTS =====
/etc/podinfo/annotations                 : build.example.com/commit="a3f9c21e77b0"
build.example.com/pipeline="4711"
kubernetes.io/config.seen="2026-09-05T10:12:43.998112345Z"
kubernetes.io/config.source="api"

/etc/podinfo/labels                      : app="demo"
app.kubernetes.io/version="1.4.2"
environment="lab"
tier="backend"

/etc/podinfo/limits/cpu_millicores       : 1500
/etc/podinfo/limits/mem_mib              : 1024
/etc/podinfo/meta/commit                 : a3f9c21e77b0
/etc/podinfo/meta/tier                   : backend
/etc/podinfo/name                        : downward-everything
/etc/podinfo/namespace                   : default
/etc/podinfo/requests/cpu_millicores     : 250
/etc/podinfo/requests/mem_mib            : 256
/etc/podinfo/uid                         : 6f3c1a29-8b74-4c0d-9e21-7a5f0b3d8c14
```

### Interactive Verification

```bash
$ kubectl exec downward-everything -- ls -l /etc/podinfo
total 0
lrwxrwxrwx 1 root root 18 Sep  5 10:12 annotations -> ..data/annotations
lrwxrwxrwx 1 root root 13 Sep  5 10:12 labels -> ..data/labels
lrwxrwxrwx 1 root root 13 Sep  5 10:12 limits -> ..data/limits
lrwxrwxrwx 1 root root 11 Sep  5 10:12 meta -> ..data/meta
lrwxrwxrwx 1 root root 11 Sep  5 10:12 name -> ..data/name
lrwxrwxrwx 1 root root 16 Sep  5 10:12 namespace -> ..data/namespace
lrwxrwxrwx 1 root root 15 Sep  5 10:12 requests -> ..data/requests
lrwxrwxrwx 1 root root 10 Sep  5 10:12 uid -> ..data/uid

$ kubectl exec downward-everything -- readlink /etc/podinfo/..data
..2026_09_05_10_12_44.1874265301

$ kubectl exec downward-everything -- ls -l /etc/podinfo/..data/meta/
total 8
-r--r--r-- 1 root root 12 Sep  5 10:12 commit
-r-------- 1 root root  7 Sep  5 10:12 tier

$ kubectl exec downward-everything -- printenv POD_IP
10.244.2.17
```

Note `meta/tier` at `0400` from its per item `mode`, while everything else inherits `defaultMode: 0444`. Note also that the volume uses the exact same `..data` symlink and timestamped directory structure as a ConfigMap or Secret volume.

> 📖 **See Also**: [ConfigMaps](configmaps.md#inside-the-mounted-directory) for a full explanation of the `..data` symlink and the atomic swap.

---

## Live Updates: What Refreshes and What Does Not

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Downward API Update Behaviour                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  MECHANISM / FIELD                       │ REFRESHES?                │
│  ────────────────────────────────────────┼────────────────────────── │
│  env var, ANY field                      │ ❌ never                  │
│  volume: metadata.labels                 │ ✅ yes, eventually        │
│  volume: metadata.annotations            │ ✅ yes, eventually        │
│  volume: metadata.labels['key']          │ ✅ yes, eventually        │
│  volume: metadata.annotations['key']     │ ✅ yes, eventually        │
│  volume: metadata.name / namespace / uid │ n/a, immutable anyway     │
│  volume: resourceFieldRef                │ n/a in the general case;  │
│                                          │ resources are fixed for   │
│                                          │ the container's lifetime  │
│                                          │ under the classic model   │
│  volume mounted with subPath             │ ❌ never                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Why Labels and Annotations Are the Only Mutable Ones

Look at what can actually change on a running Pod:

```
metadata.name       immutable for the object's lifetime
metadata.namespace  immutable
metadata.uid        immutable
spec.nodeName       set once at binding; a Pod is never rescheduled,
                    it is replaced by a new Pod
status.podIP        assigned at sandbox creation; stable for the Pod
status.hostIP       follows nodeName
metadata.labels     ✅ MUTABLE: kubectl label, controllers, operators
metadata.annotations ✅ MUTABLE: kubectl annotate, controllers, operators
```

Labels and annotations are the only Pod metadata that routinely changes while the Pod runs, so they are the only fields where a refresh is meaningful. The Downward API volume refreshes exactly those.

### Demonstration

```bash
# 1. current state
$ kubectl exec downward-everything -- cat /etc/podinfo/labels
app="demo"
app.kubernetes.io/version="1.4.2"
environment="lab"
tier="backend"

# 2. change a label on the LIVE Pod
$ kubectl label pod downward-everything tier=frontend --overwrite
pod/downward-everything labeled

$ kubectl label pod downward-everything canary=true
pod/downward-everything labeled

# 3. wait for the kubelet sync period plus cache propagation delay,
#    then read again
$ kubectl exec downward-everything -- cat /etc/podinfo/labels
app="demo"
app.kubernetes.io/version="1.4.2"
canary="true"
environment="lab"
tier="frontend"

# 4. the single-label file updated too
$ kubectl exec downward-everything -- cat /etc/podinfo/meta/tier; echo
frontend

# 5. but an environment variable sourced from a label did NOT change
$ kubectl exec downward-everything -- printenv APP_VERSION
1.4.2
$ kubectl label pod downward-everything app.kubernetes.io/version=9.9.9 --overwrite
$ kubectl exec downward-everything -- printenv APP_VERSION
1.4.2                          # still the old value, and it always will be
```

The timing is the same as for ConfigMap and Secret volumes: the kubelet notices on its next periodic sync, then rewrites the whole volume with a new timestamped directory and an atomic `..data` symlink swap. The delay is the kubelet sync period plus its cache propagation delay, and it is not configurable per Pod.

### Watching for Changes

The same rules as any projected volume:

```
❌ inotify on /etc/podinfo/labels
   The path is a symlink into a directory that gets deleted. You get one
   IN_DELETE_SELF and then silence.

✅ inotify on the DIRECTORY /etc/podinfo, watching IN_CREATE and IN_MOVED_TO
   The rename of ..data fires IN_MOVED_TO. Re-read by path on that event.

✅ Or poll: readlink("/etc/podinfo/..data") and act when the target changes.
```

### The subPath Exception

```yaml
    volumeMounts:
    - name: podinfo
      mountPath: /etc/app/labels
      subPath: labels          # ⚠️ frozen at container start, forever
```

A `subPath` bind mount is pinned to a specific inode inside the timestamped directory the kubelet later deletes. It never sees the swap. If you use `subPath`, you have an environment variable with extra steps.

### A Useful Pattern: Annotation Driven Behaviour

Because annotations refresh live, you can toggle application behaviour without restarting a Pod:

```yaml
  volumes:
  - name: podinfo
    downwardAPI:
      items:
      - path: "log_level"
        fieldRef:
          fieldPath: "metadata.annotations['ops.example.com/log-level']"
```

```bash
kubectl annotate pod myapp-0 ops.example.com/log-level=debug --overwrite
# after the kubelet syncs, /etc/podinfo/log_level contains "debug"
```

The application polls or watches that file and adjusts. No restart, no ConfigMap, no API access, and the change is recorded on the Pod object itself where `kubectl describe` will show it. The trade off is the sync delay, so this is for operational toggles, not for anything latency sensitive.

Two caveats:

- If the annotation does not exist, the file **is not created**. The application must handle a missing file, not just an empty one.
- Annotating a Pod directly is not durable: the change is lost when the Pod is replaced. For a lasting change, annotate the Pod template and let the workload roll, which defeats the purpose. Use direct Pod annotation for temporary, per instance debugging.

---

## Practical Use Cases

### 1. Logging and Metrics Agents

Every log line and every metric needs to be attributed to a Pod. This is by far the most common use of the Downward API.

```yaml
      containers:
      - name: app
        image: myapp:1.4.2
      - name: fluent-bit
        image: fluent/fluent-bit:2.2
        env:
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        - name: POD_NAMESPACE
          valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
        - name: NODE_NAME
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        - name: POD_IP
          valueFrom: {fieldRef: {fieldPath: status.podIP}}
```

Without this, the agent would need `get pods` RBAC and would have to query the API server to answer "which Pod am I attached to", for every single Pod in the cluster. The Downward API removes an API call, a credential and a privilege in one step.

The same three variables feed OpenTelemetry resource attributes:

```yaml
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "k8s.pod.name=$(POD_NAME),k8s.namespace.name=$(POD_NAMESPACE),k8s.node.name=$(NODE_NAME)"
```

### 2. Node Local Endpoints

A Pod that must talk to an agent on its own node (a node local DNS cache, a metrics collector, a service mesh node agent) needs the node's IP, which it cannot know in advance:

```yaml
        - name: HOST_IP
          valueFrom: {fieldRef: {fieldPath: status.hostIP}}
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://$(HOST_IP):4317"
```

This keeps telemetry traffic on the node instead of crossing the cluster network to a central collector, which is a meaningful efficiency win at scale.

### 3. Sizing the JVM Heap

The JVM's container awareness handles the common case, but explicit sizing is still often required, especially when you want a specific ratio or when running an older runtime.

```yaml
    resources:
      requests: {memory: 1Gi, cpu: 500m}
      limits:   {memory: 2Gi, cpu: 2}       # explicit limit is MANDATORY here
    env:
    - name: MEM_LIMIT_MIB
      valueFrom:
        resourceFieldRef: {resource: limits.memory, divisor: 1Mi}
    command: ["/bin/sh", "-c"]
    args:
    - |
      set -eu
      : "${MEM_LIMIT_MIB:=1024}"
      # 70 percent to the heap; the rest for metaspace, code cache,
      # thread stacks, direct buffers and the GC's own overhead
      HEAP=$(( MEM_LIMIT_MIB * 70 / 100 ))
      exec java -Xms${HEAP}m -Xmx${HEAP}m \
                -XX:+ExitOnOutOfMemoryError \
                -jar /app/app.jar
```

```
╔══════════════════════════════════════════════════════════════════════╗
║  Without limits.memory set, MEM_LIMIT_MIB reports the NODE'S         ║
║  ALLOCATABLE memory. The JVM sizes a heap for the whole node,        ║
║  the kernel OOM killer terminates it, and the failure looks          ║
║  random because it depends on which node the Pod landed on.          ║
║                                                                       ║
║  ALWAYS set an explicit limit when sizing from limits.*.             ║
╚══════════════════════════════════════════════════════════════════════╝
```

### 4. Setting GOMAXPROCS

The Go runtime defaults `GOMAXPROCS` to the number of **host** CPUs, ignoring the cgroup CPU quota. On a 64 core node with a `500m` limit, Go spins up 64 OS threads to share half a core, producing heavy context switching, long GC pauses and severe throttling.

```yaml
    resources:
      limits: {cpu: 2}
    env:
    - name: CPU_LIMIT_MILLICORES
      valueFrom:
        resourceFieldRef: {resource: limits.cpu, divisor: 1m}   # NOT the default divisor
    command: ["/bin/sh", "-c"]
    args:
    - |
      set -eu
      CORES=$(( CPU_LIMIT_MILLICORES / 1000 ))
      [ "$CORES" -lt 1 ] && CORES=1
      export GOMAXPROCS="$CORES"
      exec /app/server
```

Use `divisor: 1m` and floor the result. With the default divisor, a `100m` limit reports `1` (fine by luck) but a `1200m` limit reports `2`, over provisioning by 66 percent.

> 📖 **See Also**: [Cgroups](cgroups.md) for how CPU quota and throttling actually work.

### 5. Node Aware Sharding

A DaemonSet where each Pod must claim a distinct slice of work:

```yaml
        env:
        - name: NODE_NAME
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        args:
        - "--shard-key=$(NODE_NAME)"
        - "--scrape-only-targets-on=$(NODE_NAME)"
```

Each replica filters its work by its own node name, so the set of Pods partitions the workload with no coordinator, no leader election and no shared state.

For a StatefulSet, the ordinal embedded in the Pod name serves the same purpose:

```yaml
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        command: ["/bin/sh", "-c"]
        args:
        - |
          ORDINAL="${POD_NAME##*-}"          # myapp-3 → 3
          exec /app/worker --shard-index="$ORDINAL" --shard-count=5
```

> 📖 **See Also**: [DaemonSets](daemonsets.md) and [StatefulSets](statefulsets.md).

### 6. Trace and Log Correlation

```yaml
        env:
        - name: SERVICE_INSTANCE_ID
          valueFrom: {fieldRef: {fieldPath: metadata.uid}}
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        - name: NODE_NAME
          valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
        - name: OTEL_SERVICE_NAME
          value: "checkout"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "service.instance.id=$(SERVICE_INSTANCE_ID),k8s.pod.name=$(POD_NAME),k8s.node.name=$(NODE_NAME)"
```

`metadata.uid` is genuinely unique across the cluster and across time, which makes it the right choice for `service.instance.id`. A Pod name can be reused after deletion; a UID cannot.

### 7. Cluster Peer Discovery

Clustered software (databases, caches, coordination services) needs each member to advertise a reachable address. With a StatefulSet and a headless Service, the Downward API supplies both halves:

```yaml
        env:
        - name: POD_NAME
          valueFrom: {fieldRef: {fieldPath: metadata.name}}
        - name: POD_NAMESPACE
          valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
        - name: POD_IP
          valueFrom: {fieldRef: {fieldPath: status.podIP}}
        - name: HEADLESS_SVC
          value: "myapp-headless"
        - name: ADVERTISE_ADDR
          value: "$(POD_NAME).$(HEADLESS_SVC).$(POD_NAMESPACE).svc.cluster.local"
        args:
        - "--node-id=$(POD_NAME)"
        - "--listen-addr=$(POD_IP):7000"
        - "--advertise-addr=$(ADVERTISE_ADDR):7000"
```

Bind to the Pod IP, advertise the stable DNS name. Binding to the DNS name would fail because it does not exist as a local interface address; advertising the Pod IP would break as soon as the Pod is rescheduled with a new address.

> 📖 **See Also**: [CoreDNS](coredns.md) for how that DNS name resolves.

### 8. Feature Flags From Labels

```yaml
    env:
    - name: FEATURE_TIER
      valueFrom:
        fieldRef:
          fieldPath: "metadata.labels['tier']"
    - name: CANARY
      valueFrom:
        fieldRef:
          fieldPath: "metadata.labels['canary']"
```

Reuse the labels you already need for Service selectors as behavioural inputs. A canary Pod knows it is a canary and can, for example, emit extra telemetry, without a separate ConfigMap or a separate image.

---

## Downward API vs ConfigMap vs Secret vs the API

| | **Downward API** | **ConfigMap** | **Secret** | **Kubernetes API** |
|---|---|---|---|---|
| **Source of data** | The Pod object itself | A separate object you author | A separate object you author | Anything in the cluster |
| **Scope** | This Pod only | Namespace | Namespace | Cluster wide, subject to RBAC |
| **Confidential data** | No | No | Yes (with encryption at rest) | Depends |
| **Needs RBAC** | ❌ none | ❌ none for the Pod | ❌ none for the Pod | ✅ yes |
| **Needs a token** | ❌ no | ❌ no | ❌ no | ✅ yes |
| **Needs a client library** | ❌ no | ❌ no | ❌ no | ✅ effectively yes |
| **Extra network call** | ❌ no | ❌ no | ❌ no | ✅ yes, per query |
| **Works if the API server is down** | ✅ yes, once the Pod is running | ✅ yes | ✅ yes | ❌ no |
| **Env var support** | ✅ yes | ✅ yes | ✅ yes | n/a |
| **Volume support** | ✅ yes | ✅ yes | ✅ yes | n/a |
| **Volume refresh** | Labels and annotations only | ✅ all keys | ✅ all keys | Continuous, by watch |
| **Env var refresh** | ❌ never | ❌ never | ❌ never | n/a |
| **tmpfs backed volume** | No | No | ✅ yes | n/a |
| **Size limit** | Small by nature | ~1 MiB | ~1 MiB | None practically |
| **Can read other objects** | ❌ no | ❌ no | ❌ no | ✅ yes |
| **Can WRITE to the cluster** | ❌ no | ❌ no | ❌ no | ✅ yes |
| **Typical use** | Self identity, own resources | App configuration | Credentials | Controllers, operators |

### Decision Tree

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Which One Do I Need?                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Is the data ABOUT THIS POD (its name, node, IP, labels,             │
│  annotations, or its own resource requests and limits)?              │
│      └─► YES ──► Downward API. Nothing else is cheaper or safer.     │
│                                                                      │
│  Is it configuration that varies per environment and is NOT          │
│  confidential?                                                       │
│      └─► YES ──► ConfigMap                                           │
│                                                                      │
│  Is it a credential, key or certificate?                             │
│      └─► YES ──► Secret, with encryption at rest, mounted as a       │
│                  volume rather than an environment variable          │
│                                                                      │
│  Does it require reading OTHER objects, watching for changes, or     │
│  writing back to the cluster?                                        │
│      └─► YES ──► the Kubernetes API, with a ServiceAccount and       │
│                  the narrowest possible RBAC                         │
│                                                                      │
│  ⚠️  Never call the API server just to learn something the Downward  │
│      API already provides. It costs a token, an RBAC grant, a        │
│      client library, a network round trip, and a startup dependency  │
│      on the control plane.                                           │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### What the Downward API Cannot Do

Be clear about the boundary:

```
❌ Read another Pod's fields
❌ Read Node object fields (labels, taints, capacity, annotations).
   You get spec.nodeName and status.hostIP, nothing more about the node.
❌ Read Service, Endpoint, ConfigMap or Secret objects
❌ Read most of status (phase, conditions, containerStatuses, startTime,
   qosClass). The status fields available are only the IP addresses.
❌ Write anything anywhere
❌ Read spec fields in general (only nodeName and serviceAccountName)
❌ Expose the full label set as an environment variable
❌ Expose spec.nodeName, status.podIP or status.hostIP in a volume
```

If you need node labels (a common request, for topology aware behaviour), you need the API with `get nodes` RBAC, or you need a controller to copy the relevant label onto the Pod, or you need `topology.kubernetes.io/zone` injected by whatever creates your Pods.

---

## Combining Sources in a Projected Volume

A `projected` volume merges `configMap`, `secret`, `downwardAPI` and `serviceAccountToken` into one directory with a single atomic update.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: projected-all
  labels:
    app: myapp
    tier: backend
spec:
  serviceAccountName: myapp
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "find /etc/appinfo -type l | sort; sleep 3600"]
    resources:
      limits: {cpu: 2, memory: 1Gi}
    volumeMounts:
    - name: appinfo
      mountPath: /etc/appinfo
      readOnly: true
  volumes:
  - name: appinfo
    projected:
      defaultMode: 0444
      sources:
      # ── application configuration ────────────────────────────────
      - configMap:
          name: app-config
          items:
          - key: application.properties
            path: config/application.properties

      # ── credentials ──────────────────────────────────────────────
      - secret:
          name: app-tls
          items:
          - key: tls.crt
            path: certs/tls.crt
          - key: tls.key
            path: certs/tls.key
            mode: 0400

      # ── pod self awareness ───────────────────────────────────────
      - downwardAPI:
          items:
          - path: podinfo/name
            fieldRef:
              fieldPath: metadata.name
          - path: podinfo/namespace
            fieldRef:
              fieldPath: metadata.namespace
          - path: podinfo/labels
            fieldRef:
              fieldPath: metadata.labels
          - path: podinfo/annotations
            fieldRef:
              fieldPath: metadata.annotations
          - path: podinfo/cpu_limit_millicores
            resourceFieldRef:
              containerName: app
              resource: limits.cpu
              divisor: 1m
          - path: podinfo/mem_limit_mib
            resourceFieldRef:
              containerName: app
              resource: limits.memory
              divisor: 1Mi

      # ── bound, expiring API token ────────────────────────────────
      - serviceAccountToken:
          path: token/api-token
          audience: vault.example.com
          expirationSeconds: 3600
```

Resulting layout:

```
/etc/appinfo/
├── certs/
│   ├── tls.crt
│   └── tls.key                    (mode 0400)
├── config/
│   └── application.properties
├── podinfo/
│   ├── annotations                (refreshes live)
│   ├── cpu_limit_millicores
│   ├── labels                     (refreshes live)
│   ├── mem_limit_mib
│   ├── name
│   └── namespace
└── token/
    └── api-token                  (rotated by the kubelet before expiry)
```

Rules that apply to the combination:

```
┌────────────────────────────────────────────────────────────────────┐
│              Projected Volume with a downwardAPI Source             │
├────────────────────────────────────────────────────────────────────┤
│  • Inside a projected volume, the downwardAPI source uses the       │
│    SAME items[] structure as a standalone downwardAPI volume.       │
│                                                                     │
│  • defaultMode is set ONCE, on the projected volume, not per        │
│    source. Individual items may still override it with mode.        │
│                                                                     │
│  • Two sources must not produce the same path. A collision is a     │
│    validation error at Pod creation time.                           │
│                                                                     │
│  • The whole directory shares ONE ..data symlink and ONE atomic     │
│    swap, so ConfigMap keys, Secret keys and label files all         │
│    update together and consistently.                                │
│                                                                     │
│  • The field restrictions still apply: no spec.nodeName, no         │
│    status.podIP, no status.hostIP in a downwardAPI source.          │
│    Those remain environment variables only.                         │
│                                                                     │
│  • A projected volume is NOT tmpfs backed just because it contains  │
│    a secret source. If tmpfs backing matters to you, use a plain    │
│    secret volume.                                                   │
└────────────────────────────────────────────────────────────────────┘
```

The last point is worth emphasising in a security review: mixing a Secret into a projected volume for convenience changes the storage characteristics compared with a dedicated `secret` volume.

> 📖 **See Also**: [ConfigMaps](configmaps.md#projected-volumes) and [Secrets](secrets.md#service-account-tokens).

---

## Command Reference

```bash
# ── APPLY AND INSPECT ─────────────────────────────────────────────────
kubectl apply -f downward-everything.yaml
kubectl wait --for=condition=Ready pod/downward-everything --timeout=60s
kubectl logs downward-everything

# ── ENVIRONMENT ───────────────────────────────────────────────────────
kubectl exec POD -- env | sort
kubectl exec POD -- printenv POD_NAME
kubectl exec POD -c CONTAINER -- env | grep -E '^(POD|NODE|CPU|MEM)'

# ── VOLUME ────────────────────────────────────────────────────────────
kubectl exec POD -- ls -l /etc/podinfo
kubectl exec POD -- find /etc/podinfo -type l | sort
kubectl exec POD -- cat /etc/podinfo/labels
kubectl exec POD -- cat /etc/podinfo/annotations
kubectl exec POD -- readlink /etc/podinfo/..data
kubectl exec POD -- stat -c '%n %U:%G %a' /etc/podinfo/..data/name

# ── WHAT DOES THE POD OBJECT ACTUALLY SAY? ────────────────────────────
kubectl get pod POD -o jsonpath='{.spec.nodeName}'; echo
kubectl get pod POD -o jsonpath='{.status.podIP}'; echo
kubectl get pod POD -o jsonpath='{.status.podIPs}'; echo
kubectl get pod POD -o jsonpath='{.status.hostIP}'; echo
kubectl get pod POD -o jsonpath='{.metadata.uid}'; echo
kubectl get pod POD --show-labels
kubectl get pod POD -o jsonpath='{.metadata.labels}' | jq
kubectl get pod POD -o jsonpath='{.metadata.annotations}' | jq

# resolved resources for a container
kubectl get pod POD -o jsonpath='{.spec.containers[0].resources}' | jq

# ── TEST LIVE REFRESH ─────────────────────────────────────────────────
kubectl label pod POD tier=frontend --overwrite
kubectl annotate pod POD ops.example.com/log-level=debug --overwrite
kubectl exec POD -- cat /etc/podinfo/labels

# watch the symlink flip
kubectl exec POD -- sh -c 'while :; do date +%T; readlink /etc/podinfo/..data; sleep 5; done'

# ── VALIDATE A MANIFEST WITHOUT CREATING ANYTHING ─────────────────────
kubectl apply -f pod.yaml --dry-run=server

# ── EXPLAIN THE SCHEMA ────────────────────────────────────────────────
kubectl explain pod.spec.containers.env.valueFrom.fieldRef
kubectl explain pod.spec.containers.env.valueFrom.resourceFieldRef
kubectl explain pod.spec.volumes.downwardAPI
kubectl explain pod.spec.volumes.downwardAPI.items
kubectl explain pod.spec.volumes.projected.sources.downwardAPI

# ── NODE ALLOCATABLE, TO UNDERSTAND THE NO-LIMIT CASE ─────────────────
kubectl get node NODE -o jsonpath='{.status.allocatable}' | jq
```

---

## Troubleshooting

### Pod Rejected: field label not supported

```
The Pod "demo" is invalid: spec.volumes[0].downwardAPI.items[0].fieldRef.fieldPath:
Invalid value: "spec.nodeName": error converting fieldPath: field label not
supported: spec.nodeName
```

You used an environment only field in a volume. `spec.nodeName`, `spec.serviceAccountName`, `status.hostIP`, `status.podIP` and `status.podIPs` are available **only** as environment variables. Move that item into `env`.

The same error with a different value usually means a typo. Check against [the field lists](#fields-available-via-fieldref).

### Pod Rejected: containerName Required

```
The Pod "demo" is invalid: spec.volumes[0].downwardAPI.items[0].resourceFieldRef.containerName:
Required value
```

`containerName` is mandatory in a volume, because a Pod level volume has no implicit container. It is optional in `env`, where it defaults to the current container.

### Environment Variable Is Empty or Missing

```bash
kubectl exec POD -- printenv MY_VAR || echo "NOT SET"
kubectl get pod POD -o jsonpath='{.spec.containers[0].env}' | jq
```

| Cause | Check |
|-------|-------|
| The named label or annotation does not exist | `kubectl get pod POD --show-labels`. A missing named key means the variable is simply not set; this is **not** an error |
| Wrong container | `kubectl exec POD -c CONTAINER -- env` |
| Init container | Init containers need their own `env` block |
| Requests not set, so `requests.*` reports `0` | `kubectl get pod POD -o jsonpath='{.spec.containers[0].resources}'` |
| Quoting mistake in the `fieldPath` | It must be `"metadata.labels['key']"`, quoted on the outside, single quoted inside |

### The Value Is a Literal $(SOMETHING)

```bash
$ kubectl exec POD -- printenv POD_FQDN
$(POD_NAME).svc.cluster.local
```

You referenced a variable that is not defined **earlier in the same `env` list**. Expansion only looks backwards. Reorder so every referenced variable appears first. Note that variables coming from `envFrom` are never available for `$(VAR)` expansion.

### CPU Value Is Wrong

```bash
$ kubectl exec POD -- printenv CPU_LIMIT
2
$ kubectl get pod POD -o jsonpath='{.spec.containers[0].resources.limits.cpu}'
1500m
```

Not a bug. The default divisor is `1` (whole cores) and the result is rounded **up**: `ceil(1.5) = 2`. Use `divisor: 1m` for exact millicores and do your own arithmetic.

### Memory Limit Reports an Enormous Number

```bash
$ kubectl exec POD -- printenv MEM_LIMIT_MIB
64253
$ kubectl get pod POD -o jsonpath='{.spec.containers[0].resources}' | jq
{ "requests": { "memory": "256Mi" } }        # no limits at all
```

With no `limits.memory`, the Downward API reports the **node's allocatable memory**. Set an explicit limit. Confirm the node's allocatable value to be sure that is what you are seeing:

```bash
NODE=$(kubectl get pod POD -o jsonpath='{.spec.nodeName}')
kubectl get node "$NODE" -o jsonpath='{.status.allocatable.memory}'; echo
```

### Volume Files Do Not Update

```bash
kubectl get pod POD --show-labels
kubectl exec POD -- cat /etc/podinfo/labels
kubectl exec POD -- readlink /etc/podinfo/..data
```

Work through:

1. **Are you reading an environment variable rather than a file?** Environment variables never update.
2. **Is `subPath` in use?** It never updates. Check `kubectl get pod POD -o jsonpath='{.spec.containers[0].volumeMounts}'`.
3. **Has enough time passed?** Allow for the kubelet sync period plus cache propagation delay.
4. **Did you change the label on the Pod or on the Deployment's template?** Changing the template creates **new Pods**; it does not modify the existing ones' labels. Use `kubectl label pod` for a live change.
5. **Is the `..data` timestamp advancing?** If it is stale, the kubelet has not rewritten the volume at all.

### The Named Annotation File Does Not Exist

```bash
$ kubectl exec POD -- cat /etc/podinfo/log_level
cat: can't open '/etc/podinfo/log_level': No such file or directory
```

Selecting a single annotation or label that does not exist produces **no file**, rather than an empty file. Your application must tolerate a missing path. Add the annotation and wait for the sync:

```bash
kubectl annotate pod POD ops.example.com/log-level=debug --overwrite
```

### Permission Denied Reading a File

```bash
kubectl exec POD -- id
kubectl exec POD -- ls -l /etc/podinfo/..data/
```

A `mode` or `defaultMode` of `0400` grants read access only to the file's owner, and the kubelet decides the owner. Use `0444` where the content is not sensitive, or set `spec.securityContext.fsGroup` and use `0440`. Remember to write the mode in octal with a leading zero: `defaultMode: 400` is decimal and means octal `0620`.

### labels File Contains Unexpected Entries

The kubelet adds its own annotations (`kubernetes.io/config.seen`, `kubernetes.io/config.source`), and controllers add labels such as `pod-template-hash`. Project the specific keys you care about instead of the whole set:

```yaml
      - path: "meta/app"
        fieldRef:
          fieldPath: "metadata.labels['app']"
```

### The annotations File Is Huge

`kubectl.kubernetes.io/last-applied-configuration` embeds the entire applied manifest. Projecting all annotations therefore projects that manifest. Select individual annotations by name instead.

### Values Differ Between Replicas

Entirely expected, and the point of the mechanism. `metadata.name`, `metadata.uid`, `status.podIP` and `spec.nodeName` are different for every replica. If you needed a value that is the same everywhere, you wanted a [ConfigMap](configmaps.md).

---

## Exam and Interview Traps

1. **The env field set and the volume field set are different, and neither is a superset of the other.** This is the single most examined fact about the Downward API.
2. **`spec.nodeName`, `spec.serviceAccountName`, `status.hostIP`, `status.podIP` and `status.podIPs` are environment variables only.** Using them in a volume is a validation error and the Pod is never created.
3. **The complete `metadata.labels` and `metadata.annotations` sets are volume only.** As an environment variable you can only select one key at a time, by name.
4. **A single label or annotation by name works in both**, with the syntax `"metadata.labels['key']"`, quoted on the outside and single quoted inside.
5. **Environment variables never refresh.** Not for any field, ever.
6. **Labels and annotations in a volume DO refresh**, because they are the only Pod metadata that meaningfully changes while the Pod runs.
7. **`subPath` breaks the refresh**, exactly as it does for ConfigMaps and Secrets.
8. **`containerName` is required in a volume `resourceFieldRef` and optional in an env one**, where it defaults to the current container.
9. **The default `divisor` is `1`: whole cores for CPU, bytes for memory.** Results are rounded **up**, so a `500m` limit reports `1` and a `1500m` limit reports `2`.
10. **Use `divisor: 1m` for CPU and `1Mi` for memory** whenever you intend to compute with the value.
11. **If `limits.cpu` or `limits.memory` is not set, the Downward API reports the node's allocatable amount**, which is how a JVM ends up trying to allocate the whole node. Always set explicit limits when sizing from limits.
12. **If a request is not set, `requests.*` reports `0`.** Guard against dividing by it.
13. **A missing named label or annotation is not an error.** The environment variable is simply unset, and the volume file is simply not created.
14. **An invalid `fieldPath` is a validation error at creation time,** not a runtime failure. That is a feature.
15. **The Downward API needs no ServiceAccount token and no RBAC.** Calling the API server to learn your own Pod name is the anti pattern it exists to eliminate.
16. **It is read only and Pod scoped.** No writes, no other Pods, no Node object fields beyond `spec.nodeName` and `status.hostIP`, no Services, no ConfigMaps.
17. **You cannot get node labels.** `spec.nodeName` and `status.hostIP` are all the node information available.
18. **Only IP addresses are available from `status`.** Not `phase`, not `conditions`, not `containerStatuses`, not `qosClass`.
19. **The `labels` and `annotations` files use `key="value"` lines, one per entry, sorted, with the value quoted.**
20. **Scalar files have no trailing newline;** the `labels` and `annotations` files do, because each entry is a line.
21. **The volume uses the same `..data` symlink and atomic swap** as ConfigMap and Secret volumes, so naive `inotify` watches on individual file paths stop firing after the first update.
22. **`defaultMode` defaults to `0644` and must be written in octal with a leading zero.**
23. **The kubelet injects its own annotations** (`kubernetes.io/config.seen`, `kubernetes.io/config.source`), and `last-applied-configuration` can make the annotations file very large.
24. **`$(VAR)` expansion in `command` and `args` only sees variables defined earlier in the same `env` list**, and is performed by the kubelet, not a shell.
25. **`metadata.uid` is the right unique instance identifier**, because Pod names can be reused after deletion.
26. **Inside a projected volume, the `downwardAPI` source keeps the same field restrictions**, and `defaultMode` is set once at the projected volume level.
27. **A projected volume containing a secret source is not tmpfs backed** the way a dedicated `secret` volume is.
28. **Changing a label on a Deployment's Pod template creates new Pods; it does not relabel existing ones.** To test live refresh, use `kubectl label pod`.

---

## Related Topics

- [ConfigMaps](configmaps.md)
- [Secrets](secrets.md)
- [Pods](pods.md)
- [Cgroups](cgroups.md)
- [Deployments](deployments.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [Controllers](controllers.md)
- [kubelet](kubelet.md)
- [kube-scheduler](kube-scheduler.md)
- [kube-apiserver](kube-apiserver.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [CoreDNS](coredns.md)
- [Worker Node](worker-node.md)
- [etcd](etcd.md)

---

## Key Takeaways

1. The Downward API projects **the Pod's own metadata and resource allocation** into its containers, with no ServiceAccount token, no RBAC grant, no client library and no network call. Querying the API server to learn your own name is the anti pattern it replaces.
2. There are two mechanisms (**environment variables** and **downwardAPI volumes**) and two selectors (**`fieldRef`** for Pod fields, **`resourceFieldRef`** for a container's requests and limits).
3. **The two field sets are different and neither contains the other.** `spec.nodeName`, `spec.serviceAccountName`, `status.hostIP`, `status.podIP` and `status.podIPs` are environment variables only. The complete `metadata.labels` and `metadata.annotations` sets are volume only. `metadata.name`, `metadata.namespace`, `metadata.uid` and single named labels or annotations work in both.
4. Selecting one label or annotation uses `"metadata.labels['key']"`, quoted on the outside and single quoted inside. A missing key is **not an error**: the variable is unset, or the file is not created.
5. `resourceFieldRef` supports `requests` and `limits` for `cpu`, `memory`, `ephemeral-storage` and `hugepages-*`. **`containerName` is mandatory in a volume and optional in an environment variable.**
6. **The default `divisor` of `1` means whole cores and raw bytes, and the result is rounded up**, so a `1500m` limit reports `2`. Use `divisor: 1m` and `divisor: 1Mi` whenever you intend to compute with the value.
7. **With no limit set, `limits.*` reports the node's allocatable amount.** A JVM or thread pool sized from that value will try to consume the whole node. Always set explicit limits when sizing from them, and guard against a `0` from an unset request.
8. **Environment variables are frozen at container start and never refresh.** Labels and annotations projected into a **volume** are refreshed by the kubelet, because they are the only Pod metadata that changes while the Pod runs. `subPath` mounts never refresh.
9. The volume uses the same **`..data` symlink and atomic `rename(2)` swap** as ConfigMap and Secret volumes, so watch the directory rather than individual file paths.
10. The `labels` and `annotations` files contain sorted `key="value"` lines; scalar files carry **no trailing newline**; the kubelet adds its own annotations, and `last-applied-configuration` can make the annotations file surprisingly large.
11. An invalid `fieldPath` or a missing `containerName` is a **validation error at Pod creation**, so mistakes surface immediately rather than at runtime.
12. Canonical use cases: **Pod identity for logging and metrics agents**, **node local endpoints from `status.hostIP`**, **JVM heap and `GOMAXPROCS` sizing from limits**, **node aware and ordinal based sharding**, **trace correlation using `metadata.uid`**, and **peer advertisement in clustered software** by combining Pod name, namespace and Pod IP.
13. Use the Downward API for facts **about this Pod**, a ConfigMap for **environment specific configuration**, a Secret for **credentials**, and the Kubernetes API only when you must read other objects, watch for changes, or write.
14. It is strictly **read only and Pod scoped**. No node labels, no other Pods, no Services, and only IP addresses out of `status`.
15. Inside a **projected volume** the `downwardAPI` source keeps every one of these restrictions, shares a single `defaultMode` and a single atomic update with the `configMap`, `secret` and `serviceAccountToken` sources, and is not tmpfs backed merely because a secret is present.

---

## References

- [Downward API](https://kubernetes.io/docs/concepts/workloads/pods/downward-api/)
- [Expose Pod Information to Containers Through Environment Variables](https://kubernetes.io/docs/tasks/inject-data-application/environment-variable-expose-pod-information/)
- [Expose Pod Information to Containers Through Files](https://kubernetes.io/docs/tasks/inject-data-application/downward-api-volume-expose-pod-information/)
- [Projected Volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
- [Volumes: downwardAPI](https://kubernetes.io/docs/concepts/storage/volumes/#downwardapi)
- [Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Resource Quantities in the API](https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/quantity/)
- [Define Environment Variables for a Container](https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/)
- [Define Dependent Environment Variables](https://kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables/)
- [Define a Command and Arguments for a Container](https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/)
- [Labels and Selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/)
- [Annotations](https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/)
- [Reserve Compute Resources for System Daemons](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
- [Pod API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
