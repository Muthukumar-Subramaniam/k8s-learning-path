# 🛂 Kubernetes Admission Control: The Last Gate Before etcd

Authorization decided *whether you may*. Admission decides *whether this specific object is acceptable*, and may rewrite it before it is stored. This document covers the two phase pipeline, the compiled-in controllers that ship with the API server, the `AdmissionConfiguration` file, CEL based `ValidatingAdmissionPolicy`, ordering and dry-run semantics, and the failure modes that can render a cluster unable to schedule a single pod.

## 📋 Table of Contents
- [Why Admission Exists](#why-admission-exists)
- [The Two Phase Pipeline](#the-two-phase-pipeline)
- [Mutating vs Validating](#mutating-vs-validating)
- [Reinvocation](#reinvocation)
- [Enabling and Disabling Controllers](#enabling-and-disabling-controllers)
- [The Default Enabled Set](#the-default-enabled-set)
- [Controller Catalogue](#controller-catalogue)
- [NamespaceLifecycle](#namespacelifecycle)
- [ServiceAccount](#serviceaccount)
- [NodeRestriction](#noderestriction)
- [LimitRanger](#limitranger)
- [ResourceQuota](#resourcequota)
- [PodSecurity](#podsecurity)
- [DefaultStorageClass and DefaultIngressClass](#defaultstorageclass-and-defaultingressclass)
- [Protection Controllers](#protection-controllers)
- [The AdmissionConfiguration File](#the-admissionconfiguration-file)
- [ValidatingAdmissionPolicy](#validatingadmissionpolicy)
- [CEL Expression Cookbook](#cel-expression-cookbook)
- [MutatingAdmissionPolicy](#mutatingadmissionpolicy)
- [Admission and Dry Run](#admission-and-dry-run)
- [Latency Budget](#latency-budget)
- [How Admission Bricks a Cluster](#how-admission-bricks-a-cluster)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why Admission Exists

Authorization answers a question about an *identity and a verb*. It deliberately never looks inside the request body. That leaves an enormous class of policy unexpressible:

```
   QUESTIONS AUTHORIZATION CANNOT ANSWER
   ─────────────────────────────────────
   "May alice create pods?"                     ◄── authorization CAN answer this
   "May alice create a PRIVILEGED pod?"         ◄── needs the body
   "Does this pod have resource limits?"         ◄── needs the body
   "Is this image from an approved registry?"    ◄── needs the body
   "Is the replica count being reduced below 3?" ◄── needs the OLD and NEW body
   "Should this pod get a sidecar injected?"     ◄── needs to MODIFY the body
```

Admission is the layer that can. It runs after authorization has said yes, receives the fully decoded object, and may accept it, reject it, or in the mutating phase rewrite it.

```
   TLS ──► AUTHN ──► AUTHZ ──► ┌──────────────────────┐ ──► SCHEMA ──► etcd
                               │      ADMISSION       │     VALIDATION
                               │  ◄── this document   │
                               └──────────────────────┘
```

A second, less obvious purpose: **defaulting**. A great deal of Kubernetes convenience is admission quietly filling in fields. The reason a pod you created without a `serviceAccountName` ends up with `default`, and with a projected token volume you never asked for, is an admission controller.

### What Admission Does Not See

Admission is invoked only for **write** operations that pass through the API server. It never sees:

- `get`, `list`, or `watch`. There is no read-time admission.
- Objects already in etcd. Enabling a policy does not retroactively evict violating workloads.
- Changes made by writing to etcd directly.

That first point is worth internalising: admission is a gate, not a scanner. Turning on `PodSecurity` with `enforce: restricted` today does nothing to the privileged pods already running. They keep running until something recreates them.

---

## The Two Phase Pipeline

Admission runs in two distinct passes with object schema validation sandwiched between them.

```
  ┌────────────────────────────────────────────────────────────────────────┐
  │                          ADMISSION PIPELINE                            │
  ├────────────────────────────────────────────────────────────────────────┤
  │                                                                        │
  │   incoming object                                                      │
  │        │                                                               │
  │        ▼                                                               │
  │  ┌───────────────────────────────────────────────────────┐             │
  │  │  PHASE 1: MUTATING                                    │             │
  │  │                                                       │             │
  │  │  built-in mutating plugins, in a FIXED internal order │             │
  │  │        ServiceAccount, DefaultStorageClass, ...       │             │
  │  │                        │                              │             │
  │  │                        ▼                              │             │
  │  │  MutatingAdmissionWebhook plugin                      │             │
  │  │        calls external webhooks, ordering NOT           │             │
  │  │        guaranteed between them                        │             │
  │  │                        │                              │             │
  │  │                        ▼                              │             │
  │  │  reinvocation pass (if any webhook asked for it)      │             │
  │  └───────────────────────────────────────────────────────┘             │
  │        │                                                               │
  │        ▼                                                               │
  │  ┌───────────────────────────────────────────────────────┐             │
  │  │  OBJECT SCHEMA VALIDATION                             │             │
  │  │  the mutated object must still be a legal object      │             │
  │  └───────────────────────────────────────────────────────┘             │
  │        │                                                               │
  │        ▼                                                               │
  │  ┌───────────────────────────────────────────────────────┐             │
  │  │  PHASE 2: VALIDATING                                  │             │
  │  │                                                       │             │
  │  │  built-in validating plugins                          │             │
  │  │  ValidatingAdmissionPolicy (CEL)                      │             │
  │  │  ValidatingAdmissionWebhook plugin                     │             │
  │  │        all run in PARALLEL, none may mutate           │             │
  │  │        ANY rejection fails the whole request           │             │
  │  └───────────────────────────────────────────────────────┘             │
  │        │                                                               │
  │        ▼                                                               │
  │     persist to etcd                                                    │
  │                                                                        │
  └────────────────────────────────────────────────────────────────────────┘
```

The ordering guarantees are precise and limited:

| Guarantee | Holds? |
|---|---|
| All mutating admission finishes before any validating admission starts | **Yes** |
| Built-in plugins run in a deterministic order | **Yes**, a fixed compile-time order |
| External mutating webhooks run in a defined order relative to each other | **No** |
| Validating webhooks run in a defined order | **No**, they run in parallel |
| A validating webhook sees the final, fully mutated object | **Yes** |
| A mutating webhook sees the output of all previous mutations | **Not guaranteed** without reinvocation |

The lack of ordering between mutating webhooks is the source of most webhook bugs in the wild. Two webhooks that both patch `spec.containers` can produce different results on different requests. If your logic depends on seeing another webhook's output, you need `reinvocationPolicy: IfNeeded` and idempotent patches.

---

## Mutating vs Validating

```
   ┌──────────────────┬────────────────────────┬───────────────────────────┐
   │                  │  MUTATING              │  VALIDATING               │
   ├──────────────────┼────────────────────────┼───────────────────────────┤
   │ May change object│  Yes                   │  No                       │
   │ Execution        │  Serial                │  Parallel                 │
   │ Ordering         │  Not guaranteed        │  Irrelevant, parallel     │
   │ Sees final object│  No                    │  Yes                      │
   │ Typical use      │  defaulting, injection │  policy enforcement       │
   │ Reinvocation     │  Possible              │  Never                    │
   │ Failure effect   │  Request rejected      │  Request rejected         │
   └──────────────────┴────────────────────────┴───────────────────────────┘
```

A controller can be both. `PodSecurity`, for example, is purely validating. `ServiceAccount` is both: it mutates by assigning the default SA and adding the token volume, and validates that a referenced SA actually exists.

The practical guidance is simple: **prefer validating**. A mutating controller changes what the user asked for, which makes GitOps drift detection lie and makes debugging harder because the stored object no longer matches the manifest in git. Mutate only for genuine defaulting and injection.

---

## Reinvocation

Because mutating webhooks are unordered, a webhook may run before another webhook makes a change it cares about. `reinvocationPolicy` addresses this.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: sidecar-injector
webhooks:
  - name: inject.example.com
    # Never  : call this webhook at most once per request (default).
    # IfNeeded: call it again if a LATER webhook modified the object.
    reinvocationPolicy: IfNeeded
    # ... rest of config
```

Rules of reinvocation:

- Only mutating webhooks are ever reinvoked. Validating webhooks never are.
- Reinvocation happens at most **once** more. There is no loop until stable.
- Built-in mutating plugins are **not** reinvoked.
- Your webhook **must be idempotent**. If it injects a sidecar, it must first check whether that sidecar is already present, or reinvocation will inject it twice.

```python
# Idempotency is not optional with reinvocationPolicy: IfNeeded
existing = [c["name"] for c in pod["spec"]["containers"]]
if "log-shipper" not in existing:
    patches.append({"op": "add",
                    "path": "/spec/containers/-",
                    "value": sidecar_spec})
```

---

## Enabling and Disabling Controllers

Admission controllers are compiled into the API server binary. You select which of them are active with two flags.

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml
    command:
      - kube-apiserver
      # ADDS to the default set. Does not replace it.
      - --enable-admission-plugins=NodeRestriction,PodSecurity,AlwaysPullImages
      # REMOVES from the default set.
      - --disable-admission-plugins=DefaultStorageClass
```

The semantics catch people out:

- `--enable-admission-plugins` is **additive**. Listing three plugins does not disable the other twenty defaults.
- `--disable-admission-plugins` is subtractive and wins over enable if a plugin appears in both.
- Order in these lists is **irrelevant**. The execution order is fixed at compile time, not by the flag.
- Names are case sensitive.

Discover what your binary supports and what is on by default:

```bash
# The authoritative list for YOUR version, from the binary itself.
kube-apiserver -h | grep -A 40 'enable-admission-plugins'

# From inside the running static pod on a control plane node
sudo crictl exec -it \
  $(sudo crictl ps --name kube-apiserver -q) \
  kube-apiserver -h 2>/dev/null | grep -A 5 'default enabled ones'

# What is actually configured right now
sudo grep admission-plugins /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## The Default Enabled Set

On a recent Kubernetes release, the plugins enabled by default (before any flags) include:

```
  CertificateApproval              CertificateSigning
  CertificateSubjectRestriction    DefaultIngressClass
  DefaultStorageClass              DefaultTolerationSeconds
  LimitRanger                      MutatingAdmissionWebhook
  NamespaceLifecycle               PersistentVolumeClaimResize
  PodSecurity                      Priority
  ResourceQuota                    RuntimeClass
  ServiceAccount                   StorageObjectInUseProtection
  TaintNodesByCondition            ValidatingAdmissionPolicy
  ValidatingAdmissionWebhook
```

Notably **not** in the default set, and which kubeadm adds explicitly:

```
  NodeRestriction
```

Others you must opt into if you want them:

```
  AlwaysPullImages                 DenyServiceExternalIPs
  EventRateLimit                   ImagePolicyWebhook
  LimitPodHardAntiAffinityTopology PodNodeSelector
  PodTolerationRestriction
```

Always confirm against your own binary rather than trusting a list in a document, since the set shifts between releases.

---

## Controller Catalogue

A working reference. The ones that most affect day to day behaviour get their own sections below.

| Controller | Phase | What it does |
|---|---|---|
| `NamespaceLifecycle` | Validating | Blocks creation in terminating or non-existent namespaces; protects `default`, `kube-system`, `kube-public` from deletion. |
| `ServiceAccount` | Both | Assigns `default` SA, mounts the projected token, validates the SA exists, adds `imagePullSecrets`. |
| `NodeRestriction` | Validating | Limits what a kubelet may write to its own Node and Pod objects. |
| `LimitRanger` | Both | Applies `LimitRange` defaults and enforces min/max per object. |
| `ResourceQuota` | Validating | Enforces namespace `ResourceQuota`, and tracks usage. |
| `PodSecurity` | Validating | Enforces Pod Security Standards from namespace labels. |
| `DefaultStorageClass` | Mutating | Sets `storageClassName` on a PVC that omits it. |
| `DefaultIngressClass` | Mutating | Sets `ingressClassName` on an Ingress that omits it. |
| `DefaultTolerationSeconds` | Mutating | Adds 300s tolerations for `notReady` and `unreachable` taints. |
| `TaintNodesByCondition` | Mutating | Taints new Nodes as `NotReady` until the node reports ready. |
| `Priority` | Both | Resolves `priorityClassName` into the integer `priority` field. |
| `RuntimeClass` | Both | Injects pod `overhead` from the referenced RuntimeClass. |
| `PersistentVolumeClaimResize` | Validating | Permits PVC expansion only if the StorageClass allows it. |
| `StorageObjectInUseProtection` | Mutating | Adds finalizers to PVs and PVCs so in-use volumes are not deleted. |
| `CertificateApproval` | Validating | Requires `approve` permission on the specific `signerName`. |
| `CertificateSigning` | Validating | Requires `sign` permission on the specific `signerName`. |
| `CertificateSubjectRestriction` | Validating | Blocks CSRs requesting the `system:masters` group. |
| `MutatingAdmissionWebhook` | Mutating | Dispatches to external mutating webhooks. |
| `ValidatingAdmissionWebhook` | Validating | Dispatches to external validating webhooks. |
| `ValidatingAdmissionPolicy` | Validating | Evaluates in-tree CEL policies. |
| `AlwaysPullImages` | Mutating | Forces `imagePullPolicy: Always` on every container. |
| `EventRateLimit` | Validating | Rate limits Event creation to protect etcd. |
| `PodNodeSelector` | Both | Forces a namespace-wide `nodeSelector`. |
| `PodTolerationRestriction` | Both | Restricts which tolerations pods in a namespace may use. |
| `DenyServiceExternalIPs` | Validating | Blocks the `spec.externalIPs` field, which is a known hijacking vector. |
| `LimitPodHardAntiAffinityTopology` | Validating | Restricts hard anti-affinity to the hostname topology key. |

---

## NamespaceLifecycle

Small, always on, and responsible for two behaviours everyone has hit.

**Objects cannot be created in a namespace that is terminating.** When you delete a namespace it enters `Terminating` while finalizers drain its contents. Any create during that window is rejected:

```
Error from server (Forbidden): error when creating "pod.yaml":
pods "web" is forbidden: unable to create new content in namespace dev
because it is being terminated
```

This is the classic CI race: a pipeline deletes a namespace then immediately recreates its resources. The fix is to wait for the namespace to actually disappear.

```bash
kubectl delete namespace dev --wait=true
# or explicitly
kubectl wait --for=delete namespace/dev --timeout=120s
```

**The three system namespaces cannot be deleted.** `default`, `kube-system` and `kube-public` are hardcoded as undeletable, which prevents a fat-fingered `kubectl delete ns kube-system` from destroying the cluster.

---

## ServiceAccount

The controller responsible for the most "where did that come from" moments in Kubernetes.

Given this minimal pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  containers:
    - name: app
      image: nginx:1.27
```

The stored object contains a great deal you never wrote:

```yaml
spec:
  # Added: the namespace default SA
  serviceAccountName: default
  serviceAccount: default            # deprecated alias, still populated
  # Added: a projected token volume
  volumes:
    - name: kube-api-access-x7k2p
      projected:
        defaultMode: 420
        sources:
          - serviceAccountToken:
              # Bound, short lived, audience scoped token.
              expirationSeconds: 3607
              path: token
          - configMap:
              name: kube-root-ca.crt
              items:
                - key: ca.crt
                  path: ca.crt
          - downwardAPI:
              items:
                - fieldRef:
                    apiVersion: v1
                    fieldPath: metadata.namespace
                  path: namespace
  containers:
    - name: app
      image: nginx:1.27
      # Added: the mount for that volume
      volumeMounts:
        - name: kube-api-access-x7k2p
          mountPath: /var/run/secrets/kubernetes.io/serviceaccount
          readOnly: true
```

What the controller does, in order:

1. If `spec.serviceAccountName` is empty, set it to `default`.
2. Validate the named ServiceAccount exists. If not, reject the pod.
3. Copy `imagePullSecrets` from the ServiceAccount onto the pod.
4. Unless opted out, add the projected token volume and mount it into every container.

### Opting Out

The token is a credential. Most workloads never call the API and should not carry one.

```yaml
# Per pod
apiVersion: v1
kind: Pod
spec:
  automountServiceAccountToken: false
```

```yaml
# Per service account, applies to every pod that uses it
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: production
automountServiceAccountToken: false
```

Setting this on the `default` ServiceAccount in every namespace is one of the highest value, lowest effort hardening steps available. The pod-level setting overrides the ServiceAccount-level setting.

See [service-accounts.md](service-accounts.md) for the full identity model.

---

## NodeRestriction

The admission half of the kubelet containment story. The Node authorizer decides *which objects* a kubelet may touch; NodeRestriction inspects *what it is trying to write*.

```
   ┌────────────────────────────────────────────────────────────────────┐
   │  kubelet on worker-01:  PATCH /api/v1/nodes/worker-01              │
   │  body: metadata.labels["topology.kubernetes.io/zone"] = "eu-west"  │
   ├────────────────────────────────────────────────────────────────────┤
   │  Node authorizer:   own Node object?  yes  → ALLOW                 │
   │                     (cannot see the label)                         │
   │  NodeRestriction:   is this label self-settable?  yes → ADMIT      │
   └────────────────────────────────────────────────────────────────────┘

   ┌────────────────────────────────────────────────────────────────────┐
   │  kubelet on worker-01:  PATCH /api/v1/nodes/worker-01              │
   │  body: metadata.labels["tier"] = "secure"                          │
   ├────────────────────────────────────────────────────────────────────┤
   │  Node authorizer:   own Node object?  yes  → ALLOW                 │
   │  NodeRestriction:   arbitrary label from a kubelet → REJECT        │
   └────────────────────────────────────────────────────────────────────┘
```

Enforced rules:

- A kubelet may only modify its own `Node` object and the `Pod` objects bound to it.
- A kubelet may self-set only a permitted label set: `kubernetes.io/hostname`, `kubernetes.io/os`, `kubernetes.io/arch`, `node.kubernetes.io/instance-type`, `topology.kubernetes.io/region`, `topology.kubernetes.io/zone` and a few others.
- Labels prefixed `node-restriction.kubernetes.io/` are explicitly **blocked** from kubelet self-assignment. This exists so that you can label nodes with that prefix from a trusted controller and have scheduling constraints that a compromised kubelet cannot forge.
- A kubelet cannot create mirror pods that reference a ServiceAccount or arbitrary secrets.
- A kubelet cannot delete its own Node object.

```yaml
# A node label a compromised kubelet CANNOT forge, because of NodeRestriction.
# Safe to use as a scheduling constraint for sensitive workloads.
kubectl label node worker-03 node-restriction.kubernetes.io/tier=pci
```

```yaml
apiVersion: v1
kind: Pod
spec:
  nodeSelector:
    node-restriction.kubernetes.io/tier: pci
```

Enable it explicitly. It is not in the default set:

```yaml
- --enable-admission-plugins=NodeRestriction
```

---

## LimitRanger

The controller behind `LimitRange`, which does two different jobs that are easy to conflate: **defaulting** and **bounding**.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: container-limits
  namespace: dev
spec:
  limits:
    - type: Container
      # Applied when a container specifies NO limits at all.
      default:
        cpu: "500m"
        memory: "512Mi"
      # Applied when a container specifies NO requests.
      # If it specifies limits but not requests, requests default to limits.
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      # Hard ceiling. A container asking for more is REJECTED.
      max:
        cpu: "2"
        memory: "2Gi"
      # Hard floor. A container asking for less is REJECTED.
      min:
        cpu: "50m"
        memory: "64Mi"
      # limit / request may not exceed this ratio.
      # Stops people requesting 10m and limiting 4 CPUs.
      maxLimitRequestRatio:
        cpu: "4"

    - type: Pod
      # Sum across ALL containers in the pod.
      max:
        cpu: "4"
        memory: "8Gi"

    - type: PersistentVolumeClaim
      min:
        storage: "1Gi"
      max:
        storage: "100Gi"
```

The defaulting half runs in the mutating phase; the bounding half runs in the validating phase. That is why a container with no resources at all is silently given some, while a container asking for 8 CPU is rejected with a clear message.

Interaction worth knowing: `LimitRanger` defaults run *before* `ResourceQuota` validates. If a namespace has a quota requiring every pod to declare requests, a `LimitRange` with `defaultRequest` satisfies it automatically. Without the `LimitRange`, users get a confusing quota rejection on a pod that looks fine.

See [resource-management.md](resource-management.md).

---

## ResourceQuota

Enforces namespace-level `ResourceQuota` objects. Two aspects deserve attention.

**It is a validating controller with state.** It must read current usage, compare against the quota, and admit or reject. Under high create rates this becomes a serialisation point, and you will see `Operation cannot be fulfilled on resourcequotas` conflict errors as the usage counter is contended. The API server retries these internally.

**A quota on `requests.cpu` makes requests mandatory.** Once a namespace has a quota that counts a resource, every pod created there **must** specify that resource, or it is rejected:

```
Error from server (Forbidden): error when creating "pod.yaml":
pods "web" is forbidden: failed quota: compute-quota:
must specify limits.memory,requests.memory
```

This is the most common quota surprise. Pair every `ResourceQuota` with a `LimitRange` that provides defaults, and the problem disappears.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: dev
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    # Object count quotas
    pods: "50"
    services: "10"
    services.loadbalancers: "2"       # LB services often cost real money
    persistentvolumeclaims: "20"
    count/deployments.apps: "20"
    count/secrets: "50"
```

---

## PodSecurity

The built-in replacement for the removed PodSecurityPolicy. It reads namespace labels and validates pods against the Pod Security Standards.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    # Reject anything that violates the restricted profile.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.31
    # Also log violations of restricted to the audit log.
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.31
    # And return a warning to the client.
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.31
```

The behaviour that trips everyone up: **`enforce` applies to Pods, not to controllers.** Creating a Deployment whose pod template violates the policy succeeds. The Deployment is admitted, the ReplicaSet is created, and then every pod creation fails. You see a healthy-looking Deployment with zero ready replicas.

That is exactly why `warn` exists. The `warn` mode *does* evaluate controller objects and returns a warning at `kubectl apply` time:

```
Warning: would violate PodSecurity "restricted:v1.31": allowPrivilegeEscalation
!= false (container "app" must set securityContext.allowPrivilegeEscalation=false)
deployment.apps/web created
```

Always set `warn` alongside `enforce`. Full treatment in [pod-security-standards.md](pod-security-standards.md).

---

## DefaultStorageClass and DefaultIngressClass

Two small mutating controllers with outsized impact on user experience.

`DefaultStorageClass` fills in `spec.storageClassName` on a PVC that omits it, using whichever StorageClass carries the default annotation:

```bash
kubectl get storageclass
# NAME              PROVISIONER          RECLAIMPOLICY  ...
# nfs-csi (default) nfs.csi.k8s.io       Delete
```

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
```

Two failure modes:

- **No default class.** A PVC with no `storageClassName` stays `Pending` forever with no obvious error. `kubectl describe pvc` shows no events at all in some cases.
- **Two default classes.** The controller picks one non-deterministically and emits a warning. Always ensure exactly zero or one.

```bash
# Find accidental duplicates
kubectl get sc -o json | jq -r '
  .items[]
  | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")
  | .metadata.name'
```

Note the distinction between an empty `storageClassName` field (defaulting applies) and an explicitly set `storageClassName: ""` (defaulting is suppressed, the PVC will only bind to a PV with no class). See [storage-classes.md](storage-classes.md).

`DefaultIngressClass` does the equivalent for Ingress objects using the `ingressclass.kubernetes.io/is-default-class` annotation.

---

## Protection Controllers

`StorageObjectInUseProtection` adds finalizers so that deleting a volume in use does not silently destroy data:

- `kubernetes.io/pvc-protection` on PVCs
- `kubernetes.io/pv-protection` on PVs

Delete a PVC that a running pod mounts and it enters `Terminating` and stays there until the pod goes away. This is correct behaviour that frequently looks like a bug:

```bash
kubectl get pvc data-0
# NAME     STATUS        VOLUME   ...
# data-0   Terminating   pvc-abc  ...

# Find what is holding it
kubectl describe pvc data-0 | grep -A 3 'Used By'
```

The wrong fix is to strip the finalizer. The right fix is to delete the consuming pod.

`PersistentVolumeClaimResize` rejects a PVC size increase unless the StorageClass has `allowVolumeExpansion: true`, and rejects decreases outright, since no CSI driver supports shrinking.

---

## The AdmissionConfiguration File

Some controllers need configuration beyond on/off. That configuration lives in an `AdmissionConfiguration` file referenced by `--admission-control-config-file`.

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  # Cluster wide Pod Security defaults, so a namespace with NO labels
  # still gets a baseline rather than nothing.
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        # Identities exempt from all enforcement.
        usernames: []
        # RuntimeClasses exempt, for sandboxed workloads.
        runtimeClasses: []
        # Namespaces exempt. kube-system genuinely needs privileged pods.
        namespaces:
          - kube-system

  # Protect etcd from event storms.
  - name: EventRateLimit
    configuration:
      apiVersion: eventratelimit.admission.k8s.io/v1alpha1
      kind: Configuration
      limits:
        - type: Namespace
          qps: 50
          burst: 100
          cacheSize: 2000
        - type: Server
          qps: 500
          burst: 1000

  # A plugin can also point at its own separate file.
  - name: ImagePolicyWebhook
    path: /etc/kubernetes/admission/imagepolicy.yaml
```

Wire it up. Remember that a flag referencing a host path is useless without the corresponding volume, which is the single most common mistake here:

```yaml
    command:
      - kube-apiserver
      - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
      - --enable-admission-plugins=NodeRestriction,PodSecurity,EventRateLimit
    volumeMounts:
      - name: admission-config
        mountPath: /etc/kubernetes/admission
        readOnly: true
  volumes:
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission
        type: DirectoryOrCreate
```

On an HA cluster the file must exist identically on **every** control plane node, or behaviour depends on which API server your request lands on.

---

## ValidatingAdmissionPolicy

Since 1.30 this is GA, and it is the most important recent change to admission control. It lets you express validation policy in CEL, evaluated **inside the API server**, with no webhook, no TLS certificates, no deployment to keep alive, and no network hop.

```
   WEBHOOK                            ValidatingAdmissionPolicy
   ───────                            ─────────────────────────
   external Deployment                 evaluated in-process
   TLS cert + CA bundle                no certificates
   network round trip per request      microseconds, no network
   outage = admission failure          cannot be "down"
   arbitrary Go/Python logic           CEL only
   can mutate (mutating variant)       validation only (see next section)
```

### The Three Objects

```
   ┌──────────────────────────────┐
   │ ValidatingAdmissionPolicy    │  the LOGIC. What is checked.
   │   matchConstraints           │  Cluster scoped. Inert on its own.
   │   validations (CEL)          │
   │   paramKind (optional)       │
   └──────────────┬───────────────┘
                  │ referenced by
                  ▼
   ┌──────────────────────────────┐
   │ ValidatingAdmissionPolicy    │  the BINDING. Where it applies,
   │ Binding                      │  and how hard.
   │   policyName                 │
   │   matchResources             │
   │   validationActions          │
   │   paramRef (optional)        │
   └──────────────┬───────────────┘
                  │ may point at
                  ▼
   ┌──────────────────────────────┐
   │ a parameter object           │  the DATA. Often a ConfigMap or CRD,
   │ (ConfigMap or custom CRD)    │  letting one policy be reused with
   └──────────────────────────────┘  different values per namespace.
```

A policy with no binding does nothing. This separation is deliberate: a platform team ships the policy, and application teams (or a rollout process) attach bindings gradually.

### A Complete Example

Require that every container in a Deployment declares memory limits.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-memory-limits
spec:
  # Behaviour when a CEL expression itself errors (not when it returns false).
  # Fail  : reject the request.
  # Ignore: allow the request.
  failurePolicy: Fail

  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments", "statefulsets", "daemonsets"]

  # Named sub-expressions. Evaluated lazily, cached, and referenced
  # as variables.<name>. Keeps the validations readable.
  variables:
    - name: containers
      expression: "object.spec.template.spec.containers"
    - name: missingLimits
      expression: >-
        variables.containers.filter(c,
          !has(c.resources) ||
          !has(c.resources.limits) ||
          !('memory' in c.resources.limits))

  validations:
    - expression: "size(variables.missingLimits) == 0"
      # Dynamic message. Must evaluate to a string.
      messageExpression: >-
        "containers missing memory limits: " +
        variables.missingLimits.map(c, c.name).join(", ")
      # Machine readable reason returned to the client.
      reason: Invalid
```

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-memory-limits-binding
spec:
  policyName: require-memory-limits

  # Deny  : reject violations.
  # Warn  : return a warning header, allow the request.
  # Audit : record in the audit log, allow the request.
  # These compose. Start with Warn + Audit, graduate to Deny.
  validationActions: ["Deny"]

  matchResources:
    namespaceSelector:
      matchExpressions:
        # Apply everywhere except the control plane namespaces.
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public"]
```

### The Roll-Out Pattern

The `validationActions` field makes safe adoption trivial. This is the single biggest operational advantage over webhooks.

```yaml
# Stage 1: observe only. Nothing is rejected.
validationActions: ["Audit"]

# Stage 2: tell users, still nothing rejected.
validationActions: ["Warn", "Audit"]

# Stage 3: enforce.
validationActions: ["Deny", "Audit"]
```

Query the audit log during stage 1 to size the blast radius before enforcing:

```bash
sudo jq -r 'select(.annotations["validation.policy.admission.k8s.io/validation_failure"])
  | [.objectRef.namespace, .objectRef.name] | @tsv' \
  /var/log/kubernetes/audit.log | sort | uniq -c | sort -rn
```

### Parameterised Policies

One policy, different limits per environment.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: replica-floor
spec:
  failurePolicy: Fail
  # The type of object that supplies parameters.
  paramKind:
    apiVersion: v1
    kind: ConfigMap
  matchConstraints:
    resourceRules:
      - apiGroups:   ["apps"]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
  validations:
    # params refers to the bound ConfigMap.
    # ConfigMap data values are always strings, hence the int() cast.
    - expression: "object.spec.replicas >= int(params.data.minReplicas)"
      messageExpression: >-
        "at least " + params.data.minReplicas + " replicas required in this namespace"
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: replica-policy
  namespace: production
data:
  minReplicas: "3"
```

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: replica-floor-production
spec:
  policyName: replica-floor
  validationActions: ["Deny"]
  paramRef:
    name: replica-policy
    namespace: production
    # Deny  : if the param object is missing, reject.
    # Allow : if missing, skip the policy.
    parameterNotFoundAction: Deny
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: production
```

---

## CEL Expression Cookbook

The variables available inside a `ValidatingAdmissionPolicy` expression:

| Variable | Meaning |
|---|---|
| `object` | The incoming object. `null` on DELETE. |
| `oldObject` | The existing object. `null` on CREATE. |
| `request` | Admission request metadata (`request.operation`, `request.userInfo`, `request.namespace`, `request.name`, `request.dryRun`). |
| `params` | The bound parameter object, if `paramKind` is set. |
| `namespaceObject` | The full Namespace object of the request. |
| `authorizer` | Lets the policy perform an authorization check inline. |
| `variables.<name>` | Your own named expressions. |

### Recipes

```cel
// Every container image must come from an approved registry.
object.spec.containers.all(c,
  c.image.startsWith("registry.internal.example.com/") ||
  c.image.startsWith("gcr.io/distroless/"))
```

```cel
// No :latest tags. Note images without a tag also default to latest.
object.spec.containers.all(c,
  c.image.contains(":") && !c.image.endsWith(":latest"))
```

```cel
// Require a digest pin rather than a tag.
object.spec.containers.all(c, c.image.contains("@sha256:"))
```

```cel
// Replicas may never be reduced on update. oldObject is null on CREATE,
// so guard with the operation check.
request.operation == "CREATE" ||
object.spec.replicas >= oldObject.spec.replicas
```

```cel
// A required label must be present and non-empty.
has(object.metadata.labels) &&
'team' in object.metadata.labels &&
object.metadata.labels['team'] != ""
```

```cel
// An immutable field. Once set, it may not change.
request.operation == "CREATE" ||
object.spec.storageClassName == oldObject.spec.storageClassName
```

```cel
// No host namespaces.
!has(object.spec.hostNetwork) || object.spec.hostNetwork == false
```

```cel
// Limits must not exceed 4 CPU. quantity() understands Kubernetes
// resource quantity strings including m, Ki, Mi, Gi.
object.spec.containers.all(c,
  !has(c.resources.limits) ||
  !('cpu' in c.resources.limits) ||
  quantity(c.resources.limits.cpu).isLessThan(quantity("4001m")))
```

```cel
// Exempt cluster admins from the policy using the authorizer.
authorizer.group('').resource('pods').namespace(request.namespace)
  .check('create').allowed() == false ||
object.spec.containers.all(c, has(c.resources.limits))
```

```cel
// Only enforce on non dry-run requests.
request.dryRun == true || object.spec.replicas >= 2
```

### CEL Gotchas

- **`has()` before field access.** CEL errors on a missing field rather than returning null. With `failurePolicy: Fail`, that error rejects the request. Guard every optional field.
- **Maps versus lists.** `object.spec.containers` is a list; use `.all()`, `.exists()`, `.filter()`, `.map()`. `object.metadata.labels` is a map; use `in` and index access.
- **ConfigMap values are strings.** Always cast with `int()` or `double()`.
- **No loops, no recursion.** CEL is intentionally non-Turing-complete so evaluation always terminates. Complex logic belongs in a webhook.
- **Cost limits.** The API server rejects expressions whose estimated evaluation cost is too high. Deeply nested comprehensions over unbounded lists will be refused at policy creation time.
- **`oldObject` is null on CREATE**, `object` is null on DELETE. Always branch on `request.operation`.

Test expressions before deploying them:

```bash
# Dry-run an object against the live policy set
kubectl apply -f deployment.yaml --dry-run=server

# The API server reports policy violations exactly as it would on a real apply
```

---

## MutatingAdmissionPolicy

The mutating counterpart, `MutatingAdmissionPolicy`, is a newer addition and is still gated behind a feature gate in current releases rather than being on by default. It applies CEL based mutations using either an apply configuration or a JSON patch, removing the need for a mutating webhook for simple defaulting.

```yaml
apiVersion: admissionregistration.k8s.io/v1alpha1
kind: MutatingAdmissionPolicy
metadata:
  name: default-team-label
spec:
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE"]
        resources:   ["pods"]
  # Never or IfNeeded, same semantics as webhook reinvocation.
  reinvocationPolicy: Never
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{
            metadata: Object.metadata{
              labels: {"injected-by": "mutating-policy"}
            }
          }
```

Check availability on your cluster before relying on it:

```bash
kubectl api-resources --api-group=admissionregistration.k8s.io
sudo grep feature-gates /etc/kubernetes/manifests/kube-apiserver.yaml
```

Until it is GA, mutating webhooks remain the portable option. See [admission-webhooks.md](admission-webhooks.md).

---

## Admission and Dry Run

`--dry-run=server` sends the request through the entire pipeline including admission, then discards the result instead of persisting it.

```bash
kubectl apply -f deployment.yaml --dry-run=server
```

This is genuinely useful: it is the only way to know whether an object will be accepted without accepting it. `--dry-run=client` does nothing of the sort; it merely validates YAML locally and never contacts the API server.

Requirements on the admission side:

- Built-in controllers are dry-run aware and behave correctly.
- A webhook must declare `sideEffects: None` or `NoneOnDryRun` to be called during a dry run. A webhook declaring `sideEffects: Unknown` or `Some` is **skipped**, and the API server returns an error rather than silently giving you an incomplete answer.
- The `request.dryRun` field is `true` in the AdmissionReview, so a webhook can branch on it.

```yaml
webhooks:
  - name: policy.example.com
    # Declare honestly. If your webhook writes to a database or increments
    # a counter, that is a side effect and dry-run must be handled.
    sideEffects: None
```

---

## Latency Budget

Every admission controller sits on the write path. Their cost is additive and directly visible as API latency.

```
   Typical per-request cost
   ────────────────────────
   built-in plugin              microseconds
   ValidatingAdmissionPolicy    tens of microseconds, in-process
   admission webhook            1 network round trip + handler time
                                realistically 2ms to 50ms
```

Ten webhooks matching all resources means ten round trips on every single write, including the writes the control plane itself makes. The controller manager reconciling thousands of objects will feel it.

Mitigations, in order of effectiveness:

1. **Use `ValidatingAdmissionPolicy` instead of a webhook** wherever CEL suffices. No network hop at all.
2. **Narrow `rules`.** Match only the API groups, resources and operations you actually care about. A webhook matching `resources: ["*"]` is on the path for Lease updates, which happen constantly.
3. **Use `objectSelector` and `namespaceSelector`** so the API server filters before dialling.
4. **Set a tight `timeoutSeconds`.** Default is 10, which is far too long. Use 2 to 5.
5. **Exclude control plane namespaces** with a `namespaceSelector`.

```yaml
webhooks:
  - name: policy.example.com
    timeoutSeconds: 3
    rules:
      - apiGroups:   ["apps"]        # not "*"
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["deployments"]
        scope:       "Namespaced"
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease"]
    objectSelector:
      matchLabels:
        policy.example.com/enforce: "true"
```

Watch the cost:

```bash
kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration
kubectl get --raw /metrics | grep apiserver_admission_controller_admission_duration
```

---

## How Admission Bricks a Cluster

Admission is the most common way to make a Kubernetes cluster unusable, because a rejection here blocks writes from the control plane itself.

### The Classic Outage

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  1. A ValidatingWebhookConfiguration is created with:                │
   │        rules:         resources: ["*"], operations: ["*"]            │
   │        failurePolicy: Fail                                           │
   │        namespaceSelector: (none)                                     │
   │                                                                      │
   │  2. The webhook Deployment lives in namespace "policy-system".       │
   │                                                                      │
   │  3. The webhook pod is evicted, or its node reboots.                 │
   │                                                                      │
   │  4. The scheduler tries to bind a replacement pod.                   │
   │     That binding is a WRITE. It goes through admission.              │
   │     Admission calls the webhook. The webhook is down.                │
   │     failurePolicy: Fail  ──►  binding REJECTED.                      │
   │                                                                      │
   │  5. The webhook can never be rescheduled, because rescheduling it    │
   │     requires the webhook to be up. Total deadlock.                   │
   │                                                                      │
   │  6. Every write in the cluster now fails, including                  │
   │     node status updates and lease renewals.                          │
   └──────────────────────────────────────────────────────────────────────┘
```

Recovery requires deleting the webhook configuration. This still works because deleting a `ValidatingWebhookConfiguration` is itself subject to admission, but the API server explicitly does not call a webhook on changes to `admissionregistration.k8s.io` resources, precisely to preserve this escape hatch.

```bash
# The break-glass command. Know it before you need it.
kubectl delete validatingwebhookconfiguration <name>
kubectl delete mutatingwebhookconfiguration <name>

# If kubectl itself is failing, go to a control plane node and use
# the API server directly with the admin credentials.
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
  delete validatingwebhookconfiguration <name>
```

### Prevention Checklist

```yaml
webhooks:
  - name: policy.example.com
    # 1. Fail open unless you have a genuine security reason not to.
    failurePolicy: Ignore

    # 2. ALWAYS exclude kube-system and your own namespace.
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "policy-system"]

    # 3. Never match "*" resources.
    rules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE"]
        resources:   ["pods"]

    # 4. Short timeout.
    timeoutSeconds: 3
```

Plus: run the webhook with at least two replicas, a PodDisruptionBudget, and anti-affinity across nodes. See [pod-disruption-budgets.md](pod-disruption-budgets.md).

The `ValidatingAdmissionPolicy` alternative sidesteps this entire failure class, since there is no external service to lose.

---

## Recipes

### Recipe: Inventory Everything on the Admission Path

```bash
echo "=== Enabled plugins ==="
sudo grep -E 'enable-admission-plugins|disable-admission-plugins' \
  /etc/kubernetes/manifests/kube-apiserver.yaml

echo "=== Mutating webhooks ==="
kubectl get mutatingwebhookconfigurations -o custom-columns=\
'NAME:.metadata.name,WEBHOOKS:.webhooks[*].name,FAILURE:.webhooks[*].failurePolicy'

echo "=== Validating webhooks ==="
kubectl get validatingwebhookconfigurations -o custom-columns=\
'NAME:.metadata.name,WEBHOOKS:.webhooks[*].name,FAILURE:.webhooks[*].failurePolicy'

echo "=== CEL policies ==="
kubectl get validatingadmissionpolicies
kubectl get validatingadmissionpolicybindings
```

### Recipe: Find Dangerous Webhook Configurations

Webhooks that match everything and fail closed are the ones that will take you down.

```bash
kubectl get validatingwebhookconfigurations -o json | jq -r '
  .items[] as $c
  | $c.webhooks[]
  | select(.failurePolicy == "Fail")
  | select(.rules[]? | (.resources[]? == "*") or (.apiGroups[]? == "*"))
  | "DANGER  \($c.metadata.name)/\(.name)  matches everything and fails closed"'
```

### Recipe: Enforce No :latest Images, Safely

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: no-latest-tag
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: allContainers
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
    - name: bad
      expression: >-
        variables.allContainers.filter(c,
          c.image.endsWith(":latest") || !c.image.contains(":"))
  validations:
    - expression: "size(variables.bad) == 0"
      messageExpression: >-
        "images must be pinned to a specific tag or digest: " +
        variables.bad.map(c, c.image).join(", ")
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: no-latest-tag-binding
spec:
  policyName: no-latest-tag
  # Start here. Flip to Deny once the audit log is clean.
  validationActions: ["Warn", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public"]
```

### Recipe: Harden Every Default ServiceAccount

```bash
# Stop mounting API tokens into pods that never call the API.
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in
    kube-system|kube-public|kube-node-lease) continue ;;
  esac
  kubectl patch serviceaccount default -n "$ns" \
    -p '{"automountServiceAccountToken": false}'
done
```

Workloads that genuinely need a token then opt back in explicitly with `automountServiceAccountToken: true` on the pod, which makes the requirement visible in the manifest.

---

## Command Reference

```bash
# ---------- What is enabled ----------
sudo grep admission /etc/kubernetes/manifests/kube-apiserver.yaml
kube-apiserver -h | grep -A 40 'enable-admission-plugins'

# ---------- Webhook configurations ----------
kubectl get mutatingwebhookconfigurations
kubectl get validatingwebhookconfigurations
kubectl describe validatingwebhookconfiguration NAME
kubectl get validatingwebhookconfiguration NAME -o yaml

# ---------- CEL policies ----------
kubectl get validatingadmissionpolicies
kubectl get validatingadmissionpolicybindings
kubectl describe validatingadmissionpolicy NAME

# ---------- Test without persisting ----------
kubectl apply -f obj.yaml --dry-run=server
kubectl create -f obj.yaml --dry-run=server -o yaml   # see mutations applied

# ---------- Break glass ----------
kubectl delete validatingwebhookconfiguration NAME
kubectl delete mutatingwebhookconfiguration NAME

# ---------- Metrics ----------
kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration
kubectl get --raw /metrics | grep apiserver_admission_webhook_rejection_count

# ---------- Pod Security namespace labels ----------
kubectl label ns NS pod-security.kubernetes.io/warn=restricted
kubectl label ns NS pod-security.kubernetes.io/enforce=baseline
kubectl get ns --show-labels | grep pod-security

# ---------- API server logs ----------
sudo crictl logs $(sudo crictl ps --name kube-apiserver -q) 2>&1 | grep -i admission
```

---

## Troubleshooting

### Distinguishing Admission Errors From Authorization Errors

Both return a non-2xx, but the wording differs.

```
# AUTHORIZATION. Names a user, a verb and a resource.
Error from server (Forbidden): pods is forbidden:
User "alice" cannot create resource "pods" in API group "" in the namespace "dev"

# ADMISSION, built-in controller. Names the controller or the policy.
Error from server (Forbidden): pods "web" is forbidden:
violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false

# ADMISSION, webhook. Names the webhook.
Error from server: admission webhook "policy.example.com" denied the request:
container must specify resource limits

# ADMISSION, CEL policy. Names the policy.
Error from server (Forbidden): deployments.apps "web" is forbidden:
ValidatingAdmissionPolicy 'require-memory-limits' with binding
'require-memory-limits-binding' denied request:
containers missing memory limits: app
```

If the message names a webhook or a policy, authorization already passed and the problem is admission.

### Everything Is Timing Out After Adding a Webhook

```
Internal error occurred: failed calling webhook "policy.example.com":
Post "https://policy-svc.policy-system.svc:443/validate?timeout=10s":
context deadline exceeded
```

Work through:

```bash
# 1. Is the service resolvable and are there endpoints?
kubectl -n policy-system get svc,endpoints

# 2. Is the pod actually ready?
kubectl -n policy-system get pods -o wide

# 3. Does the CA bundle in the config match the serving cert?
kubectl get validatingwebhookconfiguration policy \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d | \
  openssl x509 -noout -subject -issuer -dates

# 4. Can the API server reach the pod network at all?
#    On a control plane node, the apiserver must route to pod IPs.
#    A CNI problem shows up here first.
kubectl -n policy-system get endpoints policy-svc -o yaml
```

The CA bundle mismatch is the most frequent cause, especially with cert-manager rotating a certificate without the `caBundle` being re-injected. Check for the `cert-manager.io/inject-ca-from` annotation.

### A Pod Has Fields I Did Not Write

Compare what you submitted against what was stored:

```bash
# Server side dry run shows the object AFTER mutation, before persistence.
kubectl create -f pod.yaml --dry-run=server -o yaml > mutated.yaml
diff <(kubectl create -f pod.yaml --dry-run=client -o yaml) mutated.yaml
```

Anything in the diff came from a mutating controller or webhook. Then find the culprit:

```bash
kubectl get mutatingwebhookconfigurations -o yaml | grep -B 5 -A 20 'rules:'
```

### Deployment Is Healthy But No Pods Appear

Almost always PodSecurity, because `enforce` applies to pods and not to the Deployment.

```bash
# The Deployment looks fine
kubectl get deploy web
# NAME  READY  UP-TO-DATE  AVAILABLE
# web   0/3    3           0

# The truth is on the ReplicaSet
kubectl describe rs -l app=web | tail -20
# Warning  FailedCreate  ...  Error creating: pods "web-abc-" is forbidden:
#   violates PodSecurity "restricted:latest": ...

# Or in events
kubectl get events --field-selector reason=FailedCreate -n NAMESPACE
```

Always look at the ReplicaSet, not the Deployment, when replicas will not appear.

### A Policy Is Not Firing

```bash
# 1. Does a binding exist? A policy alone does nothing.
kubectl get validatingadmissionpolicybindings

# 2. Does validationActions include Deny? Warn and Audit do not reject.
kubectl get validatingadmissionpolicybinding NAME -o jsonpath='{.spec.validationActions}'

# 3. Does matchConstraints actually match your object's group/version/resource?
#    "deployments" is in apiGroup "apps", not "".
kubectl api-resources | grep -i deployment

# 4. Is the ValidatingAdmissionPolicy plugin enabled?
sudo grep enable-admission-plugins /etc/kubernetes/manifests/kube-apiserver.yaml
```

### API Server Will Not Start After an Admission Change

```bash
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -40
sudo journalctl -u kubelet -n 100 --no-pager
```

Usual causes: a plugin name typo (case sensitive), an `--admission-control-config-file` path that is not mounted into the pod, or invalid YAML in the `AdmissionConfiguration`. Fix the manifest and the kubelet restarts the pod automatically.

---

## Exam and Interview Traps

1. **Which runs first, mutating or validating?** All mutating, then object schema validation, then all validating. A validating webhook always sees the final object.

2. **Are mutating webhooks ordered?** No. If your logic depends on another webhook's output, use `reinvocationPolicy: IfNeeded` and make the patch idempotent.

3. **Does `--enable-admission-plugins` replace the defaults?** No, it adds to them. `--disable-admission-plugins` subtracts, and wins on conflict.

4. **Why did my Deployment get created but no pods?** PodSecurity `enforce` evaluates Pods. Controller objects are only evaluated by `warn` and `audit`.

5. **Where did the token volume in my pod come from?** The `ServiceAccount` mutating admission controller. Disable with `automountServiceAccountToken: false`.

6. **Node authorizer versus NodeRestriction?** The authorizer decides which objects a kubelet may touch. NodeRestriction inspects the body and stops a kubelet setting arbitrary labels or taints on its own Node.

7. **My PVC is stuck Pending with no events.** Frequently no default StorageClass, so `DefaultStorageClass` had nothing to inject. Or two defaults exist.

8. **My PVC is stuck Terminating.** `StorageObjectInUseProtection` finalizer. A pod still mounts it. Delete the pod, do not strip the finalizer.

9. **A quota exists and now every pod is rejected for not specifying limits.** A `ResourceQuota` counting a resource makes that resource mandatory. Add a `LimitRange` with defaults.

10. **How do you recover from a webhook that blocks all writes?** Delete the `ValidatingWebhookConfiguration`. Changes to `admissionregistration.k8s.io` resources are deliberately exempt from webhook calls so this escape hatch always works.

11. **`failurePolicy: Fail` versus `Ignore`?** `Fail` rejects the request when the webhook is unreachable, which is fail-closed and can deadlock the cluster. `Ignore` allows it, which is fail-open and can silently skip policy.

12. **Why prefer `ValidatingAdmissionPolicy` over a webhook?** In-process CEL evaluation: no certificates, no deployment, no network hop, cannot be down, and `validationActions` gives you a safe Audit to Warn to Deny rollout.

13. **Does admission run on GET?** No. Admission is only on write operations.

14. **Does enabling PodSecurity restricted evict existing privileged pods?** No. Admission is a gate on writes, never a scanner of existing state. They run until recreated.

15. **What does `--dry-run=server` do differently from `--dry-run=client`?** Server-side runs the full pipeline including admission and discards the result. Client-side never contacts the API server at all.

---

## Related Topics

- [authorization.md](authorization.md) for the gate immediately before this one
- [admission-webhooks.md](admission-webhooks.md) for authoring your own webhooks
- [pod-security-standards.md](pod-security-standards.md) for the PodSecurity controller in depth
- [security-context.md](security-context.md) for the fields those standards check
- [rbac.md](rbac.md) for the permission model admission complements
- [service-accounts.md](service-accounts.md) for what the ServiceAccount controller injects
- [resource-management.md](resource-management.md) for LimitRange and ResourceQuota
- [storage-classes.md](storage-classes.md) for DefaultStorageClass behaviour
- [crds.md](crds.md) and [operators.md](operators.md) for extending the API itself
- [cluster-hardening.md](cluster-hardening.md) for where admission fits in overall posture
- [kube-apiserver.md](kube-apiserver.md) for the component hosting the pipeline

---

## Key Takeaways

- Admission is the last gate before persistence and the only layer that can see and modify the object body.
- The pipeline is strictly two phase: all mutating, then schema validation, then all validating.
- Built-in plugins run in a fixed compile-time order. External webhooks have no guaranteed order among themselves.
- `--enable-admission-plugins` is additive, not a replacement for the default set.
- A great deal of Kubernetes "magic" is mutating admission: the default ServiceAccount, the token volume, the default StorageClass, pod overhead, priority resolution.
- Admission only sees writes. Enabling a policy never affects objects already in etcd.
- PodSecurity `enforce` applies to Pods, not controllers, which is why a Deployment can be admitted while all its pods are rejected. Always pair `enforce` with `warn`.
- `ValidatingAdmissionPolicy` should be your default choice over a webhook: no certs, no deployment, no network hop, and a safe Audit to Warn to Deny rollout path.
- A broadly matching webhook with `failurePolicy: Fail` is the classic way to deadlock a cluster. Always scope with `namespaceSelector` and exclude `kube-system`.
- Deleting the webhook configuration is the break-glass recovery, and it works because webhook configuration changes are exempt from webhook calls.

---

## References

- [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Mutating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/)
- [Common Expression Language in Kubernetes](https://kubernetes.io/docs/reference/using-api/cel/)
- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Using Node Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/)
- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [kube-apiserver Command Line Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
