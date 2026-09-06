# 📸 Volume Snapshots: Point in Time Copies as a Kubernetes API

A complete guide to VolumeSnapshot, VolumeSnapshotContent and VolumeSnapshotClass: how a CSI driver's snapshot capability becomes three Kubernetes objects, how restore and clone actually work, and why a snapshot is not a backup.

## 📋 Table of Contents
- [What a Volume Snapshot Is](#what-a-volume-snapshot-is)
- [Snapshots Are Not Backups](#snapshots-are-not-backups)
- [The Architecture: Two Controllers and Three CRDs](#the-architecture-two-controllers-and-three-crds)
- [Installing the CRDs and the Snapshot Controller](#installing-the-crds-and-the-snapshot-controller)
- [VolumeSnapshotClass](#volumesnapshotclass)
- [VolumeSnapshot](#volumesnapshot)
- [VolumeSnapshotContent](#volumesnapshotcontent)
- [The Dynamic Snapshot Flow](#the-dynamic-snapshot-flow)
- [The Pre-Provisioned (Static) Flow](#the-pre-provisioned-static-flow)
- [Snapshot Status Fields](#snapshot-status-fields)
- [Restoring From a Snapshot](#restoring-from-a-snapshot)
- [Cloning a PVC](#cloning-a-pvc)
- [dataSource vs dataSourceRef](#datasource-vs-datasourceref)
- [Application Consistency](#application-consistency)
- [A Complete Worked Walkthrough](#a-complete-worked-walkthrough)
- [Retention, Deletion Policy and Finalizers](#retention-deletion-policy-and-finalizers)
- [Backup Tooling Context](#backup-tooling-context)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What a Volume Snapshot Is

A **volume snapshot** is a point in time copy of a volume, taken by the storage backend, exposed to Kubernetes as an API object. The backend does the work; Kubernetes provides the vocabulary, the lifecycle and the RBAC.

```
┌───────────────────────────────────────────────────────────────────────────┐
│   t=0    PVC "postgres-data"                                              │
│          ┌──────────────────────────────────────┐                         │
│          │  users.db  orders.db  wal/000001     │                         │
│          └──────────────────────────────────────┘                         │
│   t=0    kubectl apply -f snapshot.yaml   ──►  CreateSnapshot RPC         │
│          ┌──────────────────────────────────────┐                         │
│          │  SNAPSHOT snap-2026-09-05            │  frozen image of the    │
│          │  users.db  orders.db  wal/000001     │  volume at t=0          │
│          └──────────────────────────────────────┘                         │
│   t=1    the live volume keeps changing                                   │
│          ┌──────────────────────────────────────┐                         │
│          │  users.db' orders.db' wal/000002     │                         │
│          └──────────────────────────────────────┘                         │
│          The snapshot still shows t=0. It is immutable.                   │
└───────────────────────────────────────────────────────────────────────────┘
```

### Why It Exists as an API

Every storage system has always had snapshots. What Kubernetes adds is that a snapshot becomes **declarative** (a YAML object a GitOps pipeline can manage), **namespaced and RBAC controlled** (a team can snapshot its own volumes without an account on the SAN), **portable in shape** (the same three objects work for every CSI driver implementing `CreateSnapshot`), and **composable** (a snapshot is a valid `dataSource` for a new PVC, which makes restore and clone one-liners).

### What It Is Not

A VolumeSnapshot is **not** a file you can download, **not** a copy on different hardware, **not** a mountable volume (you must restore into a new PVC first), **not** application consistent by default, **not** portable between CSI drivers, and **not** available without installing CRDs and a controller separately. The last two cause the most surprise, and both get their own sections below.

### Implementation Varies Wildly

The specification says "point in time copy". It does not say how.

| Backend style | Typical mechanism | Create time | Space cost |
|---------------|-------------------|-------------|------------|
| Copy on write (LVM, ZFS, many SANs) | Metadata only, blocks shared | Milliseconds | Grows as the source changes |
| Redirect on write | New writes go elsewhere | Milliseconds | Grows as the source changes |
| Full copy | Byte-for-byte duplicate | Minutes to hours | 100% of the source |
| Cloud disk snapshot | Copied to object storage asynchronously | Seconds to return, minutes to be usable | Incremental after the first |

The visible Kubernetes consequence is `readyToUse`. A driver whose backend is asynchronous returns immediately with `readyToUse: false`, and the snapshot becomes usable minutes later. Any script that snapshots and then immediately restores must wait for that field.

---

## Snapshots Are Not Backups

The single most important idea here, and the one most often ignored until an outage teaches it.

```
┌═══════════════════════════════════════════════════════════════════════════┐
║  A SNAPSHOT LIVES ON THE SAME STORAGE BACKEND AS THE VOLUME IT COPIES.    ║
║  IT SHARES THE VOLUME'S FAILURE DOMAIN.                                   ║
╚═══════════════════════════════════════════════════════════════════════════┝

   ┌───────────────────────────────────────────────────────────┐
   │                  ONE STORAGE ARRAY                         │
   │    volume: postgres-data          snapshot: snap-monday    │
   │    volume: orders-data            snapshot: snap-tuesday   │
   │                                   snapshot: snap-wednesday │
   │                                                            │
   │  Array dies / datacenter floods / filesystem corrupts /    │
   │  admin runs the wrong destroy command / ransomware         │
   │  encrypts the LUN:                                         │
   │        EVERYTHING IN THIS BOX IS GONE AT ONCE              │
   └───────────────────────────────────────────────────────────┘
```

Worse, for copy on write backends the snapshot is not even an independent copy: it is a set of pointers into the same blocks as the live volume plus the blocks that have since changed. Corruption in the shared blocks corrupts the snapshot too.

### What Each Mechanism Actually Protects Against

| Threat | Snapshot | Replica | Off-site backup |
|--------|----------|---------|-----------------|
| `DROP TABLE` by mistake | ✅ fast recovery | ❌ replicates the drop instantly | ✅ slower |
| Bad application release corrupting data | ✅ | ❌ | ✅ |
| Accidental PVC deletion | ✅ if `Retain` policy | ❌ | ✅ |
| Single disk failure | ✅ usually | ✅ | ✅ |
| Storage array or controller failure | ❌ | ✅ if on other hardware | ✅ |
| Filesystem corruption on shared blocks | ⚠️ maybe | ✅ | ✅ |
| Datacenter loss | ❌ | ✅ if remote | ✅ |
| Ransomware with storage admin credentials | ❌ | ❌ | ✅ if immutable |
| Cluster deleted entirely | ❌ | ❌ | ✅ |
| Restore to a different cluster or vendor | ❌ | ❌ | ✅ |

### Where Snapshots Belong in a Real Strategy

Snapshots are excellent at exactly one thing: **fast recovery from logical errors on the same infrastructure.** Use them as the first tier, not the only tier.

```
┌───────────────────────────────────────────────────────────────────────────┐
│  TIER 1: SNAPSHOTS            minutes old, seconds to restore             │
│    before every schema migration, before every risky deployment,          │
│    hourly for the last 24 hours                                           │
│    ► recovers from: bad migration, bad release, fat-fingered delete       │
│                                                                            │
│  TIER 2: REPLICATION          seconds behind, automatic failover          │
│    database replicas on different nodes and racks                         │
│    ► recovers from: node loss, disk loss                                  │
│    ► does NOT recover from: anything logical; it replicates the mistake   │
│                                                                            │
│  TIER 3: OFF-BACKEND BACKUP   hours old, minutes to hours to restore      │
│    pg_dump / mysqldump to object storage; Velero with a filesystem or     │
│    snapshot data mover; different vendor, credentials, ideally immutable  │
│    ► recovers from: array loss, site loss, ransomware, cluster loss       │
│                                                                            │
│  TIER 4: TESTED RESTORE       the only tier that proves the others work   │
│    a scheduled Job that restores tier 3 into a scratch namespace, runs a  │
│    consistency check, and alerts on failure                               │
└───────────────────────────────────────────────────────────────────────────┘
```

An untested backup is a hypothesis. A snapshot that has never been restored is a hypothesis with extra steps.

---

## The Architecture: Two Controllers and Three CRDs

Volume snapshots are **not built into the Kubernetes API server**. Unlike PersistentVolumeClaim, they are Custom Resource Definitions plus controllers, shipped by the `kubernetes-csi/external-snapshotter` project and installed by the cluster operator.

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │  kube-apiserver                                                       │
  │    CRDs (installed separately, NOT built in):                        │
  │      volumesnapshots.snapshot.storage.k8s.io                         │
  │      volumesnapshotcontents.snapshot.storage.k8s.io                  │
  │      volumesnapshotclasses.snapshot.storage.k8s.io                   │
  └───────────▲──────────────────────────────────▲───────────────────────┘
              │ watch VolumeSnapshot              │ watch VolumeSnapshotContent
              │ create/bind Content               │ (only for ITS driver)
  ┌───────────┴───────────────────────┐  ┌───────┴────────────────────────┐
  │  snapshot-controller               │  │  CSI CONTROLLER POD            │
  │  ONE per cluster, driver AGNOSTIC  │  │  ┌──────────────────────────┐ │
  │  its own Deployment                │  │  │ csi-snapshotter sidecar  │ │
  │                                     │  │  └────────────┬─────────────┘ │
  │  Responsibilities:                  │  │  ┌────────────▼─────────────┐ │
  │   • create Content for a Snapshot   │  │  │  CSI DRIVER              │ │
  │   • bind Snapshot <-> Content       │  │  │  CreateSnapshot          │ │
  │   • manage finalizers               │  │  │  DeleteSnapshot          │ │
  │   • copy status up to the Snapshot  │  │  │  ListSnapshots           │ │
  │   • validate the source PVC         │  │  └────────────┬─────────────┘ │
  │   • NEVER talks to a CSI driver     │  └───────────────┼───────────────┘
  └─────────────────────────────────────┘  ┌──────────────▼───────────────┐
                                            │      STORAGE BACKEND          │
                                            │  the snapshot actually exists │
                                            │  here, and only here          │
                                            └───────────────────────────────┘
```

| Component | Count | Scope | Talks to CSI? | Job |
|-----------|-------|-------|---------------|-----|
| **CRDs** | 3 | Cluster | n/a | Define the object types |
| **snapshot-controller** | 1 per cluster | All drivers | ❌ Never | Object lifecycle, binding, status |
| **csi-snapshotter sidecar** | 1 per driver | One driver | ✅ Yes | Turn Content objects into RPCs |
| **CSI driver** | 1 per backend | One backend | is the CSI | Actually take the snapshot |

The two most common installation mistakes both come from this split:

1. **CRDs installed, no snapshot-controller.** You can create a VolumeSnapshot. It sits with no status forever, no Content object is ever created, and no error appears anywhere.
2. **CRDs and controller installed, but the driver has no csi-snapshotter sidecar.** A Content object is created and nothing happens to it, because nobody calls `CreateSnapshot`.

Snapshot semantics vary so much between backends that the API needed to evolve outside the Kubernetes release cycle, exactly like CSI itself. The trade is that **`kubectl get volumesnapshot` on a fresh cluster returns an error, not an empty list**, and that error is the correct first diagnostic:

```bash
kubectl get volumesnapshots
# error: the server doesn't have a resource type "volumesnapshots"
```

---

## Installing the CRDs and the Snapshot Controller

Order matters: CRDs first, then the controller, then (per driver) the sidecar.

```bash
# Pin the release; do not track a branch in production, because CRD schemas
# change between major versions.
snap_ver=$(curl -s -L \
  https://api.github.com/repos/kubernetes-csi/external-snapshotter/releases/latest \
  | jq -r '.tag_name' | tr -d '[:space:]')

base="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${snap_ver}"

# 1. The three CRDs
kubectl apply -f "${base}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
kubectl apply -f "${base}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
kubectl apply -f "${base}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml"

# 2. The cluster-wide snapshot controller (RBAC + Deployment)
kubectl apply -f "${base}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
kubectl apply -f "${base}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"
```

Verify in the order that isolates faults:

```bash
kubectl get crd | grep snapshot.storage.k8s.io      # 1. CRDs registered?
kubectl get deploy -A | grep -i snapshot             # 2. controller running?

# 3. Does the driver have the sidecar?
kubectl get pod -n kube-system -l app=csi-nfs-controller \
  -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# csi-provisioner csi-snapshotter liveness-probe nfs
#                 ^^^^^^^^^^^^^^^ must be present

kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-snapshotter --tail=30
```

> Some releases of external-snapshotter also shipped a **snapshot validating
> webhook**, and its role changed over the project's history. Read the release
> notes for the version you install rather than assuming it is required or absent.

Upgrade in the order **CRDs, then snapshot-controller, then the csi-snapshotter sidecars** in each driver, reading the release notes for schema changes.

---

## VolumeSnapshotClass

The analogy is exact: **VolumeSnapshotClass is to snapshots what StorageClass is to volumes.**

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  # Cluster scoped. Referenced by VolumeSnapshot.spec.volumeSnapshotClassName.
  name: csi-nfs-snapclass
  annotations:
    # A VolumeSnapshot that omits volumeSnapshotClassName gets the default
    # for its PVC's driver. NOTE the key: snapshot.storage.KUBERNETES.io,
    # which is NOT the same shape as the StorageClass annotation.
    snapshot.storage.kubernetes.io/is-default-class: "true"

# The CSI driver that will take the snapshot. MUST match the driver of the
# PVC being snapshotted. Cross-driver snapshots do not exist.
driver: nfs.csi.k8s.io

# What happens to the underlying BACKEND snapshot when the
# VolumeSnapshotContent object is deleted.
#   Delete - call DeleteSnapshot; the backend snapshot is destroyed
#   Retain - no RPC; the Content object goes and the backend snapshot
#            survives as an orphan you must track yourself
# REQUIRED FIELD. There is no default.
deletionPolicy: Delete

# Driver specific, opaque to Kubernetes, validated only by the driver.
# There is no universal parameter set; consult the driver's own docs.
parameters: {}
```

### The Three Rules

**1. `driver` must match the PVC's driver.**

```bash
pv=$(kubectl get pvc postgres-data -n databases -o jsonpath='{.spec.volumeName}')
kubectl get pv "${pv}" -o jsonpath='{.spec.csi.driver}{"\n"}'          # nfs.csi.k8s.io
kubectl get volumesnapshotclass -o custom-columns='NAME:.metadata.name,DRIVER:.driver'
```

A mismatch produces a snapshot that stays not ready, with an error saying the class driver does not match the volume's driver.

**2. `deletionPolicy` is mandatory** and lives on the class, not on the VolumeSnapshot. It is copied into each dynamically created Content and, exactly like `reclaimPolicy` on a StorageClass, editing the class later affects only future snapshots. The enforced value is on the Content object and can be patched there.

**3. The default class annotation key differs from the StorageClass one:**

```
StorageClass:         storageclass.kubernetes.io/is-default-class
VolumeSnapshotClass:  snapshot.storage.kubernetes.io/is-default-class
```

Typing the wrong one produces a class that is silently not default. As with StorageClasses, more than one default per driver is a configuration bug.

Running a second class with `deletionPolicy: Retain` alongside the default is a common and sensible pattern: `Delete` for the hourly churn, `Retain` for the pre-migration safety snapshot that must survive a panicked `kubectl delete ns`.

---

## VolumeSnapshot

**Namespaced, like a PVC.** This is the object an application team writes.

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: postgres-data-2026-09-05
  # MUST be in the same namespace as the source PVC. There is no
  # cross-namespace snapshot source.
  namespace: databases
spec:
  # Omit to use the default class for the PVC's driver, if one exists.
  volumeSnapshotClassName: csi-nfs-snapclass

  # EXACTLY ONE of the two below. They are mutually exclusive and select
  # the dynamic or the pre-provisioned flow.
  source:
    # DYNAMIC: snapshot this live PVC.
    persistentVolumeClaimName: postgres-data
    # PRE-PROVISIONED (do not set both):
    # volumeSnapshotContentName: snapcontent-imported-2026-09-05

status:
  # Everything below is written by the controllers. Never author it.
  boundVolumeSnapshotContentName: snapcontent-6a1e0d70-6a9f-4f1a-91c1-8f9b0f6b1d2e
  readyToUse: true
  creationTime: "2026-09-05T09:14:22Z"
  restoreSize: 50Gi
```

### The PVC Analogy, Precisely

```
┌──────────────────────────────────────────────────────────────────────────┐
│  VOLUMES                          SNAPSHOTS                               │
├──────────────────────────────────────────────────────────────────────────┤
│  StorageClass                     VolumeSnapshotClass                     │
│    cluster scoped                   cluster scoped                        │
│    provisioner: <driver>            driver: <driver>                      │
│    reclaimPolicy: Delete|Retain     deletionPolicy: Delete|Retain         │
│                                                                           │
│  PersistentVolumeClaim            VolumeSnapshot                          │
│    NAMESPACED, what the app asks    NAMESPACED, what the app asks for     │
│    spec.volumeName (bound PV)       status.boundVolumeSnapshotContentName │
│                                                                           │
│  PersistentVolume                 VolumeSnapshotContent                   │
│    CLUSTER SCOPED, the real thing   CLUSTER SCOPED, the real thing        │
│    spec.csi.volumeHandle            status.snapshotHandle                 │
│    spec.claimRef                    spec.volumeSnapshotRef                │
│    persistentVolumeReclaimPolicy    deletionPolicy                        │
└──────────────────────────────────────────────────────────────────────────┘
```

Once you see this table the whole model follows: the namespaced object is a **request**, the cluster scoped object is the **reality**, and the class is the **recipe**. Binding is bidirectional, exactly as with PVC and PV.

---

## VolumeSnapshotContent

**Cluster scoped, like a PV.** Created automatically in the dynamic flow, written by hand in the pre-provisioned flow.

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotContent
metadata:
  # In the dynamic flow this is generated as snapcontent-<snapshot-uid>.
  name: snapcontent-6a1e0d70-6a9f-4f1a-91c1-8f9b0f6b1d2e
  finalizers:
  - snapshot.storage.kubernetes.io/volumesnapshotcontent-bound-protection
spec:
  # Copied from the class at creation. THIS is the enforced value.
  deletionPolicy: Delete
  driver: nfs.csi.k8s.io
  volumeSnapshotClassName: csi-nfs-snapclass
  # Volume mode of the SOURCE volume. A restore must produce a PVC whose
  # volumeMode matches.
  sourceVolumeMode: Filesystem

  # EXACTLY ONE of these two.
  source:
    # DYNAMIC: the CSI volume handle of the SOURCE VOLUME, i.e. the value of
    # pv.spec.csi.volumeHandle. Passed as source_volume_id to CreateSnapshot.
    volumeHandle: "10.0.0.20#export/fast#pvc-9f2e5c31-8b4a-4d21-9c7e-1a2b3c4d5e6f"
    # PRE-PROVISIONED: an EXISTING snapshot's backend identifier. Nothing is
    # created; Kubernetes adopts what is already there.
    # snapshotHandle: "10.0.0.20#export/fast#snap-2026-09-05"

  # The two-way binding back to the namespaced object. In the dynamic flow
  # the controller fills this in including the uid. In the pre-provisioned
  # flow you write name and namespace and LEAVE UID OUT.
  volumeSnapshotRef:
    apiVersion: snapshot.storage.k8s.io/v1
    kind: VolumeSnapshot
    name: postgres-data-2026-09-05
    namespace: databases
    uid: 6a1e0d70-6a9f-4f1a-91c1-8f9b0f6b1d2e

status:
  # The backend's own identifier, returned by CreateSnapshot.
  snapshotHandle: "10.0.0.20#export/fast#snap-6a1e0d70"
  readyToUse: true
  # Nanoseconds since the epoch here; the VolumeSnapshot exposes the same
  # instant as an RFC3339 timestamp.
  creationTime: 1788675262000000000
  restoreSize: 53687091200
```

### volumeHandle vs snapshotHandle

Confusing these two is the number one cause of a failed pre-provisioned import:

```
spec.source.volumeHandle      the SOURCE VOLUME's id
                              "snapshot THIS volume for me"
                              ► dynamic flow; equals pv.spec.csi.volumeHandle

spec.source.snapshotHandle    an EXISTING SNAPSHOT's id
                              "adopt this snapshot that already exists"
                              ► pre-provisioned flow; equals the
                                status.snapshotHandle of a real snapshot
```

Both are **driver specific opaque strings**. A handle from one driver is meaningless to another, which is precisely why a snapshot cannot be restored across drivers.

---

## The Dynamic Snapshot Flow

```
  USER                snapshot-controller      csi-snapshotter      DRIVER
   │ 1. create               │                       │                 │
   │    VolumeSnapshot       │                       │                 │
   │    source: pvcName      │                       │                 │
   ├────────────────────────►│                       │                 │
   │                    2. validate: PVC exists and is Bound; class     │
   │                       driver matches the PV's driver               │
   │                    3. add finalizers to the VolumeSnapshot and     │
   │                       to the source PVC                            │
   │                    4. create VolumeSnapshotContent                 │
   │                       source.volumeHandle = pv.spec.csi.volumeHandle
   │                       deletionPolicy from the class                │
   │                       volumeSnapshotRef -> the VolumeSnapshot      │
   │                         ├──────────────────────►│                 │
   │                         │                  5. see a Content for   │
   │                         │                     MY driver           │
   │                         │                       ├────────────────►│
   │                         │                       │  CreateSnapshot │
   │                         │                       │  (name, source  │
   │                         │                       │   volume_id,    │
   │                         │                       │   params, secrets)
   │                         │                       │◄────────────────┤
   │                         │                       │  snapshot_id    │
   │                         │                       │  size_bytes     │
   │                         │                       │  creation_time  │
   │                         │                       │  ready_to_use   │
   │                         │                  6. write status onto   │
   │                         │◄──────────────────┤   the Content       │
   │                         │                  6b. if not ready, poll │
   │                         │                      with ListSnapshots │
   │                    7. copy status UP to the VolumeSnapshot:       │
   │                       boundVolumeSnapshotContentName,             │
   │                       readyToUse, restoreSize, creationTime       │
   │◄────────────────────────┤                       │                 │
   │  8. readyToUse: true    │                       │                 │
```

```bash
kubectl get volumesnapshot -n databases -w
# NAME       READYTOUSE  SOURCEPVC      RESTORESIZE  SNAPSHOTCONTENT   AGE
# pg-snap-1  false       postgres-data                                 0s
# pg-snap-1  false       postgres-data               snapcontent-6a1e  1s
# pg-snap-1  true        postgres-data  50Gi         snapcontent-6a1e  4s
```

The columns fill in left to right in exactly the order of the steps above, which makes `-w` the fastest way to see where a stalled snapshot stopped.

Step 3 adds `snapshot.storage.kubernetes.io/pvc-as-source-protection` to the source PVC, preventing the source volume from being deleted while a snapshot of it is in flight. It is removed once the snapshot is ready.

---

## The Pre-Provisioned (Static) Flow

Used when a snapshot already exists on the backend and you want Kubernetes to manage or restore from it: a snapshot taken by the array's own scheduler, one from a decommissioned cluster, or one created out of band during a migration. **The direction of creation is reversed: you write the cluster scoped object first.**

```yaml
# STEP 1: cluster-scoped, written by an administrator.
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotContent
metadata:
  name: snapcontent-imported-20260905
spec:
  # Retain, almost always. You did not create this backend snapshot, so
  # Kubernetes should not destroy it when the object goes away.
  deletionPolicy: Retain
  driver: nfs.csi.k8s.io
  sourceVolumeMode: Filesystem
  source:
    # The EXISTING snapshot's backend identifier, in this driver's format.
    snapshotHandle: "10.0.0.20#export/fast#snap-2026-09-05"
  volumeSnapshotRef:
    apiVersion: snapshot.storage.k8s.io/v1
    kind: VolumeSnapshot
    # Name and namespace of the VolumeSnapshot that WILL be created.
    # Deliberately omit uid: it does not exist yet, and leaving uid empty
    # lets any snapshot with this name/namespace claim it.
    name: pg-restore-point
    namespace: databases
---
# STEP 2: namespaced, written by the application team.
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: pg-restore-point
  namespace: databases
spec:
  # No volumeSnapshotClassName: nothing is provisioned, so no recipe is
  # needed. Setting one here is a common mistake and can confuse binding.
  source:
    # Point at the Content object, NOT at a PVC.
    volumeSnapshotContentName: snapcontent-imported-20260905
```

The snapshot-controller then binds the two, fills in the uid on the Content, and asks the sidecar to verify the snapshot exists; `readyToUse` becomes true and the snapshot is usable as a `dataSource`.

| | Dynamic | Pre-provisioned |
|---|---------|-----------------|
| Who creates the Content | snapshot-controller | You |
| Creation order | VolumeSnapshot first | VolumeSnapshotContent first |
| `spec.source` on the Snapshot | `persistentVolumeClaimName` | `volumeSnapshotContentName` |
| `spec.source` on the Content | `volumeHandle` | `snapshotHandle` |
| `volumeSnapshotClassName` | Required (or a default) | Not used |
| `CreateSnapshot` called | ✅ Yes | ❌ It already exists |
| Typical `deletionPolicy` | `Delete` | `Retain` |
| `volumeSnapshotRef.uid` | Set by the controller | Left empty by you |
| Use case | Everyday snapshots | Migration, import, array-scheduled snapshots |

**The binding trap:** if you set `uid` in `volumeSnapshotRef` on a hand written Content it must match the eventual VolumeSnapshot's UID exactly, which you cannot know in advance. Leave it out. A wrong one means the objects never bind, and the snapshot reports that the content is bound to a different snapshot.

---

## Snapshot Status Fields

| Field | Written by | Meaning | Gotcha |
|-------|-----------|---------|--------|
| `boundVolumeSnapshotContentName` | snapshot-controller | The cluster scoped object holding the real snapshot | Empty means binding never happened: no controller, or a validation failure |
| `readyToUse` | Driver, propagated up | The snapshot can be used as a `dataSource` | **The only field that matters before restoring.** `false` is normal for asynchronous backends |
| `creationTime` | Driver | When the backend took it | RFC3339 here; nanoseconds since epoch on the Content |
| `restoreSize` | Driver | Minimum PVC size needed to restore | Not the space the snapshot occupies |
| `error` | Either controller | Last failure, with `message` and `time` | Can persist after a later success; check `readyToUse` too |

### readyToUse Is the Only Gate

```bash
kubectl wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/pg-snap-1 -n databases --timeout=600s
```

Restoring from a snapshot whose `readyToUse` is `false` fails, or worse produces a volume with incomplete data on drivers that do not check. **The existence of the object is not the existence of the snapshot.**

### restoreSize Is a Floor, Not a Size

`restoreSize` is the size of the **source volume**, and therefore the minimum size of any PVC restored from it. It says nothing about how much backend space the snapshot consumes, which for a copy on write snapshot starts near zero and grows.

```
new PVC requested size  >=  restoreSize      ✅ allowed
new PVC requested size  <   restoreSize      ❌ rejected
new PVC requested size  >   restoreSize      ⚠️  driver dependent: many drivers
                                                restore at restoreSize and need
                                                a separate expansion afterwards
```

The safe practice is to request **exactly** `restoreSize` and expand afterwards if you need more.

---

## Restoring From a Snapshot

**You always restore into a new PVC.** There is no in-place restore, no "roll back this volume" verb, and no way to point an existing PVC at a snapshot.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-restored
  # Same namespace as the VolumeSnapshot. dataSource cannot cross namespaces.
  namespace: databases
spec:
  # At minimum, a class whose provisioner is the SAME DRIVER that took the
  # snapshot. It need not be the identical class.
  storageClassName: fast-ssd
  accessModes: ["ReadWriteOnce"]
  # Must match the snapshot's sourceVolumeMode.
  volumeMode: Filesystem
  resources:
    requests:
      storage: 50Gi     # >= status.restoreSize; use exactly restoreSize
  dataSource:
    name: pg-snap-1
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
```

### What Happens Underneath

```
  PVC with dataSource created
        ▼
  external-provisioner resolves the VolumeSnapshot to its
  VolumeSnapshotContent and reads status.snapshotHandle
        ▼
  CreateVolume{ name: "pvc-<new-uid>",
                capacity_range: { required_bytes: 53687091200 },
                volume_content_source: { snapshot: { snapshot_id: "...snap-6a1e0d70" } } }
        ▼
  Driver creates a NEW volume populated from the snapshot
        ▼
  New PV, bound to the new PVC. The source volume is untouched.
```

Restore is `CreateVolume` with a content source: a normal provisioning operation, obeying all the normal rules, including that a `WaitForFirstConsumer` class still waits for a Pod.

### The In-Place Restore Pattern

```bash
ns=databases; app=postgres

# 1. Stop the workload. Never restore under a running database.
kubectl scale statefulset ${app} -n ${ns} --replicas=0
kubectl wait --for=delete pod -l app=${app} -n ${ns} --timeout=300s

# 2. Restore into a NEW PVC.
kubectl apply -f restore-pvc.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/postgres-data-restored -n ${ns} --timeout=600s

# 3. Protect the OLD volume before touching it.
old_pv=$(kubectl get pvc postgres-data -n ${ns} -o jsonpath='{.spec.volumeName}')
kubectl patch pv "${old_pv}" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# 4. Point the workload at the restored claim, then scale back up and
#    verify AT THE APPLICATION LEVEL.
kubectl scale statefulset ${app} -n ${ns} --replicas=1
```

For a StatefulSet, whose PVC names are dictated by the template and ordinal, step 4 means the restored data must end up under the expected name (`data-postgres-0`). The usual approach: delete the old PVC (its PV on `Retain`), then create a PVC with the original name whose `dataSource` is the snapshot, before scaling back up. The StatefulSet controller adopts an existing PVC with the right name rather than creating a new one.

### Restore Constraints

| Constraint | Detail |
|-----------|--------|
| Same namespace | `dataSource` cannot reference another namespace |
| Same driver | The snapshot handle is driver specific |
| Size `>=` restoreSize | Smaller is rejected; larger may be silently ignored |
| Matching `volumeMode` | A `Block` snapshot restores to a `Block` PVC |
| `readyToUse: true` | Restoring from a not-ready snapshot fails |
| New PVC only | No in-place restore exists |

Note what is **not** on the list: the restored PVC does not have to use the same StorageClass, as long as the class's provisioner is the same driver. Restoring a `fast-ssd` snapshot into a `fast-ssd-encrypted` class of the same driver is legitimate; restoring it into an SMB class is not.

---

## Cloning a PVC

A clone copies a **live** PVC directly, with no snapshot object in between.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-clone
  namespace: databases
spec:
  storageClassName: fast-ssd
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 50Gi          # must be >= the SOURCE PVC's size
  dataSource:
    name: postgres-data
    kind: PersistentVolumeClaim
    apiGroup: ""             # core API group: empty string, or omit entirely
```

This becomes `CreateVolume` with `volume_content_source.volume.volume_id` pointing at the source volume, and requires the driver to advertise the `CLONE_VOLUME` controller capability.

| | Clone | Snapshot + restore |
|---|-------|--------------------|
| Intermediate object | None | VolumeSnapshot + Content |
| CSI capability | `CLONE_VOLUME` | `CREATE_DELETE_SNAPSHOT` |
| Point in time captured | Now, implicitly | Explicit, and kept |
| Reusable | ❌ one shot | ✅ restore many times |
| Requires CRDs and snapshot-controller | ❌ No | ✅ Yes |
| Source must exist at restore time | ✅ always | ❌ snapshot outlives the source |
| Retention policy | n/a | `deletionPolicy` |
| Good for | Dev copies, test fixtures, scaling out read replicas | Backups, pre-migration safety, recovery points |

The practical rule: **clone when you want another copy right now; snapshot when you want the ability to go back later.** A clone is not a recovery point, because once the source is gone the clone is just an ordinary independent volume with no relationship to anything. Cloning is also namespace bound and driver bound, exactly like restore.

---

## dataSource vs dataSourceRef

Both live on `PersistentVolumeClaim.spec` and both mean "populate this volume from something".

| | `dataSource` | `dataSourceRef` |
|---|-------------|-----------------|
| Allowed kinds | `VolumeSnapshot`, `PersistentVolumeClaim` only | Any, including custom resources |
| Invalid values | **Silently dropped** by the API server | **Rejected** with a validation error |
| Namespace field | ❌ | ✅ (feature gated, needs a `ReferenceGrant`) |
| Populated by | The CSI driver | The driver, or a **volume populator** controller |

### The Auto-Sync Behaviour

```
┌───────────────────────────────────────────────────────────────────────────┐
│  Set dataSource only                                                       │
│     ► the API server copies it into dataSourceRef                          │
│  Set dataSourceRef only, with a kind dataSource also allows                │
│     ► the API server copies it into dataSource                             │
│  Set dataSourceRef only, with a kind dataSource does NOT allow             │
│     ► dataSource stays empty; this is expected, not a bug                  │
│  Set BOTH to DIFFERENT values                                              │
│     ► rejected at validation                                               │
│  Both are IMMUTABLE after creation.                                        │
└───────────────────────────────────────────────────────────────────────────┘
```

### The Silent Drop

The behavioural difference that matters most in practice:

```yaml
# With dataSource: a typo in apiGroup is SILENTLY DISCARDED.
  dataSource:
    name: pg-snap-1
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.io      # WRONG (missing .k8s)
```

The PVC is accepted, the `dataSource` is stripped, and an **empty volume** is provisioned. The application starts, finds no data, and initialises a fresh database. Nobody notices until somebody looks for last week's rows.

```yaml
# With dataSourceRef: the same typo is REJECTED at creation.
  dataSourceRef:
    name: pg-snap-1
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.io      # WRONG
# error: ... dataSourceRef: Invalid value: ... not supported
```

**Prefer `dataSourceRef` in automation** for exactly this reason: a loud failure at apply time beats a silent empty volume in production. Always verify a restore actually referenced the snapshot:

```bash
kubectl get pvc postgres-data-restored -n databases -o jsonpath='{.spec.dataSource}{"\n"}'
```

An empty line where you expected a snapshot means you just provisioned an empty volume.

`dataSourceRef` accepting arbitrary kinds is also what enables **volume populators**: a controller registers for a custom resource kind, and when a PVC references one, the populator creates and fills a volume before handing it over. That is how "create a PVC pre-loaded from this container image or this object storage prefix" is implemented without changing Kubernetes.

---

## Application Consistency

A snapshot captures the volume exactly as the kernel and the backend see it at that instant. It does not capture what is in the application's memory.

```
┌════════════════════════════════════════════════════════════════════════════┐
║                    THREE LEVELS OF CONSISTENCY                              ║
╚════════════════════════════════════════════════════════════════════════════┝

  CRASH CONSISTENT              what you get by default
  Equivalent to yanking the power cord at that instant. On disk: committed
  writes are there, in-flight writes may be torn, in-memory buffers are lost,
  the filesystem journal may need replay. A well-built database RECOVERS from
  this (WAL replay on startup). A naive application may find a half-written file.

  FILESYSTEM CONSISTENT         freeze the filesystem first
  fsfreeze -f flushes the page cache and blocks new writes for the duration,
  then fsfreeze -u releases. No torn filesystem metadata, no journal replay.
  Still does NOT know what the application had buffered.

  APPLICATION CONSISTENT        quiesce the application first
  Postgres pg_backup_start, MySQL FLUSH TABLES WITH READ LOCK, MongoDB
  fsyncLock, or simply stopping the process. A coherent, restartable state
  with nothing lost in memory. The only level you can promise a DBA.
```

A database with write ahead logging and `fsync` on commit is designed to survive power loss, so a crash consistent snapshot of it will start, replay the WAL and come up clean. That is a real, usable recovery point. It stops being enough when data spans **multiple volumes** (two independent snapshots at two different instants that may be mutually inconsistent), when the application has no write ahead log or does not `fsync`, or when the workload is a filesystem full of application files where a half-written upload is indistinguishable from a complete one.

### The Freeze Pattern

Kubernetes has **no built-in snapshot hook**. There is no `preSnapshot` lifecycle event and no way for the snapshot controller to call into a Pod, so quiescing is always orchestrated from outside:

**1. Scripted quiesce (most control, most reliable).**

```bash
#!/usr/bin/env bash
set -euo pipefail
ns=databases; pod=postgres-0
snap=pg-snap-$(date +%Y%m%d-%H%M%S)

# 1. Tell Postgres a backup is starting: it checkpoints and marks the WAL.
kubectl exec -n "${ns}" "${pod}" -c postgres -- \
  psql -U postgres -Atc "SELECT pg_backup_start('${snap}', true);"

# 2. Always leave backup mode, even if the rest fails. This trap matters more
#    than the snapshot: a database stuck in backup mode is a slow outage.
trap 'kubectl exec -n "${ns}" "${pod}" -c postgres -- \
        psql -U postgres -Atc "SELECT pg_backup_stop();" || true' EXIT

kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: { name: ${snap}, namespace: ${ns} }
spec:
  volumeSnapshotClassName: csi-nfs-snapclass
  source:
    persistentVolumeClaimName: data-postgres-0
EOF

kubectl wait --for=jsonpath='{.status.readyToUse}'=true \
  "volumesnapshot/${snap}" -n "${ns}" --timeout=600s
```

**2. Filesystem freeze from a privileged helper.** A DaemonSet with host access runs `fsfreeze -f` on the staged mount path, triggers the snapshot, then `fsfreeze -u`. Powerful and dangerous: a freeze never released hangs every process touching that filesystem, so it needs a hard timeout and a watchdog.

**3. Cold snapshot.** Scale to zero, snapshot, scale back up. For a nightly window on a non-critical workload this is often right, because its only failure mode is "the app was down for two minutes".

**4. Application-native dump instead.** For many databases the honest answer is that `pg_dump` or `mysqldump` to object storage is a better backup than any volume snapshot: application consistent by construction, portable across storage backends and Kubernetes versions, and restorable into a completely different cluster. Snapshots complement it; they do not replace it.

**Kubernetes has no consistency group primitive.** Two volumes snapshotted separately are captured at two different instants and nothing reconciles them. Mitigations, in order of preference: keep everything on one volume; quiesce the application across the whole window; use an application-native dump.

---

## A Complete Worked Walkthrough

### Step 0: Preflight

```bash
kubectl get crd | grep snapshot.storage.k8s.io
kubectl get deploy -A | grep -i snapshot-controller
kubectl get volumesnapshotclass
kubectl get storageclass
```

If any of these four is empty, stop and fix it. Everything below will fail in confusing ways otherwise.

### Step 1: Create a PVC and Write Data

```bash
kubectl create namespace snapdemo

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: demo-data, namespace: snapdemo }
spec:
  storageClassName: nfs-csi
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: writer, namespace: snapdemo }
spec:
  containers:
  - name: app
    image: registry.k8s.io/busybox:1.27.2
    command: ["sh","-c","sleep 3600"]
    volumeMounts:
    - { name: data, mountPath: /data }
  volumes:
  - name: data
    persistentVolumeClaim: { claimName: demo-data }
EOF

kubectl wait --for=condition=Ready pod/writer -n snapdemo --timeout=120s

kubectl exec -n snapdemo writer -- sh -c '
  echo "important record 1" >  /data/records.txt
  echo "important record 2" >> /data/records.txt
  mkdir -p /data/config && echo "retention=30d" > /data/config/settings.conf
  sync'

# Capture a checksum. This is the entire point of the exercise.
kubectl exec -n snapdemo writer -- sh -c \
  'find /data -type f | sort | xargs cat | md5sum'
# 8f3d2b1c9a7e4f6d5b0c8a2e1f4d7b3c  -
```

### Step 2: Take the Snapshot

```bash
kubectl apply -f - <<'EOF'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: { name: demo-snap-1, namespace: snapdemo }
spec:
  volumeSnapshotClassName: csi-nfs-snapclass
  source:
    persistentVolumeClaimName: demo-data
EOF

kubectl wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/demo-snap-1 -n snapdemo --timeout=300s

kubectl get volumesnapshot -n snapdemo
# NAME         READYTOUSE  SOURCEPVC  RESTORESIZE  SNAPSHOTCLASS      SNAPSHOTCONTENT
# demo-snap-1  true        demo-data  1Gi          csi-nfs-snapclass  snapcontent-6a1e..
```

### Step 3: Destroy the Data

```bash
kubectl exec -n snapdemo writer -- sh -c '
  rm -rf /data/records.txt /data/config
  echo "corrupted" > /data/records.txt
  sync'

kubectl exec -n snapdemo writer -- sh -c \
  'find /data -type f | sort | xargs cat | md5sum'
# 3e7a9c1f5d2b8e4a6c0f9b3d7e1a5c8f  -     <-- different, as expected
```

### Step 4: Restore Into a New PVC

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: demo-data-restored, namespace: snapdemo }
spec:
  storageClassName: nfs-csi
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }     # == restoreSize
  dataSourceRef:
    name: demo-snap-1
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

# Confirm the reference SURVIVED admission. If this prints nothing, you are
# about to mount an empty volume.
kubectl get pvc demo-data-restored -n snapdemo -o jsonpath='{.spec.dataSource}{"\n"}'
# {"apiGroup":"snapshot.storage.k8s.io","kind":"VolumeSnapshot","name":"demo-snap-1"}

kubectl wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/demo-data-restored -n snapdemo --timeout=300s
```

### Step 5: Verify

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: verifier, namespace: snapdemo }
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: registry.k8s.io/busybox:1.27.2
    command: ["sh","-c","find /data -type f | sort | xargs cat | md5sum; cat /data/records.txt"]
    volumeMounts:
    - { name: data, mountPath: /data }
  volumes:
  - name: data
    persistentVolumeClaim: { claimName: demo-data-restored }
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/verifier -n snapdemo --timeout=180s
kubectl logs verifier -n snapdemo
# 8f3d2b1c9a7e4f6d5b0c8a2e1f4d7b3c  -      <-- matches step 1
# important record 1
# important record 2
```

The checksum matching the one from step 1 is the proof. Anything less than a checksum comparison is a demonstration, not a verification.

### Step 6: Clean Up, and the Lesson Hiding In It

```bash
kubectl delete namespace snapdemo
kubectl get volumesnapshotcontent
# No resources found
```

**Deleting a namespace deleted the backup.** Because `deletionPolicy` was `Delete`, the Content and the backend snapshot went with it. If that had been a real recovery point it is now gone. Use `deletionPolicy: Retain` for anything you would be sad to lose, and keep genuine backups off the cluster entirely.

---

## Retention, Deletion Policy and Finalizers

```
┌───────────────────────────────────────────────────────────────────────────┐
│  DELETE the VolumeSnapshot (namespaced)                                    │
│    deletionPolicy: Delete                                                  │
│      ► Content deleted, DeleteSnapshot called, backend snapshot DESTROYED  │
│    deletionPolicy: Retain                                                  │
│      ► Content object deleted, NO RPC, backend snapshot SURVIVES as an     │
│        orphan unreferenced by Kubernetes                                   │
│                                                                            │
│  DELETE the VolumeSnapshotContent directly                                 │
│      ► same policy rules; the VolumeSnapshot is left dangling with         │
│        readyToUse false                                                    │
│                                                                            │
│  DELETE the SOURCE PVC                                                     │
│      ► existing snapshots are NOT affected; they outlive their source,     │
│        though pvc-as-source-protection blocks deletion while a snapshot    │
│        is still being created                                              │
│                                                                            │
│  DELETE the NAMESPACE                                                      │
│      ► every VolumeSnapshot in it goes, and with Delete policy every       │
│        corresponding backend snapshot is destroyed                         │
└───────────────────────────────────────────────────────────────────────────┘
```

`deletionPolicy` on the class is a template; the enforced value is on the Content and is patchable, which is the snapshot equivalent of flipping a PV to `Retain` before risky work:

```bash
content=$(kubectl get volumesnapshot pg-snap-1 -n databases \
  -o jsonpath='{.status.boundVolumeSnapshotContentName}')
kubectl patch volumesnapshotcontent "${content}" --type=merge \
  -p '{"spec":{"deletionPolicy":"Retain"}}'
```

### The Finalizers

| Finalizer | On | Prevents |
|-----------|----|----------|
| `snapshot.storage.kubernetes.io/volumesnapshot-as-source-protection` | VolumeSnapshot | Deleting a snapshot while a PVC is being restored from it |
| `snapshot.storage.kubernetes.io/volumesnapshot-bound-protection` | VolumeSnapshot | Deleting a snapshot while its Content still exists |
| `snapshot.storage.kubernetes.io/volumesnapshotcontent-bound-protection` | VolumeSnapshotContent | Deleting the Content before `DeleteSnapshot` succeeded |
| `snapshot.storage.kubernetes.io/pvc-as-source-protection` | Source PVC | Deleting the source volume while a snapshot is in flight |

A snapshot stuck `Terminating` is one of these doing its job. Force removing a finalizer deletes the Kubernetes object and **leaves the backend snapshot orphaned**, consuming space nothing accounts for. Fix the failing `DeleteSnapshot` instead; if you must force, record the handle first:

```bash
kubectl get volumesnapshotcontent "${content}" -o jsonpath='{.status.snapshotHandle}{"\n"}'
```

### Scheduled Retention

Kubernetes has **no built-in snapshot schedule and no expiry**. There is no `snapshotSchedule` field anywhere.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-hourly-snapshot
  namespace: databases
spec:
  schedule: "0 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: snapshotter
          containers:
          - name: snap
            image: bitnami/kubectl:latest
            command: ["/bin/bash","-c"]
            args:
              - |
                set -euo pipefail
                NS=databases; PVC=data-postgres-0; KEEP=24
                NAME="pg-$(date -u +%Y%m%d-%H%M%S)"
                cat <<YAML | kubectl apply -f -
                apiVersion: snapshot.storage.k8s.io/v1
                kind: VolumeSnapshot
                metadata:
                  name: ${NAME}
                  namespace: ${NS}
                  labels: { managed-by: pg-hourly-snapshot }
                spec:
                  volumeSnapshotClassName: csi-nfs-snapclass
                  source:
                    persistentVolumeClaimName: ${PVC}
                YAML
                kubectl wait --for=jsonpath='{.status.readyToUse}'=true \
                  "volumesnapshot/${NAME}" -n "${NS}" --timeout=900s
                # Keep the newest KEEP. Sort by creationTimestamp, not by name,
                # so a clock change cannot reorder them.
                kubectl get volumesnapshot -n "${NS}" \
                  -l managed-by=pg-hourly-snapshot \
                  --sort-by=.metadata.creationTimestamp -o name \
                  | head -n "-${KEEP}" | xargs -r kubectl delete -n "${NS}"
```

The ServiceAccount needs a Role granting `get,list,watch,create,delete` on `volumesnapshots` in `snapshot.storage.k8s.io`. Two things this simple CronJob does not do, and a production one must: **alert when `kubectl wait` times out** (a silently failing backup is worse than no backup), and periodically **restore** one of its snapshots to prove they work.

---

## Backup Tooling Context

Hand rolled CronJobs cover the basics. Real backup products add what Kubernetes deliberately leaves out: scheduling, retention, cross cluster restore, and moving data **off** the storage backend.

### Velero

Velero backs up Kubernetes **API objects** to object storage and can back up volume data alongside them. Two broad approaches exist for the volume data:

1. **CSI snapshots.** Velero creates VolumeSnapshot objects for the PVCs in a backup: fast, using the backend's own mechanism. CSI snapshot support was originally delivered through a separate `velero-plugin-for-csi` and was later folded into Velero itself, so which applies depends on the version you run.
2. **Filesystem backup.** Velero reads the files out of the volume and writes them to object storage. Slower, but the copy is genuinely off the storage backend and restorable into a different cluster with a different CSI driver.

Newer Velero versions also offer a **data mover**, which takes a CSI snapshot, mounts it, and copies its contents to object storage: the speed and consistency of a snapshot with the durability of an off-backend copy.

```
┌───────────────────────────────────────────────────────────────────────────┐
│  What Velero adds on top of raw VolumeSnapshots                            │
│   ✓ Backs up the API objects too: Deployments, Services, ConfigMaps,       │
│     Secrets, RBAC. A snapshot alone restores bytes, not a workload.        │
│   ✓ Schedules and retention (TTL) as first-class concepts                  │
│   ✓ Namespace and label selectors, include/exclude rules                   │
│   ✓ Restore into a DIFFERENT namespace or a DIFFERENT cluster              │
│   ✓ Pre and post backup hooks that exec into pods, which is where          │
│     application quiescing belongs                                          │
│   ✓ With filesystem backup or a data mover: data leaves the storage        │
│     backend, the one thing a snapshot can never do                         │
└───────────────────────────────────────────────────────────────────────────┘
```

The hooks point deserves emphasis: Velero's backup hooks are the standard place to run `pg_backup_start` and `pg_backup_stop`, because they run at exactly the right moments around the snapshot and are declared next to the workload rather than in a separate script.

Beyond Velero, many array vendors ship an operator adding schedules, consistency groups and replication on top of their CSI driver via proprietary CRDs; and **application native tooling** (`pg_dump`, `mysqldump`, `mongodump`, `etcdctl snapshot save`) remains the most reliable restore path for a database, application consistent by construction and independent of storage vendor and Kubernetes version.

| Need | Use |
|------|-----|
| Roll back a bad migration in seconds | CSI VolumeSnapshot |
| Nightly protection for a whole namespace | Velero with a schedule |
| Restore into a different cluster | Velero filesystem backup or data mover, or an application dump |
| Survive loss of the storage array | Anything writing to object storage; never a snapshot alone |
| Regulatory retention and immutability | Object storage with object lock, plus application dumps |
| Clone production into staging | PVC clone, or restore from a snapshot |

---

## Command Reference

```bash
# ---- Prerequisites ------------------------------------------------------
kubectl get crd | grep snapshot.storage.k8s.io
kubectl get deploy -A | grep -i snapshot-controller

# ---- Classes ------------------------------------------------------------
kubectl get volumesnapshotclass -o custom-columns=\
'NAME:.metadata.name,DRIVER:.driver,DELETIONPOLICY:.deletionPolicy'
kubectl get volumesnapshotclass -o json | jq -r '
  .items[] | select(.metadata.annotations["snapshot.storage.kubernetes.io/is-default-class"]=="true")
  | "\(.metadata.name)\t\(.driver)"'

# ---- Snapshots ----------------------------------------------------------
kubectl get volumesnapshot -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyToUse,SRCPVC:.spec.source.persistentVolumeClaimName,SIZE:.status.restoreSize,CREATED:.status.creationTime'

# Everything not ready, with its error
kubectl get volumesnapshot -A -o json | jq -r '
  .items[] | select(.status.readyToUse != true)
  | "\(.metadata.namespace)/\(.metadata.name)\t\(.status.error.message // "no error reported")"'

# ---- Contents -----------------------------------------------------------
kubectl get volumesnapshotcontent -o custom-columns=\
'NAME:.metadata.name,READY:.status.readyToUse,POLICY:.spec.deletionPolicy,DRIVER:.spec.driver,HANDLE:.status.snapshotHandle,SNAPSHOT:.spec.volumeSnapshotRef.name'

# ---- Waiting and protecting ---------------------------------------------
kubectl wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/<name> -n <ns> --timeout=600s
content=$(kubectl get volumesnapshot <name> -n <ns> -o jsonpath='{.status.boundVolumeSnapshotContentName}')
kubectl patch volumesnapshotcontent "${content}" --type=merge -p '{"spec":{"deletionPolicy":"Retain"}}'

# ---- Restore verification (the most important check) --------------------
kubectl get pvc <restored> -n <ns> -o jsonpath='{.spec.dataSource}{"\n"}'

# ---- Logs ---------------------------------------------------------------
kubectl logs -n kube-system deploy/snapshot-controller --tail=200
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-snapshotter --tail=200
kubectl get events -n <ns> --field-selector involvedObject.kind=VolumeSnapshot --sort-by=.lastTimestamp
```

---

## Troubleshooting

### `the server doesn't have a resource type "volumesnapshots"`

The CRDs are not installed. That is the whole diagnosis. Install them, then the snapshot controller.

### Snapshot Created but `readyToUse` Never Becomes True

Diagnose by asking how far it got:

```bash
kubectl get volumesnapshot <name> -n <ns> -o json \
  | jq '{bound: .status.boundVolumeSnapshotContentName, ready: .status.readyToUse, error: .status.error}'
```

```
bound: null,  ready: null,  error: null
   ► the snapshot-controller never processed it. Is it running? Crash
     looping? Does it have RBAC?

bound: null,  error: "failed to get input parameters..."
   ► validation failed: the source PVC does not exist, is not Bound, is in
     another namespace, or the class driver does not match the PV's.

bound: snapcontent-...,  ready: false,  error: null
   ► the Content exists but nothing acted on it. Is the csi-snapshotter
     sidecar present? Or the backend is simply still working (asynchronous
     snapshot); give it time.

bound: snapcontent-...,  error: "rpc error: code = ... desc = ..."
   ► the DRIVER refused. The text after desc= is the backend's own message:
     quota, unsupported operation, permissions, source busy.
```

```bash
kubectl logs -n kube-system deploy/snapshot-controller --tail=100
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-snapshotter --tail=100
kubectl logs -n kube-system deploy/csi-nfs-controller -c nfs --tail=100
```

### No csi-snapshotter Sidecar

```bash
kubectl get pod -n kube-system -l app=csi-nfs-controller \
  -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# csi-provisioner liveness-probe nfs      <-- no csi-snapshotter
```

Some drivers ship snapshot support in a separate manifest or behind a Helm value. Others do not implement `CreateSnapshot` at all, in which case no configuration will help.

### The Driver Does Not Support Snapshots

```
Error: rpc error: code = Unimplemented desc = unsupported operation
```

`Unimplemented` is the driver saying so plainly. A `local-path` style provisioner, and non-CSI provisioners such as nfs-subdir-external-provisioner, have no snapshot capability whatsoever. There is no workaround inside this API; use application level backups.

### Restore Produces an Empty Volume

The most damaging failure, because everything reports success.

```bash
kubectl get pvc <restored> -n <ns> -o jsonpath='{.spec.dataSource}{"\n"}'
# (empty)
```

Causes in order of likelihood: an **`apiGroup` typo** (must be exactly `snapshot.storage.k8s.io`, and a wrong value is silently stripped); a **`kind` typo** (`VolumeSnapshot`, capitalised exactly); the **wrong namespace**; or `dataSource` **omitted entirely** by a templating bug such as an unrendered Helm conditional. Use `dataSourceRef` in automation so this becomes a rejection, and add the check above to every restore runbook.

### Restore Size Mismatch

```
Error: ... requested volume size 1073741824 is less than the size
1610612736 for the source snapshot
```

Request exactly `restoreSize`:

```bash
kubectl get volumesnapshot <name> -n <ns> -o jsonpath='{.status.restoreSize}{"\n"}'
```

Requesting **more** is accepted by the API but many drivers restore at the snapshot's size regardless, leaving a PVC whose `status.capacity` is smaller than its request. Expand afterwards instead.

### Cross-Class or Cross-Driver Restore Fails

```bash
kubectl get volumesnapshotcontent <content> -o jsonpath='{.spec.driver}{"\n"}'   # snapshot's driver
kubectl get sc <class> -o jsonpath='{.provisioner}{"\n"}'                        # target class
# These MUST be equal.
```

Restoring across drivers requires copying data through a Job, exactly like a class migration. See [storage-classes.md](storage-classes.md#migrating-workloads-between-classes).

### Snapshot or Source PVC Stuck Terminating

```bash
kubectl get volumesnapshot <name> -n <ns> -o jsonpath='{.metadata.finalizers}' | jq
kubectl get pvc <name> -n <ns> -o jsonpath='{.metadata.finalizers}' | jq
```

Either something is still using it (a restore in flight, a snapshot still being taken) or `DeleteSnapshot` is failing on the backend. Read the sidecar and driver logs; the finalizer clears itself once the real work completes.

### Snapshots Exist on the Backend but Not in Kubernetes

Orphans, usually from `deletionPolicy: Retain` or a forced finalizer removal. Kubernetes cannot enumerate them: the API only knows about objects it has. Reconcile against the backend's own listing, and use the pre-provisioned flow to re-adopt any that should be managed again.

---

## Exam and Interview Traps

1. **Snapshots are not backups.** They live on the same storage backend and share its failure domain. They protect against logical errors, not against losing the array, the site or the cluster.
2. **The snapshot CRDs are not built into the API server.** `kubectl get volumesnapshots` on a fresh cluster errors with "the server doesn't have a resource type", and that error means "install the CRDs".
3. **Two distinct controllers exist:** the cluster wide, driver agnostic **snapshot-controller**, and the per driver **csi-snapshotter** sidecar. The controller never calls CSI; the sidecar never manages the namespaced object.
4. **Installing only the CRDs gives objects with no behaviour.** Installing only the sidecar gives Contents nobody creates.
5. **The API group is `snapshot.storage.k8s.io/v1`,** different from `storage.k8s.io/v1` used by StorageClass and CSIDriver.
6. **VolumeSnapshot is namespaced (like a PVC), VolumeSnapshotContent is cluster scoped (like a PV), VolumeSnapshotClass is cluster scoped (like a StorageClass).**
7. **`deletionPolicy` lives on the class and the Content, never on the VolumeSnapshot,** and it is required on the class with no default.
8. **The default class annotation is `snapshot.storage.kubernetes.io/is-default-class`,** not the same key as the StorageClass one.
9. **`spec.source.volumeHandle` is the SOURCE VOLUME's id (dynamic); `spec.source.snapshotHandle` is an EXISTING SNAPSHOT's id (pre-provisioned).** Swapping them is the classic import failure.
10. **In the pre-provisioned flow you create the cluster scoped Content first,** then the VolumeSnapshot pointing at it with `volumeSnapshotContentName`, leaving `volumeSnapshotRef.uid` empty.
11. **`readyToUse` is the only field that says a snapshot is usable.** The object existing means nothing; asynchronous backends return `false` first.
12. **`restoreSize` is the size of the source volume,** the minimum size of a restore, not the space the snapshot occupies.
13. **You always restore into a NEW PVC.** There is no in-place restore and no rollback verb.
14. **Restore requires the same driver.** Snapshot handles are driver specific, so cross-driver restore does not exist; copy through a Job instead.
15. **Restore and clone are both namespace bound.** `dataSource` cannot cross namespaces; `dataSourceRef` can only with a feature gate and a `ReferenceGrant`.
16. **A restore PVC smaller than `restoreSize` is rejected; larger is often ignored.** Request exactly `restoreSize` and expand afterwards.
17. **`dataSource` accepts only `VolumeSnapshot` and `PersistentVolumeClaim`, and SILENTLY DROPS anything else,** producing an empty volume and a successful-looking restore.
18. **`dataSourceRef` accepts any kind and REJECTS invalid ones,** which is why automation should prefer it. The API server keeps the two in sync where it can, and both are immutable.
19. **A clone (`kind: PersistentVolumeClaim`, `apiGroup: ""`) needs no CRDs and no snapshot-controller,** but it is a one shot copy, not a recovery point.
20. **Snapshots are crash consistent by default.** Application consistency requires quiescing, and Kubernetes has no snapshot hook: it must be orchestrated externally.
21. **There is no consistency group.** Two volumes snapshotted separately are captured at two different instants.
22. **Kubernetes has no snapshot schedule and no expiry.** Retention is a CronJob or a backup product.
23. **Deleting a namespace deletes its VolumeSnapshots,** and with `deletionPolicy: Delete` destroys the backend snapshots too.
24. **Snapshots outlive their source PVC,** though `pvc-as-source-protection` blocks deletion while one is in flight.
25. **Four finalizers exist:** `volumesnapshot-as-source-protection`, `volumesnapshot-bound-protection`, `volumesnapshotcontent-bound-protection` and `pvc-as-source-protection`. A stuck object is one of them doing its job.
26. **Force removing a finalizer orphans a real backend snapshot** that nothing accounts for. Record the `snapshotHandle` first if you must.
27. **`deletionPolicy` can be patched on an existing Content,** the snapshot equivalent of flipping a PV to `Retain`.
28. **`Unimplemented` from the driver means it has no snapshot capability,** and no configuration will change that.
29. **Velero adds what snapshots lack:** API object backup, schedules, retention, cross cluster restore, exec hooks for quiescing, and a copy that actually leaves the storage backend.
30. **A restore that has never been tested is not a backup.** Verify with a checksum, not with a directory listing.

---

## Related Topics

- [StorageClasses](storage-classes.md)
- [Container Storage Interface (CSI)](csi.md)
- [Install csi-driver-nfs](install-csi-nfs.md)
- [Install csi-driver-smb](install-csi-smb.md)
- [StatefulSets](statefulsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [Deployments](deployments.md)
- [Pods](pods.md)
- [Pod Lifecycle](pod-lifecycle.md)
- [Secrets](secrets.md)
- [Controllers](controllers.md)
- [kube-controller-manager](kube-controller-manager.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [etcd](etcd.md)

---

## Key Takeaways

1. A **VolumeSnapshot is a point in time copy taken by the storage backend**, exposed as a declarative, namespaced, RBAC controlled object. Kubernetes provides the vocabulary and lifecycle; the backend does the work.
2. **Snapshots are not backups.** They share the volume's backend and failure domain, and copy on write snapshots share its blocks. They are tier one for logical errors and must be paired with replication and a genuine off-backend backup.
3. The three CRDs mirror the volume objects exactly: **VolumeSnapshotClass is the StorageClass, VolumeSnapshot is the PVC, VolumeSnapshotContent is the PV.** The namespaced object is the request, the cluster scoped object is the reality, the class is the recipe.
4. **The CRDs are not part of the API server** and must be installed from `kubernetes-csi/external-snapshotter` along with a cluster wide **snapshot-controller**. The per driver **csi-snapshotter** sidecar is a third, separate piece. Missing any one produces silent inaction rather than an error.
5. **The snapshot-controller never calls CSI**; it manages objects, binding, finalizers and status. The **csi-snapshotter sidecar** is the only component issuing `CreateSnapshot`, `DeleteSnapshot` and `ListSnapshots`, and only for its own driver.
6. `VolumeSnapshotClass` requires **`driver`** (matching the PVC's driver) and **`deletionPolicy`** (`Delete` or `Retain`, no default). Its default annotation key is `snapshot.storage.kubernetes.io/is-default-class`.
7. **Dynamic flow:** a VolumeSnapshot with `source.persistentVolumeClaimName`; the controller creates a Content with `source.volumeHandle` and the sidecar calls `CreateSnapshot`. **Pre-provisioned flow:** the Content first, with `source.snapshotHandle` and an empty `volumeSnapshotRef.uid`, then a VolumeSnapshot with `source.volumeSnapshotContentName`.
8. **`readyToUse` is the only gate.** Always `kubectl wait` on it before restoring; the object's existence proves nothing.
9. **`restoreSize` is the source volume's size and the minimum size of any restore.** Request exactly that; smaller is rejected and larger is often ignored.
10. **You restore into a NEW PVC using `dataSource`, never in place.** Rolling back is a sequence: stop the workload, restore to a new claim, protect the old PV with `Retain`, repoint, verify at the application level.
11. **Restore and clone are bound to one namespace and one driver.** Crossing either boundary means copying data with a Job.
12. **A clone needs no CRDs and no controller,** but produces a one shot copy rather than a durable recovery point.
13. **`dataSource` silently drops anything it does not recognise, producing an empty volume that looks like a successful restore.** `dataSourceRef` rejects it loudly and enables volume populators. Prefer it in automation and always verify the field survived admission.
14. **Snapshots are crash consistent by default.** Application consistency requires quiescing, Kubernetes has no snapshot hook, and there is no consistency group across volumes.
15. **Retention is not built in.** Build a CronJob with a ServiceAccount and label-based pruning, or use a backup product; and alert when it fails.
16. **`deletionPolicy: Delete` plus `kubectl delete namespace` destroys the backend snapshots.** Patch the Content to `Retain` before anything risky, and remember that four finalizers exist to stop you losing data; forcing them off orphans real storage.
17. **Velero supplies what raw snapshots cannot:** API object backup, schedules and TTL, cross cluster restore, exec hooks for quiescing, and a copy that genuinely leaves the storage backend.
18. **The only proof a snapshot works is a tested restore with a checksum.** Everything short of that is a hypothesis.

---

## References

- [Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
- [Volume Snapshot Classes](https://kubernetes.io/docs/concepts/storage/volume-snapshot-classes/)
- [CSI Volume Cloning](https://kubernetes.io/docs/concepts/storage/volume-pvc-datasource/)
- [Volume Populators and Data Sources](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#volume-populators-and-data-sources)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [VolumeSnapshot API reference (snapshot.storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/volume-snapshot-v1/)
- [VolumeSnapshotContent API reference (snapshot.storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/volume-snapshot-content-v1/)
- [VolumeSnapshotClass API reference (snapshot.storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/volume-snapshot-class-v1/)
- [PersistentVolumeClaim API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/persistent-volume-claim-v1/)
- [Kubernetes CSI Developer Documentation](https://kubernetes-csi.github.io/docs/)
- [CSI Snapshotter](https://kubernetes-csi.github.io/docs/external-snapshotter.html)
- [CSI Volume Snapshot support](https://kubernetes-csi.github.io/docs/snapshot-restore-feature.html)
- [CSI Snapshot Controller](https://kubernetes-csi.github.io/docs/snapshot-controller.html)
- [CSI Volume Cloning](https://kubernetes-csi.github.io/docs/volume-cloning.html)
- [Secrets and Credentials for VolumeSnapshotClass](https://kubernetes-csi.github.io/docs/secrets-and-credentials-volume-snapshot-class.html)
- [external-snapshotter project](https://github.com/kubernetes-csi/external-snapshotter)
- [Container Storage Interface specification](https://github.com/container-storage-interface/spec/blob/master/spec.md)
