# 🧩 EndpointSlices: Scalable Service Membership

How Kubernetes tracks which addresses back a Service, why the original Endpoints object could not scale, and how the sliced model, its conditions and its topology hints actually behave.

## 📋 Table of Contents
- [What Problem EndpointSlices Solve](#what-problem-endpointslices-solve)
- [The Endpoints Object and Its Limits](#the-endpoints-object-and-its-limits)
- [The EndpointSlice Model](#the-endpointslice-model)
- [Anatomy of an EndpointSlice](#anatomy-of-an-endpointslice)
- [addressType](#addresstype)
- [The endpoints Array](#the-endpoints-array)
- [Conditions: ready, serving, terminating](#conditions-ready-serving-terminating)
- [The ports Array](#the-ports-array)
- [Slice Size, Packing and Churn](#slice-size-packing-and-churn)
- [The EndpointSlice Controller](#the-endpointslice-controller)
- [The EndpointSliceMirroring Controller](#the-endpointslicemirroring-controller)
- [Ownership and the service-name Label](#ownership-and-the-service-name-label)
- [How kube-proxy Consumes EndpointSlices](#how-kube-proxy-consumes-endpointslices)
- [Graceful Shutdown and Terminating Endpoints](#graceful-shutdown-and-terminating-endpoints)
- [Topology Aware Routing and Hints](#topology-aware-routing-and-hints)
- [Manually Managed EndpointSlices](#manually-managed-endpointslices)
- [Dual Stack Slices](#dual-stack-slices)
- [Inspecting EndpointSlices](#inspecting-endpointslices)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What Problem EndpointSlices Solve

A Service is a selector and a port mapping. Something has to turn that into a concrete list of addresses, keep it current as Pods come and go, and distribute it to every node.

```
┌──────────────────────────────────────────────────────────────────────────┐
│   Service (intent)          Membership (facts)         Datapath          │
│   ┌──────────────┐          ┌────────────────┐      ┌──────────────┐     │
│   │ selector:    │          │ 10.8.1.55:8080 │      │ kube-proxy   │     │
│   │   app: web   │─────────►│ 10.8.2.44:8080 │─────►│ CoreDNS      │     │
│   │ port 80→8080 │          │ 10.8.3.9:8080  │      │ Ingress ctrl │     │
│   └──────────────┘          └────────────────┘      │ service mesh │     │
│                                                     └──────────────┘     │
│    you write this          the control plane        consumers watch      │
│                            computes this            and act on it        │
└──────────────────────────────────────────────────────────────────────────┘
```

For years that middle box was a single `Endpoints` object per Service. That design is simple and it works well up to a few hundred endpoints, then it degrades badly. EndpointSlice is the replacement, and understanding why it exists explains most of its design.

---

## The Endpoints Object and Its Limits

```yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: web
  namespace: prod
subsets:
- addresses:
  - ip: 10.8.1.55
    nodeName: node-01
    targetRef:
      kind: Pod
      name: web-6d4c7f8b9-x2k9p
      namespace: prod
  - ip: 10.8.2.44
    nodeName: node-02
    targetRef:
      kind: Pod
      name: web-6d4c7f8b9-q7m3z
      namespace: prod
  notReadyAddresses:
  - ip: 10.8.3.9
    nodeName: node-03
  ports:
  - name: http
    port: 8080
    protocol: TCP
```

One object holds every address for the Service, split into `addresses` and `notReadyAddresses`.

### Problem 1: Update Amplification

An `Endpoints` object is updated as a whole. There are no partial updates for a list inside a single resource.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Service with 5000 endpoints. ONE Pod becomes Ready.                     │
│                                                                          │
│  1. Controller rewrites the ENTIRE Endpoints object                      │
│     (roughly 5000 entries, hundreds of kilobytes)                        │
│  2. etcd stores a complete new revision of that object                   │
│  3. EVERY watcher receives the COMPLETE new object                       │
│                                                                          │
│  Watchers per node: kube-proxy, CoreDNS, ingress controllers,            │
│  service mesh control planes, operators, ...                             │
│                                                                          │
│  On a 1000 node cluster:                                                 │
│     1 Pod change  ►  1000+ copies of a large object on the wire          │
│  A rolling update of 5000 Pods multiplies that by 5000.                  │
│                                                                          │
│  This is O(pods x watchers) network amplification for O(1) real change.  │
└──────────────────────────────────────────────────────────────────────────┘
```

This has been measured to saturate control plane network links during large rollouts and to make the API server the bottleneck for a change that logically touched one address.

### Problem 2: The Object Size Ceiling

etcd enforces a maximum request size, which by default is roughly 1.5 MiB (`--max-request-bytes` on etcd, with a matching limit enforced by the API server). A single `Endpoints` object must fit inside it.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Each address entry carries ip, nodeName and a targetRef with kind,      │
│  name, namespace and uid: on the order of 100 to 200 bytes serialised.   │
│                                                                          │
│    1000 endpoints  ►  comfortably inside the limit                       │
│    5000 endpoints  ►  approaching it                                     │
│   >5000 endpoints  ►  updates start being REJECTED                       │
│                                                                          │
│  The failure mode is brutal: the Service simply stops being updated,     │
│  and stale membership persists until the object shrinks again.           │
└──────────────────────────────────────────────────────────────────────────┘
```

To limit the damage, the Endpoints controller truncates very large Services and marks them, which you can see as an annotation on the object:

```bash
kubectl get endpoints huge-svc -o jsonpath='{.metadata.annotations}{"\n"}'
# {"endpoints.kubernetes.io/over-capacity":"truncated"}
```

Truncated means some real, healthy Pods are simply invisible to every consumer.

### Problem 3: No Room for Metadata

Because size was already the binding constraint, there was no room to attach per endpoint metadata such as zone, topology hints or a richer readiness state. The `Endpoints` shape could not grow.

### The Fix

```
┌──────────────────────────────────────────────────────────────────────────┐
│  BEFORE                              AFTER                               │
│  ┌────────────────────────┐          ┌──────────┐ ┌──────────┐ ┌───────┐ │
│  │ Endpoints "web"        │          │ web-7x4k │ │ web-b2m9 │ │ web-  │ │
│  │  5000 addresses        │   ────►  │ 100 eps  │ │ 100 eps  │ │ q8sd  │ │
│  │  ~1 MB per update      │          └──────────┘ └──────────┘ └───────┘ │
│  │  rewritten every time  │            ... 50 slices of 100 each ...     │
│  └────────────────────────┘                                              │
│                                                                          │
│  One Pod changes ► ONE slice (about 1/50th of the data) is rewritten.    │
│  Watch traffic drops by the same factor. Nothing hits the size ceiling.  │
└──────────────────────────────────────────────────────────────────────────┘
```

EndpointSlice is served by the `discovery.k8s.io/v1` API group. The `Endpoints` API remains for backwards compatibility and is now considered legacy, with EndpointSlice the resource that new code should watch and that kube-proxy already uses.

---

## The EndpointSlice Model

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   Service "web" (prod)                                                   │
│        ▲                                                                 │
│        │ ownerReference + label kubernetes.io/service-name: web          │
│        │                                                                 │
│   ┌────┴─────────┬───────────────┬───────────────┐                       │
│   │ web-7x4kd    │ web-b2m9p     │ web-q8sdf     │  ... N slices         │
│   │ IPv4         │ IPv4          │ IPv6          │                       │
│   │ 100 endpoints│ 37 endpoints  │ 100 endpoints │                       │
│   └──────────────┴───────────────┴───────────────┘                       │
│                                                                          │
│   Rules:                                                                 │
│    • A slice belongs to exactly ONE Service                              │
│    • A slice holds exactly ONE addressType                               │
│    • The union of all slices is the Service's membership                 │
│    • Consumers must aggregate across slices, never read just one         │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Anatomy of an EndpointSlice

```yaml
apiVersion: discovery.k8s.io/v1        # the GA API group and version
kind: EndpointSlice
metadata:
  name: web-7x4kd                      # <service-name>-<random suffix>
  namespace: prod                      # same namespace as the Service
  labels:
    kubernetes.io/service-name: web    # REQUIRED: binds the slice to the Service
    endpointslice.kubernetes.io/managed-by: endpointslice-controller.k8s.io
  ownerReferences:                     # garbage collected with the Service
  - apiVersion: v1
    kind: Service
    name: web
    uid: 8f2b6e51-1b3a-4a0e-9a1f-0a2c1d3e4f56
    controller: true
    blockOwnerDeletion: true

addressType: IPv4                      # IPv4 | IPv6 | FQDN, IMMUTABLE

ports:                                 # ports shared by every endpoint below
- name: http                           # matches the Service port name
  protocol: TCP
  port: 8080                           # the Pod side port (Service targetPort)
  appProtocol: http

endpoints:
- addresses:                           # consumers use addresses[0]
  - "10.8.1.55"
  conditions:
    ready: true
    serving: true
    terminating: false
  hostname: web-0                      # Pod hostname, when set
  nodeName: node-01                    # node hosting this endpoint
  zone: zone-a                         # from the node's topology label
  targetRef:                           # what this address actually is
    kind: Pod
    name: web-6d4c7f8b9-x2k9p
    namespace: prod
    uid: 1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809
  hints:                               # written by topology aware routing
    forZones:
    - name: zone-a
```

Note the two top level fields that are **not** under `spec`: `addressType`, `ports` and `endpoints` sit directly on the object. EndpointSlice has no `spec` or `status`, which surprises people writing jsonpath queries for the first time.

---

## addressType

```yaml
addressType: IPv4     # IPv4 | IPv6 | FQDN
```

| Value | Contents | Notes |
|-------|----------|-------|
| `IPv4` | IPv4 addresses | The common case |
| `IPv6` | IPv6 addresses | A separate slice, never mixed with IPv4 |
| `FQDN` | Fully qualified domain names | Rarely used; consumer support varies and kube-proxy does not resolve them |

Two hard rules:

1. **A slice holds exactly one address type.** Mixing families in one slice is invalid.
2. **`addressType` is immutable.** Changing it means deleting the slice and creating a new one.

The immutability exists so consumers can index and cache slices by family without re-checking on every update.

---

## The endpoints Array

Each element describes one backend.

| Field | Meaning |
|-------|---------|
| `addresses` | List of addresses for this endpoint. In practice consumers use `addresses[0]`; the field is a list for historical and future flexibility, not to express several distinct backends. |
| `conditions` | `ready`, `serving`, `terminating`. See below. |
| `hostname` | The endpoint's hostname, used by DNS for per Pod records behind a headless Service. Must be unique within the slice. |
| `nodeName` | The node hosting the endpoint. Used by `externalTrafficPolicy: Local`, `internalTrafficPolicy: Local` and node local routing decisions. |
| `zone` | Topology zone, taken from the node's `topology.kubernetes.io/zone` label. Feeds topology aware routing. |
| `targetRef` | Object reference to what this address is, normally a Pod. Absent for manually written slices pointing at external hosts. |
| `hints` | Routing hints written by the control plane, currently `forZones`. Consumed by kube-proxy. |

```yaml
endpoints:
# A healthy Pod
- addresses: ["10.8.1.55"]
  conditions: {ready: true, serving: true, terminating: false}
  nodeName: node-01
  zone: zone-a
  targetRef: {kind: Pod, name: web-x2k9p, namespace: prod}

# A Pod that is shutting down but still serving in-flight requests
- addresses: ["10.8.2.44"]
  conditions: {ready: false, serving: true, terminating: true}
  nodeName: node-02
  zone: zone-b
  targetRef: {kind: Pod, name: web-q7m3z, namespace: prod}

# An external database, written by hand, no targetRef
- addresses: ["192.0.2.77"]
  conditions: {ready: true}
```

> ⚠️ `targetRef` is what lets you map an address back to a Pod. When it is absent, either the slice was written manually or the endpoint is not a Pod. That distinction matters when a mystery IP appears in a Service.

---

## Conditions: ready, serving, terminating

Three booleans, and the relationship between them is the single most useful thing in this document.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ready       Is this endpoint suitable for NEW traffic?                  │
│              Combines Pod readiness AND not-terminating.                 │
│              A nil value should be interpreted as ready.                 │
│                                                                          │
│  serving     Is the endpoint's readiness probe passing, IGNORING         │
│              whether it is terminating?                                  │
│              A nil value should be interpreted as equal to ready.        │
│                                                                          │
│  terminating Is the Pod in the process of shutting down                  │
│              (deletionTimestamp set)?                                    │
│              A nil value means not terminating.                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### The Lifecycle in Four States

```
┌──────────────────────────────────────────────────────────────────────────┐
│  STATE                    ready   serving  terminating   receives?       │
│  ─────────────────────────────────────────────────────────────────────── │
│  1. Starting up,          false   false    false         no              │
│     probe not passing yet                                                │
│                                                                          │
│  2. Healthy and steady    true    true     false         yes             │
│                                                                          │
│  3. Deleted, still        false   true     true          in-flight only  │
│     passing its probe                                                    │
│                                                                          │
│  4. Deleted and failing   false   false    true          no              │
│     its probe                                                            │
└──────────────────────────────────────────────────────────────────────────┘
```

The critical row is **state 3**. Before the `serving` and `terminating` conditions existed, a Pod being deleted vanished from the endpoint list at once, and any request already in flight, or dispatched a few milliseconds later by a node whose rules had not yet converged, was reset. Splitting `serving` from `ready` lets consumers distinguish "do not send new work here" from "this address is dead".

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Why ready and serving are not the same field                            │
│                                                                          │
│   ready = serving AND NOT terminating                                    │
│                                                                          │
│   A terminating Pod is therefore never ready, even while it is happily   │
│   answering requests. The exception is a Service with                    │
│   publishNotReadyAddresses: true, which deliberately relaxes this.       │
└──────────────────────────────────────────────────────────────────────────┘
```

```bash
# See all three conditions per endpoint
kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='
{range .items[*].endpoints[*]}{.addresses[0]}{"\tready="}{.conditions.ready}{"\tserving="}{.conditions.serving}{"\tterm="}{.conditions.terminating}{"\n"}{end}'
# 10.8.1.55  ready=true   serving=true   term=false
# 10.8.2.44  ready=false  serving=true   term=true
# 10.8.3.9   ready=false  serving=false  term=false
```

---

## The ports Array

`ports` is defined once per slice and applies to every endpoint in it.

```yaml
ports:
- name: http          # must match the Service's port name
  protocol: TCP       # TCP | UDP | SCTP
  port: 8080          # the resolved Pod side port
  appProtocol: http   # optional hint
- name: metrics
  protocol: TCP
  port: 9090
```

Details that matter:

- `name` must equal the corresponding **Service port name**. A mismatch in a hand written slice produces a Service with endpoints that receive nothing.
- `port` is the **resolved** value. When the Service uses a named `targetPort`, the controller resolves the name per Pod and writes the number here.
- Because a named `targetPort` can resolve to different numbers on different Pods, the controller **puts those Pods in different slices**, since a slice has one shared port list. This is a normal reason to see extra slices during a port migration.
- A `null` value for `port` means "all ports", which is used by some non Pod integrations. An empty `ports` list means the same.

---

## Slice Size, Packing and Churn

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Default endpoints per slice:  100                                       │
│  Controlled by: kube-controller-manager --max-endpoints-per-slice        │
│  Allowed range for that flag:  1 to 1000                                 │
│  API validation ceiling:       1000 endpoints in a single slice          │
└──────────────────────────────────────────────────────────────────────────┘
```

The default of 100 is a deliberate compromise:

| Smaller slices | Larger slices |
|----------------|---------------|
| Less data rewritten per change | Fewer objects in etcd |
| Less watch traffic per change | Fewer watch events on bulk changes |
| More objects to list and cache | More data rewritten per change |
| More API objects per Service | Closer to the object size ceiling |

### How the Controller Packs

The controller does **not** aim for perfectly packed slices. It aims to minimise the number of writes, because writes are what cost the control plane.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Adding an endpoint                                                      │
│    1. Try to fit it into an EXISTING slice that has room                 │
│    2. If none has room, create a NEW slice                               │
│                                                                          │
│  Removing an endpoint                                                    │
│    1. Remove it from its slice, leaving a gap                            │
│    2. Do NOT immediately rebalance other slices to fill the gap          │
│                                                                          │
│  Result during heavy churn: several partially filled slices.             │
│  The controller performs periodic best-effort consolidation, but         │
│  transient under-packing is EXPECTED, not a defect.                      │
└──────────────────────────────────────────────────────────────────────────┘
```

```bash
# Slice count and fill level for a large Service
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.addressType}{"\t"}{range .endpoints[*]}x{end}{"\n"}{end}' \
  | awk '{print $1, $2, length($3)" endpoints"}'
# web-7x4kd IPv4 100 endpoints
# web-b2m9p IPv4 100 endpoints
# web-q8sdf IPv4 37 endpoints
```

Practical consequences: a Service with 250 endpoints normally has three slices, and seeing five slices with gaps after a rollout is normal. Never assume one slice per Service, and never read only the first one.

---

## The EndpointSlice Controller

Runs inside kube-controller-manager and owns slices for Services **that have a selector**.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    EndpointSlice controller loop                         │
│                                                                          │
│  Watches: Services, Pods, Nodes, EndpointSlices                          │
│                                                                          │
│  For each Service with a selector:                                       │
│    1. List Pods in the Service's namespace matching spec.selector        │
│    2. For each Pod, resolve every Service port to a numeric Pod port     │
│       (numeric passes through, a NAME is looked up in that Pod)          │
│    3. Compute conditions from Pod readiness and deletionTimestamp        │
│    4. Read nodeName and the node's zone label                            │
│    5. Diff against existing slices and write the MINIMUM set of changes  │
│    6. Create, update or delete slices, keeping ownerReferences and       │
│       the kubernetes.io/service-name label correct                       │
│                                                                          │
│  Skips: Services with type ExternalName, and Services with no selector   │
│         (those are the mirroring controller's business, if anything)     │
└──────────────────────────────────────────────────────────────────────────┘
```

Endpoints that are excluded entirely:

- Pods with no IP assigned yet.
- Pods that do not expose the required port when the Service uses a **named** `targetPort` that the Pod does not declare.
- Pods matched by the selector but in a different namespace, which cannot happen since selectors are namespace scoped.

It also keeps the legacy `Endpoints` object populated for the same Services, so older tooling keeps working.

```bash
# Is the controller healthy
kubectl -n kube-system get pods -l component=kube-controller-manager
kubectl -n kube-system logs -l component=kube-controller-manager --tail=100 \
  | grep -i endpointslice
```

---

## The EndpointSliceMirroring Controller

A second controller exists for the opposite direction: users and legacy tools that write **`Endpoints` objects by hand** for selectorless Services. Consumers now read slices, so those hand written Endpoints must be mirrored.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Service WITH selector                                                   │
│     Pods ──► EndpointSlice controller ──► EndpointSlices                 │
│                                      └──► Endpoints (compatibility)      │
│                                                                          │
│  Service WITHOUT selector, user writes Endpoints                         │
│     Endpoints ──► EndpointSliceMirroring controller ──► EndpointSlices   │
│                                                                          │
│  Service WITHOUT selector, user writes EndpointSlices directly           │
│     EndpointSlices ──► used as-is, NOTHING mirrors or manages them       │
│     (this is the recommended modern approach)                            │
└──────────────────────────────────────────────────────────────────────────┘
```

Mirroring is skipped when:

- The `Endpoints` object carries the label `endpointslice.kubernetes.io/skip-mirror: "true"`.
- The `Endpoints` object carries the `control-plane.alpha.kubernetes.io/leader` annotation, which is how legacy leader election objects avoid being mirrored.
- There is no Service with a matching name.

```bash
# Distinguish who wrote a slice
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.endpointslice\.kubernetes\.io/managed-by}{"\n"}{end}'
# web-7x4kd   endpointslice-controller.k8s.io          ► from Pods and a selector
# web-abc12   endpointslicemirroring-controller.k8s.io ► mirrored from Endpoints
# web-manual                                            ► written by a human or tool
```

> ⚠️ Do not write both an `Endpoints` object and your own EndpointSlices for the same Service. The mirroring controller will create its own slices alongside yours and the Service will contain the union, which is almost never what you intended.

---

## Ownership and the service-name Label

```yaml
metadata:
  labels:
    kubernetes.io/service-name: web           # THE binding
    endpointslice.kubernetes.io/managed-by: endpointslice-controller.k8s.io
  ownerReferences:
  - apiVersion: v1
    kind: Service
    name: web
    uid: 8f2b6e51-1b3a-4a0e-9a1f-0a2c1d3e4f56
    controller: true
    blockOwnerDeletion: true
```

| Mechanism | Purpose |
|-----------|---------|
| `kubernetes.io/service-name` | **How consumers find slices.** kube-proxy, CoreDNS and every other watcher select on this label. It is required, and it must be in the same namespace as the Service. |
| `endpointslice.kubernetes.io/managed-by` | Declares which controller owns the object so controllers do not fight. Leave it **unset** on slices you write by hand, which tells every built in controller to leave them alone. |
| `ownerReferences` | Ties the slice's lifetime to the Service so garbage collection removes it when the Service is deleted. Optional on hand written slices; without it you must clean up yourself. |

The label is the contract. A slice with the correct label and no owner reference still works. A slice with a correct owner reference and the wrong label is invisible.

```bash
kubectl get endpointslices -A -l kubernetes.io/service-name=web
kubectl get endpointslices -A --show-labels | head
```

---

## How kube-proxy Consumes EndpointSlices

```
┌──────────────────────────────────────────────────────────────────────────┐
│  kube-proxy on every node:                                               │
│                                                                          │
│   1. Watch Services and EndpointSlices (slices are the source of truth)  │
│   2. Group slices by kubernetes.io/service-name and aggregate them       │
│   3. Filter endpoints:                                                   │
│        • keep ready endpoints for normal routing                         │
│        • apply topology hints when they are present and applicable       │
│        • with internalTrafficPolicy: Local, keep only endpoints whose    │
│          nodeName equals this node                                       │
│        • with externalTrafficPolicy: Local, do the same for external     │
│          traffic, and drop external traffic entirely when none remain    │
│   4. Program the datapath: iptables chains, IPVS real servers, nftables  │
│      or eBPF maps, depending on the mode                                 │
│   5. Repeat on every change, batching updates to limit sync cost         │
└──────────────────────────────────────────────────────────────────────────┘
```

Three consequences that show up in real debugging:

- **Slices are aggregated, so partially filled slices are harmless.** What matters is the union.
- **`nodeName` on the endpoint is what makes both `Local` traffic policies work.** An endpoint with no `nodeName`, such as a hand written external address, can never satisfy a `Local` policy.
- **The Service is what carries the policy, the slice is what carries the facts.** Debugging always needs both objects.

> 📖 Proxy modes and the resulting rule structures are covered in [kube-proxy.md](kube-proxy.md).

CoreDNS is the other major consumer: it builds A, AAAA and SRV records from the same slices, which is why a headless Service returns exactly the ready endpoint addresses and per Pod records use the `hostname` field.

> 📖 See [coredns.md](coredns.md).

---

## Graceful Shutdown and Terminating Endpoints

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Pod deletion timeline                                                   │
│                                                                          │
│  t0   kubectl delete pod / rollout replaces it                           │
│       deletionTimestamp is set                                           │
│         │                                                                │
│         ├─► EndpointSlice controller sets:                               │
│         │     terminating: true, ready: false, serving: <probe result>   │
│         │                                                                │
│         ├─► kubelet runs the preStop hook, then sends SIGTERM            │
│         │                                                                │
│  t0+ε  Every node's kube-proxy receives the slice update and stops       │
│        sending NEW connections to the endpoint                           │
│                                                                          │
│  ...   The Pod keeps serving connections that already arrived, because   │
│        serving is still true                                             │
│                                                                          │
│  tN   terminationGracePeriodSeconds elapses, SIGKILL, Pod removed,       │
│       endpoint deleted from the slice entirely                           │
│                                                                          │
│  THE RACE: propagation between t0 and t0+ε is NOT instantaneous.         │
│  Requests dispatched in that window arrive at a Pod that may already     │
│  have closed its listener. That is where deploy-time 502s come from.     │
└──────────────────────────────────────────────────────────────────────────┘
```

The endpoint data is only half the fix; the application has to cooperate:

```yaml
spec:
  terminationGracePeriodSeconds: 60
  containers:
  - name: app
    image: myapp:1.0
    lifecycle:
      preStop:
        exec:
          # Keep serving while the endpoint removal propagates to every node
          command: ["sh", "-c", "sleep 15"]
    readinessProbe:
      httpGet:
        path: /healthz
        port: 8080
      periodSeconds: 2
```

kube-proxy also has a safety behaviour worth knowing: when a Service has **no ready endpoints at all** but does have endpoints that are `serving` while `terminating`, it can fall back to those rather than dropping traffic outright. That turns a hard outage during an aggressive rollout into degraded but working service. It is a safety net, not a strategy: keep enough ready replicas.

```bash
# Watch conditions change live during a rollout
kubectl get endpointslices -l kubernetes.io/service-name=web -w -o jsonpath='
{range .items[*].endpoints[*]}{.addresses[0]}{" r="}{.conditions.ready}{" s="}{.conditions.serving}{" t="}{.conditions.terminating}{"\n"}{end}{"---\n"}'
```

---

## Topology Aware Routing and Hints

The control plane can bias routing toward endpoints near the client. It does this by writing **hints** into the slice, not by changing kube-proxy's algorithm.

```yaml
endpoints:
- addresses: ["10.8.1.55"]
  conditions: {ready: true}
  nodeName: node-01
  zone: zone-a
  hints:
    forZones:
    - name: zone-a      # kube-proxy running in zone-a may use this endpoint
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  1. You enable it on the SERVICE                                         │
│       spec.trafficDistribution: PreferClose                              │
│       or the annotation service.kubernetes.io/topology-mode: "Auto"      │
│                                                                          │
│  2. The control plane evaluates whether hints are SAFE:                  │
│       • are nodes labelled with topology.kubernetes.io/zone?             │
│       • is endpoint capacity per zone roughly proportional to the        │
│         allocatable CPU per zone?                                        │
│       If not, it writes NO hints and routing stays cluster wide.         │
│                                                                          │
│  3. If safe, it writes hints.forZones on each endpoint                   │
│                                                                          │
│  4. kube-proxy in zone X uses only endpoints hinted for zone X           │
│                                                                          │
│  5. If conditions change (a zone loses Pods), hints are REMOVED and      │
│     everything falls back to cluster wide routing automatically          │
└──────────────────────────────────────────────────────────────────────────┘
```

```bash
# Which endpoints carry hints, and for which zones
kubectl get endpointslices -l kubernetes.io/service-name=web -o jsonpath='
{range .items[*].endpoints[*]}{.addresses[0]}{"\tzone="}{.zone}{"\thints="}{.hints.forZones[*].name}{"\n"}{end}'
# 10.8.1.55  zone=zone-a  hints=zone-a
# 10.8.2.44  zone=zone-b  hints=zone-b
# 10.8.3.9   zone=zone-c  hints=zone-c

# No hints column at all means the feature is off or the heuristic declined
```

Points people get wrong: hints are written by the control plane and **must not** be set by hand on controller managed slices, since the controller will overwrite them; an empty `hints` field is the normal state, not a fault; and hints are a **preference with an automatic fallback**, unlike `internalTrafficPolicy: Local`, which is a hard restriction with no fallback at all.

> 📖 The Service side of this is in [services.md](services.md).

---

## Manually Managed EndpointSlices

For a Service with **no selector**, nothing writes slices, so you can. This is the supported way to give an external system a cluster local Service name.

```yaml
# 1. The Service: no selector, so no controller touches its membership
apiVersion: v1
kind: Service
metadata:
  name: external-postgres
  namespace: prod
spec:
  ports:
  - name: pg              # the NAME is the join key with the slice below
    port: 5432            # what in-cluster clients dial
    targetPort: 5432      # the port on the external host
    protocol: TCP
---
# 2. The membership, written and maintained by you
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: external-postgres-1                        # convention: <service>-<n>
  namespace: prod                                  # MUST match the Service
  labels:
    kubernetes.io/service-name: external-postgres  # REQUIRED binding
    # deliberately NO endpointslice.kubernetes.io/managed-by label,
    # which keeps the built in controllers away from this object
addressType: IPv4
ports:
- name: pg                                         # MUST match the Service port name
  port: 5432                                       # the port on the external host
  protocol: TCP
endpoints:
- addresses:
  - "192.0.2.77"                                   # primary database
  conditions:
    ready: true
- addresses:
  - "192.0.2.78"                                   # replica, also load balanced
  conditions:
    ready: true
```

```bash
kubectl apply -f external-postgres.yaml
kubectl describe svc external-postgres -n prod | grep Endpoints
# Endpoints:  192.0.2.77:5432,192.0.2.78:5432

kubectl run pgtest --rm -it --restart=Never --image=postgres:16 -- \
  psql -h external-postgres.prod.svc.cluster.local -U app -c 'select 1'
```

### The Checklist

| Requirement | Why |
|-------------|-----|
| Same namespace as the Service | Slices are namespace scoped and bind by name within a namespace |
| Label `kubernetes.io/service-name` exactly right | This is the only binding mechanism |
| `ports[].name` equal to the Service's port name | A mismatch yields endpoints that receive nothing |
| Correct `addressType` for the addresses used | Mismatches are rejected or silently unused |
| `conditions.ready: true` set explicitly | Be explicit rather than relying on nil handling |
| No `managed-by` label | Signals that no controller owns the object |

### Constraints

- Addresses must not be **link local** (`169.254.0.0/16`, `fe80::/64`) or the loopback address; the API server rejects them.
- Pointing at another Service's ClusterIP is unsupported: the double DNAT does not behave.
- There is **no health checking**. A dead external host stays in the slice until you remove it, so pair this with external monitoring or an operator that maintains the slice.
- Endpoints without a `nodeName` can never satisfy `internalTrafficPolicy: Local` or `externalTrafficPolicy: Local`.
- Slices you write have no `ownerReferences`, so deleting the Service leaves them behind. Clean up explicitly, or add an owner reference yourself.

### Headless Variant

Adding `clusterIP: None` to the Service makes DNS return the external addresses directly as A records, with no VIP and no proxying, which suits clients that want to see the whole member list:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-cluster
  namespace: prod
spec:
  clusterIP: None
  ports:
  - name: pg
    port: 5432
```

---

## Dual Stack Slices

Each address family gets its **own** slices, because `addressType` is per slice and immutable.

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o custom-columns=NAME:.metadata.name,TYPE:.addressType,ENDPOINTS:.endpoints[*].addresses[0]
```

```
NAME        TYPE   ENDPOINTS
web-7x4kd   IPv4   10.8.1.55,10.8.2.44,10.8.3.9
web-p3m8q   IPv6   fd00:10:8:1::37,fd00:10:8:2::2c,fd00:10:8:3::9
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│   Service "web"                                                          │
│     ipFamilies: [IPv4, IPv6]                                             │
│     clusterIPs: [10.96.42.17, fd00:10:96::a1b2]                          │
│        │                                                                 │
│        ├──► slices with addressType: IPv4 ──► the IPv4 ClusterIP path    │
│        └──► slices with addressType: IPv6 ──► the IPv6 ClusterIP path    │
│                                                                          │
│   The SAME Pod appears in BOTH, once per family, with the same           │
│   targetRef and nodeName but different addresses.                        │
└──────────────────────────────────────────────────────────────────────────┘
```

Implications: endpoint counts double for a dual stack Service, so slice counts do too; a Pod that only has an IPv4 address contributes nothing to the IPv6 slices, which is a common cause of "the IPv6 Service has no endpoints"; and hand written dual stack membership means writing **two** slices, one per family.

> 📖 The Service side fields, `ipFamilies` and `ipFamilyPolicy`, are described in [services.md](services.md).

---

## Inspecting EndpointSlices

```bash
# Everything, everywhere
kubectl get endpointslices -A
kubectl get endpointslices -n prod

# For one Service, which is the query you will use most
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web -o yaml

# Short name
kubectl get eps -n prod    # NOTE: "eps" is ambiguous in some versions; prefer the full name
```

```
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                       AGE
web-7x4kd   IPv4          8080    10.8.1.55,10.8.2.44,10.8.3.9    2d
```

| Column | Meaning |
|--------|---------|
| `ADDRESSTYPE` | `IPv4`, `IPv6` or `FQDN` |
| `PORTS` | The `port` values from the slice's `ports` array, not the Service `port` |
| `ENDPOINTS` | Addresses, truncated in the display when there are many |

### jsonpath Recipes

```bash
SVC=web; NS=prod
SEL="-n $NS -l kubernetes.io/service-name=$SVC"

# Address plus all three conditions
kubectl get endpointslices $SEL -o jsonpath='
{range .items[*].endpoints[*]}{.addresses[0]}{"\tready="}{.conditions.ready}{"\tserving="}{.conditions.serving}{"\tterm="}{.conditions.terminating}{"\n"}{end}'

# Address to node, essential for Local traffic policies
kubectl get endpointslices $SEL -o jsonpath='
{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.nodeName}{"\n"}{end}'

# Address to Pod name
kubectl get endpointslices $SEL -o jsonpath='
{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.targetRef.name}{"\n"}{end}'

# Ports declared by each slice
kubectl get endpointslices $SEL -o jsonpath='
{range .items[*]}{.metadata.name}{": "}{range .ports[*]}{.name}{"="}{.port}{"/"}{.protocol}{" "}{end}{"\n"}{end}'

# Only the READY addresses, one per line, ready for scripting
kubectl get endpointslices $SEL -o json | jq -r '
  .items[].endpoints[] | select(.conditions.ready == true) | .addresses[0]'

# Endpoint count per slice, to see packing
kubectl get endpointslices $SEL -o json | jq -r '
  .items[] | "\(.metadata.name)\t\(.addressType)\t\(.endpoints | length)"'

# Which controller manages each slice
kubectl get endpointslices $SEL -o json | jq -r '
  .items[] | "\(.metadata.name)\t\(.metadata.labels["endpointslice.kubernetes.io/managed-by"] // "unmanaged")"'

# Cluster wide: every Service whose slices contain zero ready endpoints
kubectl get endpointslices -A -o json | jq -r '
  .items[]
  | select([.endpoints[]? | select(.conditions.ready == true)] | length == 0)
  | "\(.metadata.namespace)/\(.metadata.labels["kubernetes.io/service-name"])"' | sort -u

# Watch changes live
kubectl get endpointslices $SEL -w
```

---

## Troubleshooting

### No EndpointSlices Exist for a Service

```bash
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web
# No resources found in prod namespace.
```

Causes, in order:

1. **The selector matches no Pods.** This is by far the most common.
   ```bash
   kubectl get svc web -n prod -o jsonpath='{.spec.selector}{"\n"}'
   kubectl get pods -n prod --selector=app=web
   ```
2. **The Service has no selector** and you never created slices for it. Expected, and the fix is to write them.
3. **`type: ExternalName`.** These never get slices; the design has no endpoints at all.
4. **kube-controller-manager is unhealthy.**
   ```bash
   kubectl -n kube-system get pods -l component=kube-controller-manager
   kubectl -n kube-system logs -l component=kube-controller-manager --tail=100 | grep -i endpointslice
   ```

### A Slice Exists but Has No Ready Endpoints

```bash
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web -o yaml | grep -A4 conditions
```

Pods match but none is Ready. Chase the readiness probe:

```bash
kubectl get pods -n prod -l app=web             # look at READY, not STATUS
kubectl describe pod <pod> -n prod | grep -A5 Events
```

### Endpoints Are Stale After a Rollout

```bash
# What the control plane currently believes
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web -o yaml

# What actually exists
kubectl get pods -n prod -l app=web -o wide
```

If the slice lists Pods that are gone, the controller is behind or stuck: check kube-controller-manager. If the slice is correct but traffic still goes to old addresses, the problem is downstream, in kube-proxy convergence, in a client's DNS cache for a headless Service, or in stale conntrack entries for UDP.

```bash
kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=100 | grep -iE 'error|sync'
sudo conntrack -L -d <clusterIP>
```

### A Hand Written Slice Is Ignored

Check each item in order; one of them is always the cause:

```bash
kubectl get endpointslice external-postgres-1 -n prod -o yaml
```

- Is `kubernetes.io/service-name` spelled exactly right and does it name an existing Service?
- Is the slice in the **same namespace** as the Service?
- Does `ports[].name` match the Service's port name exactly? An unnamed Service port pairs with an unnamed slice port.
- Is `addressType` right for the addresses used?
- Is `conditions.ready` actually `true`?
- Does the Service still have a `selector`? If so, the controller owns the Service and will fight you.

```bash
kubectl describe svc external-postgres -n prod | grep Endpoints
```

### Too Many Slices

Normal after churn, and the controller consolidates lazily. Investigate only if the count is wildly disproportionate:

```bash
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web -o json | jq -r '
  .items[] | "\(.metadata.name)\t\(.endpoints|length)"'
```

Genuine causes of persistent extra slices: a named `targetPort` resolving to different numbers across Pods, which forces separate slices; dual stack, which doubles them; and mirroring running alongside hand written slices.

### An Endpoint Address Belongs to No Pod

```bash
kubectl get endpointslices -A -o json | jq -r '
  .items[].endpoints[] | select(.targetRef == null) | .addresses[0]'
```

An endpoint with no `targetRef` was written manually or mirrored from a hand written `Endpoints` object. On a cluster where you did not expect any, treat an unexplained external address in a Service as a security finding and check who created it.

---

## Exam and Interview Traps

1. **EndpointSlice is `discovery.k8s.io/v1`, not `v1`.** `Endpoints` is `v1`. Mixing them up fails immediately.
2. **EndpointSlice has no `spec` and no `status`.** `addressType`, `ports` and `endpoints` are top level fields.
3. **`kubernetes.io/service-name` is the binding**, not the object name and not the owner reference. Wrong label means an invisible slice.
4. **A Service can have many slices, and consumers must aggregate them.** Reading `items[0]` is a bug.
5. **`addressType` is immutable and one per slice.** Dual stack means two sets of slices for one Service.
6. **`ready` is not `serving`.** `ready` also requires not terminating, so a terminating Pod that is still healthy is `serving: true, ready: false`.
7. **`ready: nil` should be read as ready**, and `terminating: nil` as not terminating. Do not treat absent as false.
8. **The default is 100 endpoints per slice**, set by `--max-endpoints-per-slice` on kube-controller-manager, with 1000 as the ceiling.
9. **Slices are not kept perfectly packed.** The controller minimises writes, not object count, so partially filled slices during churn are expected.
10. **The `Endpoints` object has a hard size ceiling** driven by the etcd request limit of roughly 1.5 MiB, and very large Services get an `endpoints.kubernetes.io/over-capacity: truncated` annotation with real Pods silently omitted.
11. **The scaling problem was update amplification**, not storage: every watcher received the whole object for every one address change.
12. **Two controllers exist.** The EndpointSlice controller handles Services with selectors; the mirroring controller only mirrors hand written `Endpoints` objects.
13. **Mirroring is skipped** for `Endpoints` labelled `endpointslice.kubernetes.io/skip-mirror: "true"` or annotated as a leader election object.
14. **Leave `managed-by` unset on slices you write by hand.** Setting a controller's value invites that controller to take over.
15. **A hand written slice must live in the Service's namespace** and its `ports[].name` must match the Service's port name.
16. **Manually managed endpoints have no health checking.** Nothing removes a dead external host.
17. **Endpoints without `nodeName` can never satisfy `internalTrafficPolicy: Local` or `externalTrafficPolicy: Local`.**
18. **`hints` are written by the control plane**, are empty by default, and are silently withheld when the zone balance heuristic is not satisfied.
19. **Topology hints are a preference with automatic fallback**, while `Local` traffic policies are hard restrictions with none.
20. **kube-proxy can fall back to `serving` terminating endpoints** when no ready endpoint exists, which turns an outage into degradation.
21. **`ExternalName` Services never have slices or endpoints** at all.
22. **Deleting a Service garbage collects controller managed slices via `ownerReferences`**, but slices you wrote without one survive.

---

## Related Topics

- [Services](services.md)
- [Service Operations](service-operations.md)
- [kube-proxy](kube-proxy.md)
- [CoreDNS](coredns.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
- [Network Policy](network-policy.md)
- [MetalLB](metallb.md)
- [kube-controller-manager](kube-controller-manager.md)
- [Controllers](controllers.md)
- [etcd](etcd.md)
- [Kubernetes API](k8s-api.md)
- [Pods](pods.md)
- [Deployments](deployments.md)
- [StatefulSets](statefulsets.md)

---

## Key Takeaways

1. EndpointSlices exist because a single `Endpoints` object per Service caused **update amplification**: one Pod change rewrote the whole object and pushed it to every watcher on every node.
2. The second driver was the **object size ceiling** imposed by the etcd request limit of roughly 1.5 MiB, which caps a single `Endpoints` object and silently truncates very large Services.
3. Slicing turns an O(all endpoints) write into an O(one slice) write, and leaves headroom for **per endpoint metadata** that the old shape had no space for.
4. EndpointSlice lives in **`discovery.k8s.io/v1`** and has **no `spec` or `status`**: `addressType`, `ports` and `endpoints` are top level.
5. **`kubernetes.io/service-name` is the binding** between a slice and its Service, and consumers must **aggregate every slice** carrying that label.
6. **One address family per slice**, and `addressType` is immutable, so a dual stack Service always has at least two sets of slices.
7. **`ready` means suitable for new traffic; `serving` ignores termination; `terminating` reports deletion.** `ready` is effectively `serving` and not `terminating`.
8. Terminating but serving endpoints are what make **graceful shutdown** possible, and a `preStop` sleep plus a sane grace period is what closes the propagation race that causes deploy-time errors.
9. The default packing is **100 endpoints per slice**, tunable with `--max-endpoints-per-slice` up to 1000, and the controller optimises for **fewer writes rather than perfect packing**.
10. The **EndpointSlice controller** serves Services with selectors; the **EndpointSliceMirroring controller** exists only to mirror hand written `Endpoints` objects for selectorless Services.
11. Writing slices yourself is the modern, supported way to back a selectorless Service with external addresses. **Leave `managed-by` unset** so no controller fights you.
12. Hand written membership has **no health checking and no `nodeName`**, so it cannot participate in `Local` traffic policies and will happily point at a dead host forever.
13. kube-proxy filters by `ready`, by topology `hints` and by `nodeName`, then programs the datapath. **The Service carries the policy, the slice carries the facts**, so debugging needs both.
14. Topology `hints` are written by the control plane, are absent by default, and are **withheld automatically** when the per zone capacity heuristic is not met.
15. When endpoints look wrong, check in order: does the selector match Pods, are those Pods Ready, is the controller healthy, and only then look downstream at kube-proxy, DNS caches or conntrack.

---

## References

- [EndpointSlices concept](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
- [EndpointSlice API reference (discovery.k8s.io/v1)](https://kubernetes.io/docs/reference/kubernetes-api/service-resources/endpoint-slice-v1/)
- [Endpoints API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/service-resources/endpoints-v1/)
- [Service concept](https://kubernetes.io/docs/concepts/services-networking/service/)
- [Services without selectors](https://kubernetes.io/docs/concepts/services-networking/service/#services-without-selectors)
- [Topology Aware Routing](https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/)
- [Virtual IPs and Service Proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/)
- [kube-controller-manager reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/)
- [Pod Lifecycle and termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [IPv4/IPv6 dual-stack](https://kubernetes.io/docs/concepts/services-networking/dual-stack/)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
- [Well-Known Labels, Annotations and Taints](https://kubernetes.io/docs/reference/labels-annotations-taints/)
