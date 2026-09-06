# 🗄️ StatefulSets: Stable Identity and Storage

A deep dive into the StatefulSet controller: stable network identities, per replica persistent storage, ordered lifecycle guarantees, and the operational sharp edges that catch people in production.

## 📋 Table of Contents
- [What Is a StatefulSet?](#what-is-a-statefulset)
- [The Three Guarantees](#the-three-guarantees)
- [Stable Network Identity](#stable-network-identity)
- [The Headless Service and serviceName](#the-headless-service-and-servicename)
- [Stable Persistent Storage](#stable-persistent-storage)
- [PVC Retention Policy](#pvc-retention-policy)
- [Pod Management Policy](#pod-management-policy)
- [Ordered Deployment and Scaling](#ordered-deployment-and-scaling)
- [Update Strategies and Partitioned Rollouts](#update-strategies-and-partitioned-rollouts)
- [Node Failure and Stuck Terminating Pods](#node-failure-and-stuck-terminating-pods)
- [Worked Example: A Small Clustered Datastore](#worked-example-a-small-clustered-datastore)
- [Backup Considerations](#backup-considerations)
- [StatefulSet Status and Revisions](#statefulset-status-and-revisions)
- [Deleting StatefulSets](#deleting-statefulsets)
- [StatefulSet vs Deployment vs DaemonSet](#statefulset-vs-deployment-vs-daemonset)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What Is a StatefulSet?

A **StatefulSet** manages the deployment and scaling of a set of Pods, and provides guarantees about the **ordering and uniqueness** of those Pods.

A Deployment treats its Pods as interchangeable cattle: any replica can serve any request, and replacing one with a fresh Pod that has a new name and a new IP is harmless. A StatefulSet treats its Pods as individually identifiable members of a group. Replica 0 is not replica 1, it never becomes replica 1, and when it is rescheduled it comes back as replica 0 with the same name, the same DNS record and the same disk.

```
┌───────────────────────────────────────────────────────────────────┐
│               Deployment vs StatefulSet Identity                  │
├───────────────────────────────────────────────────────────────────┤
│  DEPLOYMENT (interchangeable)                                     │
│    web-7d4b9c8f5-x2k9p   ──delete──►  web-7d4b9c8f5-q7m3z         │
│    Random suffix. New name. New IP. New (or no) volume.           │
│                                                                   │
│  STATEFULSET (individually identified)                            │
│    mysql-1   ──delete──►  mysql-1                                │
│    Ordinal suffix. Same name, same DNS record, same PVC.          │
└───────────────────────────────────────────────────────────────────┘
```

Use a StatefulSet when at least one of these is true:

- Each replica needs its **own** durable volume that follows it.
- Peers need to address each other by a **stable hostname** (clustering, quorum, replication).
- Startup, shutdown or upgrade must happen in a **defined order**.

If none of those apply, a Deployment is simpler and better.

---

## The Three Guarantees

| Guarantee | Provided by | Practical effect |
|-----------|-------------|------------------|
| **Stable network identity** | Ordinal Pod names plus a headless Service | `mysql-1` always resolves to the current `mysql-1` Pod |
| **Stable persistent storage** | `volumeClaimTemplates` and deterministic PVC names | `mysql-1` always reattaches to `data-mysql-1` |
| **Ordered, graceful deployment, scaling and updates** | `podManagementPolicy` and `updateStrategy` | Bring up 0, then 1, then 2; tear down 2, then 1, then 0 |

Note the word *stable*, not *permanent*. The Pod object itself is still ephemeral: it can be deleted, rescheduled and recreated on a different node. What is stable is the **identity** attached to it.

### Ordinal Index Naming

Pods are named `<statefulset-name>-<ordinal>`, with ordinals starting at 0 by default and running to `replicas - 1`: a StatefulSet named `cassandra` with `replicas: 3` produces `cassandra-0`, `cassandra-1` and `cassandra-2`.

Because the Pod name is derived from the StatefulSet name, the name must be a valid DNS label component. Keep it short: the generated Pod name, and later the PVC name, both have to stay within the 63 character DNS label limit.

The `.spec.ordinals.start` field lets a StatefulSet begin numbering at a value other than zero. It is used for advanced migration patterns (moving replicas between two StatefulSets or across clusters without ordinal collisions). Confirm it is available and enabled on your cluster before relying on it:

```yaml
spec:
  ordinals:
    start: 3      # pods become name-3, name-4, name-5
```

---

## Stable Network Identity

Each Pod in a StatefulSet gets:

1. A **stable hostname**: the Pod's `hostname` is set to the Pod name (`mysql-1`).
2. A **stable subdomain**: the governing Service name, so the Pod's FQDN is predictable.
3. A **stable DNS A/AAAA record**, created by the cluster DNS server for the headless Service.

### The DNS Record Format

```
<pod-name>.<service-name>.<namespace>.svc.<cluster-domain>
```

With `cluster.local` as the default cluster domain:

```
mysql-0.mysql-headless.database.svc.cluster.local
mysql-1.mysql-headless.database.svc.cluster.local
mysql-2.mysql-headless.database.svc.cluster.local
   │           │             │
   │           │             └── namespace
   │           └──────────────── spec.serviceName (the governing Service)
   └──────────────────────────── pod name = statefulset name + ordinal
```

Within the same namespace, the short form `mysql-0.mysql-headless` resolves too, thanks to the search domains in the Pod's `/etc/resolv.conf`.

```
┌───────────────────────────────────────────────────────────────────┐
│                    StatefulSet DNS Topology                       │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   Headless Service "mysql-headless" (clusterIP: None)             │
│         │                                                         │
│         ├── A record: mysql-headless.db.svc.cluster.local         │
│         │      ──► 10.244.1.7, 10.244.2.4, 10.244.3.9             │
│         │          (all READY pod IPs, returned as a set)         │
│         │                                                         │
│         ├── A record: mysql-0.mysql-headless.db.svc.cluster.local │
│         │      ──► 10.244.1.7                                     │
│         ├── A record: mysql-1.mysql-headless.db.svc.cluster.local │
│         │      ──► 10.244.2.4                                     │
│         └── A record: mysql-2.mysql-headless.db.svc.cluster.local │
│                ──► 10.244.3.9                                     │
│                                                                   │
│   Pod IPs change on reschedule; the NAMES do not.                 │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Verifying DNS From Inside the Cluster

```bash
# Run a throwaway debug pod in the same namespace
kubectl run -n database dnsutils --rm -it --restart=Never \
  --image=busybox:1.36 -- sh

# Inside the pod:
nslookup mysql-0.mysql-headless
nslookup mysql-headless               # returns all ready pod IPs
cat /etc/resolv.conf                  # inspect search domains and ndots
```

```bash
# Confirm the pod's own hostname and subdomain
kubectl exec -n database mysql-1 -- hostname
# mysql-1
kubectl exec -n database mysql-1 -- hostname -f
# mysql-1.mysql-headless.database.svc.cluster.local
```

> 📖 **See Also**: [coredns.md](coredns.md) for how these records are generated and cached.

### Why the Application Cares

Clustered systems need peers to be addressable before they are healthy. A new Cassandra node contacts a seed; a MySQL replica connects to a primary; an etcd member joins by advertising a peer URL. If those addresses were random Pod IPs, every restart would break the cluster membership. Stable DNS names let the configuration be written once:

```
--initial-cluster=etcd-0=http://etcd-0.etcd:2380,etcd-1=http://etcd-1.etcd:2380,etcd-2=http://etcd-2.etcd:2380
```

> 📖 **See Also**: [etcd.md](etcd.md) for a real quorum based datastore.

---

## The Headless Service and serviceName

`spec.serviceName` names the **governing Service** that owns the per Pod DNS subdomain. That Service must be **headless** for per Pod records to be useful.

A headless Service is one with `clusterIP: None`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-headless
  namespace: database
  labels:
    app: mysql
spec:
  clusterIP: None          # <-- this is what makes it headless
  selector:
    app: mysql
  ports:
  - name: mysql
    port: 3306
    targetPort: 3306
```

| Service type | ClusterIP | DNS answer | Load balancing |
|--------------|-----------|-----------|----------------|
| Normal `ClusterIP` | Virtual IP allocated | Single VIP | kube-proxy distributes to endpoints |
| **Headless** (`clusterIP: None`) | None | **All** ready Pod IPs | None; the client chooses |

Because there is no virtual IP, there is no kube-proxy rule and no load balancing. The DNS answer is the endpoint list itself, which is exactly what a client library that needs to know the individual members wants.

### publishNotReadyAddresses

By default, DNS only publishes addresses for **ready** endpoints. That is a problem for clustered software during bootstrap: peer 1 cannot become ready until it reaches peer 0, but peer 0 is not ready either, so neither can resolve the other. Deadlock. Setting `publishNotReadyAddresses: true` on the headless Service publishes DNS records for not-yet-ready Pods and breaks the deadlock. This is standard practice for etcd, Cassandra, Kafka and similar systems.

```yaml
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: mysql
```

### The Two Service Pattern

Production StatefulSets almost always have **two** Services:

```
┌───────────────────────────────────────────────────────────────────┐
│                    Two Service Pattern                            │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────────────┐        ┌──────────────────────────┐     │
│  │  mysql-headless      │        │  mysql-read              │     │
│  │  clusterIP: None     │        │  type: ClusterIP         │     │
│  │  used by serviceName │        │  a real virtual IP       │     │
│  └──────────┬───────────┘        └────────────┬─────────────┘     │
│             │                                  │                  │
│   PEER TO PEER traffic                CLIENT traffic              │
│   mysql-0.mysql-headless              mysql-read:3306             │
│   mysql-1.mysql-headless              load balanced across        │
│   mysql-2.mysql-headless              all ready replicas          │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

The headless Service exists for identity. The normal ClusterIP Service exists for clients that just want "any healthy replica". Only the headless one goes in `spec.serviceName`.

---

## Stable Persistent Storage

### volumeClaimTemplates

A StatefulSet does not reference a PVC directly. It carries a **template** and the controller instantiates one PVC per Pod. The container mounts it by the template name, exactly as if it were a normal volume.

```yaml
spec:
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 50Gi
  # and in the container:
  #   volumeMounts:
  #   - name: data
  #     mountPath: /var/lib/mysql
```

### The Generated PVC Naming Convention

This deterministic naming is the entire mechanism behind storage stability:

```
<volumeClaimTemplate-name>-<statefulset-name>-<ordinal>

  template "data" + StatefulSet "mysql":
    Pod mysql-0  ──►  PVC  data-mysql-0
    Pod mysql-1  ──►  PVC  data-mysql-1
    Pod mysql-2  ──►  PVC  data-mysql-2
```

With two templates named `data` and `wal`, `mysql-1` gets both `data-mysql-1` and `wal-mysql-1`.

```bash
kubectl get pvc -n database
# NAME           STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS
# data-mysql-0   Bound    pvc-8a3f...  50Gi       RWO            fast-ssd
# data-mysql-1   Bound    pvc-c91b...  50Gi       RWO            fast-ssd
# data-mysql-2   Bound    pvc-4e7d...  50Gi       RWO            fast-ssd

kubectl get pods -n database -l app=mysql \
  -o custom-columns='POD:.metadata.name,PVC:.spec.volumes[*].persistentVolumeClaim.claimName'
```

### Why This Guarantees Reattachment

When `mysql-1` is rescheduled from a failed node to a healthy one, the controller recreates the Pod with the **same ordinal**, so it computes the **same PVC name** (`data-mysql-1`), so it binds the **same PersistentVolume** and sees the same data. The node changed; the identity did not.

### The ReadWriteOnce and Topology Trap

Most block storage is `ReadWriteOnce`: attachable to one node at a time. Combined with a `volumeBindingMode` of `Immediate` on the StorageClass, this produces a nasty failure: the PV is provisioned in zone A before the Pod is scheduled, and then the scheduler cannot place the Pod anywhere except zone A, or worse, cannot place it at all. `WaitForFirstConsumer` delays provisioning and binding until a Pod that uses the claim is scheduled, so the volume is created in the right topology. Prefer it for any StatefulSet on topology constrained storage.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: nfs.csi.k8s.io
volumeBindingMode: WaitForFirstConsumer   # bind AFTER the pod is scheduled
allowVolumeExpansion: true
reclaimPolicy: Delete
```

> 📖 **See Also**: [install-csi-nfs.md](install-csi-nfs.md) and [install-csi-smb.md](install-csi-smb.md) for CSI drivers in this repository.

### volumeClaimTemplates Are Immutable

You cannot edit `volumeClaimTemplates` on a live StatefulSet. To grow the volumes you must ensure the StorageClass has `allowVolumeExpansion: true`, patch each **PVC** individually with the new size, then delete the StatefulSet with `--cascade=orphan` and recreate it with the updated template so future replicas get the larger size.

```bash
# Step 1: expand each existing claim
for i in 0 1 2; do
  kubectl patch pvc data-mysql-$i -n database \
    -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
done

# Step 2: watch the resize complete (some drivers need a pod restart)
kubectl describe pvc data-mysql-0 -n database | sed -n '/Conditions/,/Events/p'

# Step 3: recreate the StatefulSet object without touching pods
kubectl delete statefulset mysql -n database --cascade=orphan
kubectl apply -f mysql-statefulset-100gi.yaml
```

---

## PVC Retention Policy

### Default: PVCs Survive Everything

By default, deleting a StatefulSet or scaling it down does **not** delete the PVCs it created. Scaling `mysql` from 3 to 1 leaves `data-mysql-1` and `data-mysql-2` bound and intact even though their Pods are gone.

This is deliberate and it is the correct default. Scaling down a database is usually a temporary capacity decision, and silently destroying the data of replicas 1 and 2 would be catastrophic. Scaling back to 3 reattaches the existing volumes with all their data intact.

The cost is **orphaned storage**. Nobody bills you a warning; the cloud bill just grows. Audit periodically by listing bound PVCs and cross referencing them against the claims actually mounted by running Pods:

```bash
kubectl get pvc -A -o json | jq -r '
  .items[] | select(.status.phase=="Bound") |
  "\(.metadata.namespace)/\(.metadata.name)"'

kubectl get pods -A -o json | jq -r '
  .items[].spec.volumes[]?.persistentVolumeClaim.claimName' | sort -u
```

### persistentVolumeClaimRetentionPolicy

The `persistentVolumeClaimRetentionPolicy` field makes the behaviour explicit and configurable.

```yaml
spec:
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain     # Retain | Delete
    whenScaled: Retain      # Retain | Delete
```

| Field | Trigger | `Retain` (default) | `Delete` |
|-------|---------|--------------------|----------|
| `whenDeleted` | The StatefulSet object is deleted | All PVCs kept | All PVCs deleted |
| `whenScaled` | `replicas` is reduced | PVCs of removed ordinals kept | PVCs of removed ordinals deleted |

Common combinations:

```yaml
# Production database: never lose data automatically
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
```

```yaml
# Elastic cache tier: data is rebuildable, reclaim storage on scale down
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Delete
    whenScaled: Delete
```

```yaml
# CI/ephemeral environments: clean up fully when the object goes away,
# but keep volumes during temporary scale downs
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Delete
    whenScaled: Retain
```

The mechanism is `ownerReferences`. With a `Delete` policy the controller sets an owner reference on the PVC (to the StatefulSet for `whenDeleted`, to the Pod for `whenScaled`), so normal garbage collection removes it when the owner disappears. With `Retain` the owner references are removed.

```bash
# See who owns a claim
kubectl get pvc data-mysql-2 -n database -o jsonpath='{.metadata.ownerReferences}' | jq
```

### PV Reclaim Policy Is a Separate Layer

Deleting the PVC does not necessarily delete the data. What happens to the underlying **PersistentVolume** is governed by the PV's `persistentVolumeReclaimPolicy`:

| Reclaim policy | Effect when the PVC is deleted |
|----------------|-------------------------------|
| `Delete` | The PV and the backing storage asset are deleted |
| `Retain` | The PV remains in `Released` state; data survives; manual cleanup required |

```
┌───────────────────────────────────────────────────────────────────┐
│                 Two Independent Retention Layers                  │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   StatefulSet scale down / delete                                 │
│            │                                                      │
│            ▼  persistentVolumeClaimRetentionPolicy                │
│         PVC kept  or  PVC deleted                                 │
│                            │                                      │
│                            ▼  PV persistentVolumeReclaimPolicy    │
│                     PV Released   or   PV + disk deleted          │
│                                                                   │
│   Safe production setup: Retain / Retain at BOTH layers.          │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

---

## Pod Management Policy

`spec.podManagementPolicy` controls whether the controller waits between Pods. It is **immutable** after creation.

```yaml
spec:
  podManagementPolicy: OrderedReady    # or Parallel
```

### OrderedReady (default)

```
┌───────────────────────────────────────────────────────────────────┐
│           podManagementPolicy: OrderedReady, replicas 3           │
├───────────────────────────────────────────────────────────────────┤
│  CREATE (ascending)                                               │
│    kafka-0 ──► Running AND Ready ──► kafka-1 ──► Ready ──► kafka-2│
│  DELETE / SCALE DOWN (descending)                                 │
│    kafka-2 ──► fully terminated ──► kafka-1 ──► ... ──► kafka-0   │
│                                                                   │
│  If kafka-1 never becomes Ready, kafka-2 is NEVER created.        │
│  The whole StatefulSet is blocked on one unhealthy pod.           │
└───────────────────────────────────────────────────────────────────┘
```

That blocking property is a feature for systems that must bootstrap in order (a primary before its replicas), and a liability when a single broken replica stalls everything.

### Parallel

With `Parallel`, all Pods are created and terminated simultaneously. Identity guarantees still hold in full: names, DNS and PVCs are unchanged. Only the **ordering** guarantee is dropped.

`Parallel` is the right choice for peer to peer systems with no bootstrap ordering requirement (Cassandra, Elasticsearch data nodes, most sharded stores) and for large replica counts where serial startup is painfully slow.

| Policy | Startup | Scale down | Use when |
|--------|---------|-----------|----------|
| `OrderedReady` | One at a time, ascending, waits for Ready | One at a time, descending | Primary/replica topologies, strict bootstrap order |
| `Parallel` | All at once | All at once | Symmetric peers, fast startup, large clusters |

**`podManagementPolicy` does not affect updates.** Rolling updates always follow `updateStrategy`, which is strictly ordered regardless of this field.

---

## Ordered Deployment and Scaling

### The Ordering Rules

| Operation | Order | Wait condition (OrderedReady) |
|-----------|-------|------------------------------|
| Initial creation | Ascending: 0, 1, 2, ... | Previous Pod is Running **and** Ready |
| Scale up | Ascending, from the current count | Previous Pod is Running and Ready |
| Scale down | **Descending**: n-1, n-2, ... | Previous Pod is completely terminated |
| Rolling update | **Descending**: n-1, n-2, ... | Previous Pod is Running and Ready |
| Deletion | Descending | Previous Pod is completely terminated |

Notice that everything except creation and scale up runs **downward**. Highest ordinal first, lowest ordinal last. That is why ordinal 0 is conventionally the primary or seed: it is created first and destroyed last.

```bash
# Scale up: 3 -> 5 creates mysql-3 then mysql-4
kubectl scale statefulset mysql -n database --replicas=5

# Scale down: 5 -> 2 deletes mysql-4, then mysql-3, then mysql-2
kubectl scale statefulset mysql -n database --replicas=2
```

### Why Ordering Matters

Consider a three node quorum system. Terminating all three at once loses quorum instantly and may corrupt state. Terminating them one at a time, waiting for the cluster to re-establish quorum between each, is a controlled operation. The StatefulSet controller does not know anything about quorum, but the ordered, one-at-a-time policy plus a correct **readiness probe** gives you exactly that behaviour: the probe is where you encode "this member has rejoined and is healthy".

A readiness probe that only checks "is the TCP port open" defeats the entire mechanism. Make it check real health.

### PodDisruptionBudget

Ordering protects you from **voluntary** controller actions. It does nothing about node drains, which are a separate path. Add a PodDisruptionBudget so `kubectl drain` blocks rather than taking a second replica down while the first is still recovering:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: mysql-pdb
  namespace: database
spec:
  minAvailable: 2          # or maxUnavailable: 1
  selector:
    matchLabels:
      app: mysql
```

---

## Update Strategies and Partitioned Rollouts

```yaml
spec:
  updateStrategy:
    type: RollingUpdate      # or OnDelete
    rollingUpdate:
      partition: 0
```

### RollingUpdate (default)

The controller updates Pods in **descending ordinal order**, one at a time, waiting for each to be Running and Ready before proceeding.

```
┌───────────────────────────────────────────────────────────────────┐
│              RollingUpdate, replicas 4, partition 0               │
├───────────────────────────────────────────────────────────────────┤
│  t0   [v1] [v1] [v1] [v1]        pods 0  1  2  3                  │
│  t1   [v1] [v1] [v1] [ X ]       delete pod 3                     │
│  t2   [v1] [v1] [v1] [v2]        pod 3 Ready                      │
│  t3   [v1] [v1] [ X ] [v2]       delete pod 2                     │
│  t4   [v1] [v1] [v2] [v2]        pod 2 Ready                      │
│  ...                                                              │
│  t8   [v2] [v2] [v2] [v2]        done                             │
│                                                                   │
│  If any pod fails to become Ready, the rollout STOPS there.       │
│  There is no automatic rollback.                                  │
└───────────────────────────────────────────────────────────────────┘
```

The rollout halting on a broken Pod is the safety property. It also means a stuck rollout is normal behaviour, not a controller bug, and your job is to fix the Pod.

### partition: Staged Canary Rollouts

`partition` splits the StatefulSet into a frozen lower half and an updatable upper half. **Pods with ordinal greater than or equal to `partition` are updated; pods below it are left alone.**

```
┌───────────────────────────────────────────────────────────────────┐
│         Canary with partition on a 5 replica StatefulSet          │
├───────────────────────────────────────────────────────────────────┤
│  partition: 4    [v1][v1][v1][v1][v2]   canary: only pod 4        │
│  partition: 3    [v1][v1][v1][v2][v2]   40% on v2                 │
│  partition: 2    [v1][v1][v2][v2][v2]   60% on v2                 │
│  partition: 1    [v1][v2][v2][v2][v2]   80% on v2                 │
│  partition: 0    [v2][v2][v2][v2][v2]   full rollout (default)    │
│  ordinal:          0   1   2   3   4                              │
│                    └─ frozen ─┘ └ updated ┘                       │
└───────────────────────────────────────────────────────────────────┘
```

The canary workflow:

```bash
# 1. Freeze everything, then change the image.
kubectl patch statefulset mysql -n database -p \
  '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":5}}}}'
kubectl set image statefulset/mysql -n database mysql=mysql:8.0.37
# Nothing happens: partition 5 with replicas 5 means no ordinal qualifies.

# 2. Release exactly one canary, then soak and observe mysql-4.
kubectl patch statefulset mysql -n database -p \
  '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":4}}}}'
kubectl rollout status statefulset/mysql -n database

# 3. Advance gradually.
for p in 3 2 1 0; do
  kubectl patch statefulset mysql -n database -p \
    "{\"spec\":{\"updateStrategy\":{\"rollingUpdate\":{\"partition\":$p}}}}"
  kubectl rollout status statefulset/mysql -n database --timeout=10m
done
```

To abort a canary, restore the old template **and** keep the partition where it is; the pods above the partition are then rolled back to the old image on the next reconcile. Because the ordinals below the partition never change, a partition based rollout has a natural, obvious blast radius. This is the closest thing StatefulSets have to a progressive delivery primitive.

### maxUnavailable and Immutable Fields

`spec.updateStrategy.rollingUpdate.maxUnavailable` allows more than one Pod to be updated concurrently. It has spent a long time behind a feature gate, so verify support with `kubectl explain statefulset.spec.updateStrategy.rollingUpdate` before designing around it. If it is not available, update concurrency is fixed at one Pod at a time.

Only a handful of StatefulSet spec fields can be changed after creation:

| Mutable | Immutable |
|---------|-----------|
| `replicas` | `selector` |
| `template` | `serviceName` |
| `updateStrategy` | `podManagementPolicy` |
| `persistentVolumeClaimRetentionPolicy` | `volumeClaimTemplates` |
| `minReadySeconds`, `ordinals` | |

Changing an immutable field requires deleting the StatefulSet, typically with `--cascade=orphan` so the Pods and their data survive the swap.

### OnDelete

With `type: OnDelete` the controller does not delete or update any Pod when the template changes. New Pods are created with the new template only when you delete the old ones. This gives total manual control, at the cost of remembering to finish the job.

```bash
kubectl set image statefulset/cassandra cassandra=cassandra:4.1.5
kubectl get sts cassandra   # UPDATED will stay at 0

# Roll a single member, verify cluster health, repeat
kubectl delete pod cassandra-2
kubectl exec cassandra-0 -- nodetool status
```

| Strategy | Order | Automatic | Concurrency | Good for |
|----------|-------|-----------|-------------|----------|
| `RollingUpdate`, `partition: 0` | Descending | Yes | One at a time | Normal upgrades |
| `RollingUpdate` with partition | Descending, above partition only | Yes, within the window | One at a time | Canary and staged rollouts |
| `OnDelete` | You decide | No | You decide | Databases needing per member verification |

---

## Node Failure and Stuck Terminating Pods

This is the highest stakes topic in StatefulSet operations.

### At Most One Semantics

The StatefulSet controller enforces that **at most one Pod exists per ordinal at any time**. That invariant is what makes `ReadWriteOnce` volumes safe: two processes must never write to the same filesystem simultaneously. To honour it, the controller will not create a replacement `mysql-1` until the existing `mysql-1` Pod object is **fully deleted from the API server**.

### What Happens When a Node Dies

```
┌───────────────────────────────────────────────────────────────────┐
│                  Timeline of a Node Failure                       │
├───────────────────────────────────────────────────────────────────┤
│  t+0s    node-03 loses power. mysql-1 was running there.          │
│  t+~40s  kubelet heartbeat lease stops renewing; the node is      │
│          marked NotReady and gains the taints                     │
│            node.kubernetes.io/not-ready:NoExecute                 │
│            node.kubernetes.io/unreachable:NoExecute               │
│  t+~5m   NoExecute eviction (default tolerationSeconds 300) sets  │
│          metadata.deletionTimestamp on mysql-1.                   │
│          Pod now shows STATUS = Terminating.                      │
│  t+5m..∞ The pod stays Terminating FOREVER. Deletion is only      │
│          finalised when the kubelet confirms the containers are   │
│          gone, and the kubelet is unreachable.                    │
│                                                                   │
│  Meanwhile: NO mysql-1 replacement is created. The StatefulSet    │
│  runs degraded, and it will stay degraded.                        │
└───────────────────────────────────────────────────────────────────┘
```

```bash
kubectl get pods -n database -o wide
# mysql-0   1/1   Running       0   6d   10.244.1.7   node-01
# mysql-1   1/1   Terminating   0   6d   10.244.3.9   node-03   <-- stuck
# mysql-2   1/1   Running       0   6d   10.244.2.4   node-02

kubectl get pod mysql-1 -n database -o jsonpath='{.metadata.deletionTimestamp}'
kubectl get nodes
```

This is **correct, intentional behaviour**, not a bug. Kubernetes cannot distinguish "the node is dead" from "the node is temporarily partitioned but the process is still running and still writing to the disk". Creating a second `mysql-1` in the second case would give you two processes writing to one volume, which is the definition of split brain and a reliable way to corrupt a database.

### Option 1: Force Delete (and its real risk)

```bash
kubectl delete pod mysql-1 -n database --grace-period=0 --force
```

This removes the Pod object from etcd immediately, without any confirmation from the kubelet. The controller then creates a fresh `mysql-1` elsewhere.
**The risk is concrete.** If the node was merely partitioned rather than dead, the old `mysql-1` process is still running and still writing to the volume while a new `mysql-1` starts elsewhere and attaches the same PersistentVolume. Two writers, one filesystem, no coordination: that is split brain, and the result is silent data corruption. Some CSI drivers refuse the second attach (`ReadWriteOnce` fencing), which saves you but leaves the new Pod stuck in `ContainerCreating` with a `Multi-Attach error for volume`.

Only force delete when you have **positively confirmed** the node is gone: powered off, terminated in the hypervisor or cloud API, or physically disconnected. "It looks down in kubectl" is not confirmation.

### Option 2: Delete the Node Object

If the machine is permanently gone, delete the Node. The Pod garbage collector then removes the Pods bound to it cleanly, which is the right move for an autoscaled node that was terminated.

```bash
kubectl delete node node-03      # only after confirming the machine is gone
```

### Option 3: The out-of-service Taint

Kubernetes provides a non graceful node shutdown path. Applying the `node.kubernetes.io/out-of-service` taint to a confirmed-down node tells the cluster that the node is genuinely gone, which triggers forceful detachment of its volumes and deletion of its Pods, allowing replacements to start and reattach.

```bash
# ONLY after confirming the node is truly powered off
kubectl taint node node-03 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute

# Remove the taint once the node is repaired and rejoins
kubectl taint node node-03 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
```

This is the recommended mechanism over blind force deletion because it also handles the volume detach side, which force deleting a Pod does not.

| Approach | Cleans up volumes | Risk | Use when |
|----------|-------------------|------|----------|
| Wait | N/A | None | Node may come back |
| `--grace-period=0 --force` | No | Split brain if node is alive | Emergency, node confirmed dead |
| `kubectl delete node` | Partially | Low if node truly gone | Node permanently removed |
| `out-of-service` taint | Yes | Low if node confirmed off | Confirmed non graceful shutdown |

### terminationGracePeriodSeconds

Never set `terminationGracePeriodSeconds: 0` in a StatefulSet Pod template. Doing so makes every ordinary Pod deletion an immediate, unclean kill, which for a database means no flush, no checkpoint and a recovery on next start. Give stateful workloads a realistic period and a `preStop` hook that shuts the engine down cleanly.

```yaml
    spec:
      terminationGracePeriodSeconds: 120
      containers:
      - name: mysql
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "mysqladmin shutdown"]
```

---

## Worked Example: A Small Clustered Datastore

A complete, three replica clustered store with a headless Service for peer discovery, a client Service, per replica storage and a PodDisruptionBudget.

### 1. Namespace and Services

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: datastore
---
apiVersion: v1
kind: Service
metadata:
  name: store-peers            # governing, headless service
  namespace: datastore
  labels:
    app: store
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: store
  ports:
  - name: client
    port: 2379
  - name: peer
    port: 2380
---
apiVersion: v1
kind: Service
metadata:
  name: store-client           # normal ClusterIP for applications
  namespace: datastore
spec:
  selector:
    app: store
  ports:
  - name: client
    port: 2379
```

### 2. The StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: store
  namespace: datastore
spec:
  serviceName: store-peers      # MUST match the headless Service name
  replicas: 3
  podManagementPolicy: Parallel
  minReadySeconds: 10

  selector:
    matchLabels:
      app: store

  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0

  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain

  template:
    metadata:
      labels:
        app: store
    spec:
      terminationGracePeriodSeconds: 60

      # Keep the three members on three different nodes.
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: store
            topologyKey: kubernetes.io/hostname

      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsNonRoot: true

      containers:
      - name: store
        image: quay.io/coreos/etcd:v3.5.15
        ports:
        - name: client
          containerPort: 2379
        - name: peer
          containerPort: 2380
        env:
        # Downward API gives the pod its own ordinal name.
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: SVC
          value: store-peers
        command:
        - /bin/sh
        - -c
        - |
          DOM="${SVC}.${POD_NAMESPACE}.svc.cluster.local"
          exec etcd --name "${POD_NAME}" --data-dir /var/lib/data \
            --listen-peer-urls http://0.0.0.0:2380 \
            --listen-client-urls http://0.0.0.0:2379 \
            --advertise-client-urls "http://${POD_NAME}.${DOM}:2379" \
            --initial-advertise-peer-urls "http://${POD_NAME}.${DOM}:2380" \
            --initial-cluster-token store-cluster-1 \
            --initial-cluster-state new \
            --initial-cluster "store-0=http://store-0.${DOM}:2380,store-1=http://store-1.${DOM}:2380,store-2=http://store-2.${DOM}:2380"
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            memory: 1Gi
        readinessProbe:
          httpGet:
            path: /health
            port: 2379
          initialDelaySeconds: 10
          periodSeconds: 10
        volumeMounts:
        - name: data
          mountPath: /var/lib/data

  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 10Gi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: store-pdb
  namespace: datastore
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: store
```

### 3. Deploy and Verify

```bash
kubectl apply -f datastore.yaml

# Pods appear as store-0, store-1, store-2 with deterministic PVCs
kubectl get pods -n datastore -o wide
kubectl get pvc -n datastore   # data-store-0 / 1 / 2, all Bound

# Per pod DNS resolves, and membership uses stable names, not IPs
kubectl run -n datastore t --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup store-1.store-peers.datastore.svc.cluster.local
kubectl exec -n datastore store-0 -- etcdctl member list -w table
```

### 4. Prove the Identity Guarantee

```bash
kubectl exec -n datastore store-0 -- etcdctl put demo/key "hello"
kubectl delete pod store-1 -n datastore

# Same name, same PVC, possibly a different node and a different IP
kubectl get pod store-1 -n datastore \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP,PVC:.spec.volumes[0].persistentVolumeClaim.claimName'

# Data still there
kubectl exec -n datastore store-1 -- etcdctl get demo/key
```

> 📖 **See Also**: [etcd.md](etcd.md) for how a real quorum store behaves, and [pods.md](pods.md) for the underlying Pod lifecycle.

---

## Backup Considerations

Kubernetes does not back up your data. StatefulSets guarantee that a Pod reattaches to its volume; they guarantee nothing about that volume's contents surviving a mistake, a bug or a filesystem corruption.

### What Must Be Backed Up

| Layer | Contents | Method |
|-------|----------|--------|
| **Application data** | Rows, keys, log segments | Native dump or snapshot tooling, executed inside a Pod |
| **Volume state** | Block level image of the PV | CSI VolumeSnapshot or storage array snapshot |
| **Kubernetes objects** | StatefulSet, Services, PVCs, Secrets, ConfigMaps | GitOps repository, or an object backup tool |

Restoring only the volumes without the object definitions leaves you with orphaned PVs and no way to reconnect them. Restoring only the objects leaves you with empty volumes. You need both.

### Application Consistent Backups

A filesystem snapshot taken mid write is **crash consistent**, not **application consistent**. Most databases can recover from crash consistent state, but recovery time is unpredictable and some engines cannot. Prefer application native backups:

```bash
# Logical dump from a specific ordinal, streamed out of the cluster
kubectl exec -n database mysql-0 -- \
  mysqldump --single-transaction --routines --triggers --all-databases \
  | gzip > mysql-$(date +%F).sql.gz

# etcd style snapshot taken inside the pod, then copied out
kubectl exec -n datastore store-0 -- etcdctl snapshot save /tmp/snap.db
kubectl cp datastore/store-0:/tmp/snap.db ./store-$(date +%F).db
```

Which ordinal to target matters. For a primary/replica topology, taking the dump from a **replica** (a high ordinal) avoids loading the primary, at the cost of replica lag in the backup. For a quorum system, any healthy member's snapshot is usually equivalent.

### CSI VolumeSnapshots and Restore

If the driver supports it, snapshot every PVC of the StatefulSet as a set. Snapshotting the three PVCs is not atomic across them, so for a distributed store you should quiesce writes or rely on the engine's own consistency mechanisms.

**Restore into a new StatefulSet, never over a running one.** The usual sequence is: scale to 0 (or deploy under a new name), pre-create PVCs with the exact names the StatefulSet will compute (`data-<name>-0`, and so on) sourced from snapshots via `dataSource`, then scale up. The controller finds the existing claims matching the expected names and uses them instead of provisioning new ones.

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: data-store-0-20250905
  namespace: datastore
spec:
  volumeSnapshotClassName: csi-snapclass
  source:
    persistentVolumeClaimName: data-store-0
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-store-0          # exact name the StatefulSet will look for
  namespace: datastore
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 10Gi
  dataSource:
    name: data-store-0-20250905
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
```

This "pre-create the PVC with the predictable name" trick is one of the most useful practical consequences of the deterministic naming convention.

### Backup Checklist

Test the **restore** on a schedule, because an untested backup is only a hypothesis. Store backups outside the cluster and outside the same storage system. Record the application version alongside the backup, since restoring a v8 dump into a v5 engine fails. Back up Secrets separately and securely, because a database restore is useless without its credentials. Finally, monitor backup job success explicitly; see [cronjobs.md](cronjobs.md) for scheduling and alerting on these.

---

## StatefulSet Status and Revisions

```bash
kubectl get statefulset store -n datastore -o jsonpath='{.status}' | jq
```

| Field | Meaning |
|-------|---------|
| `replicas` / `readyReplicas` / `availableReplicas` | Created, ready, and ready for at least `minReadySeconds` |
| `currentReplicas` / `updatedReplicas` | Pods running `currentRevision` versus `updateRevision` |
| `currentRevision` / `updateRevision` | ControllerRevision names for the pre-update and desired templates |
| `collisionCount` | Hash collision counter used to generate unique revision names |
| `observedGeneration` | The `metadata.generation` this status reflects |

When a rollout is complete, `currentRevision` equals `updateRevision`. During a partitioned rollout they differ permanently, which is expected: that is precisely what a partition means. Each Pod carries a `controller-revision-hash` label identifying which revision it belongs to.

```bash
# Revision history is ControllerRevisions, not ReplicaSets
kubectl get controllerrevisions -n datastore -l app=store
kubectl get pods -n datastore -L controller-revision-hash

kubectl rollout history statefulset/store -n datastore
kubectl rollout undo statefulset/store -n datastore --to-revision=2
kubectl rollout status statefulset/store -n datastore
kubectl rollout restart statefulset/store -n datastore
```

---

## Deleting StatefulSets

```bash
# Cascading delete: removes the pods (in descending order), keeps PVCs
# unless persistentVolumeClaimRetentionPolicy.whenDeleted is Delete
kubectl delete statefulset store -n datastore

# Non cascading: the StatefulSet object goes away, the pods keep running
kubectl delete statefulset store -n datastore --cascade=orphan
```

`--cascade=orphan` is the workhorse for changing an immutable field. The Pods keep their names and their volumes, and recreating a StatefulSet with a matching selector **adopts** them.

```bash
# Change an immutable field without downtime
kubectl get statefulset store -n datastore -o yaml > store.yaml
kubectl delete statefulset store -n datastore --cascade=orphan
# edit store.yaml (for example change podManagementPolicy)
kubectl apply -f store.yaml
kubectl get pods -n datastore   # same pods, now managed again

# Remove everything including data
kubectl delete statefulset store -n datastore
kubectl delete pvc data-store-0 data-store-1 data-store-2 -n datastore
```

PVCs created from `volumeClaimTemplates` inherit the labels from the template metadata, not from the Pod template, so check before relying on a label selector to delete them.

---

## StatefulSet vs Deployment vs DaemonSet

| Dimension | Deployment | StatefulSet | DaemonSet |
|-----------|-----------|-------------|-----------|
| Pod names | `name-<hash>-<random>` | `name-<ordinal>` | `name-<random>` |
| Identity across restarts | None | Stable | Tied to the node |
| Per replica storage | Shared or none | `volumeClaimTemplates`, one PVC per Pod | Usually `hostPath` |
| Stable DNS per Pod | No | Yes, via headless Service | No |
| Creation order | Parallel | Ordered by default | One per node, as nodes appear |
| Deletion order | Arbitrary | Descending ordinal | With the node |
| Update order | Governed by `maxSurge`/`maxUnavailable` | Descending ordinal, one at a time | Per node |
| Rollout history | ReplicaSets | ControllerRevisions | ControllerRevisions |
| Rollback | `kubectl rollout undo` | `kubectl rollout undo` | `kubectl rollout undo` |
| Pause supported | Yes | No | No |
| Scale subresource | Yes | Yes | No |
| Typical workload | Stateless web, API | Databases, queues, quorum systems | Node agents |

---

## Troubleshooting

### Symptom 1: Pod Stuck in Pending, PVC Stuck in Pending

```bash
kubectl describe pod store-0 -n datastore | sed -n '/Events/,$p'
kubectl describe pvc data-store-0 -n datastore | sed -n '/Events/,$p'
kubectl get storageclass
```

| Event message | Cause | Fix |
|---------------|-------|-----|
| `no persistent volumes available for this claim and no storage class is set` | No `storageClassName` and no default StorageClass | Set `storageClassName` in the template, or mark a StorageClass default |
| `storageclass.storage.k8s.io "fast-ssd" not found` | Typo, or the class does not exist in this cluster | `kubectl get storageclass` and correct the name |
| `waiting for first consumer to be created before binding` | `volumeBindingMode: WaitForFirstConsumer` | Normal; the real problem is why the Pod is unschedulable |
| `failed to provision volume with StorageClass` | Provisioner error, quota, or capacity | Read the provisioner and CSI controller logs |
| `pod has unbound immediate PersistentVolumeClaims` | The claim is not bound yet | Fix the PVC first, the Pod follows |

### Symptom 2: Only Pod 0 Exists, Nothing Else Is Created

With `podManagementPolicy: OrderedReady`, the controller will not create `store-1` until `store-0` is **Ready**. Ordinal 0 is not ready, so the whole set is blocked.

```bash
kubectl describe pod store-0 -n datastore | sed -n '/Events/,$p'
kubectl get pod store-0 -n datastore -o jsonpath='{.status.conditions}' | jq
```

Fix the readiness probe or the application. If startup is legitimately slow, use a `startupProbe`. If ordering is not actually required, switch to `podManagementPolicy: Parallel` (remember it is immutable, so this needs a `--cascade=orphan` recreate).

### Symptom 3: Pod Stuck Terminating

```bash
kubectl get pod store-1 -n datastore -o jsonpath='{.metadata.deletionTimestamp}'
kubectl get pod store-1 -n datastore -o jsonpath='{.metadata.finalizers}'
kubectl get nodes
```

Diagnose the cause before acting:

| Cause | Signal | Correct action |
|-------|--------|----------------|
| Node is unreachable | Node shows `NotReady` | Verify the machine is really down, then use the `out-of-service` taint or delete the Node |
| Long `terminationGracePeriodSeconds` | Node is Ready, grace period not elapsed | Wait |
| `preStop` hook hanging | Node is Ready, container still running | Fix the hook; check `kubectl logs` |
| A finalizer is present | `metadata.finalizers` is non empty | Find and fix the controller that owns the finalizer |
| Volume will not unmount | kubelet logs show unmount errors | Investigate the CSI driver on that node |

Force deletion is the last resort, and only with the node confirmed dead. See [Node Failure and Stuck Terminating Pods](#node-failure-and-stuck-terminating-pods).

### Symptom 4: Multi-Attach Error on the New Pod

```bash
kubectl describe pod store-1 -n datastore | grep -A3 Multi-Attach
# Warning  FailedAttachVolume  Multi-Attach error for volume "pvc-c91b..."
#          Volume is already exclusively attached to one node

kubectl get volumeattachments
```

The old Pod's volume is still attached to the dead node. The clean resolution is the `out-of-service` taint on the failed node, which triggers forced detachment. Manually deleting VolumeAttachment objects can work but risks the same split brain as force deleting Pods, so confirm the node state first.

### Symptom 5: Rolling Update Stalled Partway

```bash
kubectl rollout status statefulset/store -n datastore
kubectl get sts store -n datastore \
  -o jsonpath='{.status.currentRevision}{"\n"}{.status.updateRevision}{"\n"}'
kubectl get sts store -n datastore -o jsonpath='{.spec.updateStrategy}' | jq
```

Two very different explanations:

- **`partition` is non zero.** The rollout is complete for its window. Lower the partition to continue.
- **The highest not-yet-updated Pod is not becoming Ready.** The controller correctly refuses to proceed. Debug that specific Pod with `kubectl describe` and `kubectl logs --previous`. A rollout that broke the image entirely (bad tag, `ImagePullBackOff`) stalls on the first Pod, and rolling back the template fixes it.

### Symptom 6: Pod Recreated but Data Is Gone

```bash
# Which PVC is the pod actually using, and which PV backs it?
kubectl get pod store-1 -n datastore \
  -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}'
kubectl get pvc data-store-1 -n datastore -o jsonpath='{.spec.volumeName}'

kubectl exec -n datastore store-1 -- df -h
kubectl exec -n datastore store-1 -- ls -la /var/lib/data
```

Usual causes: the PVC was deleted (by a `Delete` retention policy or a cleanup script) and a fresh empty one was provisioned; the container writes to a path that is **not** the mount point; or an `emptyDir` volume shadows the persistent one.

### Symptom 7: DNS Name Does Not Resolve

```bash
kubectl run -n datastore t --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup store-0.store-peers.datastore.svc.cluster.local
# ** server can't find ...: NXDOMAIN
```

Checklist, in order:

```bash
# 1. Does spec.serviceName match a real Service?
kubectl get sts store -n datastore -o jsonpath='{.spec.serviceName}'

# 2. Is that Service headless? Must print: None
kubectl get svc store-peers -n datastore -o jsonpath='{.spec.clusterIP}'

# 3. Does its selector actually match the pods?
kubectl get svc store-peers -n datastore -o jsonpath='{.spec.selector}' | jq
kubectl get pods -n datastore --show-labels

# 4. Are there endpoints? Not-ready pods are excluded unless
#    publishNotReadyAddresses is true.
kubectl get endpointslices -n datastore -l kubernetes.io/service-name=store-peers

# 5. Is CoreDNS healthy?
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

### Symptom 8: Scale Down Did Not Free Any Storage

Expected with the default `Retain` policy. Verify and clean up deliberately:

```bash
kubectl get sts store -n datastore \
  -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}' | jq
kubectl get pvc -n datastore
kubectl delete pvc data-store-2 -n datastore   # after confirming the data is not needed
```

---

## Exam and Interview Traps

1. **`spec.serviceName` must reference a headless Service** (`clusterIP: None`) for per Pod DNS records. Pointing it at a normal ClusterIP Service gives you no individual records.
2. **The DNS format is `<pod>.<service>.<namespace>.svc.cluster.local`**, where `<service>` is `spec.serviceName`, not the client Service.
3. **PVC names are `<template-name>-<sts-name>-<ordinal>`**, not `<sts-name>-<ordinal>-<template-name>`. The template name comes first.
4. **PVCs are not deleted on scale down or on StatefulSet deletion by default.** That is `persistentVolumeClaimRetentionPolicy` with `Retain` for both `whenDeleted` and `whenScaled`.
5. **Scale up is ascending, scale down is descending.** Rolling updates are also **descending**, highest ordinal first.
6. **`podManagementPolicy` affects creation and deletion, not updates.** Updates always follow `updateStrategy` and are strictly ordered.
7. **`podManagementPolicy` is immutable.** So are `selector`, `serviceName` and `volumeClaimTemplates`. Only `replicas`, `template`, `updateStrategy`, `persistentVolumeClaimRetentionPolicy`, `minReadySeconds` and `ordinals` can be changed in place.
8. **`partition` means "update ordinals greater than or equal to partition"**, so a partition equal to the replica count freezes everything, and `partition: 0` (the default) updates everything.
9. **StatefulSets have no `spec.strategy`.** The field is `spec.updateStrategy`, with types `RollingUpdate` and `OnDelete`. There is no `Recreate`.
10. **`kubectl rollout pause` does not work on StatefulSets.** Use `partition` for the same effect.
11. **A Pod stuck `Terminating` on a dead node is correct behaviour**, driven by the at-most-one-per-ordinal invariant. No replacement appears until the Pod object is gone.
12. **Force deleting a StatefulSet Pod risks two writers on one volume.** Only do it with the node confirmed dead; prefer the `node.kubernetes.io/out-of-service` taint or deleting the Node object.
13. **Never set `terminationGracePeriodSeconds: 0`** on a StatefulSet Pod template.
14. **Rollout history is ControllerRevisions**, not ReplicaSets. A StatefulSet never creates a ReplicaSet.
15. **`volumeClaimTemplates` cannot be edited.** Expanding storage means patching each PVC and recreating the StatefulSet object with `--cascade=orphan`.
16. **`publishNotReadyAddresses: true`** on the headless Service is what breaks bootstrap deadlocks in clustered software.
17. **StatefulSets do not create the PersistentVolumes**, only the PersistentVolumeClaims. A dynamic provisioner and a StorageClass do the rest.
18. **`WaitForFirstConsumer` binding mode** avoids provisioning a volume into a topology where the Pod cannot be scheduled.
19. **A StatefulSet by itself is not high availability.** Ordering and identity are primitives; the application still has to implement replication, failover and quorum.

---

## Related Topics

- [Pods](pods.md)
- [Controllers](controllers.md)
- [DaemonSets](daemonsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [CoreDNS](coredns.md)
- [etcd](etcd.md)
- [kube-scheduler](kube-scheduler.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kubelet](kubelet.md)
- [Installing the NFS CSI Driver](install-csi-nfs.md)
- [Installing the SMB CSI Driver](install-csi-smb.md)
- [Network Policy](network-policy.md)
- [Kubernetes API](k8s-api.md)

---

## Key Takeaways

1. A StatefulSet provides three guarantees: **stable network identity**, **stable persistent storage**, and **ordered, graceful deployment, scaling and updates**. Use it only when you need at least one of them.
2. Pods are named `<statefulset>-<ordinal>` starting at 0, and that ordinal is the key from which the DNS name and the PVC name are both derived. Identity is stable; the Pod object itself is still ephemeral.
3. Per Pod DNS records come from a **headless Service** named in `spec.serviceName`, and follow the format `<pod>.<service>.<namespace>.svc.cluster.local`. Add `publishNotReadyAddresses: true` when peers must discover each other before becoming ready.
4. `volumeClaimTemplates` generate one PVC per Pod, named `<template>-<statefulset>-<ordinal>`. That deterministic name is the whole mechanism behind storage reattachment, and it is also what lets you pre-create PVCs from snapshots during a restore.
5. **PVCs survive scale down and StatefulSet deletion by default.** `persistentVolumeClaimRetentionPolicy` with `whenDeleted` and `whenScaled` makes the behaviour explicit; the PV's own `persistentVolumeReclaimPolicy` is a second, independent layer.
6. `podManagementPolicy: OrderedReady` starts Pods one at a time in ascending order and blocks on any Pod that never becomes Ready. `Parallel` drops only the ordering guarantee, never the identity guarantees, and it is immutable either way.
7. Scale up ascends, scale down descends, and rolling updates descend. The controller waits for Ready going up and for full termination coming down.
8. `updateStrategy.rollingUpdate.partition` freezes every ordinal below the partition, giving you a genuine staged canary: set it high, release one Pod, observe, then walk it down to 0.
9. `OnDelete` hands rollout control entirely to you and suits databases where each member must be verified before the next is touched.
10. On node failure a StatefulSet Pod becomes stuck `Terminating` and **no replacement is created**, because the controller enforces at most one Pod per ordinal. That protects `ReadWriteOnce` volumes from two simultaneous writers.
11. Force deleting such a Pod can produce split brain and silent data corruption if the node is merely partitioned. Prefer deleting the Node object or applying the `node.kubernetes.io/out-of-service` taint, both of which also handle volume detachment.
12. Immutable fields (`selector`, `serviceName`, `podManagementPolicy`, `volumeClaimTemplates`) are changed by deleting the StatefulSet with `--cascade=orphan` and recreating it, which re-adopts the existing Pods and volumes.
13. Pair StatefulSets with a **PodDisruptionBudget**, real readiness probes, pod anti-affinity across nodes, and a generous `terminationGracePeriodSeconds` with a `preStop` hook.
14. Kubernetes gives you storage attachment, not backups. Back up application data, volume snapshots and the object definitions, and test the restore path regularly.

---

## References

- [StatefulSet concept](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [StatefulSet Basics tutorial](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/)
- [Run a Replicated Stateful Application](https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/)
- [Scale a StatefulSet](https://kubernetes.io/docs/tasks/run-application/scale-stateful-set/)
- [Delete a StatefulSet](https://kubernetes.io/docs/tasks/run-application/delete-stateful-set/)
- [Force Delete StatefulSet Pods](https://kubernetes.io/docs/tasks/run-application/force-delete-stateful-set-pod/)
- [Perform a Rolling Update on a StatefulSet](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/#rolling-update)
- [Headless Services](https://kubernetes.io/docs/concepts/services-networking/service/#headless-services)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/)
- [Non Graceful Node Shutdown](https://kubernetes.io/docs/concepts/architecture/nodes/#non-graceful-node-shutdown)
- [Pod Disruption Budgets](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [StatefulSet API reference (apps/v1)](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/stateful-set-v1/)
