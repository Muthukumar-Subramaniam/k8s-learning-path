# 🗃️ PersistentVolumes and PersistentVolumeClaims

The complete PV and PVC contract: every field, the binding algorithm, the lifecycle state machine, expansion, raw block volumes, and the exact commands for reclaiming, resizing and unsticking storage in production.

## 📋 Table of Contents
- [The Contract in One Picture](#the-contract-in-one-picture)
- [The PersistentVolume Manifest](#the-persistentvolume-manifest)
- [volumeMode: Filesystem vs Block](#volumemode-filesystem-vs-block)
- [Reclaim Policies](#reclaim-policies)
- [mountOptions](#mountoptions)
- [nodeAffinity for Local Volumes](#nodeaffinity-for-local-volumes)
- [The csi Block](#the-csi-block)
- [The PersistentVolumeClaim Manifest](#the-persistentvolumeclaim-manifest)
- [storageClassName: Three Distinct Meanings](#storageclassname-three-distinct-meanings)
- [volumeName and selector](#volumename-and-selector)
- [The Lifecycle State Machine](#the-lifecycle-state-machine)
- [The Binding Algorithm](#the-binding-algorithm)
- [Why Binding Is Exclusive and One to One](#why-binding-is-exclusive-and-one-to-one)
- [Volume Binding Mode and the Topology Problem](#volume-binding-mode-and-the-topology-problem)
- [Storage Object in Use Protection](#storage-object-in-use-protection)
- [Reclaiming a Retained PV for Reuse](#reclaiming-a-retained-pv-for-reuse)
- [Volume Expansion](#volume-expansion)
- [Raw Block Volumes](#raw-block-volumes)
- [PVCs in StatefulSets](#pvcs-in-statefulsets)
- [Static Provisioning Walkthrough on NFS](#static-provisioning-walkthrough-on-nfs)
- [Dynamic Provisioning Walkthrough](#dynamic-provisioning-walkthrough)
- [Quotas and Limits on Storage](#quotas-and-limits-on-storage)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The Contract in One Picture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        THE PV / PVC CONTRACT                                 │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   DEVELOPER SIDE                        │        ADMINISTRATOR SIDE          │
│   namespace scoped                      │        cluster scoped              │
│                                         │                                    │
│   ┌───────────────────────────────┐     │   ┌──────────────────────────────┐ │
│   │ PersistentVolumeClaim         │     │   │ PersistentVolume             │ │
│   │  kind of a PURCHASE ORDER     │     │   │  kind of an INVENTORY ITEM   │ │
│   │                               │     │   │                              │ │
│   │  "I need:                     │◄────┼──►│  "I have:                    │ │
│   │     10Gi                      │ BIND│   │     10Gi at                  │ │
│   │     ReadWriteOnce             │ 1:1 │   │     nfs://server/export/x    │ │
│   │     class fast-ssd            │     │   │     ReadWriteOnce            │ │
│   │     Filesystem"               │     │   │     class fast-ssd           │ │
│   │                               │     │   │     reclaim: Retain"         │ │
│   │  Knows NOTHING about the      │     │   │                              │ │
│   │  backend.                     │     │   │  Knows NOTHING about which   │ │
│   └───────────────┬───────────────┘     │   │  app will use it.            │ │
│                   │                     │   └──────────────┬───────────────┘ │
│                   │                     │                  │                 │
│   ┌───────────────▼───────────────┐     │   ┌──────────────▼───────────────┐ │
│   │ Pod                           │     │   │ StorageClass                 │ │
│   │  volumes:                     │     │   │  the factory that makes PVs  │ │
│   │  - persistentVolumeClaim:     │     │   │  on demand                   │ │
│   │      claimName: my-claim      │     │   └──────────────────────────────┘ │
│   └───────────────────────────────┘     │                                    │
│                                         │                                    │
└──────────────────────────────────────────────────────────────────────────────┘

  The PVC is the ONLY storage object a portable application manifest contains.
  Everything below it varies per cluster and is the administrator's problem.
```

| | PersistentVolume | PersistentVolumeClaim |
|---|------------------|----------------------|
| `apiVersion` | `v1` | `v1` |
| Scope | **Cluster** | **Namespace** |
| Created by | Admin (static) or provisioner (dynamic) | Developer |
| Describes | A real piece of storage | A request for storage |
| Contains backend detail | Yes: server, share, driver, handle | **No** |
| Deleted when | Explicitly, or by reclaim policy | Explicitly |
| RBAC to create | Cluster level | Namespace level |
| Countable by quota | No | Yes |

---

## The PersistentVolume Manifest

Every field, annotated.

```yaml
apiVersion: v1                              # ALWAYS v1 for PV
kind: PersistentVolume
metadata:
  name: nfs-pv-web-share                    # cluster wide unique, no namespace
  labels:
    tier: web                               # used by a PVC spec.selector
    environment: lab
  annotations:
    # Set by the provisioner on dynamically created PVs. Do not hand write.
    pv.kubernetes.io/provisioned-by: nfs.csi.k8s.io
spec:
  # ── HOW MUCH ──────────────────────────────────────────────────────────
  capacity:
    storage: 10Gi                           # the only key supported today

  # ── WHAT SHAPE ────────────────────────────────────────────────────────
  volumeMode: Filesystem                    # Filesystem (default) | Block

  # ── WHO CAN MOUNT IT, AND HOW ─────────────────────────────────────────
  accessModes:                              # a LIST: the menu of offered modes
    - ReadWriteOnce                         # one node, read/write
    - ReadOnlyMany                          # many nodes, read only

  # ── WHAT HAPPENS WHEN THE CLAIM GOES AWAY ─────────────────────────────
  persistentVolumeReclaimPolicy: Retain     # Retain | Delete | Recycle(deprecated)

  # ── MATCHING ──────────────────────────────────────────────────────────
  storageClassName: nfs-tux2lab             # must equal the PVC's class

  # ── MOUNT FLAGS PASSED TO THE NODE ────────────────────────────────────
  mountOptions:
    - nfsvers=4.1
    - hard
    - noatime

  # ── WHERE THE VOLUME CAN BE REACHED (local / topology bound volumes) ──
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: ["worker-1"]

  # ── THE BACKEND (exactly ONE volume source) ───────────────────────────
  csi:
    driver: nfs.csi.k8s.io                  # must equal a CSIDriver name
    volumeHandle: nfs-web-share             # unique ID for this volume
    fsType: ""                              # empty for NFS; ext4/xfs for block
    readOnly: false
    volumeAttributes:                       # driver specific, opaque to k8s
      server: tux2lab-engine.user.internal
      share: /tux2lab-data
    # Optional secret references for each CSI phase
    # controllerPublishSecretRef: { name: ..., namespace: ... }
    # nodeStageSecretRef:         { name: ..., namespace: ... }
    # nodePublishSecretRef:       { name: ..., namespace: ... }

  # ── SET BY THE CONTROLLER WHEN BOUND (do not hand write on new PVs) ───
  # claimRef:
  #   apiVersion: v1
  #   kind: PersistentVolumeClaim
  #   name: nfs-pvc-web-share
  #   namespace: default
  #   uid: 4a3e...
status:
  phase: Bound                              # Available | Bound | Released | Failed
```

### Field Reference

| Field | Required | Mutable | Notes |
|-------|----------|---------|-------|
| `capacity.storage` | ✅ | Only via expansion | Bookkeeping for matching and quota. Not enforced by every backend. |
| `volumeMode` | No, defaults `Filesystem` | ❌ | Must equal the PVC's `volumeMode` for binding |
| `accessModes` | ✅ | ❌ | A list. The PVC's list must be a subset. |
| `persistentVolumeReclaimPolicy` | No, defaults `Retain` for hand written PVs | ✅ | Patchable at any time, including after `Released` |
| `storageClassName` | No | ❌ in practice | Empty string means "no class" |
| `mountOptions` | No | ✅ | Not validated by Kubernetes; a bad option fails at mount time |
| `nodeAffinity` | Required for `local` | ❌ | Restricts which nodes can use the volume |
| Volume source (`csi`, `nfs`, `local`, `hostPath`, `iscsi`, ...) | ✅ exactly one | ❌ | The actual backend |
| `claimRef` | No | ✅ | Set by the controller; clearing it is how you recycle a `Retained` PV |

### The Minimum Viable PV

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minimal
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  nfs:
    server: tux2lab-engine.user.internal
    path: /tux2lab-data
```

Everything else has a default: `volumeMode: Filesystem`, `persistentVolumeReclaimPolicy: Retain`, and no class.

---

## volumeMode: Filesystem vs Block

```
┌──────────────────────────────────────────────────────────────────────────┐
│              volumeMode: Filesystem      │      volumeMode: Block        │
├──────────────────────────────────────────┼───────────────────────────────┤
│                                          │                               │
│   PV ──► device or share                 │   PV ──► device               │
│           │                              │           │                   │
│           ▼                              │           ▼                   │
│   formatted with ext4/xfs                │   NOT formatted               │
│   (or already a filesystem, e.g. NFS)    │   NOT mounted                 │
│           │                              │           │                   │
│           ▼                              │           ▼                   │
│   mounted at a directory                 │   presented as a device node  │
│           │                              │           │                   │
│           ▼                              │           ▼                   │
│   container:  volumeMounts               │   container: volumeDevices    │
│     mountPath: /var/lib/data             │     devicePath: /dev/xvda     │
│           │                              │           │                   │
│           ▼                              │           ▼                   │
│   app does open("/var/lib/data/f")       │   app does open("/dev/xvda")  │
│                                          │   and manages its own layout  │
│                                          │                               │
│   ✅ the default, right for 99% of apps  │   ✅ databases with their own │
│   ✅ fsGroup, SELinux, subPath all work  │      block layer, storage     │
│                                          │      software, LVM in a pod   │
│                                          │   ❌ no fsGroup, no subPath   │
└──────────────────────────────────────────┴───────────────────────────────┘
```

Binding requires the PV and PVC to have the **same** `volumeMode`. A `Filesystem` PVC will never bind to a `Block` PV, and the mismatch produces a PVC that sits `Pending` with no obvious explanation, since the events do not spell out which criterion failed.

---

## Reclaim Policies

What happens to the PV and the underlying data when the PVC is deleted.

```
                        PVC deleted
                             │
                             ▼
                    PV becomes "Released"
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
   ┌─────────┐         ┌──────────┐        ┌──────────────┐
   │ Retain  │         │  Delete  │        │   Recycle    │
   └─────────┘         └──────────┘        └──────────────┘
   PV stays.           PV object is        DEPRECATED.
   Data stays.         deleted AND the     Ran `rm -rf /vol/*`
   Status: Released    backend volume      then made the PV
   NOT reusable        is destroyed by     Available again.
   until claimRef      the provisioner.    Use dynamic
   is cleared.         Status: gone.       provisioning instead.
   Admin decides.      Data: GONE.

   ✅ Safe default     ⚠️ Convenient and   ❌ Do not use
   for anything        destructive
   irreplaceable
```

| Policy | PV object after PVC deletion | Backend data | Default for |
|--------|------------------------------|--------------|-------------|
| `Retain` | Stays, phase `Released` | Preserved | Hand written PVs |
| `Delete` | Deleted | **Destroyed** | Dynamically provisioned PVs |
| `Recycle` | Becomes `Available` again after a scrub | Wiped | Nothing. Deprecated. |

### Changing the Policy

The reclaim policy is one of the few mutable PV fields, and patching it is a standard defensive move before any risky operation.

```bash
# Protect a dynamically provisioned volume before doing something dangerous
kubectl patch pv pvc-4a7e1b2c-... \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# Bulk protect every PV bound to a namespace
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="prod")]}{.metadata.name} {end}'); do
  kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
done

kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy
```

> ⚠️ **The most expensive mistake in Kubernetes storage** is `kubectl delete pvc` against a `Delete` policy volume holding production data. There is no undo. Set `Retain` on anything you cannot recreate, and consider a validating policy that rejects PVC deletion in production namespaces.

---

## mountOptions

Flags handed to the node at mount time. Kubernetes does not validate them.

```yaml
spec:
  mountOptions:
    - nfsvers=4.1        # protocol version
    - hard               # retry I/O forever rather than returning EIO
    - timeo=600          # tenths of a second before a retry
    - retrans=2
    - noatime            # do not write access times, a real performance win
    - nodiratime
```

| Backend | Common options | Why |
|---------|----------------|-----|
| NFS | `nfsvers=4.1`, `hard`, `noatime`, `timeo`, `retrans` | `hard` protects data integrity; `soft` returns I/O errors and can corrupt applications |
| SMB | `vers=3.0`, `dir_mode`, `file_mode`, `uid`, `gid` | SMB has no POSIX ownership, so mode and ownership are set at mount time |
| ext4 / xfs on block | `noatime`, `discard`, `nobarrier` (with care) | Performance tuning |

An invalid option surfaces only when a Pod tries to mount:

```
MountVolume.SetUp failed for volume "nfs-pv" : mount failed: exit status 32
Output: mount.nfs: an incorrect mount option was specified
```

`mountOptions` on a StorageClass are copied into every PV it provisions. Since StorageClass fields are effectively immutable, changing options for future volumes means creating a new class; existing PVs keep what they were born with, and can be patched individually.

---

## nodeAffinity for Local Volumes

A PV whose storage is only reachable from certain nodes must say so, or the scheduler will place Pods where the volume cannot be mounted.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv-worker1-nvme0
spec:
  capacity:
    storage: 500Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-nvme
  local:
    path: /mnt/disks/nvme0            # must already exist and be mounted
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - worker-1
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│              WHY nodeAffinity IS MANDATORY FOR local                     │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  WITHOUT nodeAffinity (this is what hostPath does):                      │
│                                                                          │
│    scheduler: "worker-3 has the most free CPU, put the pod there"        │
│    kubelet on worker-3: mounts /mnt/disks/nvme0                          │
│                          ...which on worker-3 is EMPTY or DIFFERENT      │
│    Result: silent data loss, no error anywhere.                          │
│                                                                          │
│  WITH nodeAffinity:                                                      │
│                                                                          │
│    scheduler: "this PV requires worker-1, therefore the pod goes to      │
│                worker-1 or it does not get scheduled at all"             │
│    Result: correct placement, or an honest Pending with a clear reason.  │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

The same mechanism carries **zone** topology for cloud volumes, using keys such as `topology.kubernetes.io/zone`. A dynamic provisioner writes it automatically; for a hand written PV you must supply it.

Local volumes should always use a class with `volumeBindingMode: WaitForFirstConsumer`, for the reason explained in [Volume Binding Mode and the Topology Problem](#volume-binding-mode-and-the-topology-problem).

---

## The csi Block

The modern volume source. Every field matters.

```yaml
spec:
  csi:
    driver: nfs.csi.k8s.io          # REQUIRED. Must match a CSIDriver object name.
    volumeHandle: nfs-web-share     # REQUIRED. The driver's unique ID for this
                                    # volume. Must be unique across the cluster.
    fsType: ext4                    # Only meaningful for block backed volumes.
                                    # Leave empty for NFS/SMB, which already
                                    # present a filesystem.
    readOnly: false                 # force read only regardless of access mode
    volumeAttributes:               # OPAQUE key/value passed to the driver
      server: tux2lab-engine.user.internal
      share: /tux2lab-data
      # subDir: some/path           # driver specific extras
    controllerPublishSecretRef:     # credentials for the attach phase
      name: storage-creds
      namespace: kube-system
    nodeStageSecretRef:             # credentials for the per node mount
      name: storage-creds
      namespace: kube-system
    nodePublishSecretRef:           # credentials for the per pod bind mount
      name: storage-creds
      namespace: kube-system
    nodeExpandSecretRef:            # credentials for online filesystem resize
      name: storage-creds
      namespace: kube-system
```

### volumeHandle Is the Identity

`volumeHandle` is what the driver receives in every subsequent call. Two PVs with the same `driver` and `volumeHandle` are, from the driver's point of view, **the same volume**, which leads to two claims pointing at one backend directory with no warning.

For `nfs.csi.k8s.io`, a widely used convention for static PVs is a composite string that encodes the server, the share and a unique suffix, so that no two PVs collide:

```yaml
    volumeHandle: tux2lab-engine.user.internal#tux2lab-data#web-share
```

The repository's own manifest uses the simpler `nfs-web-share`, which is fine as long as it is not reused. Uniqueness is the requirement; the format is a convention.

### Secret References

Each of the four secret references corresponds to a different CSI call, so a driver can use different credentials for cluster level and node level operations. They reference a Secret in a specific namespace (usually the driver's own), which is why they are safe to place in a cluster scoped PV: a developer cannot point them at a Secret they do not control, because the PV is an admin object.

---

## The PersistentVolumeClaim Manifest

```yaml
apiVersion: v1                              # ALWAYS v1 for PVC
kind: PersistentVolumeClaim
metadata:
  name: nfs-pvc-web-share
  namespace: default                        # PVCs ARE namespaced
  labels:
    app: web
spec:
  # ── HOW IT WILL BE USED ───────────────────────────────────────────────
  accessModes:
    - ReadOnlyMany                          # must be a SUBSET of the PV's list

  # ── SHAPE ─────────────────────────────────────────────────────────────
  volumeMode: Filesystem                    # must EQUAL the PV's volumeMode

  # ── HOW MUCH ──────────────────────────────────────────────────────────
  resources:
    requests:
      storage: 1Mi                          # the PV must offer at least this
    # limits:                               # rarely used; some drivers honour it
    #   storage: 20Gi

  # ── WHICH CLASS ───────────────────────────────────────────────────────
  storageClassName: ""                      # "" | omitted | a class name
                                            # three DIFFERENT meanings, see below

  # ── EXPLICIT BINDING (static provisioning) ────────────────────────────
  volumeName: nfs-pv-web-share              # bind to exactly this PV

  # ── LABEL BASED SELECTION (an alternative to volumeName) ──────────────
  # selector:
  #   matchLabels:
  #     tier: web
  #   matchExpressions:
  #     - key: environment
  #       operator: In
  #       values: ["lab", "staging"]

  # ── CLONE OR RESTORE FROM A SNAPSHOT (CSI drivers that support it) ────
  # dataSource:
  #   name: db-snapshot-2025-09-01
  #   kind: VolumeSnapshot
  #   apiGroup: snapshot.storage.k8s.io
status:
  phase: Bound                              # Pending | Bound | Lost
  accessModes:
    - ReadOnlyMany
  capacity:
    storage: 1Mi                            # the ACTUAL bound capacity
```

### Field Reference

| Field | Required | Mutable after binding | Notes |
|-------|----------|----------------------|-------|
| `accessModes` | ✅ | ❌ | Subset of the PV's list |
| `resources.requests.storage` | ✅ | ✅ **increase only**, if the class allows expansion | Shrinking is rejected |
| `volumeMode` | No, defaults `Filesystem` | ❌ | Must match the PV exactly |
| `storageClassName` | No | ❌ | Three distinct behaviours, see below |
| `volumeName` | No | ❌ | Forces binding to one specific PV |
| `selector` | No | ❌ | Ignored for dynamic provisioning |
| `dataSource` / `dataSourceRef` | No | ❌ | Clone from a PVC or restore a VolumeSnapshot |

### status.capacity Is the Truth

```bash
kubectl get pvc data -o jsonpath='{.spec.resources.requests.storage}{"\n"}'   # 10Gi requested
kubectl get pvc data -o jsonpath='{.status.capacity.storage}{"\n"}'           # 100Gi actual
```

A 10Gi request bound to a 100Gi PV gives the claim all 100Gi. `spec` is the ask; `status` is what was granted.

---

## storageClassName: Three Distinct Meanings

This is the single most common source of confusion in the whole storage API.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     THREE STATES OF storageClassName                         │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  (A) FIELD OMITTED ENTIRELY                                                  │
│      spec:                                                                   │
│        accessModes: [ReadWriteOnce]                                          │
│        resources: { requests: { storage: 10Gi } }                            │
│                                                                              │
│      ──► The DefaultStorageClass admission controller WRITES the default     │
│          class name into the object at creation time.                        │
│      ──► If no default class exists, the field stays empty and the PVC       │
│          behaves like case (B).                                              │
│      ──► kubectl get pvc -o yaml will SHOW the class it was given.           │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  (B) EMPTY STRING                                                            │
│      spec:                                                                   │
│        storageClassName: ""                                                  │
│                                                                              │
│      ──► "I explicitly want NO class."                                       │
│      ──► Dynamic provisioning is DISABLED for this claim.                    │
│      ──► Binds ONLY to PVs that also have no storageClassName.               │
│      ──► This is the correct value for hand written static PV pairs.         │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│  (C) A CLASS NAME                                                            │
│      spec:                                                                   │
│        storageClassName: nfs-tux2lab                                         │
│                                                                              │
│      ──► Binds to an existing Available PV of that class, if one matches.    │
│      ──► Otherwise the class's provisioner dynamically creates one.          │
│      ──► If the class does not exist, the PVC stays Pending with a clear     │
│          event: storageclass.storage.k8s.io "nfs-tux2lab" not found          │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### The Practical Consequences

```bash
# Scenario: a cluster HAS a default class, and you hand wrote a classless PV.
# You omit storageClassName on the PVC, expecting it to bind to your PV.

kubectl apply -f my-static-pv.yaml      # PV has no storageClassName
kubectl apply -f my-pvc.yaml            # PVC omits storageClassName

kubectl get pvc my-pvc -o yaml | grep storageClassName
#   storageClassName: nfs-tux2lab       ← the admission controller filled it in!

kubectl get pv my-static-pv
# still Available, because its class ("") does not match "nfs-tux2lab"

# Meanwhile a brand new volume was dynamically provisioned and bound instead.
```

The fix is `storageClassName: ""` on both objects, or `volumeName` for an explicit binding. The repository's `nfs-pvc-web-share.yaml` sidesteps the problem entirely by using `volumeName`, which is the most robust approach for static pairs.

### Which Class Is Default

```bash
kubectl get storageclass
# NAME                    PROVISIONER      RECLAIMPOLICY   VOLUMEBINDINGMODE
# nfs-tux2lab (default)   nfs.csi.k8s.io   Delete          Immediate

kubectl get sc -o json | jq -r '.items[]
  | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true")
  | .metadata.name'
```

---

## volumeName and selector

Two ways to steer a claim toward a particular PV.

### volumeName: Exact, Deterministic Binding

```yaml
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
  volumeName: nfs-pv-web-share     # bind to THIS pv, nothing else
```

- Skips the search entirely.
- If that PV is missing, bound elsewhere or incompatible, the PVC stays `Pending`.
- Immutable after binding.
- The clearest way to express a static pair, and the pattern the lab uses.

### selector: Label Based Matching

```yaml
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: local-nvme
  selector:
    matchLabels:
      disk-type: nvme
      rack: r14
    matchExpressions:
      - key: performance-tier
        operator: In
        values: ["gold", "platinum"]
```

Matching PVs carry those labels:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv-r14-nvme3
  labels:
    disk-type: nvme
    rack: r14
    performance-tier: gold
```

| | `volumeName` | `selector` |
|---|-------------|------------|
| Granularity | One specific PV | A pool of candidates |
| Works with dynamic provisioning | No | **No, it is ignored** |
| Use when | You wrote both objects yourself | You maintain a labelled pool of static PVs |
| Failure mode | Pending until that PV is free | Pending until a labelled PV appears |

> ⚠️ **`selector` and dynamic provisioning do not mix.** A provisioner has no way to satisfy a label selector, so a PVC with both a `selector` and a provisionable class will not be dynamically provisioned. It waits for a matching static PV forever.

---

## The Lifecycle State Machine

```
┌───────────────────────────────────────────────────────────────────────────────┐
│                     PERSISTENTVOLUME LIFECYCLE                                │
└───────────────────────────────────────────────────────────────────────────────┘

                        ┌──────────────────────┐
                        │   1. PROVISIONING    │
                        ├──────────────────────┤
     STATIC             │ admin writes a PV    │            DYNAMIC
     kubectl apply ────►│  ...or...            │◄──── provisioner sees a PVC
                        │ CSI CreateVolume     │       and calls CreateVolume
                        └──────────┬───────────┘
                                   │
                                   ▼
                        ╔══════════════════════╗
                        ║      AVAILABLE       ║  ← PV exists, no claim yet
                        ║  (free inventory)    ║
                        ╚══════════┬═══════════╝
                                   │
                        ┌──────────▼───────────┐
                        │   2. BINDING         │
                        │ PV controller matches│
                        │ a PVC to this PV and │
                        │ writes spec.claimRef │
                        └──────────┬───────────┘
                                   │
                                   ▼
                        ╔══════════════════════╗
                        ║        BOUND         ║  ← 1:1, exclusive, mutual
                        ║  PV.claimRef -> PVC  ║
                        ║  PVC.volumeName-> PV ║
                        ╚══════════┬═══════════╝
                                   │
                        ┌──────────▼───────────┐
                        │   3. USING           │
                        │ pod mounts the PVC   │
                        │ pvc-protection       │
                        │ finalizer active     │
                        └──────────┬───────────┘
                                   │  PVC deleted
                                   │  (blocked while any pod uses it)
                                   ▼
                        ┌──────────────────────┐
                        │   4. RECLAIMING      │
                        │ policy decides       │
                        └──────────┬───────────┘
                                   │
             ┌─────────────────────┼─────────────────────┐
             │ Retain              │ Delete              │ Recycle (deprecated)
             ▼                     ▼                     ▼
   ╔══════════════════╗   ┌──────────────────┐   ┌──────────────────┐
   ║    RELEASED      ║   │ DeleteVolume on  │   │  rm -rf /vol/*   │
   ║ claimRef still   ║   │ the backend, then│   │  then back to    │
   ║ points at a gone ║   │ the PV object is │   │  AVAILABLE       │
   ║ PVC. Data intact.║   │ removed          │   └──────────────────┘
   ║ NOT reusable.    ║   └────────┬─────────┘
   ╚════════┬═════════╝            │
            │                      ▼
            │              ┌──────────────┐
            │              │   DELETED    │  ← object gone, data gone
            │              └──────────────┘
            │
            │ admin clears spec.claimRef
            ▼
   ╔══════════════════╗
   ║    AVAILABLE     ║  ← reusable again, data still there
   ╚══════════════════╝

   Any step can fail:
                        ╔══════════════════════╗
                        ║        FAILED        ║  ← automatic reclamation
                        ║  read the events     ║    failed; manual repair
                        ╚══════════════════════╝
```

### PV Phases

| Phase | Meaning | Normal? |
|-------|---------|---------|
| `Available` | Free, unclaimed, ready to bind | ✅ |
| `Bound` | Claimed by exactly one PVC | ✅ the steady state |
| `Released` | The PVC is gone, `claimRef` still set, data intact | ⚠️ requires an admin decision |
| `Failed` | Automatic reclamation failed | ❌ investigate |

### PVC Phases

| Phase | Meaning |
|-------|---------|
| `Pending` | Not bound yet: waiting for a matching PV, for provisioning, or for a consumer |
| `Bound` | Bound to a PV and usable |
| `Lost` | The bound PV no longer exists. The claim is unusable. |

```bash
kubectl get pv  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,CLAIM:.spec.claimRef.name,POLICY:.spec.persistentVolumeReclaimPolicy
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName
```

---

## The Binding Algorithm

The PersistentVolume controller in [kube-controller-manager](kube-controller-manager.md) runs a reconciliation loop. For each `Pending` PVC:

```
┌───────────────────────────────────────────────────────────────────────────┐
│                          BINDING DECISION TREE                            │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  1. Is spec.volumeName set?                                               │
│       YES ──► fetch that PV.                                              │
│               Is it Available (or already claimRef'd to this PVC)?        │
│                 and compatible on modes, capacity, class, volumeMode?     │
│                 YES ──► BIND.   NO ──► stay Pending.                      │
│       NO  ──► continue                                                    │
│                                                                           │
│  2. Is the class volumeBindingMode WaitForFirstConsumer?                  │
│       YES ──► do nothing until the scheduler picks a node for a pod       │
│               that uses this PVC. Event: "waiting for first consumer".    │
│       NO  ──► continue                                                    │
│                                                                           │
│  3. Search all PVs in phase Available. Keep a candidate only if ALL hold: │
│                                                                           │
│       ✓ PV.spec.accessModes  ⊇  PVC.spec.accessModes                      │
│       ✓ PV.spec.capacity.storage  ≥  PVC.spec.resources.requests.storage  │
│       ✓ PV.spec.storageClassName  ==  PVC.spec.storageClassName           │
│       ✓ PV.spec.volumeMode        ==  PVC.spec.volumeMode                 │
│       ✓ PV labels satisfy PVC.spec.selector (if a selector is set)        │
│       ✓ PV.spec.claimRef is empty, OR points at THIS PVC                  │
│       ✓ PV nodeAffinity is satisfiable by at least one schedulable node   │
│                                                                           │
│  4. Any candidates?                                                       │
│       YES ──► pick the SMALLEST sufficient one (least wasted capacity)    │
│               write PV.spec.claimRef and PVC.spec.volumeName              │
│               ──► BOUND                                                   │
│       NO  ──► continue                                                    │
│                                                                           │
│  5. Does the PVC name a class with a real provisioner?                    │
│       YES ──► external-provisioner calls CSI CreateVolume,                │
│               creates a PV, binds it.                                     │
│       NO  ──► PVC stays Pending indefinitely.                             │
│               Event: "no persistent volumes available for this claim      │
│                       and no storage class is set"                        │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

### The Matching Criteria in Detail

| Criterion | Rule | Common mistake |
|-----------|------|----------------|
| **Access modes** | The PVC's list must be a subset of the PV's list | Asking for `ReadWriteMany` from a PV that only offers `ReadWriteOnce` |
| **Capacity** | PV capacity **at least** the request. Bigger is fine. | Expecting an exact match, or expecting the leftover to be reusable |
| **Class** | Exact string equality, including the empty string | Omitting the field and getting the default class injected |
| **Volume mode** | Exact equality | A `Block` PV silently ignored by a `Filesystem` PVC |
| **Selector** | All `matchLabels` and `matchExpressions` satisfied by the PV's labels | Using a selector together with a provisionable class |
| **claimRef** | Empty, or already this PVC | A `Released` PV still holding a stale `claimRef` |

### Best Fit, Not First Fit

```
   PVC requests 10Gi, ReadWriteOnce, class "std"

   Available PVs of class "std", all RWO:
     pv-small    5Gi   ✘ too small
     pv-exact   10Gi   ✔ candidate, waste 0
     pv-medium  50Gi   ✔ candidate, waste 40Gi
     pv-large  500Gi   ✔ candidate, waste 490Gi

   ──► binds pv-exact
```

The controller minimises wasted capacity, which is why a large PV can sit `Available` for a long time while small claims come and go.

---

## Why Binding Is Exclusive and One to One

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    ONE PV  ↔  ONE PVC.  ALWAYS.                          │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   ✅ SUPPORTED: many pods, ONE claim                                     │
│                                                                          │
│      pod-a ─┐                                                            │
│      pod-b ─┼──► PVC nfs-pvc-web-share ──► PV nfs-pv-web-share           │
│      pod-c ─┘        (subject to the PV's accessModes)                   │
│                                                                          │
│   ❌ NOT SUPPORTED: many claims, ONE PV                                  │
│                                                                          │
│      PVC-a ─┐                                                            │
│      PVC-b ─┼──✗──► PV big-100Gi                                         │
│      PVC-c ─┘        only the FIRST binds; the others stay Pending       │
│                                                                          │
│   ❌ NOT SUPPORTED: partial allocation                                   │
│                                                                          │
│      PVC 10Gi ──► PV 100Gi                                               │
│      The claim OWNS all 100Gi. The other 90Gi is not available to        │
│      anyone else, ever, while this binding exists.                       │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

The reasons this design is correct:

1. **Deterministic identity.** A claim always resolves to the same storage, which is what makes StatefulSet reattachment work.
2. **Safe reclamation.** With one owner, "the claim is gone, so reclaim the volume" is unambiguous.
3. **No allocator in the control plane.** Sub-allocating a PV would require Kubernetes to understand filesystems and quotas. That job belongs to the storage backend and to dynamic provisioning.

The way to share storage between workloads is either a shared PVC (many Pods, one claim, RWX or ROX), or many claims each getting their own dynamically provisioned volume.

### Verifying a Binding Is Mutual

```bash
kubectl get pvc nfs-pvc-web-share -o jsonpath='{.spec.volumeName}{"\n"}'
# nfs-pv-web-share

kubectl get pv nfs-pv-web-share -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'
# default/nfs-pvc-web-share
```

Both directions must agree. A PV whose `claimRef` names a PVC that does not exist is the definition of `Released`.

---

## Volume Binding Mode and the Topology Problem

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: zonal-ssd
provisioner: some.csi.driver.example.com
volumeBindingMode: WaitForFirstConsumer     # or Immediate
```

| Mode | When binding and provisioning happen | Right for |
|------|--------------------------------------|-----------|
| `Immediate` (default) | As soon as the PVC is created, before any Pod exists | Storage reachable from every node: NFS, SMB, most shared filesystems |
| `WaitForFirstConsumer` | Only once a Pod using the PVC is being scheduled | Anything topology constrained: zonal disks, `local` volumes, node pinned storage |

### The Failure Scenario That Justifies It

```
┌──────────────────────────────────────────────────────────────────────────────┐
│         IMMEDIATE BINDING IN A MULTI ZONE CLUSTER: THE DEADLOCK              │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   Cluster: zone-a (2 nodes), zone-b (2 nodes), zone-c (2 nodes)              │
│   The workload also requires nodeSelector: gpu=true, and every GPU node      │
│   happens to be in zone-c.                                                   │
│                                                                              │
│   t0  Developer creates a PVC. No pod exists yet.                            │
│                                                                              │
│   t1  volumeBindingMode: Immediate                                           │
│       ──► the provisioner must choose a zone RIGHT NOW.                      │
│       ──► it has no idea where the pod will run.                             │
│       ──► it picks zone-a.                                                   │
│       ──► a real disk is created in zone-a. PV nodeAffinity: zone-a.         │
│                                                                              │
│   t2  Developer creates the Deployment with nodeSelector gpu=true.           │
│                                                                              │
│   t3  Scheduler:                                                             │
│         "pod needs a GPU node"        → only zone-c qualifies                │
│         "pod needs PV in zone-a"      → only zone-a qualifies                │
│         intersection = ∅                                                     │
│                                                                              │
│   RESULT: Pod Pending forever.                                               │
│     0/6 nodes are available:                                                 │
│       2 node(s) had volume node affinity conflict,                           │
│       4 node(s) didn't match node selector.                                  │
│                                                                              │
│   The disk in zone-a is real, costs money, and is useless. The only fix      │
│   is to delete the PVC and the PV and start again.                           │
│                                                                              │
├──────────────────────────────────────────────────────────────────────────────┤
│         WaitForFirstConsumer: THE SAME SEQUENCE, SOLVED                      │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   t0  PVC created.                                                           │
│       ──► NOTHING happens. Status Pending.                                   │
│       ──► Event: "waiting for first consumer to be created before binding"   │
│                                                                              │
│   t1  Deployment created. Scheduler evaluates the pod:                       │
│         GPU requirement          → zone-c                                    │
│         volume not yet created   → no constraint                             │
│       ──► scheduler selects gpu-node-1 in zone-c                             │
│       ──► scheduler ANNOTATES the PVC with the selected node                 │
│                                                                              │
│   t2  Provisioner sees the annotation and creates the disk IN ZONE-C,        │
│       with matching nodeAffinity.                                            │
│                                                                              │
│   t3  Pod binds, mounts, runs. ✅                                            │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### The Annotation That Makes It Work

```bash
kubectl get pvc <pvc> -o jsonpath='{.metadata.annotations}' | jq
# {
#   "volume.kubernetes.io/selected-node": "gpu-node-1",
#   ...
# }
```

The scheduler writes `volume.kubernetes.io/selected-node`, and the external provisioner uses it to place the volume correctly. That inversion (scheduling first, provisioning second) is the entire point of the mode.

### Which to Choose

| Situation | Mode |
|-----------|------|
| NFS or SMB reachable from all nodes (the lab) | `Immediate` |
| `local` PVs | `WaitForFirstConsumer`, effectively mandatory |
| Zonal cloud disks | `WaitForFirstConsumer` |
| Workloads with `nodeSelector`, affinity, taints or GPU constraints | `WaitForFirstConsumer` |
| You want the PVC to show `Bound` before the app is deployed | `Immediate`, accepting the risk |

The cost of `WaitForFirstConsumer` is diagnostic: a `Pending` PVC is now expected, and the interesting question becomes "why is the Pod unschedulable", not "why is the PVC unbound".

---

## Storage Object in Use Protection

Kubernetes protects storage that is actively in use with **finalizers**.

```bash
kubectl get pvc nfs-pvc-web-share -o jsonpath='{.metadata.finalizers}{"\n"}'
# ["kubernetes.io/pvc-protection"]

kubectl get pv nfs-pv-web-share -o jsonpath='{.metadata.finalizers}{"\n"}'
# ["kubernetes.io/pv-protection"]
```

### How a Finalizer Works

```
┌──────────────────────────────────────────────────────────────────────────┐
│                      FINALIZER MECHANICS                                 │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   kubectl delete pvc nfs-pvc-web-share                                   │
│              │                                                           │
│              ▼                                                           │
│   API server sets metadata.deletionTimestamp                             │
│   The object is NOT removed, because finalizers[] is non empty.          │
│              │                                                           │
│              ▼                                                           │
│   Status shows Terminating.  ← this is CORRECT, not a bug                │
│              │                                                           │
│              ▼                                                           │
│   The PVC protection controller asks: is any pod still using this PVC?   │
│        YES ──► do nothing. Object stays Terminating indefinitely.        │
│        NO  ──► remove "kubernetes.io/pvc-protection" from finalizers     │
│                    │                                                     │
│                    ▼                                                     │
│   finalizers[] is now empty ──► API server deletes the object for real   │
│              │                                                           │
│              ▼                                                           │
│   PV reclaim policy takes over: Retain (Released) or Delete (destroyed)  │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

| Finalizer | On | Blocks deletion while |
|-----------|----|-----------------------|
| `kubernetes.io/pvc-protection` | PVC | Any Pod still references the PVC |
| `kubernetes.io/pv-protection` | PV | The PV is still bound to a PVC |
| `external-attacher/<driver>` | VolumeAttachment | The volume is still attached to a node |

### Diagnosing a PVC Stuck in Terminating

The answer is almost always "a Pod is still using it".

```bash
kubectl get pvc <pvc> -n <ns>
# NAME    STATUS        VOLUME     CAPACITY   ACCESS MODES
# data    Terminating   pvc-4a7e   10Gi       RWO

# Who is using it? Search the namespace.
kubectl get pods -n <ns> -o json | jq -r --arg C "<pvc>" '
  .items[]
  | . as $p
  | ($p.spec.volumes // [])[]
  | select(.persistentVolumeClaim.claimName == $C)
  | $p.metadata.name'

# Include pods that are themselves stuck terminating
kubectl get pods -n <ns> --field-selector=status.phase!=Succeeded

# Some controllers keep recreating the pod. Scale the owner down first.
kubectl scale deployment <deploy> -n <ns> --replicas=0
```

Once the last Pod is gone, the finalizer clears and the PVC disappears on its own, usually within seconds.

> 🚨 **Do not force remove the finalizer.** `kubectl patch pvc <pvc> -p '{"metadata":{"finalizers":null}}'` deletes the object while a Pod is still mounting the volume. The kubelet is then left with a mount for an object that no longer exists, and if the reclaim policy is `Delete`, the backend volume can be destroyed underneath a running application. Remove the consumer instead. The only legitimate use is a genuinely orphaned object whose consumers are provably gone.

---

## Reclaiming a Retained PV for Reuse

A `Retain` PV whose claim was deleted sits in `Released`. The data is intact, but the PV will not bind to anything because it still holds a `claimRef` for a PVC that no longer exists.

```bash
kubectl get pv
# NAME               CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM
# nfs-pv-web-share   1Mi        ROX            Retain           Released   default/nfs-pvc-web-share
```

### The Procedure

```bash
# ── 1. Record what you have, before changing anything ───────────────────
kubectl get pv nfs-pv-web-share -o yaml > /tmp/nfs-pv-web-share.backup.yaml

kubectl get pv nfs-pv-web-share -o jsonpath='{.spec.claimRef}' | jq
# {
#   "apiVersion": "v1",
#   "kind": "PersistentVolumeClaim",
#   "name": "nfs-pvc-web-share",
#   "namespace": "default",
#   "uid": "4a3e9f21-..."
# }

# ── 2. Confirm the data is what you expect, on the backend ──────────────
# On the NFS server:
#   ls -la /tux2lab-data/

# ── 3. Clear the claimRef. This is the whole trick. ─────────────────────
kubectl patch pv nfs-pv-web-share -p '{"spec":{"claimRef": null}}'

# ── 4. Verify it is Available again ─────────────────────────────────────
kubectl get pv nfs-pv-web-share
# NAME               CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM
# nfs-pv-web-share   1Mi        ROX            Retain           Available

# ── 5. Create the new claim ─────────────────────────────────────────────
kubectl apply -f nfs-pvc-web-share.yaml
kubectl get pvc nfs-pvc-web-share
# Bound
```

### Pre-binding to a Specific New Claim

To guarantee that one particular claim, and no other, picks up this PV, write a partial `claimRef` **without** a `uid`:

```bash
kubectl patch pv nfs-pv-web-share --type merge -p '
spec:
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: nfs-pvc-web-share
    namespace: production
'
```

A `claimRef` with a name and namespace but no `uid` reserves the PV: only a PVC created with exactly that name in that namespace can bind to it, and the controller fills in the `uid` at bind time. This is the safe way to hand a retained volume to a known consumer without racing other claims.

### Full YAML Alternative

Some administrators prefer to delete and recreate the PV object instead of patching. The data is untouched either way, because a `Retain` PV's deletion does not touch the backend.

```bash
kubectl get pv nfs-pv-web-share -o yaml > /tmp/pv.yaml
# edit /tmp/pv.yaml: remove spec.claimRef, status, metadata.uid,
# metadata.resourceVersion, metadata.creationTimestamp
kubectl delete pv nfs-pv-web-share      # safe: Retain policy, backend untouched
kubectl apply -f /tmp/pv.yaml
```

> ⚠️ Do this only when the reclaim policy really is `Retain`. Deleting a PV with `Delete` triggers `DeleteVolume` on the backend.

### Cleanup Checklist for a Released PV

| Question | Action |
|----------|--------|
| Is the data still needed? | If not, delete the PV and clean the backend directory |
| Should the same app get it back? | Pre-bind with a `claimRef` naming the new PVC |
| Should any claim be able to take it? | Clear `claimRef` entirely |
| Does the old data need wiping first? | Do it on the backend before rebinding; Kubernetes will not do it for you |

---

## Volume Expansion

Growing a volume is a first class operation, subject to driver support.

### Prerequisites

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-tux2lab
provisioner: nfs.csi.k8s.io
allowVolumeExpansion: true       # ← without this, the PVC edit is REJECTED
```

```bash
kubectl get sc -o custom-columns=NAME:.metadata.name,EXPANSION:.allowVolumeExpansion
```

`allowVolumeExpansion` is the one StorageClass field you can change on a live class:

```bash
kubectl patch storageclass nfs-tux2lab -p '{"allowVolumeExpansion": true}'
```

### The Procedure: Edit the PVC, Never the PV

```bash
# ── Check current size ──────────────────────────────────────────────────
kubectl get pvc data -n prod \
  -o custom-columns=NAME:.metadata.name,REQ:.spec.resources.requests.storage,ACTUAL:.status.capacity.storage
# NAME   REQ    ACTUAL
# data   10Gi   10Gi

# ── Request more ────────────────────────────────────────────────────────
kubectl patch pvc data -n prod -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
# or: kubectl edit pvc data -n prod

# ── Watch the conditions ────────────────────────────────────────────────
kubectl get pvc data -n prod -o jsonpath='{.status.conditions}' | jq
```

### The Two Phase Process

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        VOLUME EXPANSION FLOW                                 │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  PHASE 1: GROW THE VOLUME  (control plane, no pod involvement)               │
│                                                                              │
│    user patches PVC 10Gi ──► 20Gi                                            │
│              │                                                               │
│              ▼                                                               │
│    external-resizer sidecar calls ControllerExpandVolume                     │
│              │                                                               │
│              ▼                                                               │
│    backend grows the volume to 20Gi                                          │
│              │                                                               │
│              ▼                                                               │
│    PVC condition: Resizing                                                   │
│                                                                              │
│  PHASE 2: GROW THE FILESYSTEM  (node side)                                   │
│                                                                              │
│    Does the driver support ONLINE expansion?                                 │
│         │                                                                    │
│         ├── YES ──► NodeExpandVolume runs while the pod keeps running        │
│         │           resize2fs / xfs_growfs on the live mount                 │
│         │           ──► status.capacity becomes 20Gi.  DONE.                 │
│         │                                                                    │
│         └── NO  ──► PVC condition: FileSystemResizePending                   │
│                     "Waiting for user to (re-)start a pod to finish          │
│                      file system resize of volume on node."                  │
│                             │                                                │
│                             ▼                                                │
│                     admin deletes / restarts the pod                         │
│                             │                                                │
│                             ▼                                                │
│                     kubelet runs NodeExpandVolume during the next mount      │
│                     ──► status.capacity becomes 20Gi.  DONE.                 │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### The Conditions You Will See

```bash
kubectl get pvc data -n prod -o jsonpath='{.status.conditions}' | jq
```

| Condition type | Meaning | Action |
|----------------|---------|--------|
| `Resizing` | The control plane expansion is in progress | Wait |
| `FileSystemResizePending` | Backend grew, filesystem has not | Restart the Pod (offline drivers) |
| `ControllerResizeError` | `ControllerExpandVolume` failed | Read the resizer logs |
| `NodeResizeError` | `NodeExpandVolume` failed | Read the node plugin logs and the kubelet journal |

### Offline Resize

```bash
# For a Deployment
kubectl rollout restart deployment/<name> -n prod

# For a StatefulSet, delete pods one at a time so the resize happens per replica
kubectl delete pod <sts>-0 -n prod
kubectl rollout status statefulset/<sts> -n prod

# Confirm inside the container
kubectl exec -n prod <pod> -- df -h /var/lib/data
```

### Rules and Restrictions

| Rule | Detail |
|------|--------|
| **You edit the PVC, not the PV** | The PV's capacity is updated by the resizer as a consequence |
| **Shrinking is not supported** | The API rejects a smaller `resources.requests.storage`. There is no supported way to shrink in place. |
| **The class must allow it** | `allowVolumeExpansion: true`, and the driver must implement `EXPAND_VOLUME` |
| **Statically provisioned PVs generally cannot be expanded** | With no provisioner in the loop, grow the backend and update `capacity` by hand, accepting that this is bookkeeping |
| **`volumeClaimTemplates` cannot be edited** | Patch each StatefulSet PVC individually, then recreate the StatefulSet with `--cascade=orphan` so new replicas get the larger size |
| **Raw block volumes** | Expansion grows the device; the application (or a filesystem inside it) must handle the rest |

To shrink, the only path is: create a new smaller PVC, copy the data, switch the workload, delete the old one.

### Recovering From a Failed Expansion

Some clusters allow reducing `spec.resources.requests.storage` back down **towards the currently allocated size** after a failed expansion, so that a Pod is not permanently blocked by a request the backend cannot satisfy. Availability depends on the feature being enabled in your version, so verify before relying on it:

```bash
kubectl get pvc data -n prod -o jsonpath='{.status.allocatedResources}' | jq
kubectl get pvc data -n prod -o jsonpath='{.status.allocatedResourceStatuses}' | jq
```

---

## Raw Block Volumes

Give a container a device node instead of a mounted filesystem.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: block-pv-01
spec:
  capacity:
    storage: 100Gi
  volumeMode: Block                 # ← no filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: block-storage
  csi:
    driver: some.block.csi.driver.example.com
    volumeHandle: lun-000123
    # fsType is meaningless for Block, leave it out
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: block-pvc
spec:
  volumeMode: Block                 # MUST match the PV
  accessModes:
    - ReadWriteOnce
  storageClassName: block-storage
  resources:
    requests:
      storage: 100Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: block-consumer
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "ls -l /dev/xvda; sleep 3600"]
      volumeDevices:                # ← volumeDevices, NOT volumeMounts
        - name: raw
          devicePath: /dev/xvda     # ← devicePath, NOT mountPath
      securityContext:
        privileged: false           # a device node does not require privilege
  volumes:
    - name: raw
      persistentVolumeClaim:
        claimName: block-pvc
```

### volumeMounts vs volumeDevices

| | `volumeMounts` | `volumeDevices` |
|---|---------------|-----------------|
| Path field | `mountPath` | `devicePath` |
| Requires `volumeMode` | `Filesystem` | `Block` |
| `subPath` | ✅ | ❌ not applicable |
| `readOnly` | ✅ | ❌ not applicable |
| `fsGroup` applies | ✅ | ❌ |
| SELinux relabelling | ✅ | ❌ |
| What the container sees | A directory | A device node such as `/dev/xvda` |

A container may use both, for different volumes.

### When Raw Block Is Right

| Use case | Why |
|----------|-----|
| Databases with their own storage engine | Bypasses the page cache and filesystem overhead |
| Software defined storage running in Pods | It needs raw devices to manage |
| LVM, DRBD or custom volume management inside a Pod | The filesystem layer would be in the way |
| Applications that require O_DIRECT and precise I/O control | Filesystem semantics get in the way |

For everything else, `Filesystem` is correct. Raw block gives up `fsGroup`, SELinux relabelling, `subPath`, and the ability to inspect the data with ordinary tools.

```bash
kubectl exec block-consumer -- ls -l /dev/xvda
# brw-rw---- 1 root disk 202, 0 Sep  1 12:00 /dev/xvda

kubectl get pv -o custom-columns=NAME:.metadata.name,MODE:.spec.volumeMode
```

---

## PVCs in StatefulSets

A StatefulSet does not create PersistentVolumes. It creates **PersistentVolumeClaims** from a template, one per replica, with deterministic names.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: store
  namespace: datastore
spec:
  serviceName: store-peers
  replicas: 3
  selector:
    matchLabels: { app: store }
  template:
    metadata:
      labels: { app: store }
    spec:
      containers:
        - name: store
          image: busybox:1.36
          command: ["sh", "-c", "echo $(hostname) > /var/lib/data/id; sleep 86400"]
          volumeMounts:
            - name: data
              mountPath: /var/lib/data
  volumeClaimTemplates:
    - metadata:
        name: data                       # ← the FIRST part of the PVC name
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: nfs-tux2lab
        resources:
          requests:
            storage: 10Gi
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain                  # Retain | Delete
    whenScaled: Retain                   # Retain | Delete
```

### The Generated Names

```
   PVC name = <volumeClaimTemplate.metadata.name>-<statefulset.name>-<ordinal>

   volumeClaimTemplate name: data
   StatefulSet name:         store
   Replicas:                 3

   ──►  data-store-0
        data-store-1
        data-store-2
```

```bash
kubectl get pvc -n datastore
# NAME           STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS
# data-store-0   Bound    pvc-1a2b...  10Gi       RWO            nfs-tux2lab
# data-store-1   Bound    pvc-3c4d...  10Gi       RWO            nfs-tux2lab
# data-store-2   Bound    pvc-5e6f...  10Gi       RWO            nfs-tux2lab
```

The template name comes **first**. `store-data-0` is wrong, and this is a favourite exam question.

### Why the Deterministic Name Is the Whole Point

```
   store-1 is deleted, rescheduled to a different node
        │
        ▼
   controller recreates a pod named exactly store-1
        │
        ▼
   its volumeClaimTemplate resolves to exactly data-store-1
        │
        ▼
   data-store-1 already exists and is still Bound to the same PV
        │
        ▼
   the SAME data is remounted. Identity preserved.
```

That single deterministic mapping is the mechanism behind stateful reattachment. It is also what lets you restore a replica by pre-creating `data-store-1` from a snapshot before scaling up.

### Retention Policy

| `whenDeleted` | `whenScaled` | Behaviour |
|---------------|--------------|-----------|
| `Retain` | `Retain` | Default. PVCs survive everything. Safest, and accumulates orphans. |
| `Delete` | `Retain` | PVCs removed when the StatefulSet is deleted, kept on scale down |
| `Retain` | `Delete` | PVCs of removed replicas are deleted; scaling back up provisions fresh empty ones |
| `Delete` | `Delete` | Fully automatic cleanup. Only for genuinely disposable data. |

This is a **second, independent** layer on top of the PV's `persistentVolumeReclaimPolicy`. Deleting the PVC only destroys data if the PV's policy is `Delete`.

```bash
kubectl get sts store -n datastore -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}' | jq
```

`volumeClaimTemplates` is immutable. Expanding storage for an existing StatefulSet means patching each PVC individually, then recreating the StatefulSet object with `--cascade=orphan` so future replicas inherit the new size.

> 📖 **Full detail**: [statefulsets.md](statefulsets.md)

---

## Static Provisioning Walkthrough on NFS

This follows the repository's own `k8s-workshop` manifests end to end.

### Step 0: The Backend

```bash
# On tux2lab-engine
sudo mkdir -p /tux2lab-data
sudo chown -R nobody:nogroup /tux2lab-data    # or the UID the pods will use

# /etc/exports
#   /tux2lab-data  10.0.0.0/24(rw,sync,no_subtree_check,root_squash)
sudo exportfs -ra
sudo exportfs -v
showmount -e localhost
```

Every worker node needs the NFS client packages, or `NodeStageVolume` fails:

```bash
# Debian family
sudo apt-get install -y nfs-common
# Red Hat family
sudo dnf install -y nfs-utils
# SUSE family
sudo zypper install -y nfs-client

# Prove the node can mount it, outside Kubernetes, before blaming Kubernetes
sudo mkdir -p /mnt/probe
sudo mount -t nfs -o vers=4.1 tux2lab-engine.user.internal:/tux2lab-data /mnt/probe
ls /mnt/probe && sudo umount /mnt/probe
```

### Step 1: The PersistentVolume

`k8s-workshop/nfs-pv-web-share.yaml`, with `__NFS_SERVER__` substituted by the apply script:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv-web-share
spec:
  capacity:
    storage: 1Mi                    # bookkeeping; NFS enforces nothing here
  accessModes:
    - ReadOnlyMany                  # many nodes, read only: shared web content
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: nfs-web-share     # must be unique in the cluster
    volumeAttributes:
      server: __NFS_SERVER__        # tux2lab-engine.<domain>
      share: /tux2lab-data
```

Three deliberate choices worth understanding:

| Choice | Why it is correct here |
|--------|------------------------|
| `capacity: 1Mi` | Directory based NFS has no quota, so any number is fiction. A small one avoids implying a guarantee that does not exist. |
| `ReadOnlyMany` | Static site content served by many replicas across many nodes, with no writer. Removes an entire class of corruption risk. |
| No `storageClassName` | Class is empty, so it pairs with a claim that also has no class. Combined with `volumeName`, binding is fully deterministic. |
| No `persistentVolumeReclaimPolicy` | Defaults to `Retain`, which is what you want for a hand written PV over a shared export. Deleting the claim must never delete the lab's data. |

### Step 2: The PersistentVolumeClaim

`k8s-workshop/nfs-pvc-web-share.yaml`:

```yaml
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
  volumeName: nfs-pv-web-share      # explicit, deterministic binding
```

`volumeName` is doing important work: because the cluster may have a default StorageClass, omitting both `storageClassName` and `volumeName` would let the admission controller inject the default class, and the claim would dynamically provision a brand new volume instead of binding to this PV. Naming the volume removes all ambiguity.

### Step 3: Apply

```bash
cd k8s-workshop
./apply-nfs-setup.sh user.internal

# The script substitutes __DOMAIN__ and __NFS_SERVER__ into the PV, then
# applies both objects.

kubectl get pv nfs-pv-web-share
# NAME               CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM
# nfs-pv-web-share   1Mi        ROX            Retain           Bound    default/nfs-pvc-web-share

kubectl get pvc nfs-pvc-web-share
# NAME                STATUS   VOLUME             CAPACITY   ACCESS MODES
# nfs-pvc-web-share   Bound    nfs-pv-web-share   1Mi        ROX
```

### Step 4: Consume It From Several Pods

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
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

```bash
kubectl apply -f web-deploy.yaml
kubectl get pods -l app=web -o wide      # three pods, likely three different nodes

for p in $(kubectl get pods -l app=web -o name); do
  echo "== $p"
  kubectl exec "$p" -- ls /usr/share/nginx/html
done
# identical content everywhere: that is ReadOnlyMany working
```

Write a file on the NFS server and every Pod sees it immediately, with no rollout:

```bash
# On tux2lab-engine
echo "<h1>updated $(date)</h1>" | sudo tee /tux2lab-data/index.html
```

```bash
kubectl exec deploy/web -- cat /usr/share/nginx/html/index.html
```

### Step 5: Prove Read Only Is Enforced

```bash
kubectl exec deploy/web -- touch /usr/share/nginx/html/probe
# touch: /usr/share/nginx/html/probe: Read-only file system
```

### Step 6: Teardown and What Survives

```bash
cd k8s-workshop
./delete-nfs-setup.sh

kubectl get pv nfs-pv-web-share
# either gone (if the script deletes it) or Released
```

If the PV remains `Released`, the data on `/tux2lab-data` is untouched, and the PV is recycled with the `claimRef` clearing procedure described in [Reclaiming a Retained PV for Reuse](#reclaiming-a-retained-pv-for-reuse).

---

## Dynamic Provisioning Walkthrough

The same backend, but every claim gets its own subdirectory, created automatically.

### Step 1: The StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-tux2lab
provisioner: nfs.csi.k8s.io
parameters:
  server: tux2lab-engine.user.internal
  share: /tux2lab-data
  # Templated subdirectory, so each claim is isolated on the export
  subDir: ${pvc.metadata.namespace}-${pvc.metadata.name}-${pvc.metadata.uid}
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
  - hard
  - noatime
```

```bash
kubectl apply -f sc-nfs.yaml
kubectl get sc nfs-tux2lab
```

### Step 2: A Claim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
  namespace: apps
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-tux2lab
  resources:
    requests:
      storage: 5Gi
```

```bash
kubectl create namespace apps
kubectl apply -f pvc.yaml

kubectl get pvc app-data -n apps -w
# Pending → Bound, usually within a couple of seconds

kubectl get pvc app-data -n apps -o jsonpath='{.spec.volumeName}{"\n"}'
# pvc-9c1f7a2e-...      ← auto generated, always pvc-<pvc-uid>
```

### Step 3: Inspect the Generated PV

```bash
kubectl get pv pvc-9c1f7a2e-... -o yaml
```

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pvc-9c1f7a2e-...
  annotations:
    pv.kubernetes.io/provisioned-by: nfs.csi.k8s.io      # ← the tell
  finalizers:
    - kubernetes.io/pv-protection
spec:
  capacity:
    storage: 5Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Delete                   # ← from the class
  storageClassName: nfs-tux2lab
  mountOptions: [nfsvers=4.1, hard, noatime]              # ← from the class
  claimRef:
    kind: PersistentVolumeClaim
    namespace: apps
    name: app-data
    uid: 9c1f7a2e-...
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: tux2lab-engine.user.internal#tux2lab-data#apps-app-data-...
    volumeAttributes:
      server: tux2lab-engine.user.internal
      share: /tux2lab-data
      subDir: apps-app-data-9c1f7a2e-...
```

Everything an admin would have hand written was generated from the class.

### Step 4: Verify on the Server

```bash
# On tux2lab-engine
ls -la /tux2lab-data/
# drwxr-xr-x  apps-app-data-9c1f7a2e-.../     ← created by the provisioner
```

### Step 5: Watch the Delete Reclaim Policy Work

```bash
kubectl delete pvc app-data -n apps

kubectl get pv | grep pvc-9c1f7a2e
# gone within seconds
```

```bash
# On tux2lab-engine
ls -la /tux2lab-data/
# the subdirectory is gone too. The data is DESTROYED.
```

This is exactly the behaviour you want for scratch, and exactly the behaviour that loses a production database. Protect anything valuable:

```bash
kubectl patch pv $(kubectl get pvc app-data -n apps -o jsonpath='{.spec.volumeName}') \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

### Static vs Dynamic on the Same Backend

| | Static (`nfs-pv-web-share`) | Dynamic (`nfs-tux2lab`) |
|---|---------------------------|-------------------------|
| Who creates the PV | Admin, by hand | The provisioner |
| PV name | Chosen, meaningful | `pvc-<uid>` |
| Backend layout | One shared directory for everyone | One subdirectory per claim |
| Default reclaim policy | `Retain` | Inherited from the class (`Delete` here) |
| Sharing | Intentional, all consumers see the same files | Isolated by default |
| Right for | Shared read only content, pre-existing data | Self service application storage |

---

## Quotas and Limits on Storage

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: storage-quota
  namespace: apps
spec:
  hard:
    persistentvolumeclaims: "10"                                    # count
    requests.storage: 100Gi                                         # total
    # Per class limits
    nfs-tux2lab.storageclass.storage.k8s.io/requests.storage: 50Gi
    nfs-tux2lab.storageclass.storage.k8s.io/persistentvolumeclaims: "5"
    # Local ephemeral storage, which is a different resource entirely
    requests.ephemeral-storage: 20Gi
    limits.ephemeral-storage: 40Gi
```

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: storage-limits
  namespace: apps
spec:
  limits:
    - type: PersistentVolumeClaim
      min:
        storage: 1Gi          # reject tiny claims
      max:
        storage: 100Gi        # reject oversized claims
```

```bash
kubectl describe quota storage-quota -n apps
# Name:                                                     storage-quota
# Resource                                                  Used   Hard
# persistentvolumeclaims                                    3      10
# requests.storage                                          25Gi   100Gi
# nfs-tux2lab.storageclass.storage.k8s.io/requests.storage  25Gi   50Gi
```

Note that quota counts **PVC requests**, not actual backend consumption. A namespace can be well under quota while filling the NFS export, because directory based NFS provisioning does not enforce `capacity.storage`. Real enforcement has to come from the storage backend, for example filesystem quotas on the export.

---

## Troubleshooting

### Symptom 1: PVC Stuck in Pending

```bash
kubectl describe pvc <pvc> -n <ns> | sed -n '/Events/,$p'
kubectl get sc
kubectl get pv | grep -i available
```

| Event | Cause | Fix |
|-------|-------|-----|
| `no persistent volumes available for this claim and no storage class is set` | No matching PV, and nothing to provision from | Create a matching PV, set `storageClassName`, or mark a default class |
| `storageclass.storage.k8s.io "x" not found` | The class does not exist here | `kubectl get sc` and correct the name |
| `waiting for first consumer to be created before binding` | `WaitForFirstConsumer` | Expected. Debug why no Pod is being scheduled. |
| `failed to provision volume with StorageClass "x"` | Provisioner error: credentials, quota, backend down | `kubectl logs -n kube-system -l app=csi-nfs-controller -c csi-provisioner` |
| `Failed to bind volumes: node(s) had volume node affinity conflict` | The PV is pinned to nodes the Pod cannot use | Fix affinity, or recreate the volume with `WaitForFirstConsumer` |
| **No events at all** | Nothing is watching that class | Confirm the driver Pods are Running and `provisioner` matches the `CSIDriver` name |

When a static PV exists but will not bind, compare every criterion explicitly:

```bash
kubectl get pv <pv> -o jsonpath='{.spec.accessModes}{"\n"}{.spec.capacity.storage}{"\n"}{.spec.storageClassName}{"\n"}{.spec.volumeMode}{"\n"}{.spec.claimRef}{"\n"}'
kubectl get pvc <pvc> -n <ns> -o jsonpath='{.spec.accessModes}{"\n"}{.spec.resources.requests.storage}{"\n"}{.spec.storageClassName}{"\n"}{.spec.volumeMode}{"\n"}'
```

The usual culprits, in order of frequency: an injected default class on the PVC that the PV does not have; a `volumeMode` mismatch; a stale `claimRef` on the PV; an access mode the PV does not offer.

### Symptom 2: PV Stuck in Released

Expected behaviour with `Retain`, not an error. The PV holds a `claimRef` for a deleted PVC.

```bash
kubectl get pv <pv> -o jsonpath='{.spec.claimRef}' | jq
kubectl get pv <pv> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
```

Decide, then act: clear `claimRef` to make it `Available`, pre-bind it to a specific new PVC, or delete the PV and clean the backend. Full procedure in [Reclaiming a Retained PV for Reuse](#reclaiming-a-retained-pv-for-reuse).

If the phase is `Failed` rather than `Released`, automatic reclamation itself failed:

```bash
kubectl describe pv <pv> | sed -n '/Events/,$p'
kubectl logs -n kube-system -l app=csi-nfs-controller --tail=100
```

### Symptom 3: Pod Stuck in ContainerCreating on a Mount Error

```bash
kubectl describe pod <pod> -n <ns> | sed -n '/Events/,$p'
NODE=$(kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.nodeName}')
```

| Message | Cause | Fix |
|---------|-------|-----|
| `access denied by server while mounting` | The export does not allow this node's IP | Edit `/etc/exports`, `exportfs -ra` |
| `bad option; ... helper program` | NFS or SMB client packages missing on the node | Install them on **every** worker |
| `an incorrect mount option was specified` | A bad entry in `mountOptions` | Test the mount by hand on the node first |
| `no such host` | Node DNS cannot resolve the server | Fix DNS or use an IP |
| `no such file or directory` | The `share` or `subDir` path does not exist on the server | Create it, check the exact spelling |
| `operation not permitted` | SELinux, or root squash on NFS | Check `ausearch -m avc -ts recent`, and the export options |
| `timeout expired waiting for volumes to attach or mount` | Backend unreachable, driver crashed | Check the CSI node plugin Pod on that node |

Always try the mount manually on the node. It separates a Kubernetes problem from a storage problem in one command:

```bash
sudo mount -t nfs -o vers=4.1 tux2lab-engine.user.internal:/tux2lab-data /mnt/probe
```

If that fails, the problem is not Kubernetes.

```bash
kubectl logs -n kube-system -l app=csi-nfs-node --field-selector spec.nodeName="$NODE" -c nfs --tail=100
journalctl -u kubelet --since "10 min ago" | grep -iE 'volume|mount'
```

### Symptom 4: Multi-Attach Error

```
Warning  FailedAttachVolume  Multi-Attach error for volume "pvc-4a7e..."
         Volume is already exclusively attached to one node and can't be
         attached to another
```

An RWO volume is still attached to another node, usually because a Pod there is stuck `Terminating` after a node failure.

```bash
kubectl get volumeattachments | grep pvc-4a7e
kubectl get pods -A -o wide | grep -i terminating
kubectl get nodes
```

| Situation | Correct action |
|-----------|----------------|
| The old Pod is terminating gracefully on a healthy node | Wait |
| A Deployment with `RollingUpdate` and an RWO volume | Switch the strategy to `Recreate`, so the old Pod is fully gone first |
| The node is genuinely dead | Apply the `node.kubernetes.io/out-of-service` taint, or delete the Node object, both of which force detachment |
| The node is only network partitioned | **Do not force anything.** Two writers on one volume is how filesystems get destroyed. |

Note that this error class does not occur with drivers that set `attachRequired: false`, which includes `nfs.csi.k8s.io`. That is one of the practical benefits of file based storage in a home lab.

### Symptom 5: PVC Stuck in Terminating

```bash
kubectl get pvc <pvc> -n <ns> -o jsonpath='{.metadata.finalizers}{"\n"}'
# ["kubernetes.io/pvc-protection"]

# Find the consumer
kubectl get pods -n <ns> -o json | jq -r --arg C "<pvc>" '
  .items[] | . as $p | ($p.spec.volumes // [])[]
  | select(.persistentVolumeClaim.claimName == $C) | $p.metadata.name'

# A controller may keep recreating it
kubectl get deploy,sts,ds -n <ns>
kubectl scale deployment <deploy> -n <ns> --replicas=0
```

Removing the last consumer clears the finalizer automatically. Force removing the finalizer is a last resort and is dangerous while any mount exists, as described in [Storage Object in Use Protection](#storage-object-in-use-protection).

### Symptom 6: PVC Phase Is Lost

The bound PV no longer exists.

```bash
kubectl get pvc <pvc> -n <ns>
# STATUS: Lost
kubectl get pvc <pvc> -n <ns> -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl get pv <that-name>
# Error from server (NotFound)
```

Someone deleted the PV out from under the claim. The claim is unusable. If the backend data still exists (a `Retain` PV that was deleted as an object), recreate the PV with the same backend coordinates and pre-bind it with a `claimRef` naming the existing PVC. Otherwise delete the PVC and start again, restoring from backup.

### Symptom 7: Expansion Not Taking Effect

```bash
kubectl get pvc <pvc> -n <ns> -o jsonpath='{.status.conditions}' | jq
kubectl get sc <class> -o jsonpath='{.allowVolumeExpansion}{"\n"}'
kubectl logs -n kube-system -l app=csi-nfs-controller -c csi-resizer --tail=100
```

`FileSystemResizePending` means the backend grew and the filesystem has not. Restart the Pod. If `allowVolumeExpansion` is absent or false, the PVC edit was rejected outright and there is nothing in progress. If the PV was statically provisioned, there is no resizer in the loop at all.

### Symptom 8: Wrong PV Bound, or a Brand New Volume Appeared

```bash
kubectl get pvc <pvc> -n <ns> -o yaml | grep -A2 storageClassName
```

Almost certainly the default StorageClass being injected because `storageClassName` was omitted. Delete the PVC (confirm the reclaim policy first), set `storageClassName: ""` and `volumeName`, and reapply.

### A General Diagnostic Sequence

```bash
NS=<namespace>; PVC=<pvc>; POD=<pod>

kubectl get pvc "$PVC" -n "$NS" -o wide
kubectl describe pvc "$PVC" -n "$NS" | sed -n '/Events/,$p'

PV=$(kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.spec.volumeName}')
kubectl get pv "$PV" -o wide
kubectl describe pv "$PV" | sed -n '/Events/,$p'

kubectl describe pod "$POD" -n "$NS" | sed -n '/Events/,$p'

kubectl get csidrivers
kubectl get pods -n kube-system -l app=csi-nfs-controller
kubectl get pods -n kube-system -l app=csi-nfs-node -o wide

NODE=$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')
echo "pod is on $NODE"
# then, on that node:
#   journalctl -u kubelet --since "10 min ago" | grep -iE 'volume|mount'
#   mount | grep kubelet
```

---

## Exam and Interview Traps

1. **PV is cluster scoped, PVC is namespaced.** A Pod can only use a PVC in its own namespace.
2. **`apiVersion: v1` for PersistentVolume, PersistentVolumeClaim and Pod.** `storage.k8s.io/v1` for StorageClass, CSIDriver, CSINode and VolumeAttachment.
3. **Binding is one to one and exclusive.** Unused capacity in a bound PV is wasted and cannot be claimed by anyone else.
4. **A 10Gi PVC can bind to a 100Gi PV.** Capacity matching is "at least", and the claim then owns the whole PV.
5. **The controller picks the smallest sufficient PV**, not the first one it finds.
6. **The PVC's `accessModes` must be a subset of the PV's list**, not equal to it.
7. **`volumeMode` must match exactly.** A `Block` PV never binds to a `Filesystem` PVC.
8. **Omitting `storageClassName` is not the same as `storageClassName: ""`.** Omitted means "use the default class"; empty means "no class at all".
9. **`selector` is ignored during dynamic provisioning.** A PVC with a selector and a provisionable class waits for a static PV that never appears.
10. **`volumeName` is the deterministic way to bind a static pair** and is immutable once bound.
11. **The default reclaim policy is `Retain` for a hand written PV and `Delete` for a dynamically provisioned one** (inherited from the StorageClass).
12. **`Recycle` is deprecated.** The answers are `Retain` and `Delete`.
13. **`persistentVolumeReclaimPolicy` is mutable**, including after the PV is `Released`. Patching it is a standard safety move.
14. **A `Released` PV cannot be reused until `spec.claimRef` is cleared**, even though it is completely idle.
15. **A `claimRef` with a name and namespace but no `uid` pre-binds** a PV to a specific future claim.
16. **`kubernetes.io/pvc-protection` is why a PVC sits in `Terminating`** while a Pod still uses it. That is correct behaviour, not a bug.
17. **Never force remove a storage finalizer** while a Pod is mounting the volume.
18. **Expansion is done by editing the PVC, never the PV**, and requires `allowVolumeExpansion: true` on the class.
19. **Shrinking a volume is not supported.** Copy to a smaller volume instead.
20. **`FileSystemResizePending` means restart the Pod**, because the driver does not support online filesystem expansion.
21. **`allowVolumeExpansion` is the only StorageClass field that can be changed on a live class.**
22. **Raw block volumes use `volumeDevices` and `devicePath`**, not `volumeMounts` and `mountPath`, and give up `fsGroup`, `subPath` and SELinux relabelling.
23. **StatefulSet PVC names are `<template>-<statefulset>-<ordinal>`.** The template name comes first.
24. **A StatefulSet creates PVCs, never PVs.** A provisioner creates the PVs.
25. **`volumeClaimTemplates` is immutable.** Patch each PVC and recreate the StatefulSet with `--cascade=orphan`.
26. **`persistentVolumeClaimRetentionPolicy` and `persistentVolumeReclaimPolicy` are two independent layers.** PVC deletion only destroys data when the PV's policy is `Delete`.
27. **`WaitForFirstConsumer` delays binding until the scheduler picks a node**, which is what prevents the zone conflict deadlock. The scheduler records its decision in the `volume.kubernetes.io/selected-node` annotation.
28. **`local` PVs require `nodeAffinity`.** `hostPath` has none, which is exactly why it is unsafe for data.
29. **Dynamically provisioned PVs are named `pvc-<pvc-uid>`** and carry the `pv.kubernetes.io/provisioned-by` annotation.
30. **`ResourceQuota` counts PVC requests, not backend usage.** On directory based NFS, `capacity.storage` is not enforced at all.
31. **PVC phases are `Pending`, `Bound`, `Lost`.** PV phases are `Available`, `Bound`, `Released`, `Failed`.
32. **`status.capacity` on a PVC is what was actually granted**, which can exceed `spec.resources.requests.storage`.
33. **Multi-attach errors only occur with drivers that require attachment.** NFS style drivers set `attachRequired: false` and never produce them.
34. **A Deployment with `RollingUpdate` and an RWO volume deadlocks on itself**: the new Pod cannot attach until the old one is fully gone. Use `Recreate`.

---

## Related Topics

- [Storage Overview](storage.md)
- [Volumes](volumes.md)
- [StatefulSets](statefulsets.md)
- [Pods](pods.md)
- [Pod Lifecycle](pod-lifecycle.md)
- [Deployments](deployments.md)
- [Controllers](controllers.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-scheduler](kube-scheduler.md)
- [kubelet](kubelet.md)
- [Container Runtime](container-runtime.md)
- [ConfigMaps](configmaps.md)
- [Secrets](secrets.md)
- [Installing the NFS CSI Driver](install-csi-nfs.md)
- [Installing the SMB CSI Driver](install-csi-smb.md)
- [Kubernetes API](k8s-api.md)
- [etcd](etcd.md)

---

## Key Takeaways

1. A PersistentVolume is a cluster scoped resource describing real storage; a PersistentVolumeClaim is a namespaced request for storage. That split is what keeps application manifests portable across clusters with completely different backends.
2. Binding is exclusive and one to one. Many Pods can share one PVC, but two PVCs can never share one PV, and unused capacity in a bound PV is unavailable to anyone else.
3. The controller matches on access modes (subset), capacity (at least), storage class (exact), volume mode (exact), label selector and `claimRef`, then picks the smallest sufficient PV.
4. `storageClassName` has three distinct meanings: omitted means the default class is injected, `""` means no class and no dynamic provisioning, and a name means that class. Getting this wrong is the most common reason a static PV never binds.
5. `volumeName` is the deterministic way to pair a hand written PV and PVC, which is exactly why the lab's `nfs-pvc-web-share` uses it.
6. The reclaim policy decides what happens after the claim is deleted: `Retain` keeps the PV and the data in a `Released` state, `Delete` destroys the backend volume, and `Recycle` is deprecated. It is mutable, so patch it to `Retain` before doing anything risky.
7. A `Released` PV is reusable only after `spec.claimRef` is cleared. Setting a `claimRef` with a name and namespace but no `uid` reserves the volume for one specific future claim.
8. `WaitForFirstConsumer` inverts the order: the scheduler picks a node first, records it in the `volume.kubernetes.io/selected-node` annotation, and only then is the volume provisioned in the right topology. It is effectively mandatory for `local` PVs and zonal storage.
9. `kubernetes.io/pvc-protection` and `kubernetes.io/pv-protection` finalizers are why storage objects sit in `Terminating`. That is correct behaviour; remove the consumer rather than the finalizer.
10. Expansion means editing the PVC, with `allowVolumeExpansion: true` on the class. Watch for `FileSystemResizePending`, which means the driver needs a Pod restart to finish. Shrinking is not supported at all.
11. Raw block volumes use `volumeDevices` and `devicePath` with `volumeMode: Block` on both objects, and give up `fsGroup`, `subPath` and SELinux relabelling in exchange for direct device access.
12. StatefulSets create PVCs from `volumeClaimTemplates`, named `<template>-<statefulset>-<ordinal>`. That deterministic name is the entire mechanism behind stateful reattachment, and `persistentVolumeClaimRetentionPolicy` is a second layer on top of the PV's reclaim policy.
13. On the lab's NFS setup, static provisioning with `ReadOnlyMany` and `volumeName` gives many Pods across many nodes an identical, unwriteable view of `/tux2lab-data`, while a StorageClass with a templated `subDir` gives every claim its own isolated directory.
14. `capacity.storage` on directory based NFS is bookkeeping, not enforcement. Real limits come from filesystem quotas on the server; `ResourceQuota` only limits what claims may ask for.
15. Troubleshoot in a fixed order: PVC events, PV status and `claimRef`, Pod events, CSI controller logs, CSI node logs, kubelet journal, then a manual mount on the node to prove whether the problem is Kubernetes at all.

---

## References

- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Dynamic Volume Provisioning](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)
- [Volume Binding Mode](https://kubernetes.io/docs/concepts/storage/storage-classes/#volume-binding-mode)
- [Reclaiming](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#reclaiming)
- [Storage Object in Use Protection](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#storage-object-in-use-protection)
- [Expanding Persistent Volumes Claims](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims)
- [Raw Block Volume Support](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#raw-block-volume-support)
- [Node Affinity for local volumes](https://kubernetes.io/docs/concepts/storage/volumes/#local)
- [Configure a Pod to Use a PersistentVolume for Storage](https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/)
- [Change the default StorageClass](https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/)
- [Change the Reclaim Policy of a PersistentVolume](https://kubernetes.io/docs/tasks/administer-cluster/change-pv-reclaim-policy/)
- [Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
- [CSI Volume Cloning](https://kubernetes.io/docs/concepts/storage/volume-pvc-datasource/)
- [Storage Capacity](https://kubernetes.io/docs/concepts/storage/storage-capacity/)
- [Resource Quotas for storage](https://kubernetes.io/docs/concepts/policy/resource-quotas/#storage-resource-quota)
- [StatefulSet volumeClaimTemplates](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#stable-storage)
- [StatefulSet PVC retention policy](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#persistentvolumeclaim-retention)
- [Non Graceful Node Shutdown](https://kubernetes.io/docs/concepts/architecture/nodes/#non-graceful-node-shutdown)
- [PersistentVolume API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/persistent-volume-v1/)
- [PersistentVolumeClaim API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/persistent-volume-claim-v1/)
- [StorageClass API reference (storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/storage-class-v1/)
- [Kubernetes CSI Developer Documentation](https://kubernetes-csi.github.io/docs/)
