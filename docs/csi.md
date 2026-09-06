# 🔌 Container Storage Interface (CSI)

A complete guide to CSI: the vendor neutral gRPC specification that lets a storage system plug into Kubernetes without a line of code inside Kubernetes, and the sidecar architecture that turns that specification into running Pods.

## 📋 Table of Contents
- [What CSI Is](#what-csi-is)
- [Why CSI Replaced In-Tree Volume Plugins](#why-csi-replaced-in-tree-volume-plugins)
- [CSI Migration of Legacy In-Tree Plugins](#csi-migration-of-legacy-in-tree-plugins)
- [The Specification: Three gRPC Services](#the-specification-three-grpc-services)
- [Identity Service RPCs](#identity-service-rpcs)
- [Controller Service RPCs](#controller-service-rpcs)
- [Node Service RPCs](#node-service-rpcs)
- [Staging vs Publishing](#staging-vs-publishing)
- [The Sidecar Container Architecture](#the-sidecar-container-architecture)
- [The Unix Socket and Plugin Registration](#the-unix-socket-and-plugin-registration)
- [The Kubernetes API Objects](#the-kubernetes-api-objects)
- [The Full Architecture Diagram](#the-full-architecture-diagram)
- [Deploying a CSI Driver in Practice](#deploying-a-csi-driver-in-practice)
- [Inline CSI Ephemeral Volumes](#inline-csi-ephemeral-volumes)
- [Storage Capacity Tracking](#storage-capacity-tracking)
- [Writing a CSI Driver Conceptually](#writing-a-csi-driver-conceptually)
- [Debugging CSI](#debugging-csi)
- [CSI vs In-Tree vs FlexVolume](#csi-vs-in-tree-vs-flexvolume)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What CSI Is

**CSI (Container Storage Interface)** is a specification defining how a container orchestrator asks a storage system to create, attach, mount, resize, snapshot and delete volumes. It is deliberately orchestrator agnostic: the same specification was designed to serve Kubernetes, Mesos, Cloud Foundry and Nomad alike.

CSI is the storage counterpart of [CNI](cni.md), and the parallel is exact in intent and different in mechanism:

| | CNI (networking) | CSI (storage) |
|---|---|---|
| Artifact | Executable binary on the host | Long running gRPC server in a container |
| Transport | exec plus JSON on stdin/stdout | gRPC over a Unix domain socket |
| Invocation | `ADD` / `DEL` / `CHECK` commands | Named RPCs across three services |
| Configuration | JSON files in `/etc/cni/net.d/` | Kubernetes API objects (`CSIDriver`, `StorageClass`) |
| Lifetime | One shot per Pod sandbox | Persistent, watches the API, reconciles |
| Scope | Node local only | Cluster (controller) plus node |

The difference in shape follows from the difference in the problem. Wiring a network namespace takes milliseconds and is purely local. Creating a volume can involve a cloud API, take minutes, must survive a restart mid-operation, and must be coordinated cluster wide so two nodes never mount one block device read/write.

### CSI Is Two Things

```
┌───────────────────────────────────────────────────────────────────────────┐
│  1. THE SPECIFICATION                                                      │
│     A protobuf/gRPC contract defining three services (Identity, Controller,│
│     Node), their RPCs, message types, capabilities, and the idempotency    │
│     and error-code rules a driver must obey. It mentions Kubernetes        │
│     nowhere.                                                               │
│                                                                            │
│  2. THE KUBERNETES IMPLEMENTATION                                          │
│     "Sidecar" controllers maintained under github.com/kubernetes-csi that  │
│     translate Kubernetes objects (PVC, PV, VolumeAttachment, VolumeSnapshot)│
│     into those RPCs, plus in-kubelet code that calls the Node service       │
│     directly. This is what makes a CSI driver work in a cluster.           │
└───────────────────────────────────────────────────────────────────────────┘
```

A driver author implements (1). An operator deploys (1) alongside (2). Confusing the two is why people look for `CreateVolume` in `kubectl` and cannot find it: the RPC lives on a socket inside a Pod, not in the Kubernetes API.

---

## Why CSI Replaced In-Tree Volume Plugins

Before CSI, support for a storage system was **compiled into Kubernetes itself**. Code for AWS EBS, GCE PD, Azure Disk, Cinder, vSphere, Ceph RBD, GlusterFS and a dozen others lived in `kubernetes/kubernetes`, in the same binary as kube-controller-manager and kubelet.

```
┌────────────────────────────────────────────────────────────────────────────┐
│                   IN-TREE (the old world)                                   │
│   kubernetes/kubernetes/pkg/volume/                                         │
│       awsElasticBlockStore/  gcePersistentDisk/  azureDisk/  cinder/  ...   │
│                                                                             │
│   Consequences:                                                             │
│     • A driver bug = a Kubernetes patch release.                            │
│     • A new feature = wait for the next Kubernetes minor.                   │
│     • A driver panic = a kubelet or controller-manager crash.               │
│     • Vendor credentials and libraries linked into core binaries.           │
│     • Kubernetes maintainers on the hook for hardware they cannot test.     │
└────────────────────────────────────────────────────────────────────────────┘
```

### The Four Problems CSI Solves

**1. Lifecycle decoupling (out of tree).** A CSI driver ships on its own schedule, in its own repository, with its own version. A fix for a Ceph edge case does not wait for the next Kubernetes minor and does not require anyone to upgrade a cluster.

**2. No kubelet recompiles or restarts.** Adding storage support becomes `kubectl apply`: a DaemonSet and a Deployment appear, the driver registers itself with the kubelet over a socket, and volumes work. Removing it is `kubectl delete`. No binary is replaced and no node reboots.

**3. Vendor independence and blast radius.** The driver runs in its own Pod with its own limits, service account and RBAC. A driver that panics restarts a container instead of taking down the kubelet, and a proprietary library is linked into the vendor's image rather than a core Kubernetes binary.

**4. One integration, many orchestrators.** A vendor writes the gRPC server once, and the same image serves any CSI compliant orchestrator, because the specification encodes no Kubernetes concepts.

```
┌────────────────────────────────────────────────────────────────────────────┐
│                     OUT-OF-TREE (CSI, the current world)                    │
│   kubernetes/kubernetes                    vendor/driver repo               │
│   ┌────────────────────────┐               ┌──────────────────────────┐    │
│   │ kubelet                │               │ csi-driver-nfs           │    │
│   │  • calls Node service  │◄── gRPC ─────►│  • Identity service      │    │
│   │ kube-controller-manager│    over a     │  • Controller service    │    │
│   │  • creates PV/VA objs  │    unix       │  • Node service          │    │
│   └────────────────────────┘    socket     └──────────────────────────┘    │
│              ▲ watches/creates API objects                                  │
│   ┌──────────┴─────────────┐                                                │
│   │ kubernetes-csi sidecars│  external-provisioner, external-attacher,      │
│   │ (generic, shared by    │  external-resizer, external-snapshotter,       │
│   │  every driver)         │  node-driver-registrar, livenessprobe          │
│   └────────────────────────┘                                                │
└────────────────────────────────────────────────────────────────────────────┘
```

The sidecar model is the key architectural insight: **the hard, generic, Kubernetes specific work (watching PVCs, leader election, retry with backoff, status updates, finalizers) is written once in shared containers, and the driver implements only the storage specific parts.**

---

## CSI Migration of Legacy In-Tree Plugins

Kubernetes could not simply delete the in-tree plugins: millions of PV objects in the world use in-tree field names such as `spec.awsElasticBlockStore`. The answer is **CSI migration**, a translation shim.

```
┌────────────────────────────────────────────────────────────────────────────┐
│   A user writes (or already has):        Kubernetes internally treats it as:│
│                                                                             │
│     spec:                                  spec:                            │
│       awsElasticBlockStore:                  csi:                           │
│         volumeID: vol-0abc123                  driver: ebs.csi.aws.com      │
│         fsType: ext4                           volumeHandle: vol-0abc123    │
│                                                                             │
│   and all operations go to the real CSI driver. The user's YAML never       │
│   changes, and the API object never changes.                                │
└────────────────────────────────────────────────────────────────────────────┘
```

- **Existing manifests keep working.** The in-tree field names remain valid API, just routed elsewhere.
- **The corresponding CSI driver must be installed.** Migration translates the request; it does not implement the storage.
- **In-tree plugin code has been progressively removed** as each migration reached general availability, so whether a given plugin is still present depends on your release. Check the release notes rather than assuming.
- **Parameters may differ** between an in-tree plugin and its CSI replacement.

Practical advice: **for anything new, write `provisioner: <csi-driver-name>` in the StorageClass and never use an in-tree volume type.**

---

## The Specification: Three gRPC Services

```
┌────────────────────────────────────────────────────────────────────────────┐
│   ┌──────────────────┐  Mandatory in EVERY driver process.                  │
│   │ Identity Service │  "Who are you, what can you do, are you alive?"      │
│   └──────────────────┘  Called by sidecars at startup and by livenessprobe. │
│                                                                             │
│   ┌──────────────────┐  Runs where it can reach the storage control plane.  │
│   │ Controller       │  Usually one leader-elected Deployment, cluster wide. │
│   │ Service          │  "Create, delete, attach, expand, snapshot."          │
│   └──────────────────┘  Never needs to be on the node using the volume.     │
│                                                                             │
│   ┌──────────────────┐  Runs on EVERY node, as a DaemonSet.                 │
│   │ Node Service     │  "Stage this volume on this node, publish it into    │
│   │                  │   this Pod's directory, report my topology."          │
│   └──────────────────┘  Needs host mount access and privileges.             │
└────────────────────────────────────────────────────────────────────────────┘
```

Most drivers ship **one binary** serving different subsets depending on a `--mode` flag: the same image runs as the controller Pod and as the node DaemonSet.

### Capabilities Are Declared, Not Assumed

A driver advertises what it supports and the sidecars adapt:

- `GetPluginCapabilities` says whether there is a Controller service at all, and whether topology matters (`VOLUME_ACCESSIBILITY_CONSTRAINTS`).
- `ControllerGetCapabilities` says which Controller RPCs are real: `CREATE_DELETE_VOLUME`, `PUBLISH_UNPUBLISH_VOLUME`, `EXPAND_VOLUME`, `CREATE_DELETE_SNAPSHOT`, `LIST_VOLUMES`, `CLONE_VOLUME`, `GET_CAPACITY` and others.
- `NodeGetCapabilities` says whether the node needs `STAGE_UNSTAGE_VOLUME`, can report `GET_VOLUME_STATS`, or supports `EXPAND_VOLUME` node side.

This is why an NFS driver and a SAN driver are both "a CSI driver" while doing wildly different amounts of work: the NFS driver reports no `PUBLISH_UNPUBLISH_VOLUME` capability and therefore never sees an attach request.

---

## Identity Service RPCs

### GetPluginInfo

Returns the driver's **name** and vendor version. The name is the identity that ties everything together:

```
GetPluginInfo  ──►  name: "nfs.csi.k8s.io"
        ┌───────────────┼────────────────────────┐
        ▼               ▼                        ▼
  CSIDriver object   StorageClass          pv.spec.csi.driver
  metadata.name      provisioner:          driver: nfs.csi.k8s.io
```

All four must agree exactly. A mismatch produces **silence**, not an error: the provisioner ignores claims it does not own, and the kubelet reports `driver name ... not found in the list of registered CSI drivers`. The name must be a reverse-DNS style domain of at most 63 characters, hence `ebs.csi.aws.com`, `nfs.csi.k8s.io`, `smb.csi.k8s.io`.

### GetPluginCapabilities

Declares plugin level capabilities:

| Capability | Meaning |
|-----------|---------|
| `CONTROLLER_SERVICE` | This driver has a Controller service; provisioning and attaching are possible |
| `VOLUME_ACCESSIBILITY_CONSTRAINTS` | Volumes are not equally reachable from all nodes; topology matters |

A driver omitting `CONTROLLER_SERVICE` is node only, and no external-provisioner is deployed for it.

### Probe

A liveness and readiness question: "are you initialised and able to serve?" A driver may answer "not ready yet" without being unhealthy. The **livenessprobe** sidecar calls `Probe` and exposes the result over HTTP so the kubelet's ordinary `livenessProbe` can restart the container.

---

## Controller Service RPCs

Called by sidecars, never by the kubelet.

### CreateVolume

Provisions a new volume. The request carries the name, capacity range, volume capabilities (access mode plus filesystem or block), StorageClass parameters, optional secrets, optional topology requirements, and optionally a **content source** (a snapshot or another volume) for restore and clone.

The response returns a `volume_id`, which becomes `pv.spec.csi.volumeHandle`, plus the actual capacity, optional `volume_context` (which becomes `pv.spec.csi.volumeAttributes`) and `accessible_topology`.

**Idempotency is mandatory.** Calling it twice with the same name and compatible parameters must return the existing volume. Sidecars retry on any transport error, including errors that occurred *after* the volume was created, so a non idempotent driver leaks storage nobody will ever reclaim.

### DeleteVolume

Destroys the volume identified by `volume_id`. Also idempotent: deleting an already deleted volume must succeed, because the sidecar cannot tell a lost response from a failed call.

### ControllerPublishVolume / ControllerUnpublishVolume

"Attach" and "detach". Makes a volume available **to a node** without mounting it: attaching a cloud disk to an instance, mapping a LUN to an initiator, adding an export rule for a node's IP. The request names a `node_id`, the value that node reported from `NodeGetInfo`.

The response may include `publish_context`, an opaque map forwarded to `NodeStageVolume`, which is how a driver tells its own node component "the device you want is at this bus address".

Drivers with nothing to attach (NFS, SMB, most file protocols) omit the `PUBLISH_UNPUBLISH_VOLUME` capability, and Kubernetes then skips this entirely and creates no `VolumeAttachment` objects.

### ValidateVolumeCapabilities

"Given this existing volume, can it satisfy this set of capabilities?" Used mainly for **pre-provisioned volumes**: before binding a hand written PV, Kubernetes can ask whether that volume really supports, say, `MULTI_NODE_MULTI_WRITER`.

### ControllerExpandVolume

Grows the backing volume. The response includes the new capacity and a boolean `node_expansion_required`: for a block device with a filesystem on it, growing the device is not enough, so the driver says "now call `NodeExpandVolume`". For a file share where "size" is a quota, the flag is false. Called by the **external-resizer** sidecar.

### CreateSnapshot / DeleteSnapshot

Point in time copies. `CreateSnapshot` takes a source `volume_id`, a name and optional parameters and secrets from the VolumeSnapshotClass, returning a `snapshot_id`, `size_bytes`, `creation_time` and a `ready_to_use` flag. Backends that snapshot asynchronously return `ready_to_use: false`, and the sidecar polls with `ListSnapshots` until it flips. Called by the **external-snapshotter** sidecar; see [volume-snapshots.md](volume-snapshots.md).

### The Rest

| RPC | Purpose |
|-----|---------|
| `ListVolumes` | Enumerate volumes with pagination; reconciliation and health monitoring |
| `ListSnapshots` | Enumerate snapshots, and poll readiness of an asynchronous one |
| `GetCapacity` | Report available capacity, optionally per topology; feeds capacity tracking |
| `ControllerGetCapabilities` | Declare which of the above are actually implemented |
| `ControllerGetVolume` | Fetch one volume's condition, for volume health monitoring |

---

## Node Service RPCs

These run on the node that will use the volume, in a privileged DaemonSet Pod. **The kubelet calls most of these directly**, with no sidecar in between.

### NodeGetInfo

Called once, at registration. Returns:

- `node_id`: the driver's own identifier for this node, which may look nothing like the Kubernetes node name (an instance ID, a WWN, an initiator name). Every later `ControllerPublishVolume` uses this value.
- `max_volumes_per_node`: an attach limit the scheduler will respect.
- `accessible_topology`: the topology segments this node belongs to.

All three land in the node's `CSINode` object.

### NodeGetCapabilities

Declares `STAGE_UNSTAGE_VOLUME`, `GET_VOLUME_STATS`, `EXPAND_VOLUME`, `VOLUME_CONDITION` and similar. If `STAGE_UNSTAGE_VOLUME` is absent, the kubelet skips staging entirely and calls only `NodePublishVolume`.

### NodeStageVolume / NodeUnstageVolume

**Once per volume per node.** Formats the device if necessary and mounts it at a global staging path. This is where a filesystem check, a `mkfs`, an iSCSI login, an NFS mount or an SMB authentication happens. `NodeUnstageVolume` is called when the **last** Pod on the node stops using the volume, not when each Pod stops.

### NodePublishVolume / NodeUnpublishVolume

**Once per Pod.** Makes the staged volume visible at the Pod's own target path, almost always as a bind mount from the staging path. This is where per-Pod `readOnly` is applied.

### NodeExpandVolume

Grows the **filesystem** inside an already grown device (`resize2fs`, `xfs_growfs`). Called by the kubelet after `ControllerExpandVolume` returned `node_expansion_required: true`.

### NodeGetVolumeStats

Returns used, available and total bytes and inodes for a published volume. This is the source of the `kubelet_volume_stats_*` metrics; a driver that skips it produces a cluster where nobody can alert on a full PVC.

### The Full Node Sequence

```
   volume attached to node (or nothing to attach)
              ▼
   NodeStageVolume ──────────► ONCE PER NODE
   mount /dev/xyz  →  .../globalmount
     ┌────────┴────────┬─────────────────┐
     ▼                 ▼                 ▼
 NodePublish       NodePublish       NodePublish  ── ONCE PER POD
 pod-A/mount       pod-B/mount       pod-C/mount     (bind mounts)
     ▼                 ▼                 ▼
 NodeUnpublish     NodeUnpublish     NodeUnpublish
     └────────┬────────┴─────────────────┘
              ▼
   NodeUnstageVolume ────────► after the LAST pod
              ▼
   ControllerUnpublishVolume (detach), if applicable
```

---

## Staging vs Publishing

The most misunderstood part of CSI, and the explanation for the directory layout under `/var/lib/kubelet`.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  NodeStageVolume            ONE global mount, per volume, per NODE           │
│  ───────────────            Expensive work: mkfs, fsck, iSCSI login,         │
│                             NFS/SMB mount, decryption, multipath setup.      │
│                             /var/lib/kubelet/plugins/kubernetes.io/csi/      │
│                                 .../globalmount                              │
│                                                                              │
│  NodePublishVolume          ONE bind mount, per volume, per POD              │
│  ─────────────────          Cheap work: mount --bind, apply per-Pod          │
│                             readOnly, set permissions.                       │
│                             /var/lib/kubelet/pods/<pod-uid>/volumes/         │
│                                 kubernetes.io~csi/<pv-name>/mount            │
└─────────────────────────────────────────────────────────────────────────────┘
```

Consider three Pods on one node sharing one ReadWriteMany volume. Without staging, each Pod start would perform a full NFS mount and each stop a full unmount, tripling the load on the server and creating races where one Pod's teardown breaks another's mount. With staging, the expensive mount happens **once**, each Pod gets a bind mount costing microseconds, and per-Pod options are applied without touching the shared mount.

### The Filesystem Path Diagram

```
/var/lib/kubelet/
│
├── plugins_registry/                       ◄── kubelet WATCHES this directory
│   └── nfs.csi.k8s.io-reg.sock                 node-driver-registrar creates
│                                               this socket to announce the driver
├── plugins/
│   ├── csi-nfs/
│   │   └── csi.sock                        ◄── the driver's OWN socket
│   │
│   └── kubernetes.io/csi/                  ◄── STAGING area, managed by kubelet
│       └── .../globalmount                     one global mount per volume
│           │
│           │  NOTE: the exact subdirectory layout under
│           │  plugins/kubernetes.io/csi/ has changed between Kubernetes
│           │  releases (earlier layouts keyed on the PV name, later ones on
│           │  a hash of the volume handle). Discover it with `findmnt`
│           │  rather than hardcoding it in a script.
│           │
│           │  bind mount
│           ▼
└── pods/
    └── 3f8b2a1c-9d4e-5f6a-7b8c-9d0e1f2a3b4c/     ◄── POD UID
        └── volumes/kubernetes.io~csi/
            └── pvc-9f2e5c31-8b4a-4d21-.../       ◄── PV NAME
                ├── mount                          ◄── PUBLISH target: what the
                │                                      container actually sees
                └── vol_data.json                  ◄── kubelet's record of the
                                                       driver, handle and
                                                       attributes for this mount
```

`vol_data.json` matters during recovery: it is how the kubelet remembers, across its own restart, which driver owns a mount it finds on disk.

```bash
# Every CSI mount on this node, staged and published
findmnt -R -o TARGET,SOURCE,FSTYPE | grep -E 'kubernetes.io~csi|globalmount'

pod_uid=$(kubectl get pod web-0 -n web -o jsonpath='{.metadata.uid}')
cat /var/lib/kubelet/pods/${pod_uid}/volumes/kubernetes.io~csi/*/vol_data.json | jq
```

If `NodeGetCapabilities` omits `STAGE_UNSTAGE_VOLUME`, the kubelet calls only `NodePublishVolume` and there is no `globalmount`. That is legitimate for drivers where each Pod mount is genuinely independent and cheap.

---

## The Sidecar Container Architecture

The sidecars are generic controllers maintained by the `kubernetes-csi` project. They contain **no storage logic at all**: each watches a specific Kubernetes object and turns changes into a specific CSI RPC on the driver's socket.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SIDECAR                    WATCHES                    CALLS                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  external-provisioner       PVC (pending, matching     CreateVolume          │
│                             driver), PV (released)     DeleteVolume          │
│  external-attacher          VolumeAttachment           ControllerPublishVolume│
│                                                        ControllerUnpublish   │
│  external-resizer           PVC (requests.storage up)  ControllerExpandVolume │
│  external-snapshotter       VolumeSnapshotContent      CreateSnapshot        │
│                                                        DeleteSnapshot        │
│  node-driver-registrar      (nothing; it registers)    GetPluginInfo         │
│  livenessprobe              (nothing; serves HTTP)     Probe                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

### external-provisioner

Runs in the **controller** Pod. Watches PVCs whose `volume.kubernetes.io/storage-provisioner` annotation matches its own driver name (learned by calling `GetPluginInfo`). For each pending claim it builds a `CreateVolume` request from the StorageClass parameters, requested size and access modes, calls the driver, then **creates the PersistentVolume object** with `spec.csi.driver`, `volumeHandle` and `volumeAttributes` from the response. When a `Delete`-policy PV is released it calls `DeleteVolume` and removes the PV.

It also resolves the reserved `csi.storage.k8s.io/*-secret-name` parameters into real Secret contents, honours `WaitForFirstConsumer` by waiting for `volume.kubernetes.io/selected-node` and converting that node's topology into `accessibility_requirements`, turns a PVC `dataSource` into a `volume_content_source` for restore and clone, and publishes `CSIStorageCapacity` objects when capacity tracking is enabled.

### external-attacher

Runs in the **controller** Pod. Watches `VolumeAttachment` objects, created by the built-in attach/detach controller when a Pod needing a volume is scheduled:

- created ► call `ControllerPublishVolume` ► set `status.attached: true` and copy `publish_context` into `status.attachmentMetadata`.
- deleted ► call `ControllerUnpublishVolume` ► remove the finalizer.

Deployed only for drivers whose `CSIDriver` sets `attachRequired: true`.

### external-resizer

Runs in the **controller** Pod. Watches PVCs for an increase in `spec.resources.requests.storage`, calls `ControllerExpandVolume`, updates `pvc.status.capacity`, and sets `FileSystemResizePending` when the driver reports `node_expansion_required`. The node side `NodeExpandVolume` is invoked by the kubelet, not by this sidecar.

### external-snapshotter

Runs in the **controller** Pod, alongside a separate cluster wide **snapshot-controller** Deployment. The division of labour is precise and often misunderstood:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  snapshot-controller (ONE per cluster, driver agnostic)                      │
│    watches VolumeSnapshot  ──creates──►  VolumeSnapshotContent               │
│    handles binding, finalizers, status propagation                           │
│                                                                              │
│  external-snapshotter sidecar (ONE per driver, in the driver's controller Pod)│
│    watches VolumeSnapshotContent  ──calls──►  CreateSnapshot / DeleteSnapshot │
└─────────────────────────────────────────────────────────────────────────────┘
```

Deploying the sidecar without the cluster wide controller is a very common mistake: snapshots become objects that nothing ever acts on.

### node-driver-registrar

Runs in the **node** DaemonSet. It proxies no volume operation; its whole job is introduction:

1. Call `GetPluginInfo` on the driver to learn its name.
2. Create a registration socket at `/var/lib/kubelet/plugins_registry/<driver-name>-reg.sock`.
3. Serve the kubelet's plugin registration API there, reporting the driver's name, supported CSI versions and the path of the driver's real socket.
4. The kubelet then calls `NodeGetInfo` on the driver and writes the result into `CSINode`.

A crash-looping registrar means the driver runs perfectly and is completely invisible: every Pod on that node fails with `driver name ... not found in the list of registered CSI drivers`.

### livenessprobe

Runs in **both** the controller Pod and the node DaemonSet. Calls `Probe` and exposes an HTTP `/healthz` that the Pod's normal `livenessProbe` hits. It exists because Kubernetes cannot health check a Unix socket directly.

An optional **external-health-monitor-controller** watches for abnormal volume conditions via `ListVolumes` or `ControllerGetVolume` on drivers that report the volume condition capability, and reports events on the PVC. Most drivers do not deploy it.

### Where Each Sidecar Runs

```
┌────────────────────────────────────────────────────────────────────────────┐
│  CONTROLLER Pod (Deployment or StatefulSet, leader elected, scheduled       │
│                  anywhere, often on control plane nodes with tolerations)   │
│    csi-provisioner  csi-attacher  csi-resizer  csi-snapshotter              │
│    livenessprobe                                                            │
│    <driver> (--mode=controller)                                             │
│    emptyDir at /csi holds csi.sock, shared by all containers                │
├────────────────────────────────────────────────────────────────────────────┤
│  NODE DaemonSet (every node, privileged, hostPath mounts)                   │
│    node-driver-registrar   livenessprobe                                    │
│    <driver> (--mode=node)  privileged: true                                 │
│    hostPath /var/lib/kubelet/plugins/<driver>   (its socket)                │
│    hostPath /var/lib/kubelet/plugins_registry   (registration)              │
│    hostPath /var/lib/kubelet  with mountPropagation: Bidirectional          │
└────────────────────────────────────────────────────────────────────────────┘
```

`mountPropagation: Bidirectional` on the node container is not decoration. Without it, a mount the driver performs inside its container namespace is invisible to the kubelet and the workload Pod, and volumes appear to mount successfully while containers see an empty directory.

---

## The Unix Socket and Plugin Registration

CSI uses a **Unix domain socket**, never TCP, deliberately: the socket is a filesystem path, so access is controlled by ordinary file permissions and by which container mounts which volume. There is no port to firewall and no possibility of a remote caller reaching a driver, which matters because CSI RPCs are unauthenticated: whoever can open the socket can create and delete volumes.

### Inside the Controller Pod

```yaml
      containers:
      - name: csi-provisioner
        image: registry.k8s.io/sig-storage/csi-provisioner:vX.Y.Z
        args: ["--csi-address=$(ADDRESS)", "--leader-election"]
        env:
          - { name: ADDRESS, value: /csi/csi.sock }
        volumeMounts:
          - { name: socket-dir, mountPath: /csi }
      - name: nfs
        image: registry.k8s.io/sig-storage/nfsplugin:vX.Y.Z
        args: ["--endpoint=$(CSI_ENDPOINT)"]
        env:
          - { name: CSI_ENDPOINT, value: unix:///csi/csi.sock }
        volumeMounts:
          - { name: socket-dir, mountPath: /csi }
      volumes:
        - name: socket-dir
          emptyDir: {}
```

The driver **creates** `/csi/csi.sock`; the sidecars **connect** to it. Startup ordering needs no init container, because the sidecars retry the dial.

### On the Node

```yaml
      - name: node-driver-registrar
        image: registry.k8s.io/sig-storage/csi-node-driver-registrar:vX.Y.Z
        args:
          - "--csi-address=/csi/csi.sock"
          # The path AS THE KUBELET SEES IT on the host, not as this container
          # sees it. Getting this wrong is the classic mistake.
          - "--kubelet-registration-path=/var/lib/kubelet/plugins/csi-nfs/csi.sock"
        volumeMounts:
          - { name: socket-dir, mountPath: /csi }
          - { name: registration-dir, mountPath: /registration }
      volumes:
        - name: socket-dir
          hostPath: { path: /var/lib/kubelet/plugins/csi-nfs, type: DirectoryOrCreate }
        - name: registration-dir
          hostPath: { path: /var/lib/kubelet/plugins_registry, type: Directory }
        - name: pods-mount-dir
          hostPath: { path: /var/lib/kubelet/pods, type: Directory }
```

### The Registration Handshake

```
┌───────────────────────────────────────────────────────────────────────────┐
│  1. Driver container starts, creates                                       │
│       /var/lib/kubelet/plugins/csi-nfs/csi.sock                            │
│  2. node-driver-registrar dials it and calls GetPluginInfo                 │
│       ◄── name: "nfs.csi.k8s.io"                                          │
│  3. It creates /var/lib/kubelet/plugins_registry/nfs.csi.k8s.io-reg.sock   │
│     and serves the kubelet plugin registration API there                   │
│  4. The kubelet's plugin watcher notices the new socket (inotify), dials   │
│     it and calls GetInfo                                                   │
│       ◄── type: CSIPlugin, name: nfs.csi.k8s.io,                          │
│           endpoint: /var/lib/kubelet/plugins/csi-nfs/csi.sock              │
│  5. The kubelet dials the DRIVER socket directly and calls NodeGetInfo     │
│       ◄── node_id, max_volumes_per_node, accessible_topology              │
│  6. The kubelet writes the CSINode object, then calls                      │
│     NotifyRegistrationStatus back on the registrar socket.                 │
│                                                                            │
│  From here the kubelet calls the driver socket DIRECTLY for all Node RPCs. │
│  The registrar has no further role.                                        │
└───────────────────────────────────────────────────────────────────────────┘
```

```bash
ls -l /var/lib/kubelet/plugins_registry/     # nfs.csi.k8s.io-reg.sock
ls -l /var/lib/kubelet/plugins/csi-nfs/      # csi.sock
kubectl get csinode <node-name> -o yaml      # the authoritative confirmation
```

---

## The Kubernetes API Objects

Three objects in `storage.k8s.io/v1` exist purely to support CSI. Two of them you never write by hand.

### CSIDriver

Written by the driver's installation manifests. It tells Kubernetes how to treat this driver.

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  # MUST equal the name returned by GetPluginInfo, the StorageClass
  # provisioner, and pv.spec.csi.driver.
  name: nfs.csi.k8s.io
spec:
  # Does Kubernetes need to create VolumeAttachment objects and call
  # ControllerPublishVolume? For NFS and SMB there is nothing to attach:
  # set false, and the whole attach/detach machinery is skipped.
  attachRequired: false

  # Should the kubelet pass pod name/namespace/uid/serviceaccount to
  # NodePublishVolume in volume_context? Needed by drivers that fetch
  # per-pod secrets. Enable only if the driver documents that it needs it.
  podInfoOnMount: false

  # Persistent = normal PVC/PV volumes. Ephemeral = inline csi: volumes
  # declared directly in a Pod spec. Listing both allows either.
  volumeLifecycleModes:
    - Persistent
    - Ephemeral

  # How pod.spec.securityContext.fsGroup is applied.
  #   File                    - always apply the ownership/permission change
  #   ReadWriteOnceWithFSType - only for RWO volumes declaring an fsType
  #   None                    - never; the driver or backend owns permissions
  fsGroupPolicy: File

  # Does the driver publish CSIStorageCapacity objects for the scheduler?
  storageCapacity: false

  # Should the kubelet periodically re-call NodePublishVolume for already
  # published volumes? Used by drivers refreshing short-lived content.
  requiresRepublish: false

  # Can SELinux mount options be passed directly, letting the kubelet skip
  # an expensive recursive relabel?
  seLinuxMount: false
```

```bash
kubectl get csidrivers
# NAME             ATTACHREQUIRED  PODINFOONMOUNT  STORAGECAPACITY  MODES
# nfs.csi.k8s.io   false           false           false            Persistent
# smb.csi.k8s.io   false           true            false            Persistent,Ephemeral
```

Two fields deserve emphasis:

- **`attachRequired: false` removes an entire failure mode.** With it true, a node going `NotReady` leaves `VolumeAttachment` objects that must time out before the volume can move, which is where `Multi-Attach error` messages and multi-minute recovery delays come from. File protocol drivers simply do not have that class of problem.
- **`fsGroupPolicy: File`** makes the kubelet chown and chmod the volume on every mount. On a volume with a million small files that dominates Pod start time. `None` pushes the responsibility to the backend, which is usually right for NFS and SMB where mount options already set ownership.

### CSINode

**Written by the kubelet, never by you.** One object per node, recording what each driver said about this node during registration.

```yaml
apiVersion: storage.k8s.io/v1
kind: CSINode
metadata:
  name: node-c1
spec:
  drivers:
  - name: nfs.csi.k8s.io
    # The driver's own identifier for this node, from NodeGetInfo.
    nodeID: node-c1
    # Topology label keys this driver understands here. Empty for drivers
    # with no accessibility constraints.
    topologyKeys: []
  - name: ebs.csi.aws.com
    nodeID: i-0abc123def4567890
    topologyKeys:
    - topology.ebs.csi.aws.com/zone
    allocatable:
      # max_volumes_per_node from NodeGetInfo. The scheduler enforces this
      # as a hard limit when placing Pods with volumes from this driver.
      count: 25
```

This object answers "is the driver actually working on this node?" A node missing from the list, or a driver missing from a node's list, means registration did not complete there.

```bash
kubectl get csinode -o json | jq -r '
  .items[] | .metadata.name as $n | (.spec.drivers // [])[] | "\($n)\t\(.name)\t\(.nodeID)"'
```

### VolumeAttachment

**Created by the attach/detach controller, acted on by external-attacher.** The API representation of "this volume should be attached to that node".

```yaml
apiVersion: storage.k8s.io/v1
kind: VolumeAttachment
metadata:
  # Deterministic hash of attacher + volume + node.
  name: csi-4a7d2f9e8b1c0d3e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e
  finalizers:
  - external-attacher/ebs-csi-aws-com
spec:
  attacher: ebs.csi.aws.com
  nodeName: node-c1
  source:
    # Normally a PV reference. For inline ephemeral volumes an
    # inlineVolumeSpec appears here instead.
    persistentVolumeName: pvc-9f2e5c31-8b4a-4d21-9c7e-1a2b3c4d5e6f
status:
  attached: true
  # The publish_context returned by the driver, forwarded to NodeStageVolume.
  attachmentMetadata:
    devicePath: /dev/xvdba
```

Cluster scoped, and a very useful diagnostic. If a driver sets `attachRequired: false`, **no VolumeAttachment objects exist for it at all**, and an empty list is the correct, healthy state rather than a symptom.

### How the Objects Relate

```
   StorageClass.provisioner ──┐
   pv.spec.csi.driver ────────┼──── all equal ────► CSIDriver.metadata.name
   VolumeAttachment.attacher ─┘                          ▲ GetPluginInfo
   CSINode.spec.drivers[].name ───────────────────────────┤
   CSINode.spec.drivers[].nodeID ◄── NodeGetInfo ─────────┘
```

---

## The Full Architecture Diagram

```
  CONTROL PLANE
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  kube-apiserver                                                           │
  │    PVC  PV  StorageClass  VolumeAttachment  CSIDriver  CSINode            │
  │    VolumeSnapshot  VolumeSnapshotContent  VolumeSnapshotClass             │
  └───────────────▲──────────────────────────────────▲───────────────────────┘
  ┌───────────────┴──────────────────┐  ┌─────────────┴────────────────────┐
  │ kube-controller-manager          │  │ kube-scheduler                   │
  │  • PersistentVolume controller   │  │  • VolumeBinding plugin          │
  │    (binding, reclaim)            │  │    (WaitForFirstConsumer,        │
  │  • attach/detach controller      │  │     topology, attach limits,     │
  │    (creates VolumeAttachment)    │  │     CSIStorageCapacity)          │
  └──────────────────────────────────┘  └──────────────────────────────────┘
                  │  objects, not RPCs
                  ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  CSI CONTROLLER POD   (Deployment/StatefulSet, leader elected)            │
  │  ┌────────────────┐┌──────────────┐┌─────────────┐┌──────────────────┐  │
  │  │csi-provisioner ││ csi-attacher ││ csi-resizer ││ csi-snapshotter  │  │
  │  └───────┬────────┘└──────┬───────┘└──────┬──────┘└────────┬─────────┘  │
  │          └────────────────┴───────┬────────┴────────────────┘            │
  │                    unix:///csi/csi.sock   (emptyDir shared)               │
  │                    ┌───────────▼─────────────┐   ┌──────────────────┐    │
  │                    │  DRIVER: Identity +     │◄──│ livenessprobe    │    │
  │                    │          Controller     │   │  (calls Probe)   │    │
  │                    └───────────┬─────────────┘   └──────────────────┘    │
  └────────────────────────────────┼──────────────────────────────────────────┘
                                   │ vendor API / NFS / iSCSI / cloud SDK
                      ┌────────────▼───────────────┐
                      │     STORAGE BACKEND        │
                      └────────────▲───────────────┘
  ─────────────────────────────────┼──────────────────────────────────────────
  WORKER NODE                      │ data path (mount / block)
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  kubelet                                                                  │
  │   • watches plugins_registry/ (inotify)   • writes CSINode                │
  │   • calls Node RPCs DIRECTLY on the driver socket                         │
  └───────┬───────────────────────────────────────────▲──────────────────────┘
          │ NodeStage / NodePublish / NodeExpand       │ registration
  ┌───────▼─────────────────────────────────────────────┴──────────────────┐
  │  CSI NODE DAEMONSET POD  (every node, privileged)                       │
  │  ┌──────────────────────┐  ┌───────────────┐  ┌──────────────────────┐ │
  │  │ node-driver-registrar│  │ livenessprobe │  │ DRIVER: Identity +   │ │
  │  │  creates             │  │  calls Probe  │  │         Node service │ │
  │  │  <name>-reg.sock     │  └───────────────┘  │  Bidirectional mount │ │
  │  └──────────────────────┘                     └──────────┬───────────┘ │
  └───────────────────────────────────────────────────────────┼─────────────┘
  ┌────────────────────────────────────────────────────────────▼────────────┐
  │  HOST FILESYSTEM                                                         │
  │   /var/lib/kubelet/plugins_registry/nfs.csi.k8s.io-reg.sock              │
  │   /var/lib/kubelet/plugins/csi-nfs/csi.sock                              │
  │   /var/lib/kubelet/plugins/kubernetes.io/csi/.../globalmount   (STAGE)   │
  │   /var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/<pv>/mount       │
  │                                                          (PUBLISH, bind) │
  └───────────────────────────────┬──────────────────────────────────────────┘
                                  ▼  bind mount into the container namespace
                          ┌──────────────────┐
                          │  APPLICATION     │
                          └──────────────────┘
```

Three lines are worth tracing until they are obvious:

1. **The control plane never talks to the storage backend.** Only the driver's Controller service touches the backend's management API.
2. **The kubelet never talks to the Controller service**, and the sidecars never talk to the Node service. The two halves of the driver are independent processes on different machines.
3. **The data path does not pass through Kubernetes at all.** Once the mount exists, reads and writes go from the container through the kernel to the backend. Kubernetes is a control plane for storage, not a storage system.

---

## Deploying a CSI Driver in Practice

Every CSI driver installation consists of the same pieces:

```
1. CSIDriver object            declares behaviour (attachRequired, etc.)
2. ServiceAccounts + RBAC      one per sidecar role, cluster wide
3. Controller Deployment       driver + sidecars, leader elected
4. Node DaemonSet              driver + registrar + livenessprobe, privileged
5. StorageClass(es)            written by YOU, not usually by the driver
6. (optional) snapshot CRDs    if not already installed
```

The RBAC is neither trivial nor optional: the provisioner needs `get/list/watch` on PVCs and StorageClasses plus `create/delete` on PVs; the attacher needs full access to VolumeAttachments. Driver install manifests ship all of it, which is why "apply the vendor's YAML" is the normal path.

### csi-driver-nfs

Full instructions: [install-csi-nfs.md](install-csi-nfs.md).

```bash
# Discover the current release rather than hardcoding a version
csi_driver_nfs_vers=$(curl -s -L \
  https://api.github.com/repos/kubernetes-csi/csi-driver-nfs/releases/latest \
  | jq -r '.tag_name' | tr -d '[:space:]')

curl -skSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/${csi_driver_nfs_vers}/deploy/install-driver.sh" \
  | bash -s "${csi_driver_nfs_vers}" --

kubectl get pods -n kube-system -l 'app in (csi-nfs-node, csi-nfs-controller)' -o wide
# csi-nfs-controller-xxxxxxxxxx-yyyyy   4/4   Running   (Deployment)
# csi-nfs-node-aaaaa                    3/3   Running   (DaemonSet, node-a1)

kubectl get csidriver nfs.csi.k8s.io -o yaml
# spec.attachRequired: false     <-- NFS has nothing to attach
```

The install does **not** create a StorageClass; you write that yourself, naming `provisioner: nfs.csi.k8s.io` with `server` and `share` parameters. See [storage-classes.md](storage-classes.md#csi-driver-nfs).

### csi-driver-smb

Full instructions: [install-csi-smb.md](install-csi-smb.md).

```bash
csi_driver_smb_vers=$(curl -s -L \
  https://api.github.com/repos/kubernetes-csi/csi-driver-smb/releases/latest \
  | jq -r '.tag_name' | tr -d '[:space:]')

curl -skSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_driver_smb_vers}/deploy/install-driver.sh" \
  | bash -s "${csi_driver_smb_vers}" --

kubectl get pods -n kube-system -l 'app in (csi-smb-node, csi-smb-controller)'
```

SMB differs from NFS in one important way: **the mount itself is authenticated**, so a Secret is mandatory and is referenced from the StorageClass via the reserved node-stage secret parameters. See [storage-classes.md](storage-classes.md#csi-driver-smb).

### Post-Install Verification, In Order

```bash
# 1. Registered as an API object?
kubectl get csidrivers

# 2. Controller and node pods healthy?
kubectl get pods -n kube-system -l app=csi-nfs-controller
kubectl get pods -n kube-system -l app=csi-nfs-node -o wide

# 3. Did EVERY node complete registration?  <-- the step people skip
kubectl get csinode -o json | jq -r '
  .items[] | "\(.metadata.name): \((.spec.drivers//[])|map(.name)|join(","))"'

# 4. Does provisioning work end to end?
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: csi-smoke-test }
spec:
  storageClassName: nfs-csi
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/csi-smoke-test --timeout=120s

# 5. Does mounting work end to end? Then clean up.
kubectl run csi-smoke-pod --image=registry.k8s.io/busybox:1.27.2 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"c","image":"registry.k8s.io/busybox:1.27.2","command":["sh","-c","echo ok > /data/probe && cat /data/probe"],"volumeMounts":[{"name":"v","mountPath":"/data"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"csi-smoke-test"}}]}}'
kubectl logs csi-smoke-pod
kubectl delete pod csi-smoke-pod; kubectl delete pvc csi-smoke-test
```

Step 3 catches the most problems: a driver can be healthy on nine nodes and unregistered on the tenth, and the only symptom is that every tenth Pod fails to mount.

---

## Inline CSI Ephemeral Volumes

A CSI volume can be declared **directly in a Pod spec**, with no PVC and no PV, provided the driver's `CSIDriver` lists `Ephemeral` in `volumeLifecycleModes`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: inline-smb
spec:
  containers:
  - name: app
    image: nginx:1.27
    volumeMounts:
    - { name: share, mountPath: /mnt/share }
  volumes:
  - name: share
    csi:
      driver: smb.csi.k8s.io
      # Passed straight to NodePublishVolume as volume_context.
      volumeAttributes:
        source: //fileserver.corp.example.com/public
      # A Secret in the POD'S OWN namespace.
      nodePublishSecretRef:
        name: smb-creds
      readOnly: true
```

| | Inline ephemeral | PVC / PV |
|---|-----------------|----------|
| API objects created | none | PVC + PV |
| Lifetime | tied to the Pod | independent of the Pod |
| Controller RPCs used | **none** | `CreateVolume` and friends |
| Node RPCs used | `NodePublish` (and `Stage`) | the full sequence |
| Driver requirement | `Ephemeral` mode | `Persistent` mode |
| Secret namespace | the Pod's namespace | the class's configured namespace |
| Sizing / capacity | not expressed | `resources.requests` |
| Survives Pod deletion | ❌ | ✅ |
| Typical use | config, certs, mounting an existing share, secret stores | databases, uploads, anything with state |

The security consideration is real: an inline CSI volume lets any user who can create a Pod invoke `NodePublishVolume` on that driver with attributes of their choosing, referencing a Secret in their own namespace. There is no StorageClass in the path and therefore no administrator-controlled parameter set. Restrict which drivers allow `Ephemeral`, and use admission policy to constrain inline `csi` volumes if the driver is powerful.

Do not confuse this with **generic ephemeral volumes** (`ephemeral.volumeClaimTemplate` in a Pod spec), which do create a real PVC with a StorageClass, get full dynamic provisioning, and are deleted with the Pod. Generic ephemeral volumes are the better default for "a scratch volume from my normal storage tier"; inline CSI ephemeral volumes are for drivers whose whole purpose is per-Pod content.

---

## Storage Capacity Tracking

By default the scheduler assumes any node can host any volume. On a cluster with node local or zone constrained storage, that produces Pods that schedule successfully, fail to provision, get rescheduled, and fail again.

**CSIStorageCapacity** objects (`storage.k8s.io/v1`) let a driver publish available capacity per topology segment. The external-provisioner creates and refreshes them when run with capacity tracking enabled, using the driver's `GetCapacity` RPC.

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIStorageCapacity
metadata:
  name: csisc-9f2e5c31
  namespace: kube-system
storageClassName: fast-local
capacity: 1200Gi
# Optional: the largest single volume still creatable here.
maximumVolumeSize: 400Gi
nodeTopology:
  matchLabels:
    kubernetes.io/hostname: node-c1
```

Enable it end to end by setting `spec.storageCapacity: true` on the `CSIDriver` and running the provisioner sidecar with `--enable-capacity` (plus `--capacity-ownerref-level` and the `NAMESPACE`/`POD_NAME` downward API environment variables it needs to own the objects).

```
WITHOUT: scheduler picks node-a1 ► provision fails (no space) ► reschedule ►
         picks node-a2 ► fails ► ... until it happens to pick a node with room
WITH:    scheduler filters out nodes whose CSIStorageCapacity cannot satisfy
         the request ► picks a node that can ► provision succeeds first time
```

Two caveats: capacity data is **eventually consistent** (a stale object can still let the scheduler pick a node that just filled up), and it only helps for `WaitForFirstConsumer` classes, because with `Immediate` binding the volume exists before the scheduler is involved.

---

## Writing a CSI Driver Conceptually

```
┌──────────────────────────────────────────────────────────────────────────┐
│  MUST implement                                                           │
│    Identity:    GetPluginInfo, GetPluginCapabilities, Probe               │
│    Node:        NodePublishVolume, NodeUnpublishVolume,                   │
│                 NodeGetCapabilities, NodeGetInfo                          │
│  ADD for dynamic provisioning                                             │
│    Controller:  CreateVolume, DeleteVolume, ControllerGetCapabilities     │
│  ADD for block/attach semantics                                           │
│    Controller:  ControllerPublishVolume, ControllerUnpublishVolume        │
│    Node:        NodeStageVolume, NodeUnstageVolume                        │
│  ADD for resize:    ControllerExpandVolume, NodeExpandVolume              │
│  ADD for snapshots: CreateSnapshot, DeleteSnapshot, ListSnapshots         │
│  ADD for metrics:   NodeGetVolumeStats                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

A node-only driver (Identity plus Node) supporting only `Ephemeral` mode is a completely valid CSI driver, and is how several secret-injection style drivers are built.

### The Rules That Actually Matter

**1. Every RPC must be idempotent.** Sidecars retry on any error and any lost connection. `CreateVolume` twice with the same name returns the same volume; `DeleteVolume` on a deleted volume succeeds; `NodePublishVolume` onto an already published path succeeds.

**2. gRPC status codes are part of the contract**, and sidecars behave differently per code:

| Code | Meaning to the sidecar |
|------|------------------------|
| `ALREADY_EXISTS` | A *different* volume exists with this name: a real conflict |
| `INVALID_ARGUMENT` | The request is wrong; retrying is pointless, surface it |
| `NOT_FOUND` | Does not exist; for delete this is success-shaped |
| `FAILED_PRECONDITION` | Not possible right now (still attached elsewhere); retry later |
| `RESOURCE_EXHAUSTED` | Out of capacity or quota |
| `ABORTED` | An operation on this volume is already in progress; retry |
| `DEADLINE_EXCEEDED` | Timed out; may or may not have completed, so the retry must be safe |
| `UNIMPLEMENTED` | Not supported; do not call it again |

Returning `INTERNAL` for everything turns every transient problem into an infinite retry loop with no useful message on the PVC.

**3. Serialise per volume.** Two concurrent operations on one volume must not interleave. Drivers keep an in-memory lock keyed by volume ID and return `ABORTED` when it is held.

**4. The `volume_id` is your only durable state.** Everything needed to find the volume again must be encoded in it or retrievable from the backend using it. That is why real handles look like `10.0.0.20#export/fast#pvc-9f2e5c31`.

**5. Never trust that you were called before.** The controller Pod can be rescheduled between `CreateVolume` and the PV being written; the node can reboot between stage and publish. Check actual state rather than tracking it in memory.

### Testing

**csi-sanity** (from `kubernetes-csi/csi-test`) drives a running driver through the specification's requirements including idempotency, and is the first thing to run. The Kubernetes storage end-to-end tests can be pointed at a driver through a test driver manifest. **csc** (from `rexray/gocsi`) lets you call individual RPCs by hand against a socket, which is invaluable for deciding whether a failure is in the driver or the sidecar.

---

## Debugging CSI

```
┌───────────────────────────────────────────────────────────────────────────┐
│  WHERE IS IT BROKEN?                                                       │
│   PVC stuck Pending, no PV                                                │
│      ► provisioning: external-provisioner + Controller service            │
│   PVC Bound, Pod stuck ContainerCreating                                  │
│      ► attach or mount: external-attacher, kubelet, Node service          │
│   Pod running, data missing or read-only                                  │
│      ► publish semantics, mount propagation, fsGroup, backend perms       │
│   Works on some nodes only                                                │
│      ► registration: node-driver-registrar + CSINode                      │
│   PVC deleted, backend volume still there                                 │
│      ► DeleteVolume failing, or reclaimPolicy is Retain                   │
└───────────────────────────────────────────────────────────────────────────┘
```

### 1. Read the Sidecar Logs

Each sidecar is a separate container, so `-c` is mandatory:

```bash
kubectl get pod -n kube-system -l app=csi-nfs-controller \
  -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# csi-provisioner csi-snapshotter liveness-probe nfs

kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-provisioner --tail=200
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-attacher    --tail=200
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-resizer     --tail=200
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-snapshotter --tail=200
# The DRIVER's own view, where the real backend error lives:
kubectl logs -n kube-system deploy/csi-nfs-controller -c nfs             --tail=200
```

Sidecar logs are terse by default; raise verbosity with `--v=5` in the container args to see every RPC and response. Node side, target the node the Pod is on:

```bash
node=$(kubectl get pod web-0 -n web -o jsonpath='{.spec.nodeName}')
kubectl logs -n kube-system -l app=csi-nfs-node \
  --field-selector spec.nodeName=${node} -c nfs --tail=200
```

### 2. Check VolumeAttachment Objects

| Symptom | Meaning |
|---------|---------|
| No objects at all, `attachRequired: false` | Correct; this driver does not attach |
| No objects, `attachRequired: true` | The controller has not created one; the Pod may not be scheduled yet |
| Exists, `status.attached: false`, no error | external-attacher not running, or stuck calling the driver |
| Exists with `status.attachError` | The driver refused; the message is the backend's |
| Stuck Terminating with a finalizer | `ControllerUnpublishVolume` failing; read the attacher log |

### 3. Check the Kubelet Plugin Socket

```bash
ls -l /var/lib/kubelet/plugins_registry/          # is the reg socket there?
ls -l /var/lib/kubelet/plugins/*/csi.sock         # is the driver socket there?
journalctl -u kubelet --since "30 min ago" | grep -iE 'csi|plugin'
kubectl get csinode $(hostname) -o yaml           # the API's answer
```

```
No *-reg.sock
   ► node-driver-registrar not running, or the registration-dir hostPath is
     wrong (common on distros where the kubelet root is NOT /var/lib/kubelet)
reg.sock exists, CSINode has no entry
   ► --kubelet-registration-path points at a path the kubelet cannot see,
     or NodeGetInfo is failing on the driver
CSINode entry exists, mounts still fail
   ► the driver registered but NodeStage/NodePublish is failing: read the
     DRIVER container's log, not the registrar's
```

### 4. Common Failure Signatures

| Message | Cause | Fix |
|---------|-------|-----|
| `driver name X not found in the list of registered CSI drivers` | Registration incomplete on this node | Node DaemonSet Pod, `--kubelet-registration-path` |
| `failed to provision volume with StorageClass "Y": rpc error: code = InvalidArgument` | Bad StorageClass `parameters` | The text after `desc =` names the key |
| `rpc error: code = DeadlineExceeded` | Backend slow or unreachable from the controller Pod | Network path, credentials, backend load |
| `Multi-Attach error for volume` | RWO volume still attached elsewhere | Wait for the old Pod; a `NotReady` node blocks this |
| `NodeStageVolume ... permission denied` | Backend authentication or export ACL | Node-stage Secret, export rules, node IP |
| `MountVolume.SetUp failed ... no such file or directory` | Publish target missing, often mount propagation | `mountPropagation: Bidirectional` |
| `Unable to attach or mount volumes: timed out waiting for the condition` | Generic wrapper | The events and kubelet log below it |

### 5. Metrics

```
kubelet_volume_stats_capacity_bytes / available_bytes / used_bytes
kubelet_volume_stats_inodes / inodes_free
csi_sidecar_operations_seconds        (from sidecars, when enabled)
storage_operation_duration_seconds    (from kube-controller-manager)
```

A driver that does not implement `NodeGetVolumeStats` produces no `kubelet_volume_stats_*` series at all, making "PVC 90% full" alerting silently impossible. Check for that before promising it.

---

## CSI vs In-Tree vs FlexVolume

FlexVolume was the first attempt at out of tree storage: a driver was an **executable** dropped on every node in a well known directory, invoked with arguments like `init`, `attach`, `mount`. It is deprecated in favour of CSI.

| Aspect | In-Tree | FlexVolume | CSI |
|--------|---------|-----------|-----|
| Where the code lives | Kubernetes repository | A binary on every host | A container image |
| Deployment | Ship a new Kubernetes | Copy files to every node | `kubectl apply` |
| Removing a driver | Kubernetes release cycle | Delete files from every node | `kubectl delete` |
| Interface | Go function calls | exec plus JSON on stdout | gRPC over a Unix socket |
| Dependencies | Linked into core binaries | Must exist on the host | Baked into the image |
| Crash blast radius | kubelet or controller-manager | The kubelet's exec, node scoped | A container restart |
| Dynamic provisioning | ✅ | ❌ | ✅ |
| Snapshots | ❌ | ❌ | ✅ |
| Volume expansion | Partial | ❌ | ✅ |
| Topology awareness | Partial, hardcoded | ❌ | ✅ |
| Raw block volumes | Partial | ❌ | ✅ |
| Ephemeral inline volumes | Some types | ❌ | ✅ |
| Capacity aware scheduling | ❌ | ❌ | ✅ |
| Multi orchestrator | ❌ | ❌ | ✅ by design |
| Status | Removed or migrated | Deprecated | Current and only supported path |

The decisive advantage is not any single feature: **a CSI driver is an ordinary Kubernetes workload**, versioned, deployed, upgraded, monitored and debugged like one. FlexVolume required configuration management on every node; in-tree required a Kubernetes release.

---

## Command Reference

```bash
# ---- Drivers ------------------------------------------------------------
kubectl get csidrivers
kubectl get csidrivers -o custom-columns=\
'NAME:.metadata.name,ATTACH:.spec.attachRequired,PODINFO:.spec.podInfoOnMount,CAPACITY:.spec.storageCapacity,MODES:.spec.volumeLifecycleModes'

# ---- Per-node registration ---------------------------------------------
kubectl get csinode <node> -o yaml
kubectl get csinode -o json | jq -r '.items[] | "\(.metadata.name): \((.spec.drivers//[])|map(.name)|join(","))"'

# Attach limits the scheduler will honour
kubectl get csinode -o json | jq -r '
  .items[] | .metadata.name as $n | (.spec.drivers//[])[]
  | select(.allocatable!=null) | "\($n)\t\(.name)\tmax=\(.allocatable.count)"'

# ---- Attachments --------------------------------------------------------
kubectl get volumeattachment -o custom-columns=\
'NAME:.metadata.name,ATTACHER:.spec.attacher,PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName,ATTACHED:.status.attached'

# ---- Logs, per sidecar --------------------------------------------------
kubectl get pod -n kube-system -l app=csi-nfs-controller \
  -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-provisioner --tail=200
kubectl logs -n kube-system deploy/csi-nfs-controller -c nfs             --tail=200
node=$(kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.nodeName}')
kubectl logs -n kube-system -l app=csi-nfs-node --field-selector spec.nodeName=${node} -c nfs

# ---- Volume objects and capacity ---------------------------------------
kubectl get pv -o custom-columns=\
'NAME:.metadata.name,DRIVER:.spec.csi.driver,HANDLE:.spec.csi.volumeHandle,CLAIM:.spec.claimRef.name'
kubectl get csistoragecapacities -A

# ---- On a node ----------------------------------------------------------
ls -l /var/lib/kubelet/plugins_registry/
ls -l /var/lib/kubelet/plugins/*/csi.sock
findmnt -R | grep -E 'kubernetes.io~csi|globalmount'
journalctl -u kubelet --since "30 min ago" | grep -iE 'csi|volume|mount'
```

---

## Troubleshooting

### The Driver Installs but Nothing Provisions

```bash
kubectl get csidriver -o name
kubectl get sc -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner'
kubectl get pvc <name> -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/storage-provisioner}{"\n"}'
```

All three names must line up. If the PVC annotation names a driver with no `CSIDriver` object, or the class provisioner is misspelled, nothing errors: the provisioner simply never sees a claim it considers its own.

### The Controller Pod Runs but Does Nothing

Leader election. With more than one replica, only the leader acts:

```bash
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-provisioner | grep -i 'leader\|lock'
# "successfully acquired lease kube-system/nfs-csi-k8s-io"
kubectl get lease -n kube-system | grep -i csi
```

A pair of replicas where neither holds the lease usually means RBAC is missing `coordination.k8s.io` lease permissions.

### Works on Most Nodes, Fails on One

```bash
kubectl get pods -n kube-system -l app=csi-nfs-node -o wide | grep <node>
kubectl get node <node> -o jsonpath='{.spec.taints}' | jq
kubectl get csinode <node> -o yaml
```

A control plane node with `NoSchedule` taints the driver DaemonSet does not tolerate is the usual answer, and it only surfaces when somebody schedules a workload with a volume there.

### Non-Default kubelet Root Directory

Some distributions do not use `/var/lib/kubelet`. Every hostPath in the driver's manifests, and `--kubelet-registration-path`, must match reality:

```bash
ps aux | grep kubelet | tr ' ' '\n' | grep -- --root-dir
systemctl cat kubelet | grep -i root-dir
```

Most driver Helm charts expose this as a `kubeletDir` value. Setting it wrong produces a driver that runs, registers nothing, and reports no error other than mounts failing.

### Volumes Mount but the Container Sees an Empty Directory

Mount propagation. The driver mounted something inside its own mount namespace and nobody else can see it:

```bash
kubectl get ds -n kube-system csi-nfs-node -o json \
  | jq -r '.spec.template.spec.containers[].volumeMounts[]
           | select(.mountPath=="/var/lib/kubelet") | .mountPropagation'
# Bidirectional      <-- required
```

### PVC Deleted, Backend Volume Remains

```bash
kubectl get pv <name> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'   # Retain is correct behaviour
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-provisioner | grep -i 'delete\|error' | tail -40
kubectl get pv <name> -o jsonpath='{.metadata.finalizers}{"\n"}'
```

Forcing the finalizer off makes the Kubernetes object disappear and orphans real storage that nobody has a record of. Fix the underlying call and let the finalizer clear itself.

### Attach Limits Reached

```
0/12 nodes are available: 12 node(s) exceed max volume count
```

Each node has a per driver attach limit from `NodeGetInfo`, visible in `CSINode.spec.drivers[].allocatable.count`. Spread the workload, use fewer volumes per Pod, or use a file protocol driver that does not attach at all.

---

## Exam and Interview Traps

1. **CSI is a specification first and a Kubernetes implementation second.** The spec never mentions Kubernetes; the sidecars are the Kubernetes-specific translation layer.
2. **A CSI driver is a gRPC server on a Unix domain socket**, not an executable invoked per operation. That is the fundamental difference from both CNI and FlexVolume.
3. **There are exactly three services: Identity, Controller and Node.** Identity is mandatory in every process; Controller runs cluster wide; Node runs on every node.
4. **The kubelet calls the Node service directly.** No sidecar sits between them, and sidecars only translate API objects into Controller RPCs.
5. **`NodeStageVolume` is once per volume per node; `NodePublishVolume` is once per Pod.** Staging is the expensive mount, publishing a bind mount.
6. **The staging path ends in `globalmount`; the publish path is `/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pv-name>/mount`.**
7. **`node-driver-registrar` proxies no volume operation.** It only introduces the driver to the kubelet via a socket in `plugins_registry/`.
8. **`--kubelet-registration-path` is the path as the kubelet sees it on the host**, not as the registrar container sees it. The classic misconfiguration.
9. **`livenessprobe` exists because Kubernetes cannot health check a Unix socket.** It calls `Probe` and exposes HTTP.
10. **`attachRequired: false` means no `VolumeAttachment` objects are ever created** and `ControllerPublishVolume` is never called. An empty list is healthy for NFS and SMB.
11. **`CSINode` is written by the kubelet, not by you.** It records `nodeID`, `topologyKeys` and the attach limit from `NodeGetInfo`.
12. **The driver name must be identical in four places:** `GetPluginInfo`, the `CSIDriver` object, the StorageClass `provisioner`, and `pv.spec.csi.driver`. A mismatch fails silently.
13. **Every CSI RPC must be idempotent,** because sidecars retry aggressively and cannot distinguish a lost response from a failed operation.
14. **gRPC status codes are part of the contract.** `ALREADY_EXISTS`, `FAILED_PRECONDITION`, `ABORTED` and `UNIMPLEMENTED` each change what the sidecar does next.
15. **The `volume_id` returned by `CreateVolume` becomes `pv.spec.csi.volumeHandle`** and is the only durable handle the driver gets back later.
16. **`ControllerExpandVolume` may set `node_expansion_required`,** in which case the kubelet also calls `NodeExpandVolume` to grow the filesystem.
17. **`external-snapshotter` (a sidecar) and `snapshot-controller` (cluster wide) are different components,** and the snapshot CRDs are not part of the API server.
18. **Inline CSI ephemeral volumes bypass PVC, PV and StorageClass entirely** and use only Node RPCs. They need `Ephemeral` in `volumeLifecycleModes` and reference a Secret in the Pod's own namespace.
19. **Generic ephemeral volumes are not the same thing:** they create a real PVC from a StorageClass and are deleted with the Pod.
20. **`podInfoOnMount: true` passes pod name, namespace, uid and service account** into `NodePublishVolume`; enable it only when the driver needs it.
21. **`fsGroupPolicy: File` makes the kubelet recursively chown the volume on every mount,** which can dominate Pod start time on volumes with many files.
22. **Storage capacity tracking uses `CSIStorageCapacity` objects,** only helps with `WaitForFirstConsumer`, and is eventually consistent.
23. **CSI migration keeps in-tree PV field names working** by translating them to CSI calls, but the corresponding driver must be installed.
24. **FlexVolume required a binary on every node and had no dynamic provisioning, snapshots or resize.** It is deprecated; CSI is the only supported path.
25. **`mountPropagation: Bidirectional` on the node container is mandatory,** or mounts made by the driver are invisible to the kubelet and to workload Pods.
26. **`NodeGetVolumeStats` is what produces `kubelet_volume_stats_*` metrics.** A driver that skips it makes "volume nearly full" alerting impossible.
27. **The data path never goes through Kubernetes.** After the mount exists, I/O goes straight from the container to the backend through the kernel.
28. **A sidecar log and a driver log are different containers.** `kubectl logs` without `-c` gives you whichever the API picks, usually not the one you want.
29. **Forcing a finalizer off a stuck PV orphans real storage.** Fix the failing `DeleteVolume` call instead.
30. **Capabilities are declared, not assumed.** A compliant driver may implement only Identity and Node and still be fully valid CSI.

---

## Related Topics

- [StorageClasses](storage-classes.md)
- [Volume Snapshots](volume-snapshots.md)
- [Install csi-driver-nfs](install-csi-nfs.md)
- [Install csi-driver-smb](install-csi-smb.md)
- [Container Network Interface (CNI)](cni.md)
- [Container Runtime](container-runtime.md)
- [kubelet](kubelet.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-scheduler](kube-scheduler.md)
- [Kubernetes API](k8s-api.md)
- [Controllers](controllers.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [Pods](pods.md)
- [Secrets](secrets.md)
- [Worker Node](worker-node.md)
- [Kubernetes Architecture](k8s-architecture.md)

---

## Key Takeaways

1. **CSI is a vendor neutral gRPC specification plus a set of shared Kubernetes sidecars.** The specification knows nothing about Kubernetes; the sidecars are the only translation layer, written once and reused by every driver.
2. It replaced in-tree volume plugins to gain **independent release cycles, no kubelet recompiles or restarts, vendor independence, and a blast radius of one container** instead of a control plane binary.
3. **CSI migration** keeps legacy in-tree PV field names working by translating them to CSI calls, but the real driver must be installed. New StorageClasses should always name a CSI driver directly.
4. The specification defines **three services**: Identity (`GetPluginInfo`, `GetPluginCapabilities`, `Probe`), Controller (`CreateVolume`, `DeleteVolume`, `ControllerPublishVolume`, `ControllerUnpublishVolume`, `ValidateVolumeCapabilities`, `ControllerExpandVolume`, `CreateSnapshot`, `DeleteSnapshot` and others) and Node (`NodeStageVolume`, `NodeUnstageVolume`, `NodePublishVolume`, `NodeUnpublishVolume`, `NodeGetVolumeStats`, `NodeExpandVolume`, `NodeGetInfo`, `NodeGetCapabilities`).
5. **Capabilities are declared, not assumed**, which is how a file protocol driver and a block SAN driver are both fully compliant while doing different amounts of work.
6. **Staging is a global, per node mount done once; publishing is a per Pod bind mount.** The split exists so an expensive mount, format or login happens once even when ten Pods share the volume.
7. **The kubelet calls the Node service directly** over the driver's Unix socket. Sidecars never touch the Node service, and the kubelet never touches the Controller service.
8. Sidecars map one to one onto API objects: **external-provisioner** watches PVCs, **external-attacher** watches VolumeAttachments, **external-resizer** watches PVC size changes, **external-snapshotter** watches VolumeSnapshotContents, **node-driver-registrar** performs registration, **livenessprobe** turns `Probe` into HTTP.
9. Controller sidecars run in a **leader elected Deployment**; the driver's node half runs in a **privileged DaemonSet** with `mountPropagation: Bidirectional` and hostPath access to the kubelet directory.
10. Registration is a handshake through `/var/lib/kubelet/plugins_registry/<driver>-reg.sock`, after which the kubelet calls `NodeGetInfo` on the driver's own socket and writes **`CSINode`**. A broken registrar makes a healthy driver invisible.
11. **`CSIDriver`** declares behaviour (`attachRequired`, `podInfoOnMount`, `volumeLifecycleModes`, `fsGroupPolicy`, `storageCapacity`); **`CSINode`** is written by the kubelet per node; **`VolumeAttachment`** is created by the attach/detach controller and acted on by external-attacher. All three are `storage.k8s.io/v1`.
12. **The driver name must match exactly** across `GetPluginInfo`, `CSIDriver`, the StorageClass `provisioner` and `pv.spec.csi.driver`. Mismatches fail silently rather than loudly.
13. **Idempotency and correct gRPC status codes are the two hardest requirements on a driver author,** because sidecars retry every failure and behave differently per code.
14. **Inline CSI ephemeral volumes** skip PVC, PV and StorageClass and use only Node RPCs; they hand parameter control to whoever can create a Pod, so restrict which drivers allow them.
15. **Storage capacity tracking** publishes `CSIStorageCapacity` so the scheduler stops choosing nodes that cannot host the volume.
16. Debug in order: **sidecar logs (with `-c`), the driver container log, VolumeAttachment objects, then the plugin sockets and CSINode on the node**, then the kubelet journal. The message after `desc =` in an `rpc error` is the driver's own words.
17. **The data path never passes through Kubernetes.** CSI is a control plane for storage; once the mount exists, the kernel and the backend do all the work.

---

## References

- [Volumes](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Dynamic Volume Provisioning](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)
- [Ephemeral Volumes](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/)
- [Storage Capacity](https://kubernetes.io/docs/concepts/storage/storage-capacity/)
- [Node-specific Volume Limits](https://kubernetes.io/docs/concepts/storage/storage-limits/)
- [Volume Health Monitoring](https://kubernetes.io/docs/concepts/storage/volume-health-monitoring/)
- [CSIDriver API reference (storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/csi-driver-v1/)
- [CSINode API reference (storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/csi-node-v1/)
- [VolumeAttachment API reference (storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/volume-attachment-v1/)
- [CSIStorageCapacity API reference (storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/csi-storage-capacity-v1/)
- [Kubernetes CSI Developer Documentation](https://kubernetes-csi.github.io/docs/)
- [CSI Drivers list](https://kubernetes-csi.github.io/docs/drivers.html)
- [Developing a CSI Driver for Kubernetes](https://kubernetes-csi.github.io/docs/developing.html)
- [CSI Sidecar Containers](https://kubernetes-csi.github.io/docs/sidecar-containers.html)
- [external-provisioner](https://kubernetes-csi.github.io/docs/external-provisioner.html)
- [external-attacher](https://kubernetes-csi.github.io/docs/external-attacher.html)
- [external-resizer](https://kubernetes-csi.github.io/docs/external-resizer.html)
- [external-snapshotter](https://kubernetes-csi.github.io/docs/external-snapshotter.html)
- [node-driver-registrar](https://kubernetes-csi.github.io/docs/node-driver-registrar.html)
- [livenessprobe](https://kubernetes-csi.github.io/docs/livenessprobe.html)
- [CSI Objects](https://kubernetes-csi.github.io/docs/csi-objects.html)
- [Volume Expansion](https://kubernetes-csi.github.io/docs/volume-expansion.html)
- [Ephemeral Local Volumes](https://kubernetes-csi.github.io/docs/ephemeral-local-volumes.html)
- [Storage Capacity Tracking](https://kubernetes-csi.github.io/docs/storage-capacity-tracking.html)
- [Deploying CSI Driver on Kubernetes](https://kubernetes-csi.github.io/docs/deploying.html)
- [Testing Drivers](https://kubernetes-csi.github.io/docs/testing-drivers.html)
- [Container Storage Interface specification](https://github.com/container-storage-interface/spec/blob/master/spec.md)
