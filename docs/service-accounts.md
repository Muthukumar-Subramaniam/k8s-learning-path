# 🤖 Service Accounts: Machine Identity in Kubernetes

A complete guide to how workloads authenticate to the API server: the ServiceAccount object, the move from permanent Secret tokens to bound projected tokens, decoding the JWT, `automountServiceAccountToken`, image pull secrets, calling the API from inside a pod, and workload identity federation.

## 📋 Table of Contents
- [Two Kinds of Identity](#two-kinds-of-identity)
- [The ServiceAccount Object](#the-serviceaccount-object)
- [The default Service Account](#the-default-service-account)
- [Assigning a Service Account to a Pod](#assigning-a-service-account-to-a-pod)
- [The Username and Group Format](#the-username-and-group-format)
- [The Old Model: Permanent Secret Tokens](#the-old-model-permanent-secret-tokens)
- [The Modern Model: Bound Projected Tokens](#the-modern-model-bound-projected-tokens)
- [Before and After](#before-and-after)
- [The Projected serviceAccountToken Volume](#the-projected-serviceaccounttoken-volume)
- [The In-Pod File Paths](#the-in-pod-file-paths)
- [Decoding the Token](#decoding-the-token)
- [Token Invalidation](#token-invalidation)
- [automountServiceAccountToken](#automountserviceaccounttoken)
- [Creating a Long Lived Token Deliberately](#creating-a-long-lived-token-deliberately)
- [kubectl create token](#kubectl-create-token)
- [imagePullSecrets](#imagepullsecrets)
- [Binding RBAC to a Service Account](#binding-rbac-to-a-service-account)
- [Calling the API From Inside a Pod](#calling-the-api-from-inside-a-pod)
- [In-Cluster Configuration With Client Libraries](#in-cluster-configuration-with-client-libraries)
- [Workload Identity Federation](#workload-identity-federation)
- [Security Guidance](#security-guidance)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Two Kinds of Identity

Kubernetes splits identity cleanly in two, and service accounts are the half the cluster actually manages.

```
┌──────────────────────────────────────────────────────────────────────┐
│                     USERS vs SERVICE ACCOUNTS                         │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│                  NORMAL USER            SERVICE ACCOUNT               │
│                  (a human)              (a workload)                  │
│                  ─────────────────      ────────────────────────────  │
│  API object?     ❌ no                  ✅ yes, kind: ServiceAccount  │
│  Stored in etcd? ❌ no                  ✅ yes                        │
│  Scope           n/a                    namespaced                    │
│  Created by      an external CA or      kubectl create serviceaccount │
│                  identity provider      or a manifest                 │
│  Listed with     ❌ impossible          kubectl get serviceaccounts   │
│  Username        chosen by the          DERIVED, never chosen:        │
│                  credential issuer      system:serviceaccount:<ns>:<n>│
│  Credential      certificate, OIDC      a signed JWT bearer token     │
│                  token, proxy header                                  │
│  Intended for    people and things      pods, controllers, operators, │
│                  outside the cluster    and anything in-cluster       │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

Every pod in the cluster runs with a service account, whether or not anybody chose one. That is the first fact to internalise: **there is no such thing as a pod without an identity**, only pods whose identity nobody thought about.

> 📖 **See Also**: [authentication.md](authentication.md) for the human half, and [rbac.md](rbac.md) for what a service account is allowed to do.

---

## The ServiceAccount Object

The simplest object in Kubernetes. It has almost no spec, because it is a name, not a configuration.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: build-bot
  namespace: ci

# Optional: refuse to mount a token into pods that use this account.
automountServiceAccountToken: false

# Optional: registry credentials propagated to every pod using this account.
imagePullSecrets:
- name: registry-creds

# Optional and legacy: Secrets the token controller once populated.
# On modern clusters this list is normally EMPTY, and that is correct.
secrets: []
```

```bash
kubectl -n ci create serviceaccount build-bot
kubectl -n ci get serviceaccount build-bot -o yaml
kubectl -n ci describe serviceaccount build-bot
```

```
Name:                build-bot
Namespace:           ci
Labels:              <none>
Annotations:         <none>
Image pull secrets:  registry-creds
Mountable secrets:   <none>
Tokens:              <none>
Events:              <none>
```

`Tokens: <none>` on a modern cluster is not a problem to fix. It means the cluster is using bound projected tokens, which are never stored as objects.

---

## The default Service Account

```
┌──────────────────────────────────────────────────────────────────────┐
│                   THE default SERVICE ACCOUNT                         │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  • Created automatically in EVERY namespace, as soon as the           │
│    namespace exists, by the ServiceAccount controller in              │
│    kube-controller-manager.                                           │
│                                                                       │
│  • Used by any pod that does not set spec.serviceAccountName.         │
│                                                                       │
│  • Has NO RBAC bindings out of the box. It can reach only what        │
│    system:basic-user and system:discovery allow: its own              │
│    permissions and the API discovery endpoints.                       │
│                                                                       │
│  • CANNOT BE PERMANENTLY DELETED. Delete it and the controller        │
│    recreates it, with a NEW uid, within seconds.                      │
│                                                                       │
│  • Is SHARED by every workload in the namespace that did not          │
│    choose otherwise, which is exactly why you should not grant it     │
│    anything.                                                          │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
kubectl get serviceaccounts -A | head
kubectl -n default get sa default -o yaml

# Prove the recreation
kubectl -n default delete sa default
kubectl -n default get sa default        # already back
```

> ⚠️ Granting anything to `default` is a decision to grant it to **every unlabelled workload in the namespace, forever, including workloads added next year by someone who never read your RBAC**. The correct pattern is: leave `default` with zero permissions, and give every workload that needs API access its own service account.

---

## Assigning a Service Account to a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-client
  namespace: ci
spec:
  # THE field. Must name a ServiceAccount in the SAME namespace as the pod.
  serviceAccountName: build-bot
  containers:
  - name: app
    image: alpine:3.20
    command: ["sleep", "3600"]
```

In a Deployment or any other controller, the field belongs to the **pod template**, which is where people put it in the wrong place:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-client
  namespace: ci
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-client
  template:
    metadata:
      labels:
        app: api-client
    spec:
      serviceAccountName: build-bot        # here, under template.spec
      automountServiceAccountToken: true
      containers:
      - name: app
        image: alpine:3.20
        command: ["sleep", "3600"]
```

```
┌──────────────────────────────────────────────────────────────────┐
│  RULES                                                            │
├──────────────────────────────────────────────────────────────────┤
│  • The ServiceAccount MUST exist in the pod's namespace, or the   │
│    pod is rejected at admission:                                  │
│      error: serviceaccount "build-bot" not found                  │
│  • You CANNOT reference a service account in another namespace.   │
│  • serviceAccountName is IMMUTABLE on a running Pod. Change it in │
│    the Deployment template and the rollout creates new pods.      │
│  • `serviceAccount` (no "Name") is a DEPRECATED alias that still  │
│    appears in `kubectl get pod -o yaml`. Always write             │
│    serviceAccountName in your manifests.                          │
└──────────────────────────────────────────────────────────────────┘
```

```bash
# Which service account is a pod actually using?
kubectl -n ci get pod api-client -o jsonpath='{.spec.serviceAccountName}{"\n"}'

# Across a namespace, which is the fastest way to find pods still on `default`
kubectl -n ci get pods \
  -o custom-columns='POD:.metadata.name,SA:.spec.serviceAccountName'
```

> 📖 **See Also**: [pods.md](pods.md), [deployments.md](deployments.md).

---

## The Username and Group Format

```
┌──────────────────────────────────────────────────────────────────────┐
│                  SERVICE ACCOUNT IDENTITY                             │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   ServiceAccount `build-bot` in namespace `ci` authenticates as:      │
│                                                                       │
│   USERNAME                                                            │
│     system:serviceaccount:ci:build-bot                                │
│     └──────┬──────┘ └┬┘ └───┬───┘                                     │
│       fixed prefix   ns    name                                       │
│                                                                       │
│   UID                                                                 │
│     the ServiceAccount object's metadata.uid. A deleted and           │
│     recreated account with the SAME NAME gets a DIFFERENT uid,        │
│     which invalidates every token issued to the old one.              │
│                                                                       │
│   GROUPS                                                              │
│     system:serviceaccounts             every SA in the cluster        │
│     system:serviceaccounts:ci          every SA in namespace ci       │
│     system:authenticated               every authenticated identity   │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

The username format matters in three places, and getting it wrong is the usual reason an RBAC test "does not work":

```bash
# 1. Impersonation: the FULL username, not just the SA name
kubectl auth can-i list pods --as=system:serviceaccount:ci:build-bot -n ci

# 2. A subject written as a User rather than a ServiceAccount
#    (equivalent, but the string must be complete)

# 3. Any external system matching on the Kubernetes username
```

```yaml
# These two subjects are equivalent
subjects:
- kind: ServiceAccount
  name: build-bot
  namespace: ci
# is the same as
- kind: User
  name: system:serviceaccount:ci:build-bot
  apiGroup: rbac.authorization.k8s.io
```

---

## The Old Model: Permanent Secret Tokens

For years, this is how it worked, and you will still meet it in old manifests, old blog posts and old clusters.

```
┌──────────────────────────────────────────────────────────────────────┐
│              LEGACY MODEL (pre 1.24 auto-generation)                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  1. You create ServiceAccount `build-bot`.                            │
│                                                                       │
│  2. The TOKEN CONTROLLER automatically creates a Secret:              │
│         name: build-bot-token-x7k2p                                   │
│         type: kubernetes.io/service-account-token                     │
│         data: token, ca.crt, namespace                                │
│                                                                       │
│  3. The Secret's name is written back into the ServiceAccount's       │
│     `secrets` list.                                                   │
│                                                                       │
│  4. Every pod using that SA gets the Secret mounted at                │
│     /var/run/secrets/kubernetes.io/serviceaccount/                    │
│                                                                       │
│  PROPERTIES OF THAT TOKEN                                             │
│    ❌ NO expiry claim. Valid forever.                                 │
│    ❌ NO audience. Accepted by anything that trusts the signing key.  │
│    ❌ NOT bound to a pod. Still valid after the pod is deleted.       │
│    ❌ READABLE BY ANYONE with `get secrets` in the namespace.         │
│    ❌ SITS IN etcd, so an etcd backup contains permanent cluster      │
│       credentials.                                                    │
│    ❌ A leaked token can only be revoked by deleting the Secret AND   │
│       the ServiceAccount, because the token names the SA's uid.       │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

Kubernetes 1.24 stopped auto-generating these Secrets. Creating a ServiceAccount no longer creates a Secret, and `kubectl describe sa` shows `Tokens: <none>`. The Secret type still exists, and you can still create one on purpose, but it is now an explicit decision rather than the default.

```bash
# On an older cluster you would see this; on a modern one you will not
kubectl -n ci get secrets --field-selector type=kubernetes.io/service-account-token
```

---

## The Modern Model: Bound Projected Tokens

```
┌──────────────────────────────────────────────────────────────────────┐
│                   BOUND TOKEN LIFECYCLE                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  1. You create a Pod with serviceAccountName: build-bot               │
│           │                                                           │
│           ▼                                                           │
│  2. THE ServiceAccount ADMISSION PLUGIN mutates the pod, adding a     │
│     projected volume named kube-api-access-xxxxx and a volumeMount    │
│     at /var/run/secrets/kubernetes.io/serviceaccount in EVERY         │
│     container. You did not write this, and it appears in              │
│     `kubectl get pod -o yaml`.                                        │
│           │                                                           │
│           ▼                                                           │
│  3. THE KUBELET calls the TokenRequest API                            │
│       POST /api/v1/namespaces/ci/serviceaccounts/build-bot/token      │
│     asking for a token bound to THIS pod, with the configured         │
│     audience and expiry.                                              │
│           │                                                           │
│           ▼                                                           │
│  4. THE API SERVER signs a JWT containing:                            │
│       • exp   a real expiry                                           │
│       • aud   the requested audience                                  │
│       • kubernetes.io claims naming the namespace, the                │
│         ServiceAccount (name + uid) and the POD (name + uid)          │
│           │                                                           │
│           ▼                                                           │
│  5. THE KUBELET writes it into the pod's tmpfs and REFRESHES it       │
│     before expiry, atomically replacing the file in place.            │
│           │                                                           │
│           ▼                                                           │
│  6. ON EVERY VALIDATION the API server checks the signature, the      │
│     expiry, the audience, AND that the referenced ServiceAccount      │
│     and Pod still exist with the same uids.                           │
│                                                                       │
│  DELETE THE POD → the token stops working immediately.                │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

Two API server flags make this possible:

```yaml
    # The `iss` claim, and by default the accepted audience
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    # Private key used to SIGN tokens
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    # Public key(s) used to VERIFY tokens. Repeatable during key rotation.
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    # Accepted audiences. Defaults to the issuer value.
    - --api-audiences=https://kubernetes.default.svc.cluster.local
```

---

## Before and After

```
┌────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   BEFORE: Secret based, permanent                                           │
│                                                                             │
│   ┌──────────────┐        creates        ┌──────────────────────────┐       │
│   │ServiceAccount│──────────────────────►│ Secret                   │       │
│   │  build-bot   │  (token controller)   │ build-bot-token-x7k2p    │       │
│   └──────────────┘                       │ type: ...-account-token  │       │
│          ▲                               │ token: <NEVER EXPIRES>   │       │
│          │ serviceAccountName            └───────────┬──────────────┘       │
│   ┌──────┴───────┐                                   │ mounted              │
│   │     Pod      │◄──────────────────────────────────┘                      │
│   └──────────────┘                                                          │
│                                                                             │
│   ⚠️  The token lives in etcd, never expires, works from anywhere,          │
│       and survives the pod, the deployment and the cluster restore.         │
│                                                                             │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   AFTER: TokenRequest based, bound                                          │
│                                                                             │
│   ┌──────────────┐                       ┌──────────────────────────┐       │
│   │ServiceAccount│                       │  NO SECRET EXISTS        │       │
│   │  build-bot   │                       │  nothing in etcd         │       │
│   └──────┬───────┘                       └──────────────────────────┘       │
│          │ serviceAccountName                                               │
│   ┌──────▼───────┐    kubelet asks     ┌────────────────┐                   │
│   │     Pod      │◄────────────────────│ TokenRequest   │                   │
│   │              │  writes to tmpfs    │ API            │                   │
│   │  token       │  refreshes before   └────────────────┘                   │
│   │  expires 1h  │  expiry                                                  │
│   └──────────────┘                                                          │
│                                                                             │
│   ✅ Expires. Audience scoped. Bound to this pod. Never in etcd.            │
│       Deleting the pod invalidates it instantly.                            │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

### Why the Change Mattered

```
┌──────────────────────────────────────────────────────────────────────┐
│  THREAT                          LEGACY TOKEN      BOUND TOKEN        │
├──────────────────────────────────────────────────────────────────────┤
│  Token exfiltrated from a pod    valid forever     dies in ~1 hour    │
│  Attacker reads etcd backup      full credentials  no tokens there    │
│  Attacker has `get secrets`      reads any SA      nothing to read    │
│                                  token in the ns                      │
│  Pod deleted after compromise    token still works token invalid      │
│  Token replayed at another       accepted          rejected: wrong    │
│  service that trusts the issuer                    audience           │
│  Attribution: which pod used it? impossible        pod name and uid   │
│                                                    are IN the token   │
└──────────────────────────────────────────────────────────────────────┘
```

The audience change is the subtle one and deserves a sentence of its own. A legacy token was valid at **anything** that verified the cluster's signing key. If you ran a second service that accepted Kubernetes tokens, a token minted for the API server was silently valid there too. Audience scoping ends that: a token requested for `vault` is rejected by the API server, and a token for the API server is rejected by Vault.

---

## The Projected serviceAccountToken Volume

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: explicit-token
  namespace: ci
spec:
  serviceAccountName: build-bot
  # Turn off the automatic injection so we can define it ourselves.
  automountServiceAccountToken: false
  containers:
  - name: app
    image: alpine:3.20
    command: ["sleep", "3600"]
    volumeMounts:
    - name: api-access
      mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      readOnly: true
  volumes:
  - name: api-access
    projected:
      defaultMode: 0644
      sources:

      # 1. The bound token itself
      - serviceAccountToken:
          # Path INSIDE the volume, relative to mountPath.
          path: token
          # Lifetime requested from the TokenRequest API.
          # Minimum 600 (10 minutes). The API server may cap this with
          # --service-account-max-token-expiration.
          expirationSeconds: 3600
          # Who this token is FOR. Omit to get the API server's default
          # audience. Set it when the token is for something else.
          audience: https://kubernetes.default.svc.cluster.local

      # 2. The cluster CA, so the container can verify the API server
      - configMap:
          name: kube-root-ca.crt
          items:
          - key: ca.crt
            path: ca.crt

      # 3. The namespace, via the Downward API
      - downwardAPI:
          items:
          - path: namespace
            fieldRef:
              fieldPath: metadata.namespace
```

Those three sources are exactly what the ServiceAccount admission plugin injects for you. Seeing them written out makes the automatic version far less mysterious.

### What the Admission Plugin Actually Adds

```bash
kubectl -n ci run auto --image=alpine:3.20 --command -- sleep 3600
kubectl -n ci get pod auto -o yaml | sed -n '/volumes:/,/^  [a-z]/p'
```

```yaml
  volumes:
  - name: kube-api-access-7m4zq          # random suffix, generated
    projected:
      defaultMode: 420                   # 0644 in decimal
      sources:
      - serviceAccountToken:
          expirationSeconds: 3607        # one hour plus a small offset
          path: token
      - configMap:
          items:
          - key: ca.crt
            path: ca.crt
          name: kube-root-ca.crt
      - downwardAPI:
          items:
          - fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
            path: namespace
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                  HOW THE KUBELET REFRESHES                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  The kubelet requests a NEW token and rewrites the file when the      │
│  current one is older than 80% of its lifetime, or older than 24      │
│  hours, whichever comes first. It also retries on failure, so a       │
│  brief API server outage does not leave a pod with a dead token.      │
│                                                                       │
│  The replacement is ATOMIC: the volume uses the same ..data symlink   │
│  swap as ConfigMap and Secret volumes, so a reader never sees a       │
│  half written file.                                                   │
│                                                                       │
│  ⚠️  CONSEQUENCE FOR APPLICATIONS                                     │
│      READ THE TOKEN FILE ON EVERY REQUEST, or at least periodically.  │
│      An application that reads it once at startup and caches the      │
│      string in memory will start getting 401s about an hour later.    │
│      Official client libraries handle this for you. Hand rolled curl  │
│      scripts and older HTTP clients frequently do not.                │
│                                                                       │
│  ⚠️  subPath BREAKS REFRESH, exactly as it does for ConfigMaps and    │
│      Secrets. Never mount the token with subPath.                     │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

> 📖 **See Also**: [downward-api.md](downward-api.md) for the `downwardAPI` source, and [configmaps.md](configmaps.md) for the atomic swap mechanism.

---

## The In-Pod File Paths

```
/var/run/secrets/kubernetes.io/serviceaccount/
├── token       the JWT bearer token
├── ca.crt      the PEM CA bundle that signed the API server's certificate
└── namespace   this pod's namespace, as plain text with no newline
```

```bash
kubectl -n ci exec -it auto -- ls -l /var/run/secrets/kubernetes.io/serviceaccount/
```

```
total 0
lrwxrwxrwx 1 root root 13 Jan  1 00:00 ca.crt -> ..data/ca.crt
lrwxrwxrwx 1 root root 16 Jan  1 00:00 namespace -> ..data/namespace
lrwxrwxrwx 1 root root 12 Jan  1 00:00 token -> ..data/token
```

The symlinks are the atomic swap mechanism. `..data` points at a timestamped directory, and a refresh creates a new directory and re-points the symlink in one operation.

```bash
kubectl -n ci exec auto -- cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
# ci        (no trailing newline)

kubectl -n ci exec auto -- head -c 100 \
  /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
# -----BEGIN CERTIFICATE-----
```

Two environment variables are injected into every container by the kubelet, and together with the files above they are everything a client needs:

```bash
kubectl -n ci exec auto -- env | grep KUBERNETES
```

```
KUBERNETES_SERVICE_HOST=10.96.0.1
KUBERNETES_SERVICE_PORT=443
KUBERNETES_SERVICE_PORT_HTTPS=443
KUBERNETES_PORT=tcp://10.96.0.1:443
KUBERNETES_PORT_443_TCP=tcp://10.96.0.1:443
KUBERNETES_PORT_443_TCP_ADDR=10.96.0.1
```

The DNS name `kubernetes.default.svc` resolves to the same ClusterIP and is the preferred target, because it matches the API server certificate's SAN list.

> 📖 **See Also**: [services.md](services.md), [coredns.md](coredns.md).

---

## Decoding the Token

A JWT is three base64url segments separated by dots: header, payload, signature.

```bash
kubectl -n ci exec auto -- cat /var/run/secrets/kubernetes.io/serviceaccount/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

```json
{
  "aud": [
    "https://kubernetes.default.svc.cluster.local"
  ],
  "exp": 1735693200,
  "iat": 1735689593,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "0e1f9d0c-4b2a-4c1e-9a3f-8b7c6d5e4f3a",
  "kubernetes.io": {
    "namespace": "ci",
    "node": {
      "name": "worker-01",
      "uid": "b1d2c3e4-5f6a-7b8c-9d0e-1f2a3b4c5d6e"
    },
    "pod": {
      "name": "auto",
      "uid": "3f2a1b0c-9d8e-7f6a-5b4c-3d2e1f0a9b8c"
    },
    "serviceaccount": {
      "name": "build-bot",
      "uid": "7a6b5c4d-3e2f-1a0b-9c8d-7e6f5a4b3c2d"
    }
  },
  "nbf": 1735689593,
  "sub": "system:serviceaccount:ci:build-bot"
}
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                        CLAIM BY CLAIM                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  iss   ISSUER. Matches --service-account-issuer. Also the base URL    │
│        for the OIDC discovery documents when that is enabled.         │
│                                                                       │
│  sub   SUBJECT. The Kubernetes username, verbatim:                    │
│          system:serviceaccount:<namespace>:<name>                     │
│        This is the string RBAC matches.                               │
│                                                                       │
│  aud   AUDIENCE. Who this token is FOR. The API server rejects a      │
│        token whose aud does not include one of --api-audiences.       │
│        A token minted for `vault` will NOT work against the API.      │
│                                                                       │
│  exp   EXPIRY, Unix seconds. THE claim the legacy token lacked.       │
│  iat   Issued at.                                                     │
│  nbf   Not before.                                                    │
│  jti   Unique token id, useful for correlating with audit logs.       │
│                                                                       │
│  kubernetes.io.namespace          the namespace                       │
│  kubernetes.io.serviceaccount     name AND uid                        │
│  kubernetes.io.pod                name AND uid  ← THE BINDING         │
│  kubernetes.io.node               name and uid, on clusters that      │
│                                   include node claims                 │
│                                                                       │
│  THE UIDS ARE THE POINT. Validation re-checks that the objects        │
│  still exist WITH THOSE UIDS. A recreated pod with the same name      │
│  has a different uid, so the old token stays invalid.                 │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

Useful one liners:

```bash
# Decode any token you hold locally
TOKEN=$(kubectl -n ci create token build-bot)
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .

# When does it expire, in human terms?
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.exp' |
  xargs -I{} date -d @{}

# How many seconds of life are left?
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null |
  jq -r '.exp - now | floor'

# The header, which names the signing key id
echo "$TOKEN" | cut -d. -f1 | base64 -d 2>/dev/null | jq .
# { "alg": "RS256", "kid": "cRz...", "typ": "JWT" }
```

> ⚠️ `base64 -d` may complain about missing padding on JWT segments, which is why the examples redirect stderr. The decode still succeeds. If your `base64` is stricter, append `==` or use a JWT aware tool.

A legacy Secret token decodes differently, and the shape is a quick way to tell the two apart:

```json
{
  "iss": "kubernetes/serviceaccount",
  "kubernetes.io/serviceaccount/namespace": "ci",
  "kubernetes.io/serviceaccount/secret.name": "build-bot-token-x7k2p",
  "kubernetes.io/serviceaccount/service-account.name": "build-bot",
  "kubernetes.io/serviceaccount/service-account.uid": "7a6b5c4d-...",
  "sub": "system:serviceaccount:ci:build-bot"
}
```

**No `exp`, no `aud`, no pod.** That is a permanent, unscoped, unbound credential, and seeing it should prompt a migration.

---

## Token Invalidation

```
┌──────────────────────────────────────────────────────────────────────┐
│              WHAT KILLS A BOUND TOKEN                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ✅ The pod is deleted                                                │
│       The API server checks the pod named in the token still          │
│       exists with that uid. It does not, so the token is rejected.    │
│                                                                       │
│  ✅ The pod is recreated with the same name                           │
│       New uid, so the old token remains invalid.                      │
│                                                                       │
│  ✅ The ServiceAccount is deleted (and recreated)                     │
│       Same reasoning: the uid changed.                                │
│                                                                       │
│  ✅ exp passes                                                        │
│       Ordinary expiry.                                                │
│                                                                       │
│  ✅ The signing key is rotated and the old public key removed         │
│       Invalidates every token signed with it, cluster wide.           │
│                                                                       │
│  ❌ WHAT DOES NOT KILL IT                                             │
│       Deleting a RoleBinding does not invalidate the TOKEN. It        │
│       removes the PERMISSIONS. The token still authenticates          │
│       successfully and then gets 403 on everything. That is the       │
│       correct and usually sufficient response to a leak.              │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Demonstrate binding to the pod
TOKEN=$(kubectl -n ci exec auto -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Works while the pod lives
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://<apiserver>:6443/api/v1/namespaces/ci/pods | head -5

kubectl -n ci delete pod auto

# Now rejected: the bound object is gone
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://<apiserver>:6443/api/v1/namespaces/ci/pods
# 401 Unauthorized
```

A token created with `kubectl create token` and no bound object is **not** tied to a pod. It is tied to the ServiceAccount and its expiry only, which is exactly what you want for an external CI system and exactly what you must remember when reasoning about revocation.

---

## automountServiceAccountToken

Two places to set it, and a clear precedence rule.

```yaml
# On the ServiceAccount: the default for every pod that uses it
apiVersion: v1
kind: ServiceAccount
metadata:
  name: no-api-access
  namespace: web
automountServiceAccountToken: false
---
# On the Pod: overrides the ServiceAccount setting
apiVersion: v1
kind: Pod
metadata:
  name: needs-api
  namespace: web
spec:
  serviceAccountName: no-api-access
  automountServiceAccountToken: true      # WINS over the SA's false
  containers:
  - name: app
    image: alpine:3.20
    command: ["sleep", "3600"]
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                  PRECEDENCE TABLE                                     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   ServiceAccount     Pod          RESULT                              │
│   ───────────────    ─────────    ──────────────────────────────      │
│   unset (default)    unset        MOUNTED  (the default is true)      │
│   true               unset        MOUNTED                             │
│   false              unset        NOT mounted                         │
│   unset              true         MOUNTED                             │
│   unset              false        NOT mounted                         │
│   true               false        NOT mounted   ← pod wins            │
│   false              true         MOUNTED       ← pod wins            │
│                                                                       │
│   RULE: the POD SPEC ALWAYS WINS when it is set at all.               │
│         The ServiceAccount setting is only a default.                 │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

### Why You Should Disable It

The overwhelming majority of workloads (a web server, a database, a queue consumer, a batch job) never call the Kubernetes API. Mounting a credential into them provides zero benefit and one clear cost: anyone who achieves code execution in the container, through an application vulnerability, a dependency compromise or an SSRF, immediately holds a valid cluster credential.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      automountServiceAccountToken: false     # this app never calls the API
      containers:
      - name: nginx
        image: nginx:1.27
```

```bash
# Verify: no service account files inside
kubectl -n web exec deploy/web -- ls /var/run/secrets/kubernetes.io/serviceaccount
# ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory

# Verify: no injected volume in the pod spec
kubectl -n web get pod -l app=web -o jsonpath='{.items[0].spec.volumes}' | jq
```

```bash
# AUDIT: every pod in the cluster that still mounts a token
kubectl get pods -A -o json | jq -r '
  .items[]
  | select((.spec.automountServiceAccountToken // true) == true)
  | "\(.metadata.namespace)/\(.metadata.name)\tsa=\(.spec.serviceAccountName)"'

# AUDIT: pods still using the default service account WITH a token mounted
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(.spec.serviceAccountName == "default")
  | select((.spec.automountServiceAccountToken // true) == true)
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

> 📌 A good namespace baseline is `automountServiceAccountToken: false` on the `default` ServiceAccount. Anything that genuinely needs API access then has to say so explicitly, either by setting the field on its pod or by using its own service account. That turns an invisible default into a reviewable decision.

---

## Creating a Long Lived Token Deliberately

Sometimes you genuinely need a token that outlives any pod: an external CI system, a monitoring collector outside the cluster, a `kubectl` context on a jump host.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: build-bot-token
  namespace: ci
  annotations:
    # THE annotation that ties this Secret to a ServiceAccount.
    # The ServiceAccount MUST already exist, in this namespace.
    kubernetes.io/service-account.name: build-bot
type: kubernetes.io/service-account-token
# NO data section. The token controller populates token, ca.crt
# and namespace after creation.
```

```bash
kubectl apply -f build-bot-token.yaml

# Wait a moment, then read it
kubectl -n ci get secret build-bot-token -o jsonpath='{.data.token}' | base64 -d
kubectl -n ci get secret build-bot-token -o jsonpath='{.data.ca\.crt}' | base64 -d
kubectl -n ci get secret build-bot-token -o jsonpath='{.data.namespace}' | base64 -d
```

```
┌──────────────────────────────────────────────────────────────────────┐
│  PROPERTIES OF A DELIBERATE LONG LIVED TOKEN                          │
├──────────────────────────────────────────────────────────────────────┤
│  • NO exp claim. It is valid until the Secret is deleted.             │
│  • Stored in etcd, therefore present in every etcd backup.            │
│  • Readable by anyone with `get secrets` in that namespace.           │
│  • Revoked by deleting the SECRET (not the ServiceAccount).           │
│  • Not bound to any pod, so it works from anywhere on the network     │
│    that can reach the API server.                                     │
│                                                                       │
│  WHEN IT IS STILL JUSTIFIED                                           │
│  ✅ An external system that cannot call TokenRequest to refresh.      │
│  ✅ A tool that has no way to re-read a rotating credential.          │
│  ✅ A bootstrap path that must work before anything else does.        │
│                                                                       │
│  WHEN IT IS NOT                                                       │
│  ❌ Anything running INSIDE the cluster. Use the projected token.     │
│  ❌ Convenience, because refreshing felt like work.                   │
│  ❌ A service account with broad permissions. If you must have a      │
│     permanent token, the identity behind it should be tiny.           │
│                                                                       │
│  IF YOU CREATE ONE                                                    │
│  • Scope the ServiceAccount to one namespace and a handful of verbs.  │
│  • Enable encryption at rest for Secrets.                             │
│  • Put a calendar reminder to rotate: delete the Secret, recreate it, │
│    redistribute. Kubernetes will not remind you.                      │
│  • Restrict `get secrets` in that namespace to as few subjects as     │
│    possible.                                                          │
└──────────────────────────────────────────────────────────────────────┘
```

> 📖 **See Also**: [secrets.md](secrets.md) for encryption at rest and Secret handling in general.

---

## kubectl create token

The modern, preferred way to obtain a token on demand. It calls the TokenRequest API and stores nothing.

```bash
# Default lifetime, decided by the API server (commonly one hour)
kubectl -n ci create token build-bot

# Explicit duration. The server may cap it with
# --service-account-max-token-expiration.
kubectl -n ci create token build-bot --duration=10m
kubectl -n ci create token build-bot --duration=24h

# A token FOR SOMETHING ELSE. This token will NOT work against the
# Kubernetes API, which is exactly the point.
kubectl -n ci create token build-bot --audience=https://vault.example.com

# Bind the token to an object, so deleting that object revokes it.
kubectl -n ci create token build-bot \
  --bound-object-kind=Pod \
  --bound-object-name=auto \
  --bound-object-uid=$(kubectl -n ci get pod auto -o jsonpath='{.metadata.uid}')

# Output as the full TokenRequest object, to see the granted expiry
kubectl -n ci create token build-bot --duration=1h -o yaml
```

```yaml
apiVersion: authentication.k8s.io/v1
kind: TokenRequest
spec:
  audiences:
  - https://kubernetes.default.svc.cluster.local
  boundObjectRef:
    apiVersion: v1
    kind: Pod
    name: auto
    uid: 3f2a1b0c-9d8e-7f6a-5b4c-3d2e1f0a9b8c
  expirationSeconds: 3600
status:
  expirationTimestamp: "2025-01-01T01:00:00Z"
  token: eyJhbGciOiJSUzI1NiIsImtpZCI6...
```

```
┌──────────────────────────────────────────────────────────────────┐
│  NOTES ON kubectl create token                                    │
├──────────────────────────────────────────────────────────────────┤
│  • It requires `create` on the SUBRESOURCE                        │
│      serviceaccounts/token                                        │
│    Granting that on a service account is equivalent to granting   │
│    everything that service account can do.                        │
│                                                                   │
│  • The requested --duration is a REQUEST. Check the granted       │
│    expiry in the output, or decode `exp` from the token.          │
│                                                                   │
│  • Minimum expiry is 600 seconds (10 minutes).                    │
│                                                                   │
│  • Nothing is persisted. There is no object to delete afterwards, │
│    and no way to list the tokens you have issued. Revocation is   │
│    by expiry, by bound object deletion, or by removing RBAC.      │
└──────────────────────────────────────────────────────────────────┘
```

```yaml
# The RBAC that lets a delegate mint tokens for ONE service account
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: build-bot-token-minter
  namespace: ci
rules:
- apiGroups: [""]
  resources: ["serviceaccounts/token"]
  resourceNames: ["build-bot"]        # this one account only
  verbs: ["create"]
```

Building a kubeconfig around such a token:

```bash
TOKEN=$(kubectl -n ci create token build-bot --duration=24h)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' |
  base64 -d > ca.crt

KUBECONFIG=bot.kubeconfig kubectl config set-cluster prod \
  --server="$APISERVER" --certificate-authority=ca.crt --embed-certs=true
KUBECONFIG=bot.kubeconfig kubectl config set-credentials build-bot --token="$TOKEN"
KUBECONFIG=bot.kubeconfig kubectl config set-context bot \
  --cluster=prod --user=build-bot --namespace=ci
KUBECONFIG=bot.kubeconfig kubectl config use-context bot
chmod 600 bot.kubeconfig

KUBECONFIG=bot.kubeconfig kubectl auth whoami
# Username  system:serviceaccount:ci:build-bot
```

> 📖 **See Also**: [authentication.md](authentication.md) for kubeconfig anatomy and the `tokenFile` credential style, which re-reads a rotating token from disk.

---

## imagePullSecrets

A ServiceAccount can carry registry credentials, which the ServiceAccount admission plugin then copies into every pod that uses it. This is how you avoid repeating `imagePullSecrets` in every manifest.

```bash
kubectl -n ci create secret docker-registry registry-creds \
  --docker-server=registry.example.com \
  --docker-username=ci-puller \
  --docker-password="${REGISTRY_PASSWORD}" \
  --docker-email=ci@example.com
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: build-bot
  namespace: ci
imagePullSecrets:
- name: registry-creds
```

```bash
# Or patch an existing one, including `default`
kubectl -n ci patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"registry-creds"}]}'
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                  HOW PROPAGATION WORKS                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│   Pod created with serviceAccountName: build-bot                      │
│            │                                                          │
│            ▼                                                          │
│   ServiceAccount admission plugin APPENDS the SA's imagePullSecrets   │
│   to spec.imagePullSecrets on the pod.                                │
│            │                                                          │
│            ▼                                                          │
│   The kubelet uses them when pulling images for that pod.             │
│                                                                       │
│   PROPERTIES                                                          │
│   • The Secret must be of type kubernetes.io/dockerconfigjson.        │
│   • It must live in the SAME NAMESPACE as the pod. There is no        │
│     cross namespace reference, which is why registry credentials      │
│     must be replicated into every namespace that needs them.          │
│   • It is APPENDED, not replaced: a pod may add its own on top.       │
│   • Existing pods are NOT updated. Only new pods get it.              │
│   • This has NOTHING to do with API authentication. It is a           │
│     convenience for the kubelet's image pulls.                        │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Verify the propagation happened
kubectl -n ci run puller --image=registry.example.com/app:1.0
kubectl -n ci get pod puller -o jsonpath='{.spec.imagePullSecrets}'
# [{"name":"registry-creds"}]

# The classic failure when it did not
kubectl -n ci describe pod puller | grep -A3 Events
#   Failed to pull image ...: unauthorized
```

> 📖 **See Also**: [secrets.md](secrets.md) for the `kubernetes.io/dockerconfigjson` type.

---

## Binding RBAC to a Service Account

A service account with no bindings can do essentially nothing, which is the correct default. Grant explicitly.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-watcher
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-watcher
  namespace: monitoring
rules:
- apiGroups: [""]
  resources: ["pods", "events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-watcher
  namespace: monitoring
subjects:
- kind: ServiceAccount
  name: pod-watcher
  namespace: monitoring     # REQUIRED. No apiGroup for ServiceAccount.
roleRef:
  kind: Role
  name: pod-watcher
  apiGroup: rbac.authorization.k8s.io
```

### Cluster Wide, With a Home Namespace

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: metrics-collector
subjects:
# The service account still LIVES in one namespace; the BINDING is
# what makes its permissions cluster wide.
- kind: ServiceAccount
  name: metrics-collector
  namespace: monitoring
roleRef:
  kind: ClusterRole
  name: metrics-reader
  apiGroup: rbac.authorization.k8s.io
```

### Granting to a Service Account in Another Namespace

```yaml
# The pipeline's SA lives in `ci`, but needs rights in `payments-prod`.
# The RoleBinding lives where the PERMISSIONS apply.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-can-deploy
  namespace: payments-prod
subjects:
- kind: ServiceAccount
  name: deployer
  namespace: ci              # a DIFFERENT namespace: this is allowed
roleRef:
  kind: ClusterRole
  name: app-developer
  apiGroup: rbac.authorization.k8s.io
```

```bash
# ALWAYS verify with impersonation, never by "it seems to work"
kubectl auth can-i --list --as=system:serviceaccount:ci:deployer -n payments-prod
kubectl auth can-i delete deployments \
  --as=system:serviceaccount:ci:deployer -n payments-prod       # expect: no
kubectl auth can-i list secrets \
  --as=system:serviceaccount:ci:deployer -n payments-prod       # expect: no
```

> 📖 **See Also**: [rbac.md](rbac.md) for the full scoping matrix and least privilege methodology.

---

## Calling the API From Inside a Pod

Everything needed is already in the container. No client library, no kubeconfig.

```bash
kubectl -n monitoring run apitest \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"serviceAccountName":"pod-watcher"}}' \
  --command -- sleep 3600

kubectl -n monitoring exec -it apitest -- sh
```

```bash
# Inside the pod
SA=/var/run/secrets/kubernetes.io/serviceaccount
TOKEN=$(cat $SA/token)
CACERT=$SA/ca.crt
NAMESPACE=$(cat $SA/namespace)
APISERVER=https://kubernetes.default.svc

echo "namespace: $NAMESPACE"

# 1. Who am I? Ask the API, do not assume.
curl -s --cacert $CACERT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -X POST \
  -d '{"apiVersion":"authentication.k8s.io/v1","kind":"SelfSubjectReview"}' \
  $APISERVER/apis/authentication.k8s.io/v1/selfsubjectreviews
```

```json
{
  "kind": "SelfSubjectReview",
  "apiVersion": "authentication.k8s.io/v1",
  "status": {
    "userInfo": {
      "username": "system:serviceaccount:monitoring:pod-watcher",
      "uid": "9c8b7a6d-...",
      "groups": [
        "system:serviceaccounts",
        "system:serviceaccounts:monitoring",
        "system:authenticated"
      ]
    }
  }
}
```

```bash
# 2. List pods in my own namespace
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  $APISERVER/api/v1/namespaces/$NAMESPACE/pods

# 3. Get one pod
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  $APISERVER/api/v1/namespaces/$NAMESPACE/pods/apitest

# 4. Something I am NOT allowed to do: the negative test that matters
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  $APISERVER/api/v1/namespaces/$NAMESPACE/secrets
```

```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "status": "Failure",
  "message": "secrets is forbidden: User \"system:serviceaccount:monitoring:pod-watcher\" cannot list resource \"secrets\" in API group \"\" in the namespace \"monitoring\"",
  "reason": "Forbidden",
  "code": 403
}
```

```bash
# 5. Watch, for a controller style loop
curl -sN --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/$NAMESPACE/pods?watch=true"

# 6. Create an object
curl -s --cacert $CACERT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -X POST \
  -d '{"apiVersion":"v1","kind":"ConfigMap",
       "metadata":{"name":"from-inside"},"data":{"hello":"world"}}' \
  $APISERVER/api/v1/namespaces/$NAMESPACE/configmaps
```

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⚠️  RE-READ THE TOKEN FILE ON EVERY REQUEST                         │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ❌ WRONG: reads once, breaks after roughly one hour                  │
│       TOKEN=$(cat $SA/token)                                          │
│       while true; do                                                  │
│         curl -H "Authorization: Bearer $TOKEN" ...                    │
│         sleep 300                                                     │
│       done                                                            │
│                                                                       │
│  ✅ RIGHT: reads the file each time                                   │
│       while true; do                                                  │
│         curl -H "Authorization: Bearer $(cat $SA/token)" ...          │
│         sleep 300                                                     │
│       done                                                            │
│                                                                       │
│  This is the single most common cause of a long running script that   │
│  works perfectly for an hour and then returns nothing but 401.        │
│                                                                       │
│  ❌ NEVER use curl -k or --insecure. The ca.crt is right there;       │
│     using it costs one flag and prevents a trivial man in the middle. │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## In-Cluster Configuration With Client Libraries

Every official client library implements the same convention, called **in-cluster config**: read the token file, read `ca.crt`, read the namespace file, and build the server URL from `KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT`. They also re-read the token file as it rotates, which is the main reason to prefer them over hand rolled HTTP.

```go
// Go, client-go
package main

import (
	"context"
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

func main() {
	// Reads the token, ca.crt and the KUBERNETES_SERVICE_* env vars.
	config, err := rest.InClusterConfig()
	if err != nil {
		panic(err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err)
	}
	pods, err := clientset.CoreV1().Pods("monitoring").
		List(context.TODO(), metav1.ListOptions{})
	if err != nil {
		panic(err)
	}
	fmt.Printf("%d pods\n", len(pods.Items))
}
```

```python
# Python, kubernetes client
from kubernetes import client, config

# Raises ConfigException when not running inside a pod.
config.load_incluster_config()

v1 = client.CoreV1Api()
for pod in v1.list_namespaced_pod(namespace="monitoring").items:
    print(pod.metadata.name, pod.status.phase)
```

```javascript
// Node.js, @kubernetes/client-node
const k8s = require('@kubernetes/client-node');

const kc = new k8s.KubeConfig();
kc.loadFromCluster();

const api = kc.makeApiClient(k8s.CoreV1Api);
api.listNamespacedPod('monitoring').then((res) => {
  res.body.items.forEach((p) => console.log(p.metadata.name));
});
```

```java
// Java, official client
import io.kubernetes.client.openapi.ApiClient;
import io.kubernetes.client.util.ClientBuilder;

ApiClient client = ClientBuilder.cluster().build();
```

The common pattern most libraries expose is "try in-cluster, fall back to a kubeconfig", so the same binary runs both in a pod and on a laptop:

```python
try:
    config.load_incluster_config()      # inside a pod
except config.ConfigException:
    config.load_kube_config()           # on a developer machine
```

---

## Workload Identity Federation

A service account token is a signed JWT with a published issuer, which means anything that speaks OIDC can verify it without asking Kubernetes. That single fact is the basis of every cloud workload identity mechanism.

### The Discovery Endpoints

When the API server is configured with an issuer URL, it can serve the standard OIDC discovery documents:

```bash
kubectl get --raw /.well-known/openid-configuration | jq .
```

```json
{
  "issuer": "https://kubernetes.default.svc.cluster.local",
  "jwks_uri": "https://kubernetes.default.svc.cluster.local/openid/v1/jwks",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
```

```bash
# The public keys, in JWKS form
kubectl get --raw /openid/v1/jwks | jq .
```

```
┌──────────────────────────────────────────────────────────────────────┐
│  ACCESS TO THE DISCOVERY ENDPOINTS                                    │
├──────────────────────────────────────────────────────────────────────┤
│  The built-in ClusterRole `system:service-account-issuer-discovery`   │
│  grants `get` on /.well-known/openid-configuration and                │
│  /openid/v1/jwks. It is NOT bound to anonymous users by default.      │
│                                                                       │
│  An external verifier must be able to reach these documents. The      │
│  usual approaches are:                                                │
│    • publish copies to a public HTTPS location (commonly an object    │
│      store) and set --service-account-issuer to that URL              │
│    • expose the endpoints through a gateway                           │
│                                                                       │
│  ⚠️  The JWKS contains PUBLIC keys only. Publishing it is safe and    │
│      is the intended design. The signing PRIVATE key never leaves     │
│      the API server.                                                  │
└──────────────────────────────────────────────────────────────────────┘
```

### The Federation Pattern

```
┌──────────────────────────────────────────────────────────────────────┐
│               WORKLOAD IDENTITY, IN GENERAL TERMS                     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  1. The pod gets a PROJECTED TOKEN with an audience naming the        │
│     external system, NOT the Kubernetes API.                          │
│                                                                       │
│       volumes:                                                        │
│       - name: cloud-token                                             │
│         projected:                                                    │
│           sources:                                                    │
│           - serviceAccountToken:                                      │
│               path: token                                             │
│               expirationSeconds: 3600                                 │
│               audience: <the external system's expected audience>     │
│                                                                       │
│  2. The workload PRESENTS that token to the external system's         │
│     token exchange endpoint.                                          │
│                                                                       │
│  3. THE EXTERNAL SYSTEM VERIFIES IT WITHOUT CONTACTING KUBERNETES:    │
│       • fetches the JWKS from the published issuer                    │
│       • checks the signature, iss, aud and exp                        │
│       • reads `sub`, which is                                         │
│           system:serviceaccount:<namespace>:<name>                    │
│                                                                       │
│  4. Its own policy maps that subject to a role or identity, and it    │
│     returns SHORT LIVED CREDENTIALS for itself.                       │
│                                                                       │
│  WHAT THIS ELIMINATES                                                 │
│    No static cloud access keys in Secrets. No long lived credentials  │
│    in environment variables. No credential rotation to schedule.      │
│    The trust anchor is the cluster's signing key, and the identity    │
│    is the namespace and service account name, which are the same      │
│    things your RBAC already reasons about.                            │
│                                                                       │
│  NOTE: each cloud provider names this differently and has its own     │
│  configuration steps for registering the issuer and mapping           │
│  subjects to roles. Consult that provider's documentation for the     │
│  specifics; the mechanism above is the part Kubernetes defines.       │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```yaml
# A pod with two tokens: one for the Kubernetes API (auto injected),
# and one explicitly minted for an external system.
apiVersion: v1
kind: Pod
metadata:
  name: federated
  namespace: apps
spec:
  serviceAccountName: cloud-worker
  containers:
  - name: app
    image: app:1.0
    env:
    - name: EXTERNAL_TOKEN_FILE
      value: /var/run/secrets/external/token
    volumeMounts:
    - name: external-token
      mountPath: /var/run/secrets/external
      readOnly: true
  volumes:
  - name: external-token
    projected:
      sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
          audience: https://sts.example-cloud.com
```

```bash
# Confirm the audience is what you intended, before debugging anything else
kubectl -n apps exec federated -- cat /var/run/secrets/external/token |
  cut -d. -f2 | base64 -d 2>/dev/null | jq '.aud, .sub, .exp'
```

The same pattern works for in-cluster consumers such as a secrets manager: give it a distinct audience, let it verify the token against the cluster's JWKS, and map `sub` to a policy.

---

## Security Guidance

```
┌──────────────────────────────────────────────────────────────────────┐
│                    SERVICE ACCOUNT SECURITY                           │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  1. ONE SERVICE ACCOUNT PER WORKLOAD.                                 │
│     Sharing one account across several deployments means the          │
│     permissions are the union of what all of them need, and an        │
│     audit log entry cannot tell you which one acted.                  │
│                                                                       │
│  2. NEVER USE OR GRANT ANYTHING TO `default`.                         │
│     It is shared by every workload in the namespace that did not      │
│     choose otherwise, including ones added long after your review.    │
│                                                                       │
│  3. DISABLE automountServiceAccountToken FOR WORKLOADS THAT NEVER     │
│     CALL THE API. That is most of them. A credential that is not      │
│     mounted cannot be stolen.                                         │
│                                                                       │
│  4. NEVER BIND cluster-admin TO A SERVICE ACCOUNT.                    │
│     Anyone who can create a pod in that namespace, or exec into an    │
│     existing one, inherits it.                                        │
│                                                                       │
│  5. ANYONE WHO CAN CREATE A POD IN A NAMESPACE CAN USE ANY SERVICE    │
│     ACCOUNT IN THAT NAMESPACE.                                        │
│         kubectl run x --image=alpine \                                │
│           --overrides='{"spec":{"serviceAccountName":"powerful"}}'    │
│           -- sleep 3600                                               │
│         kubectl exec x -- cat /var/run/secrets/.../token              │
│     There is no per service account "who may use this" control in     │
│     RBAC. `create pods` in a namespace is therefore AT LEAST as       │
│     powerful as the strongest service account in it. The same         │
│     applies to `pods/exec` into a pod already running as that SA.     │
│                                                                       │
│  6. PUT PRIVILEGED SERVICE ACCOUNTS IN THEIR OWN NAMESPACE            │
│     where no human holds `edit`, `admin`, `create pods` or            │
│     `pods/exec`. That is the only real containment for point 5.       │
│                                                                       │
│  7. PREFER BOUND, SHORT LIVED TOKENS. Use `kubectl create token`      │
│     with a small `--duration` rather than a permanent Secret.         │
│                                                                       │
│  8. SET AN AUDIENCE when a token is for something other than the      │
│     Kubernetes API, so it cannot be replayed against the API.         │
│                                                                       │
│  9. AVOID `list` ON SECRETS. It returns full object bodies, so it     │
│     reads every secret in scope.                                      │
│                                                                       │
│ 10. NEVER LOG A TOKEN. Not in debug output, not in an error message,  │
│     not in a support bundle. A leaked bound token is bad; a leaked    │
│     long lived one is a cluster incident.                             │
│                                                                       │
│ 11. ENABLE ENCRYPTION AT REST if any service account token Secret     │
│     exists, because etcd backups otherwise contain live credentials.  │
│                                                                       │
│ 12. AUDIT REGULARLY: which service accounts exist, which are used by  │
│     no pod, which are bound to powerful roles, which pods still       │
│     mount a token they do not need.                                   │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Service accounts bound to cluster-admin: the first audit to run
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name=="cluster-admin")
  | .metadata.name as $n
  | .subjects[]? | select(.kind=="ServiceAccount")
  | "\($n)\t\(.namespace)/\(.name)"'

# Service accounts that no pod uses (candidates for deletion)
comm -23 \
  <(kubectl get sa -A -o custom-columns=':.metadata.namespace,:.metadata.name' \
      --no-headers | awk '{print $1"/"$2}' | sort) \
  <(kubectl get pods -A -o custom-columns=':.metadata.namespace,:.spec.serviceAccountName' \
      --no-headers | awk '{print $1"/"$2}' | sort -u)

# Long lived token Secrets still present anywhere
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token

# Who can create pods in a namespace, and therefore use any SA in it
for u in alice bob carol; do
  printf '%-8s %s\n' "$u" "$(kubectl auth can-i create pods --as="$u" -n prod)"
done
```

---

## Command Reference

```bash
# ---------- SERVICE ACCOUNTS ----------
kubectl create serviceaccount build-bot -n ci
kubectl get serviceaccounts -n ci
kubectl get sa -A
kubectl describe sa build-bot -n ci
kubectl delete sa build-bot -n ci
kubectl create sa x -n ci --dry-run=client -o yaml

# ---------- ASSIGN TO A POD ----------
kubectl run app --image=alpine:3.20 \
  --overrides='{"spec":{"serviceAccountName":"build-bot"}}' \
  --command -- sleep 3600

kubectl set serviceaccount deployment/web build-bot -n ci

kubectl get pods -n ci \
  -o custom-columns='POD:.metadata.name,SA:.spec.serviceAccountName'

# ---------- TOKENS ----------
kubectl create token build-bot -n ci
kubectl create token build-bot -n ci --duration=15m
kubectl create token build-bot -n ci --audience=https://vault.example.com
kubectl create token build-bot -n ci --duration=1h -o yaml

# Decode
kubectl create token build-bot -n ci | cut -d. -f2 | base64 -d 2>/dev/null | jq .

# ---------- INSIDE A POD ----------
kubectl exec -n ci app -- ls -l /var/run/secrets/kubernetes.io/serviceaccount/
kubectl exec -n ci app -- cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
kubectl exec -n ci app -- cat /var/run/secrets/kubernetes.io/serviceaccount/token

# ---------- AUTOMOUNT ----------
kubectl patch serviceaccount default -n web \
  -p '{"automountServiceAccountToken":false}'

kubectl get pods -A -o json | jq -r '
  .items[] | select((.spec.automountServiceAccountToken // true) == true)
  | "\(.metadata.namespace)/\(.metadata.name)"'

# ---------- IMAGE PULL SECRETS ----------
kubectl create secret docker-registry registry-creds -n ci \
  --docker-server=registry.example.com \
  --docker-username=u --docker-password=p

kubectl patch serviceaccount build-bot -n ci \
  -p '{"imagePullSecrets":[{"name":"registry-creds"}]}'

# ---------- RBAC ----------
kubectl create rolebinding build-bot-reader \
  --role=pod-reader --serviceaccount=ci:build-bot -n ci

kubectl create clusterrolebinding monitor \
  --clusterrole=view --serviceaccount=monitoring:collector

kubectl auth can-i --list --as=system:serviceaccount:ci:build-bot -n ci
kubectl auth can-i list secrets --as=system:serviceaccount:ci:build-bot -n ci

# ---------- IDENTITY AND DISCOVERY ----------
kubectl auth whoami
kubectl get --raw /.well-known/openid-configuration | jq .
kubectl get --raw /openid/v1/jwks | jq .
```

---

## Troubleshooting

### 401 Unauthorized From Inside a Pod

```bash
SA=/var/run/secrets/kubernetes.io/serviceaccount

# 1. Does the token file even exist?
kubectl exec -n ci app -- ls -l $SA/
# No such file or directory → automountServiceAccountToken is false

# 2. Has it expired?
kubectl exec -n ci app -- cat $SA/token |
  cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.exp' | xargs -I{} date -d @{}

# 3. What audience is it for?
kubectl exec -n ci app -- cat $SA/token |
  cut -d. -f2 | base64 -d 2>/dev/null | jq '.aud'

# 4. Is the application caching the token instead of re-reading it?
#    Symptom: works for about an hour after every pod start.

# 5. Does the SA still exist with the same uid?
kubectl -n ci get sa build-bot -o jsonpath='{.metadata.uid}{"\n"}'
kubectl exec -n ci app -- cat $SA/token |
  cut -d. -f2 | base64 -d 2>/dev/null | jq -r '."kubernetes.io".serviceaccount.uid'
```

| Symptom | Cause | Fix |
|---------|-------|-----|
| No `/var/run/secrets/kubernetes.io/serviceaccount` directory | `automountServiceAccountToken: false` on the pod or the SA | Set it to `true` on the pod, or add an explicit projected volume |
| 401 after roughly one hour, every time | The application read the token once and cached it | Re-read the file per request, or use an official client library |
| 401 immediately, token looks fine | Wrong `aud`: the token was minted for something else | Remove the custom `audience`, or add it to `--api-audiences` |
| 401 after the pod was recreated | An old token from the previous pod uid is being used | Read the current file; do not copy tokens between pods |
| 401 for a token pasted from a Secret | The ServiceAccount was deleted and recreated, changing its uid | Recreate the token Secret |
| 401 cluster wide after a control plane change | The service account signing key was rotated | Restart workloads; ensure the old public key stays in `--service-account-key-file` during rotation |
| `x509: certificate signed by unknown authority` | Not using `--cacert $SA/ca.crt` | Use the mounted CA; never use `-k` |

### 403 Forbidden From Inside a Pod

Authentication worked. This is RBAC.

```bash
# The message names everything you need
# secrets is forbidden: User "system:serviceaccount:ci:build-bot" cannot
# list resource "secrets" in API group "" in the namespace "ci"

kubectl auth can-i --list --as=system:serviceaccount:ci:build-bot -n ci

kubectl get rolebindings,clusterrolebindings -A -o json | jq -r '
  .items[] | select(.subjects[]? |
    (.kind=="ServiceAccount" and .name=="build-bot" and .namespace=="ci"))
  | "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.name)"'
```

Frequent causes, in order of how often they occur: the pod is using `default` rather than the intended service account; the RoleBinding is in the wrong namespace; the subject omits `namespace`; the subject wrongly includes `apiGroup: rbac.authorization.k8s.io` for a ServiceAccount kind.

```bash
# The first thing to check, always
kubectl -n ci get pod app -o jsonpath='{.spec.serviceAccountName}{"\n"}'
```

### Pod Will Not Start: `serviceaccount not found`

```bash
kubectl -n ci describe pod app | tail -20
# Error creating: pods "app" is forbidden: error looking up service account
# ci/build-bot: serviceaccount "build-bot" not found

kubectl -n ci get sa
```

The ServiceAccount must exist in the pod's own namespace before the pod is created. In a Deployment this shows up as a ReplicaSet that reports the error in its events while the replica count stays at zero:

```bash
kubectl -n ci describe replicaset -l app=web | tail -20
```

### Image Pull Failures Despite imagePullSecrets

```bash
kubectl -n ci get pod puller -o jsonpath='{.spec.imagePullSecrets}'
# empty → the SA had no imagePullSecrets when the pod was CREATED

kubectl -n ci get sa build-bot -o jsonpath='{.imagePullSecrets}'
kubectl -n ci get secret registry-creds -o jsonpath='{.type}'
# must be kubernetes.io/dockerconfigjson
```

Remember that propagation happens at pod creation. Adding `imagePullSecrets` to a ServiceAccount does nothing for pods that already exist; restart them.

### Token Never Appears in a Long Lived Secret

```bash
kubectl -n ci get secret build-bot-token -o yaml
```

```
┌──────────────────────────────────────────────────────────────────┐
│  data is empty. Check, in order:                                  │
│  1. type is exactly kubernetes.io/service-account-token           │
│  2. the annotation kubernetes.io/service-account.name is present  │
│     and spelled correctly                                         │
│  3. the named ServiceAccount EXISTS in the SAME namespace         │
│  4. kube-controller-manager is running and healthy                │
│       kubectl -n kube-system get pods -l component=              │
│         kube-controller-manager                                   │
└──────────────────────────────────────────────────────────────────┘
```

### Verifying an Arbitrary Token

```bash
cat <<EOF | kubectl create -f - -o jsonpath='{.status}'
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: ${TOKEN}
  audiences: ["https://kubernetes.default.svc.cluster.local"]
EOF
```

`authenticated: false` with an audience mismatch is the clearest possible confirmation that the token was minted for something else.

---

## Exam and Interview Traps

1. **Every pod runs with a service account.** If `serviceAccountName` is unset, the pod uses `default` in its namespace. There is no such thing as a pod with no identity.
2. **The `default` service account exists in every namespace and cannot be permanently deleted.** The controller recreates it, with a new uid.
3. **`default` has no permissions out of the box**, beyond what `system:basic-user` and `system:discovery` give every authenticated identity.
4. **The username is `system:serviceaccount:<namespace>:<name>`**, and that full string is what you pass to `--as`.
5. **The groups are `system:serviceaccounts`, `system:serviceaccounts:<namespace>` and `system:authenticated`.** Binding a role to any of them affects far more identities than people expect.
6. **A pod can only reference a ServiceAccount in its own namespace.** A RoleBinding, by contrast, can reference a ServiceAccount from another namespace.
7. **`serviceAccountName` is immutable on a running pod**, and lives under `spec.template.spec` in a Deployment.
8. **`serviceAccount` without "Name" is a deprecated alias** that still appears in output. Write `serviceAccountName`.
9. **Since Kubernetes 1.24, creating a ServiceAccount does not create a Secret.** `Tokens: <none>` in `describe` is normal and correct.
10. **Modern tokens are bound, audience scoped and time limited**, issued by the TokenRequest API and delivered through a projected volume. They are never stored in etcd.
11. **The token, `ca.crt` and `namespace` files are at `/var/run/secrets/kubernetes.io/serviceaccount/`.** Know that path by heart.
12. **The `namespace` file has no trailing newline.** Scripts that append it to a URL without trimming still work; scripts that compare it to a string with a newline do not.
13. **The kubelet refreshes the token when it passes 80% of its lifetime, or 24 hours, whichever comes first.** Applications must re-read the file, not cache the string.
14. **`subPath` breaks token refresh**, exactly as it does for ConfigMap and Secret volumes.
15. **Minimum `expirationSeconds` is 600 (10 minutes)**, and the API server can cap the maximum.
16. **The pod name and uid are inside the token**, which is what makes it bound. Deleting the pod invalidates it immediately.
17. **Deleting a RoleBinding does not invalidate a token.** It removes permissions, so the token authenticates and then gets 403.
18. **`automountServiceAccountToken` on the Pod always wins** over the setting on the ServiceAccount.
19. **The default is `true`.** Disabling it is an active decision you have to make for every workload that does not call the API.
20. **A long lived token needs a Secret of type `kubernetes.io/service-account-token` with the annotation `kubernetes.io/service-account.name`**, and the ServiceAccount must already exist in the same namespace.
21. **Those Secret tokens have no `exp` and no `aud`.** They are valid until the Secret is deleted, and they sit in every etcd backup.
22. **`kubectl create token` persists nothing.** There is no object to list or delete afterwards, and revocation is by expiry, bound object deletion, or RBAC removal.
23. **`kubectl create token` requires `create` on `serviceaccounts/token`**, which is effectively a grant of that service account's whole permission set.
24. **A token minted with `--audience` for another system will not authenticate to the Kubernetes API.** That is the feature, and it is a common self inflicted 401.
25. **`imagePullSecrets` on a ServiceAccount propagate to pods at creation time only**, must be `kubernetes.io/dockerconfigjson`, and must live in the same namespace.
26. **`imagePullSecrets` have nothing to do with API authentication.** They are for the kubelet's image pulls.
27. **A ServiceAccount subject in a binding needs `namespace` and must not set `apiGroup`.** User and Group are the opposite.
28. **Anyone who can create a pod in a namespace can use any service account in it**, and therefore holds the permissions of the strongest one. The same is true of `pods/exec`.
29. **Never bind `cluster-admin` to a namespaced service account.** It converts `edit` in that namespace into cluster-admin.
30. **In-cluster config comes from the mounted files plus `KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT`**, and every official client library implements it, including token refresh.
31. **`https://kubernetes.default.svc` is the correct in-cluster API endpoint**, because it matches the API server certificate's SAN list.
32. **Never use `curl -k` inside a pod.** The correct CA bundle is mounted next to the token.
33. **The JWKS at `/openid/v1/jwks` contains public keys only.** Publishing it is the intended design and is what makes workload identity federation possible.
34. **Federation works because an external verifier checks the signature offline and reads `sub`**, which is the service account username. Kubernetes is never contacted during that exchange.

---

## Related Topics

- [Authentication](authentication.md)
- [RBAC](rbac.md)
- [Secrets](secrets.md)
- [ConfigMaps](configmaps.md)
- [Downward API](downward-api.md)
- [Pods](pods.md)
- [Deployments](deployments.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [Controllers](controllers.md)
- [Kubernetes API](k8s-api.md)
- [kube-apiserver](kube-apiserver.md)
- [kube-controller-manager](kube-controller-manager.md)
- [kubelet](kubelet.md)
- [kubectl](kubectl.md)
- [Services](services.md)
- [CoreDNS](coredns.md)
- [Network Policy](network-policy.md)
- [etcd](etcd.md)

---

## Key Takeaways

1. **A ServiceAccount is machine identity, and unlike a user it is a real, namespaced API object** that you create, list and delete like anything else. Its username is derived, never chosen: `system:serviceaccount:<namespace>:<name>`.
2. **Every pod has one.** If you do not choose, the pod uses `default`, which is shared with every other unlabelled workload in the namespace and should therefore be granted nothing.
3. **The model changed for good reasons.** The old permanent Secret token had no expiry, no audience and no binding, sat in etcd and in every backup, and was readable by anyone with `get secrets`. Since Kubernetes 1.24 those Secrets are no longer created automatically.
4. **Modern tokens are issued by the TokenRequest API and delivered through a projected volume**: time limited, audience scoped, and bound to the pod by name and uid, so deleting the pod invalidates the token immediately.
5. **The kubelet refreshes the token in place**, at 80% of its lifetime or 24 hours, whichever is first. Applications must re-read `/var/run/secrets/kubernetes.io/serviceaccount/token` rather than caching it, which is the single most common cause of a workload that fails exactly one hour after starting.
6. **The three in-pod files are `token`, `ca.crt` and `namespace`**, and together with `KUBERNETES_SERVICE_HOST` they are everything a client needs. `curl -k` is never necessary and never acceptable.
7. **Decoding the JWT tells you everything**: `sub` is the RBAC username, `aud` is who the token is for, `exp` is when it dies, and the `kubernetes.io` claims name the namespace, the service account and the pod, with uids.
8. **`automountServiceAccountToken` on the pod always beats the setting on the ServiceAccount**, and the default is on. Turn it off for every workload that never calls the API, which is most of them.
9. **A long lived token is now a deliberate act**: a Secret of type `kubernetes.io/service-account-token` annotated with `kubernetes.io/service-account.name`. It is justified only for external systems that cannot refresh, and the identity behind it should be as small as possible.
10. **`kubectl create token` with `--duration` and `--audience` is the right tool for everything else.** It persists nothing, and an audience scoped token cannot be replayed against the API server.
11. **`imagePullSecrets` on a ServiceAccount are a kubelet convenience, not an authentication mechanism.** They propagate to new pods only, must be `kubernetes.io/dockerconfigjson`, and must live in the same namespace.
12. **Anyone who can create a pod in a namespace, or exec into one, can use any service account in that namespace.** That single fact drives the whole discipline: one service account per workload, nothing granted to `default`, never `cluster-admin` on a namespaced account, and privileged accounts isolated in namespaces where no human holds `edit` or `pods/exec`.

---

## References

- [Managing Service Accounts](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)
- [Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [Service Accounts Concept](https://kubernetes.io/docs/concepts/security/service-accounts/)
- [Authenticating: Service Account Tokens](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#service-account-tokens)
- [TokenRequest v1](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/token-request-v1/)
- [ServiceAccount v1](https://kubernetes.io/docs/reference/kubernetes-api/authentication-resources/service-account-v1/)
- [Projected Volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
- [Service Account Token Volume Projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection)
- [Accessing the Kubernetes API From a Pod](https://kubernetes.io/docs/tasks/run-application/access-api-from-pod/)
- [Service Account Issuer Discovery](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-issuer-discovery)
- [Pull an Image From a Private Registry](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Role Based Access Control Good Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
- [Security Checklist](https://kubernetes.io/docs/concepts/security/security-checklist/)
