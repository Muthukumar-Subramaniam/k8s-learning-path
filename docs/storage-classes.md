# 🗂️ StorageClasses: Named Storage Tiers and the Recipe for Provisioning Them

A complete guide to the StorageClass object: how a cluster offers "fast SSD", "bulk" and "shared RWX" as named tiers, how a PersistentVolumeClaim picks one, and how one line of YAML becomes a real volume mounted in a real container.

## 📋 Table of Contents
- [What a StorageClass Actually Is](#what-a-storageclass-actually-is)
- [The Fully Annotated Manifest](#the-fully-annotated-manifest)
- [Field by Field Reference](#field-by-field-reference)
- [The Default StorageClass](#the-default-storageclass)
- [How a PVC Selects a Class](#how-a-pvc-selects-a-class)
- [Why storageClassName Is Effectively Immutable](#why-storageclassname-is-effectively-immutable)
- [volumeBindingMode: Immediate vs WaitForFirstConsumer](#volumebindingmode-immediate-vs-waitforfirstconsumer)
- [The Scheduler VolumeBinding Plugin](#the-scheduler-volumebinding-plugin)
- [allowedTopologies](#allowedtopologies)
- [reclaimPolicy: On the Class vs On a Static PV](#reclaimpolicy-on-the-class-vs-on-a-static-pv)
- [Dynamic Provisioning End to End](#dynamic-provisioning-end-to-end)
- [Provisioner Parameters in Practice](#provisioner-parameters-in-practice)
- [Volume Expansion and allowVolumeExpansion](#volume-expansion-and-allowvolumeexpansion)
- [mountOptions](#mountoptions)
- [Designing Storage Tiers for a Cluster](#designing-storage-tiers-for-a-cluster)
- [Migrating Workloads Between Classes](#migrating-workloads-between-classes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What a StorageClass Actually Is

A **StorageClass** is two things at once, and confusing them causes most StorageClass mistakes:

1. **A name that application authors consume.** A developer writes `storageClassName: fast-ssd`. That is the entire contract. They never learn the NFS server address, the SAN LUN policy or the encryption key ID.
2. **A recipe that the cluster operator writes.** The operator decides which provisioner implements `fast-ssd`, which parameters it receives, whether the volume is destroyed with the claim, whether it can grow, and *when* it is physically created.

```
┌───────────────────────────────────────────────────────────────────────┐
│                     The StorageClass Contract                          │
├───────────────────────────────────────────────────────────────────────┤
│   APPLICATION AUTHOR                    CLUSTER OPERATOR               │
│   (writes a PVC)                        (writes the StorageClass)      │
│                                                                        │
│   kind: PersistentVolumeClaim           kind: StorageClass             │
│   spec:                                 metadata:                      │
│     storageClassName: fast-ssd  ──────►   name: fast-ssd               │
│     accessModes: [ReadWriteOnce]        provisioner: nfs.csi.k8s.io    │
│     resources:                          parameters:                    │
│       requests:                           server: 10.0.0.20            │
│         storage: 20Gi                     share: /export/fast          │
│                                         reclaimPolicy: Delete          │
│                                         allowVolumeExpansion: true     │
│                                         volumeBindingMode: Immediate   │
│                                                                        │
│   Knows: a name and a size.             Knows: everything else.        │
└───────────────────────────────────────────────────────────────────────┘
```

| Job | Fields | Who cares |
|-----|--------|-----------|
| Select an implementation | `provisioner` | Operator |
| Tune that implementation | `parameters`, `mountOptions` | Operator |
| Define lifecycle and placement policy | `reclaimPolicy`, `allowVolumeExpansion`, `volumeBindingMode`, `allowedTopologies` | Operator and SRE |

### Static vs Dynamic Provisioning

```
STATIC   Admin creates PV ahead of time ──► Developer creates PVC ──► controller binds
DYNAMIC  Developer creates PVC ──► provisioner creates the real volume AND the PV object
```

Static provisioning still works and needs no StorageClass. A StorageClass is the object that makes **dynamic** provisioning possible: its `provisioner` field names the controller that hears about a pending claim and manufactures storage for it.

### It Is Cluster Scoped

```bash
kubectl api-resources | grep -i storageclass
# storageclasses   sc   storage.k8s.io/v1   false   StorageClass
```

`NAMESPACED false` means one flat namespace of names cluster wide, any PVC in any namespace may reference any class, and RBAC on classes is cluster wide. Limiting which teams may use an expensive tier is a job for **ResourceQuota**, keyed `<class>.storageclass.storage.k8s.io/requests.storage`, not for the class itself.

---

## The Fully Annotated Manifest

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  # Cluster scoped: no namespace field. This name is the entire public API of
  # the tier. It cannot be changed in place; you delete and recreate.
  name: fast-ssd
  annotations:
    # Exactly one class in a cluster should carry this. A PVC that omits
    # storageClassName entirely gets this class. Value is the STRING "true".
    storageclass.kubernetes.io/is-default-class: "true"
    description: "Low latency tier for databases. Deleted with the claim."

# WHICH controller provisions volumes. For a CSI driver this MUST equal the
# name the driver reports from GetPluginInfo, which is also the CSIDriver
# object name. The reserved value kubernetes.io/no-provisioner means "no
# dynamic provisioning": use this class only to group static PVs.
provisioner: nfs.csi.k8s.io

# Driver specific key/value pairs, handed to the provisioner verbatim.
# Kubernetes does NOT validate them; the driver does, at CreateVolume time.
# Keys under the reserved csi.storage.k8s.io/ prefix are consumed by the
# external-provisioner sidecar instead. IMMUTABLE after creation.
parameters:
  server: 10.0.0.20
  share: /export/fast
  subDir: ${pvc.metadata.namespace}-${pvc.metadata.name}-${pv.metadata.name}

# What happens to a DYNAMICALLY PROVISIONED PV when its PVC is deleted.
#   Delete (default) - PV object removed, DeleteVolume called, data gone
#   Retain           - PV kept in Released phase, data kept, manual cleanup
# Copied into pv.spec.persistentVolumeReclaimPolicy at provisioning time;
# editing it later affects only volumes provisioned AFTER the edit.
reclaimPolicy: Delete

# May a PVC using this class be grown by editing spec.resources.requests?
# Defaults to false. Also needs driver support for ControllerExpandVolume
# and the external-resizer sidecar. Shrinking is never allowed.
allowVolumeExpansion: true

# WHEN the volume is created and bound.
#   Immediate            - as soon as the PVC exists
#   WaitForFirstConsumer - only once a Pod using the PVC is scheduled
volumeBindingMode: WaitForFirstConsumer

# Written into pv.spec.mountOptions of every volume this class provisions.
# NOT validated by Kubernetes: a bad option is a mount failure at Pod start.
mountOptions:
  - nfsvers=4.1
  - hard
  - noatime

# Restrict WHERE the provisioner may place the volume. Expressions inside one
# term are ANDed; separate terms are ORed; values inside one expression ORed.
allowedTopologies:
- matchLabelExpressions:
  - key: topology.kubernetes.io/zone
    values:
    - us-east-1a
    - us-east-1b
```

### What Is Immutable

```
IMMUTABLE (delete and recreate):  name, provisioner, parameters, volumeBindingMode
EDITABLE, future volumes only:    reclaimPolicy, mountOptions, allowedTopologies
EDITABLE, effective immediately:  allowVolumeExpansion, labels, annotations
```

```bash
kubectl patch sc fast-ssd -p '{"parameters":{"share":"/export/other"}}'
# The StorageClass "fast-ssd" is invalid: parameters: Forbidden:
# updates to parameters are forbidden.
```

The operational consequence: **you change a tier by creating a new class, not by editing the old one.** Existing PVs keep the recipe they were born with, because the parameters were already consumed at `CreateVolume` time.

---

## Field by Field Reference

| Field | Type | Default | Mutable | Notes |
|-------|------|---------|---------|-------|
| `provisioner` | string | required | ❌ | CSI driver name, or `kubernetes.io/no-provisioner` |
| `parameters` | map[string]string | `{}` | ❌ | Opaque to Kubernetes, validated only by the driver |
| `reclaimPolicy` | `Delete` \| `Retain` | `Delete` | ✅ future volumes | `Recycle` is removed |
| `allowVolumeExpansion` | bool | `false` | ✅ | Needs driver support and `external-resizer` |
| `volumeBindingMode` | `Immediate` \| `WaitForFirstConsumer` | `Immediate` | ❌ | Controls *when* binding happens |
| `mountOptions` | []string | none | ✅ future volumes | Copied into each PV |
| `allowedTopologies` | []TopologySelectorTerm | none | ✅ future volumes | Only meaningful for topology aware drivers |

### provisioner

```yaml
provisioner: nfs.csi.k8s.io                               # a CSI driver name
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner  # out-of-tree, non-CSI
provisioner: kubernetes.io/no-provisioner                 # static PVs only
```

`kubernetes.io/no-provisioner` is not a placeholder. It explicitly states that this class exists purely to **group statically created PVs**, most commonly `local` volumes, in which case the class must also set `volumeBindingMode: WaitForFirstConsumer` because a local volume is usable only from the node owning the disk. A PVC naming such a class stays `Pending` until an administrator creates a matching PV by hand. No error, no "there is no provisioner" event: just a claim waiting for supply.

### parameters

Two categories share the map. **Driver parameters** are forwarded verbatim in `CreateVolume`. **Reserved `csi.storage.k8s.io/` keys** are consumed by the external-provisioner sidecar and never reach the driver as parameters:

| Reserved key | Purpose |
|--------------|---------|
| `csi.storage.k8s.io/fstype` | Filesystem to format the volume with |
| `csi.storage.k8s.io/provisioner-secret-name` / `-namespace` | Secret for `CreateVolume` and `DeleteVolume` |
| `csi.storage.k8s.io/controller-publish-secret-name` / `-namespace` | Secret for `ControllerPublishVolume` |
| `csi.storage.k8s.io/node-stage-secret-name` / `-namespace` | Secret for `NodeStageVolume` |
| `csi.storage.k8s.io/node-publish-secret-name` / `-namespace` | Secret for `NodePublishVolume` |
| `csi.storage.k8s.io/controller-expand-secret-name` / `-namespace` | Secret for `ControllerExpandVolume` |

Secret names and namespaces support templating, so one class can serve many namespaces:

```yaml
parameters:
  csi.storage.k8s.io/node-stage-secret-name: "${pvc.name}-creds"
  csi.storage.k8s.io/node-stage-secret-namespace: "${pvc.namespace}"
```

Everything else is defined by the driver. There is no cluster side schema and no `kubectl explain` for a driver's keys, so a misspelled key is either silently ignored or rejected at `CreateVolume` time with a driver specific message that surfaces as an event on the PVC.

---

## The Default StorageClass

```yaml
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
```

The value is the **string** `"true"`. Annotation values are always strings. An older key, `storageclass.beta.kubernetes.io/is-default-class`, is deprecated; write the GA one.

### Who Reads It

The `DefaultStorageClass` **admission controller**. When a PVC is created with **no** `storageClassName` field at all, the plugin writes the default class name into the object during admission. The mutation is permanent and visible:

```bash
kubectl get storageclass
# NAME                PROVISIONER                   RECLAIMPOLICY  VOLUMEBINDINGMODE      EXPANSION
# bulk-nfs            nfs.csi.k8s.io                Delete         Immediate              true
# fast-ssd (default)  nfs.csi.k8s.io                Delete         WaitForFirstConsumer   true
# local-storage       kubernetes.io/no-provisioner  Delete         WaitForFirstConsumer   false
```

### Zero Defaults

Nothing errors. The PVC is stored with `storageClassName` unset (`nil`) and no provisioner is interested in it:

```bash
kubectl describe pvc data
# Status: Pending
# Events:
#   Normal  FailedBinding  no persistent volumes available for this claim
#                          and no storage class is set
```

A workload that never starts, with an event most people never read. This is the most common "my Pod is stuck in Pending" cause on a freshly built cluster: a working CSI driver installed, and nobody marked a class default.

Kubernetes also performs **retroactive default assignment**: a PVC left with a `nil` class because no default existed is updated once a default appears, so previously stuck claims begin provisioning without being recreated. A PVC with an explicit empty string is never touched, because empty string is a deliberate opt out.

### More Than One Default

Easy to create accidentally: an add-on chart ships its own default class and the platform team already had one.

```bash
kubectl get sc -o custom-columns=\
'NAME:.metadata.name,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class'
# NAME           DEFAULT
# bulk-nfs       true
# fast-ssd       true      <-- two defaults
```

The documented behaviour is that the **most recently created** default wins for PVCs that omit the field. Older releases behaved differently and could leave such claims unprovisioned. Neither is something to rely on:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Two defaults is a latent outage, not a tie-break puzzle:             │
│   • The winner depends on creationTimestamp, so reinstalling an       │
│     add-on silently flips which tier new claims land on.              │
│   • A workload on Delete-with-expansion can land on a Retain-without- │
│     expansion tier after a chart upgrade.                             │
│   • Cluster rebuilds apply objects in a different order and get a     │
│     different winner.                                                 │
│  Operational rule: assert exactly one default in CI.                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Moving the Default Safely

Always unset first, so the cluster never has two:

```bash
kubectl patch storageclass fast-ssd \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch storageclass bulk-nfs \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verify exactly one, and use this same query as a CI gate.
kubectl get sc -o json | jq -r '
  [.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")
   | .metadata.name] | "defaults: \(length) \(.)"'
# defaults: 1 ["bulk-nfs"]
```

`"false"` and removing the annotation are equivalent. To remove it outright: `kubectl annotate sc fast-ssd storageclass.kubernetes.io/is-default-class-`.

---

## How a PVC Selects a Class

Three cases, and the difference between two of them is invisible unless you know to look.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    PVC storageClassName semantics                         │
├──────────────────────────────────────────────────────────────────────────┤
│  1. NAMED CLASS       storageClassName: fast-ssd                          │
│     ► Dynamic provisioning by that class. If the class does not exist,    │
│       the claim stays Pending forever (no error at create time).          │
│                                                                           │
│  2. EMPTY STRING      storageClassName: ""                                │
│     ► Explicit opt out. Dynamic provisioning disabled for this claim.     │
│       Admission will NOT fill it in. Binds only to a pre-existing PV      │
│       that itself has no class.                                          │
│                                                                           │
│  3. FIELD OMITTED     (no storageClassName key at all)                    │
│     ► Admission rewrites it to the default class, if one exists. If not,  │
│       it stays nil and is assigned retroactively when a default appears.  │
└──────────────────────────────────────────────────────────────────────────┘
```

### Case 1: A Named Class

```yaml
spec:
  storageClassName: fast-ssd
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 50Gi } }
```

The PV controller stamps an annotation recording which provisioner owns the claim. `volume.kubernetes.io/storage-provisioner` is what the external-provisioner sidecar filters on: it ignores every claim whose annotation does not match its own driver name. Alongside it you will see `pv.kubernetes.io/bind-completed`, `pv.kubernetes.io/bound-by-controller` and a legacy `volume.beta.kubernetes.io/storage-provisioner` twin.

### Case 2: The Empty String

```yaml
spec:
  storageClassName: ""     # deliberately empty, not missing
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 10Gi } }
```

This is how you bind to a hand made PV in a cluster that has a default class. Without it, admission would rewrite the claim to `fast-ssd`, which would then refuse to bind to your classless PV because the class names do not match. The PV must also declare no class: either omit `storageClassName` or set it to `""`, which mean the same thing.

> The legacy PVC annotation `volume.beta.kubernetes.io/storage-class` is
> deprecated. If both it and `spec.storageClassName` are present, the spec
> field wins. Do not write the annotation in new manifests.

### Case 3: Omitted

The portable form for application charts: the same manifest works on a laptop cluster with `local-path` as default and in production with `fast-ssd`. It is also the form that silently changes behaviour when somebody moves the default annotation.

### Binding Rules

A PVC binds to a PV only when **all** of these hold:

```
1. storageClassName matches exactly (including "" == none)
2. PV capacity >= PVC requested storage        ◄── >=, NOT ==
3. PV accessModes is a superset of PVC accessModes
4. PV volumeMode == PVC volumeMode (Filesystem or Block)
5. PV is Available (not Bound, not Released)
6. PVC selector, if any, matches the PV labels
7. PV claimRef, if set, names THIS pvc (pre-binding)
```

Rule 2 is greater-than-or-equal, not exact. A 10Gi claim can bind to a 100Gi static PV, wasting 90Gi. Dynamic provisioning avoids this because the volume is created at the requested size.

---

## Why storageClassName Is Effectively Immutable

**Before binding**, while the PVC is still `Pending`, changing the class is accepted and does re-target provisioning. That is the only useful window, and it is usually a race against the provisioner.

**After binding**, the API server rejects it:

```bash
kubectl patch pvc postgres-data -n databases -p '{"spec":{"storageClassName":"bulk-nfs"}}'
# persistentvolumeclaims "postgres-data" is invalid: spec: Forbidden:
# spec is immutable after creation except resources.requests (for expansion)
# and volumeAttributesClassName (for modification)
```

```
┌────────────────────────────────────────────────────────────────────────┐
│  If editing the class on a bound PVC were allowed:                      │
│                                                                         │
│    PVC ──bound──► PV ──► CSI volume vol-abc123 on nfs.csi.k8s.io        │
│         └── edit class to "bulk-nfs" (provisioner: smb.csi.k8s.io)      │
│                                                                         │
│    The PV still points at an NFS export. The bytes are still on the     │
│    NFS server. Nothing copies them, and nothing CAN: Kubernetes has no  │
│    generic "read this volume, write that volume" primitive, and two     │
│    drivers cannot talk to each other.                                   │
│                                                                         │
│    You would have a claim that lies about where its data lives.         │
└────────────────────────────────────────────────────────────────────────┘
```

A class is not a label; it determined which physical thing was created. Kubernetes refuses the edit rather than let the object become a lie. Moving data between tiers is a copy operation; see [Migrating Workloads Between Classes](#migrating-workloads-between-classes).

### The StatefulSet Corollary

```bash
kubectl patch statefulset postgres -p '{"spec":{"volumeClaimTemplates":[...]}}'
# The StatefulSet "postgres" is invalid: spec: Forbidden: updates to
# statefulset spec for fields other than 'replicas', 'ordinals', 'template',
# 'updateStrategy', 'persistentVolumeClaimRetentionPolicy' and
# 'minReadySeconds' are forbidden
```

Changing the class of a StatefulSet's volumes means recreating the StatefulSet, with `--cascade=orphan` if the Pods must keep running meanwhile. Choose the class for a StatefulSet carefully the first time.

---

## volumeBindingMode: Immediate vs WaitForFirstConsumer

The most consequential field in the object, and the one most often left at its default.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            Immediate                                      │
│   PVC created                                                             │
│      ▼  Provision NOW, in whatever zone the provisioner picks             │
│      ▼  PV exists and is Bound, pinned to that zone                       │
│      ▼  ... later ... Pod is created                                      │
│      ▼  Scheduler MUST place the Pod where the volume already is          │
│         THE VOLUME CONSTRAINS THE POD                                     │
├──────────────────────────────────────────────────────────────────────────┤
│                       WaitForFirstConsumer                                │
│   PVC created                                                             │
│      ▼  Nothing happens. PVC Pending, event: WaitForFirstConsumer         │
│      ▼  Pod created that references the PVC                               │
│      ▼  Scheduler picks a node using cpu, memory, affinity, taints        │
│      ▼  THEN provision, in that node's zone and topology                  │
│         THE POD CONSTRAINS THE VOLUME                                     │
└──────────────────────────────────────────────────────────────────────────┘
```

### The Worked Multi Zone Failure

Three zone cluster, zonal block storage: a volume in `us-east-1a` can only attach to a node in `us-east-1a`.

```
┌────────────────────────┬────────────────────────┬────────────────────────┐
│  zone us-east-1a       │  zone us-east-1b       │  zone us-east-1c       │
│  node-a1  (full: 95%)  │  node-b1  (free)       │  node-c1  (free)       │
│  node-a2  (full: 92%)  │  node-b2  (free)       │  node-c2  (free)       │
└────────────────────────┴────────────────────────┴────────────────────────┘
```

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: zonal-ssd
provisioner: example.csi.vendor.io
volumeBindingMode: Immediate      # <-- the bug
```

**1.** A Deployment is applied. Its PVC is created a moment before its Pod, because the ReplicaSet controller takes a few hundred milliseconds.

**2.** The external-provisioner sees the pending claim immediately. The Pod does not exist yet, so it has no idea where the workload will run. It picks a zone: `us-east-1a`.

**3.** The PV is created with `spec.nodeAffinity` requiring `topology.kubernetes.io/zone In [us-east-1a]`. This is not advisory.

**4.** The Pod is created and the scheduler runs its filters:

```
node-a1: VolumeBinding OK (zone a)  ► NodeResourcesFit FAIL (insufficient cpu)
node-a2: VolumeBinding OK (zone a)  ► NodeResourcesFit FAIL (insufficient memory)
node-b1: VolumeBinding FAIL (volume node affinity conflict)
node-b2: VolumeBinding FAIL (volume node affinity conflict)
node-c1: VolumeBinding FAIL (volume node affinity conflict)
node-c2: VolumeBinding FAIL (volume node affinity conflict)
```

**5.** The Pod is unschedulable, forever, on a cluster with four idle nodes:

```bash
kubectl describe pod web-7d4b9c8f5-x2k9p
# Warning  FailedScheduling  0/6 nodes are available:
#   2 Insufficient cpu, 2 Insufficient memory,
#   4 node(s) had volume node affinity conflict.
```

`volume node affinity conflict` is the fingerprint of this exact problem. Nothing resolves it on its own; scaling up zone `b` does not help. Only freeing capacity in zone `a`, or deleting the PVC and starting over, will.

### How WaitForFirstConsumer Fixes It

Change one field, and the ordering inverts:

**1.** The PVC deliberately does nothing:

```bash
kubectl describe pvc web-data
# Status: Pending
# Events:
#   Normal  WaitForFirstConsumer  waiting for first consumer to be created
#                                 before binding
```

That event is **healthy**, not an error. Alerting on "PVC Pending" without excluding this reason produces permanent false alarms.

**2.** The Pod is created. The scheduler filters on compute only, because no PV exists yet to constrain it. It picks `node-c1`.

**3.** The scheduler's VolumeBinding plugin annotates the PVC with the chosen node in its `PreBind` phase:

```bash
kubectl get pvc web-data -o jsonpath='{.metadata.annotations}' | jq
# { "volume.kubernetes.io/selected-node": "node-c1" }
```

**4.** The external-provisioner is watching for exactly that annotation. It reads `node-c1`, looks up that node's topology from its labels and its `CSINode` object, and issues `CreateVolume` with an accessibility requirement of zone `us-east-1c`.

**5.** The volume is created in zone `c`, the PV binds, the Pod starts. No conflict is possible, because the volume was created *after and because of* the node choice.

### Comparison

| Aspect | `Immediate` | `WaitForFirstConsumer` |
|--------|-------------|------------------------|
| Volume created | On PVC creation | On first Pod scheduling |
| PVC Pending before Pod | No | Yes, by design |
| Multi zone safety | ❌ Can pin to the wrong zone | ✅ Follows the scheduler |
| Works with `local` volumes | ❌ Never | ✅ Required |
| Pod affinity / anti affinity respected | ❌ | ✅ |
| Taints and tolerations respected | ❌ | ✅ |
| Node resource pressure respected | ❌ | ✅ |
| Pre-provision before workloads exist | ✅ | ❌ |
| PVC usable with no Pod | ✅ | Needs a Pod first |

### When Immediate Is Still Correct

Use it for **network attached storage with no topology at all** (an NFS export reachable from every node, where there is no wrong zone to pick), for **pre-seeding data** into a volume before the real workload exists, and for **capacity reservation** on a backend where provisioning is slow enough to want it done in a maintenance window.

For anything zonal, anything node local, and any cluster you expect to grow into multiple failure domains, use `WaitForFirstConsumer`. It is not the API default for historical compatibility reasons, not because it is the worse choice.

---

## The Scheduler VolumeBinding Plugin

```
┌────────────────────────────────────────────────────────────────────────────┐
│                     kube-scheduler: one Pod, one pass                       │
├────────────────────────────────────────────────────────────────────────────┤
│  PreFilter  Gather the Pod's PVCs. A bound PVC's PV nodeAffinity becomes a  │
│             hard constraint. An unbound WaitForFirstConsumer PVC is a       │
│             delayed binding candidate.                                     │
│      ▼                                                                      │
│  Filter     Per node: can every bound PV be reached from here? For each     │
│             delayed PVC, does a suitable Available PV exist for this node,  │
│             or can the class provision into this node's topology (checked   │
│             against allowedTopologies and CSIStorageCapacity)?              │
│      ▼                                                                      │
│  Score      Prefers nodes where an existing PV can be reused.               │
│      ▼                                                                      │
│  Reserve    Records the intended PVC-to-PV assignment in the scheduler      │
│             cache so concurrent Pods do not claim the same PV.              │
│      ▼                                                                      │
│  PreBind    Pre-binds matching PVs via pv.spec.claimRef and sets            │
│             volume.kubernetes.io/selected-node on each PVC still to be      │
│             provisioned. Then WAITS for binding to complete.                │
│      ▼                                                                      │
│  Bind       The Pod is assigned to the node.                                │
└────────────────────────────────────────────────────────────────────────────┘
```

Two consequences follow directly:

1. **Provisioning happens between `PreBind` and `Bind`, and the scheduler blocks on it.** A driver taking 30 seconds to create a volume makes the Pod appear stuck in `Pending` for 30 seconds. That is the backend, not scheduler latency.
2. **If provisioning fails, the scheduler gives up on that node and retries the Pod**, possibly choosing a different node. That is why a Pending PVC's `selected-node` annotation sometimes changes.

```bash
kubectl get pvc web-data -w -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,NODE:.metadata.annotations.volume\.kubernetes\.io/selected-node,PV:.spec.volumeName'
# web-data  Pending   <none>    <none>
# web-data  Pending   node-c1   <none>      <-- scheduler chose the node
# web-data  Pending   node-c1   pvc-9f2e... <-- provisioner created the PV
# web-data  Bound     node-c1   pvc-9f2e...
```

---

## allowedTopologies

Restricts where a provisioner may place a volume. Only meaningful for drivers that report topology (drivers supporting `VOLUME_ACCESSIBILITY_CONSTRAINTS` whose node plugin returns topology keys from `NodeGetInfo`).

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ssd-zone-a-and-b
provisioner: example.csi.vendor.io
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
parameters:
  type: ssd
allowedTopologies:
# Each list item is a TopologySelectorTerm. Terms are ORed.
- matchLabelExpressions:
  # Expressions inside ONE term are ANDed.
  - key: topology.kubernetes.io/zone
    values:
    - us-east-1a
    - us-east-1b        # values within one expression are ORed
  - key: example.csi.vendor.io/rack
    values: ["rack-1", "rack-2"]
# Second term: a completely separate acceptable placement.
- matchLabelExpressions:
  - key: topology.kubernetes.io/zone
    values: ["us-east-1c"]
```

Read that as: (zone in {a,b} AND rack in {1,2}) OR (zone `c`, any rack).

| Combination | Result |
|-------------|--------|
| `Immediate` + `allowedTopologies` | The provisioner picks any allowed segment without knowing the Pod. Narrows the blast radius of a wrong guess but does not eliminate it. |
| `WaitForFirstConsumer` + `allowedTopologies` | The scheduler filters out nodes outside the allowed segments **before** choosing, so Pod and volume are consistent by construction. This is the useful combination. |

If a Pod can only fit on a node outside the allowed segments, you get an unschedulable Pod instead of a misplaced volume: an explicit failure instead of a silent one.

```bash
# What topology labels do the nodes carry?
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'

# What topology keys does the driver claim per node?
kubectl get csinode -o custom-columns=\
'NODE:.metadata.name,DRIVERS:.spec.drivers[*].name,KEYS:.spec.drivers[*].topologyKeys'
```

A key that is not in the driver's `topologyKeys` can never be satisfied, and every provisioning attempt fails.

---

## reclaimPolicy: On the Class vs On a Static PV

```
┌────────────────────────────────────────────────────────────────────────────┐
│   StorageClass.reclaimPolicy                                                │
│      A TEMPLATE VALUE, copied into every PV this class provisions at the    │
│      moment of provisioning. Editing the class changes nothing about        │
│      volumes that already exist.                                            │
│                            │ copied at CreateVolume time                    │
│                            ▼                                                │
│   PersistentVolume.spec.persistentVolumeReclaimPolicy                       │
│      THE VALUE THAT IS ENFORCED, read by the PV controller when the bound   │
│      PVC is deleted. Patchable on a live PV.                                │
│                                                                             │
│   A statically created PV has no class to inherit from, so you write this   │
│   yourself. Omitted on a static PV it defaults to Retain; dynamically       │
│   provisioned PVs default to Delete via the class default.                  │
└────────────────────────────────────────────────────────────────────────────┘
```

| Policy | On PVC deletion | PV phase afterwards | Data |
|--------|-----------------|---------------------|------|
| `Delete` | `DeleteVolume` issued, PV object removed | Gone | Destroyed |
| `Retain` | Nothing called, PV object stays | `Released` | Kept |

`Recycle` was a third policy that ran `rm -rf /thevolume/*` in a scrubber Pod. It is removed; do not put it in a manifest.

### The Released Phase Is a Trap

**A `Released` PV never binds to anything again**, even to a new PVC with an identical name in an identical namespace, because `spec.claimRef` still names the deleted claim including its UID. Clear the stale reference to make it `Available` again:

```bash
kubectl get pv pv-archive -o jsonpath='{.spec.claimRef.uid}{"\n"}'
# 6a1e0d70-6a9f-4f1a-91c1-8f9b0f6b1d2e     <-- a claim that no longer exists
kubectl patch pv pv-archive -p '{"spec":{"claimRef":null}}'
# STATUS becomes Available
```

The old data is still there, and the next claim to bind will see it. That is either deliberate reuse or a data leak between tenants. Decide which before you patch.

### Flipping a Live PV to Retain Before Risky Work

```bash
# Protect every PV bound in a namespace from accidental deletion
kubectl get pvc -n databases -o jsonpath='{.items[*].spec.volumeName}' \
  | xargs -r -n1 kubectl patch pv -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Retroactive and immediate, unlike editing the class. Run it before a chart uninstall, a namespace deletion, or a cluster migration.

### Opposite Defaults, Deliberately

```
StorageClass with reclaimPolicy omitted        ==>  Delete
Static PV with persistentVolumeReclaimPolicy
  omitted (no class to inherit from)           ==>  Retain
```

A volume the cluster made, the cluster may destroy; a volume a human made, the cluster must not touch.

---

## Dynamic Provisioning End to End

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  CONTROL PLANE                              NODE (worker)                     │
│  ┌─────────────────────────┐                ┌──────────────────────────────┐ │
│  │  kube-apiserver         │                │  kubelet                     │ │
│  └───────────┬─────────────┘                └──────────┬───────────────────┘ │
│  ┌───────────▼─────────────┐                ┌──────────▼───────────────────┐ │
│  │ PV controller           │                │ node-driver-registrar        │ │
│  └───────────┬─────────────┘                └──────────┬───────────────────┘ │
│  ┌───────────▼─────────────┐                ┌──────────▼───────────────────┐ │
│  │ external-provisioner    │  ── gRPC ──►   │ CSI driver: NODE service     │ │
│  │ external-attacher       │                └──────────┬───────────────────┘ │
│  └───────────┬─────────────┘                           │ mount(2)            │
│  ┌───────────▼─────────────┐                ┌──────────▼───────────────────┐ │
│  │ CSI driver: CONTROLLER  │                │ /var/lib/kubelet/...          │ │
│  └───────────┬─────────────┘                │   globalmount  (staged)       │ │
│  ┌───────────▼─────────────┐                │   pods/<uid>/... (published)  │ │
│  │  Storage backend         │                └──────────────────────────────┘ │
│  └──────────────────────────┘                                                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

**1. The PVC is created.** The `DefaultStorageClass` admission plugin does nothing if the class is explicit. The object lands in etcd with `status.phase: Pending`.

**2. The PersistentVolume controller stamps ownership.** It sees a Pending claim with a class, finds no matching Available PV, reads the class's `provisioner`, and writes `volume.kubernetes.io/storage-provisioner: nfs.csi.k8s.io`. Under `WaitForFirstConsumer` it emits the `WaitForFirstConsumer` event and stops until the scheduler sets `volume.kubernetes.io/selected-node`.

**3. The external-provisioner sidecar picks it up.** It watches PVCs cluster wide, filters on that annotation matching its own driver name, and builds a request from the StorageClass parameters, the requested size, the access modes and (for topology aware drivers) the selected node's topology.

**4. `CreateVolume` is called on the CSI Controller service.**

```
external-provisioner ──gRPC──► /csi/csi.sock
  CreateVolume{
    name: "pvc-9f2e5c31-...",
    capacity_range: { required_bytes: 21474836480 },
    volume_capabilities: [{ mount: { fs_type: "ext4" }, access_mode: SINGLE_NODE_WRITER }],
    parameters: { "server": "10.0.0.20", "share": "/export/fast" },
    accessibility_requirements: { preferred: [{ segments:
        {"topology.kubernetes.io/zone":"us-east-1c"} }] }
  }
  ◄── CreateVolumeResponse{ volume: { volume_id: "10.0.0.20#export/fast#pvc-9f2e...",
                                      capacity_bytes: 21474836480 } }
```

The driver does whatever its backend requires and returns an opaque `volume_id`, which becomes the PV's `volumeHandle`. `CreateVolume` **must be idempotent**: sidecars retry aggressively, so a non idempotent driver leaks volumes.

**5. The PV object is created**, named `pvc-<pvc-uid>`, filling in what the class specified and what the driver returned:

```yaml
spec:
  capacity: { storage: 20Gi }
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Delete            # from the class
  storageClassName: fast-ssd                       # from the class
  mountOptions: ["nfsvers=4.1","hard","noatime"]   # from the class
  claimRef:                                        # pre-bound to the claim
    kind: PersistentVolumeClaim
    name: web-data
    namespace: web
    uid: 9f2e5c31-8b4a-4d21-9c7e-1a2b3c4d5e6f
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: "10.0.0.20#export/fast#pvc-9f2e5c31..."
    volumeAttributes: { server: "10.0.0.20", share: "/export/fast" }
```

The annotation `pv.kubernetes.io/provisioned-by: nfs.csi.k8s.io` records who made it.

**6. The PV controller completes the bind.** It sets `pvc.spec.volumeName`, moves both objects to `Bound`, and adds `pv.kubernetes.io/bind-completed: "yes"`. The `kubernetes.io/pvc-protection` and `kubernetes.io/pv-protection` finalizers prevent deletion while in use.

**7. The scheduler places the Pod.** Under `Immediate` this happens against a fixed PV; under `WaitForFirstConsumer` the node choice already drove step 3.

**8. `ControllerPublishVolume` attaches the volume to the node**, but only if the driver's `CSIDriver` object sets `attachRequired: true`. The external-attacher acts on a `VolumeAttachment` (`storage.k8s.io/v1`) created by the attach/detach controller, carrying `spec.attacher`, `spec.nodeName`, `spec.source.persistentVolumeName` and `status.attached`. For NFS and SMB there is nothing to attach, so those drivers set `attachRequired: false` and this step, along with the object itself, does not exist.

**9. `NodeStageVolume` mounts the volume once per node**, at a global staging path under `/var/lib/kubelet/plugins/kubernetes.io/csi/...` ending in `globalmount`. Ten Pods on this node using this volume trigger this once.

**10. `NodePublishVolume` bind mounts into the Pod directory**, at `/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pv-name>/mount`, once per Pod.

**11. The container runtime mounts it into the container** at the container's `volumeMounts.mountPath`. The application sees a normal directory.

Steps 8 to 10 are invisible in `kubectl get pvc`, which reports `Bound` from step 6 onward. **A Pod stuck in `ContainerCreating` with a `Bound` PVC is failing somewhere in steps 8 to 10**, and the evidence is in Pod events and the kubelet log, not in the PVC.

---

## Provisioner Parameters in Practice

Only parameters the referenced projects actually document appear here. When adopting any driver, read its own `docs/driver-parameters.md`; the set changes between releases.

### csi-driver-nfs

Driver name `nfs.csi.k8s.io`. Install: [install-csi-nfs.md](install-csi-nfs.md).

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs.internal.example.com     # NFS server hostname or IP
  share: /export/k8s                   # exported path; one subdir per volume
  # Optional layout of the per-volume subdirectory. Supports
  # ${pvc.metadata.name}, ${pvc.metadata.namespace}, ${pv.metadata.name}.
  subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}
  mountPermissions: "0777"             # chmod on the created directory
  onDelete: "archive"                  # delete (default) | retain | archive
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nfsvers=4.1
  - hard
  - timeo=600
  - retrans=2
  - noresvport
```

- NFS is a shared filesystem, so this class can legitimately serve `ReadWriteMany`. Access modes are declarations Kubernetes uses when matching claims; the protocol does not enforce them.
- `hard` blocks I/O indefinitely if the server is unreachable; `soft` returns errors. Databases want `hard`; a process that must never hang wants `soft` plus application level retry.
- `noresvport` avoids mount failures after a reconnect exhausts reserved ports.
- `attachRequired` is false for this driver, so no VolumeAttachment objects exist and step 8 above is skipped.

### csi-driver-smb

Driver name `smb.csi.k8s.io`. Install: [install-csi-smb.md](install-csi-smb.md).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: smb-creds
  namespace: kube-system
type: Opaque
stringData:
  username: svc_k8s
  password: "replace-me"
  # domain: CORP    # for a domain account
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smb-csi
provisioner: smb.csi.k8s.io
parameters:
  source: //fileserver.corp.example.com/k8s          # UNC path of the share
  subDir: ${pvc.metadata.namespace}-${pvc.metadata.name}
  # SMB mounts are authenticated, so the node-stage secret is mandatory.
  csi.storage.k8s.io/node-stage-secret-name: smb-creds
  csi.storage.k8s.io/node-stage-secret-namespace: kube-system
  csi.storage.k8s.io/provisioner-secret-name: smb-creds
  csi.storage.k8s.io/provisioner-secret-namespace: kube-system
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=1000
  - gid=1000
  - mfsymlinks        # emulate symlinks over SMB; most Linux workloads need it
  - cache=strict
  - noserverino
```

`mfsymlinks` and the `uid`/`gid`/`*_mode` options are not decoration: without them a Linux container writing to an SMB share commonly fails on permissions or symlink creation, and it surfaces as an application bug rather than a storage one.

### nfs-subdir-external-provisioner

**Not** a CSI driver. An out of tree provisioner that watches PVCs and creates subdirectories on an NFS export it has mounted itself. The provisioner name is whatever the Deployment's `PROVISIONER_NAME` says. Upstream manifests use `k8s-sigs.io/nfs-subdir-external-provisioner`; Helm installs commonly use a `cluster.local/<release>` form, so **read your own Deployment first**:

```bash
kubectl -n nfs-provisioner get deploy nfs-subdir-external-provisioner \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PROVISIONER_NAME")].value}{"\n"}'
```

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-subdir
# MUST match PROVISIONER_NAME in the provisioner Deployment exactly.
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  # "true": rename the directory to archived-<ns>-<pvc> instead of removing it
  archiveOnDelete: "false"
  # Alternative that takes precedence when set: delete | retain | archive
  onDelete: "retain"
  pathPattern: "${.PVC.namespace}/${.PVC.name}"
reclaimPolicy: Delete
volumeBindingMode: Immediate
```

Two warnings specific to it: **`archiveOnDelete` and `reclaimPolicy` are different knobs that both talk about deletion** (`reclaimPolicy: Delete` tells Kubernetes to invoke the provisioner's delete path, `archiveOnDelete: "true"` tells the provisioner to rename rather than remove once it gets there, and with `reclaimPolicy: Retain` the provisioner is never asked at all); and **it does not implement expansion**, so `allowVolumeExpansion: true` on such a class gives you a claim that accepts a size edit and then never grows, because the "size" was only ever a directory that nobody quotas.

### local-path (Rancher local-path-provisioner)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
# Mandatory: the volume is a directory on ONE node's disk.
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
```

Configuration lives in the provisioner's `local-path-config` ConfigMap, not in `parameters`. A `local-path` volume survives Pod restarts, does **not** survive node loss, and can never be `ReadWriteMany` across nodes.

---

## Volume Expansion and allowVolumeExpansion

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. The StorageClass says allowVolumeExpansion: true                  │
│  2. The CSI driver implements ControllerExpandVolume, and             │
│     NodeExpandVolume too if the filesystem must be grown              │
│  3. The external-resizer sidecar is deployed with the driver          │
│                                                                       │
│  Miss any one and the PVC edit is accepted but nothing grows.         │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Edit only the request. Everything else on a bound PVC is immutable.
kubectl patch pvc web-data -n web -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'

kubectl get pvc web-data -n web -o custom-columns=\
'NAME:.metadata.name,REQUESTED:.spec.resources.requests.storage,ACTUAL:.status.capacity.storage'
# web-data  50Gi  20Gi     <-- resize in progress
# web-data  50Gi  50Gi     <-- done
```

`status.capacity` is the truth; `spec.resources.requests` is the ask. The PVC gains conditions during the operation:

```bash
kubectl describe pvc web-data -n web
# Conditions:
#   Type                      Status
#   FileSystemResizePending   True
# Events:
#   Normal  Resizing                    external-resizer nfs.csi.k8s.io
#   Normal  FileSystemResizeSuccessful  MountVolume.NodeExpandVolume succeeded
```

`FileSystemResizePending` means the backend volume grew but the filesystem inside it has not. For drivers needing a node side resize it clears at the next mount, or online for drivers that support it.

| Rule | Consequence |
|------|-------------|
| Shrinking is never supported | A patch to a smaller size is rejected |
| Editing the class to `true` later works | One of the few mutable class fields, and it applies to existing PVCs of that class |
| Editing the class to `false` later | Blocks new expansions; does not undo completed ones |
| Some drivers need offline expansion | The filesystem grows at the next mount, so the Pod must restart |

---

## mountOptions

Copied into `pv.spec.mountOptions` for every volume the class provisions and handed to the driver at stage and publish time. Three properties matter: **Kubernetes never validates them**, so a typo is a mount failure at first Pod start rather than an API rejection; **they are baked into each PV at creation**, so editing the class does not fix existing volumes (patch `pv.spec.mountOptions` and restart the Pods); and **a driver may reject or filter options it considers unsafe**.

```bash
kubectl describe pod web-0 | sed -n '/Events/,$p'
# Warning  FailedMount  MountVolume.SetUp failed for volume "pvc-9f2e..." :
#   rpc error: code = Internal desc = mount failed: exit status 32
#   mount.nfs: an incorrect mount option was specified
```

`exit status 32` from `mount.nfs` almost always means a bad option or an unreachable server; the line after it distinguishes the two.

---

## Designing Storage Tiers for a Cluster

A workable default for a self managed cluster is three named tiers plus one escape hatch. The names are the API your developers see, so make them descriptive and stable.

```
┌──────────────┬─────────────┬───────────┬──────────┬─────────────────────────┐
│  Class       │ Backing     │ Access    │ Reclaim  │ Intended for            │
├──────────────┼─────────────┼───────────┼──────────┼─────────────────────────┤
│  fast-ssd    │ local NVMe  │ RWO       │ Retain   │ databases               │
│  bulk-nfs    │ NFS         │ RWO/RWX   │ Delete   │ logs, artifacts, media  │
│  shared-rwx  │ NFS/SMB     │ RWX       │ Retain   │ shared config, uploads  │
│  scratch     │ local path  │ RWO       │ Delete   │ CI, caches, throwaway   │
└──────────────┴─────────────┴───────────┴──────────┴─────────────────────────┘
```

```yaml
# Tier 1: fastest and most fragile. Paired with statically created local PVs.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
  annotations:
    description: "Node-local NVMe. Highest IOPS. Does NOT survive node loss."
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer   # node-local: follow the scheduler
reclaimPolicy: Retain                     # database data, never auto-delete
allowVolumeExpansion: false               # static PVs cannot be grown
---
# Tier 2: the DEFAULT, so it must be the safest, most portable option rather
# than the fastest. Network attached, node independent, expandable.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: bulk-nfs
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs.internal.example.com
  share: /export/k8s-bulk
  subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}
  mountPermissions: "0770"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions: ["nfsvers=4.1","hard","timeo=600","retrans=2","noresvport","noatime"]
---
# Tier 3: same physical server as bulk-nfs, different export, permissions and
# reclaim policy. A CLASS IS A POLICY AS MUCH AS A DEVICE.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: shared-rwx
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs.internal.example.com
  share: /export/k8s-shared
  subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}
  mountPermissions: "0777"
  onDelete: "retain"
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions: ["nfsvers=4.1","hard","noresvport"]
```

A fourth class, `scratch`, backed by `rancher.io/local-path` with `reclaimPolicy: Delete`, gives CI and caches an explicitly disposable tier.

### Consuming Two Tiers in One Workload

```yaml
  # StatefulSet spec, abridged. Node-local storage means node loss is replica
  # loss, so spread replicas across hosts.
  template:
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: { app: postgres }
  volumeClaimTemplates:
  - metadata: { name: data }
    spec:
      storageClassName: fast-ssd     # IOPS; Postgres itself provides the replicas
      accessModes: ["ReadWriteOnce"]
      resources: { requests: { storage: 200Gi } }
  - metadata: { name: backups }
    spec:
      storageClassName: bulk-nfs     # durability; latency does not matter here
      accessModes: ["ReadWriteOnce"]
      resources: { requests: { storage: 500Gi } }
```

Two tiers chosen for opposite reasons: the hot path wants IOPS and accepts fragility because Postgres replicates; the backup path wants durability and accepts latency.

### Enforcing Tier Usage With Quota

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: storage-tiers
  namespace: team-alpha
spec:
  hard:
    fast-ssd.storageclass.storage.k8s.io/requests.storage: 500Gi
    fast-ssd.storageclass.storage.k8s.io/persistentvolumeclaims: "5"
    bulk-nfs.storageclass.storage.k8s.io/requests.storage: 10Ti
    requests.storage: 12Ti
    persistentvolumeclaims: "50"
```

This is the correct place to say "this team may not fill the NVMe tier", because RBAC on a cluster scoped StorageClass cannot express a per namespace budget.

---

## Migrating Workloads Between Classes

You cannot change the class of a bound PVC, so every real migration is: **provision new, copy data, switch the workload, verify, delete old.**

```
┌──────────────────────────────────────────────────────────────────────────┐
│  MIGRATION: bulk-nfs  ──►  fast-ssd                                       │
│   1. Create a NEW PVC on the target class                                │
│   2. Stop writes (scale to 0, or put the app in read-only mode)          │
│   3. Run a copy Job that mounts BOTH PVCs                                │
│   4. Verify: file counts, byte counts, checksums                        │
│   5. Point the workload at the new PVC                                  │
│   6. Start it and verify at the APPLICATION level                       │
│   7. Only then delete the old PVC                                       │
│                                                                           │
│   No step skips the copy. Kubernetes has no primitive that moves bytes   │
│   between two different storage backends.                                │
└──────────────────────────────────────────────────────────────────────────┘
```

```yaml
# 1. The new claim, at least as large as the old one.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: web-data-fast
  namespace: web
spec:
  storageClassName: fast-ssd
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 50Gi } }
```

```bash
# 2. Quiesce. Copying a filesystem under a running application produces a
#    copy that is consistent with nothing.
kubectl scale deployment web -n web --replicas=0
kubectl wait --for=delete pod -l app=web -n web --timeout=300s
```

```yaml
# 3. The copy Job. Both PVCs must attach to the same node at the same time,
#    which is exactly why WaitForFirstConsumer matters for the new one.
apiVersion: batch/v1
kind: Job
metadata:
  name: migrate-web-data
  namespace: web
spec:
  backoffLimit: 0     # a failed half-copy must not be retried onto a partial target
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: copy
        image: registry.k8s.io/busybox:1.27.2
        command: ["/bin/sh","-c"]
        args:
          - |
            set -eu
            cp -a /source/. /target/     # -a preserves mode, ownership, times
            sync
            echo "files source: $(find /source -type f | wc -l)"
            echo "files target: $(find /target -type f | wc -l)"
        volumeMounts:
        - { name: source, mountPath: /source, readOnly: true }
        - { name: target, mountPath: /target }
      volumes:
      - name: source
        persistentVolumeClaim: { claimName: web-data, readOnly: true }
      - name: target
        persistentVolumeClaim: { claimName: web-data-fast }
```

For large trees, `rsync -aHAX --numeric-ids --info=progress2` in an image that has it beats `cp`, and it can be re-run to catch a final delta after a short quiesce window. For anything that matters, compare checksums (`find /source -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum`) rather than counts.

```bash
# 5. Switch the workload.
kubectl patch deployment web -n web --type=json -p='[
  {"op":"replace",
   "path":"/spec/template/spec/volumes/0/persistentVolumeClaim/claimName",
   "value":"web-data-fast"}]'
kubectl scale deployment web -n web --replicas=3
kubectl rollout status deployment/web -n web

# 7. Retire the old volume, carefully.
old_pv=$(kubectl get pvc web-data -n web -o jsonpath='{.spec.volumeName}')
kubectl patch pv "${old_pv}" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl delete pvc web-data -n web
kubectl get pv "${old_pv}"
# STATUS: Released   RECLAIM POLICY: Retain
```

Leave it `Released` for as long as your rollback window requires, then delete the PV and clean the backend.

### The StatefulSet Variant

A StatefulSet's PVCs are named `<template>-<statefulset>-<ordinal>` and survive the StatefulSet by default. Delete the StatefulSet with `--cascade=orphan`, run per-ordinal copy Jobs, delete the old PVCs (with their PVs on `Retain`), create replacements carrying the **same names**, then re-apply the StatefulSet with the new class in its `volumeClaimTemplate`. The controller matches PVCs by name, so the new volumes must end up named as expected. Snapshot and clone based approaches (see [volume-snapshots.md](volume-snapshots.md)) are far less painful when both classes use the same CSI driver.

### What Does Not Work

| Attempt | Result |
|---------|--------|
| Edit `pvc.spec.storageClassName` | Rejected: spec is immutable after binding |
| Edit `pv.spec.storageClassName` | Accepted, but the volume is unchanged; you have made the PV lie |
| Delete and recreate the PVC with a new class | New empty volume; old data gone or orphaned |
| Snapshot on class A, restore on class B | Only within a single driver; a snapshot handle is driver specific |
| `kubectl cp` | Works for small trees, loses ownership and xattrs, slow; use a Job |

---

## Command Reference

```bash
# ---- Inspecting classes -------------------------------------------------
kubectl get sc
kubectl describe sc fast-ssd
kubectl get sc -o custom-columns=\
'NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode,EXPAND:.allowVolumeExpansion'

# ---- Who is using what --------------------------------------------------
kubectl get pvc -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName,SIZE:.status.capacity.storage,PV:.spec.volumeName'

kubectl get pvc -A -o jsonpath='{range .items[*]}{.spec.storageClassName}{"\n"}{end}' \
  | sort | uniq -c | sort -rn

# ---- Provisioning diagnostics -------------------------------------------
kubectl describe pvc <name> -n <ns>
kubectl get pvc <name> -n <ns> -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/storage-provisioner}{"\n"}'
kubectl get pvc <name> -n <ns> -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/selected-node}{"\n"}'

# ---- Class management ---------------------------------------------------
kubectl annotate sc old-default storageclass.kubernetes.io/is-default-class-
kubectl annotate sc new-default storageclass.kubernetes.io/is-default-class=true
kubectl patch sc bulk-nfs -p '{"allowVolumeExpansion":true}'

# ---- Protecting data ----------------------------------------------------
kubectl get pvc -n <ns> -o jsonpath='{.items[*].spec.volumeName}' \
  | xargs -r -n1 kubectl patch pv -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl patch pv <pv> -p '{"spec":{"claimRef":null}}'   # make Released bindable
kubectl get pv --field-selector status.phase=Released
kubectl get pvc -A --field-selector status.phase=Pending
```

---

## Troubleshooting

### PVC Stuck Pending

Read `kubectl describe pvc <name> -n <ns>` events first. Causes in frequency order:

```
"waiting for first consumer to be created before binding"
   ► NOT AN ERROR. WaitForFirstConsumer with no Pod yet. Create the Pod.

"no persistent volumes available for this claim and no storage class is set"
   ► The PVC has no class and there is no default.

"storageclass.storage.k8s.io \"fast-ssd\" not found"
   ► Typo, deleted class, or the wrong cluster.

no events at all, provisioner annotation IS set
   ► The external-provisioner for that driver is not running, is crash
     looping, or is filtering on a different driver name.

"failed to provision volume with StorageClass ...: rpc error: ..."
   ► The driver rejected CreateVolume. The text after "desc =" is the
     driver's own message: bad parameters, no capacity, auth failure.
```

```bash
kubectl get sc                                     # does the class exist?
kubectl get pods -A | grep -Ei 'provisioner|csi.*controller'
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-provisioner --tail=100
kubectl get csidrivers                             # is the driver registered?
```

### Pod Stuck in ContainerCreating With a Bound PVC

The claim is fine; the problem is between attach and mount.

| Event text | Meaning | Look next at |
|------------|---------|--------------|
| `Unable to attach or mount volumes: unmounted volumes=[data]` | Generic timeout wrapper | The events below it |
| `volume node affinity conflict` | PV pinned to a zone or node the Pod cannot use | `volumeBindingMode`; recreate the volume |
| `Multi-Attach error for volume` | An RWO volume is still attached to another node | Old Pod not fully terminated, or a `NotReady` node |
| `rpc error: ... NodeStageVolume ... mount failed` | The node cannot reach or authenticate to the backend | Node network, firewall, credentials Secret |
| `MountVolume.SetUp failed ... permission denied` | Export permissions or `fsGroup` mismatch | Export options, `mountPermissions`, `securityContext` |
| `driver name X not found in the list of registered CSI drivers` | Node plugin not running or unregistered here | The node DaemonSet, `node-driver-registrar` logs |

**Multi-Attach** deserves a note: an RWO volume attaches to one node only. During a rolling update where the new Pod lands elsewhere before the old one released the volume, it usually clears within a few minutes. It does **not** clear when the old node is `NotReady`, because the attach/detach controller will not force detach from a node it cannot confirm is gone.

### Volume Expansion Does Nothing

```bash
kubectl get sc fast-ssd -o jsonpath='{.allowVolumeExpansion}{"\n"}'
kubectl logs -n kube-system deploy/csi-nfs-controller -c csi-resizer --tail=50
```

If the driver never implemented `ControllerExpandVolume`, none of this errors: the request sits in `spec` and `status.capacity` never moves. That silence is the symptom.

### PV Stuck Terminating

```bash
kubectl get pv <name> -o jsonpath='{.metadata.finalizers}{"\n"}'
# ["kubernetes.io/pv-protection","external-provisioner.volume.kubernetes.io/finalizer"]
```

Do not remove finalizers as a first response. A finalizer that will not clear means a controller is failing real work (usually `DeleteVolume` returning an error), and forcing it leaves an orphaned volume on the backend that nobody will ever find. Read the provisioner log first.

---

## Exam and Interview Traps

1. **A StorageClass is cluster scoped.** No `namespace` field, and any PVC in any namespace may reference any class.
2. **`storageClassName: ""` and an omitted `storageClassName` are different.** Empty string opts out of dynamic provisioning permanently; omitting it invites the default class in during admission.
3. **Zero default classes is not an error.** The PVC sits `Pending` with `no storage class is set` in its events, and nothing ever times out.
4. **More than one default is a configuration bug.** The documented behaviour is that the most recently created default wins, so an add-on reinstall can silently change which tier new claims land on. Assert exactly one in CI.
5. **The annotation value is the string `"true"`.** Annotations cannot hold booleans.
6. **`provisioner`, `parameters` and `volumeBindingMode` are immutable.** You change a tier by creating a new class.
7. **`reclaimPolicy` on a class is a template.** Editing it affects only future volumes. The enforced value is `pv.spec.persistentVolumeReclaimPolicy`, patchable on a live PV.
8. **Default reclaim policies are opposite:** `Delete` for dynamically provisioned (via the class default), `Retain` for a static PV that omits the field.
9. **`Recycle` is removed.** Only `Delete` and `Retain` exist.
10. **`volumeBindingMode` defaults to `Immediate`,** which is wrong for any zonal or node local storage. It produces `volume node affinity conflict` on a cluster with plenty of free capacity.
11. **`WaitForFirstConsumer` makes `Pending` the healthy state** until a Pod appears. Alerting on PVC Pending without excluding that reason gives permanent false positives.
12. **The scheduler, not the provisioner, chooses the node under `WaitForFirstConsumer`,** communicating it through `volume.kubernetes.io/selected-node` on the PVC.
13. **`allowedTopologies` only constrains the provisioner.** With `Immediate` it narrows a guess; with `WaitForFirstConsumer` it actually filters candidate nodes.
14. **Inside one `matchLabelExpressions` term, expressions are ANDed and values ORed; separate terms are ORed.**
15. **`storageClassName` on a bound PVC is immutable.** Only a larger `resources.requests.storage` is accepted, and only when the class allows expansion.
16. **Expansion needs three things:** the class flag, driver support for `ControllerExpandVolume`, and the `external-resizer` sidecar. Missing any makes the edit succeed and the volume stay the same size.
17. **Shrinking a volume is never supported.**
18. **`kubernetes.io/no-provisioner` is a real, meaningful value** for classes that exist only to group static PVs, typically `local`.
19. **A `local` PV must declare `nodeAffinity`,** and its class must use `WaitForFirstConsumer`.
20. **PV to PVC binding uses capacity `>=`, not `==`.** A 1Gi claim can consume a 1Ti static PV.
21. **A `Retain` PV goes to `Released` and never rebinds** until `spec.claimRef` is cleared, because the stale reference includes the deleted claim's UID.
22. **`mountOptions` and `parameters` are not validated by Kubernetes.** A bad mount option is a `FailedMount` at Pod start; a misspelled parameter is the driver's problem, reported as an event on the PVC.
23. **Keys under `csi.storage.k8s.io/` are consumed by the external-provisioner sidecar,** not forwarded to the driver as parameters.
24. **The `provisioner` field must exactly match the CSI driver name,** which is also the `CSIDriver` object name and what `GetPluginInfo` returns.
25. **Two classes can share one backend.** A class encodes policy as much as hardware, and a StatefulSet's `volumeClaimTemplates` cannot be edited, so its class is effectively permanent.
26. **Migrating between classes always means copying data.** Snapshot based shortcuts work only within a single driver.
27. **ResourceQuota, not RBAC, limits a namespace's use of an expensive tier,** via `<class>.storageclass.storage.k8s.io/requests.storage`.
28. **`status.capacity` is the truth; `spec.resources.requests` is the request.** During an expansion they differ, and that difference is how you know a resize is in flight.

---

## Related Topics

- [Container Storage Interface (CSI)](csi.md)
- [Volume Snapshots](volume-snapshots.md)
- [Install csi-driver-nfs](install-csi-nfs.md)
- [Install csi-driver-smb](install-csi-smb.md)
- [StatefulSets](statefulsets.md)
- [Deployments](deployments.md)
- [Pods](pods.md)
- [Secrets](secrets.md)
- [kube-scheduler](kube-scheduler.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kubelet](kubelet.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [Controllers](controllers.md)
- [Worker Node](worker-node.md)

---

## Key Takeaways

1. A StorageClass is **a name a developer consumes plus a provisioning recipe an operator writes**. The developer's entire interface is one string.
2. It is **cluster scoped** in `storage.k8s.io/v1`. Per namespace limits belong in a ResourceQuota keyed `<class>.storageclass.storage.k8s.io/requests.storage`.
3. `provisioner` must **exactly match** the CSI driver name. `kubernetes.io/no-provisioner` is the explicit "static PVs only" value.
4. `parameters` are **opaque to Kubernetes and validated only by the driver**, except reserved `csi.storage.k8s.io/` keys consumed by the external-provisioner for secrets and fstype.
5. **`provisioner`, `parameters` and `volumeBindingMode` are immutable.** You evolve a tier by creating a new class; existing volumes keep the recipe they were born with.
6. Exactly **one** class should carry `storageclass.kubernetes.io/is-default-class: "true"`. Zero leaves classless PVCs Pending with a quiet event; multiple resolve to the most recently created, making tier assignment depend on install order.
7. A PVC picks a class three ways: **named**, **empty string** (opt out, bind only to a classless PV), or **omitted** (admission injects the default, retroactively if one appears later).
8. **A bound PVC's `storageClassName` is immutable**, because the class already determined which physical volume exists and no edit can move bytes. Only a larger size request is accepted.
9. `Immediate` lets **storage dictate scheduling**; `WaitForFirstConsumer` lets **scheduling dictate storage**. In a multi zone or node local cluster, `Immediate` produces `volume node affinity conflict` and a permanently unschedulable Pod while nodes sit idle.
10. Under `WaitForFirstConsumer` the scheduler's **VolumeBinding plugin** picks the node and writes `volume.kubernetes.io/selected-node` in `PreBind`; the provisioner reads it to place the volume. `Pending` is healthy until then.
11. In `allowedTopologies`, expressions within a term are **ANDed**, values within an expression **ORed**, and separate terms **ORed**. It is most useful alongside `WaitForFirstConsumer`.
12. `reclaimPolicy` on the class is a **template**; the enforced field is `pv.spec.persistentVolumeReclaimPolicy`. Dynamic volumes default to `Delete`, hand written PVs to `Retain`, and `Recycle` no longer exists.
13. A `Retain` PV becomes **`Released` and never rebinds** until `spec.claimRef` is cleared.
14. The dynamic path is: **PVC created, provisioner annotation set, [node selected], `CreateVolume`, PV written, controller binds, Pod scheduled, `ControllerPublishVolume`, `NodeStageVolume`, `NodePublishVolume`, container mount.** A `Bound` PVC with a `ContainerCreating` Pod is failing in the last three steps.
15. `allowVolumeExpansion` needs the class flag, driver support and the `external-resizer` sidecar; missing any one is a silent no-op, and shrinking is never possible. `mountOptions` are likewise baked into each PV at creation and never validated by Kubernetes.
16. Design tiers around **policy as much as hardware**: two classes over one NFS server differing only in reclaim policy and permissions is a legitimate design.
17. **Migration between classes is always a copy**: quiesce, run a Job mounting both claims, verify checksums, repoint, and delete the old claim only after flipping its PV to `Retain`.

---

## References

- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Dynamic Volume Provisioning](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Change the Default StorageClass](https://kubernetes.io/docs/tasks/administer-cluster/change-default-storage-class/)
- [Change the Reclaim Policy of a PersistentVolume](https://kubernetes.io/docs/tasks/administer-cluster/change-pv-reclaim-policy/)
- [Storage Capacity](https://kubernetes.io/docs/concepts/storage/storage-capacity/)
- [Resource Quotas: Storage Resource Quota](https://kubernetes.io/docs/concepts/policy/resource-quotas/#storage-resource-quota)
- [Scheduling Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/)
- [StorageClass API reference (storage.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/storage-class-v1/)
- [PersistentVolume API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/persistent-volume-v1/)
- [PersistentVolumeClaim API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/persistent-volume-claim-v1/)
- [Kubernetes CSI Developer Documentation](https://kubernetes-csi.github.io/docs/)
- [CSI external-provisioner](https://kubernetes-csi.github.io/docs/external-provisioner.html)
- [CSI Volume Expansion](https://kubernetes-csi.github.io/docs/volume-expansion.html)
- [CSI Topology](https://kubernetes-csi.github.io/docs/topology.html)
- [csi-driver-nfs driver parameters](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/driver-parameters.md)
- [csi-driver-smb driver parameters](https://github.com/kubernetes-csi/csi-driver-smb/blob/master/docs/driver-parameters.md)
