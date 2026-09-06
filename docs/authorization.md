# 🚦 Kubernetes Authorization: The Chain That Decides

Authentication proved *who* you are. Authorization decides *whether you may*. This document covers the authorizer chain as a whole: how `--authorization-mode` ordering works, every mode in depth (Node, RBAC, ABAC, Webhook, AlwaysAllow, AlwaysDeny), the request attribute model every authorizer sees, the Access Review APIs, impersonation, and how to debug a `403` down to the exact rule that failed. RBAC itself has its own deep dive in [rbac.md](rbac.md); this is the layer above it.

## 📋 Table of Contents
- [Where Authorization Sits](#where-authorization-sits)
- [Request Attributes](#request-attributes)
- [Resource vs Non-Resource Requests](#resource-vs-non-resource-requests)
- [The Authorizer Chain](#the-authorizer-chain)
- [Allow, Deny, and No Opinion](#allow-deny-and-no-opinion)
- [Configuring Authorization Modes](#configuring-authorization-modes)
- [Mode: Node](#mode-node)
- [Mode: RBAC](#mode-rbac)
- [Mode: ABAC](#mode-abac)
- [Mode: Webhook](#mode-webhook)
- [Mode: AlwaysAllow and AlwaysDeny](#mode-alwaysallow-and-alwaysdeny)
- [The AuthorizationConfiguration File](#the-authorizationconfiguration-file)
- [Subresource Authorization](#subresource-authorization)
- [The Access Review APIs](#the-access-review-apis)
- [kubectl auth can-i](#kubectl-auth-can-i)
- [Impersonation](#impersonation)
- [Ordering Pitfalls](#ordering-pitfalls)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Where Authorization Sits

Every request that reaches the API server passes through four gates in a fixed order. Authorization is the third.

```
                          kube-apiserver request pipeline
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  │   1. TLS TERMINATION                                                     │
  │      Client cert chain validated against --client-ca-file                │
  │      Failure: TLS handshake error, no HTTP response                      │
  │                              │                                           │
  │                              ▼                                           │
  │   2. AUTHENTICATION            ──►  produces user.Info                   │
  │      x509 / bearer token / OIDC / webhook / anonymous                    │
  │      Failure: 401 Unauthorized                                           │
  │                              │                                           │
  │                              ▼                                           │
  │   3. AUTHORIZATION           ◄──  THIS DOCUMENT                          │
  │      Node │ RBAC │ ABAC │ Webhook, evaluated in order                    │
  │      Failure: 403 Forbidden                                              │
  │                              │                                           │
  │                              ▼                                           │
  │   4. ADMISSION                                                           │
  │      Mutating phase, then validating phase                               │
  │      Failure: 400 / 403 / 422 depending on the controller                │
  │                              │                                           │
  │                              ▼                                           │
  │   5. VALIDATION + PERSIST to etcd                                        │
  │                                                                          │
  └──────────────────────────────────────────────────────────────────────────┘
```

Two facts about this boundary matter more than any other:

**Authorization has forgotten how you authenticated.** By the time an authorizer runs, the API server holds only a `user.Info` structure. It contains a username, a UID, a list of groups, and a map of extra fields. Whether that identity came from a client certificate, a projected service account token, or an OIDC provider is invisible to RBAC. This is why you cannot write a rule like "allow only if authenticated by certificate".

**Authorization never sees your YAML.** It sees a small attribute set derived from the HTTP verb and path. An authorizer cannot inspect `spec.containers[0].image`, cannot see that you set `privileged: true`, and cannot compare old and new object state. Anything that requires looking *inside* the object body is admission's job, not authorization's. See [admission-controllers.md](admission-controllers.md).

```
   WHAT AUTHORIZATION CAN SEE            WHAT IT CANNOT SEE
   ──────────────────────────            ──────────────────
   user, groups, UID, extra              the request body
   verb (get, create, delete...)         field values
   resource (pods, secrets...)           the previous object version
   subresource (log, exec...)            labels and annotations
   namespace                             which authn method was used
   apiGroup, apiVersion                  the client IP (mostly)
   resource name                         time of day
```

---

## Request Attributes

Before any authorizer is consulted, the API server reduces the incoming HTTP request to a canonical attribute set. Understanding this reduction is the single most useful skill in debugging authorization, because rules match attributes, not commands.

Consider a familiar command:

```bash
kubectl -n dev logs web-7d9f8c-abcde
```

The chain of translation is:

```
   kubectl -n dev logs web-7d9f8c-abcde
        │
        ▼  kubectl builds a REST path
   GET /api/v1/namespaces/dev/pods/web-7d9f8c-abcde/log
        │
        ▼  apiserver parses the path into attributes
   ┌───────────────────────────────────────────────────┐
   │  user            alice                            │
   │  groups          [developers, system:authenticated]│
   │  verb            get          ◄── from HTTP GET   │
   │  apiGroup        ""           ◄── core group      │
   │  apiVersion      v1                               │
   │  resource        pods                             │
   │  subresource     log          ◄── the tail segment│
   │  namespace       dev                              │
   │  name            web-7d9f8c-abcde                 │
   │  resourceRequest true                             │
   └───────────────────────────────────────────────────┘
```

### HTTP Verb to Kubernetes Verb Mapping

Kubernetes verbs are not HTTP methods. The mapping depends on whether the request targets a collection or an individual object.

| HTTP method | Target | Kubernetes verb |
|---|---|---|
| `GET`, `HEAD` | single object | `get` |
| `GET`, `HEAD` | collection | `list` |
| `GET`, `HEAD` | collection with `?watch=true` | `watch` |
| `POST` | collection | `create` |
| `PUT` | single object | `update` |
| `PATCH` | single object | `patch` |
| `DELETE` | single object | `delete` |
| `DELETE` | collection | `deletecollection` |

Three consequences that catch people out:

1. **`get` does not imply `list`.** A user with only `get` on pods can fetch `pods/web-1` by exact name but `kubectl get pods` will return `403` because that is a `list`.
2. **`watch` is separate from `list`.** `kubectl get pods --watch` and every controller informer need `watch` explicitly. Informers actually need `list` *and* `watch`, since they LIST to build the initial cache then WATCH for deltas.
3. **`deletecollection` is separate from `delete`.** `kubectl delete pods --all` issues a `deletecollection`. Granting `delete` alone does not permit it.

```
    kubectl get pods                 ──► verb: list
    kubectl get pods web-1           ──► verb: get
    kubectl get pods --watch         ──► verb: watch (and list)
    kubectl delete pod web-1         ──► verb: delete
    kubectl delete pods --all        ──► verb: deletecollection
    kubectl apply -f new.yaml        ──► verb: create   (if absent)
    kubectl apply -f existing.yaml   ──► verb: patch    (if present)
    kubectl edit deploy web          ──► verb: get, then patch
    kubectl scale deploy web         ──► verb: patch on deployments/scale
```

Note the `kubectl apply` line carefully. A user who may `create` but not `patch` can lay down a manifest the first time and then fail on every subsequent apply, which produces a confusing intermittent `403`. Server-side apply uses `patch` with the `application/apply-patch+yaml` content type, so it too requires `patch`.

---

## Resource vs Non-Resource Requests

Not every API server path names a Kubernetes object. Paths like `/healthz`, `/metrics`, `/version`, `/openapi/v2` and `/livez` are **non-resource requests**. They carry a different, much smaller attribute set.

```
   RESOURCE REQUEST                     NON-RESOURCE REQUEST
   ────────────────                     ────────────────────
   /api/v1/namespaces/dev/pods          /healthz
   /apis/apps/v1/deployments            /metrics
                                        /version
   attributes:                          attributes:
     verb, resource, subresource,         verb  (lowercased HTTP method)
     namespace, name, apiGroup            path
     resourceRequest = true               resourceRequest = false
```

The verb for a non-resource request is simply the lowercased HTTP method: `get`, `post`, `put`, `patch`, `delete`, `head`, `options`. There is no `list` or `watch`.

RBAC matches these with `nonResourceURLs` inside a `ClusterRole` only. A namespaced `Role` cannot grant non-resource access, because non-resource paths have no namespace.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: metrics-reader
rules:
  # nonResourceURLs is only valid in a ClusterRole.
  # The trailing * is a prefix match, not a glob: /metrics* matches
  # /metrics and /metrics/anything, but * is only allowed as the final character.
  - nonResourceURLs: ["/metrics", "/metrics/*"]
    verbs: ["get"]
```

The default `system:discovery` and `system:public-info-viewer` ClusterRoles exist precisely to grant the unauthenticated and authenticated groups access to discovery and health endpoints.

---

## The Authorizer Chain

The API server does not have one authorizer. It has an ordered list, built from `--authorization-mode`, and it walks that list until something takes a position.

```
  Request attributes
        │
        ▼
  ┌───────────────┐   no opinion   ┌───────────────┐   no opinion   ┌───────────────┐
  │  Authorizer 1 │ ─────────────► │  Authorizer 2 │ ─────────────► │  Authorizer 3 │
  │     Node      │                │     RBAC      │                │    Webhook    │
  └───────────────┘                └───────────────┘                └───────────────┘
        │                                 │                                 │
        │ ALLOW                           │ ALLOW                           │ ALLOW / DENY
        ▼                                 ▼                                 ▼
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │                        request proceeds to admission                        │
   └─────────────────────────────────────────────────────────────────────────────┘

   If every authorizer returns "no opinion", the chain falls off the end
   and the request is DENIED with 403.
```

The rules are short and absolute:

- The chain is walked **in the order given on the command line**.
- The **first authorizer to return ALLOW** short circuits the chain. Nothing after it runs.
- The **first authorizer to return DENY** short circuits the chain. Nothing after it runs.
- An authorizer that returns **no opinion** passes the decision to the next one.
- If the chain is exhausted with no opinion from anyone, the result is **deny**.

This last rule is what makes Kubernetes default-deny. There is no implicit allow anywhere.

---

## Allow, Deny, and No Opinion

This tri-state is the concept people most often get wrong, so it deserves its own treatment.

```
   ┌────────────────┬───────────────────────────────────────────────────────┐
   │ DECISION       │ MEANING                                               │
   ├────────────────┼───────────────────────────────────────────────────────┤
   │ Allow          │ "Yes, and stop asking." Chain terminates. Request     │
   │                │ moves to admission.                                   │
   ├────────────────┼───────────────────────────────────────────────────────┤
   │ Deny           │ "No, and stop asking." Chain terminates immediately.  │
   │                │ 403 returned. Later authorizers never get a vote.     │
   ├────────────────┼───────────────────────────────────────────────────────┤
   │ NoOpinion      │ "Not my department." Chain continues to the next      │
   │                │ authorizer. If nobody else allows, the request is     │
   │                │ denied by default at the end of the chain.            │
   └────────────────┴───────────────────────────────────────────────────────┘
```

### RBAC Can Never Deny

RBAC is a purely additive system. Every RBAC rule grants. There is no `deny` verb, no rule precedence, no ordering within RBAC, and no way to write "allow everything except secrets".

When RBAC does not find a matching rule, it returns **NoOpinion**, not Deny. This is a deliberate design choice: it lets you place RBAC before a Webhook authorizer and have the webhook still be consulted for requests RBAC does not cover.

The practical implication is severe and worth stating plainly:

> **You cannot revoke a permission in RBAC by adding a rule. You can only revoke it by removing every rule that grants it.**

If a user has three RoleBindings and one of them grants `secrets: get`, no fourth binding will take that away. You must find and edit the granting binding. This is why `kubectl auth can-i --list` and careful binding hygiene matter so much.

If you genuinely need deny semantics, your options are:

1. A **Webhook authorizer** placed before RBAC, which can return an explicit `denied: true`.
2. An **admission controller** or `ValidatingAdmissionPolicy`, which can reject based on the object body as well as the identity.
3. **Separate clusters or namespaces**, which is often the honest answer.

### The Deny Short-Circuit Is a Loaded Gun

Because Deny terminates the chain immediately, an authorizer placed early that denies aggressively can lock out even `cluster-admin`. A Webhook authorizer listed first that returns Deny on a bug, or that is unreachable and configured to fail closed, will make the cluster unmanageable. This is the primary reason `Node,RBAC` is the standard ordering and why webhooks usually go last.

---

## Configuring Authorization Modes

The flag lives on the API server. On a kubeadm cluster the API server runs as a static pod, so the flag lives in a manifest file on disk.

```bash
# The API server is a static pod. Edit the manifest, and the kubelet
# restarts it automatically when the file changes.
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        # Ordered, comma separated. Order is significant.
        # Node first so kubelet requests are handled by the purpose built
        # authorizer, then RBAC for everything else.
        - --authorization-mode=Node,RBAC
        # ...many other flags
```

Inspect the live value without editing anything:

```bash
# Straight from the running process
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep authorization

# Or from the manifest on the control plane node
sudo grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml
```

The default when the flag is omitted is `AlwaysAllow`, which is why every production installer sets it explicitly. kubeadm sets `Node,RBAC`.

### Common Orderings

| Setting | When it is appropriate |
|---|---|
| `Node,RBAC` | The standard. kubeadm default. Correct for almost every cluster. |
| `Node,RBAC,Webhook` | You need an external policy engine as a fallback for requests RBAC does not grant. |
| `Webhook,Node,RBAC` | You need the webhook to be able to *deny* things RBAC would allow. Dangerous, fail-closed webhooks can brick the cluster. |
| `RBAC` | Single node or no kubelets you care about constraining. Loses Node authorizer protection. |
| `AlwaysAllow` | Never in production. Effectively disables authorization entirely. |
| `AlwaysDeny` | Testing only. Nothing works, including the control plane's own components. |

---

## Mode: Node

The Node authorizer is a special purpose authorizer whose entire job is to constrain kubelets. It grants a kubelet exactly the API access it needs to run the pods assigned to *its own node*, and nothing more.

### How It Identifies a Kubelet

The Node authorizer only applies to requests from identities in the `system:nodes` group whose username has the form `system:node:<nodeName>`. That identity comes from the kubelet's client certificate.

```bash
# Look at a kubelet's own certificate identity on a worker node
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem \
  -noout -subject

# Output looks like:
#   subject=O = system:nodes, CN = system:node:worker-01
#            │                     │
#            └─ becomes the group  └─ becomes the username
```

If the CN does not match `system:node:<name>`, the Node authorizer returns NoOpinion and the request falls through to RBAC.

### The Graph

The Node authorizer maintains an in-memory graph of which objects a node legitimately needs, derived from the pods currently scheduled to it.

```
                          NODE AUTHORIZATION GRAPH
   ┌──────────────────────────────────────────────────────────────────────┐
   │                                                                      │
   │        Node: worker-01                                               │
   │             │                                                        │
   │             │ has pods scheduled to it                               │
   │             ▼                                                        │
   │      ┌─────────────┐        ┌─────────────┐                          │
   │      │  pod: web-1 │        │  pod: api-3 │                          │
   │      └─────────────┘        └─────────────┘                          │
   │             │                      │                                 │
   │    ┌────────┼────────┐             ├──────────────┐                  │
   │    ▼        ▼        ▼             ▼              ▼                  │
   │ ┌──────┐ ┌──────┐ ┌──────┐   ┌──────────┐  ┌──────────┐              │
   │ │Secret│ │Config│ │ PVC  │   │  Secret  │  │ Service  │              │
   │ │ tls  │ │ Map  │ │data-1│   │ api-cred │  │ Account  │              │
   │ └──────┘ └──────┘ └──────┘   └──────────┘  └──────────┘              │
   │                                                                      │
   │   worker-01 may read exactly these objects and no others.            │
   │   It cannot read Secret "tls" if pod web-1 moves to worker-02.       │
   └──────────────────────────────────────────────────────────────────────┘
```

### What a Kubelet May Do

**Read operations**, permitted only for objects linked to pods bound to that node:

| Resource | Constraint |
|---|---|
| `secrets` | Only those referenced by a pod on this node (volume, env, imagePullSecrets, service account token) |
| `configmaps` | Only those referenced by a pod on this node |
| `persistentvolumeclaims` | Only those bound to a pod on this node |
| `persistentvolumes` | Only those backing a PVC used on this node |
| `services` | Read access for the service environment variable injection |
| `endpoints` | Read access |
| `nodes` | Get its own Node object |
| `pods` | Get pods bound to this node |

**Write operations**:

| Resource | Constraint |
|---|---|
| `nodes` (create) | Its own Node object, at registration |
| `nodes/status` | Its own status only |
| `pods/status` | Only for pods on this node |
| `pods` (delete) | Only pods on this node |
| `events` | Create and update |
| `certificatesigningrequests` | Create for TLS bootstrap and rotation |
| `leases` in `kube-node-lease` | Its own lease, for node heartbeats |
| `csinodes` | Its own CSINode object |

### Node Authorizer Plus NodeRestriction

The Node authorizer answers "may this kubelet touch this object". It does **not** inspect the request body, so it cannot stop a kubelet from writing a malicious value into its own Node object, for example adding a label that attracts sensitive workloads, or removing a taint.

That gap is closed by the **NodeRestriction admission controller**, which does see the body.

```
   ┌───────────────────────────────────────────────────────────────────┐
   │  kubelet on worker-01 sends: PATCH /api/v1/nodes/worker-01        │
   │  body: add label "tier=secure"                                    │
   ├───────────────────────────────────────────────────────────────────┤
   │                                                                   │
   │  NODE AUTHORIZER                                                  │
   │    "Is worker-01 patching its own Node object?"  → yes → ALLOW    │
   │    (it cannot see the label being set)                            │
   │                          │                                        │
   │                          ▼                                        │
   │  NodeRestriction ADMISSION                                        │
   │    "Is this a label the kubelet is permitted to self-set?"        │
   │    tier=* is not in the allowed prefix list      → REJECT         │
   │                                                                   │
   └───────────────────────────────────────────────────────────────────┘
```

NodeRestriction enforces:

- A kubelet may only modify its own Node and Pod objects.
- A kubelet cannot add or remove labels outside the permitted set. It may self-set `kubernetes.io/hostname`, `topology.kubernetes.io/*`, `node.kubernetes.io/instance-type` and labels under `node-restriction.kubernetes.io/` are explicitly *blocked* from kubelet self-assignment so that schedulers can trust them.
- A kubelet cannot create mirror pods that reference service accounts or arbitrary secrets.
- A kubelet cannot delete its own Node object in ways that would let it re-register with different attributes.

The pairing is mandatory. Enabling `Node` in `--authorization-mode` without `NodeRestriction` in `--enable-admission-plugins` leaves a real privilege escalation path.

```yaml
# Both halves. Neither is sufficient alone.
- --authorization-mode=Node,RBAC
- --enable-admission-plugins=NodeRestriction,...
```

Verify both are on:

```bash
sudo grep -E 'authorization-mode|enable-admission-plugins' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## Mode: RBAC

RBAC is the workhorse. It is covered exhaustively in [rbac.md](rbac.md). For the purposes of the chain, the only things you need to hold in mind are:

- RBAC evaluates `Role`, `ClusterRole`, `RoleBinding` and `ClusterRoleBinding` objects stored in the API.
- It is **purely additive**. Union of all matching rules. No ordering, no precedence, no deny.
- It returns **Allow** on a match and **NoOpinion** otherwise.
- It is **dynamic**. Changing a RoleBinding takes effect within seconds, with no API server restart, because the authorizer watches those objects.
- The `system:masters` group **bypasses RBAC entirely**. It is hardcoded in the authorizer to return Allow for everything. This is the escape hatch that keeps `admin.conf` working even if you delete every RBAC object in the cluster.

```
   ┌──────────────────────────────────────────────────────────────────┐
   │  Is the user in group "system:masters"?                          │
   │       yes ──► ALLOW everything, no rule evaluation at all        │
   │       no  ──► evaluate bindings                                  │
   │                  match found ──► ALLOW                           │
   │                  no match    ──► NO OPINION (not deny)           │
   └──────────────────────────────────────────────────────────────────┘
```

---

## Mode: ABAC

Attribute Based Access Control is the original Kubernetes authorizer and is now effectively legacy. You should understand it because it appears in older clusters and in exam material, and because its shortcomings explain why RBAC exists.

### The Policy File

ABAC reads a static file at API server start. Each line is a self contained JSON object. It is **not** a JSON array; it is newline delimited JSON.

```json
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user": "admin", "namespace": "*", "resource": "*", "apiGroup": "*"}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user": "alice", "namespace": "dev", "resource": "pods", "readonly": true}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"group": "system:authenticated", "nonResourcePath": "/api", "readonly": true}}
{"apiVersion": "abac.authorization.kubernetes.io/v1beta1", "kind": "Policy", "spec": {"user": "kubelet", "resource": "pods", "readonly": true}}
```

Field meanings inside `spec`:

| Field | Meaning |
|---|---|
| `user` | Match this exact username. |
| `group` | Match this group. Use one of `user` or `group`, not both. |
| `namespace` | Namespace to match, or `*` for all. |
| `resource` | Resource type to match, or `*` for all. |
| `apiGroup` | API group to match, or `*` for all. |
| `readonly` | If `true`, the rule only permits `get`, `list` and `watch`. |
| `nonResourcePath` | Non-resource path to match, or `*`. |

Enable it with two flags:

```yaml
- --authorization-mode=ABAC,RBAC
- --authorization-policy-file=/etc/kubernetes/abac/policy.jsonl
```

The file must be mounted into the static pod:

```yaml
    volumeMounts:
      - name: abac-policy
        mountPath: /etc/kubernetes/abac
        readOnly: true
  volumes:
    - name: abac-policy
      hostPath:
        path: /etc/kubernetes/abac
        type: DirectoryOrCreate
```

### Why ABAC Is Legacy

| Problem | Consequence |
|---|---|
| Policy lives in a file, not the API | You cannot manage it with `kubectl`, GitOps, or RBAC-on-RBAC. |
| Requires an API server restart to change | Every permission change is a control plane operation. |
| Must be replicated by hand to every control plane node | HA clusters drift silently. |
| No tooling for introspection | There is no ABAC equivalent of `kubectl auth can-i --list`. |
| Flat matching, no composition | No roles, no reuse, no aggregation. |

ABAC does have one property RBAC lacks: because the policy is a file, it survives a completely broken etcd. That is the only reason to reach for it, and even then a static `system:masters` certificate is a better answer.

---

## Mode: Webhook

The Webhook authorizer delegates the decision to an external HTTPS service. It is how you integrate a corporate policy engine, a ticketing system, or a custom risk engine into the authorization path.

### The Flow

```
   ┌───────────┐   1. request   ┌────────────────┐
   │  client   │ ─────────────► │  kube-apiserver│
   └───────────┘                └────────────────┘
                                        │
                          2. POST SubjectAccessReview
                                        │
                                        ▼
                               ┌────────────────────┐
                               │  authz webhook svc │
                               │  (external HTTPS)  │
                               └────────────────────┘
                                        │
                          3. SubjectAccessReview
                             with status filled in
                                        │
                                        ▼
                               ┌────────────────────┐
                               │  allowed: true     │  ──► ALLOW
                               │  allowed: false    │
                               │    denied: true    │  ──► DENY (stops chain)
                               │    denied: false   │  ──► NO OPINION (continue)
                               └────────────────────┘
```

### Configuration

Two flags, plus a kubeconfig-shaped file describing how to reach the webhook.

```yaml
- --authorization-mode=Node,RBAC,Webhook
- --authorization-webhook-config-file=/etc/kubernetes/authz/webhook-kubeconfig.yaml
# How long an ALLOW decision is cached. Default 5m.
- --authorization-webhook-cache-authorized-ttl=5m
# How long a DENY or no-opinion decision is cached. Default 30s.
- --authorization-webhook-cache-unauthorized-ttl=30s
```

The config file uses the kubeconfig schema, but `clusters` describes the *webhook* and `users` describes the *API server's* client credentials for calling it.

```yaml
apiVersion: v1
kind: Config

clusters:
  # "cluster" here means the remote webhook service, not a Kubernetes cluster.
  - name: authz-webhook
    cluster:
      # CA that signed the webhook's serving certificate.
      certificate-authority: /etc/kubernetes/authz/webhook-ca.crt
      # Must be https. The API server will not talk plaintext here.
      server: https://authz.example.internal:8443/authorize

users:
  # These are the credentials the API SERVER presents to the webhook,
  # so the webhook can verify the caller really is the API server.
  - name: kube-apiserver
    user:
      client-certificate: /etc/kubernetes/authz/apiserver-client.crt
      client-key: /etc/kubernetes/authz/apiserver-client.key

contexts:
  - name: webhook
    context:
      cluster: authz-webhook
      user: kube-apiserver

current-context: webhook
```

### The Request Body

The API server POSTs a `SubjectAccessReview` with `spec` populated and `status` empty.

```json
{
  "apiVersion": "authorization.k8s.io/v1",
  "kind": "SubjectAccessReview",
  "spec": {
    "user": "alice",
    "uid": "a1b2c3d4-0000-1111-2222-333344445555",
    "groups": [
      "developers",
      "system:authenticated"
    ],
    "extra": {
      "authentication.kubernetes.io/pod-name": ["web-7d9f8c-abcde"]
    },
    "resourceAttributes": {
      "namespace": "production",
      "verb": "delete",
      "group": "apps",
      "version": "v1",
      "resource": "deployments",
      "subresource": "",
      "name": "payments-api"
    }
  }
}
```

For a non-resource request, `resourceAttributes` is replaced by `nonResourceAttributes`:

```json
{
  "apiVersion": "authorization.k8s.io/v1",
  "kind": "SubjectAccessReview",
  "spec": {
    "user": "alice",
    "groups": ["system:authenticated"],
    "nonResourceAttributes": {
      "path": "/metrics",
      "verb": "get"
    }
  }
}
```

### The Response Body

The webhook must echo back the whole object with `status` filled in. Three distinct responses are possible.

**Allow.** Chain stops, request proceeds.

```json
{
  "apiVersion": "authorization.k8s.io/v1",
  "kind": "SubjectAccessReview",
  "status": {
    "allowed": true
  }
}
```

**No opinion.** Chain continues to the next authorizer. Note `denied` is absent or false.

```json
{
  "apiVersion": "authorization.k8s.io/v1",
  "kind": "SubjectAccessReview",
  "status": {
    "allowed": false,
    "reason": "not covered by any policy in this engine"
  }
}
```

**Explicit deny.** Chain stops immediately. No later authorizer can rescue the request. This is the only way to get true deny semantics in Kubernetes authorization.

```json
{
  "apiVersion": "authorization.k8s.io/v1",
  "kind": "SubjectAccessReview",
  "status": {
    "allowed": false,
    "denied": true,
    "reason": "change freeze active for namespace production until 2026-01-02"
  }
}
```

The `reason` string is surfaced to the user in the `403` message, so use it to tell people something actionable.

### Operational Warnings

- **The webhook is on the hot path of every request.** Its latency is added to every API call that reaches it. Keep it in the low single digit milliseconds, and tune the cache TTLs.
- **If the webhook is unreachable, the authorizer returns an error**, which the API server treats as a denial. Placing an unreliable webhook early in the chain will take the cluster down, including the control plane's own components.
- **Cache TTLs hide revocations.** With the default 5 minute authorized TTL, revoking access can take 5 minutes to take effect.
- Always keep `RBAC` in the chain so that `system:masters` and the core control plane identities still work if the webhook fails.

---

## Mode: AlwaysAllow and AlwaysDeny

Two trivial authorizers, included for completeness and for testing.

**`AlwaysAllow`** returns Allow for every request from every identity. It is the default if `--authorization-mode` is not set at all, which is why every real installer sets the flag. If `AlwaysAllow` appears anywhere in your mode list, every authorizer after it is dead code, because the chain short circuits on the first Allow.

```
  --authorization-mode=AlwaysAllow,RBAC
                       ▲            ▲
                       │            └── never reached, ever
                       └── allows everything
```

**`AlwaysDeny`** returns Deny for every request. Because Deny short circuits, placing it anywhere means nothing after it runs either. It is used in tests and to prove the chain is wired correctly. A cluster with `AlwaysDeny` first is completely inoperable, including kubelets and controllers.

Neither belongs in a production `--authorization-mode`.

---

## The AuthorizationConfiguration File

Newer Kubernetes releases support expressing the authorizer chain in a structured file instead of a flag, which enables multiple webhooks and CEL based match conditions. This is the `--authorization-config` flag, and it is mutually exclusive with `--authorization-mode`.

```yaml
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthorizationConfiguration
authorizers:
  # Order in this list is the chain order, exactly like the flag.
  - type: Node
    name: node

  - type: RBAC
    name: rbac

  - type: Webhook
    name: change-freeze
    webhook:
      # Cache tuning, per webhook, which the flag form cannot do.
      authorizedTTL: 5m
      unauthorizedTTL: 30s
      timeout: 3s
      subjectAccessReviewVersion: v1
      # Fail closed on error. Use NoOpinion to fail open.
      failurePolicy: Deny
      connectionInfo:
        type: KubeConfigFile
        kubeConfigFile: /etc/kubernetes/authz/freeze-webhook.yaml
      # CEL expressions that decide whether to even CALL the webhook.
      # If none match, the authorizer returns NoOpinion without a network hop.
      # This is the main reason to prefer the config file form: it lets you
      # keep an expensive webhook off the hot path for most requests.
      matchConditions:
        - expression: "request.resourceAttributes.namespace == 'production'"
        - expression: "request.resourceAttributes.verb in ['create','update','patch','delete']"
```

Enable it:

```yaml
- --authorization-config=/etc/kubernetes/authz/authorization-config.yaml
# Do NOT also set --authorization-mode. The API server will refuse to start.
```

The advantages over the flag are meaningful: multiple distinct webhooks, per webhook timeouts and failure policies, and `matchConditions` that keep webhooks off the hot path for requests they do not care about.

---

## Subresource Authorization

Subresources are separate authorization targets, and this is where the most dangerous permissions hide.

```
   /api/v1/namespaces/dev/pods/web-1/exec
   └────────────────────────────┘ └──┘
              resource: pods      subresource: exec
```

In RBAC you name them with a slash:

```yaml
rules:
  # Read pod objects.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]

  # Read pod logs. This is a DIFFERENT permission from reading the pod.
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]

  # Shell into a running container. Effectively equal to the container's
  # full privileges. Grant with extreme care.
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]        # note: create, not get
```

### The Subresources That Matter

| Subresource | Verb | Why it matters |
|---|---|---|
| `pods/log` | `get` | Reads application logs, which routinely contain tokens and PII. |
| `pods/exec` | `create` | Full shell in the container. Equivalent to owning the workload. |
| `pods/attach` | `create` | Attaches to the main process stdio. Similar power to exec. |
| `pods/portforward` | `create` | Tunnels arbitrary TCP into the pod network, bypassing NetworkPolicy from the client's perspective. |
| `pods/ephemeralcontainers` | `update` | Injects a new container into a running pod, with a chosen image. A privilege escalation vector if the pod is privileged. |
| `pods/status` | `patch` | Lets a caller lie about pod health. |
| `nodes/proxy` | `get`, `create` | Proxies to the kubelet API. Reaches `/exec` on any pod on that node, bypassing pod-level RBAC entirely. Extremely dangerous. |
| `services/proxy` | `get`, `create` | Proxies arbitrary HTTP through a Service. |
| `deployments/scale` | `patch`, `update` | Scale without full deployment write. Useful for least privilege. |
| `*/status` | `patch`, `update` | Controllers need this; users almost never should. |
| `serviceaccounts/token` | `create` | Mints a token for that ServiceAccount. Direct identity theft. |

Two of these deserve emphasis:

**`nodes/proxy` is a cluster takeover primitive.** With it, a caller can reach the kubelet API on any node and execute in any container on that node, regardless of what pod-level RBAC says. Treat it as equivalent to `cluster-admin`.

**`serviceaccounts/token` with `create` lets the holder impersonate any ServiceAccount** they can name, including one bound to `cluster-admin`. Scope it with `resourceNames` if you must grant it at all.

```yaml
# If you must grant token creation, pin it to specific service accounts.
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    resourceNames: ["ci-deployer"]     # not "*"
    verbs: ["create"]
```

Note also that a wildcard on `resources` covers subresources of that pattern only if written as such. `resources: ["pods"]` does **not** grant `pods/exec`. But `resources: ["pods/*"]` grants every pod subresource, and `resources: ["*"]` grants everything including all subresources.

---

## The Access Review APIs

Kubernetes exposes authorization decisions as first class API objects, in the `authorization.k8s.io` group. These are **virtual** resources: you `create` them and read the answer out of the response. Nothing is persisted to etcd.

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │  SelfSubjectAccessReview   "May I do X?"                            │
   │     Anyone may create one. Always about the caller.                 │
   │     Backs `kubectl auth can-i`.                                     │
   ├─────────────────────────────────────────────────────────────────────┤
   │  SubjectAccessReview       "May THAT user do X?"                    │
   │     Requires privilege. Used by aggregated API servers and by       │
   │     admins auditing other identities.                               │
   ├─────────────────────────────────────────────────────────────────────┤
   │  SelfSubjectRulesReview    "What may I do in namespace N?"          │
   │     Returns the full rule set. Backs `kubectl auth can-i --list`.   │
   │     NOT a security boundary, see the warning below.                 │
   ├─────────────────────────────────────────────────────────────────────┤
   │  LocalSubjectAccessReview  "May THAT user do X in THIS namespace?"  │
   │     Namespaced variant, so it can be delegated per namespace.       │
   └─────────────────────────────────────────────────────────────────────┘
```

### SelfSubjectAccessReview

```yaml
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectAccessReview
spec:
  resourceAttributes:
    namespace: production
    verb: delete
    group: apps
    resource: deployments
    name: payments-api
```

```bash
kubectl create -f ssar.yaml -o yaml
```

The response comes back with a populated status:

```yaml
status:
  allowed: false
  reason: 'RBAC: no rules authorize user "alice" to delete resource "deployments"
    in API group "apps" in namespace "production"'
```

### SubjectAccessReview

This asks about *someone else*, so creating one is itself a privileged action.

```yaml
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  # The identity being asked about.
  user: alice
  groups:
    - developers
    - system:authenticated
  resourceAttributes:
    namespace: production
    verb: delete
    group: apps
    resource: deployments
```

The permission to create these is bundled in the `system:auth-delegator` ClusterRole, which is what you bind to an aggregated API server's ServiceAccount so it can ask the main API server to make decisions on its behalf. See [api-aggregation.md](api-aggregation.md).

### SelfSubjectRulesReview and Its Caveat

```yaml
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectRulesReview
spec:
  namespace: dev
```

The response enumerates the caller's rules in that namespace. There is an important warning attached to this API in upstream documentation, and it is worth restating:

> `SelfSubjectRulesReview` is **not** a reliable security boundary. It reports what RBAC grants. It cannot account for a Webhook authorizer, an admission controller, or any external authorizer that might deny the action. Use it as a convenience for building UIs and for debugging, never to make an authorization decision in your own code. Ask `SelfSubjectAccessReview` for the specific action instead.

The response also carries `incomplete: true` when an authorizer in the chain could not enumerate its rules, which is exactly what happens when a webhook is present.

---

## kubectl auth can-i

The everyday interface to `SelfSubjectAccessReview`.

```bash
# Basic question about yourself
kubectl auth can-i create deployments --namespace production

# Subresource, using the slash form
kubectl auth can-i create pods/exec --namespace dev

# A specific named object
kubectl auth can-i delete deployment/payments-api -n production

# Cluster scoped
kubectl auth can-i list nodes

# Non-resource URL
kubectl auth can-i get /metrics

# Across every namespace
kubectl auth can-i create pods --all-namespaces

# Enumerate everything you can do here (SelfSubjectRulesReview)
kubectl auth can-i --list --namespace dev

# Suppress the human output, use the exit code in scripts.
# Exit 0 = yes, exit 1 = no.
if kubectl auth can-i create deployments -n prod --quiet; then
  echo "permitted"
fi
```

Asking on behalf of someone else requires impersonation privileges:

```bash
# As a specific user
kubectl auth can-i list secrets -n prod --as alice

# As a user in specific groups
kubectl auth can-i list secrets -n prod --as alice --as-group developers

# As a service account. Note the full system: form.
kubectl auth can-i list secrets -n prod \
  --as system:serviceaccount:prod:builder

# Enumerate a service account's entire permission set. This is the single
# most useful audit command in Kubernetes.
kubectl auth can-i --list -n prod \
  --as system:serviceaccount:prod:builder
```

There is also `kubectl auth whoami`, which reports the identity the API server actually resolved for your credentials. It is the fastest way to confirm that your kubeconfig is presenting the certificate you think it is.

```bash
kubectl auth whoami

# ATTRIBUTE         VALUE
# Username          kubernetes-admin
# Groups            [kubeadm:cluster-admins system:authenticated]
```

---

## Impersonation

Impersonation lets an authorized principal make requests **as** another identity. It is implemented as a set of HTTP headers, and it is authorized like any other resource.

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │  1. Authenticate the REAL caller (admin) from their credentials.    │
   │  2. Check the REAL caller may impersonate the requested identity:   │
   │        users        verb create on resource "users"                 │
   │        groups       verb create on resource "groups"               │
   │        SAs          verb create on resource "serviceaccounts"       │
   │        extra fields verb create on "userextras/<key>"               │
   │  3. If permitted, DISCARD the real identity and re-authorize the    │
   │     request entirely as the impersonated identity.                  │
   └─────────────────────────────────────────────────────────────────────┘
```

Step 3 is the crucial one. After impersonation is approved, the original user's permissions are irrelevant. The request is evaluated purely as the target identity. This is what makes `kubectl auth can-i --as` an accurate simulation.

### The Headers

```
Impersonate-User: alice
Impersonate-Group: developers
Impersonate-Group: qa
Impersonate-Uid: a1b2c3d4-...
Impersonate-Extra-scopes: view
```

`kubectl` sets these for you from `--as`, `--as-group` (repeatable) and `--as-uid`.

### The RBAC To Permit It

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: impersonator
rules:
  # Impersonate any user
  - apiGroups: [""]
    resources: ["users"]
    verbs: ["impersonate"]

  # Impersonate any group
  - apiGroups: [""]
    resources: ["groups"]
    verbs: ["impersonate"]

  # Impersonate any service account
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    verbs: ["impersonate"]
```

Unrestricted impersonation is **equivalent to cluster-admin**, because the holder can simply impersonate a member of `system:masters`. Never grant the above as written.

Constrain it with `resourceNames`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: support-desk-impersonator
rules:
  # May only become these two specific low privilege service accounts.
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    resourceNames: ["readonly-support", "readonly-audit"]
    verbs: ["impersonate"]

  # Explicitly NOT granting users or groups, so system:masters is unreachable.
```

Impersonated requests are fully visible in the audit log, which records both the real user and the impersonated one. This is what makes impersonation acceptable for break-glass workflows: the accountability trail survives.

```json
{
  "user":            { "username": "ops-oncall" },
  "impersonatedUser":{ "username": "system:serviceaccount:prod:deployer" },
  "verb": "delete",
  "objectRef": { "resource": "deployments", "name": "payments-api" }
}
```

---

## Ordering Pitfalls

The chain order is not cosmetic. Four failure patterns recur.

**1. An Allow authorizer placed first neuters everything after it.**

```
  --authorization-mode=AlwaysAllow,RBAC       # RBAC is decorative
```

**2. A fail-closed webhook placed first can brick the cluster.**

If the webhook is down and `failurePolicy: Deny`, every request including those from the scheduler, controller manager and kubelets is denied. The cluster cannot self-heal because the components that would fix it are also denied. Recovery requires editing the static pod manifest on a control plane node by hand.

```
  --authorization-mode=Webhook,Node,RBAC     # webhook outage = cluster outage
```

**3. Removing Node from the chain silently widens kubelet permissions.**

If you set `--authorization-mode=RBAC` only, kubelets fall back to whatever the `system:node` ClusterRole grants, which is broad and not scoped per node. A single compromised worker can then read every Secret referenced by any pod anywhere.

**4. Enabling Node without NodeRestriction leaves the body unguarded.**

Covered above. The two must ship together.

The safe default remains:

```
  --authorization-mode=Node,RBAC
  --enable-admission-plugins=NodeRestriction,...
```

Add `Webhook` at the end if you need it, and give it `failurePolicy: NoOpinion` unless you have thought hard about the outage mode.

---

## Recipes

### Recipe: Audit Every Permission a ServiceAccount Holds

The highest value five minutes you can spend on a cluster.

```bash
NS=production
SA=deployer

# What can it do in its own namespace?
kubectl auth can-i --list -n "$NS" \
  --as "system:serviceaccount:${NS}:${SA}"

# The dangerous specifics, checked one by one.
for perm in \
  "create pods/exec" \
  "get secrets" \
  "list secrets" \
  "create serviceaccounts/token" \
  "get nodes/proxy" \
  "escalate roles" \
  "bind clusterroles" \
  "impersonate users"
do
  printf '%-32s %s\n' "$perm" \
    "$(kubectl auth can-i $perm -n "$NS" \
        --as "system:serviceaccount:${NS}:${SA}" 2>/dev/null)"
done
```

### Recipe: Find Every Identity That Can Read Secrets Cluster Wide

```bash
# Every ClusterRole that grants secrets read
kubectl get clusterroles -o json | jq -r '
  .items[]
  | select(.rules[]?
      | (.resources[]? | . == "secrets" or . == "*")
        and (.verbs[]? | . == "get" or . == "list" or . == "*"))
  | .metadata.name'

# Then find who is bound to each of those
kubectl get clusterrolebindings -o json | jq -r '
  .items[]
  | select(.roleRef.name == "secret-reader")
  | "\(.metadata.name): \(.subjects // [] | map(.kind + "/" + .name) | join(", "))"'
```

### Recipe: Prove the Node Authorizer Is Working

From a control plane node, impersonate a kubelet and confirm it cannot read a secret it has no business reading.

```bash
# Create a secret in a namespace with no pods on worker-02
kubectl create ns authz-test
kubectl -n authz-test create secret generic canary --from-literal=k=v

# Impersonate worker-02's kubelet identity
kubectl auth can-i get secrets/canary -n authz-test \
  --as system:node:worker-02 \
  --as-group system:nodes
# expected: no

# Now schedule a pod on worker-02 that mounts it, and re-check.
# The Node authorizer graph updates and the answer flips to yes.
```

### Recipe: A Minimal Working Authorization Webhook

A tiny reference implementation, useful for understanding the contract. Run it outside the cluster on the control plane node.

```python
#!/usr/bin/env python3
"""Minimal Kubernetes authorization webhook.

Denies deletes in the 'production' namespace during a change freeze,
and expresses no opinion about everything else so RBAC still decides.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

FROZEN_NAMESPACES = {"production"}
FROZEN_VERBS = {"delete", "deletecollection"}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        review = json.loads(self.rfile.read(length))
        attrs = review.get("spec", {}).get("resourceAttributes", {})

        if (attrs.get("namespace") in FROZEN_NAMESPACES
                and attrs.get("verb") in FROZEN_VERBS):
            # Explicit deny. This terminates the authorizer chain.
            status = {
                "allowed": False,
                "denied": True,
                "reason": "change freeze in effect for production",
            }
        else:
            # No opinion. RBAC and any later authorizer still get a vote.
            status = {"allowed": False}

        body = json.dumps({
            "apiVersion": "authorization.k8s.io/v1",
            "kind": "SubjectAccessReview",
            "status": status,
        }).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8443), Handler).serve_forever()
```

In production this must be served over TLS with a certificate the API server trusts, and it must be highly available, since it sits on the request path.

---

## Command Reference

```bash
# ---------- Inspecting the configured chain ----------
sudo grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n'

# ---------- Who am I ----------
kubectl auth whoami
kubectl config current-context
kubectl config view --minify

# ---------- Can I ----------
kubectl auth can-i VERB RESOURCE
kubectl auth can-i VERB RESOURCE -n NAMESPACE
kubectl auth can-i VERB RESOURCE/SUBRESOURCE
kubectl auth can-i VERB RESOURCE/NAME
kubectl auth can-i VERB RESOURCE --all-namespaces
kubectl auth can-i get /healthz
kubectl auth can-i --list -n NAMESPACE
kubectl auth can-i VERB RESOURCE --quiet          # exit code only

# ---------- Can THEY ----------
kubectl auth can-i VERB RESOURCE --as USER
kubectl auth can-i VERB RESOURCE --as USER --as-group GROUP
kubectl auth can-i VERB RESOURCE --as system:serviceaccount:NS:NAME
kubectl auth can-i --list --as system:serviceaccount:NS:NAME -n NS

# ---------- Access review objects directly ----------
kubectl create -f ssar.yaml -o yaml
kubectl api-resources --api-group=authorization.k8s.io

# ---------- Node authorizer identities ----------
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem \
  -noout -subject
kubectl get csr

# ---------- Verify NodeRestriction is enabled ----------
sudo grep enable-admission-plugins /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## Troubleshooting

### Reading a 403 Properly

The message is structured and tells you the exact attribute set that failed.

```
Error from server (Forbidden): deployments.apps "payments-api" is forbidden:
User "alice" cannot delete resource "deployments" in API group "apps"
in the namespace "production"
     │            │         │                 │                    │
     │            │         │                 │                    └ namespace
     │            │         │                 └ apiGroup
     │            │         └ resource
     │            └ verb
     └ the identity the API server resolved
```

Work the message left to right:

1. **Is the username what you expected?** If it says `system:anonymous`, your credentials were not accepted at all and this is really an authentication problem. Run `kubectl auth whoami`.
2. **Is the verb what you expected?** A `list` failure on what you thought was a `get` means you asked for a collection.
3. **Is the apiGroup right?** `deployments` in group `apps`, not `""`. A rule with `apiGroups: [""]` will never match Deployments.
4. **Is the namespace right?** A `Role` in `dev` does nothing for a request against `production`.

### Decision Tree

```
403 received
  │
  ├─ kubectl auth whoami shows the wrong identity?
  │     └─► authentication problem, not authorization.
  │         Check kubeconfig, cert expiry, token validity. See authentication.md
  │
  ├─ kubectl auth can-i --list -n NS shows the permission IS present?
  │     └─► something later in the chain denied it:
  │         - a Webhook authorizer returned denied: true
  │         - an admission controller rejected it (check the message wording:
  │           admission errors usually name the controller)
  │         Check the audit log for the authorization decision.
  │
  ├─ Permission is genuinely absent?
  │     └─► find or create the binding. Check:
  │         - Role vs ClusterRole scope
  │         - RoleBinding namespace matches the request namespace
  │         - subject kind and name spelled exactly right
  │         - apiGroup on the rule
  │         - subresource named separately
  │
  └─ It worked five minutes ago?
        └─► webhook cache TTL, expired client certificate,
            or a binding was removed. Check `kubectl get rolebindings -A`
            change history and cert expiry.
```

### The Subject Name Typo

The single most common RBAC bug is a subject that does not match any real identity. RBAC does not validate that a subject exists, so a typo produces a binding that silently grants nothing.

```yaml
subjects:
  # Wrong: ServiceAccount subjects need a namespace field.
  - kind: ServiceAccount
    name: deployer

  # Right:
  - kind: ServiceAccount
    name: deployer
    namespace: production

  # Wrong: User subjects must NOT use the system:serviceaccount form
  # unless you really mean to name it as a User.
  - kind: User
    name: deployer

  # Right, for a human whose cert CN is "alice":
  - kind: User
    name: alice
    apiGroup: rbac.authorization.k8s.io
```

Verify with impersonation, which is authoritative:

```bash
kubectl auth can-i get pods -n production \
  --as system:serviceaccount:production:deployer
```

### Finding the Decision in the Audit Log

If audit logging is enabled (see [audit-logging.md](audit-logging.md)), the authorization decision is recorded in the annotations of the event.

```bash
sudo jq -r 'select(.user.username == "alice")
  | select(.annotations["authorization.k8s.io/decision"] == "forbid")
  | [.requestReceivedTimestamp,
     .verb,
     .objectRef.resource,
     .objectRef.namespace,
     .annotations["authorization.k8s.io/reason"]]
  | @tsv' /var/log/kubernetes/audit.log
```

The `authorization.k8s.io/decision` annotation is either `allow` or `forbid`, and `authorization.k8s.io/reason` names the rule or authorizer responsible. On an allow it will look like `RBAC: allowed by ClusterRoleBinding "cluster-admin" of ClusterRole "cluster-admin" to Group "system:masters"`, which tells you exactly which binding did it.

### API Server Will Not Start After an Authorization Change

Because the API server is a static pod, a bad flag means it never comes up and `kubectl` stops working entirely. Recover on the control plane node:

```bash
# The kubelet still logs the container's failure
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1)

# Or the kubelet's own view
sudo journalctl -u kubelet -n 100 --no-pager

# Fix the manifest. The kubelet re-reads it on write.
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Classic causes: setting both `--authorization-mode` and `--authorization-config`, pointing `--authorization-webhook-config-file` at a path that is not mounted into the pod, or a typo in a mode name (the list is case sensitive: `RBAC`, not `rbac`).

The missing-mount case is worth calling out because it is so common. Adding a flag that references a file on the host does nothing unless you also add the `volume` and `volumeMount`:

```yaml
    volumeMounts:
      - name: authz-config
        mountPath: /etc/kubernetes/authz
        readOnly: true
  volumes:
    - name: authz-config
      hostPath:
        path: /etc/kubernetes/authz
        type: DirectoryOrCreate
```

---

## Exam and Interview Traps

1. **"How do you deny a permission in RBAC?"** You do not. RBAC is additive and has no deny. You remove the granting binding, or you use a Webhook authorizer or admission control.

2. **A user has `get` on pods but `kubectl get pods` fails.** `get` covers a named object. Listing a collection is the `list` verb.

3. **What is the difference between no opinion and deny?** No opinion continues the chain; deny terminates it. RBAC only ever returns allow or no opinion.

4. **Which comes first, authentication or authorization?** Authentication. Authorization only ever sees a resolved `user.Info`.

5. **`--authorization-mode=AlwaysAllow,RBAC`, what happens?** RBAC never runs. The first Allow short circuits.

6. **Why do you need NodeRestriction if you already have the Node authorizer?** The authorizer cannot see the request body. NodeRestriction is admission and can, so it stops a kubelet from setting labels or taints on its own Node object.

7. **A ServiceAccount can `create` on `pods/exec` but has no `get` on `pods`. Can it exec?** Yes, if it knows the pod name. `exec` is authorized independently of reading the pod object.

8. **Which single permission most resembles cluster-admin without looking like it?** `nodes/proxy`, because it reaches the kubelet API and can exec into any pod on the node. `escalate` on roles and `impersonate` on users are the other two.

9. **`kubectl auth can-i --list` says yes but the action fails.** `SelfSubjectRulesReview` only reports RBAC. A webhook authorizer or an admission controller can still refuse. Also check `incomplete: true` in the response.

10. **What identity does `kubectl auth can-i --as X` evaluate?** Purely X. Your own permissions are used only to authorize the impersonation itself, then discarded.

11. **Where does the `system:masters` group get its power?** It is hardcoded in the RBAC authorizer, not granted by any object. You cannot remove it with `kubectl`, which is why `admin.conf` is a break-glass credential that must be protected like a root password.

12. **`kubectl apply` works the first time then 403s.** First apply is `create`, subsequent applies are `patch`. Grant both.

13. **Can a `Role` grant access to `/metrics`?** No. Non-resource URLs are cluster scoped and only valid in a `ClusterRole`.

14. **Does `resources: ["pods"]` grant `pods/log`?** No. Subresources must be named explicitly, or matched by `pods/*`.

---

## Related Topics

- [rbac.md](rbac.md) for the full treatment of Roles, ClusterRoles and bindings
- [authentication.md](authentication.md) for how identity is established before this layer runs
- [admission-controllers.md](admission-controllers.md) for the gate after this one, which can see the object body
- [admission-webhooks.md](admission-webhooks.md) for authoring mutating and validating webhooks
- [service-accounts.md](service-accounts.md) for in-cluster workload identity
- [certificates.md](certificates.md) for how CN and O become username and groups
- [audit-logging.md](audit-logging.md) for recording every authorization decision
- [cluster-hardening.md](cluster-hardening.md) for the overall security posture
- [kube-apiserver.md](kube-apiserver.md) for the component that hosts this pipeline
- [kubelet.md](kubelet.md) for the client the Node authorizer exists to constrain

---

## Key Takeaways

- Authorization is the third gate: TLS, then authentication, then authorization, then admission.
- Authorizers see a small attribute set derived from the HTTP verb and path. They never see the object body.
- The chain is ordered. First Allow wins, first Deny wins, no opinion continues, exhausted chain means deny.
- RBAC is additive and can never deny. It returns allow or no opinion, never deny.
- `Node,RBAC` is the correct default, and `Node` must be paired with the `NodeRestriction` admission plugin.
- Subresources are separate permissions. `pods/exec`, `nodes/proxy` and `serviceaccounts/token` are effectively privilege escalation grants.
- HTTP method does not equal Kubernetes verb. `get` is not `list`, `delete` is not `deletecollection`.
- Non-resource URLs can only be granted by a `ClusterRole`.
- `kubectl auth can-i --as` is the authoritative way to test someone else's access, because impersonation re-authorizes entirely as the target identity.
- `system:masters` bypasses RBAC in code. Treat `admin.conf` as a root credential.
- A fail-closed webhook early in the chain is a cluster-wide outage waiting to happen.

---

## References

- [Authorization Overview](https://kubernetes.io/docs/reference/access-authn-authz/authorization/)
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Using Node Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/)
- [Using ABAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/abac/)
- [Webhook Mode](https://kubernetes.io/docs/reference/access-authn-authz/webhook/)
- [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [User Impersonation](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#user-impersonation)
- [kube-apiserver Command Line Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Certificate Signing Requests](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
- [kubectl auth](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/)
