# 🛡️ Kubernetes RBAC: Deciding What You May Do

A complete guide to Role Based Access Control: the authorizer chain, the four RBAC objects and their scoping rules, rule anatomy down to subresources and verbs, aggregation, privilege escalation prevention, testing with `kubectl auth can-i`, and a set of production ready recipes.

## 📋 Table of Contents
- [Where Authorization Sits](#where-authorization-sits)
- [Authorization Modes](#authorization-modes)
- [How the Authorizer Chain Decides](#how-the-authorizer-chain-decides)
- [The Four RBAC Objects](#the-four-rbac-objects)
- [The Scoping Matrix](#the-scoping-matrix)
- [Role: Annotated Manifest](#role-annotated-manifest)
- [ClusterRole: Annotated Manifest](#clusterrole-annotated-manifest)
- [RoleBinding: Annotated Manifest](#rolebinding-annotated-manifest)
- [ClusterRoleBinding: Annotated Manifest](#clusterrolebinding-annotated-manifest)
- [Rule Anatomy](#rule-anatomy)
- [apiGroups](#apigroups)
- [Resources and Subresources](#resources-and-subresources)
- [Verbs](#verbs)
- [resourceNames](#resourcenames)
- [nonResourceURLs](#nonresourceurls)
- [Wildcards and Why They Are Dangerous](#wildcards-and-why-they-are-dangerous)
- [Aggregated ClusterRoles](#aggregated-clusterroles)
- [Default ClusterRoles](#default-clusterroles)
- [The system:masters Bypass](#the-systemmasters-bypass)
- [Privilege Escalation Prevention](#privilege-escalation-prevention)
- [Subjects](#subjects)
- [Testing and Auditing Access](#testing-and-auditing-access)
- [Recipe: Read Only Namespace Viewer](#recipe-read-only-namespace-viewer)
- [Recipe: Developer With Deploy Rights](#recipe-developer-with-deploy-rights)
- [Recipe: CI/CD Service Account Scoped to One Namespace](#recipe-cicd-service-account-scoped-to-one-namespace)
- [Recipe: Operator Service Account for a CRD](#recipe-operator-service-account-for-a-crd)
- [Recipe: Break Glass Role](#recipe-break-glass-role)
- [Least Privilege Methodology](#least-privilege-methodology)
- [Common RBAC Mistakes](#common-rbac-mistakes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Where Authorization Sits

Authentication answered "who are you". Authorization answers "may you do this". By the time RBAC runs, the API server holds a `user.Info` structure and nothing else about your credential: a username, a UID, a list of groups, and some extra fields. It has forgotten whether you presented a certificate, an OIDC token or a service account token.

```
   TLS  ──►  AUTHENTICATION  ──►  AUTHORIZATION  ──►  ADMISSION  ──►  etcd
              401 on failure       403 on failure       400/403/422
                    │                     │
                    │                     └── this document
                    └── authentication.md
```

RBAC evaluates a **request attribute set**, not your YAML. Every incoming request is reduced to these attributes before any rule is examined:

```
┌──────────────────────────────────────────────────────────────────────┐
│                     REQUEST ATTRIBUTES                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  kubectl -n dev logs mypod-abc123                                     │
│      becomes                                                          │
│      GET /api/v1/namespaces/dev/pods/mypod-abc123/log                 │
│      which becomes                                                    │
│                                                                       │
│    user             alice                                             │
│    groups           [developers, system:authenticated]                │
│    verb             get                                               │
│    apiGroup         ""            (core)                              │
│    resource         pods                                              │
│    subresource      log                                               │
│    namespace        dev                                               │
│    name             mypod-abc123                                      │
│    resourceRequest  true                                              │
│                                                                       │
│  For a NON resource request such as GET /healthz:                     │
│    verb             get                                               │
│    path             /healthz                                          │
│    resourceRequest  false                                             │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

The single most useful habit in RBAC debugging is to translate the failing command into these attributes first. Almost every "my role does not work" turns out to be a subresource, an apiGroup, or a namespace that was not what the author assumed.

```bash
# Let kubectl show you the exact request it makes
kubectl -n dev logs mypod-abc123 -v=8 2>&1 | grep -E '^I.*(GET|POST|PATCH|DELETE)'
```

> 📖 **See Also**: [authentication.md](authentication.md) for the stage before this one, and [kube-apiserver.md](kube-apiserver.md) for the pipeline as a whole.

---

## Authorization Modes

The API server runs a chain of authorizers, configured in order:

```yaml
    # /etc/kubernetes/manifests/kube-apiserver.yaml
    - --authorization-mode=Node,RBAC
```

| Mode | What it does | Can return an explicit deny |
|------|--------------|------------------------------|
| **Node** | Grants each kubelet access only to the objects related to pods scheduled on *its own* node: those Secrets, ConfigMaps, PVCs, PVs and the Node object itself | No |
| **RBAC** | Evaluates Roles, ClusterRoles and their bindings against the request attributes | No |
| **ABAC** | Attribute Based Access Control from a static policy file on disk (`--authorization-policy-file`). Legacy: changing it requires an API server restart | Yes |
| **Webhook** | Delegates the decision to an external HTTPS service via a `SubjectAccessReview` | Yes |
| **AlwaysAllow** | Allows every request unconditionally | No |
| **AlwaysDeny** | Denies every request unconditionally | It denies everything |

```
┌──────────────────────────────────────────────────────────────────────┐
│                   TYPICAL PRODUCTION ORDER                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   --authorization-mode=Node,RBAC                                      │
│                        │    │                                         │
│                        │    └─ everything else: humans, service       │
│                        │       accounts, controllers                  │
│                        │                                              │
│                        └─ kubelets first, because the Node authorizer │
│                           is cheaper and more precise for them than   │
│                           any RBAC rule could be                      │
│                                                                       │
│   Cloud managed clusters commonly add Webhook for their own IAM:      │
│   --authorization-mode=Node,RBAC,Webhook                              │
│                                                                       │
│   ⚠️  --authorization-mode=AlwaysAllow disables ALL authorization.    │
│      Every authenticated request, including anonymous ones if         │
│      anonymous auth is on, becomes cluster admin. Never in            │
│      production, and check for it during any cluster audit.           │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# What is actually configured
sudo grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml

# On a cluster you can only reach through the API
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' |
  tr ',' '\n' | grep authorization
```

---

## How the Authorizer Chain Decides

Every authorizer returns one of three answers: **Allow**, **Deny**, or **NoOpinion**.

```
┌──────────────────────────────────────────────────────────────────────┐
│                    CHAIN EVALUATION                                   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   request attributes                                                  │
│          │                                                            │
│          ▼                                                            │
│    ┌───────────┐   Allow ──────────────────────────────► ALLOWED      │
│    │   Node    │   Deny  ──────────────────────────────► DENIED       │
│    └─────┬─────┘   NoOpinion                                          │
│          │  (the identity is not system:node:<name>,                  │
│          │   or the resource is not node related)                     │
│          ▼                                                            │
│    ┌───────────┐   Allow ──────────────────────────────► ALLOWED      │
│    │   RBAC    │   NoOpinion                                          │
│    └─────┬─────┘   (RBAC NEVER returns Deny)                          │
│          │                                                            │
│          ▼                                                            │
│    ┌───────────┐   Allow ──────────────────────────────► ALLOWED      │
│    │  Webhook  │   Deny  ──────────────────────────────► DENIED       │
│    └─────┬─────┘   NoOpinion                                          │
│          │                                                            │
│          ▼                                                            │
│   No authorizer had an opinion  ─────────────────────────► DENIED     │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

Three rules follow, and the first is the one that matters most day to day:

1. **RBAC is purely additive.** There is no `deny` rule in RBAC. You cannot write a Role that says "everything except Secrets". You can only add permissions, so the way to remove access is to remove or narrow a binding, never to add a counter rule.
2. **The first definite answer wins.** An Allow from any authorizer ends the evaluation immediately; so does an explicit Deny from an authorizer capable of issuing one (ABAC and Webhook).
3. **Default deny.** If every authorizer returns NoOpinion, the request is refused with 403. A user with no bindings at all is authenticated and completely powerless, which is the correct starting point for everyone.

```
┌──────────────────────────────────────────────────────────────────┐
│  THE UNION RULE, STATED PRECISELY                                 │
├──────────────────────────────────────────────────────────────────┤
│  • RBAC and Node never say "no". They say "yes" or "not my       │
│    business".                                                     │
│  • Because of that, in a Node,RBAC cluster (the overwhelming      │
│    majority), a request is denied ONLY when every authorizer      │
│    declined. There is no such thing as an RBAC deny rule.         │
│  • Adding a second RoleBinding can only ever GRANT more. It can   │
│    never take anything away.                                      │
│  • The effective permission set of a user is the UNION of every   │
│    rule in every Role and ClusterRole reachable from every        │
│    binding that names the user, any of their groups, or (for a    │
│    service account) the service account itself.                   │
└──────────────────────────────────────────────────────────────────┘
```

---

## The Four RBAC Objects

```
┌──────────────────────────────────────────────────────────────────────┐
│                       THE FOUR OBJECTS                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   WHAT can be done          WHO can do it                             │
│   ┌──────────────────┐      ┌──────────────────────┐                  │
│   │      Role        │◄─────│     RoleBinding      │  namespaced      │
│   │  (namespaced)    │      │    (namespaced)      │                  │
│   └──────────────────┘      └──────────────────────┘                  │
│                                        │                              │
│                                        │ may also reference           │
│                                        │ a ClusterRole                │
│                                        ▼                              │
│   ┌──────────────────┐      ┌──────────────────────┐                  │
│   │   ClusterRole    │◄─────│  ClusterRoleBinding  │  cluster scoped  │
│   │ (cluster scoped) │      │  (cluster scoped)    │                  │
│   └──────────────────┘      └──────────────────────┘                  │
│                                                                       │
│   ROLES hold rules and grant NOTHING on their own.                    │
│   BINDINGS connect subjects to exactly ONE role via roleRef.          │
│                                                                       │
│   All four are in the API group rbac.authorization.k8s.io/v1.         │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
kubectl api-resources --api-group=rbac.authorization.k8s.io
```

```
NAME                  SHORTNAMES  APIVERSION                      NAMESPACED  KIND
clusterrolebindings               rbac.authorization.k8s.io/v1    false       ClusterRoleBinding
clusterroles                      rbac.authorization.k8s.io/v1    false       ClusterRole
rolebindings                      rbac.authorization.k8s.io/v1    true        RoleBinding
roles                             rbac.authorization.k8s.io/v1    true        Role
```

A Role by itself is inert. Creating a Role that grants `delete` on everything is harmless until a binding points at it. Conversely, deleting a binding instantly removes the access it granted, with no restart and no cache to wait for.

---

## The Scoping Matrix

This table is the heart of RBAC, and the third row is the one that appears in every exam.

| Binding | Role reference | Where the permission applies | Typical use |
|---------|---------------|------------------------------|-------------|
| **RoleBinding** in namespace `dev` | **Role** in namespace `dev` | Namespaced resources in `dev` only | The normal case: a team's permissions inside their namespace |
| **RoleBinding** in namespace `dev` | **ClusterRole** | Namespaced resources in `dev` **only**, even though the role is cluster scoped | Reuse one shared role definition across many namespaces |
| **ClusterRoleBinding** | **ClusterRole** | Every namespace, plus cluster scoped resources, plus non resource URLs | Cluster administrators, controllers, node level access |
| **ClusterRoleBinding** | **Role** | ❌ **Invalid.** The API server rejects it | n/a |
| **RoleBinding** in namespace `dev` | **Role** in namespace `prod` | ❌ **Invalid.** A RoleBinding can only reference a Role in its own namespace | n/a |

```
┌──────────────────────────────────────────────────────────────────────┐
│         THE CASE EVERYONE GETS WRONG                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   ClusterRole "pod-reader"          RoleBinding in namespace "dev"    │
│   ┌───────────────────────┐         ┌────────────────────────────┐    │
│   │ get,list,watch pods   │◄────────│ roleRef: ClusterRole        │    │
│   │ (cluster scoped       │         │          pod-reader         │    │
│   │  definition)          │         │ subject: User alice         │    │
│   └───────────────────────┘         └────────────────────────────┘    │
│                                                                       │
│   RESULT: alice can read pods IN NAMESPACE dev ONLY.                  │
│                                                                       │
│   The scope comes from the BINDING, not from the role. Referencing    │
│   a ClusterRole from a RoleBinding does NOT grant cluster wide        │
│   access; it narrows the ClusterRole to that one namespace.           │
│                                                                       │
│   WHY THIS IS THE RIGHT PATTERN                                       │
│     Define "what a developer may do" once, as a ClusterRole.          │
│     Bind it in dev, test and staging with three RoleBindings.         │
│     Change the ClusterRole once and all three namespaces follow.      │
│     Without this you would maintain three identical Role objects.     │
│                                                                       │
│   IMPORTANT EXCEPTION                                                 │
│     A RoleBinding to a ClusterRole grants only the NAMESPACED         │
│     resources in it. Rules covering cluster scoped resources          │
│     (nodes, persistentvolumes, namespaces, clusterroles) and          │
│     nonResourceURLs are simply IGNORED, silently. No error, no        │
│     warning, no access.                                               │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

The mirror image is worth stating too: a **ClusterRoleBinding** to a ClusterRole that contains only namespaced rules grants those rules in **every namespace, including ones created later**. That is exactly why `ClusterRoleBinding` deserves a second look in every review.

---

## Role: Annotated Manifest

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-and-config-reader
  # A Role ALWAYS belongs to a namespace, and can only ever be
  # referenced by a RoleBinding in this same namespace.
  namespace: dev

rules:
# Rule 1: read pods and their logs.
- apiGroups: [""]                       # "" is the CORE group, not "all"
  resources: ["pods", "pods/log"]       # subresources are separate entries
  verbs: ["get", "list", "watch"]

# Rule 2: read configuration, but note what is NOT here: secrets.
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]

# Rule 3: read Deployments and ReplicaSets, which live in apps/v1.
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "watch"]

# Rule 4: one specific ConfigMap only, by name.
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-settings"]
  verbs: ["update", "patch"]

# RULES ARE A UNION. A request is allowed if ANY rule matches all of
# its attributes. Within a SINGLE rule, every field must match:
#   apiGroup ∈ apiGroups AND resource ∈ resources AND verb ∈ verbs
#   AND (resourceNames empty OR name ∈ resourceNames)
```

Verify what the API server actually stored, which is the fastest way to catch a typo in `apiGroups`:

```bash
kubectl -n dev describe role pod-and-config-reader
```

```
Name:         pod-and-config-reader
Namespace:    dev
PolicyRule:
  Resources        Non-Resource URLs  Resource Names   Verbs
  ---------        -----------------  --------------   -----
  configmaps       []                 []               [get list watch]
  configmaps       []                 [app-settings]   [update patch]
  pods/log         []                 []               [get list watch]
  pods             []                 []               [get list watch]
  daemonsets.apps  []                 []               [get list watch]
  deployments.apps []                 []               [get list watch]
  replicasets.apps []                 []               [get list watch]
  statefulsets.apps[]                 []               [get list watch]
```

---

## ClusterRole: Annotated Manifest

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: platform-operator
  # NO namespace field. A ClusterRole is cluster scoped.

rules:
# Namespaced resources. These apply cluster wide when bound with a
# ClusterRoleBinding, or in ONE namespace when bound with a RoleBinding.
- apiGroups: [""]
  resources: ["pods", "services", "configmaps"]
  verbs: ["get", "list", "watch"]

# CLUSTER SCOPED resources. These are ONLY effective through a
# ClusterRoleBinding. A RoleBinding referencing this role ignores them.
- apiGroups: [""]
  resources: ["nodes", "persistentvolumes", "namespaces"]
  verbs: ["get", "list", "watch"]

# Subresource on a cluster scoped resource: the kubelet API proxy.
- apiGroups: [""]
  resources: ["nodes/proxy", "nodes/metrics", "nodes/stats"]
  verbs: ["get"]

# Storage, a non core group.
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses", "volumeattachments"]
  verbs: ["get", "list", "watch"]

# NON RESOURCE URLs. Only valid in a ClusterRole, and only effective
# through a ClusterRoleBinding. The verbs here are HTTP methods,
# lowercased, not Kubernetes verbs.
- nonResourceURLs: ["/healthz", "/livez", "/readyz", "/version", "/metrics"]
  verbs: ["get"]
```

---

## RoleBinding: Annotated Manifest

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-team-access
  namespace: dev            # the namespace where the permissions apply

# WHO. A list; a single binding can name many subjects of mixed kinds.
subjects:

# A human, identified by the string an authenticator produced.
# For a client certificate this is the CN; for OIDC it is the mapped claim.
- kind: User
  name: alice                                  # case sensitive, exact match
  apiGroup: rbac.authorization.k8s.io          # required for User

# A group. Also just a string; there is no Group object.
- kind: Group
  name: developers
  apiGroup: rbac.authorization.k8s.io          # required for Group

# A service account. NOTE the differences from the two above.
- kind: ServiceAccount
  name: build-bot
  namespace: dev            # REQUIRED, and may be a DIFFERENT namespace
  # apiGroup is "" (core) for ServiceAccount, so it is OMITTED here.
  # Writing apiGroup: rbac.authorization.k8s.io is a validation error.

# WHAT. Exactly one role, and this field is IMMUTABLE after creation.
roleRef:
  kind: Role                                   # Role or ClusterRole
  name: pod-and-config-reader
  apiGroup: rbac.authorization.k8s.io
```

```
┌──────────────────────────────────────────────────────────────────┐
│  roleRef IS IMMUTABLE                                             │
├──────────────────────────────────────────────────────────────────┤
│  kubectl edit rolebinding dev-team-access                         │
│  → "cannot change roleRef"                                        │
│                                                                   │
│  This is deliberate: it prevents someone with `update` on         │
│  bindings from silently repointing a harmless binding at          │
│  cluster-admin.                                                   │
│                                                                   │
│  To change the role: DELETE the binding and CREATE a new one.     │
│    kubectl -n dev delete rolebinding dev-team-access              │
│    kubectl apply -f new-binding.yaml                              │
│                                                                   │
│  `subjects` IS mutable, so adding and removing people is a normal │
│  edit, and is the reason to bind Groups rather than Users.        │
│                                                                   │
│  ⚠️  `kubectl apply` on a binding whose roleRef changed FAILS.    │
│      Automation that regenerates RBAC must handle this, or use    │
│      `kubectl auth reconcile`, or delete first.                   │
└──────────────────────────────────────────────────────────────────┘
```

### The Same Binding, Referencing a ClusterRole

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-viewers
  namespace: dev
subjects:
- kind: Group
  name: qa-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole      # the built-in `view` role
  name: view
  apiGroup: rbac.authorization.k8s.io
# RESULT: qa-team gets the `view` permissions, in namespace dev ONLY.
```

---

## ClusterRoleBinding: Annotated Manifest

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-team-operator
  # NO namespace field.

subjects:
- kind: Group
  name: platform-engineers
  apiGroup: rbac.authorization.k8s.io
- kind: ServiceAccount
  name: cluster-monitor
  namespace: monitoring      # still required: it names the SA's home

roleRef:
  kind: ClusterRole          # MUST be ClusterRole; Role is rejected
  name: platform-operator
  apiGroup: rbac.authorization.k8s.io
```

```
┌──────────────────────────────────────────────────────────────────┐
│  BEFORE YOU CREATE A ClusterRoleBinding, ASK:                     │
├──────────────────────────────────────────────────────────────────┤
│  • Does this really need to work in EVERY namespace, including    │
│    every namespace that will exist next year?                     │
│  • Would three RoleBindings to the same ClusterRole do the job?   │
│  • Does the role touch nodes, PVs, namespaces, CRDs or RBAC       │
│    itself? If not, it almost certainly does not need to be        │
│    cluster wide.                                                  │
│  • Is the subject a Group? Binding cluster wide power to a User   │
│    creates an unauditable single point of privilege.              │
└──────────────────────────────────────────────────────────────────┘
```

---

## Rule Anatomy

```
┌──────────────────────────────────────────────────────────────────────┐
│                        ONE RBAC RULE                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  rules:                                                               │
│  - apiGroups:      ["apps"]        WHICH API GROUP                    │
│    resources:      ["deployments"] WHICH RESOURCE                     │
│    resourceNames:  ["web"]         WHICH INSTANCES (optional)         │
│    verbs:          ["get","patch"] WHICH ACTIONS                      │
│                                                                       │
│  - nonResourceURLs: ["/healthz"]   RAW HTTP PATHS (ClusterRole only)  │
│    verbs:           ["get"]                                           │
│                                                                       │
│  MATCHING: within one rule, EVERY field must match.                   │
│            across rules, ANY rule matching is enough.                 │
│                                                                       │
│  A rule may NOT combine `resources` and `nonResourceURLs`.            │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## apiGroups

The single most common cause of a rule that silently does nothing.

| Resource | apiVersion | `apiGroups` value |
|----------|-----------|-------------------|
| Pod, Service, ConfigMap, Secret, ServiceAccount, Node, Namespace, PersistentVolume, PersistentVolumeClaim, Event | `v1` | `""` |
| Deployment, ReplicaSet, StatefulSet, DaemonSet, ControllerRevision | `apps/v1` | `"apps"` |
| Job, CronJob | `batch/v1` | `"batch"` |
| Ingress, NetworkPolicy, IngressClass | `networking.k8s.io/v1` | `"networking.k8s.io"` |
| Role, ClusterRole, RoleBinding, ClusterRoleBinding | `rbac.authorization.k8s.io/v1` | `"rbac.authorization.k8s.io"` |
| StorageClass, VolumeAttachment, CSIDriver | `storage.k8s.io/v1` | `"storage.k8s.io"` |
| CertificateSigningRequest | `certificates.k8s.io/v1` | `"certificates.k8s.io"` |
| TokenReview, SelfSubjectReview | `authentication.k8s.io/v1` | `"authentication.k8s.io"` |
| SelfSubjectAccessReview, SubjectAccessReview | `authorization.k8s.io/v1` | `"authorization.k8s.io"` |
| HorizontalPodAutoscaler | `autoscaling/v2` | `"autoscaling"` |
| PodDisruptionBudget | `policy/v1` | `"policy"` |
| CustomResourceDefinition | `apiextensions.k8s.io/v1` | `"apiextensions.k8s.io"` |
| Lease | `coordination.k8s.io/v1` | `"coordination.k8s.io"` |
| Any custom resource | `<group>/<version>` | that `<group>` |

```
┌──────────────────────────────────────────────────────────────────┐
│  THE "" TRAP                                                      │
├──────────────────────────────────────────────────────────────────┤
│  apiGroups: [""]    means the CORE group. Pods live here.         │
│  apiGroups: ["*"]   means EVERY group. Completely different.      │
│                                                                   │
│  A rule with apiGroups: ["apps"] and resources: ["pods"] matches  │
│  NOTHING. Pods are not in the apps group. There is no error and   │
│  no warning; the rule is simply never satisfied.                  │
└──────────────────────────────────────────────────────────────────┘
```

```bash
# Find the group for any resource. Note the APIVERSION column.
kubectl api-resources | grep -w deployments
# deployments  deploy  apps/v1   true   Deployment

kubectl api-resources --namespaced=false        # cluster scoped resources
kubectl api-resources --verbs=list -o name      # everything listable
kubectl api-versions                            # every group/version served
```

---

## Resources and Subresources

A subresource is a distinct authorization target written as `resource/subresource`. Permission on the parent grants **nothing** on the subresource, and vice versa.

| Subresource | Reached by | What it exposes | Risk |
|-------------|-----------|-----------------|------|
| `pods/log` | `kubectl logs` | Container stdout and stderr | Logs often contain tokens, connection strings, PII |
| `pods/exec` | `kubectl exec` | A shell inside the container | Effectively full control of the workload |
| `pods/attach` | `kubectl attach` | The running process's streams | Similar to exec |
| `pods/portforward` | `kubectl port-forward` | A tunnel to any port in the pod | Bypasses NetworkPolicy and Service routing |
| `pods/ephemeralcontainers` | `kubectl debug` | Injects a debug container | Equivalent to exec, with a chosen image |
| `pods/eviction` | `kubectl drain`, PDB aware eviction | Evicts a pod respecting disruption budgets | Availability impact |
| `pods/status` | Controllers | Writes to `.status` | Lets a caller lie about pod state |
| `deployments/scale` | `kubectl scale` | The replica count only | Safe way to grant scaling without full write |
| `deployments/status` | Controllers | Writes to `.status` | Controller only |
| `nodes/proxy` | Metrics scrapers | Proxies to the kubelet API | Very powerful: can reach kubelet endpoints |
| `serviceaccounts/token` | `kubectl create token` | Mints a service account token | Lets the holder become that service account |

```yaml
# A support role: read pods, read logs, get a shell, but never delete
# anything and never read a Secret.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: support-debug
  namespace: prod
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["pods/exec"]
  # exec is a CREATE. It is not a `get`, because the API server
  # creates a streaming connection. This surprises everyone once.
  verbs: ["create"]
- apiGroups: [""]
  resources: ["pods/portforward"]
  verbs: ["create"]
```

```
┌──────────────────────────────────────────────────────────────────┐
│  VERB MAPPING FOR STREAMING SUBRESOURCES                          │
├──────────────────────────────────────────────────────────────────┤
│   kubectl logs pod          → get    pods/log                     │
│   kubectl exec pod -- sh    → create pods/exec                    │
│   kubectl attach pod        → create pods/attach                  │
│   kubectl port-forward pod  → create pods/portforward             │
│   kubectl cp                → create pods/exec  (it runs tar)     │
│   kubectl debug pod         → patch  pods/ephemeralcontainers     │
│   kubectl drain node        → create pods/eviction (+ node patch) │
│   kubectl top node          → get    nodes/metrics (metrics API)  │
└──────────────────────────────────────────────────────────────────┘
```

> ⚠️ **`pods/exec` is a privilege escalation path.** A user who can exec into a pod inherits everything that pod has: its mounted Secrets, its service account token, and its network position. Granting `exec` in a namespace where a privileged service account runs is equivalent to granting that service account's permissions.

---

## Verbs

### Standard Verbs

| Verb | HTTP | Applies to | Notes |
|------|------|-----------|-------|
| `get` | GET | One named object | The only verb that `resourceNames` restricts cleanly |
| `list` | GET on a collection | A collection | **Returns full object bodies**, so `list secrets` reads every secret |
| `watch` | GET with `?watch=true` | A collection | Streams changes; also returns full objects |
| `create` | POST | A collection | The name is chosen by the client, so `resourceNames` cannot restrict it |
| `update` | PUT | One object | Full replacement |
| `patch` | PATCH | One object | Partial modification; **a separate verb from `update`** |
| `delete` | DELETE | One object | |
| `deletecollection` | DELETE on a collection | A collection | Deletes everything matching; `resourceNames` cannot restrict it |

```
┌──────────────────────────────────────────────────────────────────┐
│  THE list / get DISTINCTION                                       │
├──────────────────────────────────────────────────────────────────┤
│  `get` fetches ONE object by name.                                │
│  `list` fetches ALL of them, WITH THEIR FULL CONTENT.             │
│                                                                   │
│  So `list` on secrets in a namespace reads EVERY secret in it,    │
│  even without `get`. Restricting a user to `get` on one named     │
│  secret while also granting `list` on secrets gives them          │
│  everything. Grant `list` only when the user genuinely needs      │
│  to enumerate.                                                    │
│                                                                   │
│  Note also: `kubectl get pods` (plural, no name) requires `list`, │
│  not `get`. That trips people constantly.                         │
└──────────────────────────────────────────────────────────────────┘
```

```
┌──────────────────────────────────────────────────────────────────┐
│  update vs patch                                                  │
├──────────────────────────────────────────────────────────────────┤
│  kubectl edit          → get + patch  (or update, by client)      │
│  kubectl apply         → get + patch  (server side apply: patch)  │
│  kubectl label / annotate / scale / set image  → patch            │
│  kubectl replace       → update                                   │
│                                                                   │
│  Granting `update` without `patch` breaks most kubectl workflows. │
│  In practice, grant both together, or neither.                    │
└──────────────────────────────────────────────────────────────────┘
```

### Special Verbs

| Verb | apiGroup / resource | Meaning |
|------|---------------------|---------|
| `bind` | `rbac.authorization.k8s.io` / `roles`, `clusterroles` | Permits creating a binding to a role you do not fully hold |
| `escalate` | `rbac.authorization.k8s.io` / `roles`, `clusterroles` | Permits writing a role containing permissions you do not hold |
| `impersonate` | core / `users`, `groups`, `serviceaccounts`; `authentication.k8s.io` / `uids`, `userextras/*` | Permits acting as another identity |
| `approve` | `certificates.k8s.io` / `signers` | Permits approving CSRs for a named signer |
| `sign` | `certificates.k8s.io` / `signers` | Permits signing CSRs for a named signer |
| `use` | varies | Defined by PodSecurityPolicy, which was removed in Kubernetes 1.25. It remains meaningful only for third party resources that define it |

```yaml
# The verb that lets a namespace admin delegate without holding the power
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: namespace-delegator
  namespace: dev
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["rolebindings"]
  verbs: ["create", "get", "list", "delete"]
# Without this, the holder could only bind roles they already hold.
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles"]
  resourceNames: ["view", "edit"]     # NEVER "admin" or "cluster-admin"
  verbs: ["bind"]
```

---

## resourceNames

```yaml
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-config", "feature-flags"]
  verbs: ["get", "update", "patch"]
```

```
┌──────────────────────────────────────────────────────────────────┐
│  resourceNames LIMITATIONS                                        │
├──────────────────────────────────────────────────────────────────┤
│  ✅ WORKS with verbs that name a single object:                   │
│       get, update, patch, delete                                  │
│                                                                   │
│  ❌ CANNOT restrict `create`. The name of a new object is not     │
│     known when the authorization decision is made.                │
│                                                                   │
│  ❌ CANNOT restrict `deletecollection`, for the same reason.      │
│                                                                   │
│  ❌ DOES NOT usefully restrict `list` or `watch`. A collection    │
│     request carries no object name, so a rule with resourceNames  │
│     never matches it. The practical effect: a user with only a    │
│     named-resource rule can `kubectl get configmap app-config`    │
│     but CANNOT `kubectl get configmaps`, and cannot see the       │
│     object in any UI that lists first.                            │
│                                                                   │
│  ❌ NO WILDCARDS OR PREFIXES. resourceNames: ["app-*"] matches a  │
│     literal object named "app-*", nothing else. There is no       │
│     pattern matching anywhere in RBAC.                            │
└──────────────────────────────────────────────────────────────────┘
```

The usual workaround for the list problem is to split the rule:

```yaml
rules:
# Broad read, so tools can enumerate
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
# Narrow write, only the ones this workload owns
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-config"]
  verbs: ["update", "patch"]
```

---

## nonResourceURLs

Paths that are not Kubernetes objects: health, metrics, discovery, profiling.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: health-and-metrics-reader
rules:
- nonResourceURLs:
  - /healthz
  - /livez
  - /readyz
  - /version
  - /metrics
  - /openapi/v2
  # A trailing /* matches everything below the prefix.
  - /apis/*
  verbs: ["get"]
```

```
┌──────────────────────────────────────────────────────────────────┐
│  nonResourceURLs RULES                                            │
├──────────────────────────────────────────────────────────────────┤
│  • Valid ONLY in a ClusterRole.                                   │
│  • Effective ONLY through a ClusterRoleBinding. A RoleBinding     │
│    referencing the role ignores these rules entirely.             │
│  • Cannot appear in the same rule as `resources`.                 │
│  • The verbs are lowercased HTTP methods: get, post, put, patch,  │
│    delete, head, options.                                         │
│  • The only wildcard is a trailing /*, which matches a prefix.    │
│    /api/*  matches /api/v1/... ; it does NOT match /api itself.   │
└──────────────────────────────────────────────────────────────────┘
```

```bash
kubectl get --raw /healthz
kubectl get --raw /metrics | head
kubectl auth can-i get /healthz
```

---

## Wildcards and Why They Are Dangerous

```yaml
# The most dangerous eleven lines in Kubernetes
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: do-not-do-this
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
- nonResourceURLs: ["*"]
  verbs: ["*"]
# This is cluster-admin, written by hand, usually by someone who was
# debugging and meant to narrow it later.
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                WHY WILDCARDS AGE BADLY                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  1. THEY GROW SILENTLY. apiGroups: ["*"] covers every CRD that any    │
│     operator installs in the future. The role you audited last year   │
│     now grants access to your secrets manager, your certificate       │
│     issuer and your database operator.                                │
│                                                                       │
│  2. THEY INCLUDE THE SPECIAL VERBS. verbs: ["*"] includes             │
│     `escalate`, `bind` and `impersonate`, which are exactly the       │
│     verbs that defeat privilege escalation prevention.                │
│                                                                       │
│  3. THEY INCLUDE EVERY SUBRESOURCE. resources: ["*"] covers           │
│     pods/exec, nodes/proxy and serviceaccounts/token.                 │
│                                                                       │
│  4. THEY DEFEAT REVIEW. Nobody can tell from `["*"]` what the         │
│     workload actually needs, so nobody can ever safely reduce it.     │
│                                                                       │
│  NARROWER WILDCARDS ARE ALSO WORSE THAN THEY LOOK:                    │
│    resources: ["*"] within apiGroups: [""] still includes secrets,    │
│    serviceaccounts and pods/exec.                                     │
│    verbs: ["*"] on pods still includes exec, attach and eviction.     │
│                                                                       │
│  THE ONE ACCEPTABLE USE: a controller that genuinely owns an entire   │
│  API group it defined itself.                                         │
│    apiGroups: ["widgets.example.com"]                                 │
│    resources: ["*"]                                                   │
│    verbs: ["*"]                                                       │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Audit: every ClusterRole containing a wildcard
kubectl get clusterroles -o json | jq -r '
  .items[] | select(.rules[]? |
    (.verbs[]? == "*") or (.resources[]? == "*") or (.apiGroups[]? == "*")) |
  .metadata.name' | sort

# Narrow it to roles that are actually bound to something
kubectl get clusterrolebindings -o json |
  jq -r '.items[].roleRef.name' | sort -u
```

---

## Aggregated ClusterRoles

An aggregated ClusterRole has an empty `rules` list that a controller in kube-controller-manager fills in by unioning every ClusterRole matching its selectors.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.example.com/aggregate-to-monitoring: "true"
rules: []      # DO NOT WRITE RULES HERE. The controller overwrites them.
```

```yaml
# A contributing role. Its rules flow into `monitoring` automatically.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-pods
  labels:
    rbac.example.com/aggregate-to-monitoring: "true"
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "nodes/metrics"]
  verbs: ["get", "list", "watch"]
```

### The Built-in Aggregation Labels

```
┌──────────────────────────────────────────────────────────────────────┐
│              DEFAULT AGGREGATION HIERARCHY                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   Label a ClusterRole with:                                           │
│                                                                       │
│     rbac.authorization.k8s.io/aggregate-to-view: "true"               │
│         └─► flows into `view`                                         │
│              └─► `view` itself carries aggregate-to-edit: "true"      │
│                   └─► so it also flows into `edit`                    │
│                        └─► `edit` carries aggregate-to-admin: "true"  │
│                             └─► so it also reaches `admin`            │
│                                                                       │
│     rbac.authorization.k8s.io/aggregate-to-edit: "true"               │
│         └─► `edit` and `admin`                                        │
│                                                                       │
│     rbac.authorization.k8s.io/aggregate-to-admin: "true"              │
│         └─► `admin` only                                              │
│                                                                       │
│   THE PAYOFF: label once, and every existing RoleBinding to view,     │
│   edit or admin in every namespace picks it up, with no edits to      │
│   any binding anywhere.                                               │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### Worked Example: Teach `view` About a CRD

You install an operator that defines `databases.example.com`. Nobody with the `view` role can see them, because `view` predates the CRD.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: database-viewer
  labels:
    # Reaches view, and therefore edit and admin too.
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
- apiGroups: ["example.com"]
  resources: ["databases", "databases/status"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: database-editor
  labels:
    # Write access reaches edit and admin, but NOT view.
    rbac.authorization.k8s.io/aggregate-to-edit: "true"
rules:
- apiGroups: ["example.com"]
  resources: ["databases"]
  verbs: ["create", "update", "patch", "delete", "deletecollection"]
```

```bash
kubectl apply -f database-rbac.yaml

# The controller reconciles within seconds. Watch the rules appear:
kubectl get clusterrole view -o yaml | grep -A4 'example.com'

# Anyone already bound to view can now see them
kubectl auth can-i list databases.example.com --as=alice -n dev     # yes
kubectl auth can-i delete databases.example.com --as=alice -n dev   # no
```

> ⚠️ Never edit the `rules` of an aggregated ClusterRole directly. The controller reconciles it and your change disappears, usually a few seconds later, which makes for a memorable debugging session. Add a labelled contributing ClusterRole instead.

---

## Default ClusterRoles

Every cluster ships with these. Reuse them before writing your own.

| ClusterRole | Scope of intent | Can read Secrets | Can write RBAC | Notes |
|-------------|-----------------|------------------|----------------|-------|
| `cluster-admin` | Everything, cluster wide | Yes | Yes | `*` on `*` plus all nonResourceURLs |
| `admin` | Full control of one namespace, via a RoleBinding | Yes | Yes, within the namespace | Cannot write ResourceQuota or the Namespace object itself |
| `edit` | Read and write most namespaced objects | Yes | No | Can run pods as any service account in the namespace |
| `view` | Read only | **No** | No | Secrets are deliberately excluded |

```
┌──────────────────────────────────────────────────────────────────────┐
│              WHAT `edit` AND `admin` REALLY GRANT                     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  `edit` in a namespace lets the holder:                               │
│    • create a Pod with serviceAccountName: <any SA in the namespace>  │
│    • therefore obtain that service account's token                    │
│    • therefore act with ALL of that service account's permissions     │
│                                                                       │
│  So if ANY service account in the namespace is bound to               │
│  cluster-admin (a very common shortcut for operators and CI),         │
│  then `edit` in that namespace is effectively cluster-admin.          │
│                                                                       │
│  The same applies to `pods/exec` into a pod running as that SA.       │
│                                                                       │
│  MITIGATION                                                           │
│    • Never bind cluster-admin to a namespaced service account.        │
│    • Keep privileged service accounts in their own namespace where    │
│      no human holds edit or admin.                                    │
│    • Audit: which SAs in this namespace are powerful?                 │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Read the built-in roles rather than guessing what they contain
kubectl describe clusterrole view
kubectl describe clusterrole edit
kubectl describe clusterrole admin
kubectl get clusterrole cluster-admin -o yaml

# Confirm view really cannot read secrets
kubectl auth can-i get secrets --as=someone --as-group=viewers -n dev
```

### The `system:` ClusterRoles

Reserved, reconciled by the API server at startup, and not to be edited.

| Role | Bound to | Purpose |
|------|----------|---------|
| `system:basic-user` | Group `system:authenticated` | Lets any authenticated user read their own permissions (`SelfSubjectAccessReview`) |
| `system:discovery` | Group `system:authenticated` | API discovery endpoints, so clients can build their request paths |
| `system:public-info-viewer` | Groups `system:authenticated` and `system:unauthenticated` | `/healthz`, `/livez`, `/readyz`, `/version` |
| `system:node` | Historically the group `system:nodes` | Kubelet permissions; superseded in practice by the Node authorizer |
| `system:kube-scheduler` | User `system:kube-scheduler` | Scheduler permissions |
| `system:kube-controller-manager` | User `system:kube-controller-manager` | Controller manager permissions |
| `system:kube-proxy` | User `system:kube-proxy` | Services and EndpointSlices |
| `system:auth-delegator` | Extension API servers | Create `TokenReview` and `SubjectAccessReview` |
| `system:kubelet-api-admin` | Nothing by default | Full access to the kubelet API through `nodes/proxy` |
| `system:certificates.k8s.io:certificatesigningrequests:nodeclient` | Group `system:bootstrappers:kubeadm:default-node-token` | Lets a joining node request its kubelet client certificate |

```bash
kubectl get clusterroles | grep '^system:' | head -30

# If someone edits a system: role, the API server restores it on restart.
# The escape hatch, which you should treat as a red flag if you find it:
kubectl get clusterrole system:discovery \
  -o jsonpath='{.metadata.annotations.rbac\.authorization\.kubernetes\.io/autoupdate}'
```

---

## The system:masters Bypass

```
┌──────────────────────────────────────────────────────────────────────┐
│                    system:masters                                     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   Membership in the GROUP system:masters is checked by a HARDCODED    │
│   authorizer that runs before RBAC and allows everything.             │
│                                                                       │
│   CONSEQUENCES                                                        │
│   • There is NO ClusterRoleBinding to delete. Search for one and      │
│     you will not find it, because none exists.                        │
│   • RBAC is never consulted, so no rule can restrain it and no        │
│     audit of RBAC objects will reveal it.                             │
│   • A leaked certificate with O=system:masters is unrevocable,        │
│     because Kubernetes checks no CRL. The only remedy is rotating     │
│     the cluster CA, which invalidates every other certificate too.    │
│                                                                       │
│   WHO HAS IT                                                          │
│   • On older kubeadm: admin.conf (CN=kubernetes-admin,                │
│     O=system:masters)                                                 │
│   • On newer kubeadm: super-admin.conf only, while admin.conf uses    │
│     the group kubeadm:cluster-admins with an ordinary, DELETABLE      │
│     ClusterRoleBinding to cluster-admin                               │
│                                                                       │
│   PRACTICE                                                            │
│   • Never issue a certificate with O=system:masters for a person.     │
│   • Store super-admin.conf offline, and use it only when RBAC         │
│     itself is broken.                                                 │
│   • Prefer cluster-admin via a binding, because a binding can be      │
│     deleted, audited and time boxed.                                  │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# There is nothing to find here, and that is the point:
kubectl get clusterrolebindings -o json |
  jq -r '.items[] | select(.subjects[]?.name=="system:masters") | .metadata.name'
# (usually empty)
```

---

## Privilege Escalation Prevention

The API server refuses to let you write a role granting permissions you do not already hold. Without this, `edit` on Roles would be equivalent to cluster-admin for everyone.

```
┌──────────────────────────────────────────────────────────────────────┐
│                 THE TWO GUARDS                                        │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  GUARD 1: WRITING A ROLE                                              │
│    To create or update a Role/ClusterRole, you must ALREADY HOLD      │
│    every permission the role contains, within the scope where you     │
│    are writing it.                                                    │
│                                                                       │
│    alice (can read pods in dev)                                       │
│      tries to create a Role in dev granting `delete secrets`          │
│      → 403: "attempt to grant extra privileges"                       │
│                                                                       │
│    OVERRIDE: the `escalate` verb on roles/clusterroles.               │
│                                                                       │
│  GUARD 2: CREATING A BINDING                                          │
│    To create a RoleBinding or ClusterRoleBinding, you must ALREADY    │
│    HOLD every permission in the referenced role, OR hold the `bind`   │
│    verb on that specific role.                                        │
│                                                                       │
│    alice (namespace admin in dev)                                     │
│      tries to bind cluster-admin to herself in dev                    │
│      → 403, because she does not hold cluster-admin                   │
│                                                                       │
│    OVERRIDE: the `bind` verb, ideally with resourceNames.             │
│                                                                       │
│  WHY BOTH ARE NEEDED                                                  │
│    Guard 1 alone would let you bind an EXISTING powerful role.        │
│    Guard 2 alone would let you write a powerful role and then bind    │
│    it because you now "hold" it. Together they close the loop.        │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# The error you will see
kubectl -n dev create role sneaky --verb=delete --resource=secrets --as=alice
```

```
Error from server (Forbidden): roles.rbac.authorization.k8s.io "sneaky" is
forbidden: user "alice" (groups=["developers" "system:authenticated"]) is
attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["secrets"], Verbs:["delete"]}
```

### Granting the Overrides Safely

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-owner
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["rolebindings", "roles"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Allow binding ONLY these three roles, and never anything stronger.
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles"]
  resourceNames: ["view", "edit", "app-developer"]
  verbs: ["bind"]
```

```
┌──────────────────────────────────────────────────────────────────┐
│  ⚠️  `escalate` IS EQUIVALENT TO cluster-admin                    │
├──────────────────────────────────────────────────────────────────┤
│  A user with `escalate` on clusterroles can write a ClusterRole   │
│  containing `*` on `*`, then (holding it by definition) bind it   │
│  to themselves. Treat `escalate` as the same grant as             │
│  cluster-admin, and prefer `bind` with resourceNames instead.     │
│                                                                   │
│  Audit for it:                                                    │
│    kubectl get clusterroles -o json | jq -r '.items[] |           │
│      select(.rules[]?.verbs[]? == "escalate") | .metadata.name'   │
└──────────────────────────────────────────────────────────────────┘
```

---

## Subjects

```yaml
subjects:

# A human or any external identity. Just a string; nothing is validated.
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io

# For an OIDC user, include the prefix the API server applies.
- kind: User
  name: "oidc:alice@example.com"
  apiGroup: rbac.authorization.k8s.io

# A group. Also just a string.
- kind: Group
  name: developers
  apiGroup: rbac.authorization.k8s.io

# A service account, referenced structurally.
- kind: ServiceAccount
  name: build-bot
  namespace: ci             # required, and may differ from the binding's ns
                            # apiGroup is omitted (core group)

# A service account, referenced as a User by its full username.
# Equivalent in effect, and the form you must use with --as.
- kind: User
  name: system:serviceaccount:ci:build-bot
  apiGroup: rbac.authorization.k8s.io
```

### Binding to Many Service Accounts at Once

```yaml
# EVERY service account in namespace `dev`
subjects:
- kind: Group
  name: system:serviceaccounts:dev
  apiGroup: rbac.authorization.k8s.io
---
# EVERY service account in the ENTIRE cluster. Rarely correct.
subjects:
- kind: Group
  name: system:serviceaccounts
  apiGroup: rbac.authorization.k8s.io
---
# EVERY authenticated identity, human and machine alike. Almost never
# correct beyond the built-in system:basic-user and system:discovery.
subjects:
- kind: Group
  name: system:authenticated
  apiGroup: rbac.authorization.k8s.io
```

```
┌──────────────────────────────────────────────────────────────────┐
│  ⚠️  SCOPE OF THE BUILT-IN GROUPS                                 │
├──────────────────────────────────────────────────────────────────┤
│  system:serviceaccounts:dev  → every SA in dev, including the     │
│                                `default` SA that any pod gets     │
│                                when no serviceAccountName is set  │
│  system:serviceaccounts      → every SA in every namespace,       │
│                                including namespaces created later │
│  system:authenticated        → every human AND every service      │
│                                account AND every kubelet          │
│  system:unauthenticated      → every anonymous caller. Binding    │
│                                anything meaningful here exposes   │
│                                the cluster to the network.        │
└──────────────────────────────────────────────────────────────────┘
```

> 📌 A common and legitimate use of `system:serviceaccounts:<namespace>` is granting every workload in a namespace the ability to read a shared ConfigMap. A common and illegitimate use is granting `edit` to it, which hands every pod in the namespace, including any compromised one, write access to the whole namespace.

---

## Testing and Auditing Access

### kubectl auth can-i

```bash
# Ask about yourself
kubectl auth can-i create deployments -n dev
kubectl auth can-i delete nodes
kubectl auth can-i '*' '*'                      # am I cluster-admin?

# Ask about somebody else (requires the impersonate verb)
kubectl auth can-i list secrets --as=alice -n prod
kubectl auth can-i create pods --as=alice --as-group=developers -n dev
kubectl auth can-i get pods --as=system:serviceaccount:ci:build-bot -n ci

# A specific named object
kubectl auth can-i update configmap/app-config -n dev
kubectl auth can-i get pods/mypod-abc123 -n dev

# A subresource
kubectl auth can-i create pods --subresource=exec -n dev
kubectl auth can-i get pods --subresource=log -n dev

# A non resource URL
kubectl auth can-i get /healthz

# THE MOST USEFUL FORM: everything, in one namespace
kubectl auth can-i --list -n dev
kubectl auth can-i --list --as=alice -n dev
kubectl auth can-i --list --as=system:serviceaccount:dev:build-bot -n dev

# Suppress the human readable output, for scripting
kubectl auth can-i delete pods -n prod --quiet && echo "allowed"
```

```
$ kubectl auth can-i --list --as=alice -n dev

Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
pods                                            []                  []               [get list watch]
pods/log                                        []                  []               [get list watch]
                                                [/healthz]          []               [get]
                                                [/version]          []               [get]
```

The first two rows appear for everyone: they come from `system:basic-user`, bound to `system:authenticated`.

> ⚠️ `--list` is computed from RBAC rules only. It cannot account for a Webhook authorizer, and it says nothing about admission control. A `yes` from `can-i` still leaves room for a rejection by PodSecurity or a validating webhook.

### kubectl auth whoami

```bash
kubectl auth whoami
kubectl auth whoami -o yaml
```

Confirm which identity you are testing with before concluding anything about a rule.

### SelfSubjectAccessReview

What `can-i` actually sends:

```yaml
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectAccessReview
spec:
  resourceAttributes:
    namespace: dev
    verb: create
    group: "apps"          # "" for core
    resource: deployments
    subresource: ""        # for example "log" or "exec"
    name: ""               # a specific object name, optional
# Or, for a non resource path:
#  nonResourceAttributes:
#    path: /healthz
#    verb: get
```

```bash
cat <<'EOF' | kubectl create -f - -o yaml
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectAccessReview
spec:
  resourceAttributes:
    namespace: dev
    verb: create
    group: apps
    resource: deployments
EOF
```

```yaml
status:
  allowed: true
  reason: 'RBAC: allowed by RoleBinding "dev-deployers/dev" of ClusterRole
    "app-developer" to Group "developers"'
```

That `reason` string is gold: it names the exact binding and role that allowed the request, which turns "why can they do this" from guesswork into a lookup.

`SelfSubjectRulesReview` returns everything at once, which is what `can-i --list` uses:

```yaml
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectRulesReview
spec:
  namespace: dev
```

### Finding Who Can Do Something

There is no built-in reverse lookup. Build one from impersonation plus the binding list.

```bash
# Every binding that mentions a given subject
SUBJECT=alice
kubectl get rolebindings,clusterrolebindings -A -o json | jq -r --arg s "$SUBJECT" '
  .items[]
  | select(.subjects[]? | .name == $s)
  | "\(.kind)\t\(.metadata.namespace // "-")\t\(.metadata.name)\t-> \(.roleRef.kind)/\(.roleRef.name)"'

# Every subject bound to cluster-admin, which is the audit everyone needs
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name=="cluster-admin")
  | .metadata.name as $n | .subjects[]? | "\($n)\t\(.kind)/\(.name)"'

# Who can read secrets in prod? Test each candidate.
for u in alice bob carol; do
  printf '%-8s %s\n' "$u" "$(kubectl auth can-i list secrets --as="$u" -n prod)"
done

# Same, for every service account in a namespace
for sa in $(kubectl -n prod get sa -o name | cut -d/ -f2); do
  printf '%-20s %s\n' "$sa" \
    "$(kubectl auth can-i list secrets --as=system:serviceaccount:prod:$sa -n prod)"
done
```

### kubectl auth reconcile

The right way to apply RBAC manifests, because it understands that `roleRef` is immutable and that rules should be merged rather than replaced.

```bash
kubectl auth reconcile -f rbac.yaml
kubectl auth reconcile -f rbac.yaml --dry-run=client
# Remove permissions present in the cluster but absent from the file:
kubectl auth reconcile -f rbac.yaml --remove-extra-permissions --remove-extra-subjects
```

---

## Recipe: Read Only Namespace Viewer

Someone who needs to look at a namespace and never change it.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: qa-view-dev
  namespace: dev
subjects:
- kind: Group
  name: qa-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view              # built-in, and deliberately excludes Secrets
  apiGroup: rbac.authorization.k8s.io
```

If `view` is not quite right, for example because logs are needed but Secrets must stay excluded and the team also wants to see events:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-viewer-plus-logs
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "endpoints",
              "persistentvolumeclaims", "serviceaccounts", "events"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log", "pods/status"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
# Deliberately absent: secrets, pods/exec, pods/portforward,
# roles, rolebindings, and every write verb.
```

```bash
kubectl auth can-i list pods --as=qa1 --as-group=qa-team -n dev       # yes
kubectl auth can-i get pods --subresource=log --as=qa1 --as-group=qa-team -n dev  # yes
kubectl auth can-i list secrets --as=qa1 --as-group=qa-team -n dev    # no
kubectl auth can-i delete pods --as=qa1 --as-group=qa-team -n dev     # no
```

---

## Recipe: Developer With Deploy Rights

A developer who owns their application in one namespace: deploy, scale, restart, read logs, debug, but never touch RBAC and never read the namespace's Secrets.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: app-developer
rules:
# Workload objects: full lifecycle
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments/scale", "statefulsets/scale"]
  verbs: ["get", "update", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments/status", "statefulsets/status", "daemonsets/status"]
  verbs: ["get"]

- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Pods: read and delete (to force a restart), plus logs and debugging
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "delete"]
- apiGroups: [""]
  resources: ["pods/log", "pods/status"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec", "pods/portforward"]
  verbs: ["create"]

# Services, config, ingress
- apiGroups: [""]
  resources: ["services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Read only visibility into the rest
- apiGroups: [""]
  resources: ["events", "endpoints", "persistentvolumeclaims", "serviceaccounts"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["get", "list", "watch"]

# DELIBERATELY ABSENT
#   secrets                 → use a secrets manager or a platform pipeline
#   roles, rolebindings     → prevents self escalation
#   resourcequotas, limitranges → platform owned
#   namespaces, nodes, pv   → cluster scoped, not a developer's business
---
# One ClusterRole, bound once per namespace the team owns.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-developers
  namespace: payments-dev
subjects:
- kind: Group
  name: payments-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: app-developer
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: payments-developers
  namespace: payments-staging
subjects:
- kind: Group
  name: payments-team
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: app-developer
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl auth can-i create deployments --as=dev1 --as-group=payments-team -n payments-dev    # yes
kubectl auth can-i create deployments --as=dev1 --as-group=payments-team -n payments-prod   # no
kubectl auth can-i list secrets --as=dev1 --as-group=payments-team -n payments-dev          # no
kubectl auth can-i create rolebindings --as=dev1 --as-group=payments-team -n payments-dev   # no
```

---

## Recipe: CI/CD Service Account Scoped to One Namespace

A pipeline that deploys and nothing else.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deployer
  namespace: payments-prod
automountServiceAccountToken: false      # the pipeline runs OUTSIDE the cluster
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: payments-prod
rules:
# Exactly the objects the pipeline manages
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
  # NOTE: no `delete`. A pipeline that can delete a Deployment can
  # take production down with a bad template path.
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  verbs: ["get", "update", "patch"]
- apiGroups: [""]
  resources: ["services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
# Enough to verify the rollout succeeded
- apiGroups: [""]
  resources: ["pods", "events"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer
  namespace: payments-prod
subjects:
- kind: ServiceAccount
  name: deployer
  namespace: payments-prod
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
```

```bash
# Short lived credential for the pipeline run
TOKEN=$(kubectl -n payments-prod create token deployer --duration=30m)

# Verify before handing it over
kubectl auth can-i --list --as=system:serviceaccount:payments-prod:deployer -n payments-prod
kubectl auth can-i delete deployments --as=system:serviceaccount:payments-prod:deployer -n payments-prod  # no
kubectl auth can-i get pods --as=system:serviceaccount:payments-prod:deployer -n kube-system             # no
```

> 📖 **See Also**: [service-accounts.md](service-accounts.md) for token lifetime, audiences and long lived credentials.

---

## Recipe: Operator Service Account for a CRD

A controller that owns `databases.example.com` cluster wide. This is the one place a resource wildcard is defensible, and even here the rest is written out explicitly.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: database-operator
  namespace: database-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: database-operator
rules:
# The CRD this operator owns, including its status and finalizers.
- apiGroups: ["example.com"]
  resources: ["databases"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["example.com"]
  resources: ["databases/status"]
  verbs: ["get", "update", "patch"]
- apiGroups: ["example.com"]
  resources: ["databases/finalizers"]
  verbs: ["update"]

# The objects it creates on behalf of each Database.
- apiGroups: ["apps"]
  resources: ["statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["services", "configmaps", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# Secrets: create and read only the ones it owns, never list all of them.
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "create", "update", "patch"]

# Every controller needs these two.
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: database-operator
subjects:
- kind: ServiceAccount
  name: database-operator
  namespace: database-system
roleRef:
  kind: ClusterRole
  name: database-operator
  apiGroup: rbac.authorization.k8s.io
```

```
┌──────────────────────────────────────────────────────────────────┐
│  OPERATOR RBAC CHECKLIST                                          │
├──────────────────────────────────────────────────────────────────┤
│  ✅ /status as a separate rule, usually get/update/patch          │
│  ✅ /finalizers with `update` if the operator sets finalizers     │
│  ✅ leases in coordination.k8s.io for leader election             │
│  ✅ events with create and patch, or the operator logs errors     │
│     every time it tries to record one                             │
│  ✅ secrets WITHOUT `list`, so a compromise cannot dump them all  │
│  ❌ never `escalate`, `bind` or `impersonate`                     │
│  ❌ never cluster-admin "until we work out what it needs"         │
└──────────────────────────────────────────────────────────────────┘
```

---

## Recipe: Break Glass Role

Full access, deliberately hard to obtain, and loud when used.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: break-glass-incident-2025-01-15
  annotations:
    incident: "INC-4471"
    approved-by: "security-oncall"
    expires: "2025-01-15T18:00:00Z"      # documentation only, NOT enforced
    ticket: "https://tickets.example.com/INC-4471"
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                  BREAK GLASS PRACTICE                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  1. THE BINDING DOES NOT EXIST UNTIL IT IS NEEDED. Keep the manifest  │
│     in a repository, not in the cluster.                              │
│                                                                       │
│  2. NAME IT AFTER THE INCIDENT. `break-glass-incident-<id>` makes an  │
│     abandoned binding obvious in any listing.                         │
│                                                                       │
│  3. KUBERNETES DOES NOT EXPIRE BINDINGS. The `expires` annotation is  │
│     a note to humans. Removal must be automated or checklisted:       │
│       kubectl delete clusterrolebinding break-glass-incident-...      │
│                                                                       │
│  4. ALERT ON CREATION. An audit policy rule on the creation of        │
│     ClusterRoleBindings referencing cluster-admin should page         │
│     someone, every time, with no exceptions.                          │
│                                                                       │
│  5. BIND A USER, NOT A GROUP. Attribution matters most precisely      │
│     when the stakes are highest.                                      │
│                                                                       │
│  6. PREFER cluster-admin OVER system:masters. A binding can be        │
│     deleted and audited; group membership in system:masters cannot.   │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Find abandoned break glass bindings
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.metadata.annotations.expires != null)
  | "\(.metadata.name)\texpires=\(.metadata.annotations.expires)"'
```

---

## Least Privilege Methodology

```
┌──────────────────────────────────────────────────────────────────────┐
│              DERIVING A MINIMAL ROLE                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  STEP 1  START AT ZERO                                                │
│          Create the ServiceAccount or issue the certificate with NO   │
│          bindings at all. Run the workload. Collect the failures.     │
│                                                                       │
│  STEP 2  READ THE 403s                                                │
│          Every Forbidden message names the verb, the resource, the    │
│          apiGroup and the namespace. That IS the rule you need,       │
│          already written out for you.                                 │
│                                                                       │
│  STEP 3  ADD ONE RULE AT A TIME                                       │
│          Not one role. One rule. Re-run. Repeat until it works.       │
│                                                                       │
│  STEP 4  REMOVE THE VERBS YOU ADDED "JUST IN CASE"                    │
│          Especially delete, deletecollection and list on secrets.     │
│                                                                       │
│  STEP 5  CHOOSE THE SMALLEST SCOPE THAT WORKS                         │
│          Role > RoleBinding to a ClusterRole > ClusterRoleBinding.    │
│                                                                       │
│  STEP 6  VERIFY THE NEGATIVES                                         │
│          Test what must FAIL, not only what must succeed. A role      │
│          review that only checks the happy path proves nothing.       │
│                                                                       │
│  STEP 7  RE-DERIVE AFTER EVERY UPGRADE                                │
│          New controller versions need new permissions, and old        │
│          permissions become unnecessary. Roles rot.                   │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### Deriving Rules From Audit Logs

Enable auditing with a policy that records the metadata of every request from the identity you are profiling:

```yaml
# /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# Record what one specific service account does, at Metadata level.
# Metadata is enough: it captures user, verb, resource and namespace,
# without the request or response bodies.
- level: Metadata
  users: ["system:serviceaccount:dev:build-bot"]

# Everything else: nothing, to keep the log small during profiling.
- level: None
```

```yaml
    # kube-apiserver flags
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-log-maxage=7
    - --audit-log-maxbackup=5
    - --audit-log-maxsize=100
```

```bash
# Turn the log into a list of distinct (verb, apiGroup, resource) tuples
sudo jq -r '
  select(.user.username=="system:serviceaccount:dev:build-bot")
  | select(.objectRef != null)
  | [.verb,
     (.objectRef.apiGroup // ""),
     .objectRef.resource,
     (.objectRef.subresource // ""),
     (.objectRef.namespace // "-")]
  | @tsv' /var/log/kubernetes/audit.log | sort -u
```

```
create      apps      deployments             -        dev
get         apps      deployments             -        dev
patch       apps      deployments             -        dev
list                  pods                    -        dev
get                   pods            log              dev
create                events                  -        dev
```

That output maps one to one onto rules. Group by apiGroup and resource, union the verbs, and you have a minimal Role that is derived from observed behaviour rather than guesswork.

```bash
# Rejected requests only: exactly the permissions that are MISSING
sudo jq -r 'select(.annotations."authorization.k8s.io/decision"=="forbid")
  | [.user.username, .verb, (.objectRef.apiGroup // ""), .objectRef.resource,
     (.objectRef.namespace // "-")] | @tsv' \
  /var/log/kubernetes/audit.log | sort | uniq -c | sort -rn
```

> 📌 Audit annotations are unusually helpful here. `authorization.k8s.io/decision` is `allow` or `forbid`, and `authorization.k8s.io/reason` names the exact binding and role that allowed a request, in the same format `SelfSubjectAccessReview` returns.

---

## Common RBAC Mistakes

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. WRONG apiGroup                                                    │
│     resources: ["deployments"] with apiGroups: [""]                   │
│     Deployments are in "apps". The rule matches nothing, silently.    │
│                                                                       │
│  2. FORGETTING THE SUBRESOURCE                                        │
│     Granting `pods` does not grant `pods/log`. Add it explicitly.     │
│                                                                       │
│  3. get WHERE list IS NEEDED                                          │
│     `kubectl get pods` with no name requires `list`, not `get`.       │
│                                                                       │
│  4. update WITHOUT patch                                              │
│     kubectl edit, apply, label, annotate and scale all use patch.     │
│                                                                       │
│  5. ClusterRoleBinding WHERE RoleBinding WAS MEANT                    │
│     Grants the role in EVERY namespace, forever, including ones       │
│     that do not exist yet. Read every ClusterRoleBinding twice.       │
│                                                                       │
│  6. EXPECTING A RoleBinding TO GRANT CLUSTER SCOPED ACCESS            │
│     Rules about nodes, PVs, namespaces and nonResourceURLs are        │
│     silently ignored when a ClusterRole is bound with a RoleBinding.  │
│                                                                       │
│  7. WRONG SUBJECT SHAPE                                               │
│     ServiceAccount needs `namespace` and NO apiGroup.                 │
│     User and Group need apiGroup: rbac.authorization.k8s.io.          │
│                                                                       │
│  8. USERNAME MISMATCH                                                 │
│     The binding says `alice`; the certificate CN is `Alice`, or the   │
│     OIDC prefix makes it `oidc:alice@example.com`. Exact strings.     │
│                                                                       │
│  9. FORGETTING THE SERVICE ACCOUNT USERNAME FORM                      │
│     With --as you must write system:serviceaccount:<ns>:<name>.       │
│                                                                       │
│ 10. TRYING TO WRITE A DENY RULE                                       │
│     RBAC has none. Remove or narrow the grant instead.                │
│                                                                       │
│ 11. EDITING roleRef                                                   │
│     Immutable. Delete and recreate, or use kubectl auth reconcile.    │
│                                                                       │
│ 12. EDITING AN AGGREGATED ClusterRole's RULES                         │
│     The controller reverts them within seconds.                       │
│                                                                       │
│ 13. BINDING TO system:authenticated                                   │
│     That is every human, every kubelet and every service account.     │
│                                                                       │
│ 14. cluster-admin FOR A NAMESPACED SERVICE ACCOUNT                    │
│     Anyone with `edit` or `pods/exec` in that namespace inherits it.  │
│                                                                       │
│ 15. list ON SECRETS "FOR THE DASHBOARD"                               │
│     `list` returns full object bodies. That is every secret value.    │
│                                                                       │
│ 16. LEAVING A DEBUGGING WILDCARD IN PLACE                             │
│     verbs: ["*"] added at 2am is still there a year later.            │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Command Reference

```bash
# ---------- INSPECT ----------
kubectl get roles -A
kubectl get clusterroles
kubectl get rolebindings -A
kubectl get clusterrolebindings
kubectl describe role <name> -n <ns>
kubectl describe clusterrole view
kubectl get clusterrole cluster-admin -o yaml

# ---------- CREATE IMPERATIVELY (fast, exam friendly) ----------
kubectl create role pod-reader \
  --verb=get,list,watch --resource=pods -n dev

kubectl create role pod-reader \
  --verb=get --resource=pods --resource-name=mypod -n dev

kubectl create clusterrole node-reader \
  --verb=get,list,watch --resource=nodes

kubectl create clusterrole deploy-scaler \
  --verb=get,update,patch --resource=deployments.apps/scale

kubectl create clusterrole url-reader \
  --verb=get --non-resource-url=/healthz --non-resource-url=/metrics

kubectl create rolebinding alice-pod-reader \
  --role=pod-reader --user=alice -n dev

kubectl create rolebinding qa-view \
  --clusterrole=view --group=qa-team -n dev

kubectl create rolebinding ci-deployer \
  --role=deployer --serviceaccount=ci:build-bot -n ci

kubectl create clusterrolebinding platform-admins \
  --clusterrole=cluster-admin --group=platform-engineers

# Always preview first
kubectl create role x --verb=get --resource=pods -n dev \
  --dry-run=client -o yaml

# ---------- TEST ----------
kubectl auth can-i <verb> <resource> -n <ns>
kubectl auth can-i <verb> <resource> --as=<user> -n <ns>
kubectl auth can-i <verb> <resource> --as-group=<group> -n <ns>
kubectl auth can-i <verb> <resource> --subresource=<sub> -n <ns>
kubectl auth can-i --list -n <ns>
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa> -n <ns>
kubectl auth whoami

# ---------- APPLY SAFELY ----------
kubectl auth reconcile -f rbac.yaml
kubectl auth reconcile -f rbac.yaml --dry-run=client

# ---------- AUDIT ----------
kubectl get clusterrolebindings -o json |
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'

kubectl get clusterroles -o json | jq -r '
  .items[] | select(.rules[]? | .verbs[]? == "*") | .metadata.name'

kubectl get rolebindings,clusterrolebindings -A -o json |
  jq -r '.items[] | select(.subjects[]?.kind=="ServiceAccount")
  | "\(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.name)"'

# ---------- DELETE ----------
kubectl delete rolebinding <name> -n <ns>
kubectl delete clusterrolebinding <name>
kubectl delete role <name> -n <ns>
```

---

## Troubleshooting

### Reading a Forbidden Message

```
Error from server (Forbidden): deployments.apps is forbidden:
  User "system:serviceaccount:ci:build-bot" cannot create resource
  "deployments" in API group "apps" in the namespace "payments-prod"
```

```
┌──────────────────────────────────────────────────────────────────────┐
│         EVERY PIECE OF THE RULE YOU NEED IS IN THAT MESSAGE          │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   User "system:serviceaccount:ci:build-bot"                           │
│        └─► the SUBJECT: kind ServiceAccount, name build-bot, ns ci    │
│                                                                       │
│   cannot create                                                       │
│        └─► the VERB: create                                           │
│                                                                       │
│   resource "deployments"                                              │
│        └─► the RESOURCE: deployments                                  │
│                                                                       │
│   in API group "apps"                                                 │
│        └─► apiGroups: ["apps"]    (an empty "" here means core)       │
│                                                                       │
│   in the namespace "payments-prod"                                    │
│        └─► WHERE the RoleBinding must live                            │
│                                                                       │
│   ⚠️  If the message says `at the cluster scope` instead of naming a  │
│       namespace, you need a ClusterRoleBinding, not a RoleBinding.    │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

The resulting rule writes itself:

```yaml
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["create"]
```

### The 403 Debug Checklist

```bash
# 1. WHO does the server think you are? Not who you think you are.
kubectl auth whoami

# 2. What does the server say you can do here?
kubectl auth can-i --list -n <ns>

# 3. Which bindings mention that exact subject string?
kubectl get rolebindings,clusterrolebindings -A -o json | jq -r --arg s "<subject>" '
  .items[] | select(.subjects[]? | .name == $s)
  | "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'

# 4. Does the referenced role actually contain the rule?
kubectl describe clusterrole <role>
kubectl describe role <role> -n <ns>

# 5. Is the binding in the RIGHT NAMESPACE? A RoleBinding in `dev`
#    does nothing for a request against `prod`.
kubectl get rolebinding <name> -n <ns> -o yaml

# 6. Is the subject shape correct?
kubectl get rolebinding <name> -n <ns> -o jsonpath='{.subjects}' | jq

# 7. Is it a SUBRESOURCE request?
kubectl <your command> -v=8 2>&1 | grep -E 'GET|POST|PATCH|DELETE' | head
```

### Symptom Table

| Symptom | Cause | Fix |
|---------|-------|-----|
| `cannot list resource "pods"` but `get` works on one pod | Only `get` granted | Add `list` (and usually `watch`) |
| `cannot get resource "pods" in API group ""` on `kubectl logs` | Missing `pods/log` | Add the subresource as its own entry |
| `cannot create resource "pods/exec"` | `exec` is a `create`, not a `get` | `verbs: ["create"]` on `pods/exec` |
| Rule looks right but nothing works | Wrong `apiGroups` | Check `kubectl api-resources` |
| Works in `dev`, fails in `prod` | RoleBinding exists only in `dev` | Create a binding in `prod` too |
| `at the cluster scope` in the message | Cluster scoped resource with only a RoleBinding | Use a ClusterRoleBinding |
| ClusterRole rule for nodes ignored | Bound with a RoleBinding | Cluster scoped rules need a ClusterRoleBinding |
| `cannot change roleRef` | roleRef is immutable | Delete and recreate the binding |
| Role rules keep reverting | Aggregated ClusterRole | Add a labelled contributing ClusterRole |
| `attempt to grant extra privileges` | Privilege escalation prevention | Hold the permissions, or get `escalate` or `bind` |
| Works for you, not for the service account | You are cluster-admin | Always test with `--as` |
| `can-i` says yes but the request still fails | Admission control, not RBAC | Check PodSecurity, quotas, webhooks |
| Everything returns 401, not 403 | Authentication, not authorization | See [authentication.md](authentication.md) |

### When can-i Says Yes But the Request Fails

```bash
kubectl auth can-i create pods -n prod        # yes
kubectl -n prod run test --image=nginx
# Error from server (Forbidden): pods "test" is forbidden: violates
# PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
```

That is **admission control**, not RBAC. The give away is that the message names a policy or a webhook rather than a verb and a resource. RBAC decided you may create pods; a later stage decided this particular pod is not acceptable.

---

## Exam and Interview Traps

1. **RBAC has no deny rule.** Authorizers grant; RBAC and Node never say no. Remove or narrow the grant instead of trying to write an exception.
2. **A request is allowed if any rule in any bound role matches.** Permissions are a union, and adding a binding can only ever increase access.
3. **A RoleBinding can reference a ClusterRole, and the result is scoped to that one namespace.** This is the single most tested fact in RBAC.
4. **A ClusterRoleBinding cannot reference a Role.** The API server rejects it.
5. **A RoleBinding referencing a ClusterRole silently ignores cluster scoped rules and nonResourceURLs.** No error, no access.
6. **`apiGroups: [""]` is the core group; `apiGroups: ["*"]` is everything.** Deployments are in `apps`, not core.
7. **Subresources are separate authorization targets** written `pods/log`, `pods/exec`, `deployments/scale`. Access to the parent grants nothing on them.
8. **`kubectl exec` needs `create` on `pods/exec`**, not `get`. So does `port-forward`, and `kubectl cp` needs it too.
9. **`kubectl get pods` needs `list`, not `get`.** `get` covers a single named object only.
10. **`list` returns full object bodies**, so `list secrets` reads every secret in scope even without `get`.
11. **`update` and `patch` are different verbs**, and almost every kubectl write path uses `patch`.
12. **`resourceNames` cannot restrict `create` or `deletecollection`**, and does not usefully restrict `list` or `watch`.
13. **There are no wildcards or prefixes in `resourceNames`.** Names are matched literally.
14. **`nonResourceURLs` only works in a ClusterRole bound with a ClusterRoleBinding**, and its verbs are HTTP methods.
15. **`roleRef` is immutable.** Delete and recreate, or use `kubectl auth reconcile`.
16. **A ServiceAccount subject needs `namespace` and no `apiGroup`; User and Group need `apiGroup: rbac.authorization.k8s.io` and no namespace.**
17. **With `--as`, a service account is written `system:serviceaccount:<namespace>:<name>`.**
18. **Aggregated ClusterRoles have their `rules` managed by a controller.** Edit the labelled contributors, never the aggregate.
19. **`aggregate-to-view` also reaches `edit` and `admin`**, because `view` itself is labelled `aggregate-to-edit`.
20. **`view` cannot read Secrets; `edit` and `admin` can.**
21. **`edit` in a namespace is as powerful as the strongest service account in that namespace**, because it can run a pod as that service account.
22. **`system:masters` bypasses RBAC entirely and has no binding**, so it cannot be revoked through the API.
23. **You cannot create a role granting permissions you do not hold**, unless you have `escalate` on roles or clusterroles.
24. **You cannot create a binding to a role you do not hold**, unless you have `bind` on that role. Constrain `bind` with `resourceNames`.
25. **`escalate` is equivalent to cluster-admin.** So is `impersonate` on groups without `resourceNames`.
26. **Binding anything to `system:authenticated` grants it to every service account in the cluster**, not only to humans.
27. **`kubectl auth can-i --list` reflects RBAC only.** It cannot see a Webhook authorizer, and it says nothing about admission.
28. **The Forbidden message contains the exact rule you need**: the user, verb, apiGroup, resource and namespace.
29. **`at the cluster scope` in a Forbidden message means you need a ClusterRoleBinding**, not a bigger Role.
30. **`--authorization-mode=AlwaysAllow` disables authorization entirely.** Check for it in any cluster you inherit.
31. **`kubectl create role` and `kubectl create rolebinding` with `--dry-run=client -o yaml`** is the fastest correct way to produce RBAC manifests under time pressure.
32. **Deleting a binding takes effect immediately.** There is no cache to wait for and no component to restart.

---

## Related Topics

- [Authentication](authentication.md)
- [Service Accounts](service-accounts.md)
- [kube-apiserver](kube-apiserver.md)
- [Kubernetes API](k8s-api.md)
- [Secrets](secrets.md)
- [ConfigMaps](configmaps.md)
- [Downward API](downward-api.md)
- [Network Policy](network-policy.md)
- [kubectl](kubectl.md)
- [kubelet](kubelet.md)
- [Controllers](controllers.md)
- [Control Plane Node](control-plane-node.md)
- [Kubernetes Architecture](k8s-architecture.md)
- [Pods](pods.md)
- [Deployments](deployments.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)

---

## Key Takeaways

1. **RBAC answers "may you", after authentication has answered "who are you".** A 403 proves your credential worked; a 401 means it did not. Never debug certificates when the error says Forbidden.
2. **Authorizers are chained and additive.** RBAC and Node only ever allow or abstain, so in a typical `Node,RBAC` cluster a request is denied only when nothing allowed it. There is no deny rule to write.
3. **Roles hold rules and grant nothing; bindings do the granting.** `roleRef` names exactly one role and is immutable, while `subjects` can be edited freely, which is why you should bind Groups rather than individual Users.
4. **Scope comes from the binding, not from the role.** A RoleBinding to a ClusterRole grants that role in one namespace only, and silently drops its cluster scoped rules. A ClusterRoleBinding grants everywhere, including in namespaces that do not exist yet.
5. **A rule matches only when apiGroup, resource, verb and (if present) resourceName all match.** The wrong `apiGroups` value is the most common cause of a rule that does nothing, and it fails silently.
6. **Subresources are separate targets.** `pods/log`, `pods/exec`, `pods/portforward` and `deployments/scale` must be granted explicitly, and the streaming ones need `create`, not `get`.
7. **`list` is not a weaker `get`; it returns every object in full.** Granting `list` on secrets is granting every secret value in scope.
8. **Wildcards age badly.** `apiGroups: ["*"]` silently absorbs every CRD installed in the future, and `verbs: ["*"]` includes `escalate`, `bind` and `impersonate`.
9. **Aggregated ClusterRoles are the supported way to extend `view`, `edit` and `admin`.** Label a contributing ClusterRole with `rbac.authorization.k8s.io/aggregate-to-view` and every existing binding picks it up, with no binding edits anywhere.
10. **Privilege escalation prevention means you cannot grant what you do not hold.** The `escalate` and `bind` verbs override it, and `escalate` should be treated as equivalent to cluster-admin.
11. **`edit` in a namespace inherits the powers of every service account in that namespace**, because it can create a pod running as one. Never bind cluster-admin to a namespaced service account.
12. **`kubectl auth can-i --list --as=<identity> -n <ns>` is the single most valuable RBAC command**, and audit logs with `authorization.k8s.io/decision` turn least privilege from guesswork into a mechanical derivation.

---

## References

- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Authorization Overview](https://kubernetes.io/docs/reference/access-authn-authz/authorization/)
- [Using Node Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/)
- [Webhook Mode](https://kubernetes.io/docs/reference/access-authn-authz/webhook/)
- [ABAC Mode](https://kubernetes.io/docs/reference/access-authn-authz/abac/)
- [Controlling Access to the Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)
- [Role Based Access Control Good Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [Kubernetes API Access Control Resources](https://kubernetes.io/docs/reference/kubernetes-api/authorization-resources/)
- [SelfSubjectAccessReview v1](https://kubernetes.io/docs/reference/kubernetes-api/authorization-resources/self-subject-access-review-v1/)
- [Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [kubectl auth Reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#auth)
- [Security Checklist](https://kubernetes.io/docs/concepts/security/security-checklist/)
