# 💾 Kubernetes Storage: The Complete Mental Map

A hub document for the whole Kubernetes storage domain: why containers need storage that outlives them, how the Pod, Volume, PVC, PV, StorageClass and CSI layers stack up, and how to choose the right approach for a workload.

## 📋 Table of Contents
- [Why Containers Need External Storage](#why-containers-need-external-storage)
- [The Layered Storage Model](#the-layered-storage-model)
- [Ephemeral Storage vs Persistent Storage](#ephemeral-storage-vs-persistent-storage)
- [Separation of Concerns: Developer and Administrator](#separation-of-concerns-developer-and-administrator)
- [Storage Taxonomy: Block, File and Object](#storage-taxonomy-block-file-and-object)
- [Access Modes](#access-modes)
- [Volume Binding and the Two Provisioning Models](#volume-binding-and-the-two-provisioning-models)
- [StorageClass: The Provisioning Template](#storageclass-the-provisioning-template)
- [Choosing a Storage Approach](#choosing-a-storage-approach)
- [The Container Storage Ecosystem](#the-container-storage-ecosystem)
- [CSI Architecture in a Cluster](#csi-architecture-in-a-cluster)
- [Node Level Storage Concerns](#node-level-storage-concerns)
- [End to End Worked Example on the NFS Lab](#end-to-end-worked-example-on-the-nfs-lab)
- [Storage Object Quick Reference](#storage-object-quick-reference)
- [Observability and Useful Commands](#observability-and-useful-commands)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why Containers Need External Storage

A container image is a stack of read only layers. When a container starts, the runtime adds one thin **writable layer** on top using a union filesystem (overlayfs on most modern Linux systems). Everything the process writes that is not on a mounted volume lands in that writable layer.

That writable layer has three properties that make it unsuitable for anything you care about:

1. **It dies with the container.** Not with the Pod, with the *container*. A crash loop, an OOM kill, a liveness probe restart: each one throws away the writable layer and starts from the image again.
2. **It is not shareable.** Two containers in the same Pod each get their own writable layer. They cannot see each other's writes.
3. **It is slow for write heavy work.** Copy up on first write, extra union filesystem indirection, and no way to tune it independently of the node root disk.

```
┌──────────────────────────────────────────────────────────────────────┐
│              Container Filesystem: Image Layers + Writable Layer     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌──────────────────────────────────────────────┐                   │
│   │  Writable container layer  (read/write)      │  ← EPHEMERAL      │
│   │  /var/log/app.log, /tmp/scratch, /data/*     │    dies on        │
│   └──────────────────────────────────────────────┘    container      │
│   ═══════════════ union mount (overlayfs) ═══════      restart       │
│   ┌──────────────────────────────────────────────┐                   │
│   │  Layer 3: application binary   (read only)   │  ← from the image │
│   ├──────────────────────────────────────────────┤    shared by      │
│   │  Layer 2: runtime + libraries  (read only)   │    every          │
│   ├──────────────────────────────────────────────┤    container      │
│   │  Layer 1: base OS rootfs       (read only)   │    from the       │
│   └──────────────────────────────────────────────┘    same image     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

The fix is a **volume**: a directory (or a raw block device) that is prepared outside the union filesystem and bind mounted into the container's mount namespace. Because the mount is set up by the kubelet before the container starts, and torn down only when the Pod is removed from the node, its contents survive container restarts. If the volume is backed by network or remote block storage, it survives the Pod and the node too.

> 📖 **Background**: [containers.md](containers.md) for image layers and the union filesystem, [docker.md](docker.md) for how the same idea appears as `docker volume` and bind mounts, [linux-namespaces.md](linux-namespaces.md) for why a mount namespace is what makes a "volume" possible at all.

### The Same Problem in Docker Terms

| Docker concept | Kubernetes equivalent | Notes |
|----------------|----------------------|-------|
| Writable container layer | Container writable layer | Same thing, still ephemeral |
| `-v /host/path:/data` (bind mount) | `hostPath` volume | Node local, dangerous, avoid in production |
| `docker volume create` (named volume) | `emptyDir` (per Pod), or a PVC (durable) | Docker named volumes live on one host only |
| `--tmpfs /tmp` | `emptyDir` with `medium: Memory` | RAM backed, counts against memory |
| Volume driver plugin | CSI driver | CSI is the standardised, out of tree successor |

The critical difference: Docker volumes are a **single host** concept. Kubernetes schedules Pods across many nodes, so the storage layer has to answer a question Docker never had to: *how does the data follow the Pod to whichever node it lands on?* That question is why PersistentVolumes, StorageClasses and CSI exist.

---

## The Layered Storage Model

Everything in Kubernetes storage is one of seven layers. Learn this stack and the rest is detail.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE KUBERNETES STORAGE STACK                             │
└─────────────────────────────────────────────────────────────────────────────┘

  ╔═══════════════════════════════════════════════════════════════════════╗
  ║  1. POD                                             (developer owns)  ║
  ║     spec.containers[].volumeMounts                                    ║
  ║        name: data                                                     ║
  ║        mountPath: /usr/share/nginx/html   ← where it appears inside   ║
  ║        readOnly: true                       the container             ║
  ╚═══════════════════════════════════════╤═══════════════════════════════╝
                                          │ matched by name
                                          ▼
  ╔═══════════════════════════════════════════════════════════════════════╗
  ║  2. VOLUME (pod scoped)                             (developer owns)  ║
  ║     spec.volumes[]                                                    ║
  ║        name: data                                                     ║
  ║        persistentVolumeClaim:            ← one of ~20 volume types    ║
  ║          claimName: nfs-pvc-web-share      (emptyDir, configMap, ...) ║
  ╚═══════════════════════════════════════╤═══════════════════════════════╝
                                          │ references by name, same namespace
                                          ▼
  ╔═══════════════════════════════════════════════════════════════════════╗
  ║  3. PERSISTENTVOLUMECLAIM (namespaced)              (developer owns)  ║
  ║     "I need 10Gi, ReadWriteOnce, from class fast-ssd"                 ║
  ║     A REQUEST. Contains no backend detail whatsoever.                 ║
  ╚═══════════════════════════════════════╤═══════════════════════════════╝
                                          │ bound 1:1 by the PV controller
                                          ▼
  ╔═══════════════════════════════════════════════════════════════════════╗
  ║  4. PERSISTENTVOLUME (cluster scoped)                  (admin owns)   ║
  ║     "Here is 10Gi of real storage, this is how to reach it"           ║
  ║     A RESOURCE. Contains driver, volumeHandle, server, share, ...     ║
  ╚═══════════════════════════════════════╤═══════════════════════════════╝
                                          │ created by hand (static)
                                          │ or by a provisioner (dynamic)
                                          ▼
  ╔═══════════════════════════════════════════════════════════════════════╗
  ║  5. STORAGECLASS (cluster scoped)                      (admin owns)   ║
  ║     provisioner + parameters + reclaimPolicy + volumeBindingMode      ║
  ║     A TEMPLATE for making PVs on demand.                              ║
  ╚═══════════════════════════════════════╤═══════════════════════════════╝
                                          │ provisioner name selects
                                          ▼
  ╔═══════════════════════════════════════════════════════════════════════╗
  ║  6. CSI DRIVER                                    (vendor / operator) ║
  ║     controller Deployment  +  node DaemonSet                          ║
  ║     Implements CreateVolume, ControllerPublish, NodeStage, NodePublish║
  ╚═══════════════════════════════════════╤═══════════════════════════════╝
                                          │ speaks the backend protocol
                                          ▼
  ╔═══════════════════════════════════════════════════════════════════════╗
  ║  7. BACKEND STORAGE                                 (storage team)    ║
  ║     NFS export, SMB share, iSCSI LUN, Ceph RBD, cloud disk, local SSD ║
  ╚═══════════════════════════════════════════════════════════════════════╝
```

### Reading the Stack in Both Directions

**Top down (what a developer writes):** a container needs files at `/usr/share/nginx/html`, so it declares a `volumeMount`. That mount points at a Pod level `volume`, which points at a `persistentVolumeClaim`. The developer stops there.

**Bottom up (what actually happens at runtime):** an NFS export exists on a server. A CSI driver knows how to mount it. A StorageClass names that driver. A PV describes one concrete volume on it. A PVC binds to that PV. The kubelet, seeing a scheduled Pod, asks the CSI node plugin to stage and publish the volume, then bind mounts the published path into the container.

### Not Every Volume Reaches the Bottom

Layers 3 to 7 exist **only for persistent storage**. An `emptyDir`, a `configMap` or a `downwardAPI` volume stops at layer 2: the kubelet materialises it directly on the node, with no claim, no PV and no driver involved.

```
  Pod ──► volumeMounts ──► volumes ──┬──► emptyDir          (stops here)
                                     ├──► configMap         (stops here)
                                     ├──► secret            (stops here)
                                     ├──► downwardAPI       (stops here)
                                     ├──► projected         (stops here)
                                     ├──► hostPath          (stops here)
                                     ├──► csi (inline)      ──► CSI driver ──► backend
                                     ├──► ephemeral         ──► PVC ──► PV ──► SC ──► CSI
                                     └──► persistentVolumeClaim ──► PV ──► SC ──► CSI ──► backend
```

---

## Ephemeral Storage vs Persistent Storage

The single most useful distinction in the whole domain.

```
┌────────────────────────────────────────────────────────────────────────┐
│                     LIFETIME OF EACH STORAGE KIND                      │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  Container writable layer                                              │
│  ├── survives:  nothing                                                │
│  └── destroyed by: container restart, crash, OOM kill, image update    │
│      │                                                                 │
│  emptyDir / configMap / secret / downwardAPI / projected               │
│  ├── survives:  container restart (including crash loops)              │
│  └── destroyed by: pod deletion, pod eviction, node failure            │
│      │                                                                 │
│  hostPath / local PV                                                   │
│  ├── survives:  pod deletion, node reboot                              │
│  └── destroyed by: node loss, disk failure  (data is pinned to a node) │
│      │                                                                 │
│  Network backed PV (NFS, SMB, iSCSI, Ceph, cloud disk)                 │
│  ├── survives:  pod deletion, node failure, cluster rebuild            │
│  └── destroyed by: PV deletion with reclaimPolicy Delete, or by the    │
│                    storage administrator on the backend                │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### Side by Side

| Aspect | Ephemeral storage | Persistent storage |
|--------|-------------------|--------------------|
| Lifetime | Tied to the Pod | Independent of the Pod |
| Typical types | `emptyDir`, `configMap`, `secret`, `downwardAPI`, `projected`, generic ephemeral, CSI inline | `persistentVolumeClaim`, `nfs`, `iscsi`, `local` |
| Object created | None (or an auto managed PVC) | PVC, and a PV behind it |
| Survives node failure | No | Yes, if the backend is network attached |
| Follows the Pod to a new node | No | Yes, if the backend is network attached |
| Capacity accounting | `ephemeral-storage` requests and limits | PV `capacity.storage` and quota |
| Who provisions | kubelet, locally | CSI driver or an administrator |
| Common use | Scratch, cache, config injection, sidecar handoff | Databases, uploads, artefacts, shared web content |

### The Rule Everybody Gets Wrong

> A volume outlives a **container** restart. It does not outlive the **Pod**, unless the volume is backed by something outside the node.

An `emptyDir` is often described as "temporary", which leads people to believe a crashing container loses it. It does not. The kubelet creates the `emptyDir` directory when the Pod is assigned to the node and deletes it when the Pod is removed from the node. Every container restart in between sees the same data. That is precisely what makes `emptyDir` useful for sidecar handoff patterns.

---

## Separation of Concerns: Developer and Administrator

The PVC/PV split exists so that an application manifest can be portable across clusters that have completely different storage underneath.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        THE CONTRACT                                      │
├────────────────────────────────┬─────────────────────────────────────────┤
│  DEVELOPER  (namespace scoped) │  ADMINISTRATOR  (cluster scoped)        │
├────────────────────────────────┼─────────────────────────────────────────┤
│                                │                                         │
│  Writes:                       │  Writes:                                │
│    PersistentVolumeClaim       │    StorageClass                         │
│    Pod / Deployment / STS      │    PersistentVolume (static case)       │
│                                │    CSIDriver, ResourceQuota, LimitRange │
│                                │                                         │
│  Declares WHAT:                │  Declares HOW:                          │
│    "10Gi"                      │    which server, which export           │
│    "ReadWriteOnce"             │    which CSI driver                     │
│    "class: fast-ssd"           │    which mount options                  │
│    "Filesystem"                │    replication, encryption, IOPS tier   │
│                                │    reclaim policy, expansion allowed    │
│                                │                                         │
│  Never needs to know:          │  Never needs to know:                   │
│    server hostnames            │    which app is asking                  │
│    export paths                │    the mountPath inside the container   │
│    credentials                 │                                         │
│                                │                                         │
└────────────────────────────────┴─────────────────────────────────────────┘

  The same Deployment YAML runs unchanged on the home lab (NFS),
  in a datacenter (Ceph), and in a cloud (managed block storage),
  because the only storage word in it is a StorageClass name.
```

### Why This Matters Operationally

- **Least privilege.** A developer with only namespace RBAC can create a PVC. Creating a PV requires cluster level rights, because a PV can point at *any* backend path, including sensitive ones.
- **Quota.** `ResourceQuota` can cap `requests.storage` and `persistentvolumeclaims` count per namespace, and even per StorageClass with `<class>.storageclass.storage.k8s.io/requests.storage`.
- **Blast radius.** Changing an NFS server address means editing StorageClass and PV objects, not hundreds of Deployments.
- **Auditability.** All backend detail lives in a small set of cluster scoped objects that an admin reviews.

---

## Storage Taxonomy: Block, File and Object

Three fundamentally different storage shapes, and only two of them are first class Kubernetes citizens.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  BLOCK              │  FILE                    │  OBJECT               │
├─────────────────────┼──────────────────────────┼───────────────────────┤
│  Raw device         │  Filesystem tree         │  Key to blob map      │
│  /dev/sdb           │  /exports/data           │  s3://bucket/key      │
│                     │                          │                       │
│  Read/write sectors │  Read/write files        │  PUT / GET whole objs │
│  You bring the FS   │  Server owns the FS      │  No FS at all         │
│                     │                          │                       │
│  Lowest latency     │  Shareable by design     │  Infinite scale       │
│  Single writer      │  Many writers            │  HTTP API             │
│                     │                          │                       │
│  iSCSI, FC, NVMe-oF │  NFS, SMB/CIFS, CephFS   │  S3, Swift, MinIO     │
│  Ceph RBD           │  GlusterFS               │                       │
│  Cloud block disks  │  Managed file shares     │  Cloud object stores  │
└─────────────────────┴──────────────────────────┴───────────────────────┘
```

### Mapping to Kubernetes Primitives

| Shape | `volumeMode` | Typical access modes | Kubernetes primitives | Notes |
|-------|--------------|----------------------|-----------------------|-------|
| **Block, formatted** | `Filesystem` | `ReadWriteOnce`, `ReadWriteOncePod` | PV + PVC + CSI driver | The default. Kubelet or CSI formats and mounts it. |
| **Block, raw** | `Block` | `ReadWriteOnce`, sometimes `ReadWriteMany` for cluster aware apps | PV + PVC with `volumeDevices` | No filesystem. The app writes to `/dev/xvda` style paths. |
| **File (network)** | `Filesystem` | `ReadWriteMany`, `ReadOnlyMany`, `ReadWriteOnce` | PV + PVC + CSI driver, or in-tree `nfs` volume | Shareable across nodes. The lab uses this. |
| **File (node local)** | `Filesystem` | `ReadWriteOnce` | `local` PV with `nodeAffinity`, or `hostPath` | Fast, but pins the Pod to one node. |
| **File (pod local)** | n/a | n/a | `emptyDir` | Node disk or tmpfs, no PV involved. |
| **Object** | n/a | n/a | **None built in** | Applications use an SDK over HTTP. COSI exists as a separate project but is not core storage. |

### Object Storage Is Deliberately Absent

There is no `apiVersion: v1, kind: ObjectBucketClaim` in core Kubernetes. Object stores are accessed by the application over HTTP with credentials, so the Kubernetes shaped problem is **credential delivery**, not volume mounting. That is a [Secret](secrets.md) and a ServiceAccount problem, not a PV problem.

The Container Object Storage Interface (COSI) is a separate SIG Storage effort with its own CRDs, and it is not part of the core storage API discussed here. If a workload needs a bucket, give it a Secret and an endpoint.

---

## Access Modes

An access mode is a **claim about how many nodes and Pods can mount the volume at once**. It is enforced during binding and attachment, not by the filesystem.

| Mode | Short | Meaning | Enforced how |
|------|-------|---------|--------------|
| `ReadWriteOnce` | RWO | Mounted read/write by **a single node**. Multiple Pods on that same node can use it. | Attachment refuses a second node |
| `ReadOnlyMany` | ROX | Mounted read only by **many nodes** | Mount is read only |
| `ReadWriteMany` | RWX | Mounted read/write by **many nodes** | Backend must support concurrent writers |
| `ReadWriteOncePod` | RWOP | Mounted read/write by **exactly one Pod in the whole cluster** | Scheduler and kubelet refuse a second Pod |

### The RWO Misconception

`ReadWriteOnce` means **one node**, not one Pod. Two Pods scheduled onto the same node can both mount the same RWO volume read/write, and they will happily corrupt each other's data if the application is not designed for it. This surprises people constantly.

`ReadWriteOncePod` is the mode that actually means "one Pod". It graduated to stable in Kubernetes 1.29 and requires a CSI driver, since in-tree plugins never supported it.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                       ACCESS MODE SEMANTICS                              │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ReadWriteOnce (RWO)                                                     │
│      node-a                          node-b                              │
│      ┌──────────────────┐            ┌──────────────────┐                │
│      │ pod-1  ✅ rw     │            │ pod-3  ❌ blocked│                │
│      │ pod-2  ✅ rw  ⚠️ │            │                  │                │
│      └────────┬─────────┘            └──────────────────┘                │
│               └──────────► [ VOLUME ]                                    │
│      ⚠️ two pods on ONE node is allowed and is a real corruption risk    │
│                                                                          │
│  ReadWriteOncePod (RWOP)                                                 │
│      ┌──────────────────┐            ┌──────────────────┐                │
│      │ pod-1  ✅ rw     │            │ pod-3  ❌ blocked│                │
│      │ pod-2  ❌ blocked│            │                  │                │
│      └────────┬─────────┘            └──────────────────┘                │
│               └──────────► [ VOLUME ]   exactly one pod, cluster wide    │
│                                                                          │
│  ReadWriteMany (RWX)                                                     │
│      ┌──────────────────┐            ┌──────────────────┐                │
│      │ pod-1  ✅ rw     │            │ pod-3  ✅ rw     │                │
│      └────────┬─────────┘            └────────┬─────────┘                │
│               └──────────► [ VOLUME ] ◄───────┘                          │
│      needs a backend with real concurrency (NFS, SMB, CephFS)            │
│                                                                          │
│  ReadOnlyMany (ROX)                                                      │
│      ┌──────────────────┐            ┌──────────────────┐                │
│      │ pod-1  ✅ ro     │            │ pod-3  ✅ ro     │                │
│      └────────┬─────────┘            └────────┬─────────┘                │
│               └──────────► [ VOLUME ] ◄───────┘                          │
│      ideal for shared static web content, reference data, model files    │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Which Backends Realistically Support What

| Backend | RWO | ROX | RWX | RWOP | Reality check |
|---------|-----|-----|-----|------|---------------|
| **NFS** | ✅ | ✅ | ✅ | ✅ with CSI | Native multi writer. The lab's choice. |
| **SMB / CIFS** | ✅ | ✅ | ✅ | ✅ with CSI | Same shape as NFS. See [install-csi-smb.md](install-csi-smb.md). |
| **CephFS** | ✅ | ✅ | ✅ | ✅ | Real distributed POSIX filesystem |
| **Ceph RBD** | ✅ | ✅ | ⚠️ block only | ✅ | RWX only meaningful for `volumeMode: Block` with a cluster aware app |
| **iSCSI** | ✅ | ✅ | ⚠️ block only | ✅ with CSI | Multi writer on a shared filesystem is a data loss trap |
| **Cloud block disks** | ✅ | ⚠️ | ❌ | ✅ | Single attach by design |
| **Cloud managed file shares** | ✅ | ✅ | ✅ | ✅ | NFS or SMB under the hood |
| **`local` PV** | ✅ | ❌ | ❌ | ✅ | Single node by definition |
| **`hostPath`** | ✅ | ✅ nominally | ❌ | ✅ nominally | Each node has *different* data, so "many" is meaningless |

> ⚠️ **The mode is a declaration, not a guarantee.** Kubernetes will honour `ReadWriteMany` on a PV you hand write for a cloud block disk, bind it, and then fail at attach time on the second node. Nothing validates that the backend can actually do it. Declaring RWX over an unformatted shared block device and mounting ext4 on two nodes will silently destroy the filesystem.

### Access Modes Are a List, and Matching Is Subset Based

```yaml
# PV offers two modes
spec:
  accessModes:
    - ReadWriteOnce
    - ReadOnlyMany
```

```yaml
# PVC requests one; the PV qualifies because the PVC's set is a
# subset of the PV's set
spec:
  accessModes:
    - ReadOnlyMany
```

A Pod mounts the volume in **one** mode at a time, decided by the PVC and by `readOnly` on the mount. The PV's list is the menu, not the state.

---

## Volume Binding and the Two Provisioning Models

```
┌───────────────────────────────────────────────────────────────────────────┐
│                       STATIC PROVISIONING                                 │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│   Admin, ahead of time:                                                   │
│      1. Creates the export / LUN / disk on the backend                    │
│      2. Writes a PersistentVolume YAML describing it                      │
│      3. kubectl apply -f pv.yaml            → PV status: Available        │
│                                                                           │
│   Developer, later:                                                       │
│      4. Creates a PVC                                                     │
│      5. PV controller finds a matching Available PV                       │
│      6. Binds them                          → PV status: Bound            │
│                                                                           │
│   ✅ Full control over the backend layout                                 │
│   ✅ Works with storage that has no CSI provisioner                       │
│   ❌ Manual, does not scale, PVs sit idle until claimed                   │
└───────────────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────────────┐
│                       DYNAMIC PROVISIONING                                │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│   Admin, once:                                                            │
│      1. Installs a CSI driver                                             │
│      2. Creates a StorageClass naming that driver                         │
│                                                                           │
│   Developer, any time:                                                    │
│      3. Creates a PVC with storageClassName: <that class>                 │
│      4. external-provisioner sees the PVC, calls CreateVolume on the CSI  │
│         controller                                                        │
│      5. Backend creates real storage                                      │
│      6. A PV object is created automatically and bound to the PVC         │
│                                                                           │
│   ✅ Self service, scales to thousands of claims                          │
│   ✅ Lifecycle managed: delete the PVC, the volume can go too             │
│   ❌ Needs a driver that implements CreateVolume                          │
└───────────────────────────────────────────────────────────────────────────┘
```

### How the Controller Decides

The PersistentVolume controller inside [kube-controller-manager](kube-controller-manager.md) runs a loop over unbound PVCs:

```
   PVC created
       │
       ▼
   Does spec.volumeName name a specific PV?
       ├── yes ──► bind to exactly that PV if it is compatible and free
       │
       └── no
            │
            ▼
       Search all PVs with status Available for one where ALL hold:
          • PV accessModes  ⊇  PVC accessModes
          • PV capacity     ≥  PVC resources.requests.storage
          • PV storageClassName == PVC storageClassName
          • PV volumeMode   == PVC volumeMode
          • PV labels match PVC spec.selector (if any)
          • PV claimRef is empty, or already points at this PVC
            │
            ├── found ──► bind (smallest sufficient PV wins)
            │
            └── none found
                   │
                   ▼
              Is there a StorageClass to provision from?
                   ├── yes ──► dynamic provisioning
                   └── no  ──► PVC stays Pending forever
```

Binding is **exclusive and one to one**. Once a PV is bound to a PVC, no other PVC can use it, even if the PV has spare capacity. There is no partial allocation and no sharing of one PV between two claims. Sharing happens at the *Pod* level, by having several Pods reference the **same PVC**.

> 📖 **Depth**: the full state machine, the `claimRef` mechanics and `WaitForFirstConsumer` are covered in [persistent-volumes.md](persistent-volumes.md).

---

## StorageClass: The Provisioning Template

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-tux2lab
  annotations:
    # Exactly one class in the cluster should carry this as "true".
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: nfs.csi.k8s.io          # must match CSIDriver metadata.name
parameters:                          # driver specific, NOT validated by the API
  server: tux2lab-engine.user.internal
  share: /tux2lab-data
  subDir: ${pvc.metadata.namespace}-${pvc.metadata.name}
reclaimPolicy: Delete                # Delete | Retain   (default Delete)
allowVolumeExpansion: true           # can PVCs be grown later
volumeBindingMode: Immediate         # Immediate | WaitForFirstConsumer
mountOptions:                        # applied to every PV from this class
  - nfsvers=4.1
  - hard
  - noatime
```

| Field | Purpose | Mutable after creation |
|-------|---------|------------------------|
| `provisioner` | Which driver handles this class. Use `kubernetes.io/no-provisioner` for static only classes such as `local`. | ❌ |
| `parameters` | Free form key/value passed to the driver's `CreateVolume`. Every driver defines its own. | ❌ |
| `reclaimPolicy` | Written into the `persistentVolumeReclaimPolicy` of PVs this class creates | ❌ |
| `allowVolumeExpansion` | Gate for growing a PVC later | ✅ |
| `volumeBindingMode` | `Immediate` binds at once, `WaitForFirstConsumer` waits for a Pod | ❌ |
| `mountOptions` | Mount flags baked into generated PVs | ❌ |
| `allowedTopologies` | Restrict provisioning to specific zones or nodes | ❌ |

> ⚠️ StorageClasses are effectively **immutable** apart from `allowVolumeExpansion`. To change parameters, create a new class. Existing PVs keep the settings they were born with.

### The Default StorageClass

```bash
# Which class is default?
kubectl get storageclass
# NAME                 PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION
# nfs-tux2lab (default) nfs.csi.k8s.io   Delete          Immediate           true

# Make one default
kubectl patch storageclass nfs-tux2lab -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Unset the previous default first, two defaults is an error state
kubectl patch storageclass old-class -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

The three states of `storageClassName` on a PVC are a classic exam item:

| PVC `storageClassName` | Effect |
|------------------------|--------|
| Field omitted entirely | The **default** StorageClass is applied by an admission controller and written into the object |
| `storageClassName: ""` | Explicitly **no class**. Only binds to PVs that also have no class. Disables dynamic provisioning. |
| `storageClassName: fast` | Binds to PVs of class `fast`, or dynamically provisions from it |

---

## Choosing a Storage Approach

```
                        Does the data need to survive
                        the pod being deleted?
                                  │
                ┌─────────── no ──┴── yes ────────────┐
                │                                     │
                ▼                                     ▼
     Is it configuration or           Must more than one node write
     identity data?                   to it at the same time?
        │                                    │
   ┌─ yes ─┴─ no ─┐                  ┌─ yes ─┴─ no ──────────┐
   │              │                  │                       │
   ▼              ▼                  ▼                       ▼
 configMap    Does it need      RWX capable file      Does it need the
 secret       to be RAM         storage:              lowest possible
 downwardAPI  backed / never    NFS, SMB, CephFS      latency?
 projected    touch disk?          │                      │
                  │           ┌────┴────┐          ┌─ yes ┴─ no ─┐
             ┌─ yes ─┴─ no ─┐ │  lab:   │          │             │
             │              │ │ nfs.csi │          ▼             ▼
             ▼              ▼ │ .k8s.io │      local PV    Network block
        emptyDir:       emptyDir└─────────┘     with        or file PV
        medium: Memory  (default,             nodeAffinity  (RWO)
        + sizeLimit     node disk)            (pins pod)
```

### Decision Table

| Requirement | Use | Avoid |
|-------------|-----|-------|
| Scratch space for one Pod | `emptyDir` | A PVC, it is wasteful |
| Cache that must not touch disk | `emptyDir` with `medium: Memory` and a `sizeLimit` | Unbounded tmpfs, it eats the memory limit |
| Sidecar writes, main container reads | `emptyDir` shared between both containers | `hostPath` |
| Inject a config file | `configMap` volume | Baking config into the image |
| Inject credentials | `secret` volume, or `projected` with `serviceAccountToken` | Environment variables for anything rotating |
| Pod metadata as files | `downwardAPI` | Hard coded values |
| Shared static web content across many Pods | ROX PVC on NFS | `hostPath`, each node differs |
| Database data directory | RWO (ideally RWOP) PVC on block storage | NFS unless the DB explicitly supports it |
| Per replica storage for a clustered app | StatefulSet `volumeClaimTemplates` | One shared RWX PVC |
| Node agent reading host logs | `hostPath` with `type: Directory`, read only | Anything writable on the host |
| Access to the container runtime socket | `hostPath` with `type: Socket`, read only, tightly RBAC'd | Granting it broadly, it is root on the node |
| Bulk artefacts, backups, images | Object storage over HTTP | Forcing a PV where a bucket belongs |

### The NFS Caveat for Databases

NFS is excellent for shared web content, artefacts and general file sharing. It is a poor default for transactional databases: POSIX locking semantics over NFS, `fsync` durability guarantees, and the failure behaviour of a `soft` mount are all subtly different from local block storage. Most database vendors either forbid NFS or require a very specific mount option set. Use block storage with RWO for databases, and treat NFS as file sharing, which is exactly how the lab uses it.

---

## The Container Storage Ecosystem

### Three Eras

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ERA 1: IN-TREE VOLUME PLUGINS                                          │
│                                                                         │
│    Storage driver code lived INSIDE the Kubernetes source tree.         │
│    kubelet ──► compiled-in plugin ──► backend                           │
│                                                                         │
│    ❌ A vendor bug needed a Kubernetes release to fix                   │
│    ❌ Every driver's code ran inside kubelet and controller-manager     │
│    ❌ Cloud SDK dependencies bloated every Kubernetes binary            │
│    ❌ Vendors had to get code merged into Kubernetes itself             │
├─────────────────────────────────────────────────────────────────────────┤
│  ERA 2: FLEXVOLUME (transitional, deprecated)                           │
│                                                                         │
│    Executables dropped onto every node in a plugin directory.           │
│    kubelet ──► exec /usr/libexec/.../driver ──► backend                 │
│                                                                         │
│    ❌ Required root filesystem access on every node to install          │
│    ❌ No standard packaging, no dynamic provisioning story              │
│    ❌ Deprecated in favour of CSI                                       │
├─────────────────────────────────────────────────────────────────────────┤
│  ERA 3: CSI  (Container Storage Interface)  ← the standard today        │
│                                                                         │
│    A gRPC specification. Drivers ship as ordinary containers.           │
│    kubelet ──► gRPC over a unix socket ──► CSI node plugin ──► backend  │
│                                                                         │
│    ✅ Vendor releases on its own schedule                               │
│    ✅ Deployed with kubectl, like any other workload                    │
│    ✅ One spec shared by Kubernetes, Nomad, Mesos, CloudFoundry         │
│    ✅ Snapshots, cloning, expansion, topology, capacity tracking        │
└─────────────────────────────────────────────────────────────────────────┘
```

### CSI Migration

Rather than break every existing manifest, Kubernetes introduced **CSI migration**: the in-tree plugin name stays valid in YAML, but the request is transparently translated and handled by the corresponding CSI driver.

```
   User writes:                  Kubernetes internally does:
   ┌──────────────────┐          ┌────────────────────────────────┐
   │ StorageClass     │          │ translation shim rewrites the  │
   │ provisioner:     │  ──────► │ request to the CSI driver, and │
   │   kubernetes.io/ │          │ the CSI driver does the work   │
   │   <cloud>-disk   │          └────────────────────────────────┘
   └──────────────────┘
   Existing PVs and PVCs keep working. No manifest change required.
```

Over successive releases the migrated in-tree plugins were removed entirely, so on a modern cluster the CSI driver must actually be installed for those provisioner names to work. The practical takeaway for anyone building a cluster today:

| Plugin family | Status today | What to do |
|---------------|--------------|------------|
| Major cloud block and file plugins | Migrated to CSI, in-tree code removed | Install the vendor CSI driver |
| Ceph RBD, GlusterFS, and several other in-tree network plugins | Deprecated and removed | Use the vendor CSI driver |
| FlexVolume | Deprecated | Migrate to CSI |
| `nfs` | Still an in-tree volume type, no migration | Works, but prefer `nfs.csi.k8s.io` for PVs and dynamic provisioning |
| `iscsi` | Still an in-tree volume type | Prefer a CSI driver for anything managed |
| `hostPath`, `local`, `emptyDir`, `configMap`, `secret`, `downwardAPI`, `projected` | Core, not going anywhere | These are kubelet features, not storage backends |

> ⚠️ Do not assert a specific removal version from memory. Check `kubectl explain pv.spec` on the cluster in front of you, and the release notes for the version you run.

### The CSIDriver Object

Installing a CSI driver creates a cluster scoped `CSIDriver` object that tells Kubernetes how to treat it.

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: nfs.csi.k8s.io            # this exact string is the provisioner name
spec:
  attachRequired: false           # NFS needs no ControllerPublish/attach step
  podInfoOnMount: true            # pass pod name/namespace/uid to NodePublishVolume
  volumeLifecycleModes:
    - Persistent                  # add Ephemeral to allow CSI inline volumes
  fsGroupPolicy: File             # None | File | ReadWriteOnceWithFSType
  storageCapacity: false          # publish CSIStorageCapacity objects for the scheduler
  requiresRepublish: false        # periodically call NodePublishVolume again
```

| Field | Why it matters |
|-------|----------------|
| `attachRequired` | If `false`, no `VolumeAttachment` objects are created. NFS style drivers set this to `false`, which is why you never see multi-attach errors with NFS. |
| `podInfoOnMount` | Lets the driver use `${pod.name}` style templating and per Pod credentials |
| `fsGroupPolicy` | Controls whether the kubelet applies `fsGroup` ownership changes to this driver's volumes |
| `volumeLifecycleModes` | Must include `Ephemeral` before CSI inline volumes are permitted |
| `storageCapacity` | Enables capacity aware scheduling via `CSIStorageCapacity` |

```bash
kubectl get csidrivers
kubectl describe csidriver nfs.csi.k8s.io
```

---

## CSI Architecture in a Cluster

```
┌──────────────────────────────────────────────────────────────────────────┐
│  CONTROL PLANE                                                           │
│                                                                          │
│   kube-apiserver   ◄─── all sidecars watch and update objects here       │
│   kube-controller-manager                                                │
│     ├── PersistentVolume controller   (binding, reclaiming)              │
│     └── AttachDetach controller       (VolumeAttachment objects)         │
│                                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐   │
│   │  CSI CONTROLLER   (a Deployment, usually 1 to 3 replicas)        │   │
│   │                                                                  │   │
│   │   ┌─────────────────────┐      ┌─────────────────────────┐       │   │
│   │   │ csi-provisioner     │      │  VENDOR CSI PLUGIN      │       │   │
│   │   │ csi-attacher        │      │  (controller service)   │       │   │
│   │   │ csi-resizer         │ ◄──► │                         │       │   │
│   │   │ csi-snapshotter     │      │  CreateVolume           │       │   │
│   │   │ livenessprobe       │      │  DeleteVolume           │       │   │
│   │   └─────────────────────┘      │  ControllerPublishVolume│       │   │
│   │    sidecars translate          │  ControllerExpandVolume │       │   │
│   │    objects into gRPC calls     └───────────┬─────────────┘       │   │
│   └────────────────────────────────────────────┼─────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
                                                 │ backend storage API
┌──────────────────────────────────────────────────────────────────────────┐
│  EVERY WORKER NODE                              │                        │
│                                                 ▼                        │
│   ┌──────────────────────────────────────────────────────────────────┐   │
│   │  CSI NODE PLUGIN   (a DaemonSet, one pod per node)               │   │
│   │                                                                  │   │
│   │   ┌────────────────────────┐   ┌─────────────────────────┐       │   │
│   │   │ node-driver-registrar  │   │  VENDOR CSI PLUGIN      │       │   │
│   │   │ livenessprobe          │   │  (node service)         │       │   │
│   │   └────────────────────────┘   │                         │       │   │
│   │    registers the driver        │  NodeStageVolume        │       │   │
│   │    socket with the kubelet     │  NodePublishVolume      │       │   │
│   │                                │  NodeUnpublishVolume    │       │   │
│   │                                │  NodeExpandVolume       │       │   │
│   │                                └───────────▲─────────────┘       │   │
│   └────────────────────────────────────────────┼─────────────────────┘   │
│                                                │ gRPC over the socket    │
│                /var/lib/kubelet/plugins/<driver>/csi.sock                │
│   ┌────────────────────────────────────────────┼─────────────────────┐   │
│   │  kubelet                                   ┴                     │   │
│   │    VolumeManager reconciles desired vs actual mounts             │   │
│   │    then bind mounts the published path into the container        │   │
│   └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

### The Mount Sequence for One Pod

```
 1. Scheduler places the Pod on node-b
 2. AttachDetach controller creates a VolumeAttachment
      (skipped entirely when CSIDriver.attachRequired is false, as with NFS)
 3. CSI controller: ControllerPublishVolume        → volume visible to node-b
 4. CSI node plugin: NodeStageVolume               → mount once per node at
      /var/lib/kubelet/plugins/kubernetes.io/csi/<driver>/<hash>/globalmount
 5. CSI node plugin: NodePublishVolume             → bind mount per pod at
      /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pv>/mount
 6. kubelet applies fsGroup / SELinux label if required
 7. container runtime bind mounts that path to the container's mountPath
 8. container starts
```

Teardown runs the same list backwards: `NodeUnpublishVolume`, `NodeUnstageVolume`, `ControllerUnpublishVolume`, delete the VolumeAttachment.

Understanding steps 4 and 5 is what makes mount troubleshooting possible: **stage is per node, publish is per Pod**. Two Pods on one node share the staged mount and get separate bind mounts.

> 📖 **See also**: [kubelet.md](kubelet.md) for the VolumeManager, [container-runtime.md](container-runtime.md) for the final bind mount into the container.

---

## Node Level Storage Concerns

Persistent volumes are only half the story. Every node has a finite local disk, and Kubernetes manages it as a first class resource called **ephemeral storage**.

### What Counts as Ephemeral Storage

```
┌──────────────────────────────────────────────────────────────────────────┐
│                     NODE LOCAL DISK CONSUMPTION                          │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  COUNTED against a pod's ephemeral-storage limit:                        │
│    ✔ container writable layers                                           │
│    ✔ emptyDir volumes on disk (medium: "" )                              │
│    ✔ container logs written to the node (stdout/stderr)                  │
│                                                                          │
│  NOT counted against the pod:                                            │
│    ✘ emptyDir with medium: Memory   (counts against MEMORY instead)      │
│    ✘ read only image layers (shared between pods)                        │
│    ✘ any PersistentVolume, hostPath or network mount                     │
│    ✘ configMap, secret, downwardAPI, projected (tmpfs backed)            │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Requests and Limits

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bounded-scratch
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      resources:
        requests:
          ephemeral-storage: "1Gi"    # scheduler reserves this on the node
        limits:
          ephemeral-storage: "2Gi"    # pod is EVICTED if it exceeds this
      volumeMounts:
        - name: scratch
          mountPath: /scratch
  volumes:
    - name: scratch
      emptyDir:
        sizeLimit: 500Mi              # independent, per volume cap
```

Two independent guards:

- **`limits.ephemeral-storage`**: the kubelet periodically sums the Pod's writable layers, on-disk `emptyDir` volumes and logs. Exceeding the limit **evicts the Pod**. This is not an instantaneous kill like a memory limit; it is detected on a polling interval.
- **`emptyDir.sizeLimit`**: caps that one volume. Exceeding it also results in Pod eviction.

There is no cgroup enforcing a hard block on disk bytes for the writable layer in the general case, so treat these as eviction triggers, not as filesystem quotas.

> 📖 **Related**: [cgroups.md](cgroups.md) explains why CPU and memory limits are enforced instantly while storage limits are enforced by a monitoring loop.

### Image Filesystem and Container Filesystem

```
   Common single filesystem layout:
     /var/lib/containerd   ← images AND container writable layers
     /var/lib/kubelet      ← emptyDir, secrets, volume mounts
     both on the node root filesystem  →  "nodefs" and "imagefs" are the same disk

   Split layout (separate device for images):
     /var/lib/containerd on /dev/nvme1n1   →  "imagefs"
     /var/lib/kubelet    on /dev/nvme0n1   →  "nodefs"
     Independent eviction thresholds apply to each.
```

```bash
# What does the kubelet think it has?
kubectl get --raw "/api/v1/nodes/<node>/proxy/stats/summary" | jq '.node.fs, .node.runtime.imageFs'

# Node capacity and allocatable, including ephemeral-storage
kubectl describe node <node> | sed -n '/Capacity/,/System Info/p'
```

### Node Pressure Eviction on Disk

The kubelet watches eviction signals and, when a threshold is crossed, reclaims space and then evicts Pods.

| Signal | Meaning |
|--------|---------|
| `nodefs.available` | Free space on the filesystem holding `/var/lib/kubelet` |
| `nodefs.inodesFree` | Free inodes on that filesystem |
| `imagefs.available` | Free space on the filesystem holding images and writable layers |
| `imagefs.inodesFree` | Free inodes there |

Typical kubelet defaults for hard eviction on Linux are `nodefs.available<10%`, `imagefs.available<15%` and `nodefs.inodesFree<5%`. Verify on your own nodes rather than trusting memory:

```bash
# Effective kubelet configuration on a node, including eviction thresholds
kubectl get --raw "/api/v1/nodes/<node>/proxy/configz" | jq '.kubeletconfig.evictionHard'

# Look for the taint and the node condition
kubectl describe node <node> | grep -iE 'DiskPressure|Taints'
```

When `DiskPressure` becomes `True`:

1. The kubelet garbage collects unused images and dead containers first.
2. If that is not enough, it evicts Pods, ordered by whether they exceed their `ephemeral-storage` requests, then by QoS class and priority.
3. The node gets the `node.kubernetes.io/disk-pressure:NoSchedule` taint, so no new Pods land there.

```bash
# Find eviction events
kubectl get events -A --field-selector reason=Evicted
kubectl get events -A --field-selector reason=EvictionThresholdMet
```

### Inode Exhaustion: The Silent Killer

A node can have 40% free space and still be unusable because it ran out of inodes, usually from a workload creating millions of tiny files in an `emptyDir`.

```bash
df -h  /var/lib/kubelet
df -i  /var/lib/kubelet     # inodes, the number people forget to check
```

---

## End to End Worked Example on the NFS Lab

This walkthrough uses the repository's own NFS setup: an export named `/tux2lab-data` on the host `tux2lab-engine.<domain>`, served to the cluster by the `nfs.csi.k8s.io` CSI driver. See [install-csi-nfs.md](install-csi-nfs.md) for driver installation, and the existing manifests in `k8s-workshop/`.

### Step 0: Confirm the Driver Is Healthy

```bash
kubectl get csidrivers
# NAME             ATTACHREQUIRED   PODINFOONMOUNT   MODES        AGE
# nfs.csi.k8s.io   false            true             Persistent   3d

kubectl get pods -n kube-system -l app=csi-nfs-controller
kubectl get pods -n kube-system -l app=csi-nfs-node -o wide
```

Every worker node must run a `csi-nfs-node` Pod, and every node must have the NFS client packages installed, or mounts fail at `NodeStageVolume` with a "bad option" error.

```bash
# On each worker node
rpm -q nfs-utils   || apt list --installed 2>/dev/null | grep nfs-common
```

### Step 1: The StorageClass (Dynamic Path)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-tux2lab
provisioner: nfs.csi.k8s.io
parameters:
  server: tux2lab-engine.user.internal
  share: /tux2lab-data
  # Each PVC gets its own subdirectory under the export.
  subDir: ${pvc.metadata.namespace}-${pvc.metadata.name}-${pvc.metadata.uid}
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
  - hard
  - noatime
```

`Immediate` is correct here because an NFS export is reachable from every node; there is no topology constraint to wait for. `hard` is the right choice for data integrity: an I/O operation retries indefinitely rather than returning an error to the application.

### Step 2: A PVC and a Pod That Writes

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-writer
  namespace: storage-demo
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-tux2lab
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: demo-writer
  namespace: storage-demo
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          echo "written by $(hostname) at $(date -Iseconds)" >> /data/hello.txt
          sleep 3600
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: demo-writer
```

```bash
kubectl create namespace storage-demo
kubectl apply -f demo.yaml

kubectl get pvc -n storage-demo
# NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
# demo-writer   Bound    pvc-8f2c1d9e-...                           1Gi        RWX            nfs-tux2lab

kubectl get pv
# The PV name is auto generated as pvc-<pvc-uid> for dynamically provisioned volumes.
```

### Step 3: Verify from Inside the Pod

```bash
kubectl exec -n storage-demo demo-writer -- cat /data/hello.txt
# written by demo-writer at 2025-...

kubectl exec -n storage-demo demo-writer -- df -h /data
# Filesystem                                       Size  Used Avail Use% Mounted on
# tux2lab-engine.user.internal:/tux2lab-data/...   ...   ...   ...  ..% /data

kubectl exec -n storage-demo demo-writer -- mount | grep /data
# ...type nfs4 (rw,relatime,vers=4.1,hard,...)
```

Note that `df` reports the size of the whole export, not the 1Gi that was requested. NFS has no per directory quota by default, so the `capacity.storage` value is bookkeeping for the Kubernetes scheduler and quota system, not an enforced ceiling. This is a genuine operational gotcha with directory based NFS provisioning.

### Step 4: Verify from the NFS Server Side

```bash
# On tux2lab-engine
ls -la /tux2lab-data/
# drwxr-xr-x  storage-demo-demo-writer-8f2c1d9e-.../

cat /tux2lab-data/storage-demo-demo-writer-*/hello.txt
# written by demo-writer at 2025-...

# Confirm the export and who is allowed to mount it
exportfs -v
showmount -e localhost
```

Seeing the file on the server closes the loop across all seven layers: container write, bind mount, NFS client mount, network, export, on-disk file.

### Step 5: Prove Persistence Across Pod Deletion

```bash
kubectl delete pod demo-writer -n storage-demo
kubectl apply -f demo.yaml            # recreate the pod only, the PVC is untouched

kubectl exec -n storage-demo demo-writer -- cat /data/hello.txt
# two lines now: the old one and the new one
```

### Step 6: Verify the Node Level View

```bash
NODE=$(kubectl get pod demo-writer -n storage-demo -o jsonpath='{.spec.nodeName}')
echo "$NODE"

# On that node
mount | grep tux2lab
# the global (staged) mount, one per node:
#   .../plugins/kubernetes.io/csi/nfs.csi.k8s.io/<hash>/globalmount
# the per pod bind mount:
#   /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/pvc-.../mount

ls /var/lib/kubelet/pods/$(kubectl get pod demo-writer -n storage-demo \
   -o jsonpath='{.metadata.uid}')/volumes/
```

### Step 7: The Static Path, Matching the Repository Manifests

The repository already ships a static, read only example. `k8s-workshop/nfs-pv-web-share.yaml` defines the PV and `k8s-workshop/nfs-pvc-web-share.yaml` the matching claim, applied together by `k8s-workshop/apply-nfs-setup.sh`, which substitutes the NFS server hostname before applying.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv-web-share
spec:
  capacity:
    storage: 1Mi                       # bookkeeping only, NFS enforces nothing
  accessModes:
    - ReadOnlyMany                     # many nodes, read only: ideal for static content
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: nfs-web-share        # must be unique across the cluster
    volumeAttributes:
      server: tux2lab-engine.user.internal
      share: /tux2lab-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-pvc-web-share
spec:
  accessModes:
    - ReadOnlyMany
  resources:
    requests:
      storage: 1Mi
  volumeName: nfs-pv-web-share         # explicit binding to that exact PV
```

Two details in this pair are worth internalising:

1. **`volumeName` forces an exact binding.** No searching, no class matching. This is the cleanest way to wire a hand made PV to a specific claim, and it is why neither object needs a `storageClassName`.
2. **`ReadOnlyMany` is the right mode for shared static content.** Many web Pods across many nodes mount the same export, and nobody can accidentally write to it.

```bash
cd k8s-workshop
./apply-nfs-setup.sh user.internal

kubectl get pv nfs-pv-web-share
kubectl get pvc nfs-pvc-web-share
# both should read Bound
```

> 📖 **Deeper walkthrough**: [persistent-volumes.md](persistent-volumes.md) covers this exact pair in full, including what happens when the PVC is deleted and how to reuse a retained PV.

---

## Storage Object Quick Reference

| Object | apiVersion | Scope | Created by | Purpose |
|--------|-----------|-------|------------|---------|
| `PersistentVolume` | `v1` | Cluster | Admin or provisioner | A concrete piece of storage |
| `PersistentVolumeClaim` | `v1` | Namespace | Developer | A request for storage |
| `StorageClass` | `storage.k8s.io/v1` | Cluster | Admin | Template for dynamic provisioning |
| `CSIDriver` | `storage.k8s.io/v1` | Cluster | Driver install | Declares driver capabilities |
| `CSINode` | `storage.k8s.io/v1` | Cluster | node-driver-registrar | Which drivers exist on which node |
| `VolumeAttachment` | `storage.k8s.io/v1` | Cluster | AttachDetach controller | Tracks attach state per node |
| `CSIStorageCapacity` | `storage.k8s.io/v1` | Namespace | CSI provisioner | Capacity hints for the scheduler |
| `VolumeSnapshot` | `snapshot.storage.k8s.io/v1` | Namespace | Developer (CRD, needs the snapshot controller) | Point in time copy |
| `VolumeSnapshotClass` | `snapshot.storage.k8s.io/v1` | Cluster | Admin (CRD) | Snapshot template |

> Snapshot objects are **CRDs**, not core API. They only exist if the external snapshot controller and CRDs are installed. `kubectl get volumesnapshots` returning "the server doesn't have a resource type" means exactly that.

---

## Observability and Useful Commands

```bash
# ── Inventory ───────────────────────────────────────────────────────────
kubectl get storageclass
kubectl get pv -o wide
kubectl get pvc -A
kubectl get csidrivers
kubectl get csinodes -o wide
kubectl get volumeattachments

# ── Who is using what ───────────────────────────────────────────────────
# Every pod that references a PVC, cluster wide
kubectl get pods -A -o json | jq -r '
  .items[]
  | . as $p
  | ($p.spec.volumes // [])[]
  | select(.persistentVolumeClaim)
  | "\($p.metadata.namespace)/\($p.metadata.name)  ->  \(.persistentVolumeClaim.claimName)"'

# The PV behind a PVC, and the claim behind a PV
kubectl get pvc <pvc> -n <ns> -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl get pv  <pv>  -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'

# ── PV summary table ────────────────────────────────────────────────────
kubectl get pv -o custom-columns=\
'NAME:.metadata.name,CAP:.spec.capacity.storage,MODES:.spec.accessModes,'\
'RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase,'\
'CLAIM:.spec.claimRef.name,SC:.spec.storageClassName,DRIVER:.spec.csi.driver'

# ── Events, the first stop for any storage problem ──────────────────────
kubectl describe pvc <pvc> -n <ns> | sed -n '/Events/,$p'
kubectl describe pv  <pv>          | sed -n '/Events/,$p'
kubectl get events -n <ns> --sort-by=.lastTimestamp | grep -iE 'volume|mount|attach'

# ── Driver logs ─────────────────────────────────────────────────────────
kubectl logs -n kube-system -l app=csi-nfs-controller -c nfs --tail=100
kubectl logs -n kube-system -l app=csi-nfs-controller -c csi-provisioner --tail=100
kubectl logs -n kube-system -l app=csi-nfs-node -c nfs --tail=100

# ── Node side ───────────────────────────────────────────────────────────
journalctl -u kubelet -f | grep -iE 'volume|mount'
mount | grep kubelet
df -h /var/lib/kubelet ; df -i /var/lib/kubelet
```

---

## Troubleshooting

### Symptom 1: PVC Stuck in Pending

```bash
kubectl describe pvc <pvc> -n <ns> | sed -n '/Events/,$p'
kubectl get storageclass
```

| Message | Cause | Fix |
|---------|-------|-----|
| `no persistent volumes available for this claim and no storage class is set` | No matching PV and no class to provision from | Create a PV, or set `storageClassName`, or mark a default class |
| `storageclass.storage.k8s.io "x" not found` | Typo, or the class does not exist here | `kubectl get sc` and correct it |
| `waiting for first consumer to be created before binding` | `volumeBindingMode: WaitForFirstConsumer` | Normal. The real issue is why no Pod is scheduled |
| `failed to provision volume with StorageClass` | Provisioner error, credentials, quota, backend down | Read the `csi-provisioner` and driver logs |
| No events at all | No provisioner is watching that class | Confirm the driver Pods are running and the `provisioner` name matches the `CSIDriver` name exactly |

### Symptom 2: Pod Stuck in ContainerCreating

```bash
kubectl describe pod <pod> -n <ns> | sed -n '/Events/,$p'
```

| Message | Cause | Fix |
|---------|-------|-----|
| `MountVolume.SetUp failed ... access denied by server` | NFS export does not permit this node's IP | Fix `/etc/exports`, then `exportfs -ra` |
| `bad option; for several filesystems ... helper program` | NFS client packages missing on the node | Install `nfs-utils` or `nfs-common` on every worker |
| `no such host` | DNS cannot resolve the NFS server from the node | Fix node DNS or use an IP in `volumeAttributes.server` |
| `Multi-Attach error for volume` | An RWO volume is still attached to another node | See the failing node; usually a Pod stuck terminating |
| `timed out waiting for the condition` | Backend unreachable, firewall, driver crash | Check network path and driver logs |
| `configmap "x" not found` | The referenced ConfigMap or Secret does not exist yet | Create it, or mark the volume source `optional: true` |

### Symptom 3: Pods Evicted with "The node was low on resource: ephemeral-storage"

```bash
kubectl get events -A --field-selector reason=Evicted
kubectl describe node <node> | grep -iE 'DiskPressure|Taints'
```

On the node:

```bash
df -h /var/lib/kubelet /var/lib/containerd
df -i /var/lib/kubelet
du -xh --max-depth=1 /var/lib/kubelet/pods 2>/dev/null | sort -h | tail -20
crictl images
```

Fixes, in order of preference: set `ephemeral-storage` requests and limits on the offending workload, add `sizeLimit` to `emptyDir` volumes, ship logs off the node with proper rotation, move heavy scratch work onto a PVC, and only then grow the disk.

### Symptom 4: Data Written but Missing After a Restart

Diagnose in this order:

```bash
# 1. Is the pod actually writing to the mount point?
kubectl exec -n <ns> <pod> -- df -h
kubectl exec -n <ns> <pod> -- mount | grep -w /data

# 2. Which PVC and PV back it?
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.volumes}' | jq
kubectl get pvc <pvc> -n <ns> -o jsonpath='{.spec.volumeName}{"\n"}'
```

Usual causes: the application writes to a path that is not the mount point; an `emptyDir` was used where a PVC was intended; a second `volumeMount` shadows the first; or the PVC was deleted and dynamically recreated empty.

### Symptom 5: Everything Is Read Only Unexpectedly

```bash
kubectl get pv <pv> -o jsonpath='{.spec.accessModes}{"\n"}'
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].volumeMounts}' | jq
kubectl exec -n <ns> <pod> -- touch /data/probe
```

Check, in order: `readOnly: true` on the `volumeMount`, `readOnly: true` on the volume source, `accessModes: [ReadOnlyMany]` on the PV, `ro` in `mountOptions`, `readOnlyRootFilesystem` in the container `securityContext`, and finally the export options on the NFS server (`ro` in `/etc/exports`).

### Symptom 6: Permission Denied Inside the Container

```bash
kubectl exec -n <ns> <pod> -- id
kubectl exec -n <ns> <pod> -- ls -ln /data
```

The container's UID and GID must match the ownership on the backend. For NFS, `root_squash` maps root to `nobody`, which defeats `fsGroup` for a root process. Options: set `securityContext.fsGroup` and confirm the CSIDriver `fsGroupPolicy` allows it, set `runAsUser` and `runAsGroup` to match the export, or set ownership on the server side. Do not reach for `no_root_squash` in anything resembling production.

### Symptom 7: `kubectl get volumesnapshots` Errors

```bash
kubectl get crd | grep snapshot
```

Snapshots are CRDs plus an external controller. If the CRDs are absent, install the `external-snapshotter` CRDs and controller before the driver's snapshot sidecar can do anything.

---

## Exam and Interview Traps

1. **`ReadWriteOnce` means one node, not one Pod.** Two Pods on the same node can both mount it read/write. `ReadWriteOncePod` is the mode that means one Pod.
2. **A volume survives a container restart but not the Pod**, unless the backing store is external. `emptyDir` data is intact across crash loops.
3. **`emptyDir` with `medium: Memory` counts against the Pod's memory limit**, not against `ephemeral-storage`. Filling it can trigger an OOM kill.
4. **Omitting `storageClassName` is not the same as `storageClassName: ""`.** Omitted means "use the default class"; empty string means "no class at all".
5. **PVC to PV binding is one to one and exclusive.** Unused capacity in a bound PV is wasted; a second claim cannot use it.
6. **A 10Gi PVC can bind to a 100Gi PV.** Capacity matching is "at least", not "equal". The claim then owns all 100Gi.
7. **PVC and PV are matched on class, access modes, capacity, volume mode and selector.** All must be satisfied.
8. **`reclaimPolicy` lives on the PV**, and is inherited from the StorageClass at provisioning time. Changing the class later does not change existing PVs.
9. **The default reclaim policy for a dynamically provisioned PV is `Delete`.** Delete the PVC, and the real data disappears.
10. **`Recycle` is deprecated.** The modern answers are `Retain` and `Delete`.
11. **StorageClass fields are effectively immutable** except `allowVolumeExpansion`. Make a new class instead of editing.
12. **Only one StorageClass should be marked default.** Two defaults is an unsupported state.
13. **Volume expansion requires `allowVolumeExpansion: true` on the class**, and you edit the **PVC**, never the PV. Shrinking is not supported.
14. **`WaitForFirstConsumer` exists to solve topology**, so a volume is not created in a zone where the Pod cannot run.
15. **In-tree cloud volume plugins were migrated to CSI and removed.** `nfs`, `iscsi`, `hostPath` and `local` are still in-tree types.
16. **A CSI driver is two components**: a controller Deployment for cluster wide calls and a node DaemonSet for mount calls. Missing the DaemonSet on a node means Pods there never mount.
17. **`provisioner` in a StorageClass must exactly equal the `CSIDriver` object's `metadata.name`.**
18. **NFS style drivers set `attachRequired: false`**, so no `VolumeAttachment` objects appear and multi-attach errors do not occur.
19. **Kubernetes has no object storage primitive.** Buckets are an application concern with a Secret.
20. **`capacity.storage` on a directory based NFS PV is not enforced.** It is scheduler and quota bookkeeping only.
21. **`ephemeral-storage` limits cause eviction, not a write error.** Enforcement is by a kubelet polling loop.
22. **`DiskPressure` triggers image garbage collection before Pod eviction**, and taints the node `NoSchedule`.
23. **Deleting a PVC that a running Pod uses does not delete it immediately.** The `kubernetes.io/pvc-protection` finalizer holds it in `Terminating`.
24. **PVs are cluster scoped, PVCs are namespaced.** A PVC can only be used by Pods in its own namespace.
25. **VolumeSnapshot is a CRD**, not part of the core API.

---

## Related Topics

- [Volumes](volumes.md)
- [Persistent Volumes and Claims](persistent-volumes.md)
- [Containers](containers.md)
- [Docker](docker.md)
- [Container Runtime](container-runtime.md)
- [Linux Namespaces](linux-namespaces.md)
- [Cgroups](cgroups.md)
- [Pods](pods.md)
- [Pod Lifecycle](pod-lifecycle.md)
- [StatefulSets](statefulsets.md)
- [ConfigMaps](configmaps.md)
- [Secrets](secrets.md)
- [Downward API](downward-api.md)
- [kubelet](kubelet.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-scheduler](kube-scheduler.md)
- [Installing the NFS CSI Driver](install-csi-nfs.md)
- [Installing the SMB CSI Driver](install-csi-smb.md)
- [Kubernetes API](k8s-api.md)

---

## Key Takeaways

1. The container writable layer is ephemeral and dies with the container. Every piece of data you care about belongs on a volume.
2. The storage stack has seven layers: Pod, `volumeMounts`, `volumes`, PVC, PV, StorageClass, CSI driver, backend. Ephemeral volume types stop at layer 2; only persistent ones travel the whole way down.
3. A volume outlives a **container** restart. It outlives the **Pod** only when the backing store lives outside the node.
4. The PVC/PV split is a separation of concerns: developers declare *what* they need in a namespaced object, administrators define *how* it is delivered in cluster scoped objects. That is what makes application manifests portable.
5. Kubernetes has first class support for block and file storage. Object storage is an application concern, delivered with a Secret and an endpoint.
6. Access modes describe node and Pod concurrency: RWO is one **node**, RWOP is one **Pod**, RWX needs a genuinely shared filesystem, ROX is ideal for shared static content. Kubernetes does not validate that the backend can honour the mode you declare.
7. Static provisioning means an admin writes the PV by hand; dynamic provisioning means a StorageClass and a CSI provisioner create it on demand. Binding is exclusive, one to one, and matches on class, access modes, capacity, volume mode and selector.
8. A StorageClass is a template, not a quota. Its fields are effectively immutable apart from `allowVolumeExpansion`, and exactly one class should be marked default.
9. CSI replaced in-tree plugins and FlexVolume. A driver is a controller Deployment plus a node DaemonSet, described to the cluster by a `CSIDriver` object whose name is the provisioner string.
10. Node local disk is a scheduled resource. Set `ephemeral-storage` requests and limits, cap `emptyDir` with `sizeLimit`, and remember that RAM backed `emptyDir` consumes memory instead.
11. Disk pressure eviction is real and is driven by `nodefs` and `imagefs` thresholds. Check free inodes as well as free bytes.
12. On the lab's NFS setup, `nfs.csi.k8s.io` with `attachRequired: false` gives RWX and ROX volumes with no attach step, which is why static PVs such as `nfs-pv-web-share` bind and mount so simply.
13. Directory based NFS provisioning does not enforce `capacity.storage`. Treat the number as bookkeeping and enforce real limits on the server with filesystem quotas.
14. Troubleshooting order is always the same: PVC events, PV status, Pod events, CSI controller logs, CSI node logs, kubelet journal, then the backend itself.

---

## References

- [Storage concepts overview](https://kubernetes.io/docs/concepts/storage/)
- [Volumes](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Dynamic Volume Provisioning](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)
- [Ephemeral Volumes](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/)
- [Storage Capacity](https://kubernetes.io/docs/concepts/storage/storage-capacity/)
- [Node specific Volume Limits](https://kubernetes.io/docs/concepts/storage/storage-limits/)
- [Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
- [Volume Snapshot Classes](https://kubernetes.io/docs/concepts/storage/volume-snapshot-classes/)
- [CSI Volume Cloning](https://kubernetes.io/docs/concepts/storage/volume-pvc-datasource/)
- [Kubernetes CSI Developer Documentation](https://kubernetes-csi.github.io/docs/)
- [Container Storage Interface (CSI) for Kubernetes GA blog](https://kubernetes.io/blog/2019/01/15/container-storage-interface-ga/)
- [Managing Resources for Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Local ephemeral storage](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#local-ephemeral-storage)
- [Node pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [Resource Quotas for storage](https://kubernetes.io/docs/concepts/policy/resource-quotas/#storage-resource-quota)
- [Configure a Pod to Use a PersistentVolume for Storage](https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/)
- [PersistentVolume API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/persistent-volume-v1/)
- [StorageClass API reference (storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/storage-class-v1/)
- [CSIDriver API reference (storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/csi-driver-v1/)
