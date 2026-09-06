# 🗂️ Volumes: The Pod Level Storage Abstraction

Everything about `spec.volumes` and `spec.containers[].volumeMounts`: the full volume type catalogue, mount semantics, sharing between containers, ownership and SELinux, and the failure modes that produce a Pod stuck in `ContainerCreating`.

## 📋 Table of Contents
- [What a Volume Actually Is](#what-a-volume-actually-is)
- [The Lifecycle Rule](#the-lifecycle-rule)
- [Anatomy of a Volume Declaration](#anatomy-of-a-volume-declaration)
- [The Volume Type Catalogue](#the-volume-type-catalogue)
- [emptyDir](#emptydir)
- [hostPath](#hostpath)
- [configMap](#configmap)
- [secret](#secret)
- [downwardAPI](#downwardapi)
- [projected](#projected)
- [persistentVolumeClaim](#persistentvolumeclaim)
- [nfs](#nfs)
- [iscsi](#iscsi)
- [local](#local)
- [CSI Inline Volumes](#csi-inline-volumes)
- [Generic Ephemeral Volumes](#generic-ephemeral-volumes)
- [volumeMounts in Detail](#volumemounts-in-detail)
- [subPath and subPathExpr](#subpath-and-subpathexpr)
- [Mount Propagation](#mount-propagation)
- [Sharing a Volume Between Containers](#sharing-a-volume-between-containers)
- [Init Containers and Volumes](#init-containers-and-volumes)
- [Mount Ordering and Shadowing](#mount-ordering-and-shadowing)
- [Ownership, fsGroup and SELinux](#ownership-fsgroup-and-selinux)
- [Read Only Root Filesystem Pattern](#read-only-root-filesystem-pattern)
- [Node Volume Limits](#node-volume-limits)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What a Volume Actually Is

A Kubernetes **volume** is a directory (or, for raw block, a device node) that the kubelet prepares on the node and makes available inside one or more containers of a Pod.

There is nothing magical about it. The mechanism is:

```
 1. Pod is assigned to a node
 2. kubelet's VolumeManager reads spec.volumes
 3. For each volume it creates or attaches something under
        /var/lib/kubelet/pods/<pod-uid>/volumes/<plugin>~<type>/<volume-name>
 4. The container runtime bind mounts that path to the container's mountPath
    inside the container's MOUNT NAMESPACE
 5. Container starts, sees files at mountPath
```

The whole abstraction rests on Linux mount namespaces: the container has its own view of the filesystem tree, and a volume is simply an extra mount grafted into that view.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                      A VOLUME IS A BIND MOUNT                            │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   NODE (host mount namespace)                                            │
│   /var/lib/kubelet/pods/9f3c.../volumes/kubernetes.io~empty-dir/cache    │
│                       │                                                  │
│                       │  bind mount into the container's mount namespace │
│                       ▼                                                  │
│   CONTAINER (own mount namespace)                                        │
│   /                        ← from the image (overlayfs, read only + rw)  │
│   ├── usr/                 ← image                                       │
│   ├── etc/                 ← image                                       │
│   └── cache/               ← THE VOLUME, not part of the image at all    │
│                                                                          │
│   Writes to /cache never touch the writable container layer.             │
│   Writes to /tmp (no volume) do, and are lost on restart.                │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

> 📖 **Background**: [linux-namespaces.md](linux-namespaces.md) for mount namespaces, [containers.md](containers.md) for the image layer stack, [storage.md](storage.md) for where volumes sit in the overall storage model.

### Volumes Are Pod Scoped, Mounts Are Container Scoped

This is the single structural fact to internalise:

```
   Pod
   ├── spec.volumes[]                    ← DECLARED ONCE, per pod
   │     - name: shared
   │       emptyDir: {}
   │
   ├── spec.initContainers[]
   │     - name: setup
   │       volumeMounts:                 ← MOUNTED PER CONTAINER
   │         - name: shared
   │           mountPath: /work
   │
   └── spec.containers[]
         - name: producer
           volumeMounts:
             - name: shared
               mountPath: /out           ← same volume, different path
         - name: consumer
           volumeMounts:
             - name: shared
               mountPath: /in            ← same volume, third path
               readOnly: true            ← different access, same data
```

One declaration, many mounts. The `name` field is the join key, and it must match exactly. A `volumeMount` naming a volume that does not exist is a validation error at admission time, which is one of the few storage problems Kubernetes catches early.

---

## The Lifecycle Rule

> **A volume outlives a container restart. It does not outlive the Pod, unless the volume is backed by something outside the node.**

```
┌───────────────────────────────────────────────────────────────────────────┐
│                        VOLUME LIFETIME TIMELINE                           │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  t0  Pod scheduled to node-b                                              │
│      └─► kubelet creates emptyDir directory on node-b       [VOLUME BORN] │
│                                                                           │
│  t1  container starts, writes /cache/state.db                             │
│                                                                           │
│  t2  container CRASHES (exit 1)                                           │
│      └─► writable layer discarded                                         │
│      └─► volume UNTOUCHED                                   [SURVIVES]    │
│                                                                           │
│  t3  container restarted by kubelet (RestartPolicy)                       │
│      └─► same volume remounted, /cache/state.db still there [SURVIVES]    │
│                                                                           │
│  t4  container OOM killed, restarted again                  [SURVIVES]    │
│                                                                           │
│  t5  liveness probe fails, container killed and restarted   [SURVIVES]    │
│                                                                           │
│  t6  POD DELETED (or evicted, or the node dies)                           │
│      └─► kubelet removes /var/lib/kubelet/pods/<uid>/       [VOLUME DIES] │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘

  The exception: if the volume source is a PVC, an nfs share, an iscsi LUN
  or a local PV, the DATA lives outside the pod directory. Deleting the pod
  removes the mount, not the data.
```

### Lifetime by Volume Type

| Volume type | Survives container restart | Survives Pod deletion | Survives node loss |
|-------------|---------------------------|-----------------------|--------------------|
| `emptyDir` | ✅ | ❌ | ❌ |
| `emptyDir` with `medium: Memory` | ✅ | ❌ | ❌ |
| `configMap`, `secret`, `downwardAPI`, `projected` | ✅ (and re-rendered from the API) | ❌ (source object survives) | ✅ (source object survives) |
| `hostPath` | ✅ | ✅ data stays on that node | ❌ |
| `local` PV | ✅ | ✅ data stays on that node | ❌ |
| `persistentVolumeClaim` on network storage | ✅ | ✅ | ✅ |
| `nfs`, `iscsi` inline | ✅ | ✅ | ✅ |
| CSI inline (ephemeral mode) | ✅ | ❌ by definition | ❌ |
| Generic ephemeral (`ephemeral.volumeClaimTemplate`) | ✅ | ❌ the PVC is garbage collected with the Pod | ❌ |

The row people misread is the first one. `emptyDir` is *not* wiped when a container crashes. That property is exactly what makes it usable as a handoff buffer between containers, and as a crash resilient scratch area.

---

## Anatomy of a Volume Declaration

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: anatomy
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      volumeMounts:
        # ── required ────────────────────────────────────────────────
        - name: html                 # must match a spec.volumes[].name
          mountPath: /usr/share/nginx/html
        # ── optional refinements ────────────────────────────────────
        - name: config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf        # mount ONE key as a file, not a dir
          readOnly: true
        - name: cache
          mountPath: /var/cache/nginx
        - name: hostlogs
          mountPath: /hostlogs
          readOnly: true
          mountPropagation: HostToContainer

  volumes:
    - name: html                     # the join key
      persistentVolumeClaim:
        claimName: nfs-pvc-web-share
        readOnly: true
    - name: config
      configMap:
        name: nginx-config
        defaultMode: 0444
    - name: cache
      emptyDir:
        sizeLimit: 256Mi
    - name: hostlogs
      hostPath:
        path: /var/log
        type: Directory
```

### The Two Field Sets

| `spec.volumes[]` | `spec.containers[].volumeMounts[]` |
|------------------|------------------------------------|
| `name` | `name` |
| exactly one **volume source** (`emptyDir`, `configMap`, ...) | `mountPath` |
| source specific options (`sizeLimit`, `defaultMode`, `claimName`, ...) | `subPath` or `subPathExpr` |
| | `readOnly` |
| | `mountPropagation` |
| | `recursiveReadOnly` (where supported by the cluster) |

A container using raw block storage replaces `volumeMounts` with `volumeDevices`, covered in [persistent-volumes.md](persistent-volumes.md).

---

## The Volume Type Catalogue

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      VOLUME SOURCES BY CATEGORY                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  SCRATCH                    CONFIG / IDENTITY                           │
│    emptyDir                   configMap                                 │
│                               secret                                    │
│  NODE LOCAL                   downwardAPI                               │
│    hostPath                   projected  (combines the three + SA token)│
│    local (via PV)                                                       │
│                                                                         │
│  PERSISTENT (indirect)      PERSISTENT (inline, no PVC)                 │
│    persistentVolumeClaim      nfs                                       │
│    ephemeral (auto PVC)       iscsi                                     │
│                               csi (ephemeral mode)                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

| Type | Backed by | PV/PVC needed | Typical use |
|------|-----------|---------------|-------------|
| `emptyDir` | Node disk or tmpfs | No | Scratch, cache, container to container handoff |
| `hostPath` | A path on the node | No | Node agents, log collectors, runtime socket access |
| `configMap` | API object, tmpfs | No | Config files |
| `secret` | API object, tmpfs | No | Credentials, TLS material |
| `downwardAPI` | Pod metadata, tmpfs | No | Pod name, labels, resource limits as files |
| `projected` | Several of the above, plus SA tokens | No | One directory assembled from many sources |
| `persistentVolumeClaim` | Whatever the PV points at | Yes | The standard persistent path |
| `ephemeral` | Auto created PVC | Auto | Per Pod scratch on real storage |
| `nfs` | An NFS export | No | Direct share mount, bypassing PV/PVC |
| `iscsi` | An iSCSI LUN | No | Direct block mount, bypassing PV/PVC |
| `csi` | A CSI driver | No (ephemeral mode) | Secrets managers, per Pod driver volumes |
| `local` | A node local disk or partition | Yes, PV only | Low latency, node pinned storage |

---

## emptyDir

The simplest volume. An empty directory created when the Pod is assigned to a node, deleted when the Pod leaves it.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: scratch-demo
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "dd if=/dev/zero of=/scratch/blob bs=1M count=100; sleep 3600"]
      volumeMounts:
        - name: scratch
          mountPath: /scratch
      resources:
        requests:
          ephemeral-storage: "256Mi"
        limits:
          ephemeral-storage: "1Gi"
  volumes:
    - name: scratch
      emptyDir:
        sizeLimit: 512Mi         # exceeding this evicts the pod
```

### Disk Backed vs Memory Backed

```yaml
  volumes:
    # Default: on the node's disk, under /var/lib/kubelet/pods/<uid>/volumes/
    - name: disk-scratch
      emptyDir: {}

    # tmpfs: never touches disk, contents live in RAM
    - name: ram-scratch
      emptyDir:
        medium: Memory
        sizeLimit: 128Mi
```

| Property | `medium: ""` (default) | `medium: Memory` |
|----------|------------------------|------------------|
| Storage | Node filesystem | tmpfs (RAM) |
| Speed | Disk speed | RAM speed |
| Accounted against | `ephemeral-storage` | **The Pod's memory limit** |
| Survives node reboot | The Pod does not, so irrelevant | No |
| Written to disk ever | Yes | Only if the node swaps |
| Default size cap | Node disk, or `sizeLimit` | Half the node's RAM, or `sizeLimit` |

> ⚠️ **The memory trap.** A tmpfs `emptyDir` consumes memory from the Pod's cgroup. Fill a 2Gi tmpfs in a container with a 1Gi memory limit and the container is **OOM killed**, with no obvious connection to the volume in the logs. Always set `sizeLimit` on a memory backed `emptyDir`, and size the memory limit to cover it.

Without `sizeLimit`, a memory backed `emptyDir` is sized at roughly half the node's memory, which is far more than most Pods should be able to consume.

### Verifying the Medium

```bash
kubectl exec scratch-demo -- df -h /scratch
# disk backed shows the node filesystem
# Filesystem   Size  Used Avail Use% Mounted on
# /dev/sda1    100G  ...  ...   ..%  /scratch

kubectl exec ram-demo -- df -h /ram
# tmpfs backed shows tmpfs and the sizeLimit
# Filesystem   Size  Used Avail Use% Mounted on
# tmpfs        128M  0     128M   0%  /ram

kubectl exec ram-demo -- mount | grep /ram
# tmpfs on /ram type tmpfs (rw,relatime,size=131072k)
```

### Canonical Use Cases

1. **Sidecar handoff**: one container writes, another reads. See [Sharing a Volume Between Containers](#sharing-a-volume-between-containers).
2. **Writable paths on a read only root filesystem**: mount `emptyDir` at `/tmp`, `/run` and `/var/cache` so the container can still function with `readOnlyRootFilesystem: true`.
3. **Checkpoint across crash loops**: a process that crashes and restarts keeps its scratch state.
4. **Secret staging**: an init container decrypts material into a memory backed `emptyDir` that the app then reads.

> 📖 **Related**: [cgroups.md](cgroups.md) explains the memory cgroup that a tmpfs `emptyDir` charges against.

---

## hostPath

Mounts a file or directory **from the node's own filesystem** into the Pod.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-log-reader
spec:
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "tail -F /hostlogs/messages"]
      volumeMounts:
        - name: varlog
          mountPath: /hostlogs
          readOnly: true
  volumes:
    - name: varlog
      hostPath:
        path: /var/log
        type: Directory        # fail fast if it is not an existing directory
```

### Every `type` Value

| `type` | Behaviour if the path is missing or wrong | Use for |
|--------|-------------------------------------------|---------|
| `""` (empty, the default) | **No checks at all.** Backward compatible, unsafe. | Nothing new. Always set a type. |
| `DirectoryOrCreate` | Creates an empty directory, mode 0755, owned by kubelet | Node agents that need a state directory |
| `Directory` | Pod fails to start if the directory does not exist | Reading a directory that must already be there |
| `FileOrCreate` | Creates an empty file, mode 0644, owned by kubelet. **Parent directory must already exist.** | Log files an agent appends to |
| `File` | Pod fails to start if the file does not exist | Reading a specific config file such as a kubeconfig |
| `Socket` | Path must be an existing UNIX socket | Container runtime socket, device plugin sockets |
| `CharDevice` | Path must be an existing character device | `/dev/net/tun`, `/dev/fuse`, `/dev/kmsg` |
| `BlockDevice` | Path must be an existing block device | Direct disk access for storage software |

```yaml
  volumes:
    - name: state
      hostPath: { path: /var/lib/my-agent, type: DirectoryOrCreate }
    - name: kubeconfig
      hostPath: { path: /etc/kubernetes/admin.conf, type: File }
    - name: runtime-sock
      hostPath: { path: /run/containerd/containerd.sock, type: Socket }
    - name: tun
      hostPath: { path: /dev/net/tun, type: CharDevice }
    - name: rawdisk
      hostPath: { path: /dev/sdb, type: BlockDevice }
    - name: applog
      hostPath: { path: /var/log/my-agent.log, type: FileOrCreate }
```

> ⚠️ **`FileOrCreate` does not create parent directories.** If `/var/log/my-agent/` does not exist, the Pod fails. Add a second `DirectoryOrCreate` volume for the parent, or use an init container.

### 🚨 Security Warning

`hostPath` is the most dangerous volume type in Kubernetes. Treat any Pod with a writable `hostPath` as having **root on that node**.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    WHY hostPath IS A PRIVILEGE ESCALATION                │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  hostPath: / (rw)                                                        │
│      └─► write /etc/cron.d/x           → arbitrary command as root       │
│      └─► write /root/.ssh/authorized_keys → SSH in as root               │
│      └─► read /etc/kubernetes/pki/*    → forge any cluster identity      │
│      └─► read /var/lib/kubelet/pods/*  → EVERY secret of EVERY pod       │
│           mounted on that node                                           │
│                                                                          │
│  hostPath: /var/run/docker.sock or containerd.sock (rw)                  │
│      └─► launch a privileged container with the host root mounted        │
│      └─► complete node takeover, then lateral movement                   │
│                                                                          │
│  hostPath: /var/lib/kubelet (rw)                                         │
│      └─► modify another pod's mounted secrets and service account tokens │
│                                                                          │
│  hostPath: /dev (rw)                                                     │
│      └─► raw access to every disk on the node                            │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

Also, a `hostPath` breaks scheduling assumptions: the data exists on **one** node. Reschedule the Pod elsewhere and it silently sees a different (probably empty) directory. Nothing warns you.

### Controlling It

```yaml
# Pod Security Admission: the baseline and restricted profiles both
# forbid hostPath volumes outright.
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
```

Rules of engagement:

| Rule | Why |
|------|-----|
| Prefer `local` PVs over `hostPath` for node local data | `local` PVs carry `nodeAffinity`, so the scheduler keeps the Pod on the right node |
| Always set `readOnly: true` unless writing is genuinely required | Removes the whole escalation class |
| Always set an explicit `type` | Fail fast instead of silently creating directories |
| Never allow `hostPath` in tenant namespaces | Enforce with Pod Security Admission or a policy engine |
| Restrict to system DaemonSets in `kube-system` | Log shippers, CNI, CSI node plugins, monitoring agents legitimately need it |

Legitimate uses do exist, and every cluster has them: CNI plugins writing to `/etc/cni/net.d`, CSI node plugins bind mounting `/var/lib/kubelet` with `Bidirectional` propagation, node exporters reading `/proc` and `/sys`, and log collectors reading `/var/log/pods`.

---

## configMap

Renders the keys of a ConfigMap as files inside the container.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  nginx.conf: |
    server {
      listen 8080;
      root /usr/share/nginx/html;
    }
  index.html: "<h1>hello from a configmap</h1>"
---
apiVersion: v1
kind: Pod
metadata:
  name: cm-demo
spec:
  containers:
    - name: web
      image: nginx:1.27-alpine
      volumeMounts:
        # Whole ConfigMap as a directory: /etc/app/nginx.conf, /etc/app/index.html
        - name: config
          mountPath: /etc/app
          readOnly: true
  volumes:
    - name: config
      configMap:
        name: nginx-config
        defaultMode: 0444          # octal, see the trap below
        optional: false            # pod stays pending if the ConfigMap is missing
        items:                     # OPTIONAL: project only some keys, rename them
          - key: nginx.conf
            path: conf.d/default.conf   # nested paths are allowed
            mode: 0400                  # per item override
```

### What the Directory Looks Like

```bash
kubectl exec cm-demo -- ls -la /etc/app
# lrwxrwxrwx 1 root root   ... nginx.conf -> ..data/nginx.conf
# lrwxrwxrwx 1 root root   ... index.html -> ..data/index.html
# drwxr-xr-x 2 root root   ... ..2025_..._12_00_00.123456789
# lrwxrwxrwx 1 root root   ... ..data -> ..2025_..._12_00_00.123456789
```

The kubelet uses a **symlink swap** to make updates atomic: it writes a new timestamped directory, then repoints the `..data` symlink. Applications always see a consistent set of files, never a half written one. This design is also exactly why `subPath` mounts do not update.

### Update Propagation

| Mount style | Updates when the ConfigMap changes | Delay |
|-------------|-----------------------------------|-------|
| Whole volume mount | ✅ Yes | Up to the kubelet sync period plus cache TTL, typically around a minute |
| `subPath` mount | ❌ **Never** | The file is a one time copy, frozen at Pod start |
| `env` / `envFrom` | ❌ Never | Environment is set once at process exec |

```bash
kubectl create configmap nginx-config --from-file=nginx.conf --dry-run=client -o yaml \
  | kubectl replace -f -
# then watch the file inside the pod change on its own
kubectl exec cm-demo -- watch -n2 cat /etc/app/nginx.conf
```

Note that the *file* updating does not make the *application* reload it. Either the app watches the file (nginx does not by default), or you trigger a rollout. The common pattern is a checksum annotation on the Pod template so that changing the ConfigMap changes the Pod spec and forces a rolling update.

### The defaultMode Octal Trap

```yaml
        defaultMode: 0644    # ✅ YAML parses this as octal → decimal 420 → rw-r--r--
        defaultMode: 420     # ✅ identical, this is what the API stores
        defaultMode: 644     # ❌ decimal 644 → octal 1204 → nonsense permissions
```

Always write the leading zero. Verify with `kubectl get pod <pod> -o jsonpath='{.spec.volumes}'`, which shows the decimal value the API actually stored.

### Immutable ConfigMaps

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
immutable: true      # cannot be changed; kubelet stops watching it
data:
  nginx.conf: "..."
```

Marking large or numerous ConfigMaps immutable meaningfully reduces API server and kubelet load in big clusters, at the cost of having to create a new object to change anything.

> 📖 **Full detail**: [configmaps.md](configmaps.md)

---

## secret

Structurally identical to `configMap`, with different storage and defaults.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: web-tls
type: kubernetes.io/tls
data:
  tls.crt: <base64>
  tls.key: <base64>
---
apiVersion: v1
kind: Pod
metadata:
  name: secret-demo
spec:
  containers:
    - name: web
      image: nginx:1.27-alpine
      volumeMounts:
        - name: tls
          mountPath: /etc/tls
          readOnly: true          # always, for secrets
  volumes:
    - name: tls
      secret:
        secretName: web-tls       # NOTE: secretName, not name
        defaultMode: 0400
        optional: false
        items:
          - key: tls.crt
            path: server.crt
          - key: tls.key
            path: server.key
            mode: 0400
```

### Differences from configMap

| | `configMap` | `secret` |
|---|-------------|----------|
| Field naming the object | `name` | **`secretName`** |
| Backing store on the node | tmpfs | tmpfs |
| Default file mode | 0644 | 0644 |
| Values in the API | plain strings (`data`, `binaryData`) | base64 in `data`, plain in `stringData` |
| Encryption at rest | Optional | Should be configured in etcd |
| Written to node disk | No (tmpfs) | No (tmpfs) |

Secret volumes are backed by tmpfs on Linux nodes, so the plaintext never lands on the node's disk. That is a real security property, and it is another reason to mount secrets as files rather than injecting them as environment variables, which leak into `/proc/<pid>/environ`, crash dumps and child processes.

### The Field Name Trap

```yaml
  volumes:
    - name: creds
      secret:
        name: my-secret         # ❌ WRONG, silently produces an empty volume source error
        secretName: my-secret   # ✅ correct
```

This asymmetry with `configMap` (which uses `name`) is one of the most common YAML mistakes in Kubernetes.

> 📖 **Full detail**: [secrets.md](secrets.md)

---

## downwardAPI

Exposes Pod and container metadata as files, without the application needing API access.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: downward-demo
  labels:
    app: demo
    tier: backend
  annotations:
    build: "2025-09-01"
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /podinfo; cat /podinfo/labels; sleep 3600"]
      resources:
        requests: { cpu: "100m", memory: "128Mi" }
        limits:   { cpu: "500m", memory: "256Mi" }
      volumeMounts:
        - name: podinfo
          mountPath: /podinfo
          readOnly: true
  volumes:
    - name: podinfo
      downwardAPI:
        defaultMode: 0444
        items:
          - path: "name"
            fieldRef: { fieldPath: metadata.name }
          - path: "namespace"
            fieldRef: { fieldPath: metadata.namespace }
          - path: "uid"
            fieldRef: { fieldPath: metadata.uid }
          - path: "nodename"
            fieldRef: { fieldPath: spec.nodeName }
          - path: "podip"
            fieldRef: { fieldPath: status.podIP }
          - path: "labels"
            fieldRef: { fieldPath: metadata.labels }        # volume only
          - path: "annotations"
            fieldRef: { fieldPath: metadata.annotations }   # volume only
          - path: "cpu_limit"
            resourceFieldRef:
              containerName: app
              resource: limits.cpu
              divisor: "1m"
          - path: "mem_limit"
            resourceFieldRef:
              containerName: app
              resource: limits.memory
              divisor: "1Mi"
```

### Volume Form vs Environment Variable Form

| Capability | `downwardAPI` volume | `env.valueFrom.fieldRef` |
|------------|---------------------|--------------------------|
| `metadata.name`, `namespace`, `uid` | ✅ | ✅ |
| `spec.nodeName`, `spec.serviceAccountName` | ✅ | ✅ |
| `status.podIP`, `status.hostIP` | ✅ | ✅ |
| **`metadata.labels`** (the whole set) | ✅ | ❌ |
| **`metadata.annotations`** (the whole set) | ✅ | ❌ |
| Resource requests and limits | ✅ via `resourceFieldRef` | ✅ via `resourceFieldRef` |
| Updates when labels or annotations change | ✅ the files are refreshed | ❌ frozen at exec |

The labels and annotations capability, plus live updates, is the whole reason the volume form exists.

```bash
kubectl exec downward-demo -- cat /podinfo/labels
# app="demo"
# tier="backend"

kubectl label pod downward-demo tier=frontend --overwrite
# wait a moment
kubectl exec downward-demo -- cat /podinfo/labels
# app="demo"
# tier="frontend"      ← updated in place
```

> 📖 **Full detail**: [downward-api.md](downward-api.md)

---

## projected

Assembles several sources into **one** directory. This is what lets you avoid four separate mounts under `/etc/app`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: projected-demo
spec:
  serviceAccountName: app-sa
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "find /etc/app -type l -o -type f; sleep 3600"]
      volumeMounts:
        - name: bundle
          mountPath: /etc/app
          readOnly: true
  volumes:
    - name: bundle
      projected:
        defaultMode: 0444
        sources:
          - configMap:
              name: app-config
              items:
                - key: app.yaml
                  path: config/app.yaml
          - secret:
              name: app-credentials
              items:
                - key: password
                  path: secrets/password
                  mode: 0400
          - downwardAPI:
              items:
                - path: meta/labels
                  fieldRef: { fieldPath: metadata.labels }
                - path: meta/name
                  fieldRef: { fieldPath: metadata.name }
          - serviceAccountToken:
              path: token/vault-token
              audience: vault.example.internal
              expirationSeconds: 3600
```

Result inside the container:

```
/etc/app/
├── config/app.yaml         ← from the ConfigMap
├── secrets/password        ← from the Secret, mode 0400
├── meta/labels             ← from the downward API
├── meta/name
└── token/vault-token       ← a bound, audience scoped ServiceAccount token
```

### Rules

- Sources are limited to `configMap`, `secret`, `downwardAPI`, `serviceAccountToken` and, on clusters that enable it, `clusterTrustBundle`.
- **Paths must not collide.** Two sources projecting the same `path` is a validation error.
- `defaultMode` applies to every source unless a per item `mode` overrides it.
- `optional: true` is available on the `configMap` and `secret` sources, not on `serviceAccountToken`.

### serviceAccountToken: The Important One

```yaml
          - serviceAccountToken:
              path: token                  # required, relative to the mountPath
              audience: vault.example.internal   # who the token is FOR
              expirationSeconds: 3600      # minimum 600 (10 minutes)
```

| Property | Legacy Secret based token | Projected `serviceAccountToken` |
|----------|---------------------------|---------------------------------|
| Expiry | Never | Bounded, and rotated by the kubelet |
| Audience | Any (the API server) | Scoped, so a leaked token is useless elsewhere |
| Bound to a Pod | No | Yes, invalidated when the Pod is deleted |
| Stored in etcd as a Secret | Yes | No |
| Rotation | Manual | Automatic, refreshed well before expiry |

The kubelet refreshes the token before it expires (it starts trying once roughly 80% of the lifetime has elapsed). **An application must re-read the file periodically**, not cache the token at startup. Caching a bound token forever is the classic bug in this area.

The default `/var/run/secrets/kubernetes.io/serviceaccount` mount that every Pod receives is itself a projected volume, combining a bound token, the cluster CA certificate and the namespace:

```bash
kubectl get pod projected-demo -o jsonpath='{.spec.volumes}' | jq '.[] | select(.projected)'
kubectl exec projected-demo -- ls /var/run/secrets/kubernetes.io/serviceaccount
# ca.crt  namespace  token
```

Setting `automountServiceAccountToken: false` on a Pod or ServiceAccount removes that mount entirely, which is good hygiene for workloads that never talk to the API server.

---

## persistentVolumeClaim

The standard way to use durable storage. The Pod names a claim; the claim resolves to a PV; the PV points at the backend.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: default
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
          readOnly: true
  volumes:
    - name: html
      persistentVolumeClaim:
        claimName: nfs-pvc-web-share   # must exist in THIS namespace
        readOnly: true                 # mount read only regardless of PV modes
```

Three constraints that catch people:

1. **The PVC must be in the same namespace as the Pod.** There is no cross namespace claim reference in core Kubernetes.
2. **The PVC must be `Bound` before the Pod can start.** With `volumeBindingMode: Immediate` the Pod waits; with `WaitForFirstConsumer` the Pod being scheduled is what triggers binding.
3. **Several Pods may reference the same PVC**, subject to the PV's access modes. That is how RWX and ROX sharing works, and it is the mechanism behind the lab's shared web content.

```yaml
# Many pods, one claim, read only. This is the nfs-pvc-web-share pattern.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 4
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
              readOnly: true
      volumes:
        - name: html
          persistentVolumeClaim:
            claimName: nfs-pvc-web-share
            readOnly: true
```

Four replicas across four nodes all mount the same `ReadOnlyMany` NFS export. With a `ReadWriteOnce` PV this Deployment would only work if every replica landed on the same node.

> 📖 **Full detail**: [persistent-volumes.md](persistent-volumes.md)

---

## nfs

A direct, inline NFS mount with no PV and no PVC.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: inline-nfs
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /data; sleep 3600"]
      volumeMounts:
        - name: share
          mountPath: /data
  volumes:
    - name: share
      nfs:
        server: tux2lab-engine.user.internal
        path: /tux2lab-data
        readOnly: true
```

Only three fields exist: `server`, `path`, `readOnly`. There is nowhere to put mount options, so the node's client defaults apply.

| Inline `nfs` volume | PV plus PVC on `nfs.csi.k8s.io` |
|---------------------|----------------------------------|
| Server address hard coded in every Pod spec | Address lives in one PV or StorageClass |
| No `mountOptions` | Full `mountOptions` support |
| No capacity accounting or quota | Counts against `ResourceQuota` |
| No lifecycle management | Reclaim policy, expansion, snapshots (driver dependent) |
| Any developer can mount any export | Admin controls which exports exist as PVs |
| Fine for a throwaway debug Pod | The right choice for anything lasting |

Every worker node still needs NFS client packages installed either way, since the mount is performed by the node's kernel.

> 📖 The lab's preferred approach is the CSI driver: [install-csi-nfs.md](install-csi-nfs.md).

---

## iscsi

A direct, inline iSCSI block mount. The node's iSCSI initiator performs the login, the kubelet formats the LUN if needed, and mounts it.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: inline-iscsi
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "df -h /data; sleep 3600"]
      volumeMounts:
        - name: lun
          mountPath: /data
  volumes:
    - name: lun
      iscsi:
        targetPortal: 10.0.0.50:3260
        iqn: iqn.2001-04.com.example:storage.target01
        lun: 0
        fsType: ext4
        readOnly: false
        portals:                       # optional multipath portals
          - 10.0.0.51:3260
        chapAuthDiscovery: true
        chapAuthSession: true
        secretRef:
          name: iscsi-chap-secret      # keys: node.session.auth.username / .password
```

Operational requirements:

- `open-iscsi` (or the distribution equivalent) installed and the `iscsid` service running on every node that might host the Pod.
- The LUN must be presented to that node's initiator IQN on the storage array.
- **Never mount the same LUN read/write on two nodes with a non cluster filesystem.** ext4 or XFS mounted twice will corrupt. That is why iSCSI volumes are RWO in practice.

For anything beyond a lab, use a CSI driver for the array instead. Inline iSCSI gives you no provisioning, no attach coordination and no snapshot support.

---

## local

A `local` volume is node local disk exposed as a **PersistentVolume**. Unlike `hostPath`, the scheduler knows where the data is.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner    # static only, nothing creates these
volumeBindingMode: WaitForFirstConsumer      # MANDATORY in practice
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv-node1-disk1
spec:
  capacity:
    storage: 100Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  local:
    path: /mnt/disks/ssd1                    # must already exist on the node
  nodeAffinity:                              # REQUIRED for local volumes
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - worker-1
```

### local vs hostPath

| | `hostPath` | `local` PV |
|---|-----------|------------|
| Object model | Inline pod volume | PersistentVolume |
| Scheduler awareness | **None**, pod can land anywhere | `nodeAffinity` pins the pod to the right node |
| Data on a different node | Silently different or empty | Impossible, the scheduler prevents it |
| Dynamic provisioning | n/a | No, always static |
| Reclaim | n/a | `Retain`, cleanup is manual |
| Appropriate for | Node agents | Latency sensitive data such as local NVMe for a database |

`WaitForFirstConsumer` is effectively mandatory: with `Immediate` binding the PV controller might bind a claim to a disk on `worker-1` before the scheduler has decided anything, and then the Pod is forced onto `worker-1` regardless of whether it fits there.

Losing the node means losing the data. Replication must be handled by the application, which is why local PVs pair naturally with distributed databases running as StatefulSets.

---

## CSI Inline Volumes

A CSI driver can provide a volume whose entire lifecycle is tied to the Pod, with **no PV and no PVC**. This is designed for drivers that inject data rather than provide capacity: secrets store integrations, certificate providers, per Pod config.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: csi-inline-demo
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /mnt/injected; sleep 3600"]
      volumeMounts:
        - name: injected
          mountPath: /mnt/injected
          readOnly: true
  volumes:
    - name: injected
      csi:
        driver: some.csi.driver.example.com   # must allow Ephemeral mode
        readOnly: true
        volumeAttributes:
          someDriverSpecificKey: "value"
        nodePublishSecretRef:
          name: driver-credentials
```

### Preconditions

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: some.csi.driver.example.com
spec:
  volumeLifecycleModes:
    - Persistent
    - Ephemeral        # ← without this, inline csi volumes are REJECTED
  podInfoOnMount: true # usually required so the driver knows which pod is asking
```

| Aspect | CSI inline | PVC backed CSI |
|--------|------------|----------------|
| Lifecycle | Exactly the Pod's | Independent of the Pod |
| Objects created | None | PVC and PV |
| Provisioning call | `NodePublishVolume` only | `CreateVolume` then attach then stage then publish |
| Capacity / quota | Not tracked | Tracked |
| Suitable for | Data injection | Real storage |
| Who can use it | Anyone who can create a Pod | Anyone who can create a PVC |

> ⚠️ Inline CSI volumes bypass the PVC permission model. A user who can create a Pod can invoke the driver directly with arbitrary `volumeAttributes`. Only enable `Ephemeral` mode on drivers designed for it, and constrain `volumeAttributes` with a policy engine if the driver is sensitive.

---

## Generic Ephemeral Volumes

The best of both worlds: real storage from a StorageClass, with a lifetime tied to the Pod. Kubernetes creates a PVC for you and garbage collects it when the Pod goes away.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ephemeral-scratch
  namespace: storage-demo
spec:
  containers:
    - name: crunch
      image: busybox:1.36
      command: ["sh", "-c", "dd if=/dev/zero of=/scratch/big bs=1M count=2000; sleep 3600"]
      volumeMounts:
        - name: scratch
          mountPath: /scratch
  volumes:
    - name: scratch
      ephemeral:
        volumeClaimTemplate:
          metadata:
            labels:
              purpose: batch-scratch
          spec:
            accessModes:
              - ReadWriteOnce
            storageClassName: nfs-tux2lab
            resources:
              requests:
                storage: 10Gi
```

### The Generated PVC

```bash
kubectl get pvc -n storage-demo
# NAME                       STATUS   VOLUME            CAPACITY   ACCESS MODES   STORAGECLASS
# ephemeral-scratch-scratch  Bound    pvc-4a7e...       10Gi       RWO            nfs-tux2lab
#  └── name is  <pod-name>-<volume-name>

kubectl get pvc ephemeral-scratch-scratch -n storage-demo \
  -o jsonpath='{.metadata.ownerReferences}' | jq
# ownerReference points at the Pod, so deleting the pod deletes the PVC,
# and the PV follows if the class reclaimPolicy is Delete.
```

| Property | Value |
|----------|-------|
| PVC name | `<pod-name>-<volume-name>`, deterministic |
| Owner reference | The Pod, so garbage collection cascades |
| Namespace | The Pod's namespace |
| Counts against `ResourceQuota` | ✅ Yes, unlike `emptyDir` |
| Supports snapshots, expansion, topology | ✅ Whatever the driver supports |

### When to Choose It

| Need | Use |
|------|-----|
| A few hundred MB of scratch | `emptyDir` |
| Tens or hundreds of GB of scratch, per Pod, on real storage | Generic ephemeral volume |
| Scratch that must survive the Pod | A normal PVC |
| Per replica durable storage | StatefulSet `volumeClaimTemplates` |

> ⚠️ **Name collision.** Because the PVC name is deterministic, a user could pre-create `<pod-name>-<volume-name>` and have a Pod pick up storage it should not see. Kubernetes guards against this by checking the owner reference, and refuses to use a PVC that it did not create for that Pod.

---

## volumeMounts in Detail

```yaml
      volumeMounts:
        - name: data                # ← join key to spec.volumes[].name
          mountPath: /var/lib/app   # ← absolute path inside the container
          subPath: instance-01      # ← mount a subdirectory of the volume
          readOnly: true            # ← mount read only for THIS container
          mountPropagation: None    # ← None | HostToContainer | Bidirectional
```

### mountPath

| Rule | Consequence |
|------|-------------|
| Must be absolute | Relative paths are rejected by validation |
| Must not contain `:` | Rejected by validation |
| Must be unique per container | Two mounts at the same path in one container is a validation error |
| Created if missing | The runtime creates the directory inside the container |
| **Shadows anything the image has there** | See [Mount Ordering and Shadowing](#mount-ordering-and-shadowing) |

### readOnly at Three Levels

```yaml
  volumes:
    - name: html
      persistentVolumeClaim:
        claimName: nfs-pvc-web-share
        readOnly: true          # (2) volume source level, applies to all mounts
```

```yaml
      volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
          readOnly: true        # (1) mount level, applies to this container only
```

Plus **(3)** the PV's `accessModes` and the backend's own export options. The effective access is the most restrictive of all of them, and a `ro` in `/etc/exports` on the NFS server beats every Kubernetes field. That layering is exactly why "why is my volume read only?" needs a checklist rather than a guess.

Some clusters additionally support `recursiveReadOnly` on a mount, which makes read only apply to submounts as well, not just the top level mount. Check `kubectl explain pod.spec.containers.volumeMounts` on your own cluster before relying on it.

---

## subPath and subPathExpr

`subPath` mounts a **subdirectory or single file** of a volume rather than the whole thing.

```yaml
      volumeMounts:
        # Whole volume: /var/lib/mysql gets everything in the PVC
        - name: data
          mountPath: /var/lib/mysql

        # subPath: only <volume>/mysql appears at /var/lib/mysql
        - name: data
          mountPath: /var/lib/mysql
          subPath: mysql

        # subPath on a ConfigMap: mount ONE key as a file without
        # replacing the whole /etc/nginx directory
        - name: config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
```

### The Two Reasons subPath Exists

**1. Share one volume between several workloads or containers.**

```
   PVC "shared-data"
     ├── postgres/     ← mounted by the database at /var/lib/postgresql/data
     ├── redis/        ← mounted by the cache at /data
     └── uploads/      ← mounted by the app at /srv/uploads
```

**2. Mount a single file into a directory that must keep its other contents.**

Without `subPath`, mounting a ConfigMap at `/etc/nginx` replaces the entire directory, and nginx loses `mime.types`, `conf.d` and everything else the image shipped. With `subPath: nginx.conf` and `mountPath: /etc/nginx/nginx.conf`, only that one file is replaced.

### 🚨 The ConfigMap and Secret Live Update Caveat

> **A `subPath` mount of a ConfigMap or Secret never receives updates.**

This is not a bug, it follows directly from the symlink swap design:

```
   NORMAL MOUNT                          subPath MOUNT
   ────────────                          ─────────────
   /etc/app/  (the volume root)          /etc/nginx/nginx.conf
     ..data -> ..2025_09_01_...            is a bind mount straight to
     nginx.conf -> ..data/nginx.conf       ONE INODE inside the volume

   kubelet writes a NEW timestamped       the bind mount still points at the
   directory and repoints ..data          OLD inode, forever

   ✅ container sees the new content      ❌ container sees the original file
                                            until the pod is recreated
```

Workarounds:

| Approach | Trade off |
|----------|-----------|
| Mount the whole ConfigMap in a separate directory and symlink or read from there | Requires app cooperation |
| Add a checksum annotation to the Pod template so config changes force a rollout | Explicit, auditable, the usual production answer |
| Use `projected` with nested `path` values instead of `subPath` | Keeps live updates, restructures the layout |
| Accept it and roll the Deployment on every config change | Simple and predictable |

```yaml
# The checksum annotation pattern
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    metadata:
      annotations:
        # Changing the ConfigMap changes this value, which changes the pod
        # template, which triggers a rolling update.
        checksum/config: "8f14e45fceea167a5a36dedd4bea2543"
```

### subPathExpr

`subPath` is a static string. `subPathExpr` expands environment variables, which is what makes per Pod paths possible.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: per-pod-subpath
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo hello > /logs/app.log; sleep 3600"]
      env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
      volumeMounts:
        - name: shared-logs
          mountPath: /logs
          subPathExpr: $(NODE_NAME)/$(POD_NAME)   # each pod gets its own dir
  volumes:
    - name: shared-logs
      persistentVolumeClaim:
        claimName: cluster-logs
```

Rules:

- `subPath` and `subPathExpr` are **mutually exclusive** on one mount.
- Expansion uses `$(VAR)` syntax and only resolves variables defined in that container's `env`.
- Use `$$(VAR)` to emit a literal `$(VAR)`.
- The directory is created if it does not exist.

This pattern turns a single RWX PVC into per Pod private directories, which is the usual way to give a DaemonSet writable space on shared storage.

### subPath Sharp Edges

| Issue | Detail |
|-------|--------|
| No live updates for ConfigMap and Secret | Covered above, the big one |
| Directory is created with kubelet's ownership | May not match `fsGroup` expectations |
| `..` is rejected | Path traversal is blocked by validation |
| Expansion failure | An undefined variable in `subPathExpr` leaves the literal text, producing a strangely named directory |
| Resize with subPath | Expanding the underlying PVC still works, but the mount is of a subdirectory, so the app may not notice |

---

## Mount Propagation

Controls whether mounts created **inside** the container are visible on the host, and vice versa. It maps directly onto Linux mount propagation.

```yaml
      volumeMounts:
        - name: host-mounts
          mountPath: /mnt/host
          mountPropagation: HostToContainer
```

| Value | Linux equivalent | Host mount appears in container | Container mount appears on host | Requires `privileged` |
|-------|------------------|-------------------------------|-------------------------------|-----------------------|
| `None` (default) | `rprivate` | ❌ | ❌ | No |
| `HostToContainer` | `rslave` | ✅ | ❌ | No |
| `Bidirectional` | `rshared` | ✅ | ✅ | **Yes** |

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        MOUNT PROPAGATION                                 │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  None (default)                                                          │
│     HOST mounts /mnt/host/nfs-share  ──✗──►  container sees nothing new  │
│     CONTAINER mounts /mnt/host/x     ──✗──►  host sees nothing new       │
│     Fully isolated. Safe. Correct for almost every workload.             │
│                                                                          │
│  HostToContainer  (rslave)                                               │
│     HOST mounts /mnt/host/nfs-share  ──✓──►  container sees it appear    │
│     CONTAINER mounts /mnt/host/x     ──✗──►  host sees nothing           │
│     One way. Ideal for monitoring agents that must see new host mounts.  │
│                                                                          │
│  Bidirectional  (rshared)   ⚠️ requires privileged: true                 │
│     HOST mounts ...                  ──✓──►  container sees it           │
│     CONTAINER mounts ...             ──✓──►  HOST SEES IT TOO            │
│     This is how CSI node plugins publish volumes for other pods.         │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Where Each One Is Used

- **`None`**: everything normal. Do not change it without a specific reason.
- **`HostToContainer`**: a node exporter or log agent mounting `/var/lib/kubelet` or `/mnt`, which needs to see volumes that appear after the agent started. Without it, the agent sees the directory as it looked at container start and silently misses later mounts.
- **`Bidirectional`**: CSI node plugins, and only CSI node plugins in most clusters. The driver mounts a volume inside its own container at `/var/lib/kubelet/pods/...` and that mount must become visible to the kubelet and to the target Pod on the host.

```yaml
# Excerpt from a typical CSI node DaemonSet
        volumeMounts:
          - name: kubelet-dir
            mountPath: /var/lib/kubelet
            mountPropagation: Bidirectional
      volumes:
        - name: kubelet-dir
          hostPath:
            path: /var/lib/kubelet
            type: Directory
```

> ⚠️ **`Bidirectional` plus `hostPath` plus `privileged` is total node compromise if abused.** A container with that combination can mount anything anywhere on the host. It is correct for a CSI driver and wrong for an application. Pod Security Admission's `baseline` profile blocks it.

The node's own mounts must also be shared (`mount --make-rshared /`) for propagation to work at all; on most modern distributions systemd already does this.

---

## Sharing a Volume Between Containers

All containers in a Pod share the same set of volumes. This is the foundation of the sidecar pattern.

### Worked Example: Log Producer and Log Shipper

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-logging
  namespace: storage-demo
spec:
  volumes:
    - name: applogs
      emptyDir:
        sizeLimit: 256Mi
    - name: shipper-config
      configMap:
        name: shipper-config

  initContainers:
    - name: prepare
      image: busybox:1.36
      command: ["sh", "-c", "mkdir -p /logs/app && chmod 0775 /logs/app"]
      volumeMounts:
        - name: applogs
          mountPath: /logs

  containers:
    # ── PRODUCER: writes ────────────────────────────────────────────────
    - name: app
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          i=0
          while true; do
            i=$((i+1))
            echo "$(date -Iseconds) request id=$i" >> /var/log/app/access.log
            sleep 2
          done
      volumeMounts:
        - name: applogs
          mountPath: /var/log/app
          subPath: app                # writes into <volume>/app

    # ── CONSUMER: reads, read only ──────────────────────────────────────
    - name: shipper
      image: busybox:1.36
      command: ["sh", "-c", "tail -F /input/access.log"]
      volumeMounts:
        - name: applogs
          mountPath: /input
          subPath: app                # SAME directory, different mountPath
          readOnly: true              # consumer cannot corrupt the producer
        - name: shipper-config
          mountPath: /etc/shipper
          readOnly: true
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│                      ONE VOLUME, TWO VIEWS                               │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   POD sidecar-logging                                                    │
│                                                                          │
│   ┌────────────────────┐              ┌────────────────────┐             │
│   │  app (producer)    │              │ shipper (consumer) │             │
│   │                    │              │                    │             │
│   │  writes            │              │  reads             │             │
│   │  /var/log/app/     │              │  /input/           │             │
│   │    access.log      │              │    access.log      │             │
│   │  rw                │              │  ro                │             │
│   └─────────┬──────────┘              └─────────┬──────────┘             │
│             │                                   │                        │
│             │      subPath: app                 │  subPath: app          │
│             └──────────────┬────────────────────┘                        │
│                            ▼                                             │
│              ┌──────────────────────────────┐                            │
│              │  emptyDir volume "applogs"   │                            │
│              │    /app/access.log           │                            │
│              └──────────────────────────────┘                            │
│                                                                          │
│   Both containers see the SAME inode. The producer's writes are          │
│   visible to the consumer immediately, with no network involved.         │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

```bash
kubectl logs sidecar-logging -c shipper -f
# 2025-09-01T12:00:00+00:00 request id=1
# 2025-09-01T12:00:02+00:00 request id=2
```

### Design Rules for Shared Volumes

| Rule | Reason |
|------|--------|
| Mount `readOnly: true` in every container that does not write | Prevents accidental corruption, documents intent |
| Use different `mountPath` values freely | The path is per container, only the volume name is shared |
| Have exactly one writer per file | Two writers appending to one file without locking interleave badly |
| Prepare directories and permissions in an init container | It runs to completion before the app containers start |
| Set `sizeLimit` on the shared `emptyDir` | A runaway producer otherwise fills the node and evicts the Pod |
| Consider `fsGroup` when the containers run as different UIDs | Otherwise the consumer cannot read what the producer wrote |

---

## Init Containers and Volumes

Init containers run to completion, in order, before any app container starts, and they see the same volumes. That makes them the correct place for anything that must happen to a volume before the application touches it.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: init-volume-work
spec:
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: app-data
    - name: secrets-plain
      emptyDir:
        medium: Memory
        sizeLimit: 16Mi

  initContainers:
    # 1. Fix ownership without granting the app container any privilege
    - name: fix-perms
      image: busybox:1.36
      command: ["sh", "-c", "chown -R 1000:1000 /data && chmod 0750 /data"]
      securityContext:
        runAsUser: 0
      volumeMounts:
        - name: data
          mountPath: /data

    # 2. Seed an empty volume on first run only
    - name: seed
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          if [ ! -f /data/.initialised ]; then
            echo "seeding"
            cp -r /defaults/. /data/
            touch /data/.initialised
          fi
      volumeMounts:
        - name: data
          mountPath: /data

    # 3. Materialise decrypted material into a tmpfs the app can read
    - name: decrypt
      image: busybox:1.36
      command: ["sh", "-c", "echo 'decrypted-value' > /out/token"]
      volumeMounts:
        - name: secrets-plain
          mountPath: /out

  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "cat /run/creds/token; ls -la /data; sleep 3600"]
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        allowPrivilegeEscalation: false
      volumeMounts:
        - name: data
          mountPath: /data
        - name: secrets-plain
          mountPath: /run/creds
          readOnly: true
```

The `fix-perms` pattern is worth highlighting: the privileged `chown` runs in a throwaway container that exits, while the application itself runs unprivileged as UID 1000. This is usually preferable to `fsGroup` when the volume is large, because a recursive `chown` on every Pod start is expensive.

> 📖 **Related**: [pod-lifecycle.md](pod-lifecycle.md) for init container ordering and restart semantics.

---

## Mount Ordering and Shadowing

A `volumeMount` **replaces** whatever the image had at that path. The image content is not merged, not backed up, and not visible.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        SHADOWING AN IMAGE DIRECTORY                      │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  IMAGE nginx:1.27-alpine ships:                                          │
│    /etc/nginx/nginx.conf                                                 │
│    /etc/nginx/mime.types                                                 │
│    /etc/nginx/conf.d/default.conf                                        │
│                                                                          │
│  ── Mount the whole ConfigMap at /etc/nginx ──────────────────────────   │
│    volumeMounts:                                                         │
│      - name: config                                                      │
│        mountPath: /etc/nginx        ← REPLACES THE DIRECTORY             │
│                                                                          │
│    Container now sees ONLY:                                              │
│      /etc/nginx/nginx.conf          (from the ConfigMap)                 │
│    mime.types and conf.d ARE GONE. nginx fails to start.                 │
│                                                                          │
│  ── Mount one file with subPath ──────────────────────────────────────   │
│    volumeMounts:                                                         │
│      - name: config                                                      │
│        mountPath: /etc/nginx/nginx.conf                                  │
│        subPath: nginx.conf          ← replaces ONE FILE                  │
│                                                                          │
│    Container sees:                                                       │
│      /etc/nginx/nginx.conf          (from the ConfigMap)  ✔              │
│      /etc/nginx/mime.types          (from the image)      ✔              │
│      /etc/nginx/conf.d/default.conf (from the image)      ✔              │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Nested Mounts

Mounts at nested paths are applied from the shortest path to the longest, so a deeper mount lands on top of a shallower one.

```yaml
      volumeMounts:
        - name: everything
          mountPath: /data           # applied first
        - name: just-cache
          mountPath: /data/cache     # applied second, visible on top
```

The container sees `everything` at `/data`, except at `/data/cache`, where it sees `just-cache`. The `cache` subdirectory of the `everything` volume still exists on the backend, it is simply hidden.

### Diagnosing Shadowing

```bash
# What does the image actually contain at that path?
kubectl run probe --rm -it --restart=Never --image=nginx:1.27-alpine -- ls -la /etc/nginx

# What does the running pod see?
kubectl exec <pod> -- ls -la /etc/nginx

# Which mounts are active, and in what order?
kubectl exec <pod> -- mount | grep -v ' proc \| sysfs \| cgroup '
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].volumeMounts}' | jq
```

A container that starts fine standalone but fails in Kubernetes with "file not found" or "no such directory" is very often a shadowed image directory.

---

## Ownership, fsGroup and SELinux

The most common runtime storage failure is not a missing volume, it is `Permission denied` after the volume mounts perfectly.

### The securityContext Fields That Touch Volumes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ownership-demo
spec:
  securityContext:                  # POD level: applies to volumes
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000                   # volumes are chgrp'd to 2000, mode g+rwX
    fsGroupChangePolicy: OnRootMismatch
    seLinuxOptions:
      level: "s0:c123,c456"
    supplementalGroups: [4000]
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "id; ls -ln /data; touch /data/probe; sleep 3600"]
      securityContext:              # CONTAINER level: does NOT affect volumes
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: app-data
```

| Field | Level | Effect on volumes |
|-------|-------|-------------------|
| `runAsUser` | Pod or container | The UID that must be able to read and write the files |
| `runAsGroup` | Pod or container | The primary GID of the process |
| **`fsGroup`** | **Pod only** | kubelet sets group ownership and adds group permissions on the volume |
| **`fsGroupChangePolicy`** | **Pod only** | Whether to do that recursively every time, or only when needed |
| `supplementalGroups` | Pod only | Extra groups, useful for NFS exports with a known GID |
| `seLinuxOptions` | Pod or container | The SELinux label applied to the volume content |

### What fsGroup Actually Does

When `fsGroup` is set, before starting containers the kubelet:

1. Sets the group ownership of the volume's contents to that GID.
2. Adds group read, write and (for directories) execute permissions.
3. Sets the setgid bit on directories, so new files inherit the group.

```bash
kubectl exec ownership-demo -- ls -ln /data
# drwxrwsr-x 2 0 2000 4096 ... .
#      ^  ^        ^
#      |  |        └── group is fsGroup
#      |  └── setgid, so new files inherit group 2000
#      └── group has write
```

### fsGroupChangePolicy: Always vs OnRootMismatch

```yaml
  securityContext:
    fsGroup: 2000
    fsGroupChangePolicy: OnRootMismatch    # or Always (the default)
```

| Policy | Behaviour | Cost on a volume with 10 million files |
|--------|-----------|----------------------------------------|
| `Always` (default) | Recursively `chown` and `chmod` **every file, every time** the Pod starts | Minutes to hours. The Pod sits in `ContainerCreating` the whole time. |
| `OnRootMismatch` | Check the **top level directory** only. If its owner and mode already match, skip the recursion entirely. | Milliseconds on every start after the first |

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    WHY OnRootMismatch MATTERS                            │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Always:                                                                 │
│    pod start ──► chown -R 2000 /volume  (10M files)                      │
│                  ├── every restart                                       │
│                  ├── every reschedule                                    │
│                  └── every node drain                                    │
│    Result: pods that take 20 minutes to become Ready, repeatedly.        │
│                                                                          │
│  OnRootMismatch:                                                         │
│    pod start ──► stat /volume                                            │
│                  ├── owner and mode already correct? ──► SKIP, start now │
│                  └── mismatch? ──► do the full recursive chown once      │
│    Result: the expensive operation happens exactly once, on first use.   │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

For any volume that will grow large (databases, artefact stores, media), set `fsGroupChangePolicy: OnRootMismatch`. The one caveat: if something changes ownership deeper in the tree without touching the root directory, the policy will not notice and will not fix it.

### When fsGroup Does Nothing

`fsGroup` only applies where the volume plugin supports ownership management. The `CSIDriver` object controls this per driver:

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: nfs.csi.k8s.io
spec:
  fsGroupPolicy: File     # None | File | ReadWriteOnceWithFSType
```

| `fsGroupPolicy` | Meaning |
|-----------------|---------|
| `None` | The driver's volumes are never modified by `fsGroup`. Typical for shared network filesystems where the server owns permissions. |
| `File` | Ownership and permissions are managed, on the assumption the volume is a filesystem |
| `ReadWriteOnceWithFSType` | Only for RWO volumes that declare an `fsType`. This was the historical default behaviour. |

```bash
kubectl get csidriver nfs.csi.k8s.io -o jsonpath='{.spec.fsGroupPolicy}{"\n"}'
```

On NFS specifically, even when `fsGroup` is applied, the **server** decides what happens. With `root_squash` (the sensible default), a `chown` issued as root from the client is mapped to `nobody` and denied. The reliable approaches for NFS are:

1. Set the ownership on the server side once, and use `runAsUser` / `runAsGroup` matching it.
2. Use `supplementalGroups` with a GID that the export grants.
3. Export with the right ownership and use `ReadOnlyMany`, as the lab's `nfs-pv-web-share` does, sidestepping the problem entirely.

### SELinux and Volumes

On SELinux enforcing nodes (RHEL family, and openSUSE / SLES with SELinux enabled), a container process carries a type and an MCS level such as `s0:c123,c456`. It can only access files labelled with a compatible context.

```yaml
  securityContext:
    seLinuxOptions:
      user: "system_u"
      role: "object_r"
      type: "container_file_t"
      level: "s0:c123,c456"
```

Two ways the label gets applied to a volume:

| Mechanism | How | Cost |
|-----------|-----|------|
| **Recursive relabelling** | The runtime walks the volume and `chcon`s every file | Same scaling problem as `fsGroup: Always`. Very slow on large volumes. |
| **Mount option** | The volume is mounted with `-o context=<label>`, so the whole filesystem presents that label with no walk | Constant time, and the modern approach |

The mount option path is what the `seLinuxMount` field on `CSIDriver` and the related SELinux mount features enable. Availability depends on your Kubernetes version and driver, so check rather than assume:

```bash
kubectl get csidriver <driver> -o yaml | grep -i selinux
```

Diagnosis when a mount succeeds but access fails on an SELinux node:

```bash
# On the node
ausearch -m avc -ts recent
ls -Z /var/lib/kubelet/pods/<pod-uid>/volumes/...
getenforce
```

An AVC denial mentioning `container_file_t` versus `nfs_t` or `default_t` is the signature. For NFS specifically, the boolean `virt_use_nfs` (or the container equivalent on your distribution) is often what is missing.

> ⚠️ Setting `privileged: true` or disabling SELinux to "fix" a label problem trades a small permissions issue for a large security hole. Fix the label.

---

## Read Only Root Filesystem Pattern

A hardened container runs with an immutable root filesystem and gets writable space only where it genuinely needs it.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    fsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      securityContext:
        readOnlyRootFilesystem: true       # ← the whole point
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        # Every path the process must write to gets an emptyDir
        - name: tmp
          mountPath: /tmp
        - name: run
          mountPath: /var/run
        - name: cache
          mountPath: /var/cache/nginx
        # Read only content from the shared NFS export
        - name: html
          mountPath: /usr/share/nginx/html
          readOnly: true
  volumes:
    - name: tmp
      emptyDir: { sizeLimit: 64Mi }
    - name: run
      emptyDir: { medium: Memory, sizeLimit: 8Mi }
    - name: cache
      emptyDir: { sizeLimit: 128Mi }
    - name: html
      persistentVolumeClaim:
        claimName: nfs-pvc-web-share
        readOnly: true
```

Finding the paths a given image needs to write is empirical: run it with `readOnlyRootFilesystem: true`, read the error, add an `emptyDir`, repeat. Common ones are `/tmp`, `/var/run`, `/run`, `/var/cache`, `/var/tmp` and application specific state directories.

---

## Node Volume Limits

Every node has a cap on how many volumes of a given driver can be attached at once, imposed by the underlying platform (device slots, controller limits). The scheduler respects it.

```bash
# What the node reports
kubectl get csinodes <node> -o yaml
# spec:
#   drivers:
#   - name: some.csi.driver
#     allocatable:
#       count: 25            ← max attachable volumes for this driver on this node
#     nodeID: ...
#     topologyKeys: [...]
```

A Pod that cannot be placed because every candidate node is at its volume limit reports a scheduling failure mentioning `node(s) exceed max volume count`.

```bash
kubectl describe pod <pod> | grep -A5 Events
# 0/6 nodes are available: 6 node(s) exceed max volume count.
```

Drivers that do not require attachment (such as `nfs.csi.k8s.io` with `attachRequired: false`) have no such limit, which is one practical advantage of file based storage for high density nodes.

---

## Troubleshooting

### Symptom 1: Pod Stuck in ContainerCreating

Always start here:

```bash
kubectl describe pod <pod> -n <ns> | sed -n '/Events/,$p'
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -30
```

| Event message | Cause | Fix |
|---------------|-------|-----|
| `configmap "x" not found` | The ConfigMap does not exist in this namespace | Create it, or set `optional: true` on the volume source |
| `secret "x" not found` | Same, for Secrets. Also check `secretName` vs `name` | Create it, or fix the field name |
| `MountVolume.SetUp failed ... access denied by server while mounting` | The NFS export does not allow this node | Fix `/etc/exports`, run `exportfs -ra`, check the node IP is in range |
| `wrong fs type, bad option, bad superblock` | NFS or iSCSI client packages missing on the node | Install `nfs-utils` / `nfs-common` / `open-iscsi` on every worker |
| `no such host` | Node cannot resolve the storage server name | Fix node DNS, or use an IP address in the volume source |
| `hostPath type check failed: /x is not a directory` | Wrong `type` value, or path absent | Correct the `type`, or pre-create the path |
| `Multi-Attach error for volume` | An RWO volume is still attached elsewhere | Find the other Pod or the dead node |
| `timeout expired waiting for volumes to attach or mount` | Backend unreachable, driver crashed, firewall | Check driver logs and network path |
| `unable to attach or mount volumes: unmounted volumes=[data]` | A generic wrapper; the real reason is in an earlier event | Scroll up in the event list |

### Symptom 2: Permission Denied Writing to a Mounted Volume

```bash
kubectl exec <pod> -- id
# uid=1000 gid=3000 groups=2000,4000

kubectl exec <pod> -- ls -ln /data
# drwxr-xr-x 2 0 0 4096 ... .      ← owned by root:root, mode 755, no group write
```

Decision path:

```
   Is the volume itself read only?
     ├── volumeMount readOnly: true          → remove it
     ├── volume source readOnly: true        → remove it
     ├── PV accessModes: [ReadOnlyMany]      → wrong mode for this workload
     └── server side export is 'ro'          → fix /etc/exports
   Otherwise it is an ownership problem:
     ├── set securityContext.fsGroup, and confirm CSIDriver fsGroupPolicy != None
     ├── or set runAsUser / runAsGroup to match the backend ownership
     ├── or add supplementalGroups matching the export's GID
     ├── or chown once in a privileged init container
     └── on NFS, remember root_squash defeats a root chown from the client
```

### Symptom 3: ConfigMap Updated but the File Did Not Change

```bash
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].volumeMounts}' | jq
```

If the mount has a `subPath`, that is your answer: `subPath` mounts never update. If it does not, wait about a minute (the kubelet sync period plus its cache TTL) and check again. If it still has not changed, verify you edited the right object in the right namespace, and confirm the ConfigMap is not `immutable: true`.

### Symptom 4: Container Crashes on Start After Adding a Mount

Almost always shadowing.

```bash
# Compare image content against what the pod sees
kubectl run probe --rm -it --restart=Never --image=<same-image> -- ls -la <mountPath>
kubectl exec <pod> -- ls -la <mountPath>
```

If the image had files there and the Pod does not, switch to a `subPath` mount of the single file, or mount the volume somewhere else and point the application at it with a flag or environment variable.

### Symptom 5: Pod Evicted with Low Ephemeral Storage

```bash
kubectl get events -n <ns> --field-selector reason=Evicted
kubectl describe pod <pod> -n <ns> | grep -i -A5 message
```

An `emptyDir` grew past `sizeLimit`, or the Pod's total local usage exceeded `limits.ephemeral-storage`, or the node crossed a `nodefs` eviction threshold. Add or lower `sizeLimit`, set explicit `ephemeral-storage` requests and limits, or move the workload's scratch space to a generic ephemeral volume backed by real storage.

### Symptom 6: Memory Backed emptyDir Causing OOM Kills

```bash
kubectl get pod <pod> -o jsonpath='{.spec.volumes}' | jq '.[] | select(.emptyDir.medium=="Memory")'
kubectl exec <pod> -- df -h | grep tmpfs
kubectl describe pod <pod> | grep -iE 'OOMKilled|Last State'
```

tmpfs pages count against the Pod's memory cgroup. Either set a `sizeLimit` well below the memory limit, or move the data to a disk backed `emptyDir`.

### Symptom 7: Sidecar Cannot See Files the Main Container Wrote

Checklist:

```bash
# Same volume name in both containers?
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].volumeMounts}' | jq

# Same subPath? A mismatch means two different directories.
# Same UID/GID, or a shared fsGroup?
kubectl exec <pod> -c producer -- id
kubectl exec <pod> -c consumer -- id
kubectl exec <pod> -c consumer -- ls -ln <mountPath>
```

The two classic causes are a `subPath` mismatch between the containers and a UID mismatch with no `fsGroup`.

### Symptom 8: hostPath Data Missing After a Reschedule

Expected, and unfixable with `hostPath`. The Pod moved to another node, where that path holds different data or nothing at all.

```bash
kubectl get pod <pod> -o jsonpath='{.spec.nodeName}{"\n"}'
```

The fix is architectural: use a `local` PV with `nodeAffinity` so the scheduler keeps the Pod on the correct node, or move to network backed storage.

### Symptom 9: Volume Mounts, but the Application Sees an Empty Directory

```bash
# Is the pod looking at the path you think it is?
kubectl exec <pod> -- mount | grep -w <mountPath>
kubectl exec <pod> -- ls -la <mountPath>
```

Common causes: a `subPath` pointing at a directory that does not exist yet (it is created empty), a fresh dynamically provisioned volume that genuinely is empty, or a second mount shadowing the first at a nested path.

### Symptom 10: Node Agent Does Not See New Host Mounts

The agent mounts a host directory with the default `mountPropagation: None`, so mounts created on the host after the container started are invisible to it.

```yaml
        - name: kubelet-dir
          mountPath: /var/lib/kubelet
          readOnly: true
          mountPropagation: HostToContainer     # ← the fix
```

---

## Exam and Interview Traps

1. **A volume survives container restarts, not Pod deletion.** `emptyDir` data is intact across crash loops and OOM kills.
2. **Volumes are declared once per Pod, mounted per container.** The `name` field is the join key and must match exactly.
3. **`emptyDir` with `medium: Memory` counts against the Pod's memory limit**, not `ephemeral-storage`. Filling it causes an OOM kill.
4. **A memory backed `emptyDir` without `sizeLimit` defaults to roughly half the node's RAM.** Always cap it.
5. **`secret` uses `secretName`; `configMap` uses `name`.** This asymmetry is a very common YAML bug.
6. **`defaultMode: 644` is wrong.** Write `0644` so YAML parses it as octal.
7. **`subPath` mounts of ConfigMaps and Secrets never receive updates.** The mount is bound to one inode; the kubelet's atomic update swaps a symlink.
8. **Environment variables from ConfigMaps and Secrets never update either.** Only whole volume mounts do.
9. **`subPath` and `subPathExpr` are mutually exclusive** on a single mount.
10. **`subPathExpr` only expands variables defined in that container's `env`.**
11. **A `volumeMount` shadows whatever the image had at that path.** Mounting a ConfigMap at `/etc/nginx` destroys the rest of the directory from the container's point of view.
12. **`mountPropagation: Bidirectional` requires `privileged: true`** and is intended for CSI node plugins, not applications.
13. **`HostToContainer` is one way**: the container sees new host mounts, but the host never sees container mounts.
14. **`fsGroup` is a Pod level field.** There is no container level `fsGroup`.
15. **`fsGroupChangePolicy: Always` recursively chowns the entire volume on every Pod start.** Use `OnRootMismatch` for large volumes.
16. **`fsGroup` may do nothing at all** if the driver's `CSIDriver.fsGroupPolicy` is `None`, or if the NFS server squashes root.
17. **`hostPath` has eight `type` values.** The empty default performs no checks; always set one explicitly.
18. **`FileOrCreate` does not create parent directories.**
19. **`hostPath` is a node level privilege escalation.** Pod Security Admission's `baseline` and `restricted` profiles forbid it.
20. **`local` PVs require `nodeAffinity`** and should use `WaitForFirstConsumer`. `hostPath` has neither, which is precisely the difference.
21. **CSI inline volumes require `volumeLifecycleModes: [Ephemeral]`** on the `CSIDriver` object.
22. **A generic ephemeral volume's PVC is named `<pod-name>-<volume-name>`** and is owned by the Pod, so it is garbage collected with it.
23. **Generic ephemeral volumes count against `ResourceQuota`; `emptyDir` does not.**
24. **The inline `nfs` volume type has only `server`, `path` and `readOnly`.** No mount options.
25. **A PVC referenced by a Pod must be in the same namespace.** There are no cross namespace claims in core Kubernetes.
26. **Projected volume paths must not collide**, and `serviceAccountToken` has a minimum `expirationSeconds` of 600.
27. **Bound service account tokens are rotated by the kubelet.** Applications must re-read the file rather than caching it forever.
28. **`metadata.labels` and `metadata.annotations` are only available through a `downwardAPI` volume**, never as environment variables.
29. **Init containers see the same volumes** and are the correct place for `chown`, seeding and one time preparation.
30. **Nested mounts apply shortest path first**, so a deeper mount is layered on top of a shallower one.

---

## Related Topics

- [Storage Overview](storage.md)
- [Persistent Volumes and Claims](persistent-volumes.md)
- [Pods](pods.md)
- [Pod Lifecycle](pod-lifecycle.md)
- [Pod Operations](pod-operations.md)
- [ConfigMaps](configmaps.md)
- [Secrets](secrets.md)
- [Downward API](downward-api.md)
- [Containers](containers.md)
- [Container Runtime](container-runtime.md)
- [Linux Namespaces](linux-namespaces.md)
- [Cgroups](cgroups.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [kubelet](kubelet.md)
- [Installing the NFS CSI Driver](install-csi-nfs.md)
- [Installing the SMB CSI Driver](install-csi-smb.md)

---

## Key Takeaways

1. A volume is a directory the kubelet prepares on the node and bind mounts into a container's mount namespace. There is no magic beyond Linux mount namespaces.
2. Volumes are declared once at Pod level and mounted independently in each container, at any path, with any `readOnly` setting. The `name` field is the join.
3. The lifecycle rule: a volume survives container restarts, including crash loops and OOM kills, but dies with the Pod unless the data lives outside the node.
4. `emptyDir` is the workhorse for scratch and for sidecar handoff. Set `sizeLimit`, and remember that `medium: Memory` charges the Pod's memory limit rather than its ephemeral storage.
5. `hostPath` is the most dangerous volume type. Always set an explicit `type`, always prefer `readOnly`, and prefer a `local` PV whenever the scheduler needs to know where the data lives.
6. `configMap`, `secret`, `downwardAPI` and `projected` are API driven volumes rendered onto tmpfs. Whole volume mounts update live; `subPath` mounts and environment variables never do.
7. `projected` combines ConfigMaps, Secrets, downward API entries and bound ServiceAccount tokens into one directory. Bound tokens are audience scoped, expiring and rotated, so applications must re-read them.
8. `persistentVolumeClaim` is the standard persistent path. The claim must be in the Pod's namespace, and several Pods can share one claim when the PV's access modes allow it.
9. Inline `nfs` and `iscsi` volumes work but give up mount options, quota and lifecycle management. Prefer a CSI driver with a PV and PVC.
10. Generic ephemeral volumes give real storage with Pod scoped lifetime, creating a PVC named `<pod-name>-<volume-name>` owned by the Pod. They count against quota; `emptyDir` does not.
11. `subPath` mounts a subdirectory or a single file, which is how you replace one config file without destroying the rest of a directory. Its cost is losing live updates for ConfigMaps and Secrets.
12. `subPathExpr` expands environment variables, turning one shared RWX volume into per Pod private directories.
13. Mount propagation is `None` by default. `HostToContainer` lets an agent see new host mounts; `Bidirectional` requires `privileged: true` and exists for CSI node plugins.
14. A `volumeMount` shadows the image's content at that path. Unexpected "file not found" errors after adding a mount are almost always this.
15. Ownership problems dominate real world storage failures. `fsGroup` fixes many of them, `fsGroupChangePolicy: OnRootMismatch` keeps it affordable on large volumes, and neither helps when the driver's `fsGroupPolicy` is `None` or the NFS server squashes root.
16. On SELinux nodes, prefer context mount options over recursive relabelling, and read the AVC denials rather than disabling enforcement.

---

## References

- [Volumes](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Ephemeral Volumes](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/)
- [Projected Volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Configure a Pod to Use a Volume for Storage](https://kubernetes.io/docs/tasks/configure-pod-container/configure-volume-storage/)
- [Configure a Pod to Use a ConfigMap](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/)
- [Distribute Credentials Securely Using Secrets](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/)
- [Expose Pod Information to Containers Through Files](https://kubernetes.io/docs/tasks/inject-data-application/downward-api-volume-expose-pod-information/)
- [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Configure volume permission and ownership change policy](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#configure-volume-permission-and-ownership-change-policy-for-pods)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Managing Service Accounts](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)
- [Sidecar Containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/)
- [Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)
- [Local ephemeral storage](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage)
- [Node pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Pod API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
- [Kubernetes CSI Developer Documentation: Ephemeral Inline Volumes](https://kubernetes-csi.github.io/docs/ephemeral-local-volumes.html)
