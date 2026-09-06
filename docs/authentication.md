# 🔐 Kubernetes Authentication: Proving Who You Are

A complete guide to how the API server decides *who* is making a request: the full request pipeline, every authentication strategy, X.509 client certificates and the CertificateSigningRequest API, OIDC, webhooks, bootstrap tokens, impersonation, and the anatomy of a kubeconfig file.

## 📋 Table of Contents
- [Why Authentication Is Different in Kubernetes](#why-authentication-is-different-in-kubernetes)
- [The Full Request Pipeline](#the-full-request-pipeline)
- [There Is No User Object](#there-is-no-user-object)
- [What an Authenticator Produces](#what-an-authenticator-produces)
- [The Authenticator Chain](#the-authenticator-chain)
- [X.509 Client Certificates](#x509-client-certificates)
- [The CertificateSigningRequest API](#the-certificatesigningrequest-api)
- [Service Account Bearer Tokens](#service-account-bearer-tokens)
- [OpenID Connect](#openid-connect)
- [Webhook Token Authentication](#webhook-token-authentication)
- [Authenticating Proxy Headers](#authenticating-proxy-headers)
- [Anonymous Requests](#anonymous-requests)
- [Static Token File and Basic Auth](#static-token-file-and-basic-auth)
- [Bootstrap Tokens and Node Join](#bootstrap-tokens-and-node-join)
- [Node Authentication](#node-authentication)
- [Special Groups and Reserved Prefixes](#special-groups-and-reserved-prefixes)
- [Impersonation](#impersonation)
- [kubeconfig Anatomy](#kubeconfig-anatomy)
- [The KUBECONFIG Environment Variable and Merging](#the-kubeconfig-environment-variable-and-merging)
- [kubeadm Generated kubeconfig Files](#kubeadm-generated-kubeconfig-files)
- [Certificate Expiry and Renewal](#certificate-expiry-and-renewal)
- [Complete Lab: Onboard a New User](#complete-lab-onboard-a-new-user)
- [Strategy Comparison](#strategy-comparison)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why Authentication Is Different in Kubernetes

Every other system you have administered has a user database. Linux has `/etc/passwd`. A database has a `users` table. An LDAP directory has entries. Kubernetes has **none of these**.

There is no `kubectl create user`. There is no `kubectl get users`. There is no object in etcd that represents Alice. This is not an oversight; it is a deliberate design decision, and understanding it is the single most important step in understanding Kubernetes security.

```
┌─────────────────────────────────────────────────────────────────────┐
│               The Kubernetes Identity Model                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   TWO CLASSES OF IDENTITY                                            │
│                                                                      │
│   1. NORMAL USERS (humans, and anything outside the cluster)         │
│      • NOT Kubernetes objects                                        │
│      • NOT stored in etcd                                            │
│      • Cannot be created, listed, updated or deleted via the API     │
│      • Managed entirely by an EXTERNAL system:                       │
│           - a certificate authority you control                      │
│           - an OIDC identity provider (Entra ID, Okta, Keycloak...)  │
│           - an authenticating proxy                                  │
│           - a custom webhook                                         │
│      • The cluster only ever sees a STRING: the username             │
│                                                                      │
│   2. SERVICE ACCOUNTS (machine identity for in-cluster workloads)    │
│      • ARE Kubernetes objects (kind: ServiceAccount, v1)             │
│      • ARE stored in etcd, namespaced                                │
│      • Created, listed and deleted with kubectl like anything else   │
│      • Username is derived, never chosen:                            │
│           system:serviceaccount:<namespace>:<name>                   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

The consequence is that **authentication is delegated and authorization is native**. Kubernetes has no opinion on how you prove you are Alice; it has a very strong opinion, expressed through RBAC, about what "alice" is allowed to do once it believes you.

The practical rule that follows: if a request arrives with a valid credential naming `alice`, the cluster treats it as Alice. There is no password to check against a stored hash, no account lockout, no "disable this account" button. Revocation happens in the external system, or by letting a credential expire, or by removing every RBAC binding that mentions the name.

> 📖 **See Also**: [rbac.md](rbac.md) for what happens after the API server knows who you are.

---

## The Full Request Pipeline

Authentication is the second gate, not the first. Every request to the API server walks the same path, and a failure at any stage returns before the next stage runs.

```
┌────────────────────────────────────────────────────────────────────────────┐
│                    kube-apiserver REQUEST PIPELINE                          │
└────────────────────────────────────────────────────────────────────────────┘

   kubectl / client-go / curl / kubelet / controller / Pod
        │
        │  HTTPS request, for example:
        │     POST /api/v1/namespaces/dev/pods
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  1. TRANSPORT SECURITY (TLS)                                        │
│     • Server presents its serving certificate                       │
│       (--tls-cert-file, --tls-private-key-file)                     │
│     • Client verifies it against the cluster CA it was given        │
│       (certificate-authority-data in kubeconfig)                    │
│     • Client MAY present a client certificate in the TLS handshake  │
│       (this is where mTLS material is captured for stage 2)         │
│                                                                     │
│     FAILURE: connection refused / x509 verification error           │
│              (no HTTP status code at all, the TLS handshake failed) │
└─────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  2. AUTHENTICATION            "WHO are you?"                        │
│     Authenticator modules are tried until one succeeds:             │
│       X.509 client cert → bearer token → OIDC → webhook → proxy     │
│     Produces: username, UID, groups, extra fields                   │
│                                                                     │
│     FAILURE: 401 Unauthorized                                       │
└─────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  2b. IMPERSONATION (optional)                                       │
│     If Impersonate-User / Impersonate-Group headers are present,    │
│     the ORIGINAL identity must hold the `impersonate` verb.         │
│     If allowed, the identity is REPLACED for the rest of the        │
│     pipeline; the original user is recorded in the audit log.       │
└─────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  3. AUTHORIZATION             "MAY you do this?"                    │
│     Authorizer chain, in the order given by --authorization-mode:   │
│       Node → RBAC → ABAC → Webhook   (typical: Node,RBAC)           │
│     Each authorizer returns allow / deny / no-opinion.              │
│                                                                     │
│     FAILURE: 403 Forbidden                                          │
└─────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  4. ADMISSION CONTROL                                               │
│                                                                     │
│    4a. MUTATING ADMISSION                                           │
│        Built-in plugins (ServiceAccount, DefaultStorageClass,       │
│        LimitRanger...) then MutatingAdmissionWebhooks.              │
│        These may CHANGE the object: inject sidecars, add the        │
│        projected service account token volume, set defaults.        │
│                                                                     │
│    4b. OBJECT SCHEMA VALIDATION                                     │
│        The (possibly mutated) object is decoded and validated       │
│        against the API schema. Unknown fields, bad enums and        │
│        malformed values are rejected here.                          │
│                                                                     │
│    4c. VALIDATING ADMISSION                                         │
│        Built-in validating plugins (ResourceQuota,                  │
│        PodSecurity, NodeRestriction...), then                       │
│        ValidatingAdmissionPolicy (CEL) and                          │
│        ValidatingAdmissionWebhooks. These may only ACCEPT or        │
│        REJECT; they may not modify the object.                      │
│                                                                     │
│     FAILURE: 400 Bad Request / 403 Forbidden / 422 Invalid          │
│              with the admission plugin or webhook name in the       │
│              message                                                │
└─────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  5. PERSISTENCE TO etcd                                             │
│     The object is serialised (protobuf on the wire to etcd),        │
│     optionally encrypted at rest (EncryptionConfiguration),         │
│     and written under /registry/<resource>/<namespace>/<name>.      │
│     etcd's revision becomes the object's resourceVersion.           │
└─────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  6. RESPONSE + WATCH FAN-OUT                                        │
│     201/200 to the caller; the write is broadcast to every open     │
│     watch, waking the scheduler, controllers and kubelets.          │
└─────────────────────────────────────────────────────────────────────┘
```

### The Two Status Codes You Must Never Confuse

| Code | Meaning | Stage | Typical cause |
|------|---------|-------|---------------|
| **401 Unauthorized** | "I do not know who you are" | Authentication | Expired certificate, bad or missing token, unknown CA, clock skew |
| **403 Forbidden** | "I know exactly who you are, and you may not do that" | Authorization | Missing RBAC rule, wrong namespace, wrong verb |

A 401 is an **identity** problem. A 403 is a **permission** problem, and it proves authentication succeeded. Reading the error text tells you which half of the system to debug, and the 403 body helpfully names the identity the server settled on.

```
Error from server (Forbidden): pods is forbidden:
  User "alice" cannot list resource "pods" in API group "" in the namespace "prod"
       ^^^^^                  ^^^^      ^^^^                              ^^^^
       identity               verb      resource                          namespace
```

> 📖 **See Also**: [kube-apiserver.md](kube-apiserver.md) and [k8s-api.md](k8s-api.md) for the API surface itself.

---

## There Is No User Object

It is worth restating with a demonstration, because almost everyone tries this once:

```bash
kubectl get users
# error: the server doesn't have a resource type "users"

kubectl api-resources | grep -i '^user'
# (no output)

kubectl create user alice
# error: unknown command "user" for "kubectl create"
```

The only "users" resource that exists is the one used by **impersonation** RBAC rules, and it is a virtual resource with no storage behind it:

```bash
kubectl api-resources --api-group=authentication.k8s.io
# NAME                 SHORTNAMES   APIVERSION                 NAMESPACED   KIND
# selfsubjectreviews                authentication.k8s.io/v1   false        SelfSubjectReview
# tokenreviews                      authentication.k8s.io/v1   false        TokenReview
```

You cannot list users, so **you cannot enumerate who has access to your cluster from the cluster itself**. You can only enumerate who has been *granted* something:

```bash
# Every subject mentioned by any binding, cluster wide
kubectl get clusterrolebindings,rolebindings -A \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,NS:.metadata.namespace,SUBJECTS:.subjects[*].name'
```

A user with a valid certificate and no bindings is authenticated and completely powerless. That is a perfectly normal, and quite useful, state.

---

## What an Authenticator Produces

Every authentication module, no matter the mechanism, produces the same small structure. Everything downstream (RBAC, audit, admission) sees only this:

```
┌──────────────────────────────────────────────────────────────────┐
│                       user.Info                                   │
├──────────────────────────────────────────────────────────────────┤
│  Name    string                "alice"                            │
│                                "system:serviceaccount:dev:ci"     │
│                                "system:node:worker-01"            │
│                                "system:anonymous"                 │
│                                                                   │
│  UID     string                stable unique id, often empty for  │
│                                certificate users                  │
│                                                                   │
│  Groups  []string              ["developers","system:authenticated"] │
│                                                                   │
│  Extra   map[string][]string   arbitrary key/value pairs from     │
│                                webhooks or proxy headers, usable  │
│                                by authorization webhooks          │
└──────────────────────────────────────────────────────────────────┘
```

Three things follow immediately:

1. **Groups are just strings too.** There is no Group object either. A group exists the moment an authenticator asserts it.
2. **RBAC never sees your certificate, token or password.** It sees a name and a list of group names. Two completely different mechanisms that assert the name `alice` are indistinguishable to the authorizer.
3. **The username is case sensitive and matched exactly.** `Alice` and `alice` are different users, and a binding for one does nothing for the other.

You can see exactly what the server made of you:

```bash
kubectl auth whoami
```

```
ATTRIBUTE   VALUE
Username    alice
Groups      [developers system:authenticated]
```

This is a real API call, a `SelfSubjectReview` in the `authentication.k8s.io/v1` group, and it is the fastest way to end an argument about which credential your kubeconfig is actually using:

```yaml
apiVersion: authentication.k8s.io/v1
kind: SelfSubjectReview
# POST this to /apis/authentication.k8s.io/v1/selfsubjectreviews
# The server fills in .status.userInfo with the identity it resolved.
```

```bash
# The raw call, useful when kubectl auth whoami is unavailable
kubectl create -f - -o yaml <<'EOF'
apiVersion: authentication.k8s.io/v1
kind: SelfSubjectReview
EOF
```

```yaml
apiVersion: authentication.k8s.io/v1
kind: SelfSubjectReview
metadata:
  creationTimestamp: "2025-01-01T00:00:00Z"
status:
  userInfo:
    groups:
    - developers
    - system:authenticated
    username: alice
```

---

## The Authenticator Chain

The API server runs its configured authenticators **in sequence until one succeeds**.

```
┌────────────────────────────────────────────────────────────────────┐
│                     AUTHENTICATOR CHAIN                             │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  request                                                            │
│     │                                                               │
│     ├─► X.509 client certificate      (--client-ca-file)            │
│     │      TLS peer cert chains to the CA?  → username = CN         │
│     │      no cert presented → skip to the next module              │
│     │                                                               │
│     ├─► Bearer token modules, all reading `Authorization: Bearer …` │
│     │      • service account tokens  (--service-account-key-file)   │
│     │      • bootstrap tokens        (--enable-bootstrap-token-auth)│
│     │      • OIDC id_token           (--oidc-issuer-url …)          │
│     │      • static token file       (--token-auth-file, legacy)    │
│     │      • webhook                 (--authentication-token-       │
│     │                                  webhook-config-file)         │
│     │                                                               │
│     ├─► Authenticating proxy headers  (--requestheader-* flags)     │
│     │                                                               │
│     └─► Anonymous                     (--anonymous-auth=true)       │
│            username system:anonymous, group system:unauthenticated  │
│                                                                     │
│  RULES                                                              │
│  • The FIRST module that returns success wins. Later modules are    │
│    not consulted, and their groups are NOT merged in.               │
│  • A module that cannot find its kind of credential returns         │
│    "no opinion" and the chain continues.                            │
│  • A module that finds a MALFORMED credential of its own kind may   │
│    fail the whole request with 401 instead of continuing.           │
│  • If every module declines and anonymous auth is off: 401.         │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Two practical consequences that bite people:

- **A client certificate beats a token.** If your kubeconfig has both `client-certificate` and `token` for the same user, the certificate is presented during the TLS handshake and is evaluated first. Your token is silently ignored, and you spend an hour wondering why your new token has no effect.
- **Groups do not accumulate across modules.** You cannot get groups from your certificate and additional groups from OIDC. Whichever module authenticated you supplies the complete group list, plus `system:authenticated`, which the framework adds for every successfully authenticated request.

### Inspecting What Your API Server Has Enabled

```bash
# On a kubeadm control plane node
sudo grep -E 'oidc|client-ca|token|anonymous|requestheader|authentication' \
  /etc/kubernetes/manifests/kube-apiserver.yaml

# Or, if the API server runs as a pod you can read
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n'
```

---

## X.509 Client Certificates

The default mechanism in every kubeadm cluster, and the one that CKA style exams focus on. It requires no external system: the cluster CA is already there.

### The Mapping Rule

```
┌───────────────────────────────────────────────────────────────────┐
│           X.509 Subject  →  Kubernetes Identity                    │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│   Subject: CN = alice, O = developers, O = payments                │
│            ▲           ▲                ▲                          │
│            │           └────────────────┴──► GROUPS                │
│            │                                 developers            │
│            │                                 payments              │
│            └──► USERNAME: alice                                    │
│                                                                    │
│   Every O (Organization) entry becomes one group.                  │
│   OU, L, ST, C and every other field are IGNORED.                  │
│                                                                    │
│   Plus, automatically: system:authenticated                        │
│                                                                    │
│   VALIDITY REQUIREMENTS                                            │
│   • Chains to a CA in --client-ca-file                             │
│   • Not expired (notBefore <= now <= notAfter)                     │
│   • Extended Key Usage includes clientAuth                         │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

### The Complete openssl Walkthrough

**Step 1: generate a private key.** This never leaves the user's machine. The cluster never sees it, never stores it, and cannot recover it.

```bash
# RSA, still the most widely compatible choice
openssl genrsa -out alice.key 2048

# Or ECDSA, smaller and faster, also accepted by the signer
openssl ecparam -name prime256v1 -genkey -noout -out alice.key

chmod 600 alice.key
```

**Step 2: create a certificate signing request.** The subject is where identity is declared. Note the repeated `/O=` to request two groups.

```bash
openssl req -new -key alice.key -out alice.csr \
  -subj "/CN=alice/O=developers/O=payments"
```

**Step 3: verify the subject before you send it anywhere.** A typo here becomes a wrong identity that authenticates perfectly and is authorized for nothing.

```bash
openssl req -in alice.csr -noout -subject
# subject=CN = alice, O = developers, O = payments

openssl req -in alice.csr -noout -text | head -n 12
```

**Step 4: get it signed.** Two options follow: the API driven way (preferred, auditable, see the next section) and the direct way.

### Direct Signing With the Cluster CA (Emergency and Lab Use)

This bypasses the API entirely, leaves no record in the cluster, and requires read access to the CA private key on a control plane node. Use it in a lab; prefer the CSR API in production.

```bash
# On a control plane node, as root
openssl x509 -req \
  -in alice.csr \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -CAcreateserial \
  -out alice.crt \
  -days 365 \
  -extfile <(printf "extendedKeyUsage=clientAuth")
```

```bash
# Confirm what was actually issued
openssl x509 -in alice.crt -noout -subject -issuer -dates -ext extendedKeyUsage
```

```
subject=CN = alice, O = developers, O = payments
issuer=CN = kubernetes
notBefore=Jan  1 00:00:00 2025 GMT
notAfter=Jan  1 00:00:00 2026 GMT
X509v3 Extended Key Usage:
    TLS Web Client Authentication
```

### The Hard Truths About Certificate Users

```
┌────────────────────────────────────────────────────────────────────┐
│              CERTIFICATE AUTHENTICATION LIMITATIONS                 │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ❌ NO REVOCATION. Kubernetes does not consult a CRL and does not  │
│     support OCSP. A leaked client certificate is valid until it     │
│     expires. The only real remedies are:                            │
│        • let it expire (so: short lifetimes)                        │
│        • delete every RBAC binding naming that user or group        │
│        • rotate the cluster CA, which invalidates EVERYTHING        │
│                                                                     │
│  ❌ NO CHANGE WITHOUT REISSUE. To add a group you must generate a  │
│     new CSR and get a new certificate. Groups are baked in.         │
│                                                                     │
│  ❌ DOES NOT SCALE TO HUMANS. Every joiner, mover and leaver is a  │
│     manual certificate operation. Use OIDC for people once you      │
│     have more than a handful.                                       │
│                                                                     │
│  ⚠️  ANY CA IN --client-ca-file CAN MINT ANY IDENTITY, including   │
│     CN=kubernetes-admin with O=system:masters. Treat that file      │
│     and every key behind it as root credentials for the cluster.    │
│                                                                     │
│  ✅ GOOD FOR: components, break glass access, small teams, labs,   │
│     and anything that must work when the identity provider is down. │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

---

## The CertificateSigningRequest API

The in-cluster way to get a client certificate signed: auditable, RBAC controlled, and it never exposes the CA private key.

### The Object

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice                       # cluster scoped, must be unique
spec:
  # Base64 of the PEM CSR produced by openssl. NOT base64 of the DER,
  # and it must have no embedded newlines in the YAML value.
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNUL...

  # WHICH signer handles it. This is the field that decides everything.
  signerName: kubernetes.io/kube-apiserver-client

  # Optional. Minimum 600 (10 minutes). The signer may issue a shorter
  # certificate but never a longer one.
  expirationSeconds: 86400          # 24 hours

  usages:
  - client auth                     # required for this signer
status: {}                          # filled in by approver and signer
```

### The Built-in Signers

| signerName | Purpose | Who normally approves | Resulting identity |
|------------|---------|-----------------------|--------------------|
| `kubernetes.io/kube-apiserver-client` | Generic client certificate for a human or automation | A human, via `kubectl certificate approve` | CN and O from the CSR |
| `kubernetes.io/kube-apiserver-client-kubelet` | Kubelet client certificate used to talk to the API server | Auto approved by the controller manager for valid node requests | `system:node:<nodename>`, group `system:nodes` |
| `kubernetes.io/kubelet-serving` | The kubelet's own HTTPS serving certificate | Requires an approver; not auto approved by default | Serving cert, not an identity |
| `kubernetes.io/legacy-unknown` | Legacy catch all; **not honoured by the built-in signer** | n/a | n/a |

> ⚠️ **The single most common failure**: a CSR that is created, approved, and then sits forever with an empty `status.certificate`. That means **no signer picked it up**. Ninety percent of the time the `signerName` is wrong (a typo, or `legacy-unknown`), and the rest of the time an external signer is expected but not installed.

### Creating the CSR From a File

Never hand type the base64. Generate it:

```bash
# Single line, no wrapping. This is what breaks people's manifests.
REQ=$(base64 -w 0 < alice.csr)          # GNU coreutils
# REQ=$(base64 < alice.csr | tr -d '\n')  # macOS / BSD

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: ${REQ}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
  - client auth
EOF
```

### The Approval Lifecycle

```
┌──────────────────────────────────────────────────────────────────────┐
│                    CSR LIFECYCLE                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   kubectl apply -f csr.yaml                                           │
│            │                                                          │
│            ▼                                                          │
│   ┌──────────────┐                                                    │
│   │   Pending    │   status.conditions is empty                       │
│   └──────┬───────┘   status.certificate is empty                      │
│          │                                                            │
│          ├──── kubectl certificate deny alice ──► ┌──────────┐        │
│          │        writes condition Denied         │  Denied  │        │
│          │        TERMINAL: cannot be approved    └──────────┘        │
│          │        afterwards, delete and redo                         │
│          │                                                            │
│          └──── kubectl certificate approve alice                      │
│                   writes condition Approved                           │
│                   (an UPDATE on the `approval` SUBRESOURCE)           │
│                        │                                              │
│                        ▼                                              │
│                 ┌──────────────┐                                      │
│                 │   Approved   │  approved but NOT yet issued         │
│                 └──────┬───────┘                                      │
│                        │                                              │
│                        │  kube-controller-manager's csrsigner         │
│                        │  controller notices, signs with              │
│                        │  --cluster-signing-cert-file / -key-file     │
│                        ▼                                              │
│                 ┌──────────────────────┐                              │
│                 │ Approved,Issued      │  status.certificate is now   │
│                 └──────────────────────┘  a base64 PEM certificate    │
│                                                                       │
│   NOTE: CSR objects are garbage collected after they expire, and      │
│   the signed certificate is only in status.certificate. EXTRACT IT.   │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
kubectl get csr
# NAME    AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION  CONDITION
# alice   5s    kubernetes.io/kube-apiserver-client   kubernetes-admin   365d               Pending

kubectl certificate approve alice

kubectl get csr alice
# NAME    AGE   SIGNERNAME                            REQUESTOR          CONDITION
# alice   20s   kubernetes.io/kube-apiserver-client   kubernetes-admin   Approved,Issued

# Extract the issued certificate
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt

# Verify what you got
openssl x509 -in alice.crt -noout -subject -issuer -dates
```

Reject instead, when the request is wrong:

```bash
kubectl certificate deny alice
# Denied is terminal. To retry:
kubectl delete csr alice && kubectl apply -f csr.yaml
```

### RBAC Required to Request, Approve and Sign

Three separate privileges, deliberately separable so that requesting and approving can be different people.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: csr-requester
rules:
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests"]
  verbs: ["create", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: csr-approver
rules:
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests"]
  verbs: ["get", "list", "watch"]
# Approval is a SUBRESOURCE update, not a normal update on the object.
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests/approval"]
  verbs: ["update"]
# And you must be allowed to approve FOR THAT SPECIFIC SIGNER.
- apiGroups: ["certificates.k8s.io"]
  resources: ["signers"]
  resourceNames: ["kubernetes.io/kube-apiserver-client"]
  verbs: ["approve"]
```

> ⚠️ The `signers` resource with the `approve` verb is the piece everyone forgets. Without it, `kubectl certificate approve` returns 403 even though the user can update the `approval` subresource. The built-in ClusterRoles `system:certificates.k8s.io:certificatesigningrequests:nodeclient` and `:selfnodeclient` follow exactly this pattern for kubelets.

---

## Service Account Bearer Tokens

Full treatment lives in [service-accounts.md](service-accounts.md); here is what you need in the context of authentication.

A service account token is a **signed JWT** presented as `Authorization: Bearer <token>`. The API server validates the signature with the public key in `--service-account-key-file`, and for bound tokens it additionally checks that the referenced Pod, ServiceAccount and Secret still exist, that the audience matches `--api-audiences`, and that the token has not expired.

```
┌──────────────────────────────────────────────────────────────────┐
│            Service Account Token → Identity                       │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  JWT claim  sub: system:serviceaccount:dev:build-bot              │
│                                                                   │
│  USERNAME  system:serviceaccount:dev:build-bot                    │
│  UID       the ServiceAccount object's metadata.uid               │
│  GROUPS    system:serviceaccounts                                 │
│            system:serviceaccounts:dev                             │
│            system:authenticated                                   │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

Mint one on demand, without creating any Secret:

```bash
kubectl -n dev create token build-bot --duration=10m
```

```bash
# Verify what the server makes of an arbitrary token: the TokenReview API
TOKEN=$(kubectl -n dev create token build-bot)
cat <<EOF | kubectl create -f - -o yaml
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: ${TOKEN}
EOF
```

```yaml
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: "[redacted by the server]"
status:
  audiences:
  - https://kubernetes.default.svc.cluster.local
  authenticated: true
  user:
    groups:
    - system:serviceaccounts
    - system:serviceaccounts:dev
    - system:authenticated
    uid: 6f1c1e2a-0b0a-4a1f-9f0a-1c2d3e4f5a6b
    username: system:serviceaccount:dev:build-bot
```

> ⚠️ Creating a TokenReview is a privileged operation (the built-in ClusterRole `system:auth-delegator` grants it). Do not hand it out casually: the ability to validate arbitrary tokens is useful to an attacker.

---

## OpenID Connect

The right answer for human users at any real scale. The cluster trusts an external identity provider and never sees a password.

### API Server Flags

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml  (kubeadm static pod)
spec:
  containers:
  - command:
    - kube-apiserver

    # REQUIRED. Must be an https URL. Must match the `iss` claim EXACTLY,
    # including or excluding a trailing slash.
    - --oidc-issuer-url=https://accounts.example.com

    # REQUIRED. Must appear in the token's `aud` claim.
    - --oidc-client-id=kubernetes

    # Which claim becomes the username. Default: sub
    # `sub` is opaque and stable; `email` is readable but can be reassigned.
    - --oidc-username-claim=email

    # Which claim becomes the groups list. Must be an array of strings.
    - --oidc-groups-claim=groups

    # Prefix to avoid collisions with existing users.
    # "-" disables prefixing entirely.
    - --oidc-username-prefix=oidc:

    - --oidc-groups-prefix=oidc:

    # PEM CA bundle used to verify the provider's TLS certificate.
    # Omit to use the host trust store.
    - --oidc-ca-file=/etc/kubernetes/pki/oidc-ca.pem

    # Optional hardening: require an exact claim value. Repeatable.
    - --oidc-required-claim=hd=example.com

    # Optional: restrict accepted signing algorithms. Default RS256.
    - --oidc-signing-algs=RS256
```

> ⚠️ **Prefix behaviour is subtle.** If `--oidc-username-claim` is set to anything other than `email` and you do not set `--oidc-username-prefix`, the API server prefixes usernames with the issuer URL followed by `#`. Your RBAC bindings must then reference `https://accounts.example.com#alice`, not `alice`. Always set the prefix explicitly (`oidc:` is the conventional choice) so your bindings are predictable, and never use a prefix that could collide with `system:`.

### The Token Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                       OIDC AUTHENTICATION FLOW                        │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ONE TIME (browser)                                                   │
│  ┌────────┐  1. login  ┌──────────────────┐                           │
│  │  user  │───────────►│ Identity Provider │                          │
│  │        │◄───────────│  (Okta, Entra ID, │                          │
│  └────────┘  2. id_token│  Keycloak, Dex)  │                          │
│                 +      └──────────────────┘                           │
│              refresh_token                                            │
│                 │                                                     │
│                 ▼  3. stored in kubeconfig or by a credential plugin  │
│                                                                       │
│  EVERY REQUEST                                                        │
│  ┌────────┐                                                           │
│  │kubectl │  4. Authorization: Bearer <id_token>                      │
│  └───┬────┘                                                           │
│      │                                                                │
│      ▼                                                                │
│  ┌──────────────────────────────────────────────────────────────┐     │
│  │ kube-apiserver                                               │     │
│  │  5. Fetch and cache the provider's JWKS from                 │     │
│  │     <issuer>/.well-known/openid-configuration                │     │
│  │  6. Verify signature, iss, aud, exp, nbf                     │     │
│  │  7. username = <prefix> + <username-claim>                   │     │
│  │     groups   = <prefix> + each entry of <groups-claim>       │     │
│  └──────────────────────────────────────────────────────────────┘     │
│                                                                       │
│  KEY POINT: the API server NEVER calls the provider per request.      │
│  Validation is offline signature checking. That means:                │
│    • it is fast                                                       │
│    • a revoked user keeps access until the id_token EXPIRES           │
│      (which is why id_token lifetimes should be short)                │
│                                                                       │
│  REFRESH: kubectl (or the exec plugin) uses the refresh_token to      │
│  obtain a new id_token when the old one expires. The API server is    │
│  not involved in refresh at all.                                      │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### kubectl Side: Auth Provider (Legacy) vs Exec Plugin (Current)

The in-tree `oidc` auth provider is legacy. The supported pattern is a **client-go credential plugin** declared with `exec`:

```yaml
apiVersion: v1
kind: Config
users:
- name: alice-oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: kubectl-oidc_login          # for example, the kubelogin plugin
      args:
      - get-token
      - --oidc-issuer-url=https://accounts.example.com
      - --oidc-client-id=kubernetes
      - --oidc-extra-scope=email
      - --oidc-extra-scope=groups
      # Set to true only if the binary needs a TTY or a browser prompt
      interactiveMode: IfAvailable
      provideClusterInfo: false
      env:
      - name: EXAMPLE_VAR
        value: "1"
```

How it works: kubectl runs the command, the command writes an `ExecCredential` JSON document to stdout, and kubectl uses the token from it and caches it until `expirationTimestamp`.

```json
{
  "apiVersion": "client.authentication.k8s.io/v1",
  "kind": "ExecCredential",
  "status": {
    "expirationTimestamp": "2025-01-01T01:00:00Z",
    "token": "eyJhbGciOiJSUzI1NiIsImtpZCI6..."
  }
}
```

The same mechanism powers cloud provider CLIs (`aws eks get-token`, `gcloud`, `az`), which is why those kubeconfigs look like this too.

> ⚠️ **Security note**: an `exec` stanza in a kubeconfig runs an arbitrary binary on your machine with your privileges. Never source a kubeconfig from an untrusted place. Read the `command` field before you use a file someone sent you.

The legacy in-tree form, which you will still meet in older documentation:

```yaml
users:
- name: alice-oidc
  user:
    auth-provider:
      name: oidc
      config:
        idp-issuer-url: https://accounts.example.com
        client-id: kubernetes
        client-secret: <secret>
        id-token: <jwt>
        refresh-token: <jwt>
```

> 📌 Newer Kubernetes releases additionally support a **structured authentication configuration file** passed with `--authentication-config`, which can define multiple JWT authenticators and use CEL expressions to map claims to usernames and groups. Consult the documentation for your exact cluster version before relying on it, and keep using the `--oidc-*` flags where the structured file is not available.

---

## Webhook Token Authentication

When your token is not a JWT the API server understands, delegate validation to a service you run.

```yaml
# /etc/kubernetes/webhook-auth.yaml
# This is an ordinary kubeconfig file. `clusters` describes the WEBHOOK,
# and `users` describes how the API SERVER authenticates TO it.
apiVersion: v1
kind: Config
clusters:
- name: token-validator
  cluster:
    server: https://auth.internal.example.com/authenticate
    certificate-authority: /etc/kubernetes/pki/webhook-ca.pem
users:
- name: apiserver
  user:
    client-certificate: /etc/kubernetes/pki/apiserver-webhook-client.crt
    client-key: /etc/kubernetes/pki/apiserver-webhook-client.key
contexts:
- name: webhook
  context:
    cluster: token-validator
    user: apiserver
current-context: webhook
```

```yaml
    # kube-apiserver flags
    - --authentication-token-webhook-config-file=/etc/kubernetes/webhook-auth.yaml
    - --authentication-token-webhook-cache-ttl=2m
    - --authentication-token-webhook-version=v1
```

The API server POSTs a `TokenReview` and expects one back with `status` filled in:

```yaml
# Request sent by the API server
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: "opaque-token-string"
  audiences:
  - https://kubernetes.default.svc.cluster.local
```

```yaml
# Success response from your webhook
apiVersion: authentication.k8s.io/v1
kind: TokenReview
status:
  authenticated: true
  audiences:
  - https://kubernetes.default.svc.cluster.local
  user:
    username: alice
    uid: "42"
    groups:
    - developers
    - system:authenticated
    extra:
      department:
      - payments
```

```yaml
# Failure response. Do NOT return an HTTP error for an invalid token;
# return 200 with authenticated: false.
apiVersion: authentication.k8s.io/v1
kind: TokenReview
status:
  authenticated: false
  error: "token expired"
```

> ⚠️ The webhook is on the critical path of **every** request that carries an unrecognised bearer token. If it is slow, the whole cluster feels slow; if it is down, those users cannot authenticate at all. Cache aggressively with `--authentication-token-webhook-cache-ttl`, run it highly available, and remember that a longer cache TTL is exactly a longer revocation delay.

---

## Authenticating Proxy Headers

A trusted front proxy terminates the user's session and asserts the identity in HTTP headers. This is how the aggregation layer authenticates extension API servers, and how some enterprise SSO gateways integrate.

```yaml
    # kube-apiserver flags
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-username-headers=X-Remote-User
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
```

```
┌───────────────────────────────────────────────────────────────────┐
│                 AUTHENTICATING PROXY                               │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│  user ──(SSO session, SAML, whatever)──► ┌──────────────┐          │
│                                          │ trusted proxy │         │
│                                          └───────┬───────┘         │
│                                                  │                 │
│           mTLS with a certificate signed by      │                 │
│           the front-proxy CA, CN must be in      │                 │
│           --requestheader-allowed-names          │                 │
│                                                  ▼                 │
│                                          ┌────────────────┐        │
│   X-Remote-User: alice                   │ kube-apiserver │        │
│   X-Remote-Group: developers             └────────────────┘        │
│   X-Remote-Group: payments                                         │
│   X-Remote-Extra-Scopes: read                                      │
│                                                                    │
│  ⚠️  THE HEADERS ARE TRUSTED ONLY BECAUSE THE CLIENT CERTIFICATE   │
│      IS. If any untrusted client could reach the API server        │
│      directly with a front-proxy certificate, it could claim to    │
│      be anyone, including a member of system:masters.              │
│      The proxy MUST strip these headers from inbound traffic.      │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

Header values are URL encoded when they contain non ASCII characters, and repeated headers produce multiple groups.

---

## Anonymous Requests

```yaml
    - --anonymous-auth=true        # default for kube-apiserver
```

When every other authenticator declines and anonymous auth is enabled, the request proceeds with:

```
username: system:anonymous
groups:   [system:unauthenticated]
```

It then still has to pass authorization, and out of the box an anonymous request can reach almost nothing. What it *can* reach is deliberate: the health and discovery endpoints that load balancers and clients need before they have credentials.

```bash
# From a machine with no credentials at all
curl -k https://<apiserver>:6443/version
curl -k https://<apiserver>:6443/healthz
curl -k https://<apiserver>:6443/livez
curl -k https://<apiserver>:6443/readyz

# And this, which is the useful negative test:
curl -k https://<apiserver>:6443/api/v1/namespaces/default/pods
```

```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "status": "Failure",
  "message": "pods is forbidden: User \"system:anonymous\" cannot list resource \"pods\" in API group \"\" in the namespace \"default\"",
  "reason": "Forbidden",
  "code": 403
}
```

> ⚠️ **The classic catastrophic misconfiguration** is binding `cluster-admin` to the group `system:unauthenticated` or to `system:anonymous`, usually while "fixing" a dashboard. That opens the entire cluster to anyone who can reach port 6443. Audit for it:

```bash
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.subjects[]? |
    (.name=="system:anonymous" or .name=="system:unauthenticated")) |
  .metadata.name'
```

Setting `--anonymous-auth=false` is the hard fix, but note that it also affects unauthenticated health probes; make sure your load balancer probes an endpoint that still works, or give them credentials.

---

## Static Token File and Basic Auth

**Historical. Do not build anything new on these.**

### Static Token File

```yaml
    - --token-auth-file=/etc/kubernetes/tokens.csv
```

```csv
# token,user,uid,"group1,group2,group3"
02b50b05283e98dd0fd71db496ef01e8,alice,1001,"developers,payments"
f8c9a1d2e3b4a5c6d7e8f9a0b1c2d3e4,cicd,1002,"automation"
```

Why it is a bad idea:

```
┌──────────────────────────────────────────────────────────────────┐
│  STATIC TOKEN FILE: EVERY PROPERTY IS WRONG                      │
├──────────────────────────────────────────────────────────────────┤
│  • Tokens NEVER expire                                            │
│  • Stored in PLAINTEXT on every control plane node                │
│  • Changing the file requires an API SERVER RESTART               │
│  • No revocation without that restart                             │
│  • The same file must be identical on every control plane replica │
│  • Anyone who reads the file becomes every user in it             │
└──────────────────────────────────────────────────────────────────┘
```

### Basic Authentication

The `--basic-auth-file` flag and HTTP Basic authentication support were **removed in Kubernetes 1.19**. If you find a guide that tells you to use it, the guide predates that release and everything else in it should be treated with suspicion.

Use instead, in order of preference: OIDC for humans, service account tokens for workloads, client certificates for components and break glass.

---

## Bootstrap Tokens and Node Join

A node that is joining has no credentials yet, and cannot have a kubelet certificate before it has talked to the API server. Bootstrap tokens break that circular dependency: a short lived, low privilege credential whose only job is to let a node request its real certificate.

```yaml
    - --enable-bootstrap-token-auth=true
```

### Token Format

```
┌────────────────────────────────────────────────────────────────┐
│                  BOOTSTRAP TOKEN FORMAT                         │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│        abcdef.0123456789abcdef                                  │
│        └────┘ └──────────────┘                                  │
│        token-id   token-secret                                  │
│        6 chars    16 chars                                      │
│        [a-z0-9]   [a-z0-9]                                      │
│                                                                 │
│   The ID is PUBLIC (it names the Secret). The secret half is    │
│   the actual credential. Both halves are needed to authenticate.│
│                                                                 │
│   RESULTING IDENTITY                                            │
│     username: system:bootstrap:abcdef                           │
│     groups:   system:bootstrappers                              │
│               system:authenticated                              │
│               + anything listed in auth-extra-groups            │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

### The Secret Shape

```yaml
apiVersion: v1
kind: Secret
metadata:
  # MUST be exactly bootstrap-token-<token-id>
  name: bootstrap-token-abcdef
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  # The two halves, stored separately
  token-id: abcdef
  token-secret: "0123456789abcdef"

  # RFC3339 UTC. After this instant the token stops authenticating
  # and the tokencleaner controller deletes the Secret.
  expiration: "2025-01-02T00:00:00Z"

  # Allow this token to authenticate to the API server
  usage-bootstrap-authentication: "true"
  # Allow it to be used for signing the cluster-info ConfigMap
  usage-bootstrap-signing: "true"

  # Extra groups granted. MUST start with system:bootstrappers:
  auth-extra-groups: system:bootstrappers:kubeadm:default-node-token

  description: "Token generated by kubeadm for joining worker nodes"
```

### The kubeadm Join Sequence

```
┌────────────────────────────────────────────────────────────────────────┐
│                      NODE BOOTSTRAP FLOW                                │
├────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ON THE CONTROL PLANE                                                   │
│    kubeadm token create --print-join-command                            │
│      → creates the bootstrap-token-<id> Secret (default TTL 24h)        │
│                                                                         │
│  ON THE JOINING NODE                                                    │
│    kubeadm join 10.0.0.10:6443 \                                        │
│      --token abcdef.0123456789abcdef \                                  │
│      --discovery-token-ca-cert-hash sha256:<hex>                        │
│                                                                         │
│  1. DISCOVERY                                                           │
│     Fetch the cluster-info ConfigMap from kube-public.                  │
│     Verify the CA in it against --discovery-token-ca-cert-hash,         │
│     which prevents a man in the middle from supplying a fake CA.        │
│              │                                                          │
│  2. AUTHENTICATE AS system:bootstrap:abcdef                             │
│     Using the token as a bearer token.                                  │
│              │                                                          │
│  3. CREATE A CSR                                                        │
│     signerName kubernetes.io/kube-apiserver-client-kubelet              │
│     CN = system:node:<nodename>, O = system:nodes                       │
│     Allowed by the ClusterRole                                          │
│     system:certificates.k8s.io:certificatesigningrequests:nodeclient,   │
│     bound to the group system:bootstrappers:kubeadm:default-node-token  │
│              │                                                          │
│  4. AUTO APPROVAL                                                       │
│     The csrapproving controller in kube-controller-manager approves it. │
│              │                                                          │
│  5. SIGNING AND DELIVERY                                                │
│     The kubelet writes the key and certificate to                       │
│     /var/lib/kubelet/pki/kubelet-client-current.pem and points          │
│     /etc/kubernetes/kubelet.conf at it.                                 │
│              │                                                          │
│  6. THE BOOTSTRAP TOKEN IS NEVER USED AGAIN                             │
│     From here the kubelet authenticates as system:node:<nodename>       │
│     and rotates its own certificate before expiry.                      │
│                                                                         │
└────────────────────────────────────────────────────────────────────────┘
```

```bash
# Managing bootstrap tokens
kubeadm token list
kubeadm token create --ttl 2h --description "join batch 3"
kubeadm token create --print-join-command
kubeadm token delete abcdef.0123456789abcdef

# The CA hash needed for discovery, computed from the CA public key
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt |
  openssl rsa -pubin -outform der 2>/dev/null |
  openssl dgst -sha256 -hex | sed 's/^.* /sha256:/'

# See the underlying Secrets
kubectl -n kube-system get secrets --field-selector type=bootstrap.kubernetes.io/token
```

> ⚠️ A bootstrap token is a **credential that lets an unknown machine become a node**. Default TTL is 24 hours for a reason. Do not create tokens with `--ttl 0` (never expires) and leave them lying around, and never paste a join command into a ticket, a chat channel or a build log.

---

## Node Authentication

Kubelets are ordinary certificate users with a naming convention that the rest of the system depends on.

```
┌───────────────────────────────────────────────────────────────────┐
│                     NODE IDENTITY                                  │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│   Certificate subject: CN = system:node:worker-01                  │
│                        O  = system:nodes                           │
│                                                                    │
│   USERNAME  system:node:worker-01                                  │
│   GROUPS    system:nodes, system:authenticated                     │
│                                                                    │
│   THE NAME AFTER system:node: MUST EQUAL THE Node OBJECT NAME.     │
│   If it does not, the Node authorizer cannot match the identity    │
│   to a Node, and the kubelet is refused access to the Secrets,     │
│   ConfigMaps and Pods it needs. Symptom: pods stuck in             │
│   ContainerCreating with authorization errors in the kubelet log.  │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

Three mechanisms work together, and all three matter:

| Mechanism | Type | What it does |
|-----------|------|--------------|
| `system:node:<name>` identity | Authentication | Names the kubelet as a specific node |
| **Node authorizer** (`--authorization-mode=Node,...`) | Authorization | Grants each kubelet access only to objects related to pods scheduled on *its* node |
| **NodeRestriction** (`--enable-admission-plugins=NodeRestriction`) | Admission | Stops a kubelet modifying other nodes, and stops it setting labels on itself that would affect scheduling or Node authorization |

Without the Node authorizer, a single compromised kubelet can read **every Secret in the cluster**. Without NodeRestriction, it can relabel itself and attract other workloads. Both are on by default in kubeadm clusters; verify rather than assume:

```bash
sudo grep -E 'authorization-mode|enable-admission-plugins' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

```bash
# Inspect a live kubelet certificate
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem \
  -noout -subject -dates
# subject=O = system:nodes, CN = system:node:worker-01
```

> 📖 **See Also**: [kubelet.md](kubelet.md), [worker-node.md](worker-node.md).

---

## Special Groups and Reserved Prefixes

```
┌──────────────────────────────────────────────────────────────────────┐
│                    SYSTEM GROUPS AND USERS                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  system:authenticated                                                 │
│      Added automatically to EVERY successfully authenticated          │
│      request, whatever the mechanism. Binding anything to this        │
│      group grants it to every identity in the cluster, including      │
│      every service account in every namespace.                        │
│                                                                       │
│  system:unauthenticated                                               │
│      The group of anonymous requests. Paired with the username        │
│      system:anonymous.                                                │
│                                                                       │
│  system:masters                                                       │
│      HARDCODED BYPASS. Members skip RBAC evaluation entirely and      │
│      are unconditionally allowed. Not revocable by deleting a         │
│      binding, because there is no binding. The only way out is to     │
│      stop issuing certificates with O=system:masters and rotate       │
│      the CA if one leaks.                                             │
│                                                                       │
│  system:nodes                                                         │
│      Every kubelet, via O=system:nodes in its client certificate.     │
│      Paired with usernames of the form system:node:<nodename>.        │
│                                                                       │
│  system:serviceaccounts                                               │
│      Every service account in the cluster.                            │
│  system:serviceaccounts:<namespace>                                   │
│      Every service account in one namespace.                          │
│                                                                       │
│  system:bootstrappers                                                 │
│  system:bootstrappers:kubeadm:default-node-token                      │
│      Bootstrap token identities during node join.                     │
│                                                                       │
│  system:kube-controller-manager, system:kube-scheduler,               │
│  system:kube-proxy                                                    │
│      Control plane component identities, each with a matching         │
│      system: ClusterRole and ClusterRoleBinding.                      │
│                                                                       │
│  RESERVED PREFIX                                                      │
│      The `system:` prefix is reserved. The API server REJECTS         │
│      usernames and groups beginning with `system:` from OIDC,         │
│      webhook and proxy authenticators, so an identity provider        │
│      cannot mint a system:masters member. Certificates issued by      │
│      a CA in --client-ca-file are NOT subject to that protection,     │
│      which is exactly why that CA is so sensitive.                    │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Who is in system:masters? You cannot ask. You can only check what
# certificates exist and what your CA has issued. This is the strongest
# argument for never using system:masters for day to day work.
sudo openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt \
  -noout -subject
```

---

## Impersonation

Impersonation lets a privileged identity execute a request **as someone else**. Its most valuable everyday use is testing RBAC without holding anyone else's credentials.

```bash
# Act as a user
kubectl get pods --as=alice -n dev

# Act as a user in specific groups (repeat the flag per group)
kubectl get pods --as=alice --as-group=developers --as-group=payments -n dev

# Act as a specific UID (useful when an authorization webhook keys on UID)
kubectl get pods --as=alice --as-uid=1001 -n dev

# Act as a service account: use its full username
kubectl auth can-i list secrets \
  --as=system:serviceaccount:dev:build-bot -n dev

# Combine with can-i, which is the real workhorse
kubectl auth can-i --list --as=alice -n dev
```

### What the Flags Become on the Wire

```
--as alice                 →  Impersonate-User: alice
--as-group developers      →  Impersonate-Group: developers
--as-uid 1001              →  Impersonate-Uid: 1001
(extra fields)             →  Impersonate-Extra-<key>: <value>
```

### RBAC Required to Impersonate

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rbac-tester
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
# Required only when --as-uid is used
- apiGroups: ["authentication.k8s.io"]
  resources: ["uids"]
  verbs: ["impersonate"]
# Required only for Impersonate-Extra-scopes headers
- apiGroups: ["authentication.k8s.io"]
  resources: ["userextras/scopes"]
  verbs: ["impersonate"]
```

Scope it down with `resourceNames`, which is how you build a safe testing role:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: impersonate-support-only
rules:
- apiGroups: [""]
  resources: ["users"]
  resourceNames: ["alice", "bob"]      # these two humans, nobody else
  verbs: ["impersonate"]
- apiGroups: [""]
  resources: ["groups"]
  resourceNames: ["developers"]        # never system:masters
  verbs: ["impersonate"]
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                    HOW IMPERSONATION IS CHECKED                       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  1. The ORIGINAL user authenticates normally.                         │
│  2. The API server checks: may the original user `impersonate`        │
│     this users / groups / serviceaccounts / uids resource?            │
│         NO  → 403, naming the ORIGINAL user                           │
│         YES → continue                                                │
│  3. The identity is REPLACED. Authorization for the actual request    │
│     is evaluated against the IMPERSONATED identity only. The          │
│     original user's own permissions do not apply.                     │
│  4. The audit event records BOTH: `user` is the impersonated one,     │
│     `impersonatedUser` and the original are both retained.            │
│                                                                       │
│  ⚠️  Granting `impersonate` on groups without resourceNames is        │
│      equivalent to granting cluster-admin, because the holder can     │
│      simply impersonate the group system:masters.                     │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## kubeconfig Anatomy

A kubeconfig is three independent lists plus a pointer. Everything confusing about kubeconfig becomes simple once you see that shape.

```
┌───────────────────────────────────────────────────────────────────┐
│                        kubeconfig STRUCTURE                        │
├───────────────────────────────────────────────────────────────────┤
│                                                                    │
│   clusters:  WHERE          server URL + CA to trust               │
│   users:     WHO            credentials                            │
│   contexts:  WHICH COMBO    cluster + user + default namespace     │
│   current-context:          the context in effect right now        │
│                                                                    │
│      clusters ────┐                                                │
│                   ├──► context ──► current-context                 │
│      users ───────┘                                                │
│                                                                    │
│   Clusters and users are INDEPENDENT. One user can have contexts   │
│   against several clusters; one cluster can be reached by several  │
│   users. A context is just a named pairing.                        │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

### A Fully Annotated Example

```yaml
apiVersion: v1
kind: Config
preferences: {}

# WHERE ------------------------------------------------------------
clusters:
- name: production
  cluster:
    server: https://api.prod.example.com:6443
    # Inline, base64 encoded PEM. Portable: the file travels with it.
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
- name: lab
  cluster:
    server: https://10.0.0.10:6443
    # Path on disk. Not portable, but easy to rotate.
    certificate-authority: /etc/kubernetes/pki/ca.crt
- name: dangerous
  cluster:
    server: https://10.0.0.99:6443
    # Disables server certificate verification. Debugging only:
    # this makes you vulnerable to a man in the middle.
    insecure-skip-tls-verify: true
    # Override the hostname used for TLS verification (SNI / SAN mismatch)
    tls-server-name: kubernetes.default.svc

# WHO --------------------------------------------------------------
users:

# Style 1: client certificate by path
- name: alice-file
  user:
    client-certificate: /home/alice/.certs/alice.crt
    client-key: /home/alice/.certs/alice.key

# Style 2: client certificate embedded (base64 PEM). Self contained.
- name: alice-embedded
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ...

# Style 3: static bearer token (service account token, bootstrap token)
- name: build-bot
  user:
    token: eyJhbGciOiJSUzI1NiIsImtpZCI6IlF...

# Style 4: token read from a file, re-read on each use.
#          Right choice for a rotating projected token.
- name: build-bot-file
  user:
    tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token

# Style 5: exec credential plugin (OIDC, cloud CLIs). Current best practice.
- name: alice-oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: kubectl-oidc_login
      args: ["get-token", "--oidc-issuer-url=https://accounts.example.com",
             "--oidc-client-id=kubernetes"]
      interactiveMode: IfAvailable

# Style 6: impersonation baked into the user entry
- name: alice-as-bob
  user:
    token: eyJhbGciOiJSUzI1NiIs...
    as: bob
    as-groups: ["developers"]

# WHICH COMBO ------------------------------------------------------
contexts:
- name: alice@production
  context:
    cluster: production
    user: alice-embedded
    namespace: payments        # the default -n for this context
- name: admin@lab
  context:
    cluster: lab
    user: alice-file
    namespace: default

current-context: alice@production
```

### Precedence: How kubectl Decides

```
┌──────────────────────────────────────────────────────────────────┐
│              WHICH CREDENTIAL AND NAMESPACE WIN                   │
├──────────────────────────────────────────────────────────────────┤
│  HIGHEST                                                          │
│    1. Explicit command line flags                                 │
│         --context, --user, --cluster, --namespace, --server,      │
│         --token, --client-certificate                             │
│    2. The context named by --context                              │
│    3. current-context in the kubeconfig                           │
│    4. Defaults (namespace "default")                              │
│  LOWEST                                                           │
│                                                                   │
│  AND WITHIN A USER ENTRY, if several credentials are present:     │
│    client certificate  >  exec plugin  >  token / tokenFile       │
│    (the certificate is offered during the TLS handshake, so it    │
│     is evaluated by the first authenticator in the chain)         │
└──────────────────────────────────────────────────────────────────┘
```

### The Commands

```bash
# ---- Inspect ----
kubectl config view                      # secrets redacted
kubectl config view --raw                # EVERYTHING, including keys
kubectl config view --minify             # only the current context
kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}'
kubectl config get-contexts              # the * marks the current one
kubectl config get-clusters
kubectl config get-users
kubectl config current-context

# ---- Switch ----
kubectl config use-context alice@production
kubectl config set-context --current --namespace=payments

# ---- Build ----
kubectl config set-cluster production \
  --server=https://api.prod.example.com:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true

kubectl config set-credentials alice \
  --client-certificate=alice.crt \
  --client-key=alice.key \
  --embed-certs=true

kubectl config set-credentials build-bot --token="${TOKEN}"

kubectl config set-context alice@production \
  --cluster=production \
  --user=alice \
  --namespace=payments

# ---- Remove ----
kubectl config delete-context alice@production
kubectl config delete-cluster production
kubectl config unset users.alice

# ---- Target a specific file ----
kubectl --kubeconfig=/tmp/alice.kubeconfig config view
KUBECONFIG=/tmp/alice.kubeconfig kubectl auth whoami
```

> ⚠️ `--embed-certs=true` is what turns a kubeconfig into a single portable file. Without it, `set-credentials` writes **paths**, and the file is useless on any other machine. It is also what makes the file itself a secret worth protecting: `chmod 600`.

---

## The KUBECONFIG Environment Variable and Merging

```bash
# Default location
~/.kube/config

# Override with a single file
export KUBECONFIG=/etc/kubernetes/admin.conf

# Or a colon separated LIST, which kubectl MERGES (semicolon on Windows)
export KUBECONFIG=~/.kube/config:~/.kube/prod.conf:~/.kube/lab.conf
```

```
┌──────────────────────────────────────────────────────────────────┐
│                    MERGE SEMANTICS                                │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  • Files are read LEFT TO RIGHT.                                  │
│  • For a conflicting key (same cluster/user/context name),         │
│    THE FIRST FILE WINS. Later definitions are discarded.           │
│  • current-context comes from the FIRST file that sets it.         │
│  • WRITES (config set-context, use-context, ...) go to the         │
│    FIRST file in the list, not to all of them.                     │
│  • Missing files in the list are skipped silently, which is a      │
│    frequent source of "my context disappeared".                    │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

```bash
# Flatten a merged view into one portable file
KUBECONFIG=~/.kube/config:~/.kube/prod.conf \
  kubectl config view --flatten --raw > ~/.kube/merged.config

chmod 600 ~/.kube/merged.config
mv ~/.kube/merged.config ~/.kube/config
```

`--flatten` inlines every file reference (certificates, keys) so the result is self contained; `--raw` keeps the credentials rather than redacting them. Use both together or the output is not usable.

---

## kubeadm Generated kubeconfig Files

kubeadm writes one kubeconfig per control plane consumer, each with its own identity, all under `/etc/kubernetes`.

| File | Identity (CN) | Groups (O) | Used by |
|------|---------------|------------|---------|
| `admin.conf` | `kubernetes-admin` | `kubeadm:cluster-admins` on newer kubeadm, `system:masters` on older | Cluster administrators |
| `super-admin.conf` | `kubernetes-super-admin` | `system:masters` | Break glass only (present in newer kubeadm versions) |
| `controller-manager.conf` | `system:kube-controller-manager` | none | kube-controller-manager |
| `scheduler.conf` | `system:kube-scheduler` | none | kube-scheduler |
| `kubelet.conf` | `system:node:<nodename>` | `system:nodes` | kubelet on that node |

```bash
sudo ls -l /etc/kubernetes/*.conf

# Check the identity inside any of them
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf config view --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' |
  base64 -d | openssl x509 -noout -subject -dates
```

The split of `admin.conf` and `super-admin.conf` in newer kubeadm releases is a real security improvement: `admin.conf` reaches `cluster-admin` through an ordinary, *revocable* ClusterRoleBinding to the group `kubeadm:cluster-admins`, while `super-admin.conf` keeps the unrevocable `system:masters` bypass for the day RBAC itself is broken.

```yaml
# The binding that gives admin.conf its power on newer kubeadm.
# Deleting this binding actually removes the access, which is the point.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:cluster-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: kubeadm:cluster-admins
```

The standard first step after `kubeadm init`, and the reason it works:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

> ⚠️ `admin.conf` is not a user account, it is a shared root credential with no attribution. Every action taken with it is audited as `kubernetes-admin`, whoever typed it. Issue individual certificates or OIDC identities for people and keep `admin.conf` for emergencies.

> 📖 **See Also**: [manual-install-k8s-cluster.md](manual-install-k8s-cluster.md), [control-plane-node.md](control-plane-node.md).

---

## Certificate Expiry and Renewal

Expired certificates are the most common way a cluster that nobody touched stops working, usually exactly one year after installation.

```bash
# Everything kubeadm manages, in one view
sudo kubeadm certs check-expiration
```

```
CERTIFICATE                 EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
admin.conf                 Jan 01, 2026 00:00 UTC    364d            no
apiserver                  Jan 01, 2026 00:00 UTC    364d            no
apiserver-etcd-client      Jan 01, 2026 00:00 UTC    364d            no
apiserver-kubelet-client   Jan 01, 2026 00:00 UTC    364d            no
controller-manager.conf    Jan 01, 2026 00:00 UTC    364d            no
front-proxy-client         Jan 01, 2026 00:00 UTC    364d            no
scheduler.conf             Jan 01, 2026 00:00 UTC    364d            no

CERTIFICATE AUTHORITY      EXPIRES                  RESIDUAL TIME
ca                         Jan 01, 2035 00:00 UTC    9y
etcd-ca                    Jan 01, 2035 00:00 UTC    9y
front-proxy-ca             Jan 01, 2035 00:00 UTC    9y
```

Note the split: **leaf certificates default to one year, the CAs to ten**. The one year clock is the one that catches people.

```bash
# Any single certificate, without kubeadm
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
openssl x509 -in alice.crt -noout -enddate

# Is it expired right now? Exit status answers directly.
openssl x509 -in alice.crt -noout -checkend 0 && echo VALID || echo EXPIRED

# Will it expire within 30 days?
openssl x509 -in alice.crt -noout -checkend $((30*24*3600)) \
  && echo "ok for 30 days" || echo "RENEW NOW"

# The certificate embedded in a kubeconfig
kubectl config view --raw --minify \
  -o jsonpath='{.users[0].user.client-certificate-data}' |
  base64 -d | openssl x509 -noout -subject -dates
```

Renewal:

```bash
# Renew everything kubeadm manages
sudo kubeadm certs renew all

# Or one at a time
sudo kubeadm certs renew apiserver
sudo kubeadm certs renew admin.conf

# Static pods must be restarted to pick up new certificates.
# Moving the manifest out and back is the reliable way.
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 20
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

`kubeadm upgrade` also renews control plane certificates as a side effect, which is why clusters that are upgraded regularly rarely hit this problem, and clusters that are never touched always do.

Kubelet certificates are different: with `rotateCertificates: true` in the kubelet configuration, the kubelet requests a new certificate through the CSR API before its current one expires, entirely on its own. Check that it is working by watching for CSRs:

```bash
kubectl get csr --sort-by=.metadata.creationTimestamp | tail
```

> 📖 **See Also**: [k8s-cluster-upgrade](../k8s-workshop/k8s-cluster-upgrade.sh) in the workshop scripts.

---

## Complete Lab: Onboard a New User

End to end: generate a key, request a certificate through the API, get it approved, build a kubeconfig, grant a minimal permission, verify the identity.

### Step 1: Create the Namespace and Key Material

```bash
kubectl create namespace dev

# Alice generates these on HER machine. The private key never moves.
openssl genrsa -out alice.key 2048
chmod 600 alice.key

openssl req -new -key alice.key -out alice.csr \
  -subj "/CN=alice/O=developers"

openssl req -in alice.csr -noout -subject
# subject=CN = alice, O = developers
```

### Step 2: Submit the CertificateSigningRequest

```bash
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: $(base64 -w 0 < alice.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
  - client auth
EOF
```

```bash
kubectl get csr alice
# NAME    AGE  SIGNERNAME                           REQUESTOR          CONDITION
# alice   3s   kubernetes.io/kube-apiserver-client  kubernetes-admin   Pending
```

### Step 3: Approve and Extract

```bash
kubectl certificate approve alice

kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt

openssl x509 -in alice.crt -noout -subject -issuer -dates
# subject=CN = alice, O = developers
# issuer=CN = kubernetes
```

### Step 4: Build Alice's kubeconfig

```bash
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')

# Pull the cluster CA out of the current kubeconfig
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' |
  base64 -d > cluster-ca.crt

KUBECONFIG=alice.kubeconfig kubectl config set-cluster "${CLUSTER}" \
  --server="${APISERVER}" \
  --certificate-authority=cluster-ca.crt \
  --embed-certs=true

KUBECONFIG=alice.kubeconfig kubectl config set-credentials alice \
  --client-certificate=alice.crt \
  --client-key=alice.key \
  --embed-certs=true

KUBECONFIG=alice.kubeconfig kubectl config set-context alice@"${CLUSTER}" \
  --cluster="${CLUSTER}" \
  --user=alice \
  --namespace=dev

KUBECONFIG=alice.kubeconfig kubectl config use-context alice@"${CLUSTER}"

chmod 600 alice.kubeconfig
```

### Step 5: Verify Identity Before Granting Anything

```bash
KUBECONFIG=alice.kubeconfig kubectl auth whoami
```

```
ATTRIBUTE   VALUE
Username    alice
Groups      [developers system:authenticated]
```

Authentication works. Authorization does not yet, which is exactly right:

```bash
KUBECONFIG=alice.kubeconfig kubectl get pods -n dev
# Error from server (Forbidden): pods is forbidden: User "alice"
# cannot list resource "pods" in API group "" in the namespace "dev"
```

That 403, not a 401, is the proof that the certificate is good.

### Step 6: Grant a Minimal Permission

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: dev
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader
  namespace: dev
subjects:
- kind: User
  name: alice                        # exact string from the certificate CN
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f alice-rbac.yaml

KUBECONFIG=alice.kubeconfig kubectl get pods -n dev
# No resources found in dev namespace.        ← success

KUBECONFIG=alice.kubeconfig kubectl get pods -n kube-system
# Error from server (Forbidden): ...           ← correctly scoped

KUBECONFIG=alice.kubeconfig kubectl auth can-i --list -n dev
```

### Step 7: Verify From the Admin Side Without Alice's Credentials

```bash
kubectl auth can-i list pods --as=alice -n dev            # yes
kubectl auth can-i delete pods --as=alice -n dev          # no
kubectl auth can-i list pods --as=alice -n kube-system    # no
kubectl auth can-i --list --as=alice -n dev
```

### Step 8: Clean Up

```bash
kubectl delete csr alice
kubectl delete rolebinding alice-pod-reader -n dev
kubectl delete role pod-reader -n dev
rm -f alice.key alice.csr alice.crt alice.kubeconfig cluster-ca.crt
```

Note what step 8 cannot do: **it cannot revoke the certificate**. Deleting the RoleBinding removes Alice's access; the certificate itself remains valid and would work again the moment any binding named `alice` or the group `developers` reappeared.

---

## Strategy Comparison

| Strategy | Credential | Expiry | Revocable | Groups from | Best for |
|----------|-----------|--------|-----------|-------------|----------|
| **X.509 client cert** | Certificate + key | Baked into the certificate | ❌ No CRL support | `O` fields | Components, break glass, small teams, labs |
| **Service account token (bound)** | Projected JWT | Yes, refreshed by the kubelet | ✅ Delete the pod or the ServiceAccount | Derived from the namespace | In-cluster workloads |
| **Service account token (Secret)** | JWT in a Secret | ❌ Never | ✅ Delete the Secret | Derived from the namespace | External CI, only when unavoidable |
| **OIDC** | id_token | Short, refreshed by the client | ✅ At the provider, after the token expires | Claim from the provider | Humans, at any real scale |
| **Webhook token** | Opaque token | Your service decides | ✅ Your service decides | Your service decides | Custom or legacy token systems |
| **Authenticating proxy** | Session at the proxy | The proxy decides | ✅ At the proxy | `X-Remote-Group` headers | Enterprise SSO gateways |
| **Bootstrap token** | `id.secret` string | Yes, typically 24h | ✅ Delete the Secret | `system:bootstrappers` | Node join only |
| **Static token file** | Fixed string | ❌ Never | Restart required | CSV column | Nothing. Legacy. |
| **Anonymous** | none | n/a | Disable the flag | `system:unauthenticated` | Health and discovery endpoints |

---

## Command Reference

```bash
# ---------- WHO AM I ----------
kubectl auth whoami
kubectl auth whoami -o yaml
kubectl config current-context
kubectl config view --minify

# ---------- CERTIFICATES ----------
openssl genrsa -out user.key 2048
openssl req -new -key user.key -out user.csr -subj "/CN=user/O=group"
openssl req -in user.csr -noout -subject
openssl x509 -in user.crt -noout -subject -issuer -dates
openssl x509 -in user.crt -noout -checkend 0
openssl x509 -in user.crt -noout -ext extendedKeyUsage
openssl verify -CAfile /etc/kubernetes/pki/ca.crt user.crt

# ---------- CSR API ----------
kubectl get csr
kubectl describe csr <name>
kubectl certificate approve <name>
kubectl certificate deny <name>
kubectl get csr <name> -o jsonpath='{.status.certificate}' | base64 -d > user.crt
kubectl delete csr <name>

# ---------- kubeconfig ----------
kubectl config get-contexts
kubectl config use-context <ctx>
kubectl config set-context --current --namespace=<ns>
kubectl config set-cluster <name> --server=<url> --certificate-authority=<ca> --embed-certs=true
kubectl config set-credentials <name> --client-certificate=<crt> --client-key=<key> --embed-certs=true
kubectl config set-credentials <name> --token=<token>
kubectl config set-context <ctx> --cluster=<c> --user=<u> --namespace=<ns>
kubectl config view --raw --flatten > merged.config
kubectl config delete-context <ctx>

# ---------- TOKENS ----------
kubectl -n <ns> create token <serviceaccount>
kubectl -n <ns> create token <sa> --duration=1h --audience=https://example.com
kubeadm token list
kubeadm token create --print-join-command
kubeadm token delete <token>

# ---------- IMPERSONATION AND TESTING ----------
kubectl get pods --as=alice -n dev
kubectl auth can-i <verb> <resource> --as=<user> -n <ns>
kubectl auth can-i --list --as=<user> -n <ns>

# ---------- EXPIRY ----------
sudo kubeadm certs check-expiration
sudo kubeadm certs renew all

# ---------- RAW API ----------
kubectl get --raw /version
kubectl get --raw /apis/authentication.k8s.io/v1
curl -k --cert user.crt --key user.key https://<apiserver>:6443/api/v1/namespaces
curl -k -H "Authorization: Bearer ${TOKEN}" https://<apiserver>:6443/api/v1/namespaces
```

---

## Troubleshooting

### `error: You must be logged in to the server (Unauthorized)`

This is a 401. The server does not know who you are. Work through these in order.

```bash
# 1. Is the certificate expired? The most common cause by a wide margin.
kubectl config view --raw --minify \
  -o jsonpath='{.users[0].user.client-certificate-data}' |
  base64 -d | openssl x509 -noout -dates

# 2. Is the CLOCK wrong? Skew makes a valid certificate look not-yet-valid.
date -u
timedatectl status

# 3. Is the certificate signed by a CA the API server trusts?
openssl verify -CAfile /etc/kubernetes/pki/ca.crt alice.crt
# alice.crt: OK

# 4. Does the certificate have clientAuth?
openssl x509 -in alice.crt -noout -ext extendedKeyUsage

# 5. Are you actually sending the credential you think you are?
kubectl config view --minify
env | grep -i kubeconfig

# 6. Is a token both present and expired?
TOKEN=$(kubectl config view --raw --minify -o jsonpath='{.users[0].user.token}')
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.exp, .iss, .aud'
date -d @<exp>
```

### 401 Symptom Table

| Message or symptom | Likely cause | Fix |
|--------------------|--------------|-----|
| `Unauthorized` right after a working period of ~1 year | Client certificate expired | `kubeadm certs renew`, reissue the user certificate |
| `x509: certificate signed by unknown authority` | Wrong CA in the kubeconfig, or the cluster CA was rotated | Re-fetch `certificate-authority-data` |
| `x509: certificate has expired or is not yet valid` | Expiry, or clock skew | Renew; fix NTP |
| `Unauthorized` only for OIDC users | id_token expired and refresh failed, or issuer or audience mismatch | Re-login; verify `--oidc-issuer-url` matches `iss` exactly |
| `Unauthorized` from inside a pod | Token file not mounted, or wrong audience | See [service-accounts.md](service-accounts.md) |
| `Unauthorized` after adding a token to the kubeconfig | A client certificate in the same user entry is winning | Remove the certificate fields from that user |
| `Unauthorized` for a joining node | Bootstrap token expired | `kubeadm token create --print-join-command` |

### CSR Stuck in Pending After Approval

```bash
kubectl get csr <name> -o yaml | grep -A5 'signerName\|conditions'
```

```
┌──────────────────────────────────────────────────────────────────┐
│  Approved but status.certificate is EMPTY                         │
├──────────────────────────────────────────────────────────────────┤
│  1. Wrong signerName. It must be exactly                          │
│     kubernetes.io/kube-apiserver-client for a normal user.        │
│  2. kube-controller-manager is not running its signer:            │
│       check --cluster-signing-cert-file and                       │
│       --cluster-signing-key-file are set                          │
│       kubectl -n kube-system logs kube-controller-manager-<node>  │
│  3. An external signer is expected but not installed.             │
│  4. usages does not include "client auth".                        │
└──────────────────────────────────────────────────────────────────┘
```

### `error: unable to load root certificates` or TLS Handshake Failures

```bash
# Prove the server certificate and the CA agree, outside kubectl
openssl s_client -connect <apiserver>:6443 \
  -CAfile /etc/kubernetes/pki/ca.crt </dev/null 2>&1 | head -n 20

# Does the server certificate cover the name you are connecting to?
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text |
  grep -A1 'Subject Alternative Name'
```

If you connect through a load balancer or a new DNS name, that name must be in the API server certificate's SAN list. Add it with `certSANs` in the kubeadm configuration and regenerate, or the client will refuse the connection.

### The kubelet Cannot Authenticate

```bash
sudo journalctl -u kubelet -n 100 --no-pager | grep -i -E 'unauthorized|x509|certificate'
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -dates
kubectl get csr | grep -i node
```

A kubelet whose certificate expired while the node was powered off cannot rotate (rotation requires a working connection). Re-run `kubeadm join` with a fresh bootstrap token, or place a manually signed `system:node:<nodename>` certificate.

### Everything Returns 403 Instead

Good news: authentication is fine. Move to [rbac.md](rbac.md).

---

## Exam and Interview Traps

1. **There is no User object.** You cannot create, list or delete users. Any question that starts "how do I create a user in Kubernetes" is really asking about issuing a credential plus creating a RoleBinding.
2. **401 is authentication, 403 is authorization.** A 403 proves your credential worked. Do not debug certificates when you are getting Forbidden.
3. **In a client certificate, `CN` is the username and every `O` is a group.** `OU` is ignored completely, and so is every other subject field.
4. **Certificates cannot be revoked.** Kubernetes checks no CRL and does no OCSP. Short lifetimes and RBAC removal are the only controls.
5. **`signerName: kubernetes.io/kube-apiserver-client`** is the value for a normal user CSR. `kubernetes.io/kube-apiserver-client-kubelet` is for kubelets; `kubernetes.io/legacy-unknown` is not served by the built-in signer.
6. **Approving a CSR requires two RBAC pieces**: `update` on `certificatesigningrequests/approval` **and** `approve` on the `signers` resource with the signer name in `resourceNames`.
7. **`spec.request` is base64 of the PEM CSR, on a single line.** `base64 -w 0` on GNU systems, `base64 | tr -d '\n'` on macOS.
8. **The issued certificate lives only in `status.certificate` and must be base64 decoded.** Extract it before the CSR object is garbage collected.
9. **`Denied` is terminal.** A denied CSR cannot later be approved; delete it and resubmit.
10. **A client certificate in a kubeconfig beats a token in the same user entry**, because it is presented during the TLS handshake.
11. **Groups do not merge across authenticators.** The module that authenticates you supplies the whole list, plus `system:authenticated`.
12. **`system:masters` bypasses RBAC entirely and has no binding to delete.** It is not revocable; that is why newer kubeadm splits `admin.conf` from `super-admin.conf`.
13. **The `system:` prefix is reserved** and is rejected from OIDC, webhook and proxy authenticators, but **not** from certificates signed by a CA in `--client-ca-file`.
14. **`system:authenticated` includes every service account.** Binding a role to it grants that role to every workload in the cluster.
15. **`--oidc-username-prefix` defaults to the issuer URL plus `#`** unless the username claim is `email` or you set the prefix explicitly. Set it explicitly.
16. **The API server validates OIDC tokens offline** using the provider's JWKS. It never calls the provider per request, so revocation only takes effect when the token expires.
17. **A bootstrap token is `[a-z0-9]{6}.[a-z0-9]{16}`**, and the Secret must be named `bootstrap-token-<token-id>` in `kube-system` with type `bootstrap.kubernetes.io/token`.
18. **Bootstrap tokens authenticate as `system:bootstrap:<token-id>` in the group `system:bootstrappers`**, and are never used again after the kubelet has its own certificate.
19. **A kubelet's CN must be `system:node:<nodename>` matching the Node object's name exactly**, or the Node authorizer will not grant it anything.
20. **`--as` requires the `impersonate` verb, and `--as-uid` additionally requires it on `uids` in the `authentication.k8s.io` group.**
21. **Granting `impersonate` on `groups` without `resourceNames` is equivalent to granting cluster-admin**, because the holder can impersonate `system:masters`.
22. **Impersonated requests are authorized as the impersonated identity only.** Your own permissions do not add to theirs.
23. **`KUBECONFIG` merges files left to right and the first definition of a key wins**, while writes always go to the first file.
24. **`kubectl config view` redacts secrets; `--raw` does not.** `--flatten` inlines file references, and you usually want both.
25. **`--embed-certs=true` is what makes a kubeconfig portable.** Without it you get paths that only work on the machine that created it.
26. **kubeadm leaf certificates default to one year and CAs to ten.** Clusters that are never upgraded break at the one year mark.
27. **Static pods do not reload certificates**; move the manifest out of `/etc/kubernetes/manifests` and back to restart them after renewal.
28. **`--basic-auth-file` was removed in Kubernetes 1.19.** Any guide still using it is out of date.
29. **Anonymous requests get `system:anonymous` and `system:unauthenticated`**, and still pass through authorization. The danger is a binding, not the flag.
30. **Adding a new DNS name or load balancer address for the API server requires it in the serving certificate SANs**, or clients fail the TLS handshake before authentication is even attempted.

---

## Related Topics

- [RBAC](rbac.md)
- [Service Accounts](service-accounts.md)
- [kube-apiserver](kube-apiserver.md)
- [Kubernetes API](k8s-api.md)
- [Secrets](secrets.md)
- [ConfigMaps](configmaps.md)
- [Downward API](downward-api.md)
- [kubectl](kubectl.md)
- [kubelet](kubelet.md)
- [Control Plane Node](control-plane-node.md)
- [Worker Node](worker-node.md)
- [etcd](etcd.md)
- [Kubernetes Architecture](k8s-architecture.md)
- [Network Policy](network-policy.md)
- [Manual Install of a Kubernetes Cluster](manual-install-k8s-cluster.md)
- [Pods](pods.md)

---

## Key Takeaways

1. **Kubernetes has no user database.** Normal users are not API objects and cannot be created, listed or deleted. Identity is asserted by an external system (a CA, an OIDC provider, a proxy, a webhook) and the cluster only ever sees a username string and a list of group strings.
2. **The request pipeline is fixed**: TLS, authentication, optional impersonation, authorization, admission (mutating, then schema validation, then validating), then persistence to etcd. A failure at each stage has a characteristic status code, and knowing which one you got tells you where to look.
3. **401 means the server does not know you; 403 means it knows you exactly and is refusing.** These are different problems with different fixes, and confusing them wastes more debugging time than any other mistake in this area.
4. **In an X.509 client certificate, `CN` becomes the username and each `O` becomes a group.** Nothing else in the subject matters. Certificates cannot be revoked by Kubernetes, so keep lifetimes short and rely on removing RBAC bindings.
5. **The CertificateSigningRequest API is the auditable way to issue client certificates.** Use `signerName: kubernetes.io/kube-apiserver-client` with `usages: ["client auth"]`, approve with `kubectl certificate approve`, and extract the result from `status.certificate` with base64 decoding.
6. **Service account tokens are the machine equivalent**, producing the username `system:serviceaccount:<namespace>:<name>` and the groups `system:serviceaccounts` and `system:serviceaccounts:<namespace>`.
7. **OIDC is the correct answer for humans at scale.** The API server validates the id_token offline against the provider's published keys, which makes it fast but means revocation waits for token expiry. Always set `--oidc-username-prefix` explicitly.
8. **Bootstrap tokens exist only to break the chicken and egg problem of node join.** They are short lived, they authenticate as `system:bootstrap:<id>` in `system:bootstrappers`, and the kubelet stops using them the moment it has its own certificate.
9. **`system:masters` is a hardcoded RBAC bypass with no binding behind it.** It cannot be revoked through the API. Newer kubeadm therefore reserves it for `super-admin.conf` and gives `admin.conf` an ordinary, deletable ClusterRoleBinding instead.
10. **Impersonation with `--as` and `--as-group` is the best RBAC testing tool available**, and simultaneously one of the most dangerous privileges to grant. Always constrain it with `resourceNames`.
11. **A kubeconfig is three lists (clusters, users, contexts) plus `current-context`.** Understand `--embed-certs`, `--flatten`, `--raw` and the left to right merge rules of `KUBECONFIG`, and the file stops being mysterious.
12. **Certificate expiry is the silent cluster killer.** kubeadm issues one year leaves; check with `kubeadm certs check-expiration`, renew with `kubeadm certs renew all`, and remember to restart the static pods afterwards.

---

## References

- [Authenticating](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Certificates and Certificate Signing Requests](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
- [Certificate Signing Requests API](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/certificate-signing-request-v1/)
- [Managing Certificates with kubeadm](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [PKI Certificates and Requirements](https://kubernetes.io/docs/setup/best-practices/certificates/)
- [Authenticating with Bootstrap Tokens](https://kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens/)
- [Kubelet TLS Bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/)
- [Using Node Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/)
- [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- [Configure Access to Multiple Clusters](https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/)
- [Certificate Management with kubeadm](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [kubectl config Reference](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#config)
- [kube-apiserver Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
- [Controlling Access to the Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)
