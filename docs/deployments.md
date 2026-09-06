# 🚀 Kubernetes Deployments: Versioned, Self Healing Workloads

A deep guide to the Deployment controller: the ownership chain it builds, the `pod-template-hash` that gives every revision an identity, how revision history and rollback actually work, and what every status condition is telling you.

## 📋 Table of Contents
- [What a Deployment Adds](#what-a-deployment-adds)
- [The Ownership Chain](#the-ownership-chain)
- [The pod-template-hash Label](#the-pod-template-hash-label)
- [Revisions and Revision History](#revisions-and-revision-history)
- [Anatomy of a Deployment Manifest](#anatomy-of-a-deployment-manifest)
- [Creating Deployments](#creating-deployments)
- [apply vs create vs replace vs edit](#apply-vs-create-vs-replace-vs-edit)
- [last-applied-configuration and Three Way Merge](#last-applied-configuration-and-three-way-merge)
- [Server Side Apply](#server-side-apply)
- [The kubectl rollout Family](#the-kubectl-rollout-family)
- [Change Cause and the record Flag](#change-cause-and-the-record-flag)
- [Deployment Status and Conditions](#deployment-status-and-conditions)
- [progressDeadlineSeconds](#progressdeadlineseconds)
- [minReadySeconds](#minreadyseconds)
- [Paused Deployments](#paused-deployments)
- [Generation and observedGeneration](#generation-and-observedgeneration)
- [The Deployment Controller Reconcile Loop](#the-deployment-controller-reconcile-loop)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What a Deployment Adds

A ReplicaSet keeps N pods alive. It has no idea what version those pods are running and no way to change them safely. A **Deployment** (`apps/v1`, kind `Deployment`, short name `deploy`) adds the version layer.

```
┌───────────────────────────────────────────────────────────────┐
│              What each layer is responsible for               │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  Deployment    "the pod template should be version X,         │
│                 and getting there should not break traffic"   │
│                  • strategy (RollingUpdate / Recreate)        │
│                  • revision history                           │
│                  • rollback                                   │
│                  • pause and resume                           │
│                  • progress deadline                          │
│                                                               │
│  ReplicaSet    "exactly N pods of THIS ONE template"          │
│                  • counting                                   │
│                  • adoption and orphaning                     │
│                  • self healing                               │
│                                                               │
│  Pod           "these containers, on this node"               │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

| Capability | ReplicaSet | Deployment |
|-----------|-----------|-----------|
| Maintain replica count | ✅ | ✅ (delegated) |
| Self heal after pod or node loss | ✅ | ✅ (delegated) |
| Scale | ✅ | ✅ |
| Update the pod template without downtime | ❌ | ✅ |
| Keep old versions around | ❌ | ✅ |
| Roll back to a previous version | ❌ | ✅ |
| Pause mid change and batch several edits | ❌ | ✅ |
| Detect a stuck rollout | ❌ | ✅ (`progressDeadlineSeconds`) |
| `kubectl rollout` subcommands | ❌ | ✅ |

**The central insight:** a Deployment never modifies a pod. It never modifies a ReplicaSet's template either. It creates a *new* ReplicaSet for a new template and then plays a scaling game between the old and the new one.

---

## The Ownership Chain

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│   Deployment/web  (uid A)                                            │
│     spec.replicas: 3                                                 │
│     spec.selector: app=web                                           │
│     spec.template: { image: nginx:1.26 }                             │
│                                                                      │
│         │ deployment-controller creates / scales                     │
│         │ ownerReferences: [{kind: Deployment, uid: A,               │
│         │                    controller: true}]                      │
│         ▼                                                            │
│   ┌────────────────────────────┐   ┌────────────────────────────┐   │
│   │ ReplicaSet/web-59c4d7f8b   │   │ ReplicaSet/web-7d9f8b6c5   │   │
│   │  revision 2  (uid B)       │   │  revision 1  (uid C)       │   │
│   │  spec.replicas: 3          │   │  spec.replicas: 0          │   │
│   │  selector:                 │   │  selector:                 │   │
│   │    app=web                 │   │    app=web                 │   │
│   │    pod-template-hash=      │   │    pod-template-hash=      │   │
│   │      59c4d7f8b             │   │      7d9f8b6c5             │   │
│   │  image: nginx:1.26         │   │  image: nginx:1.25         │   │
│   └────────────────────────────┘   └────────────────────────────┘   │
│         │ replicaset-controller creates              (kept for      │
│         │ ownerReferences: [{kind: ReplicaSet,        rollback)     │
│         │                    uid: B, controller: true}]             │
│         ▼                                                            │
│   Pod/web-59c4d7f8b-x4k2p     Pod/web-59c4d7f8b-q8n1z    ...        │
│     labels: app=web, pod-template-hash=59c4d7f8b                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Walk the chain by hand
kubectl get deploy web -o jsonpath='{.metadata.uid}{"\n"}'
kubectl get rs -l app=web -o custom-columns=\
NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,\
OWNERUID:.metadata.ownerReferences[0].uid,DESIRED:.spec.replicas,\
REV:.metadata.annotations.deployment\\.kubernetes\\.io/revision

kubectl get pods -l app=web -o custom-columns=\
NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,\
HASH:.metadata.labels.pod-template-hash,NODE:.spec.nodeName
```

Deleting the Deployment cascades down the whole chain via the garbage collector, because every link has an `ownerReference` with `controller: true`.

---

## The pod-template-hash Label

The Deployment controller computes a hash of the pod template and injects it in three places.

```
hash = FNV hash of deployment.spec.template  (collision handled by
       status.collisionCount, which is mixed into the hash on retry)

Injected into:
  1. ReplicaSet name:               web-<hash>
  2. ReplicaSet spec.selector:      pod-template-hash: <hash>   (added)
  3. ReplicaSet spec.template.labels: pod-template-hash: <hash> (added)
     ──► therefore every pod carries it too
```

```bash
kubectl get rs web-59c4d7f8b -o jsonpath='{.spec.selector}' | jq
# {
#   "matchLabels": {
#     "app": "web",
#     "pod-template-hash": "59c4d7f8b"
#   }
# }

kubectl get pods -L pod-template-hash
# NAME                   READY   STATUS    AGE   POD-TEMPLATE-HASH
# web-59c4d7f8b-x4k2p    1/1     Running   2m    59c4d7f8b
# web-59c4d7f8b-q8n1z    1/1     Running   2m    59c4d7f8b
```

### Why it must exist

The Deployment's own selector is `app=web`. During a rolling update, both the old and new ReplicaSets have templates whose labels include `app=web`. Without a discriminator:

```
WITHOUT pod-template-hash
  RS-old selector: app=web  ──► sees 6 pods (3 old + 3 new)  ──► deletes 3
  RS-new selector: app=web  ──► sees 6 pods (3 old + 3 new)  ──► deletes 3
  Both ReplicaSets fight over the same pods. Chaos.

WITH pod-template-hash
  RS-old selector: app=web, pod-template-hash=7d9f8b6c5 ──► sees only old
  RS-new selector: app=web, pod-template-hash=59c4d7f8b ──► sees only new
  Disjoint sets. Each ReplicaSet manages only its own generation.
```

### Consequences you must respect

1. **Never put `pod-template-hash` in a Service selector.** It changes on every rollout, so the Service would lose all endpoints. Select on `app`, `tier`, or a stable release label.
2. **Never set `pod-template-hash` yourself** in a pod template. The controller owns it.
3. **The hash is derived from the template**, so reverting the template exactly reproduces the same hash, and the controller will reuse the existing zero scaled ReplicaSet instead of creating a new one. That is precisely what makes `kubectl rollout undo` cheap.
4. **`status.collisionCount`** exists because two different templates can hash to the same value. On a collision the controller increments `collisionCount` and rehashes, producing a distinct name. You will essentially never see it move.

```bash
kubectl get deploy web -o jsonpath='{.status.collisionCount}{"\n"}'
```

---

## Revisions and Revision History

Each ReplicaSet is annotated with its revision number.

```bash
kubectl get rs -l app=web -o custom-columns=\
NAME:.metadata.name,\
REVISION:.metadata.annotations.deployment\\.kubernetes\\.io/revision,\
DESIRED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image

# NAME             REVISION   DESIRED   IMAGE
# web-7d9f8b6c5    1          0         nginx:1.25
# web-59c4d7f8b    2          0         nginx:1.26
# web-6b8d94c7f    3          3         nginx:1.27
```

### The annotations involved

| Annotation | On | Meaning |
|-----------|-----|---------|
| `deployment.kubernetes.io/revision` | ReplicaSet | Monotonically increasing revision number |
| `deployment.kubernetes.io/revision-history` | ReplicaSet | Comma separated list of older revision numbers this ReplicaSet has also served (populated when a ReplicaSet is reused by a rollback) |
| `deployment.kubernetes.io/desired-replicas` | ReplicaSet | The Deployment's `spec.replicas` at the time this ReplicaSet was last updated |
| `deployment.kubernetes.io/max-replicas` | ReplicaSet | `spec.replicas + maxSurge` at that time |
| `kubernetes.io/change-cause` | Deployment and ReplicaSet | Free text reason, shown in `kubectl rollout history` |

```bash
kubectl get rs web-6b8d94c7f -o jsonpath='{.metadata.annotations}' | jq
```

The revision counter is **not** reset by rollback. Rolling back from revision 3 to revision 1 produces a new revision 4 whose ReplicaSet is the same object that served revision 1.

```
rollout history BEFORE undo        AFTER `kubectl rollout undo --to-revision=1`
  REVISION  RS                       REVISION  RS
  1         web-7d9f8b6c5            2         web-59c4d7f8b
  2         web-59c4d7f8b            3         web-6b8d94c7f
  3         web-6b8d94c7f            4         web-7d9f8b6c5   <-- same RS as rev 1
```

### revisionHistoryLimit

```yaml
spec:
  revisionHistoryLimit: 10     # default. Set 0 to disable rollback entirely.
```

The controller keeps at most this many **zero scaled** old ReplicaSets, deleting the oldest first. The active ReplicaSet is never counted against the limit.

```bash
kubectl patch deployment web --type=merge -p '{"spec":{"revisionHistoryLimit":3}}'
kubectl get rs -l app=web
```

| Value | Effect |
|-------|--------|
| `10` (default) | Ten previous revisions retained |
| `0` | No history. `kubectl rollout undo` fails with `no rollout history found`. |
| unset in a patch, or `null` | Falls back to the default of 10 |

Zero scaled ReplicaSets cost no CPU or memory. They cost etcd storage and they lengthen `kubectl get rs` output. A limit of 3 to 5 is a reasonable production default.

---

## Anatomy of a Deployment Manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: production
  labels:
    app: web
    tier: frontend
  annotations:
    kubernetes.io/change-cause: "Upgrade nginx to 1.27 for CVE-2024-XXXX"
spec:
  replicas: 4                    # omit this if an HPA manages the Deployment
  revisionHistoryLimit: 5        # zero scaled old ReplicaSets to retain
  minReadySeconds: 15            # Ready this long before counting Available
  progressDeadlineSeconds: 600   # no progress for this long => Progressing=False
  paused: false                  # true freezes rollouts, scaling still works
  selector:                      # REQUIRED and IMMUTABLE
    matchLabels:
      app: web
  strategy:
    type: RollingUpdate          # or Recreate
    rollingUpdate:
      maxSurge: 1                # absolute number or percentage
      maxUnavailable: 0          # absolute number or percentage
  template:
    metadata:
      labels:
        app: web                 # must satisfy spec.selector
        tier: frontend
      annotations:
        prometheus.io/scrape: "true"
    spec:
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app: web
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 8080
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        envFrom:
        - configMapRef:
            name: web-config
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            memory: 256Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        startupProbe:            # gates liveness and readiness until it passes
          httpGet:
            path: /healthz
            port: http
          failureThreshold: 30
          periodSeconds: 2
        readinessProbe:          # gates traffic AND rollout progress
          httpGet:
            path: /readyz
            port: http
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:           # restarts the container in place
          httpGet:
            path: /healthz
            port: http
          periodSeconds: 10
          failureThreshold: 3
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 5 && nginx -s quit"]
        volumeMounts:
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
      volumes:
      - name: cache
        emptyDir: {}
      - name: run
        emptyDir: {}
```

### Mutability table

| Field | Mutable | Triggers a new revision |
|-------|---------|-------------------------|
| `spec.replicas` | yes | **no** (scaling is not a revision) |
| `spec.selector` | **no** | n/a |
| `spec.template` (any field) | yes | **yes** |
| `spec.strategy` | yes | no |
| `spec.minReadySeconds` | yes | no |
| `spec.progressDeadlineSeconds` | yes | no |
| `spec.revisionHistoryLimit` | yes | no |
| `spec.paused` | yes | no |
| `metadata.annotations` on the Deployment | yes | no |
| `spec.template.metadata.annotations` | yes | **yes**, it is part of the template |

That last row is the mechanism behind `kubectl rollout restart`: it stamps an annotation **inside the template**, which changes the hash, which forces a new ReplicaSet.

---

## Creating Deployments

### Imperatively

```bash
# Minimal
kubectl create deployment web --image=nginx:1.27

# With replicas and a container port
kubectl create deployment web --image=nginx:1.27 --replicas=4 --port=80

# Multiple containers in one pod: repeat --image
kubectl create deployment web --image=nginx:1.27 --image=busybox:1.36

# Override the container command
kubectl create deployment worker --image=busybox:1.36 \
  -- /bin/sh -c 'while true; do echo tick; sleep 5; done'

# Namespace and dry run
kubectl create deployment web --image=nginx:1.27 -n production \
  --dry-run=client -o yaml
```

Flags actually supported by `kubectl create deployment`:

| Flag | Purpose |
|------|---------|
| `--image` | Container image; repeat for multiple containers |
| `--replicas` | Initial replica count |
| `--port` | `containerPort` on the first container |
| `--dry-run=client\|server\|none` | Render without creating, or validate against the API server |
| `-o yaml` / `-o json` | Output format |
| `-n` / `--namespace` | Target namespace |
| `--` | Everything after becomes the container `args` |

> There is no `--env`, no `--limits`, no `--requests` and no `--labels` on `kubectl create deployment`. Generate the YAML and edit it, or use `kubectl set` afterwards. Guessing flags in an exam costs more time than editing the manifest.

### The imperative to declarative bridge

This is the single most valuable CKA and CKAD workflow:

```bash
kubectl create deployment web --image=nginx:1.27 --replicas=4 --port=80 \
  --dry-run=client -o yaml > web.yaml

vi web.yaml          # add resources, probes, securityContext, volumes

kubectl apply -f web.yaml
```

```bash
# Validate against the real API server, including admission webhooks,
# without creating anything
kubectl apply -f web.yaml --dry-run=server

# Show exactly what would change against the live object
kubectl diff -f web.yaml
```

### Declaratively

```bash
kubectl apply -f web.yaml
kubectl apply -f ./manifests/           # a whole directory
kubectl apply -k ./overlays/production/ # kustomize
kubectl apply -f web.yaml -f svc.yaml   # multiple files

kubectl get deploy web
kubectl get deploy web -o wide
kubectl describe deploy web
```

```bash
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    4/4     4            4           2m
```

| Column | Source | Meaning |
|--------|--------|---------|
| `READY` | `status.readyReplicas` / `spec.replicas` | Pods passing readiness over pods wanted |
| `UP-TO-DATE` | `status.updatedReplicas` | Pods running the **current** template |
| `AVAILABLE` | `status.availableReplicas` | Ready for at least `minReadySeconds` |
| `AGE` | `metadata.creationTimestamp` | |

`UP-TO-DATE` lower than `READY` means a rollout is in flight. `READY` lower than the desired count means pods are unhealthy or unscheduled.

### Mutating an existing Deployment with kubectl set

```bash
kubectl set image deployment/web nginx=nginx:1.27-alpine
kubectl set image deployment/web nginx=nginx:1.27 sidecar=fluent-bit:2.2

kubectl set env deployment/web LOG_LEVEL=debug
kubectl set env deployment/web --from=configmap/web-config
kubectl set env deployment/web LOG_LEVEL-          # remove the variable
kubectl set env deployment/web --list              # show without changing

kubectl set resources deployment/web -c=nginx \
  --requests=cpu=200m,memory=256Mi --limits=memory=512Mi

kubectl set serviceaccount deployment/web web-sa

kubectl set selector --help    # note: NOT valid on Deployments, selector is immutable
```

Every one of these edits `spec.template`, so every one triggers a new revision.

```bash
# Same effect, done with a patch
kubectl patch deployment web --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","image":"nginx:1.27"}]}}}}'

kubectl patch deployment web --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:1.27"}]'
```

### Exposing it

```bash
kubectl expose deployment web --port=80 --target-port=8080 --name=web-svc
kubectl expose deployment web --port=80 --type=NodePort
kubectl get svc web-svc -o jsonpath='{.spec.selector}{"\n"}'
# {"app":"web"}    <-- derived from the Deployment's selector, no pod-template-hash
```

---

## apply vs create vs replace vs edit

```
┌──────────────────────────────────────────────────────────────────────┐
│ create   POST. Fails with AlreadyExists if the object is there.     │
│          Does NOT record last-applied-configuration.                 │
│          Use for one shot imperative creation.                       │
│                                                                      │
│ apply    Creates if absent, patches if present. Records              │
│          last-applied-configuration and performs a three way merge.  │
│          Removes fields you deleted from your manifest.              │
│          THE production workflow.                                    │
│                                                                      │
│ replace  PUT. The object must already exist. Wholesale overwrite;    │
│          anything absent from your file is DELETED. Requires a       │
│          resourceVersion for optimistic concurrency unless --force.  │
│          `--force` means delete and recreate: real downtime, new UID.│
│                                                                      │
│ edit     Fetches, opens $EDITOR, then applies your edits as a patch. │
│          Interactive only, unauditable, but fast for triage.         │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
kubectl create -f web.yaml            # error if it exists
kubectl apply  -f web.yaml            # create or update, idempotent
kubectl replace -f web.yaml           # must exist, full overwrite
kubectl replace --force -f web.yaml   # DELETE then CREATE. Downtime. New UID.
kubectl edit deployment web
```

| Behaviour | `create` | `apply` | `replace` | `edit` |
|-----------|----------|---------|-----------|--------|
| Object must not exist | ✅ | n/a | ❌ | ❌ |
| Object must exist | ❌ | n/a | ✅ | ✅ |
| Idempotent | ❌ | ✅ | ✅ | ❌ |
| Records `last-applied-configuration` | ❌ | ✅ | ❌ | ❌ |
| Removes fields you dropped from the file | n/a | ✅ | ✅ | ✅ |
| Preserves fields set by other controllers | n/a | ✅ (if not in last-applied) | ❌ | ✅ |
| Safe in GitOps | ❌ | ✅ | ⚠️ | ❌ |

> ⚠️ The classic disaster: creating with `kubectl create -f` and later switching to `kubectl apply -f`. Because there is no `last-applied-configuration` annotation, the first `apply` cannot tell which fields you previously owned, so it merges rather than removing anything. Fields you deleted from your manifest survive. `kubectl apply` prints a warning about this. Fix it once with `kubectl apply --save-config -f web.yaml`, or migrate to server side apply.

---

## last-applied-configuration and Three Way Merge

`kubectl apply` stores your entire submitted manifest as JSON in an annotation:

```bash
kubectl get deploy web -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | jq
```

### The three inputs

```
┌─────────────────────────┐   ┌─────────────────────────┐   ┌────────────────────┐
│  1. LAST APPLIED        │   │  2. YOUR NEW FILE       │   │  3. LIVE OBJECT    │
│     the annotation      │   │     what you are        │   │     what is in     │
│     what you owned      │   │     applying now        │   │     etcd right now │
│     last time           │   │                         │   │                    │
└───────────┬─────────────┘   └───────────┬─────────────┘   └─────────┬──────────┘
            │                             │                            │
            └─────────────┬───────────────┘                            │
                          ▼                                            │
        in LAST APPLIED but NOT in NEW FILE  ──► DELETE the field      │
        in NEW FILE                          ──► SET the field         │
        in LIVE only, in neither of the      ──► LEAVE IT ALONE ───────┘
        other two                                (another controller
                                                  or a webhook owns it)
```

### Why the third rule matters

```bash
# 1. Deploy without a replicas field, letting an HPA manage the count
kubectl apply -f web-no-replicas.yaml
kubectl autoscale deployment web --min=2 --max=10 --cpu-percent=70
# HPA scales the Deployment to 7

# 2. Re-apply the same manifest. Because replicas is in neither
#    last-applied nor your file, the live value of 7 is preserved.
kubectl apply -f web-no-replicas.yaml
kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'   # 7, untouched

# 3. Now add "replicas: 3" to the manifest and apply.
#    From here on, EVERY apply resets the count to 3 and fights the HPA.
```

### Strategic merge patch and list merge keys

Kubernetes built in types use a **strategic** merge patch, which understands lists.

```yaml
# Patch only the nginx container. The sidecar container is untouched.
spec:
  template:
    spec:
      containers:
      - name: nginx            # "name" is the merge key for containers
        image: nginx:1.27
```

| List | Merge key | Strategy |
|------|-----------|----------|
| `spec.template.spec.containers` | `name` | merge |
| `spec.template.spec.volumes` | `name` | merge |
| `spec.template.spec.containers[].env` | `name` | merge |
| `spec.template.spec.containers[].ports` | `containerPort` | merge |
| `spec.template.spec.tolerations` | none | **replace** the whole list |
| `spec.template.spec.imagePullSecrets` | none | replace |

```bash
# Merge key behaviour, proved
kubectl patch deployment web --type=strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","image":"nginx:1.27"}]}}}}'
kubectl get deploy web -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}'
# nginx sidecar     <-- sidecar survived

# JSON merge patch has NO merge keys: the whole containers list is replaced
kubectl patch deployment web --type=merge -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","image":"nginx:1.27"}]}}}}'
# the sidecar would be removed
```

| Patch type | `--type` | List handling | Use when |
|-----------|----------|---------------|----------|
| Strategic merge | `strategic` (default for built in types) | Uses merge keys | Almost always, for built in types |
| JSON merge (RFC 7386) | `merge` | Whole list replaced | CRDs, or you deliberately want to replace a list |
| JSON patch (RFC 6902) | `json` | Explicit `op` and `path` per operation | Precise index level edits, add or remove single elements |

CRDs use JSON merge semantics by default unless the CRD declares `x-kubernetes-patch-merge-key`.

---

## Server Side Apply

Server side apply moves the merge from `kubectl` into the API server and replaces the annotation with per field ownership tracking.

```bash
kubectl apply --server-side -f web.yaml
kubectl apply --server-side --field-manager=ci-pipeline -f web.yaml

kubectl get deploy web --show-managed-fields -o yaml | sed -n '/managedFields/,/spec:/p'
```

```yaml
metadata:
  managedFields:
  - manager: kubectl
    operation: Apply
    apiVersion: apps/v1
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
        f:template:
          f:spec:
            f:containers:
              k:{"name":"nginx"}:
                f:image: {}
  - manager: kube-controller-manager
    operation: Update
    subresource: status
```

| Aspect | Client side apply | Server side apply |
|--------|-------------------|-------------------|
| Where the merge runs | `kubectl` on your laptop | API server |
| Prior state stored as | `last-applied-configuration` annotation | `metadata.managedFields` |
| Ownership granularity | Whole object | Per field, per manager |
| Conflicting managers | Silent last writer wins | **Conflict error**, resolve with `--force-conflicts` |
| Annotation size limits | Can exceed the 256 KB annotation ceiling on huge objects | Not affected |

```bash
# Two managers own the same field: SSA tells you instead of silently winning
kubectl apply --server-side --field-manager=ci -f web.yaml
# error: Apply failed with 1 conflict: conflict with "kubectl": .spec.replicas
kubectl apply --server-side --field-manager=ci --force-conflicts -f web.yaml
```

Server side apply is the correct answer to "the HPA and my pipeline keep fighting over `replicas`", because the HPA owns that field and your manifest simply does not list it.

---

## The kubectl rollout Family

```bash
kubectl rollout status     deployment/web
kubectl rollout history    deployment/web
kubectl rollout undo       deployment/web
kubectl rollout pause      deployment/web
kubectl rollout resume     deployment/web
kubectl rollout restart    deployment/web
```

| Subcommand | What it does to the object |
|-----------|----------------------------|
| `status` | Watches until `updatedReplicas == replicas` and `availableReplicas == replicas`, or until `Progressing=False` with `ProgressDeadlineExceeded`. Exit code 0 on success, non zero on failure. |
| `history` | Lists revisions from the `deployment.kubernetes.io/revision` annotation on each owned ReplicaSet |
| `history --revision=N` | Prints the full pod template of that revision |
| `undo` | Copies a previous ReplicaSet's template back into `spec.template`, producing a new revision |
| `undo --to-revision=N` | Same, targeting a specific revision. `--to-revision=0` means the previous one. |
| `pause` | Sets `spec.paused: true` |
| `resume` | Sets `spec.paused: false` |
| `restart` | Sets `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]` to the current timestamp |

```bash
# Gate a CI pipeline on the rollout, with a hard timeout
kubectl rollout status deployment/web --timeout=5m || {
  kubectl rollout undo deployment/web
  exit 1
}

# Inspect a specific past revision before rolling back to it
kubectl rollout history deployment/web --revision=2

# Scripted rollback
kubectl rollout undo deployment/web --to-revision=2
kubectl rollout status deployment/web
```

> `kubectl rollout status` on a **paused** Deployment prints that the deployment is paused and does not block. That is intentional; a paused rollout is not a stuck rollout.

Rollout support by workload kind:

| Kind | `rollout status` | `rollout undo` | `rollout restart` |
|------|------------------|----------------|-------------------|
| Deployment | ✅ | ✅ | ✅ |
| DaemonSet | ✅ | ✅ | ✅ |
| StatefulSet | ✅ | ✅ | ✅ |
| ReplicaSet | ❌ | ❌ | ❌ |

---

## Change Cause and the record Flag

`kubectl rollout history` reads the `kubernetes.io/change-cause` annotation.

```bash
kubectl rollout history deployment/web
# REVISION  CHANGE-CAUSE
# 1         <none>
# 2         <none>
# 3         <none>
```

`--record` is **deprecated** and prints a warning. It used to stamp the full command line into the annotation. Set the annotation explicitly instead:

```bash
# Imperative, then annotate
kubectl set image deployment/web nginx=nginx:1.27
kubectl annotate deployment/web \
  kubernetes.io/change-cause="Upgrade nginx to 1.27 for CVE-2024-XXXX" --overwrite

# Declarative: put it in the manifest so it is versioned in git
```

```yaml
metadata:
  name: web
  annotations:
    kubernetes.io/change-cause: "Upgrade nginx to 1.27 for CVE-2024-XXXX"
```

```bash
kubectl rollout history deployment/web
# REVISION  CHANGE-CAUSE
# 1         Initial deployment, nginx 1.25
# 2         Bump to 1.26 for HTTP/3
# 3         Upgrade nginx to 1.27 for CVE-2024-XXXX
```

> The annotation must be on the **Deployment** at the moment the new revision is created. Annotating after the fact updates the Deployment but the ReplicaSet for that revision keeps whatever it was given. In practice: change the annotation in the same `kubectl apply` that changes the template.

---

## Deployment Status and Conditions

```yaml
status:
  observedGeneration: 5
  replicas: 4                # total pods across ALL owned ReplicaSets
  updatedReplicas: 4         # pods from the CURRENT template only
  readyReplicas: 4           # Ready condition True
  availableReplicas: 4       # Ready for at least minReadySeconds
  unavailableReplicas: 0     # desired + maxSurge headroom not yet available
  collisionCount: 0
  conditions:
  - type: Available
    status: "True"
    reason: MinimumReplicasAvailable
    message: Deployment has minimum availability.
    lastTransitionTime: "2025-01-14T09:12:03Z"
  - type: Progressing
    status: "True"
    reason: NewReplicaSetAvailable
    message: ReplicaSet "web-6b8d94c7f" has successfully progressed.
    lastUpdateTime: "2025-01-14T09:12:03Z"
```

### Available

Reports whether at least `spec.replicas - maxUnavailable` pods are available.

| `status` | `reason` | Meaning |
|----------|----------|---------|
| `True` | `MinimumReplicasAvailable` | Enough available pods to serve traffic |
| `False` | `MinimumReplicasUnavailable` | Below the minimum. You are degraded or down. |

### Progressing

Reports whether the Deployment is making forward progress toward the current template. Its `lastUpdateTime` is the clock that `progressDeadlineSeconds` measures against.

| `status` | `reason` | Meaning |
|----------|----------|---------|
| `True` | `NewReplicaSetCreated` | A ReplicaSet was created for the new template |
| `True` | `FoundNewReplicaSet` | An existing ReplicaSet matches the new template, reused |
| `True` | `ReplicaSetUpdated` | The new ReplicaSet was scaled, progress was made |
| `True` | `NewReplicaSetAvailable` | **Rollout complete.** This is the terminal success state. |
| `False` | `ProgressDeadlineExceeded` | No progress for `progressDeadlineSeconds`. Rollout is stuck. |
| `Unknown` | `DeploymentPaused` | `spec.paused` is true |

> `Progressing=True` with reason `NewReplicaSetAvailable` is confusing at first glance: it means finished, not in flight. To detect "a rollout is happening right now", compare `updatedReplicas` to `replicas` instead.

### ReplicaFailure

Mirrors the `ReplicaFailure` condition of the active ReplicaSet. Set when the ReplicaSet controller cannot create pods at all (quota, RBAC, Pod Security, a failing admission webhook).

```bash
kubectl get deploy web -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
# Available=True (MinimumReplicasAvailable)
# Progressing=False (ProgressDeadlineExceeded)

kubectl wait --for=condition=Available deployment/web --timeout=300s

# Every count in one line
kubectl get deploy web -o jsonpath=\
'desired={.spec.replicas} total={.status.replicas} updated={.status.updatedReplicas} ready={.status.readyReplicas} avail={.status.availableReplicas} unavail={.status.unavailableReplicas}{"\n"}'
```

### The four counters, disambiguated

```
During a rolling update of a 4 replica Deployment
(maxSurge=1, maxUnavailable=1), a possible mid rollout snapshot:

  spec.replicas          4    what you asked for
  status.replicas        5    3 old + 2 new, surge in effect
  status.updatedReplicas 2    only the new template counts here
  status.readyReplicas   4    one new pod is still starting
  status.availableReplicas 3  one Ready pod has not cleared minReadySeconds
  status.unavailableReplicas 1
```

---

## progressDeadlineSeconds

```yaml
spec:
  progressDeadlineSeconds: 600     # default
```

A watchdog. If the `Progressing` condition's `lastUpdateTime` does not advance for this many seconds, the controller flips `Progressing` to `False` with reason `ProgressDeadlineExceeded`.

```
t=0     kubectl set image ... nginx:doesnotexist
        new ReplicaSet created, Progressing=True (NewReplicaSetCreated)
t=0..   pods stuck in ImagePullBackOff, no pod ever becomes Ready
        no progress event, lastUpdateTime frozen
t=600   Progressing=False, reason=ProgressDeadlineExceeded
        kubectl rollout status exits non zero
```

**What it does not do:**

- It does **not** roll back. There is no automatic rollback in Kubernetes.
- It does **not** delete the failed pods. They keep retrying forever.
- It does **not** affect the `Available` condition. With `maxUnavailable: 0` or `25%`, the old pods are still serving and `Available` stays `True`.

It is purely a **signal** so that `kubectl rollout status` and your CI pipeline can stop waiting and act.

```bash
# The intended pattern
if ! kubectl rollout status deployment/web --timeout=10m; then
  echo "rollout failed, rolling back"
  kubectl rollout undo deployment/web
  kubectl rollout status deployment/web --timeout=5m
  exit 1
fi
```

> `progressDeadlineSeconds` must be strictly greater than `minReadySeconds`, otherwise a rollout that is behaving perfectly can be declared failed. The API server does not enforce this; you must.

Setting it to a very large value effectively disables the watchdog. There is no documented sentinel value for "never", so just pick a number larger than your slowest legitimate rollout.

---

## minReadySeconds

```yaml
spec:
  minReadySeconds: 15     # default 0
```

The gap between a pod becoming **Ready** and becoming **Available**.

```
Pod passes readinessProbe
       │
       │  ◄── it now receives Service traffic IMMEDIATELY
       │      (Endpoints are driven by Ready, not Available)
       │
       │  minReadySeconds countdown
       │
       ▼
Pod becomes Available
       └──► counts toward status.availableReplicas
       └──► the rolling update is now allowed to proceed to the next pod
```

| Effect | Detail |
|--------|--------|
| Slows rollouts | Each batch waits `minReadySeconds` before the next batch starts |
| Catches early crashers | A container that passes readiness and then dies at second 8 never becomes Available, so the rollout stalls instead of continuing to destroy healthy pods |
| Does not delay traffic | Service endpoints follow the Ready condition. A pod receives requests during the `minReadySeconds` window. |
| Interacts with PDBs | PDB availability is computed from Ready pods, so `minReadySeconds` does not protect you there either |

Typical values: 10 to 30 seconds for a service with a meaningful warm up, 0 for a stateless service with an honest readiness probe. If you find yourself setting 120 seconds, your readiness probe is lying and should be fixed instead.

---

## Paused Deployments

```bash
kubectl rollout pause deployment/web

# Make several template edits. NONE of them start a rollout.
kubectl set image deployment/web nginx=nginx:1.27
kubectl set resources deployment/web -c=nginx --requests=cpu=200m
kubectl set env deployment/web LOG_LEVEL=info

kubectl get rs -l app=web     # still only the old ReplicaSet

kubectl rollout resume deployment/web   # ONE rollout for all three edits
kubectl rollout status deployment/web
```

```yaml
spec:
  paused: true
```

| While paused | Behaviour |
|--------------|-----------|
| Template edits | Accepted and stored, **no new ReplicaSet is created** |
| `spec.replicas` changes | **Still applied.** The active ReplicaSet is scaled normally. |
| Self healing | **Still works.** The ReplicaSet controller is unaffected by `spec.paused`. |
| An in flight rollout | Frozen exactly where it is, with both ReplicaSets at their current counts |
| `Progressing` condition | `Unknown` with reason `DeploymentPaused` |
| `kubectl rollout status` | Reports paused and returns instead of blocking |
| `kubectl rollout undo` | Refuses: `you cannot rollback a paused deployment` |

Two real uses:

1. **Batching.** Avoid three sequential rollouts for three related edits.
2. **Manual canary.** Start a rollout, let a few new pods come up, pause, observe metrics, then resume or undo.

```bash
# Manual canary with pause
kubectl set image deployment/web nginx=nginx:1.27
sleep 20                                  # let a couple of new pods appear
kubectl rollout pause deployment/web
kubectl get pods -L pod-template-hash
# ... watch dashboards ...
kubectl rollout resume deployment/web     # or:
kubectl rollout resume deployment/web && kubectl rollout undo deployment/web
```

> Remember the last row: you must `resume` before you can `undo`. A paused, half rolled out Deployment left overnight is a classic incident.

---

## Generation and observedGeneration

```bash
kubectl get deploy web -o jsonpath='gen={.metadata.generation} observed={.status.observedGeneration}{"\n"}'
```

```
You change spec (template, replicas, strategy, anything under spec)
        │
        ▼
API server increments metadata.generation
        │
        ▼
deployment controller reconciles
        │
        ▼
controller writes status.observedGeneration = that generation
```

| Comparison | What you may conclude |
|-----------|-----------------------|
| `observedGeneration == generation` | The status you are reading reflects your latest spec |
| `observedGeneration < generation` | The controller has not processed your change. **Every other status field is stale.** Do not act on it. |

This is exactly what `kubectl rollout status` checks first, and it is why it briefly prints `Waiting for deployment spec update to be observed...`.

`metadata.generation` is **not** the same as the revision number. Generation increments on any spec change including a scale; the revision increments only when the template hash changes.

```bash
# Prove it
kubectl scale deployment web --replicas=6
kubectl get deploy web -o jsonpath='{.metadata.generation}{"\n"}'   # incremented
kubectl rollout history deployment/web                              # unchanged
```

---

## The Deployment Controller Reconcile Loop

```
syncDeployment(key = "production/web")
 │
 ├─ 1. Get the Deployment from the informer cache
 ├─ 2. List all ReplicaSets in the namespace, claim the ones matching
 │      spec.selector with no controller owner, release the ones that
 │      stopped matching  (same adoption logic as ReplicaSet -> Pod)
 ├─ 3. If spec.paused:
 │        sync only the status and the scale of existing ReplicaSets,
 │        then return. Do NOT create a new ReplicaSet.
 ├─ 4. If a rollback was requested (deprecated inline field path):
 │        handled today by kubectl writing the old template into
 │        spec.template, so from the controller's view this is an
 │        ordinary template change.
 ├─ 5. Compute hash(spec.template)
 │        found an owned ReplicaSet with that hash?
 │          yes ──► that is the NEW ReplicaSet. Reuse it. Bump its
 │                  revision annotation to max(existing)+1 and record
 │                  the old revision in revision-history.
 │          no  ──► CREATE ReplicaSet "<deploy>-<hash>" with the
 │                  pod-template-hash injected into its selector and
 │                  template labels, revision = max(existing)+1
 ├─ 6. Every other owned ReplicaSet is an OLD ReplicaSet
 ├─ 7. Apply the strategy:
 │        Recreate      ──► scale ALL old ReplicaSets to 0, wait for
 │                          every old pod to be fully terminated,
 │                          then scale the new one to spec.replicas
 │        RollingUpdate ──► scale up the new RS within the maxSurge
 │                          budget; scale down old RSes within the
 │                          maxUnavailable budget; repeat each sync
 ├─ 8. Clean up old ReplicaSets beyond revisionHistoryLimit
 │      (only zero scaled ones are eligible)
 └─ 9. Recompute status: replicas, updatedReplicas, readyReplicas,
       availableReplicas, unavailableReplicas, conditions,
       observedGeneration. Write via the /status subresource.
```

Three properties fall out of this:

1. **The controller never creates or deletes a Pod.** It only writes ReplicaSets. All pod churn is the ReplicaSet controller reacting.
2. **Each sync makes only as much progress as the budgets allow**, then returns. It does not loop internally waiting for pods. The next pod status change re-enqueues the Deployment key.
3. **Step 5 is why rollback is cheap.** Reverting the template reproduces the old hash, the old zero scaled ReplicaSet is found and reused, and the pods it creates are identical to the originals.

```bash
# Watch the controller's decisions in real time
kubectl get rs -l app=web -w &
kubectl set image deployment/web nginx=nginx:1.27
kubectl describe deployment web | sed -n '/Events:/,$p'
# Normal  ScalingReplicaSet  deployment-controller  Scaled up   replica set web-6b8d94c7f to 1
# Normal  ScalingReplicaSet  deployment-controller  Scaled down replica set web-59c4d7f8b to 3
# Normal  ScalingReplicaSet  deployment-controller  Scaled up   replica set web-6b8d94c7f to 2
# ...
```

Every `ScalingReplicaSet` event is one budget step of one reconcile pass.

---

## Troubleshooting

### READY 0/4 and the pods do not exist

```bash
kubectl get deploy web
kubectl get rs -l app=web
kubectl get deploy web -o jsonpath='{.status.conditions[?(@.type=="ReplicaFailure")]}' | jq
kubectl describe rs $(kubectl get rs -l app=web -o name | tail -1) | sed -n '/Events:/,$p'
```

`ReplicaFailure` means pod creation is being rejected before a pod object exists. Causes: ResourceQuota, RBAC on the `replicaset-controller` ServiceAccount, Pod Security admission on the namespace, or a failing admission webhook.

### Rollout hangs forever

```bash
kubectl rollout status deployment/web --timeout=60s
kubectl get pods -l app=web -o wide
kubectl describe pod <newest-pod> | sed -n '/Events:/,$p'
kubectl get deploy web -o jsonpath='{.status.conditions}' | jq
```

| Pod state | Root cause | Fix |
|-----------|-----------|-----|
| `ImagePullBackOff` | Wrong tag, private registry, missing `imagePullSecrets` | Fix the image reference or add the pull secret |
| `CrashLoopBackOff` | The app exits on start | `kubectl logs <pod> --previous` |
| `Pending`, `FailedScheduling` | No node fits: resources, taints, affinity, topology spread | `kubectl describe pod` for the exact scheduler message |
| `Running` but `0/1` | Readiness probe failing | Check probe path, port, scheme and `initialDelaySeconds` |
| `ContainerCreating` | Volume, CNI or secret mount | `kubectl describe pod`, then `journalctl -u kubelet` on that node |
| Nothing new appears at all | `spec.paused: true`, or `maxSurge: 0` with `maxUnavailable: 0` | `kubectl rollout resume`, or fix the strategy |

```bash
# maxSurge: 0 AND maxUnavailable: 0 is a permanently deadlocked rollout.
# The API server rejects it at admission, but a manual patch that sets them
# in two separate steps can transiently produce it. Verify:
kubectl get deploy web -o jsonpath='{.spec.strategy.rollingUpdate}{"\n"}'
```

### Rollout succeeded but the app is broken

```bash
kubectl rollout undo deployment/web
kubectl rollout status deployment/web
```

Then find out why your readiness probe reported healthy on a broken build. That is the real defect; the rollback is just first aid.

### rollout undo says "no rollout history found"

```bash
kubectl get deploy web -o jsonpath='{.spec.revisionHistoryLimit}{"\n"}'
kubectl get rs -l app=web
```

Either `revisionHistoryLimit: 0`, or the old ReplicaSets were deleted manually, or this is the very first revision. Recover by applying the previous manifest from git.

### Every apply resets replicas and fights the HPA

```bash
kubectl get hpa
kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
```

Remove `replicas` from the manifest entirely and re-apply, or move to server side apply so the HPA owns the field. See [Deployment Strategies](deployment-strategies.md#scaling).

### A field I removed from my YAML is still on the object

```bash
kubectl get deploy web -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | head -c 100
```

Empty means the object was created with `create` or `edit`, so `apply` has no baseline for deletions.

```bash
kubectl apply --save-config -f web.yaml     # seed the annotation once
# or migrate to field ownership
kubectl apply --server-side --force-conflicts -f web.yaml
```

### Two Deployments fighting over the same pods

```bash
kubectl get deploy -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,SELECTOR:.spec.selector.matchLabels
```

Overlapping selectors in the same namespace cause both Deployments to claim the same ReplicaSets and thrash. Selectors are immutable, so you must delete and recreate one of them with a distinct selector.

### Old ReplicaSets piling up

```bash
kubectl get rs -l app=web
kubectl patch deployment web --type=merge -p '{"spec":{"revisionHistoryLimit":3}}'
```

### Everything looks fine but the change did not take effect

```bash
kubectl get deploy web -o jsonpath='gen={.metadata.generation} obs={.status.observedGeneration}{"\n"}'
kubectl diff -f web.yaml
```

If `gen == obs` and `kubectl diff` is empty, the live object already matches your file, and your change is somewhere else: a ConfigMap the pods read at startup, an image tag that was overwritten, or a mutating webhook rewriting your spec.

```bash
# Did a webhook rewrite my spec?
kubectl get mutatingwebhookconfigurations
kubectl get deploy web -o yaml | diff - <(kubectl apply -f web.yaml --dry-run=server -o yaml)
```

---

## Exam and Interview Traps

1. **A Deployment never touches a Pod.** It writes ReplicaSets. The ReplicaSet controller writes Pods. Saying "the Deployment creates the pods" is the classic wrong answer.
2. **Updating the template creates a new ReplicaSet; it does not edit the existing one.** The old one is scaled to zero and retained as a revision.
3. **`pod-template-hash` is injected into the ReplicaSet name, its selector and its template labels.** Never put it in a Service selector and never set it yourself.
4. **Scaling is not a revision.** `kubectl scale` bumps `metadata.generation` but produces no new entry in `kubectl rollout history`.
5. **`spec.selector` is immutable.** To change it you delete and recreate the Deployment.
6. **`kubectl rollout undo` does not restore the old ReplicaSet as the current revision number.** It creates a *new*, higher revision that happens to reuse the old ReplicaSet object.
7. **`revisionHistoryLimit: 0` silently disables rollback.**
8. **`--record` is deprecated.** Use the `kubernetes.io/change-cause` annotation, and set it in the same apply that changes the template.
9. **There is no automatic rollback.** `progressDeadlineSeconds` only sets a condition; your pipeline must call `kubectl rollout undo`.
10. **`progressDeadlineSeconds` must exceed `minReadySeconds`**, and nothing enforces that for you.
11. **`Progressing=True` with reason `NewReplicaSetAvailable` means finished, not in progress.** To detect an in flight rollout compare `updatedReplicas` with `replicas`.
12. **`readyReplicas` drives Service endpoints; `availableReplicas` drives rollout progress.** `minReadySeconds` delays availability, not traffic.
13. **`kubectl create` does not write `last-applied-configuration`**, so a later `apply` cannot delete fields you removed from your manifest.
14. **`kubectl replace --force` deletes and recreates the object.** New UID, real downtime, all history gone. It is not a stronger `apply`.
15. **Strategic merge uses `name` as the merge key for containers; JSON merge patch replaces the whole list.** Choosing `--type=merge` when you meant `--type=strategic` silently deletes your sidecar.
16. **`tolerations` and `imagePullSecrets` have no merge key**, so patching them replaces the entire list.
17. **A paused Deployment still scales and still self heals.** Only rollouts are frozen.
18. **You cannot `rollout undo` a paused Deployment.** Resume first.
19. **`kubectl rollout status` on a paused Deployment returns immediately** rather than blocking.
20. **`metadata.generation` is not the revision number.** Generation tracks spec changes; revision tracks template changes.
21. **`kubectl set image` targets the container by name, not by index.** `kubectl set image deployment/web nginx=...` fails silently in the sense of doing nothing useful if no container is named `nginx`.
22. **`kubectl create deployment` has no `--env`, `--limits` or `--requests` flags.** Generate YAML with `--dry-run=client -o yaml` and edit it.
23. **`kubectl expose deployment` builds the Service selector from the Deployment's selector**, which is exactly why that selector must not contain `pod-template-hash`.
24. **Deleting a Deployment with `--cascade=orphan` leaves the ReplicaSets and pods running** and unmanaged.

---

## Related Topics

- [Controllers](controllers.md)
- [ReplicaSets](replicasets.md)
- [Deployment Strategies](deployment-strategies.md)
- [Pods](pods.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kube-apiserver](kube-apiserver.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [Imperative Kubernetes](imperative-kubernetes.md)
- [kube-scheduler](kube-scheduler.md)
- [kubelet](kubelet.md)
- [Kubernetes Architecture](k8s-architecture.md)
- [Microservices](microservices.md)

---

## Key Takeaways

1. A Deployment adds versioning, rollout strategy, revision history, rollback, pause and a progress watchdog on top of the ReplicaSet's pure replica counting.
2. The ownership chain is Deployment, ReplicaSet, Pod, linked by `ownerReferences` with `controller: true`, which is what makes cascading deletion work.
3. The Deployment controller writes only ReplicaSets. Every pod create and delete you observe is the ReplicaSet controller reacting.
4. `pod-template-hash` is computed from the pod template and injected into the ReplicaSet name, selector and template labels, which is the only thing that stops old and new ReplicaSets from fighting over the same pods.
5. Because the hash is derived from the template, reverting the template reproduces the old hash and the old zero scaled ReplicaSet is reused. That is why rollback is fast and exact.
6. Each ReplicaSet carries `deployment.kubernetes.io/revision`; `revisionHistoryLimit` (default 10) caps how many zero scaled ones are retained, and `0` disables rollback.
7. Changing anything under `spec.template` creates a new revision. Changing `spec.replicas`, `strategy`, `minReadySeconds` or `paused` does not.
8. `kubectl rollout restart` works by stamping `kubectl.kubernetes.io/restartedAt` into the template annotations, which changes the hash.
9. `kubectl apply` performs a three way merge across the `last-applied-configuration` annotation, your file, and the live object, which is how it can delete fields you removed while preserving fields owned by other controllers.
10. Objects created with `create`, `edit` or `replace` have no `last-applied-configuration`, so the first `apply` on them cannot remove anything. Seed it with `--save-config` or move to server side apply.
11. Server side apply replaces the annotation with per field `managedFields` ownership and turns silent overwrites into explicit conflicts.
12. `Available` reports whether enough pods are serving; `Progressing` reports forward motion, and its terminal success reason is `NewReplicaSetAvailable`.
13. `progressDeadlineSeconds` (default 600) only flips a condition so `kubectl rollout status` can fail. It never rolls back and never deletes pods.
14. `minReadySeconds` delays Available, not Ready, so it slows the rollout without delaying traffic to the pod.
15. A paused Deployment freezes rollouts but still scales and still self heals, and you must resume before you can undo.
16. `metadata.generation` versus `status.observedGeneration` is the only reliable staleness check; generation is not the revision number.
17. `kubectl replace --force` deletes and recreates the object, producing a new UID and real downtime, and is never an equivalent of `apply`.

---

## References

- [Deployments Concept](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [Deployment API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/deployment-v1/)
- [ReplicaSet Concept](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/)
- [Kubernetes Object Management](https://kubernetes.io/docs/concepts/overview/working-with-objects/object-management/)
- [Declarative Management of Kubernetes Objects Using Configuration Files](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/)
- [Server Side Apply](https://kubernetes.io/docs/reference/using-api/server-side-apply/)
- [Update API Objects in Place Using kubectl patch](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/)
- [Owners and Dependents](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)
- [Labels and Selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/)
- [kubectl rollout Reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#rollout)
- [kubectl create deployment Reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-deployment-em-)
- [Pod Lifecycle and Probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
