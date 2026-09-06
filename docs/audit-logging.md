# 📜 Kubernetes Audit Logging: The Forensic Record

Audit logging is the only mechanism that answers "who did this, when, from where, and what exactly changed". Without it, a cluster compromise is unreconstructible. This document covers the four levels and four stages, writing a production audit policy that captures what matters without drowning etcd, enabling it on a kubeadm cluster including the volume mounts everyone forgets, dissecting a real audit event field by field, and the `jq` queries that turn a log file into an investigation.

## 📋 Table of Contents
- [Why Audit Logging Exists](#why-audit-logging-exists)
- [Where Audit Sits in the Request Pipeline](#where-audit-sits-in-the-request-pipeline)
- [The Four Levels](#the-four-levels)
- [The Four Stages](#the-four-stages)
- [The Policy Object](#the-policy-object)
- [Rule Matching and Ordering](#rule-matching-and-ordering)
- [A Production Policy](#a-production-policy)
- [Backends](#backends)
- [Enabling on kubeadm](#enabling-on-kubeadm)
- [Anatomy of an Audit Event](#anatomy-of-an-audit-event)
- [Investigation Queries](#investigation-queries)
- [Volume and Disk Sizing](#volume-and-disk-sizing)
- [Shipping Logs Off the Node](#shipping-logs-off-the-node)
- [What Audit Does Not Capture](#what-audit-does-not-capture)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why Audit Logging Exists

Consider a real incident. A production Deployment is deleted at 03:00. The questions you must answer, in order:

```
   1. WHO deleted it?                  ── an identity, not an IP
   2. WHEN exactly?                    ── to the millisecond
   3. FROM WHERE?                      ── source IP, user agent
   4. WAS IT AUTHORIZED?               ── which RBAC rule permitted it
   5. WAS IT IMPERSONATED?             ── real user vs effective user
   6. WHAT ELSE did they touch?        ── the full session
   7. WHAT DID THE OBJECT LOOK LIKE?   ── for reconstruction
```

Nothing else in Kubernetes answers these. Events expire. Container logs are on the wrong side of the trust boundary. `kubectl get` shows current state, not history. etcd's revision history is compacted away. The audit log is the record.

It is also frequently a compliance requirement: PCI DSS, SOC 2, HIPAA and ISO 27001 all expect an immutable record of administrative actions on systems handling regulated data.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Audit logging is OFF by default on a kubeadm cluster.               │
   │  You have no forensic record until you turn it on.                   │
   └──────────────────────────────────────────────────────────────────────┘
```

---

## Where Audit Sits in the Request Pipeline

Audit is not a gate. It is an observer, and it observes at multiple points.

```
  ┌───────────────────────────────────────────────────────────────────────┐
  │                                                                       │
  │   client request                                                      │
  │        │                                                              │
  │        ▼                                                              │
  │   ┌─────────────────────────────────────────────┐                     │
  │   │  audit stage: RequestReceived               │  ◄── event 1        │
  │   │  logged BEFORE anything is evaluated        │                     │
  │   └─────────────────────────────────────────────┘                     │
  │        │                                                              │
  │        ▼                                                              │
  │   AUTHENTICATION ──► 401 still produces an audit event                │
  │        │                                                              │
  │        ▼                                                              │
  │   AUTHORIZATION  ──► adds authorization.k8s.io/decision annotation    │
  │        │                                                              │
  │        ▼                                                              │
  │   ADMISSION      ──► adds admission annotations (PodSecurity, etc)    │
  │        │                                                              │
  │        ▼                                                              │
  │   ┌─────────────────────────────────────────────┐                     │
  │   │  audit stage: ResponseStarted               │  ◄── event 2        │
  │   │  long running requests only (watch, exec)   │                     │
  │   └─────────────────────────────────────────────┘                     │
  │        │                                                              │
  │        ▼                                                              │
  │   handler runs, object persisted to etcd                              │
  │        │                                                              │
  │        ▼                                                              │
  │   ┌─────────────────────────────────────────────┐                     │
  │   │  audit stage: ResponseComplete              │  ◄── event 3        │
  │   │  the one you almost always want              │                     │
  │   └─────────────────────────────────────────────┘                     │
  │                                                                       │
  └───────────────────────────────────────────────────────────────────────┘
```

Crucially, **a failed request is still audited**. A `403` from RBAC, a `401` from bad credentials, and a rejection from PodSecurity all produce events. Failed attempts are often more interesting than successful ones.

---

## The Four Levels

The level controls how much of the request is recorded. It is the primary volume-versus-value dial.

```
   ┌───────────────────┬──────────────────────────────────────────────────┐
   │ LEVEL             │ WHAT IS RECORDED                                 │
   ├───────────────────┼──────────────────────────────────────────────────┤
   │ None              │ Nothing. The request is dropped from the log.    │
   ├───────────────────┼──────────────────────────────────────────────────┤
   │ Metadata          │ user, verb, resource, namespace, timestamp,      │
   │                   │ source IP, response code.                        │
   │                   │ NO request body, NO response body.               │
   │                   │ Small. The right default for most rules.         │
   ├───────────────────┼──────────────────────────────────────────────────┤
   │ Request           │ Metadata + the full request body.                │
   │                   │ Shows exactly what was submitted.                │
   │                   │ Large. Use selectively.                          │
   ├───────────────────┼──────────────────────────────────────────────────┤
   │ RequestResponse   │ Metadata + request body + response body.         │
   │                   │ Complete reconstruction of the change.           │
   │                   │ Very large. Never apply to secrets.              │
   └───────────────────┴──────────────────────────────────────────────────┘
```

Rough size per event:

| Level | Typical size |
|---|---|
| `Metadata` | 1 to 2 KB |
| `Request` | 3 to 20 KB |
| `RequestResponse` | 6 to 50 KB |

The critical safety rule:

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  NEVER use Request or RequestResponse on secrets or configmaps.      │
   │  The body contains the secret data. Your audit log becomes a         │
   │  plaintext credential store, usually with weaker access controls     │
   │  than etcd itself.                                                    │
   └──────────────────────────────────────────────────────────────────────┘
```

Always place an explicit `Metadata`-level rule for `secrets` **before** any broad `RequestResponse` rule.

---

## The Four Stages

A single request can generate up to three events. `omitStages` controls which are written.

| Stage | When | Usefulness |
|---|---|---|
| `RequestReceived` | The API server received the request, before any processing | Low. Doubles volume for almost no information. Usually omitted. |
| `ResponseStarted` | Response headers sent, body still streaming | Only meaningful for long-running requests: `watch`, `exec`, `port-forward`, `attach`. |
| `ResponseComplete` | Response finished | **The one you want.** Contains the outcome. |
| `Panic` | The API server panicked handling the request | Rare, always keep. |

The standard optimisation, applied globally at the top of the policy:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
# Applies to every rule unless a rule overrides it.
# Halves log volume immediately.
omitStages:
  - RequestReceived
```

Note that for `exec` and `port-forward`, `ResponseComplete` fires only when the session **ends**. A long-lived shell produces its `ResponseStarted` event immediately and its `ResponseComplete` event potentially hours later. If you want to know a shell was opened *now*, you need `ResponseStarted` for those resources.

---

## The Policy Object

A YAML file on the control plane node. Like `EncryptionConfiguration`, it is not an API object.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# Global stage omission.
omitStages:
  - RequestReceived

# Redact managedFields, which is enormous boilerplate on every object
# and never useful in an investigation.
omitManagedFields: true

rules:
  - level: Metadata
    # ── SUBJECT MATCHERS ───────────────────────────────────────────
    users: ["system:kube-scheduler"]
    userGroups: ["system:authenticated"]
    # Match the EFFECTIVE user during impersonation.
    # (The real user is still recorded in the event.)

    # ── VERB MATCHER ───────────────────────────────────────────────
    verbs: ["create", "update", "patch", "delete"]

    # ── RESOURCE MATCHER ───────────────────────────────────────────
    resources:
      - group: ""                    # core group
        resources: ["pods", "pods/exec"]
        resourceNames: ["specific-pod"]   # optional, narrows further
      - group: "apps"
        resources: ["deployments"]

    # ── SCOPE MATCHERS ─────────────────────────────────────────────
    namespaces: ["production"]
    # or: omit for all namespaces

    # ── NON-RESOURCE MATCHER ───────────────────────────────────────
    nonResourceURLs: ["/healthz*", "/metrics"]

    # ── PER-RULE STAGE OVERRIDE ────────────────────────────────────
    omitStages: ["RequestReceived"]
```

Matcher semantics:

- Omitting a matcher means "match anything" for that dimension.
- Within one matcher, values are OR'd.
- Across matchers, they are AND'd. A rule with `users` and `verbs` matches only requests satisfying both.
- `resources[].group: ""` is the core API group. `apps`, `batch`, `rbac.authorization.k8s.io` and so on are named.
- `resources: ["pods/*"]` matches every pod subresource. `resources: ["pods"]` does **not** match `pods/exec`.

---

## Rule Matching and Ordering

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Rules are evaluated TOP TO BOTTOM.                                  │
   │  The FIRST rule that matches determines the level.                   │
   │  Evaluation stops there.                                             │
   │  A request matching NO rule is NOT logged at all.                    │
   └──────────────────────────────────────────────────────────────────────┘
```

This makes ordering the entire design of a policy:

```
   ┌───────────────────────────────────────────────────────┐
   │  1. level: None    ── drop the noise                  │
   │                       health checks, leases, watches  │
   ├───────────────────────────────────────────────────────┤
   │  2. level: Metadata ── protect the sensitive          │
   │                        secrets, configmaps            │
   │                        MUST come before step 3        │
   ├───────────────────────────────────────────────────────┤
   │  3. level: RequestResponse ── capture the important   │
   │                               RBAC changes, workload  │
   │                               mutations               │
   ├───────────────────────────────────────────────────────┤
   │  4. level: Metadata ── the catch-all                  │
   │                        everything else                │
   └───────────────────────────────────────────────────────┘
```

Get step 2 wrong and you leak every Secret into the log. This ordering is not stylistic; it is a security control.

---

## A Production Policy

A complete, annotated policy suitable for a real cluster. Read the comments; each block exists for a specific reason.

```yaml
# /etc/kubernetes/audit/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# Halves volume. RequestReceived tells you a request arrived; the
# ResponseComplete event tells you that AND what happened.
omitStages:
  - RequestReceived

# managedFields is server-side-apply bookkeeping. Enormous, never useful here.
omitManagedFields: true

rules:

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 1: DROP THE NOISE
#  These would otherwise be 90%+ of all events and drown everything else.
# ═══════════════════════════════════════════════════════════════════════

  # Node and controller heartbeats. Constant, high frequency, zero value.
  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # Endpoint churn from the endpoints controller.
  - level: None
    users: ["system:kube-controller-manager"]
    verbs: ["get", "update"]
    resources:
      - group: ""
        resources: ["endpoints"]
      - group: "discovery.k8s.io"
        resources: ["endpointslices"]

  # Kubelet reporting node status, every 10 seconds, per node.
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "update", "patch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  # Health, readiness and discovery endpoints. Constant polling.
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/livez*"
      - "/readyz*"
      - "/version"
      - "/openapi/*"
      - "/apis"
      - "/apis/*"
      - "/api"
      - "/api/*"

  # Prometheus scraping. Frequent and uninteresting.
  - level: None
    users: ["system:serviceaccount:monitoring:prometheus"]
    nonResourceURLs: ["/metrics"]

  # Watch establishment from control plane components. Every informer
  # in the cluster does this on startup and after every disconnect.
  - level: None
    users:
      - "system:kube-controller-manager"
      - "system:kube-scheduler"
      - "system:serviceaccount:kube-system:endpoint-controller"
    verbs: ["watch", "list"]

  # The authorization delegation calls made by aggregated API servers.
  - level: None
    resources:
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews", "selfsubjectaccessreviews"]

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 2: SENSITIVE RESOURCES, METADATA ONLY
#  MUST appear before any RequestResponse rule, or bodies leak.
# ═══════════════════════════════════════════════════════════════════════

  # Secrets: record WHO read WHICH secret, never the contents.
  # This is the single most valuable rule in the policy.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: ""
        resources: ["serviceaccounts/token"]

  # CSRs contain key material in flight.
  - level: Metadata
    resources:
      - group: "certificates.k8s.io"
        resources: ["certificatesigningrequests"]

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 3: SECURITY CRITICAL, FULL CAPTURE
# ═══════════════════════════════════════════════════════════════════════

  # Every RBAC change, with full before and after. If someone grants
  # themselves cluster-admin, this rule is how you find out.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources:
          - "roles"
          - "rolebindings"
          - "clusterroles"
          - "clusterrolebindings"

  # Admission policy changes. A webhook or policy being deleted or
  # weakened is a strong compromise indicator.
  - level: RequestResponse
    resources:
      - group: "admissionregistration.k8s.io"
        resources: ["*"]

  # Namespace security label changes. Someone downgrading a namespace
  # from restricted to privileged is a red flag.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["namespaces"]

  # Interactive access into containers. Capture ResponseStarted too,
  # because ResponseComplete for a shell only fires when it CLOSES.
  - level: Request
    omitStages: []          # override the global omission
    resources:
      - group: ""
        resources:
          - "pods/exec"
          - "pods/attach"
          - "pods/portforward"
          - "pods/ephemeralcontainers"

  # Node proxy access reaches the kubelet API directly and can exec
  # into any pod on the node. Effectively cluster-admin.
  - level: Request
    resources:
      - group: ""
        resources: ["nodes/proxy", "services/proxy"]

  # Anything done via impersonation deserves full capture.
  # (Impersonation is recorded in every event, but this ensures
  #  the body is captured for privileged targets.)
  - level: RequestResponse
    userGroups: ["system:masters"]
    verbs: ["create", "update", "patch", "delete"]

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 4: WORKLOAD MUTATIONS
# ═══════════════════════════════════════════════════════════════════════

  # Full capture of workload changes: what image, what security context,
  # what replica count. This is what lets you reconstruct a deployment.
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["pods", "services", "persistentvolumeclaims"]
      - group: "apps"
        resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
      - group: "batch"
        resources: ["jobs", "cronjobs"]
      - group: "networking.k8s.io"
        resources: ["networkpolicies", "ingresses"]
      - group: "policy"
        resources: ["poddisruptionbudgets"]

  # Reads of workloads: metadata only. Knowing someone listed pods is
  # useful; the response body is not worth the disk.
  - level: Metadata
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
      - group: "apps"
      - group: "batch"

# ═══════════════════════════════════════════════════════════════════════
#  SECTION 5: CATCH-ALL
#  Anything not matched above. Without this, unmatched requests are
#  silently dropped and you have a blind spot.
# ═══════════════════════════════════════════════════════════════════════

  - level: Metadata
```

That final catch-all is not optional. A request matching no rule is not logged, so omitting it creates gaps precisely where you have not thought about the traffic.

---

## Backends

Two backends, configurable independently and simultaneously.

### Log Backend

Writes JSON to a file on the control plane node. Simple, reliable, no external dependency, and what you should start with.

```yaml
- --audit-log-path=/var/log/kubernetes/audit/audit.log
- --audit-log-maxage=30          # days to retain
- --audit-log-maxbackup=10       # rotated files to keep
- --audit-log-maxsize=100        # megabytes before rotating
- --audit-log-format=json        # json or legacy; always json
- --audit-log-compress=true      # gzip rotated files
```

Retention arithmetic worth doing before you enable it:

```
   maxsize × (maxbackup + 1) = maximum disk consumed
   100 MB  × (10 + 1)        = 1.1 GB
```

`maxage` and `maxbackup` are both ceilings; whichever triggers first wins. Setting `maxbackup=0` means unlimited files, which will eventually fill the disk and take the control plane down. Always set it.

A special case: `--audit-log-path=-` writes to stdout, which on a static pod means the events land in the container log and can be collected by your normal log agent. That is a reasonable pattern if you already ship container logs.

### Webhook Backend

POSTs events to an external service. Use it in addition to the file backend, never instead of it, because the network is not guaranteed.

```yaml
- --audit-webhook-config-file=/etc/kubernetes/audit/webhook-config.yaml
# batch : buffer and send in batches (default, use this)
# blocking : send synchronously, blocks the API request
- --audit-webhook-mode=batch
- --audit-webhook-batch-max-size=400
- --audit-webhook-batch-max-wait=30s
- --audit-webhook-batch-buffer-size=10000
- --audit-webhook-initial-backoff=10s
```

```yaml
# /etc/kubernetes/audit/webhook-config.yaml
apiVersion: v1
kind: Config
clusters:
  - name: audit-sink
    cluster:
      certificate-authority: /etc/kubernetes/audit/sink-ca.crt
      server: https://audit-sink.example.internal:9443/events
users:
  - name: kube-apiserver
    user:
      client-certificate: /etc/kubernetes/audit/apiserver-client.crt
      client-key: /etc/kubernetes/audit/apiserver-client.key
contexts:
  - name: audit
    context:
      cluster: audit-sink
      user: kube-apiserver
current-context: audit
```

`--audit-webhook-mode=blocking` makes every API request wait for the audit sink to acknowledge. If the sink is slow, your API server is slow. If the sink is down, your API server may stall. Use `batch`.

---

## Enabling on kubeadm

The most error-prone part of this document. Three things must all be correct: the policy file, the flags, and the volume mounts.

### Step 1: Create the Policy and Log Directory

```bash
sudo mkdir -p /etc/kubernetes/audit
sudo mkdir -p /var/log/kubernetes/audit
sudo chmod 700 /var/log/kubernetes/audit

# Write the policy from the section above.
sudo vi /etc/kubernetes/audit/audit-policy.yaml
sudo chmod 600 /etc/kubernetes/audit/audit-policy.yaml
```

### Step 2: Edit the API Server Manifest

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml \
        /root/kube-apiserver.yaml.pre-audit.bak
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
        # ── FLAGS ────────────────────────────────────────────────────
        - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
        - --audit-log-path=/var/log/kubernetes/audit/audit.log
        - --audit-log-maxage=30
        - --audit-log-maxbackup=10
        - --audit-log-maxsize=100
        - --audit-log-format=json
        - --audit-log-compress=true
        # ...existing flags unchanged...

      volumeMounts:
        # ── MOUNT 1: the policy, read only ──────────────────────────
        - name: audit-policy
          mountPath: /etc/kubernetes/audit
          readOnly: true
        # ── MOUNT 2: the log directory, READ WRITE ──────────────────
        #    This is the one people forget. Without it, the API server
        #    cannot create the log file and will not start.
        - name: audit-log
          mountPath: /var/log/kubernetes/audit
          readOnly: false
        # ...existing mounts unchanged...

  volumes:
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit
        type: DirectoryOrCreate
    - name: audit-log
      hostPath:
        path: /var/log/kubernetes/audit
        type: DirectoryOrCreate
    # ...existing volumes unchanged...
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  THE TWO CLASSIC MISTAKES                                            │
   │                                                                      │
   │  1. Adding the flags but not the volumes.                            │
   │     Result: the API server cannot find the policy file and           │
   │     crashloops. kubectl stops working entirely.                      │
   │                                                                      │
   │  2. Mounting the log directory readOnly: true.                       │
   │     Result: the API server cannot write and crashloops.              │
   │     The log mount MUST be writable.                                  │
   └──────────────────────────────────────────────────────────────────────┘
```

### Step 3: Verify

Saving the manifest restarts the API server.

```bash
# Wait for it to come back.
until kubectl get --raw /healthz 2>/dev/null; do sleep 2; done; echo

# Events should be arriving immediately.
sudo ls -la /var/log/kubernetes/audit/
sudo tail -f /var/log/kubernetes/audit/audit.log | jq -c \
  '{t:.requestReceivedTimestamp, u:.user.username, v:.verb, r:.objectRef.resource}'

# Generate a distinctive event and find it.
kubectl create namespace audit-canary
sudo grep audit-canary /var/log/kubernetes/audit/audit.log | jq
kubectl delete namespace audit-canary
```

---

## Anatomy of an Audit Event

A single `ResponseComplete` event for a Deployment deletion, dissected.

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",

  "level": "RequestResponse",
  "auditID": "d4f1c9a3-7b21-4e88-9c05-1a2b3c4d5e6f",
  "stage": "ResponseComplete",

  "requestURI": "/apis/apps/v1/namespaces/production/deployments/payments-api",
  "verb": "delete",

  "user": {
    "username": "alice@example.com",
    "uid": "a1b2c3d4-0000-1111-2222-333344445555",
    "groups": [
      "platform-engineers",
      "system:authenticated"
    ],
    "extra": {
      "authentication.kubernetes.io/credential-id": ["X509SHA256=9f2a..."]
    }
  },

  "impersonatedUser": {
    "username": "system:serviceaccount:production:deployer",
    "groups": ["system:serviceaccounts", "system:authenticated"]
  },

  "sourceIPs": ["10.20.30.40"],
  "userAgent": "kubectl/v1.31.2 (linux/amd64) kubernetes/8f8f8f8",

  "objectRef": {
    "resource": "deployments",
    "namespace": "production",
    "name": "payments-api",
    "apiGroup": "apps",
    "apiVersion": "v1",
    "uid": "11112222-3333-4444-5555-666677778888"
  },

  "responseStatus": {
    "metadata": {},
    "status": "Success",
    "code": 200
  },

  "requestObject": {
    "kind": "DeleteOptions",
    "apiVersion": "meta.k8s.io/__internal",
    "gracePeriodSeconds": 30,
    "propagationPolicy": "Background"
  },

  "responseObject": {
    "kind": "Status",
    "apiVersion": "v1",
    "status": "Success",
    "details": {
      "name": "payments-api",
      "group": "apps",
      "kind": "deployments",
      "uid": "11112222-3333-4444-5555-666677778888"
    }
  },

  "requestReceivedTimestamp": "2026-01-15T03:00:12.334521Z",
  "stageTimestamp":           "2026-01-15T03:00:12.451903Z",

  "annotations": {
    "authorization.k8s.io/decision": "allow",
    "authorization.k8s.io/reason": "RBAC: allowed by ClusterRoleBinding \"platform-admin\" of ClusterRole \"edit\" to Group \"platform-engineers\"",
    "pod-security.kubernetes.io/enforce-policy": "restricted:v1.31"
  }
}
```

Field by field, and why each matters:

| Field | Investigation value |
|---|---|
| `auditID` | Correlates the multiple stages of one request. Join on this. |
| `stage` | Which point in the pipeline this event represents. |
| `level` | How much detail was captured, per your policy. |
| `user.username` | **The real authenticated identity.** |
| `user.groups` | Which groups granted the access. |
| `impersonatedUser` | **The effective identity.** If present, `user` did the action *as* someone else. Always check this field. |
| `sourceIPs` | Where the request came from. An array, because proxies append. |
| `userAgent` | `kubectl` vs a controller vs a scanner. Anomalous agents are a signal. |
| `objectRef` | Exactly which object, including its UID, which survives recreation with the same name. |
| `responseStatus.code` | Success or the specific failure. `403` here means an authorization denial. |
| `requestObject` | What was submitted. Only present at `Request`/`RequestResponse` level. |
| `responseObject` | What the server returned. Only at `RequestResponse`. |
| `annotations["authorization.k8s.io/decision"]` | `allow` or `forbid`. |
| `annotations["authorization.k8s.io/reason"]` | **Names the exact binding and role that permitted the action.** This is gold for RBAC auditing. |
| `stageTimestamp` minus `requestReceivedTimestamp` | Request latency. |

The `authorization.k8s.io/reason` annotation deserves emphasis. It tells you not just that access was granted, but *which RBAC object granted it*, which is otherwise very laborious to determine. See [rbac.md](rbac.md).

---

## Investigation Queries

The log is newline-delimited JSON, so `jq` is the tool. These are the queries worth memorising.

### Who Deleted the Deployment

```bash
sudo jq -r 'select(.verb == "delete")
  | select(.objectRef.resource == "deployments")
  | select(.objectRef.name == "payments-api")
  | [ .requestReceivedTimestamp,
      .user.username,
      (.impersonatedUser.username // "-"),
      .sourceIPs[0],
      .responseStatus.code ]
  | @tsv' /var/log/kubernetes/audit/audit.log | column -t
```

### Who Read a Specific Secret

The question every incident eventually asks.

```bash
sudo jq -r 'select(.objectRef.resource == "secrets")
  | select(.objectRef.namespace == "production")
  | select(.objectRef.name == "db-credentials")
  | select(.verb == "get" or .verb == "list")
  | [ .requestReceivedTimestamp,
      .user.username,
      .verb,
      .sourceIPs[0],
      .userAgent ]
  | @tsv' /var/log/kubernetes/audit/audit.log | column -t
```

### Every Secret Access, Ranked by Identity

```bash
sudo jq -r 'select(.objectRef.resource == "secrets")
  | select(.verb == "get" or .verb == "list" or .verb == "watch")
  | .user.username' /var/log/kubernetes/audit/audit.log \
  | sort | uniq -c | sort -rn | head -30
```

A human username high in this list is worth a conversation. Service accounts dominating it is normal.

### Everything One Identity Did

```bash
USER="alice@example.com"
sudo jq -r --arg u "$USER" 'select(.user.username == $u)
  | [ .requestReceivedTimestamp,
      .verb,
      (.objectRef.resource // .requestURI),
      (.objectRef.namespace // "-"),
      (.objectRef.name // "-"),
      .responseStatus.code ]
  | @tsv' /var/log/kubernetes/audit/audit.log | column -t
```

### All Authorization Denials

Failed attempts often reveal reconnaissance.

```bash
sudo jq -r 'select(.annotations["authorization.k8s.io/decision"] == "forbid")
  | [ .requestReceivedTimestamp,
      .user.username,
      .verb,
      (.objectRef.resource // .requestURI),
      (.objectRef.namespace // "-") ]
  | @tsv' /var/log/kubernetes/audit/audit.log | column -t
```

Cluster them to spot scanning behaviour:

```bash
sudo jq -r 'select(.responseStatus.code == 403)
  | "\(.user.username)"' /var/log/kubernetes/audit/audit.log \
  | sort | uniq -c | sort -rn | head -20
```

A single identity generating hundreds of 403s across many resource types is enumerating your permissions.

### Every exec Into a Container

```bash
sudo jq -r 'select(.objectRef.subresource == "exec")
  | [ .requestReceivedTimestamp,
      .user.username,
      (.impersonatedUser.username // "-"),
      .objectRef.namespace,
      .objectRef.name,
      .sourceIPs[0] ]
  | @tsv' /var/log/kubernetes/audit/audit.log | column -t
```

Interactive shell access to a production container should be a rare, explainable event. If it is routine, that is an operational finding in itself.

### RBAC Changes

```bash
sudo jq -r 'select(.objectRef.apiGroup == "rbac.authorization.k8s.io")
  | select(.verb | test("create|update|patch|delete"))
  | [ .requestReceivedTimestamp,
      .user.username,
      .verb,
      .objectRef.resource,
      .objectRef.name ]
  | @tsv' /var/log/kubernetes/audit/audit.log | column -t
```

Then look at what a specific change actually contained:

```bash
sudo jq 'select(.objectRef.resource == "clusterrolebindings")
  | select(.verb == "create")
  | select(.objectRef.name == "suspicious-binding")
  | .requestObject' /var/log/kubernetes/audit/audit.log
```

### Anything Done Via Impersonation

```bash
sudo jq -r 'select(.impersonatedUser != null)
  | [ .requestReceivedTimestamp,
      .user.username,
      "AS",
      .impersonatedUser.username,
      .verb,
      (.objectRef.resource // "-") ]
  | @tsv' /var/log/kubernetes/audit/audit.log | column -t
```

### Activity in a Time Window

```bash
FROM="2026-01-15T02:55:00Z"
TO="2026-01-15T03:10:00Z"
sudo jq -r --arg a "$FROM" --arg b "$TO" '
  select(.requestReceivedTimestamp >= $a and .requestReceivedTimestamp <= $b)
  | select(.verb | test("create|update|patch|delete"))
  | [ .requestReceivedTimestamp, .user.username, .verb,
      (.objectRef.resource // "-"), (.objectRef.name // "-") ]
  | @tsv' /var/log/kubernetes/audit/audit.log | column -t
```

ISO-8601 timestamps sort lexicographically, which is why plain string comparison works here.

### Reconstruct an Object From the Log

```bash
sudo jq 'select(.objectRef.name == "payments-api")
  | select(.verb == "update")
  | select(.level == "RequestResponse")
  | .responseObject' /var/log/kubernetes/audit/audit.log \
  | tail -1 > recovered-deployment.json
```

At `RequestResponse` level, the log contains full object bodies. This has genuinely been used to restore a resource nobody had in git.

### Correlating Stages of One Request

```bash
AID="d4f1c9a3-7b21-4e88-9c05-1a2b3c4d5e6f"
sudo jq -c --arg id "$AID" 'select(.auditID == $id)
  | {stage, level, code: .responseStatus.code, t: .stageTimestamp}' \
  /var/log/kubernetes/audit/audit.log
```

### Slowest Requests

```bash
sudo jq -r 'select(.stage == "ResponseComplete")
  | [ ((.stageTimestamp[0:23] + "Z" | fromdateiso8601) -
       (.requestReceivedTimestamp[0:23] + "Z" | fromdateiso8601)),
      .user.username, .verb, (.objectRef.resource // .requestURI) ]
  | @tsv' /var/log/kubernetes/audit/audit.log \
  | sort -rn | head -20
```

---

## Volume and Disk Sizing

Estimate before enabling, because filling the control plane disk takes the cluster down.

```
   events/sec × avg_event_size × 86400 = bytes/day
```

Measure your actual request rate first:

```bash
kubectl get --raw /metrics | grep '^apiserver_request_total' | wc -l
# Better: rate over a window
kubectl get --raw /metrics | grep 'apiserver_request_total' | \
  awk -F' ' '{s+=$2} END {print s}'
```

Rough guidance for a small to medium cluster after a well-tuned policy:

| Cluster | Requests/sec (post-filter) | Metadata-heavy policy | Mixed policy |
|---|---|---|---|
| 5 nodes, light | 5 to 15 | ~1 to 3 GB/day | ~4 to 10 GB/day |
| 20 nodes | 30 to 80 | ~5 to 15 GB/day | ~20 to 50 GB/day |
| 100 nodes | 150 to 400 | ~25 to 70 GB/day | ~100 GB+/day |

The dominant variable is not cluster size but **policy quality**. A policy without the Section 1 noise-dropping rules can easily produce ten times these numbers, almost entirely leases and node status updates.

Bound the disk usage explicitly, and put the log on its own filesystem if you can:

```yaml
- --audit-log-maxsize=100      # MB per file
- --audit-log-maxbackup=10     # files
- --audit-log-maxage=30        # days
- --audit-log-compress=true
```

Monitor it:

```bash
sudo du -sh /var/log/kubernetes/audit/
sudo df -h /var/log
```

And alert on the control plane filesystem. A full disk stops the API server from writing audit events, and depending on layout, can stop etcd from writing at all.

---

## Shipping Logs Off the Node

A log that lives only on the compromised host is not evidence. Get it off the node.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  control plane node                                                  │
   │    /var/log/kubernetes/audit/audit.log                               │
   │              │                                                       │
   │              ▼                                                       │
   │    ┌────────────────────┐                                            │
   │    │ Fluent Bit / Vector│  DaemonSet on control plane nodes,         │
   │    │ (hostPath read)    │  tolerating the control plane taint         │
   │    └────────────────────┘                                            │
   │              │                                                       │
   │              ▼                                                       │
   │    Loki / Elasticsearch / S3 / SIEM   ── append-only, separate       │
   │                                          trust domain                │
   └──────────────────────────────────────────────────────────────────────┘
```

A Fluent Bit configuration fragment:

```ini
[INPUT]
    Name              tail
    Path              /var/log/kubernetes/audit/audit.log
    Parser            json
    Tag               k8s.audit
    Refresh_Interval  5
    Mem_Buf_Limit     20MB
    Skip_Long_Lines   On
    DB                /var/log/flb-audit.db

[FILTER]
    Name    modify
    Match   k8s.audit
    Add     cluster prod-eu-west

[OUTPUT]
    Name       loki
    Match      k8s.audit
    Host       loki.monitoring.svc
    Port       3100
    Labels     job=k8s-audit, cluster=prod-eu-west
    Label_Keys $verb,$user['username'],$objectRef['resource']
```

The DaemonSet must schedule onto control plane nodes:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: audit-log
          hostPath:
            path: /var/log/kubernetes/audit
            type: Directory
```

Requirements for the destination:

- **Append-only or WORM**, so an attacker with cluster access cannot delete their trail.
- **A separate credential domain** from the cluster. If cluster admin also grants log deletion, the log is not evidence.
- **Retention matching your compliance obligation**, commonly one year.

Alerts worth configuring on the shipped data:

```
   ► Any create/update on clusterrolebindings
   ► Any binding referencing cluster-admin
   ► Any exec into a production namespace
   ► Any secret read by a non-service-account identity
   ► Any delete of a validating/mutating webhook configuration
   ► More than N 403s from one identity in 5 minutes
   ► Any request from system:anonymous that is not a health check
   ► Any use of impersonation
```

---

## What Audit Does Not Capture

Real blind spots. Know them.

```
   ✗ Anything written directly to etcd, bypassing the API server
   ✗ Actions on a node itself (SSH, docker/crictl commands, file edits)
   ✗ Traffic between pods (that is a CNI/NetworkPolicy concern)
   ✗ Application-level activity inside a container
   ✗ Requests to the kubelet API directly on port 10250, unless
     proxied through the API server via nodes/proxy
   ✗ Anything at all, if the policy has no matching rule
```

The kubelet blind spot matters. An attacker with node access can talk to the local kubelet directly and exec into pods without touching the API server. Kubelet authentication and authorization must therefore be locked down separately, and the kubelet has its own (much more limited) logging. See [cluster-hardening.md](cluster-hardening.md).

For host-level activity, pair audit logging with `auditd` on the nodes and a runtime detector such as Falco.

---

## Recipes

### Recipe: A Minimal Starter Policy

If the production policy above is too much to adopt at once, start here. It is small, safe, and immediately useful.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
omitManagedFields: true
rules:
  # Drop the loudest noise.
  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]
  - level: None
    nonResourceURLs: ["/healthz*", "/livez*", "/readyz*", "/version", "/metrics"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "update", "patch"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  # Never log secret bodies.
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Full detail on the things that matter most.
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["*"]

  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # Everything else.
  - level: Metadata
```

### Recipe: Daily Security Digest

```bash
#!/usr/bin/env bash
# audit-digest.sh - run from cron on a control plane node
LOG=/var/log/kubernetes/audit/audit.log
SINCE=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)

echo "=== Kubernetes audit digest since ${SINCE} ==="

echo
echo "--- RBAC changes ---"
sudo jq -r --arg s "$SINCE" '
  select(.requestReceivedTimestamp >= $s)
  | select(.objectRef.apiGroup == "rbac.authorization.k8s.io")
  | select(.verb | test("create|update|patch|delete"))
  | [.requestReceivedTimestamp, .user.username, .verb,
     .objectRef.resource, .objectRef.name] | @tsv' "$LOG" | column -t

echo
echo "--- exec / attach / port-forward ---"
sudo jq -r --arg s "$SINCE" '
  select(.requestReceivedTimestamp >= $s)
  | select(.objectRef.subresource // "" | test("exec|attach|portforward"))
  | [.requestReceivedTimestamp, .user.username, .objectRef.namespace,
     .objectRef.name, .objectRef.subresource] | @tsv' "$LOG" | column -t

echo
echo "--- secret reads by non-service-accounts ---"
sudo jq -r --arg s "$SINCE" '
  select(.requestReceivedTimestamp >= $s)
  | select(.objectRef.resource == "secrets")
  | select(.verb | test("get|list"))
  | select(.user.username | startswith("system:serviceaccount:") | not)
  | [.requestReceivedTimestamp, .user.username, .objectRef.namespace,
     (.objectRef.name // "LIST")] | @tsv' "$LOG" | column -t

echo
echo "--- top 403 sources ---"
sudo jq -r --arg s "$SINCE" '
  select(.requestReceivedTimestamp >= $s)
  | select(.responseStatus.code == 403)
  | .user.username' "$LOG" | sort | uniq -c | sort -rn | head -10

echo
echo "--- impersonation ---"
sudo jq -r --arg s "$SINCE" '
  select(.requestReceivedTimestamp >= $s)
  | select(.impersonatedUser != null)
  | [.requestReceivedTimestamp, .user.username, "AS",
     .impersonatedUser.username, .verb] | @tsv' "$LOG" | column -t

echo
echo "--- anonymous requests (excluding health) ---"
sudo jq -r --arg s "$SINCE" '
  select(.requestReceivedTimestamp >= $s)
  | select(.user.username == "system:anonymous")
  | [.requestReceivedTimestamp, .sourceIPs[0], .verb, .requestURI] | @tsv' \
  "$LOG" | column -t
```

### Recipe: Measure Your Log Volume Before Committing

Deploy with a `Metadata`-only catch-all for one hour, measure, then tune.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  - level: Metadata
```

```bash
# After an hour
sudo ls -l /var/log/kubernetes/audit/audit.log
sudo wc -l /var/log/kubernetes/audit/audit.log

# What is generating the volume?
sudo jq -r '[.user.username, .verb, (.objectRef.resource // .requestURI)]
  | @tsv' /var/log/kubernetes/audit/audit.log \
  | sort | uniq -c | sort -rn | head -25
```

That last command output is your Section 1 noise-dropping list, derived from your actual cluster rather than a generic template.

---

## Command Reference

```bash
# ---------- Configuration ----------
sudo cat /etc/kubernetes/audit/audit-policy.yaml
sudo grep audit /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep audit

# ---------- Live tail ----------
sudo tail -f /var/log/kubernetes/audit/audit.log | jq -c \
  '{t:.requestReceivedTimestamp,u:.user.username,v:.verb,r:.objectRef.resource,c:.responseStatus.code}'

# ---------- Volume ----------
sudo ls -lh /var/log/kubernetes/audit/
sudo du -sh /var/log/kubernetes/audit/
sudo wc -l /var/log/kubernetes/audit/audit.log
sudo df -h /var/log

# ---------- Common filters ----------
sudo jq 'select(.verb=="delete")'                    audit.log
sudo jq 'select(.user.username=="alice")'            audit.log
sudo jq 'select(.objectRef.resource=="secrets")'     audit.log
sudo jq 'select(.responseStatus.code>=400)'          audit.log
sudo jq 'select(.impersonatedUser!=null)'            audit.log
sudo jq 'select(.objectRef.subresource=="exec")'     audit.log
sudo jq 'select(.annotations["authorization.k8s.io/decision"]=="forbid")' audit.log

# ---------- Search rotated and compressed files ----------
sudo zcat /var/log/kubernetes/audit/audit-*.log.gz | jq 'select(...)'

# ---------- Restart the API server to reload the policy ----------
#  (the policy file is NOT hot reloaded)
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 5
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
until kubectl get --raw /healthz 2>/dev/null; do sleep 2; done; echo
```

---

## Troubleshooting

### API Server Will Not Start After Enabling

`kubectl` is dead because the static pod is crashlooping. Work from the node.

```bash
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -40
sudo journalctl -u kubelet -n 100 --no-pager
```

Causes in order of frequency:

**1. Policy file not mounted.**

```
error: unable to read audit policy file:
open /etc/kubernetes/audit/audit-policy.yaml: no such file or directory
```

Add the `volume` and `volumeMount` for `/etc/kubernetes/audit`.

**2. Log directory not mounted, or mounted read-only.**

```
error: failed to open audit log file: open
/var/log/kubernetes/audit/audit.log: read-only file system
```

The log mount must be `readOnly: false`.

**3. Invalid policy YAML.**

```
error: loading audit policy file: unknown field "levels"
```

The field is `level`, singular, on each rule. Check `apiVersion: audit.k8s.io/v1` and `kind: Policy`.

**4. An invalid level value.**

Valid values are exactly `None`, `Metadata`, `Request`, `RequestResponse`. They are case sensitive.

Recovery:

```bash
sudo cp /root/kube-apiserver.yaml.pre-audit.bak \
        /etc/kubernetes/manifests/kube-apiserver.yaml
until kubectl get --raw /healthz 2>/dev/null; do sleep 2; done; echo
```

### The Log File Is Empty

```bash
# 1. Does the file exist and is it growing?
sudo ls -la /var/log/kubernetes/audit/

# 2. Are the flags actually applied?
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep audit

# 3. Is the policy dropping everything?
#    A policy whose only rule is level: None logs nothing.
sudo cat /etc/kubernetes/audit/audit-policy.yaml

# 4. Is there a catch-all rule at the bottom?
#    Without one, unmatched requests are silently dropped.
```

The most common cause is a policy with noise-dropping `None` rules and **no final catch-all**. Add:

```yaml
  - level: Metadata
```

as the last rule.

### Policy Changes Are Not Taking Effect

The audit policy file is **not** hot reloaded. Unlike `EncryptionConfiguration`, there is no automatic-reload flag. You must restart the API server.

```bash
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 5
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
until kubectl get --raw /healthz 2>/dev/null; do sleep 2; done; echo
```

On an HA cluster, do this one node at a time, waiting for each to become ready.

### The Disk Filled Up

```bash
sudo df -h /var/log
sudo du -sh /var/log/kubernetes/audit/
```

Immediate relief:

```bash
# Remove compressed rotated files first, keeping the live log.
sudo rm -f /var/log/kubernetes/audit/audit-*.log.gz
```

Then fix the cause:

```yaml
- --audit-log-maxsize=100
- --audit-log-maxbackup=5      # lower this
- --audit-log-maxage=7         # and this
- --audit-log-compress=true
```

And tune the policy. Find what is generating the volume:

```bash
sudo jq -r '[.user.username, .verb, (.objectRef.resource // .requestURI)] | @tsv' \
  /var/log/kubernetes/audit/audit.log \
  | sort | uniq -c | sort -rn | head -20
```

Add `level: None` rules for whatever dominates.

### API Server Latency Increased

Audit writes are synchronous to the file. Check:

```bash
kubectl get --raw /metrics | grep apiserver_audit_event_total
kubectl get --raw /metrics | grep apiserver_audit_error_total
kubectl get --raw /metrics | grep apiserver_audit_requests_rejected_total
```

Remedies, in order:

1. Reduce `RequestResponse` rules; they are by far the most expensive.
2. Add more `level: None` noise filters.
3. Put the audit log on a separate, fast filesystem from etcd. Sharing a disk with etcd is the usual cause of a real problem here.
4. If using a webhook backend, ensure `--audit-webhook-mode=batch`, not `blocking`.

### Secrets Are Appearing in the Log

You have a `Request` or `RequestResponse` rule matching secrets, or a broad rule that matches them before your `Metadata` rule.

```bash
# Confirm the exposure
sudo jq 'select(.objectRef.resource=="secrets") | select(.requestObject != null)' \
  /var/log/kubernetes/audit/audit.log | head -1
```

Fix the policy so the secrets `Metadata` rule comes **before** any broad rule, restart the API server, then treat the existing log as compromised material: rotate every secret it contains and dispose of the log securely.

---

## Exam and Interview Traps

1. **Is audit logging enabled by default on kubeadm?** No. It is entirely off until you configure a policy and the flags.

2. **Name the four levels.** `None`, `Metadata`, `Request`, `RequestResponse`.

3. **Name the four stages.** `RequestReceived`, `ResponseStarted`, `ResponseComplete`, `Panic`.

4. **How are rules evaluated?** Top to bottom, first match wins, evaluation stops. A request matching no rule is not logged.

5. **Why must the secrets rule come early?** Otherwise a later broad `RequestResponse` rule captures secret bodies and your audit log becomes a plaintext credential store.

6. **Which stage is almost always omitted, and why?** `RequestReceived`. It roughly doubles volume while adding no outcome information.

7. **What are the two things people forget when enabling on kubeadm?** The `hostPath` volume for the policy file, and a **writable** mount for the log directory.

8. **Is the audit policy hot reloaded?** No. You must restart the API server. This differs from `EncryptionConfiguration`, which has an automatic reload flag.

9. **Are failed requests logged?** Yes. A `403` or `401` still produces an audit event, and failed attempts are often the most valuable signal.

10. **Which annotation tells you which RBAC rule allowed a request?** `authorization.k8s.io/reason`. It names the binding and the role.

11. **How do you tell a request was impersonated?** The `impersonatedUser` field is present. `user` is the real identity, `impersonatedUser` is the effective one.

12. **Why is `ResponseComplete` unreliable for detecting an exec in real time?** For long-running requests it fires when the session ends, which could be hours later. Capture `ResponseStarted` for `pods/exec`.

13. **Does audit logging capture kubelet API access on port 10250?** No, not unless it goes through the API server via `nodes/proxy`. Direct kubelet access is a blind spot.

14. **What happens if `--audit-log-maxbackup` is 0?** Unlimited rotated files, which will eventually fill the disk and take down the control plane.

15. **What is `omitManagedFields` for?** Suppressing server-side-apply bookkeeping, which is large and never useful in an investigation.

---

## Related Topics

- [authentication.md](authentication.md) for the identity recorded in `user`
- [authorization.md](authorization.md) for the decision annotations
- [rbac.md](rbac.md) for interpreting `authorization.k8s.io/reason`
- [admission-controllers.md](admission-controllers.md) for the admission annotations
- [encryption-at-rest.md](encryption-at-rest.md) for the sibling control on the storage layer
- [secrets.md](secrets.md) for why secret access auditing matters
- [cluster-hardening.md](cluster-hardening.md) for the wider posture including kubelet gaps
- [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md) for editing the API server manifest safely
- [logging.md](logging.md) for the cluster logging architecture that ships these events
- [monitoring.md](monitoring.md) for alerting on the shipped data
- [kube-apiserver.md](kube-apiserver.md) for the component emitting the events

---

## Key Takeaways

- Audit logging is off by default. Until you enable it, a compromise is unreconstructible.
- Rules match top to bottom, first match wins, and an unmatched request is silently dropped. Always end with a catch-all.
- Order the policy: drop noise first, protect secrets second, capture security-critical resources third, catch-all last.
- Never apply `Request` or `RequestResponse` to secrets or configmaps. Place their `Metadata` rule before any broad rule.
- `omitStages: [RequestReceived]` roughly halves volume for no loss of information.
- On kubeadm you need the flags **and** two volume mounts: the policy read-only, the log directory writable.
- The audit policy is not hot reloaded. Restart the API server after changing it.
- Failed requests are audited too, and clustered 403s from one identity are a strong reconnaissance signal.
- `authorization.k8s.io/reason` names the exact RBAC binding that permitted an action, which is otherwise laborious to determine.
- Always check `impersonatedUser`. `user` is who authenticated; `impersonatedUser` is who acted.
- Ship the log off the node to append-only storage in a separate credential domain, or it is not evidence.
- Direct kubelet access on port 10250 is invisible to the audit log. Harden the kubelet separately.

---

## References

- [Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Audit Policy API Reference](https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/)
- [kube-apiserver Command Line Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Authorization Overview](https://kubernetes.io/docs/reference/access-authn-authz/authorization/)
- [Controlling Access to the Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)
- [Securing a Cluster](https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/)
- [Logging Architecture](https://kubernetes.io/docs/concepts/cluster-administration/logging/)
