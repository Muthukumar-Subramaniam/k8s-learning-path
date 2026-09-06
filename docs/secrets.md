# 🔐 Secrets: Handling Sensitive Data in Kubernetes

A rigorous guide to the Secret API object: what it protects and what it does not, every built in type, every way to create and consume one, encryption at rest end to end, and the operational discipline that turns a base64 blob into an actual security control.

## 📋 Table of Contents
- [What a Secret Is, and What It Is Not](#what-a-secret-is-and-what-it-is-not)
- [Anatomy of the Object](#anatomy-of-the-object)
- [data versus stringData](#data-versus-stringdata)
- [Built In Secret Types](#built-in-secret-types)
- [Creating Secrets](#creating-secrets)
- [Reading and Decoding Secrets](#reading-and-decoding-secrets)
- [Consuming Secrets: Environment Variables](#consuming-secrets-environment-variables)
- [Consuming Secrets: Volume Mounts](#consuming-secrets-volume-mounts)
- [Why Volumes Beat Environment Variables](#why-volumes-beat-environment-variables)
- [Image Pull Secrets](#image-pull-secrets)
- [Update Behaviour and tmpfs Backing](#update-behaviour-and-tmpfs-backing)
- [Encryption at Rest](#encryption-at-rest)
- [Verifying Encryption With etcdctl](#verifying-encryption-with-etcdctl)
- [RBAC Hygiene for Secrets](#rbac-hygiene-for-secrets)
- [Service Account Tokens](#service-account-tokens)
- [External Secret Management](#external-secret-management)
- [Rotation Strategy](#rotation-strategy)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What a Secret Is, and What It Is Not

A **Secret** is a namespaced API object for storing a small amount of sensitive data: a password, a token, a private key, a certificate. Structurally it is nearly identical to a [ConfigMap](configmaps.md). Behaviourally it differs in a handful of important ways.

### The Single Most Important Fact

```
╔═════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║        BASE64 IS AN ENCODING, NOT AN ENCRYPTION.                     ║
║                                                                      ║
║        It is a transport format for arbitrary bytes over a           ║
║        text protocol. It has no key. It is reversible by             ║
║        anyone, instantly, with no secret material at all:            ║
║                                                                      ║
║            $ echo 'c3VwZXJzZWNyZXQ=' | base64 -d                     ║
║            supersecret                                               ║
║                                                                      ║
║        A Secret is NOT encrypted by default. It is stored in         ║
║        etcd in plaintext unless you explicitly configure             ║
║        encryption at rest on the API server.                         ║
║                                                                      ║
╚═════════════════════════════════════════════════════════════════════╝
```

Base64 is there because `data` values are byte arrays and JSON has no byte array type. That is the entire reason. It provides no confidentiality whatsoever.

### What a Secret Actually Gives You Over a ConfigMap

| Property | ConfigMap | Secret |
|----------|-----------|--------|
| Values stored as | UTF-8 strings and base64 blobs | base64 encoded bytes only |
| Node storage for volume mounts | kubelet pod directory on disk | **tmpfs**, RAM backed, never written to node disk |
| Distributed to nodes | Only to nodes running a consuming Pod | Only to nodes running a consuming Pod |
| Values shown by `kubectl describe` | Full contents | Byte counts only, never values |
| Encryption at rest | Only if you configure it | Only if you configure it, but this is the object you configure it for |
| Typed with required keys | No | Yes, several built in types |
| Auditable as a distinct resource | Yes | Yes, and worth a dedicated audit policy rule |

```
┌─────────────────────────────────────────────────────────────────────┐
│                  Secret Protections: Real vs Imagined                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ✅ REAL                                                             │
│     • tmpfs backing: secret volume contents never hit node disk      │
│     • kubelet only fetches secrets used by Pods on its own node      │
│       (enforced by the Node authorizer and NodeRestriction)          │
│     • kubectl describe redacts the values                            │
│     • separate RBAC resource, so you can grant configmaps without    │
│       granting secrets                                               │
│     • can be encrypted at rest in etcd, including via an external    │
│       KMS                                                            │
│     • audit logging can single out secret access                     │
│                                                                      │
│  ❌ IMAGINED                                                         │
│     • base64 does NOT hide anything                                  │
│     • not encrypted in etcd by default                               │
│     • not encrypted in transit beyond ordinary TLS                   │
│     • not hidden from anyone with `get secrets` in the namespace     │
│     • not hidden from anyone who can create a Pod in the namespace   │
│     • not hidden from anyone with root on a node running a           │
│       consuming Pod                                                  │
│     • not versioned, not rotated, not expired by Kubernetes          │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### The Threat Model, Stated Plainly

Before you decide a Secret is good enough, be explicit about who you are defending against:

| Adversary | Does a plain Secret help? |
|-----------|---------------------------|
| A developer who should not see production credentials | Yes, via RBAC, provided they cannot create Pods in that namespace |
| Someone reading a Git repository | Yes, if the value is not committed. This is the main win: get credentials out of Git |
| Someone with an etcd backup or a stolen disk | **No**, unless encryption at rest is enabled with a key stored elsewhere |
| Someone with `get secrets` RBAC in the namespace | No |
| Someone who can create a Pod in the namespace | **No.** They can mount any Secret in that namespace and read it |
| Someone with root on a node | No, for the Secrets used by Pods on that node |
| A compromised application process | Partially: volume mounts limit blast radius compared with environment variables |

The realistic goal is: **credentials live outside Git and outside the image, access is governed by RBAC and audited, the etcd data at rest is encrypted, and the blast radius of any single compromise is small and rotatable.** Not "the value is hidden from the cluster".

### Size and Scope

- Namespaced. A Pod can only reference Secrets in **its own namespace**. There is no cross namespace reference syntax.
- Limited to roughly **1 MiB**, for the same etcd reason as ConfigMaps. Plenty for keys and certificates, useless for anything large.
- Supports `immutable: true` with the same semantics and the same scale benefit as ConfigMaps: the kubelet closes its watch.

---

## Anatomy of the Object

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: production
  labels:
    app.kubernetes.io/name: myapp
type: Opaque                      # defaults to Opaque if omitted
data:                             # values MUST be base64 encoded
  username: YWRtaW4=              # "admin"
  password: czNjcjN0UEBzcw==      # "s3cr3tP@ss"
stringData:                       # values in plaintext, WRITE ONLY
  connection-string: "postgresql://admin:s3cr3tP@ss@db:5432/appdb"
immutable: false
```

| Field | Type | Notes |
|-------|------|-------|
| `type` | string | Determines which keys are expected and how the Secret is used. Defaults to `Opaque`. **Immutable after creation.** |
| `data` | `map[string][]byte` | Base64 encoded in YAML and JSON. Keys follow the same `[-._a-zA-Z0-9]+` rule as ConfigMaps. |
| `stringData` | `map[string]string` | Plaintext convenience field. Write only: never returned on read. |
| `immutable` | bool | When true, `data` and `stringData` can never change again. |

The `type` field being immutable after creation surprises people. If you create an `Opaque` Secret and later realise it should have been `kubernetes.io/tls`, you must delete and recreate it.

---

## data versus stringData

```
┌─────────────────────────────────────────────────────────────────────┐
│                       data vs stringData                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  data:                             stringData:                       │
│  ─────────────────────────────     ───────────────────────────────   │
│  base64 encoded values             plaintext values                  │
│  read/write                        WRITE ONLY                        │
│  what the API returns              never returned by the API         │
│  what is actually stored           merged into data on write         │
│  awkward to hand edit              readable in a manifest            │
│                                                                      │
│  WRITE PATH:                                                         │
│    your manifest ──► API server ──► base64(stringData values)        │
│                                     merged into data                 │
│                                     stringData discarded             │
│                                                                      │
│  READ PATH:                                                          │
│    API server ──► data (base64) only. stringData is GONE.            │
│                                                                      │
│  COLLISION RULE:                                                     │
│    If the same key appears in both, the stringData value WINS.       │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Demonstration:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: demo
type: Opaque
data:
  shared: b2xkLXZhbHVl          # "old-value"
  only-in-data: ZGF0YQ==        # "data"
stringData:
  shared: new-value             # wins over data.shared
  only-in-string: plaintext
```

```bash
$ kubectl apply -f demo.yaml
$ kubectl get secret demo -o yaml
apiVersion: v1
data:
  only-in-data: ZGF0YQ==
  only-in-string: cGxhaW50ZXh0
  shared: bmV3LXZhbHVl              # "new-value": stringData won
kind: Secret
metadata:
  name: demo
type: Opaque
# note: no stringData field in the response at all
```

### The Round Trip Trap

Because `stringData` is not returned, this sequence destroys information you may care about:

```bash
kubectl get secret demo -o yaml > demo-backup.yaml
# demo-backup.yaml now contains only `data`, all base64.
# Your nicely readable stringData manifest is not recoverable from the cluster.
```

Keep the authoritative manifest in Git (with the values templated or sealed, never committed in plaintext), and treat the cluster as a projection of it.

### Multi Line Values in stringData

`stringData` handles multi line content cleanly, which is its main practical advantage:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ssh-key
type: kubernetes.io/ssh-auth
stringData:
  ssh-privatekey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz
    c2gtZWQyNTUxOQAAACBmwn6H2dJcqTKlUrTdD5W4kEg7hZ8h9L8kZ0V6Y1Qh1w
    -----END OPENSSH PRIVATE KEY-----
```

Compare with the `data` equivalent, which requires you to base64 the entire multi line blob into one unreadable string. Both are equally insecure in Git; `stringData` is simply less painful to work with when the value comes from a templating engine or a secret manager at deploy time.

### Base64 Encoding by Hand

```bash
# encode
echo -n 'admin' | base64
# YWRtaW4=

# ⚠️ WITHOUT -n, echo appends a newline and you encode "admin\n"
echo 'admin' | base64
# YWRtaW4K      ← note the K: this is a DIFFERENT value

# encode a file
base64 -w0 < tls.crt          # -w0 prevents line wrapping (GNU coreutils)
base64 -i tls.crt             # macOS equivalent behaviour differs, check your tool

# decode
echo -n 'YWRtaW4=' | base64 -d
```

**The missing `-n` is the most common Secret bug in existence.** A trailing newline in a password gives an authentication failure that looks exactly like a wrong password, and the value looks correct when you print it. Detect it:

```bash
kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d | xxd | tail -1
# if the last byte is 0a, you have a stray newline
```

Avoid the whole class of bug by using `stringData` or `kubectl create secret`, both of which do the encoding for you without shell involvement.

---

## Built In Secret Types

The `type` field tells Kubernetes and its clients what shape to expect. Some types have keys the API server validates; others are conventions that only consumers enforce.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Secret Types                                    │
├─────────────────────────────────┬───────────────────────────────────────┤
│ type                            │ expected keys                          │
├─────────────────────────────────┼───────────────────────────────────────┤
│ Opaque                          │ anything (default)                     │
│ kubernetes.io/service-account-  │ token, ca.crt, namespace               │
│   token                         │ + annotation kubernetes.io/            │
│                                 │   service-account.name                 │
│ kubernetes.io/dockercfg         │ .dockercfg                             │
│ kubernetes.io/dockerconfigjson  │ .dockerconfigjson                      │
│ kubernetes.io/basic-auth        │ username, password                     │
│ kubernetes.io/ssh-auth          │ ssh-privatekey                         │
│ kubernetes.io/tls               │ tls.crt, tls.key                       │
│ bootstrap.kubernetes.io/token   │ token-id, token-secret, and optional   │
│                                 │   usage/expiration/group keys          │
└─────────────────────────────────┴───────────────────────────────────────┘
```

You may also define your own type string. The convention is a domain prefixed name such as `example.com/my-type`. Kubernetes performs no validation on custom types; they exist purely so that your own tooling can filter on them.

### Opaque

The default and the workhorse. Arbitrary key value pairs, no validation, no expectations.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
type: Opaque
stringData:
  DB_PASSWORD: "s3cr3tP@ss"
  API_KEY: "ak_live_4f8a9b2c1d3e"
  JWT_SIGNING_KEY: "hunter2butlonger"
```

An omitted `type` is treated as `Opaque`.

### kubernetes.io/service-account-token

Holds a token that authenticates as a ServiceAccount. Requires the annotation naming the ServiceAccount; the token controller populates `token`, `ca.crt` and `namespace`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-legacy-token
  annotations:
    kubernetes.io/service-account.name: myapp
type: kubernetes.io/service-account-token
```

```bash
$ kubectl get secret myapp-legacy-token -o jsonpath='{.data}' | jq keys
[
  "ca.crt",
  "namespace",
  "token"
]
```

**These tokens do not expire, are not bound to a Pod, and remain valid until the Secret is deleted.** Modern Kubernetes does not auto create them for ServiceAccounts; workloads use projected, bound, short lived tokens instead. See [Service Account Tokens](#service-account-tokens). Create one manually only when an external, non Pod client genuinely needs a long lived credential, and treat it as a high value target.

### kubernetes.io/dockercfg and kubernetes.io/dockerconfigjson

Both hold registry credentials for pulling private images. `dockercfg` is the legacy `~/.dockercfg` format under the key `.dockercfg`; `dockerconfigjson` is the modern `~/.docker/config.json` format under the key `.dockerconfigjson`. Use the latter.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: regcred
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: eyJhdXRocyI6eyJyZWdpc3RyeS5leGFtcGxlLmNvbSI6eyJ1c2Vy...
```

The decoded structure:

```json
{
  "auths": {
    "registry.example.com": {
      "username": "deploy-bot",
      "password": "REDACTED",
      "email": "deploy@example.com",
      "auth": "ZGVwbG95LWJvdDpSRURBQ1RFRA=="
    }
  }
}
```

Note the `auth` field is itself `base64(username:password)`, so the credential appears twice. Never construct this by hand; use `kubectl create secret docker-registry`.

### kubernetes.io/basic-auth

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: basic-auth-creds
type: kubernetes.io/basic-auth
stringData:
  username: admin
  password: s3cr3tP@ss
```

Kubernetes expects the keys `username` and `password`. The type is a convention that lets consumers (ingress controllers, operators, your own code) know what to look for. Do not assume the API server guarantees both keys are present; consumers should handle a missing key gracefully.

### kubernetes.io/ssh-auth

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: git-deploy-key
type: kubernetes.io/ssh-auth
stringData:
  ssh-privatekey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
```

The `ssh-privatekey` key is required. Two operational notes:

- SSH clients refuse private keys with loose permissions. Mount with `defaultMode: 0400` and make sure the container's UID owns the file.
- This type does not carry `known_hosts`. Ship host key verification data separately (often a ConfigMap), and never disable host key checking to work around it.

### kubernetes.io/tls

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: web-tls
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t...
```

The keys `tls.crt` and `tls.key` are required for this type, and their absence is rejected. The values must be PEM encoded, and `tls.crt` should contain the full chain (leaf first, then intermediates) because most servers and Ingress controllers serve exactly what is in that file.

This is the type Ingress resources reference:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
spec:
  tls:
  - hosts: ["www.example.com"]
    secretName: web-tls
  rules:
  - host: www.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port: {number: 80}
```

A `ca.crt` key is commonly added by convention when clients need to verify a private CA. That extra key is allowed alongside the two required ones.

### bootstrap.kubernetes.io/token

Used during node bootstrap (`kubeadm join`) so that a new kubelet can authenticate well enough to request a client certificate.

```yaml
apiVersion: v1
kind: Secret
metadata:
  # name MUST be bootstrap-token-<token-id>
  name: bootstrap-token-07401b
  namespace: kube-system          # MUST be kube-system
type: bootstrap.kubernetes.io/token
stringData:
  token-id: "07401b"                        # 6 characters, [a-z0-9]
  token-secret: "f395accd246ae52d"          # 16 characters, [a-z0-9]
  expiration: "2026-09-06T03:22:11Z"        # RFC3339
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: "system:bootstrappers:kubeadm:default-node-token"
  description: "kubeadm join token for worker nodes"
```

Three hard requirements: the namespace must be `kube-system`, the name must be `bootstrap-token-<token-id>`, and `token-id` must match the name suffix. The full token presented to `kubeadm join` is `<token-id>.<token-secret>`.

```bash
kubeadm token list
kubeadm token create --ttl 2h --print-join-command
kubeadm token delete 07401b
```

Always set a short `expiration`. A bootstrap token that lets an attacker join a node to your cluster is a serious finding.

> 📖 **See Also**: [Manual Kubernetes Cluster Install](manual-install-k8s-cluster.md) for where these tokens appear in practice.

---

## Creating Secrets

### kubectl create secret generic

```bash
# from literals
kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password='s3cr3tP@ss'

# from files: key defaults to the base name
kubectl create secret generic tls-bundle \
  --from-file=ca.crt \
  --from-file=client.crt \
  --from-file=client.key

# from a file with a custom key
kubectl create secret generic db-credentials \
  --from-file=password=./secrets/db_password.txt

# from a directory: one key per file, no recursion
kubectl create secret generic certs --from-file=./certs/

# from an env file: one key per line
kubectl create secret generic app-secrets --from-env-file=./secrets/app.env

# specify a custom type
kubectl create secret generic my-creds \
  --type=example.com/custom \
  --from-literal=token=abc123
```

The `--from-*` flags behave exactly as they do for `kubectl create configmap`, including the directory rules and the `--from-file` versus `--from-env-file` distinction. See [ConfigMaps](configmaps.md#creating-configmaps-every-method).

### The Shell History Problem

```bash
kubectl create secret generic db --from-literal=password='s3cr3tP@ss'
#                                                       ^^^^^^^^^^^^
#            now in ~/.bash_history, in your terminal scrollback, and
#            possibly in your shell's remote sync
```

Safer patterns:

```bash
# 1. read from a file, then shred it
printf '%s' "$PASSWORD" > /dev/shm/pw
kubectl create secret generic db --from-file=password=/dev/shm/pw
shred -u /dev/shm/pw

# 2. leading space to skip history (requires HISTCONTROL=ignorespace)
 kubectl create secret generic db --from-literal=password='s3cr3tP@ss'

# 3. prompt without echo, never touching argv
read -rsp 'Password: ' PW; echo
kubectl create secret generic db --from-literal=password="$PW"
unset PW
```

Even option 3 puts the value in the process argument list, visible in `ps` to other users on the same machine for the lifetime of the command. Option 1 is the only one that avoids argv entirely. In automation, do not use `kubectl create secret` at all: use a secret manager integration.

### kubectl create secret docker-registry

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=deploy-bot \
  --docker-password="$REGISTRY_TOKEN" \
  --docker-email=deploy@example.com
```

Or from an existing Docker config file, which avoids putting the password on the command line:

```bash
kubectl create secret generic regcred \
  --from-file=.dockerconfigjson=$HOME/.docker/config.json \
  --type=kubernetes.io/dockerconfigjson
```

Verify what you produced:

```bash
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq
```

Note the escaped `\.` in the JSONPath: the key literally begins with a dot.

### kubectl create secret tls

```bash
kubectl create secret tls web-tls \
  --cert=./fullchain.pem \
  --key=./privkey.pem
```

`--cert` should be the **full chain**, not just the leaf. A missing intermediate produces a certificate that validates in a browser (which caches intermediates) and fails in `curl`, Java and Go clients, which is a memorably confusing incident.

Inspect what you loaded before trusting it:

```bash
kubectl get secret web-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates

# count the certificates in the chain
kubectl get secret web-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | grep -c 'BEGIN CERTIFICATE'

# confirm the key matches the certificate (the two hashes must be identical)
kubectl get secret web-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -modulus | openssl md5
kubectl get secret web-tls -o jsonpath='{.data.tls\.key}' | base64 -d \
  | openssl rsa -noout -modulus | openssl md5
```

### Declaratively

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: production
type: Opaque
stringData:
  DB_PASSWORD: "s3cr3tP@ss"
  API_KEY: "ak_live_4f8a9b2c1d3e"
```

**Do not commit this file with real values.** Declarative Secrets are correct as a shape; the values must come from somewhere else at apply time. Legitimate patterns:

| Pattern | Mechanism |
|---------|-----------|
| Sealed Secrets | Commit an encrypted `SealedSecret`; a controller decrypts into a `Secret` in cluster |
| External Secrets Operator | Commit an `ExternalSecret` that names a key in AWS/GCP/Azure/Vault; the operator materialises the `Secret` |
| Secrets Store CSI Driver | Commit a `SecretProviderClass`; the driver mounts values directly into the Pod |
| CI injection | The pipeline substitutes values from its own secret store immediately before `kubectl apply` |
| Vault agent injection | Annotations on the Pod cause a sidecar to render secrets into a shared in memory volume |

### The Generate and Inspect Pattern

```bash
kubectl create secret generic app-secrets \
  --from-literal=API_KEY=placeholder \
  --dry-run=client -o yaml
```

Useful for producing the right shape to template, and for confirming which keys a given `--from-*` combination produces before you run it for real.

### Immutable Secrets

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets-v7
type: Opaque
immutable: true
stringData:
  API_KEY: "ak_live_4f8a9b2c1d3e"
```

Same rationale as ConfigMaps: the kubelet can stop watching an object that can never change, which is a real saving in large clusters. It also forces the versioned name workflow, which for credentials is a feature, because rotation then becomes an explicit, reviewable, rollback-able Pod template change rather than an in place edit that silently diverges from running Pods.

---

## Reading and Decoding Secrets

```bash
# list
kubectl get secrets
kubectl get secrets -A

# describe: values are NEVER shown, only byte counts
kubectl describe secret db-credentials
```

```
Name:         db-credentials
Namespace:    production
Labels:       <none>
Annotations:  <none>

Type:  Opaque

Data
====
password:  10 bytes
username:  5 bytes
```

That byte count is diagnostically useful on its own: a password you expect to be 10 characters showing as 11 bytes means you encoded a trailing newline.

### Decoding a Single Key

```bash
kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d
```

Add a newline for readability without corrupting the comparison:

```bash
kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d; echo
```

Keys containing dots must be escaped:

```bash
kubectl get secret web-tls -o jsonpath='{.data.tls\.crt}' | base64 -d
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

### Decoding Every Key

```bash
# with jq
kubectl get secret db-credentials -o json \
  | jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"'
```

```
password=s3cr3tP@ss
username=admin
```

```bash
# pure kubectl, using go-template
kubectl get secret db-credentials -o go-template='
{{- range $k, $v := .data }}{{ $k }}={{ $v | base64decode }}
{{ end }}'
```

Recent `kubectl` versions also offer a convenience subcommand:

```bash
kubectl get secret db-credentials -o yaml
kubectl view-secret db-credentials       # if the krew plugin is installed
```

### Extracting Files

```bash
kubectl get secret web-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > tls.crt
kubectl get secret web-tls -o jsonpath='{.data.tls\.key}' | base64 -d > tls.key
chmod 600 tls.key
```

### Hygiene When Decoding

Decoding a Secret writes a credential to your terminal, your scrollback, and possibly your shell history and any terminal recording or screen sharing session in progress.

```
┌────────────────────────────────────────────────────────────────────┐
│               Where a Decoded Secret Ends Up                        │
├────────────────────────────────────────────────────────────────────┤
│  • terminal scrollback buffer                                       │
│  • tmux/screen session history and any saved pane dumps             │
│  • shell history (the kubectl command, not the value, but the       │
│    command tells an attacker exactly what to run)                   │
│  • CI job logs, if you do this in a pipeline                        │
│  • the audit log: your read is recorded, which is a feature         │
│  • a screen recording or shared screen                              │
│  • your clipboard, if you copy it                                   │
└────────────────────────────────────────────────────────────────────┘
```

Prefer piping directly into the consumer rather than printing:

```bash
# ✅ never rendered on screen
kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d \
  | psql "postgresql://admin@db:5432/appdb"
```

---

## Consuming Secrets: Environment Variables

### Single Key With secretKeyRef

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-secret
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: password
          optional: false
    - name: DB_USER
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: username
```

The kubelet base64 **decodes** the value before setting it. The container sees plaintext; you never decode inside the application.

### All Keys With envFrom

```yaml
    envFrom:
    - secretRef:
        name: app-secrets
    - secretRef:
        name: optional-secrets
        optional: true
      prefix: EXT_
```

Same rules as ConfigMaps: keys that are not valid environment variable names are silently dropped with an `InvalidEnvironmentVariableNames` event, `env` entries beat `envFrom`, and later `envFrom` sources beat earlier ones.

This is a particularly bad idea for Secrets specifically, because `envFrom` gives you no control over which credentials enter the process environment. A Secret with six keys puts all six in the environment even if the application needs one.

### Values Are Frozen

Exactly as with ConfigMaps: environment variables are set at `execve()` time and never change. **Rotating a Secret has no effect on any running Pod that consumes it as an environment variable, silently.** This alone disqualifies environment variables for any credential you intend to rotate.

---

## Consuming Secrets: Volume Mounts

### Whole Secret as a Volume

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vol-secret
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: creds
      mountPath: /etc/creds
      readOnly: true
  volumes:
  - name: creds
    secret:
      secretName: db-credentials      # NOTE: secretName, not name
      defaultMode: 0400
```

**The field is `secretName`, not `name`.** A `configMap` volume uses `name`; a `secret` volume uses `secretName`. This asymmetry is a historical wart and a reliable source of validation errors.

```bash
$ kubectl exec vol-secret -- ls -l /etc/creds
total 0
lrwxrwxrwx 1 root root 15 Sep  5 10:12 password -> ..data/password
lrwxrwxrwx 1 root root 15 Sep  5 10:12 username -> ..data/username

$ kubectl exec vol-secret -- cat /etc/creds/password
s3cr3tP@ss
```

Values are stored base64 in the API and written **decoded** into the file. The application reads plaintext.

### Selective Projection With items

```yaml
  volumes:
  - name: creds
    secret:
      secretName: app-secrets
      defaultMode: 0400
      items:
      - key: tls.key
        path: certs/server.key
        mode: 0400
      - key: tls.crt
        path: certs/server.crt
        mode: 0444
      optional: false
```

As with ConfigMaps: if `items` is present, only the listed keys are projected, `path` may contain `/` to build subdirectories, and `mode` overrides `defaultMode` per file.

### File Permissions Matter More Here

```
┌─────────────────────────────────────────────────────────────────────┐
│                    defaultMode for Secrets                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  0644 (default)  rw-r--r--   every process in the container, and     │
│                              every sidecar sharing the mount, can    │
│                              read it. Too permissive for keys.       │
│                                                                      │
│  0440            r--r-----   owner and group only                    │
│                                                                      │
│  0400            r--------   owner only. The right default for       │
│                              private keys. SSH and some TLS          │
│                              libraries REFUSE looser modes.          │
│                                                                      │
│  ⚠️  Write it in octal with a leading zero. `defaultMode: 400` is    │
│     decimal 400 = octal 0620, which is not what you meant.           │
│                                                                      │
│  ⚠️  The file OWNER is decided by the kubelet, not by your           │
│     container's UID. If a non root container cannot read a 0400      │
│     file, set spec.securityContext.fsGroup so the group matches,     │
│     and use 0440.                                                    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Diagnosing a permission problem:

```bash
kubectl exec POD -- id
kubectl exec POD -- ls -l /etc/creds/..data/
kubectl exec POD -- stat -c '%n %U:%G %a' /etc/creds/..data/password
```

---

## Why Volumes Beat Environment Variables

```
╔══════════════════════════════════════════════════════════════════════╗
║   For anything genuinely sensitive, mount it as a volume.            ║
╚══════════════════════════════════════════════════════════════════════╝
```

### 1. Environment Variables Are Inherited by Every Child Process

```
┌────────────────────────────────────────────────────────────────────┐
│                    Environment Inheritance                          │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   PID 1: /app/server   DB_PASSWORD=s3cr3tP@ss                      │
│      │                                                              │
│      ├── fork/exec: /usr/bin/curl        inherits DB_PASSWORD       │
│      ├── fork/exec: a shell hook script  inherits DB_PASSWORD       │
│      ├── fork/exec: an image scanner     inherits DB_PASSWORD       │
│      └── fork/exec: ANY subprocess       inherits DB_PASSWORD       │
│                                                                     │
│   Every one of those can log, print, or transmit it. A single       │
│   `env`-dumping debug helper leaks the whole set at once.           │
│                                                                     │
│   A FILE is read only by code that explicitly opens that path.      │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### 2. Environment Variables Appear in Crash Dumps and Diagnostics

`/proc/<pid>/environ` is readable by anything running as the same UID inside the container. Core dumps embed the environment block. Many language runtimes print the full environment in an unhandled exception handler, and many observability agents capture process environments as metadata.

### 3. Environment Variables Are Visible in the Pod Spec

```bash
kubectl describe pod myapp
```

For a `secretKeyRef` the output shows the reference, not the value, which is fine:

```
    Environment:
      DB_PASSWORD:  <set to the key 'password' in secret 'db-credentials'>  Optional: false
```

But a hardcoded `value:` shows in full, and **anyone with `get pods` can read it**, without needing `get secrets` at all:

```yaml
    env:
    - name: DB_PASSWORD
      value: "s3cr3tP@ss"        # ❌ visible to everyone with `get pods`
```

This is the most common accidental credential exposure in Kubernetes.

### 4. Environment Variables Never Rotate

Files are refreshed by the kubelet. Environment variables are frozen at container start. Any rotation strategy that does not involve restarting Pods is incompatible with environment variables.

### 5. Volumes Are tmpfs Backed

See the next section. Environment variables live wherever the container runtime's process state lives; secret volume contents are explicitly kept off node disk.

### The Honest Counterargument

Environment variables are ubiquitous. A great deal of software, and most twelve factor tooling, reads config exclusively from the environment. When that is your situation:

| Mitigation | How |
|-----------|-----|
| Prefer `secretKeyRef` over `envFrom` | Inject only what that container needs |
| Never use a literal `value:` for a credential | Always `valueFrom` |
| Use an entrypoint shim | Read files into environment variables inside the process just before `exec`, so the value never appears in the Pod spec at all |
| Restrict `get pods` and `pods/exec` | Both give access to the environment |
| Scrub logs | Ensure your logging framework never dumps the environment |

The entrypoint shim pattern:

```yaml
    command: ["/bin/sh", "-c"]
    args:
    - |
      set -eu
      export DB_PASSWORD="$(cat /etc/creds/password)"
      exec /app/server
    volumeMounts:
    - name: creds
      mountPath: /etc/creds
      readOnly: true
```

The credential is in the environment of the application process only, is not in the Pod spec, is not visible to `kubectl describe pod`, and can be re-read on restart without changing any manifest.

---

## Image Pull Secrets

Private registries need credentials before the kubelet can pull an image. This happens before any container exists, so it cannot use a volume.

### On the Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: private-app
spec:
  imagePullSecrets:
  - name: regcred
  - name: backup-regcred        # a list; all are tried
  containers:
  - name: app
    image: registry.example.com/team/app:1.4.2
```

### On the ServiceAccount (Better)

Attach the pull secret once to the ServiceAccount, and every Pod using that ServiceAccount inherits it without touching a single Deployment manifest.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: production
imagePullSecrets:
- name: regcred
```

```bash
kubectl patch serviceaccount default -n production \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

```
┌────────────────────────────────────────────────────────────────────┐
│                 imagePullSecrets Resolution                         │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. Admission merges the ServiceAccount's imagePullSecrets into     │
│     the Pod spec at creation time.                                  │
│                                                                     │
│  2. The final Pod spec therefore contains BOTH the Pod's own list   │
│     and the ServiceAccount's list.                                  │
│                                                                     │
│  3. The kubelet tries each referenced Secret when authenticating    │
│     to the registry for that image.                                 │
│                                                                     │
│  ⚠️  The merge happens at Pod CREATION. Adding a pull secret to a   │
│     ServiceAccount does NOT affect Pods that already exist.         │
│     Recreate them.                                                  │
│                                                                     │
│  ⚠️  The Secret must be in the SAME NAMESPACE as the Pod. Registry  │
│     credentials must be replicated to every namespace that pulls.   │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Verify the merge happened:

```bash
kubectl get pod private-app -o jsonpath='{.spec.imagePullSecrets}' | jq
```

Diagnosing `ImagePullBackOff` on a private registry:

```bash
kubectl describe pod private-app | grep -A5 Events
```

| Message | Meaning |
|---------|---------|
| `pull access denied` / `unauthorized` | Credentials wrong, missing, or in the wrong namespace |
| `no basic auth credentials` | No `imagePullSecrets` reached the Pod at all |
| `manifest unknown` | Auth succeeded; the tag does not exist |
| `x509: certificate signed by unknown authority` | Registry CA not trusted by the node, not a Secret problem |

Confirm the credential itself is valid, independently of Kubernetes:

```bash
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths | keys[]'
# the server key must match the registry host in your image reference EXACTLY,
# including port. registry.example.com and registry.example.com:443 are
# different keys as far as the kubelet is concerned.
```

---

## Update Behaviour and tmpfs Backing

### tmpfs

On Linux nodes, a `secret` volume is mounted as **tmpfs**, a RAM backed filesystem.

```bash
$ kubectl exec vol-secret -- mount | grep /etc/creds
tmpfs on /etc/creds type tmpfs (ro,relatime)

$ kubectl exec vol-secret -- df -h /etc/creds
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           7.8G  4.0K  7.8G   1% /etc/creds
```

Why this matters:

```
┌────────────────────────────────────────────────────────────────────┐
│                    tmpfs Consequences                               │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ✅ Contents never touch the node's persistent storage. Pulling     │
│     the disk out of a node does not yield the secret.               │
│                                                                     │
│  ✅ Deleting the Pod destroys the memory; nothing to shred.         │
│                                                                     │
│  ⚠️  tmpfs pages CAN be swapped to disk if the node has swap        │
│     enabled. Historically kubelet refused to start with swap on,    │
│     and swap support is now configurable. If you enable swap,       │
│     understand that you have weakened this guarantee.               │
│                                                                     │
│  ⚠️  tmpfs consumes node memory. Enormous numbers of secret         │
│     volumes on one node is a memory consideration.                  │
│                                                                     │
│  ⚠️  On Windows nodes the tmpfs guarantee does not apply; the       │
│     storage mechanism differs.                                      │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### Update Semantics

Identical to ConfigMaps, and worth restating because rotation depends on it:

| Method | Refreshes on Secret update? |
|--------|----------------------------|
| `secretKeyRef` env var | ❌ never |
| `secretRef` in `envFrom` | ❌ never |
| `secret` volume | ✅ eventually, kubelet sync period plus cache propagation delay |
| `projected` volume, `secret` source | ✅ eventually |
| volume mounted with `subPath` | ❌ never |
| `imagePullSecrets` | applied at pull time; a running container is unaffected |
| `immutable: true` | cannot change at all |

The kubelet uses the same `..data` symlink and atomic `rename(2)` swap described in [ConfigMaps](configmaps.md#inside-the-mounted-directory). All keys in a Secret update together, which is exactly what you need for a certificate and key pair: you will never observe a new `tls.crt` beside an old `tls.key`.

**But the application still has to notice.** A refreshed file changes nothing for a server that loaded its certificate into memory at startup. Either the application supports reload (nginx `-s reload`, Envoy SDS, a Go server with a `GetCertificate` callback that re-reads on each handshake), or you roll the Pods.

---

## Encryption at Rest

By default, `kube-apiserver` writes Secret values to etcd **unencrypted**. Anyone with an etcd backup, a snapshot, a stolen disk, or direct etcd access reads every secret in the cluster in plaintext.

```
┌─────────────────────────────────────────────────────────────────────┐
│                   Without Encryption at Rest                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   kubectl ──TLS──► kube-apiserver ──TLS──► etcd                     │
│                                             │                        │
│                                             └─► /var/lib/etcd/       │
│                                                 member/snap/db       │
│                                                                      │
│                                                 contains:            │
│                                                 password=s3cr3tP@ss  │
│                                                 in PLAINTEXT         │
│                                                                      │
│   TLS protects the wire. Nothing protects the disk.                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

> 📖 **See Also**: [etcd](etcd.md) for backup, restore and access control on the datastore itself.

### The EncryptionConfiguration Object

```yaml
# /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  - configmaps                       # optional, ConfigMaps often hold sensitive-ish data
  providers:
  # ORDER MATTERS: the FIRST provider is used to ENCRYPT new writes.
  # ALL listed providers are tried, in order, to DECRYPT reads.
  - aescbc:
      keys:
      - name: key2                   # newest key first, so it is used for writes
        secret: c2VjcmV0IGlzIHNlY3VyZSwgb3IgaXMgaXQ/Cg==
      - name: key1                   # kept so previously written data still decrypts
        secret: dGhpcyBpcyBwYXNzd29yZAo=
  - identity: {}                     # LAST: allows reading data written before
                                     # encryption was enabled
```

### The Providers

| Provider | Key size | Notes |
|----------|----------|-------|
| `identity` | none | **No encryption.** Plaintext. Placing it first disables encryption for that resource. |
| `secretbox` | 32 bytes | XSalsa20 and Poly1305. Fast, strong, authenticated. |
| `aesgcm` | 16, 24 or 32 bytes | AES-GCM with a random nonce. Fast, but **the key must be rotated frequently** because nonce reuse under a single key breaks the security of GCM. The documentation states it must be rotated every 200,000 writes. Not recommended unless you have automated rotation. |
| `aescbc` | 32 bytes | AES-CBC with PKCS#7 padding. Widely used; note that CBC is unauthenticated at this layer. |
| `kms` | external | Envelope encryption: the API server generates a data encryption key per object and asks an external KMS to wrap it with a key encryption key that never leaves the KMS. |

### Generating a Key

```bash
head -c 32 /dev/urandom | base64
# 8Wo4RRoIVOEV+CQ2j4LmYUX0h5hGvJ+FzYqOe7Mrz2s=
```

For `aesgcm` with a 16 byte key, use `head -c 16`. Always use `/dev/urandom`, never a password or a passphrase derived string.

The key file is now the most sensitive file in your cluster:

```bash
sudo mkdir -p /etc/kubernetes/enc
sudo install -m 0600 -o root -g root encryption-config.yaml /etc/kubernetes/enc/
```

```
┌────────────────────────────────────────────────────────────────────┐
│              The Local Key File Problem                             │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  With aescbc/aesgcm/secretbox, the key sits on the SAME MACHINE     │
│  as the API server, which usually sits next to etcd.                │
│                                                                     │
│  This defends against:                                              │
│    ✅ a stolen etcd snapshot or backup tarball                      │
│    ✅ a stolen or improperly decommissioned disk                    │
│    ✅ an operator with read access to etcd but not to the           │
│       control plane filesystem                                      │
│                                                                     │
│  It does NOT defend against:                                        │
│    ❌ full compromise of a control plane node (key and data both    │
│       present)                                                      │
│                                                                     │
│  For separation of key material from data, use the kms provider.    │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### Wiring It Into the API Server

Add the flag and mount the file. On a kubeadm cluster, edit the static Pod manifest:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml
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
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
    - --encryption-provider-config-automatic-reload=true
    # ... all existing flags ...
    volumeMounts:
    - name: enc
      mountPath: /etc/kubernetes/enc
      readOnly: true
  volumes:
  - name: enc
    hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
```

Editing the static Pod manifest causes the kubelet to restart the API server automatically.

```
┌────────────────────────────────────────────────────────────────────┐
│                 HA Control Plane Requirement                        │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  EVERY kube-apiserver instance must have the SAME configuration     │
│  and the SAME keys. If apiserver-1 encrypts with key2 and           │
│  apiserver-2 does not have key2, reads served by apiserver-2 fail.  │
│                                                                     │
│  Roll the change out to all control plane nodes before relying      │
│  on it, and verify each one individually.                           │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Confirm the API server came back:

```bash
sudo crictl ps | grep kube-apiserver
kubectl -n kube-system get pod -l component=kube-apiserver
kubectl get --raw='/readyz?verbose'
```

If the API server refuses to start, the most common causes are a malformed YAML config, a key that is not valid base64, a key of the wrong length, or the `hostPath` not being mounted. Read the container logs directly, since `kubectl` will not work:

```bash
sudo crictl logs "$(sudo crictl ps -a --name kube-apiserver -q | head -1)" 2>&1 | tail -40
```

### The Mandatory Rewrite Step

```
╔══════════════════════════════════════════════════════════════════════╗
║  Enabling encryption only affects NEW WRITES.                        ║
║  Every Secret already in etcd stays in plaintext until it is         ║
║  written again. You MUST rewrite them.                               ║
╚══════════════════════════════════════════════════════════════════════╝
```

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

That one line reads every Secret and writes it back unchanged, which forces the API server to re encrypt it with the current first provider.

Notes on running it:

- It is idempotent and safe to repeat.
- It updates `resourceVersion` on every Secret, which will wake up every controller watching Secrets. On a large cluster, do it during a quiet period.
- It needs cluster wide read and update on secrets.
- Run it again after **every key rotation**, otherwise old data stays encrypted with the old key and you can never retire that key.

If you also encrypt ConfigMaps, rewrite those too:

```bash
kubectl get configmaps --all-namespaces -o json | kubectl replace -f -
```

### Key Rotation Procedure

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Rotating an Encryption Key                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  STEP 1: generate the new key                                        │
│      head -c 32 /dev/urandom | base64                                │
│                                                                      │
│  STEP 2: add it SECOND in the list, on every apiserver               │
│      providers:                                                      │
│      - aescbc:                                                       │
│          keys:                                                       │
│          - name: key1        ← still first: still used for writes    │
│            secret: OLD                                               │
│          - name: key2        ← second: only used for decryption      │
│            secret: NEW                                               │
│      Wait until every apiserver has reloaded. Now all of them can    │
│      DECRYPT with key2, but none writes with it yet.                 │
│                                                                      │
│  STEP 3: promote the new key to FIRST, on every apiserver            │
│          - name: key2        ← now used for writes                   │
│            secret: NEW                                               │
│          - name: key1        ← retained for decryption               │
│            secret: OLD                                               │
│                                                                      │
│  STEP 4: rewrite everything with the new key                         │
│      kubectl get secrets -A -o json | kubectl replace -f -           │
│                                                                      │
│  STEP 5: verify nothing is still encrypted with key1, then remove    │
│          key1 from the config on every apiserver, and destroy it.    │
│                                                                      │
│  Skipping STEP 2 breaks reads on any apiserver that has not yet      │
│  learned the new key. Skipping STEP 4 makes STEP 5 destroy data.     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### The KMS Provider

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - kms:
      apiVersion: v2
      name: myKmsProvider
      endpoint: unix:///var/run/kmsplugin/socket.sock
      timeout: 3s
  - identity: {}
```

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Envelope Encryption with KMS                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Secret ──► kube-apiserver                                          │
│                   │                                                  │
│                   │ 1. generate a local Data Encryption Key (DEK)    │
│                   │ 2. encrypt the Secret with the DEK               │
│                   │                                                  │
│                   ├──── gRPC over a unix socket ────►  KMS plugin    │
│                   │                                         │        │
│                   │     3. plugin asks the external KMS to   │        │
│                   │        wrap the DEK with the KEK         ▼        │
│                   │                                    ┌──────────┐  │
│                   │◄──── wrapped DEK ──────────────────│ Cloud KMS│  │
│                   │                                    │ or HSM   │  │
│                   │                                    │  (KEK    │  │
│                   │ 4. store ciphertext + wrapped DEK  │  never   │  │
│                   ▼    in etcd                         │  leaves) │  │
│                 etcd                                   └──────────┘  │
│                                                                      │
│   The Key Encryption Key NEVER exists on the control plane node.     │
│   Compromising the node yields ciphertext and wrapped DEKs only.     │
│   KEK rotation happens in the KMS, without touching Kubernetes.      │
│   Every unwrap is logged by the KMS, giving you an external audit.   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Trade offs to plan for:

- **The KMS is now on the critical path.** If the plugin or the external KMS is unavailable, the API server may be unable to decrypt Secrets. Health check the plugin and understand your provider's caching behaviour.
- **Latency.** Every uncached unwrap is a network call.
- **Managed Kubernetes offerings** typically expose this as a one line cluster setting rather than a hand written EncryptionConfiguration.

---

## Verifying Encryption With etcdctl

Trust nothing; verify from etcd directly.

```bash
# Create a canary
kubectl create secret generic enc-canary -n default \
  --from-literal=canary=IF_YOU_CAN_READ_THIS_IT_IS_NOT_ENCRYPTED
```

On a control plane node:

```bash
export ETCDCTL_API=3

sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/enc-canary | hexdump -C | head -20
```

**Encrypted output:**

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 64 65 66 61 75 6c  74 2f 65 6e 63 2d 63 61  |s/default/enc-ca|
00000020  6e 61 72 79 0a 6b 38 73  3a 65 6e 63 3a 61 65 73  |nary.k8s:enc:aes|
00000030  63 62 63 3a 76 31 3a 6b  65 79 32 3a 8f 2b 91 c4  |cbc:v1:key2:.+..|
00000040  7e 3a 05 dd 11 6f 8c 29  b3 a1 4d 5e 02 f7 6b 88  |~:...o.)..M^..k.|
...
```

The marker to look for is the prefix, which encodes provider and key name:

```
k8s:enc:aescbc:v1:key2:      ← aescbc provider, key named key2
k8s:enc:secretbox:v1:key1:   ← secretbox provider
k8s:enc:kms:v2:myKmsProvider ← kms v2 provider
```

Everything after the prefix is ciphertext, and `IF_YOU_CAN_READ_THIS` appears nowhere.

**Unencrypted output** looks like this instead:

```
00000030  6b 38 73 00 0a 0c 0a 02  76 31 12 06 53 65 63 72  |k8s.....v1..Secr|
...
000000d0  63 61 6e 61 72 79 12 28  49 46 5f 59 4f 55 5f 43  |canary.(IF_YOU_C|
000000e0  41 4e 5f 52 45 41 44 5f  54 48 49 53 5f 49 54 5f  |AN_READ_THIS_IT_|
```

The value is right there in the ASCII column. That is what an attacker with your etcd backup sees.

### Auditing Every Secret

```bash
#!/usr/bin/env bash
# Report which secrets are still stored in plaintext.
set -euo pipefail

ETCD="sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

$ETCD get /registry/secrets/ --prefix --keys-only | grep -v '^$' | while read -r key; do
  if $ETCD get "$key" | grep -qa 'k8s:enc:'; then
    printf 'ENCRYPTED  %s\n' "$key"
  else
    printf 'PLAINTEXT  %s\n' "$key"
  fi
done
```

Any `PLAINTEXT` line after you enabled encryption means the rewrite step did not cover it. Run `kubectl get secrets -A -o json | kubectl replace -f -` again.

### Confirming the API Server Can Still Read Everything

```bash
kubectl get secrets -A -o name | while read -r s; do
  ns=${s%%/*}; kubectl get "$s" >/dev/null || echo "UNREADABLE: $s"
done
```

If anything is unreadable, a key that was used for a write is missing from the provider list. Do not proceed with removing keys.

---

## RBAC Hygiene for Secrets

### The Rule Everyone Forgets

```
╔══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║   ANYONE WHO CAN CREATE A POD IN A NAMESPACE CAN READ EVERY           ║
║   SECRET IN THAT NAMESPACE.                                           ║
║                                                                       ║
║   They do not need `get secrets`. They write a Pod that mounts        ║
║   the Secret and prints it:                                           ║
║                                                                       ║
║     spec:                                                             ║
║       containers:                                                     ║
║       - name: exfil                                                   ║
║         image: busybox                                                ║
║         command: ["sh","-c","cat /s/* ; sleep 1"]                     ║
║         volumeMounts: [{name: s, mountPath: /s}]                      ║
║       volumes:                                                        ║
║       - name: s                                                       ║
║         secret: {secretName: db-credentials}                          ║
║                                                                       ║
║   Then: kubectl logs exfil                                            ║
║                                                                       ║
║   Granting `create pods` is equivalent to granting `get secrets`      ║
║   for that namespace. Treat them as the same privilege.               ║
║                                                                       ║
╚══════════════════════════════════════════════════════════════════════╝
```

Corollaries:

- `create deployments`, `create jobs`, `create cronjobs`, `create daemonsets`, `create statefulsets` and `create replicasets` all imply the ability to create Pods, and therefore imply secret read.
- `pods/exec` and `pods/attach` let you read anything a running Pod can read, including its mounted secrets and its environment.
- `pods/log` reads whatever the application printed, which is why logging a credential is permanently damaging.
- **Namespace boundaries are the real security boundary for Secrets.** If two workloads must not read each other's credentials, they must be in different namespaces.

### Least Privilege Roles

```yaml
# Read only, and only for the two secrets this component needs.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-secret-reader
  namespace: production
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["db-credentials", "api-keys"]
  verbs: ["get"]
```

```
┌────────────────────────────────────────────────────────────────────┐
│                   resourceNames Limitations                         │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  resourceNames restricts verbs that address ONE named object:       │
│      get, update, patch, delete                                     │
│                                                                     │
│  resourceNames CANNOT restrict:                                     │
│      list, watch, create, deletecollection                          │
│                                                                     │
│  Consequence: you cannot grant "list only these two secrets".       │
│  Granting `list` on secrets grants the ability to enumerate and,    │
│  because list responses include object data, to READ ALL OF THEM.   │
│                                                                     │
│  `list secrets` is effectively `read every secret in scope`.        │
│  Never grant it casually, and never grant it cluster wide.          │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### Audit Who Can Read Secrets

```bash
# does a specific subject have access?
kubectl auth can-i get secrets --as=system:serviceaccount:production:myapp -n production
kubectl auth can-i list secrets --as=jane@example.com -n production
kubectl auth can-i create pods --as=jane@example.com -n production   # equivalent power

# what can a ServiceAccount do?
kubectl auth can-i --list --as=system:serviceaccount:production:myapp -n production

# find every binding that grants secret access
kubectl get clusterroles -o json | jq -r '
  .items[]
  | select(.rules[]? | (.resources[]? == "secrets" or .resources[]? == "*")
                    and (.verbs[]? == "get" or .verbs[]? == "list" or .verbs[]? == "*"))
  | .metadata.name'
```

### Audit Policy for Secret Access

```yaml
# /etc/kubernetes/audit-policy.yaml (excerpt)
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# Record metadata for every secret access, but NEVER the body,
# otherwise the audit log itself becomes a credential store.
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets", "configmaps"]

# Do not log request/response bodies for these, ever.
- level: None
  resources:
  - group: ""
    resources: ["secrets"]
  verbs: ["get", "list", "watch"]
  users: ["system:kube-controller-manager"]
```

`level: Metadata` is the correct level for Secrets. `RequestResponse` would write the secret values into the audit log in plaintext, which is a spectacular own goal.

### The Node Authorizer

The kubelet on each node is restricted by the **Node authorizer** plus the **NodeRestriction** admission plugin so that it may only read Secrets referenced by Pods scheduled to that node. This is what limits blast radius when a single node is compromised: the attacker gets the secrets used on that node, not the whole cluster.

```bash
# confirm the plugins are enabled
ps aux | grep kube-apiserver | tr ',' '\n' | grep -E 'authorization-mode|enable-admission-plugins'
# expect: --authorization-mode=Node,RBAC
#         --enable-admission-plugins=...,NodeRestriction,...
```

> 📖 **See Also**: [kube-apiserver](kube-apiserver.md) and [Worker Node](worker-node.md).

### Other Hygiene

```yaml
# Turn off the automatic API token mount for workloads that do not
# talk to the API server. This removes a credential from the container
# for free.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myapp
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: myapp
spec:
  serviceAccountName: myapp
  automountServiceAccountToken: false      # Pod level overrides the SA level
```

Additional controls worth having:

- **Admission policy** to reject Pods with a literal `value:` on env vars whose name matches `PASSWORD|TOKEN|SECRET|KEY`.
- **A pre commit hook and CI scanner** that rejects credentials in Git.
- **A `ResourceQuota` on secrets** per namespace, which limits the damage of a runaway controller creating secrets in a loop.
- **Alerting on `list secrets` by unexpected subjects** in the audit log.

---

## Service Account Tokens

### The Legacy Model

Historically, every ServiceAccount got an auto created Secret of type `kubernetes.io/service-account-token` containing a JWT that:

- never expired,
- was valid until the Secret was deleted,
- was not bound to any Pod, so it kept working after the Pod was gone,
- was not bound to any audience, so it was replayable against anything trusting the cluster's issuer.

A single leaked token was therefore a permanent credential. Modern Kubernetes no longer auto creates these Secrets for ServiceAccounts.

### The Modern Model: Bound, Projected Tokens

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: modern-token
spec:
  serviceAccountName: myapp
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: api-token
      mountPath: /var/run/secrets/tokens
      readOnly: true
  volumes:
  - name: api-token
    projected:
      sources:
      - serviceAccountToken:
          path: token
          audience: vault.example.com     # who this token is FOR
          expirationSeconds: 3600         # minimum accepted is 600
```

```
┌─────────────────────────────────────────────────────────────────────┐
│                Legacy Token vs Bound Token                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  LEGACY (Secret)              │  BOUND (projected volume)            │
│  ─────────────────────────────┼───────────────────────────────────── │
│  never expires                │  expires; kubelet refreshes it       │
│  stored in etcd forever       │  not stored as a Secret at all       │
│  valid after Pod deletion     │  invalidated when the Pod is gone    │
│  any audience                 │  scoped to a named audience          │
│  readable by anyone with      │  only present inside the Pod         │
│    get secrets                │                                      │
│  no automatic rotation        │  kubelet rotates before expiry       │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

The kubelet requests the token from the API server's TokenRequest endpoint, writes it into the volume, and **re requests it before it expires**, replacing the file via the usual atomic swap. The token's claims bind it to the Pod's UID and to the ServiceAccount, so the API server rejects it once the Pod no longer exists.

**Your client must re-read the token file.** A client that reads the token once at startup and caches it will start getting 401 responses after the first rotation. The official Kubernetes client libraries handle this; hand rolled HTTP clients frequently do not. This is a very common bug in home grown operators.

### The Default Projected Token

Every Pod that does not opt out gets this mount automatically:

```bash
$ kubectl exec modern-token -- ls -l /var/run/secrets/kubernetes.io/serviceaccount/
total 0
lrwxrwxrwx 1 root root 13 Sep  5 10:12 ca.crt -> ..data/ca.crt
lrwxrwxrwx 1 root root 16 Sep  5 10:12 namespace -> ..data/namespace
lrwxrwxrwx 1 root root 12 Sep  5 10:12 token -> ..data/token
```

Inspecting the claims (a JWT is three base64url segments joined by dots):

```bash
kubectl exec modern-token -- cat /var/run/secrets/kubernetes.io/serviceaccount/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq
```

```json
{
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1788000000,
  "iat": 1787996400,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "kubernetes.io": {
    "namespace": "default",
    "pod": { "name": "modern-token", "uid": "9f2a..." },
    "serviceaccount": { "name": "myapp", "uid": "3c1b..." }
  },
  "sub": "system:serviceaccount:default:myapp"
}
```

The `pod` claim is the binding. Delete the Pod and the token stops working.

### Requesting a Token With kubectl

```bash
# short lived token for a ServiceAccount, printed once, never stored
kubectl create token myapp
kubectl create token myapp --duration=10m
kubectl create token myapp --audience=vault.example.com
```

This is the correct way to get a token for a script or a one off integration. It does not create a Secret, so there is nothing left behind to leak.

### When You Still Need a Long Lived Token

An external system that cannot perform the TokenRequest dance may need a static token. Create it explicitly, understand the risk, restrict its ServiceAccount to the minimum, and rotate it on a schedule:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ci-robot-token
  namespace: automation
  annotations:
    kubernetes.io/service-account.name: ci-robot
type: kubernetes.io/service-account-token
```

Treat this object as a permanent credential in your inventory, with an owner and an expiry date that you enforce yourself, because Kubernetes will not.

---

## External Secret Management

Native Secrets solve "get credentials out of Git and out of the image". They do not solve central management, automatic rotation, cross cluster distribution, dynamic credentials, or a unified audit trail. Four widely used approaches fill those gaps.

### External Secrets Operator

A controller that reads from an external secret store and materialises a native Kubernetes Secret.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secretsmanager
  namespace: production
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: SecretStore
  target:
    name: db-credentials        # the Kubernetes Secret it will create
    creationPolicy: Owner
  data:
  - secretKey: password         # key in the resulting Kubernetes Secret
    remoteRef:
      key: prod/db/credentials  # path in AWS Secrets Manager
      property: password
```

```
┌────────────────────────────────────────────────────────────────────┐
│                    External Secrets Operator                        │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   AWS Secrets Manager / Vault / GCP / Azure Key Vault               │
│                    │                                                │
│                    │ operator authenticates (often with a bound     │
│                    │ ServiceAccount token exchanged for a cloud     │
│                    │ identity: no static cloud credential needed)   │
│                    ▼                                                │
│           ExternalSecret CR  ──► operator ──► native Secret         │
│                                                    │                 │
│                                                    ▼                 │
│                                        Pod consumes it normally      │
│                                                                     │
│   ✅ Applications need no changes at all                            │
│   ✅ Git contains only a reference, never a value                   │
│   ✅ Refreshes on an interval, so external rotation propagates      │
│   ⚠️  The value STILL lands in etcd as a normal Secret. Encryption  │
│      at rest is still required.                                     │
│   ⚠️  Refreshing the Secret does not restart Pods. Env var          │
│      consumers keep the stale value.                                │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

`ClusterSecretStore` is the cluster scoped variant, letting many namespaces share one store definition.

### Sealed Secrets

An asymmetric encryption scheme that makes a secret safe to commit to Git. `kubeseal` encrypts with the controller's public key; only the controller's private key, which lives in the cluster, can decrypt.

```bash
# encrypt locally against the cluster's public key
kubectl create secret generic db-credentials \
  --from-literal=password='s3cr3tP@ss' \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > sealed-db-credentials.yaml

git add sealed-db-credentials.yaml     # safe to commit
```

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: db-credentials
  namespace: production
spec:
  encryptedData:
    password: AgBy3i4OJSWK+PiTySYZZA9rO43cGDEq...
  template:
    metadata:
      name: db-credentials
      namespace: production
    type: Opaque
```

```
┌────────────────────────────────────────────────────────────────────┐
│                        Sealed Secrets                               │
├────────────────────────────────────────────────────────────────────┤
│   ✅ Truly GitOps native: the encrypted value lives in Git          │
│   ✅ No external secret store to run or pay for                     │
│   ✅ Encryption happens on the developer's machine                  │
│                                                                     │
│   ⚠️  By default a sealed value is bound to a specific NAME and     │
│      NAMESPACE. Moving it requires resealing, or a looser scope.    │
│   ⚠️  The controller's private key is now the crown jewel. Back it  │
│      up, or a cluster rebuild cannot decrypt anything in Git.       │
│   ⚠️  No rotation story: rotating means resealing and committing.   │
│   ⚠️  The decrypted result is a normal Secret in etcd.              │
└────────────────────────────────────────────────────────────────────┘
```

### Vault Agent Injection

A mutating webhook adds a Vault Agent init container and sidecar to annotated Pods. The agent authenticates to Vault using the Pod's bound ServiceAccount token, fetches secrets, and renders them into a shared in memory volume.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "myapp"
        vault.hashicorp.com/agent-inject-secret-db: "database/creds/app-role"
        vault.hashicorp.com/agent-inject-template-db: |
          {{- with secret "database/creds/app-role" -}}
          export DB_USER="{{ .Data.username }}"
          export DB_PASS="{{ .Data.password }}"
          {{- end }}
    spec:
      serviceAccountName: myapp
      containers:
      - name: app
        image: myapp:1.4.2
```

The rendered file appears at `/vault/secrets/db` inside the container.

```
┌────────────────────────────────────────────────────────────────────┐
│                     Vault Agent Injection                           │
├────────────────────────────────────────────────────────────────────┤
│   ✅ The secret NEVER becomes a Kubernetes Secret and never         │
│      touches etcd at all                                            │
│   ✅ Supports DYNAMIC secrets: Vault creates a database user with   │
│      a short lease per Pod, and revokes it afterwards               │
│   ✅ The agent renews and re renders automatically                  │
│   ✅ Authentication uses the Pod's bound token, so there is no       │
│      bootstrap credential to manage                                 │
│                                                                     │
│   ⚠️  Two extra containers per Pod                                  │
│   ⚠️  Vault becomes a hard dependency of Pod startup                │
│   ⚠️  Applications must read a file (or source a rendered script)   │
│   ⚠️  Vault itself must be operated, unsealed and backed up         │
└────────────────────────────────────────────────────────────────────┘
```

### Secrets Store CSI Driver

A CSI driver that mounts secrets from an external store directly into the Pod as a volume, with provider plugins for AWS, Azure, GCP and Vault.

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: aws-db-credentials
  namespace: production
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "prod/db/credentials"
        objectType: "secretsmanager"
        jmesPath:
          - path: "password"
            objectAlias: "db-password"
  # OPTIONAL: also sync into a native Kubernetes Secret, which is what
  # you need if anything must consume the value as an env var.
  secretObjects:
  - secretName: db-credentials
    type: Opaque
    data:
    - objectName: db-password
      key: password
---
apiVersion: v1
kind: Pod
metadata:
  name: myapp
spec:
  serviceAccountName: myapp
  containers:
  - name: app
    image: myapp:1.4.2
    volumeMounts:
    - name: secrets-store
      mountPath: /mnt/secrets
      readOnly: true
  volumes:
  - name: secrets-store
    csi:
      driver: secrets-store.csi.x-k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: aws-db-credentials
```

```
┌────────────────────────────────────────────────────────────────────┐
│                   Secrets Store CSI Driver                          │
├────────────────────────────────────────────────────────────────────┤
│   ✅ Values are mounted straight into the Pod, bypassing etcd       │
│      entirely, UNLESS you opt in to secretObjects syncing           │
│   ✅ One consistent mechanism across cloud providers and Vault      │
│   ✅ Uses workload identity, so no static cloud credential          │
│                                                                     │
│   ⚠️  A Pod MUST mount the volume for a synced Secret to exist.     │
│      The synced Secret is created when the first consuming Pod      │
│      starts and removed when the last one stops. This surprises     │
│      people who expect the Secret to exist independently.           │
│   ⚠️  Rotation support depends on the driver's rotation reconciler  │
│      being enabled, and mounted file rotation still requires the    │
│      application to re-read the file.                               │
│   ⚠️  A CSI driver and a provider DaemonSet must be installed on    │
│      every node.                                                    │
└────────────────────────────────────────────────────────────────────┘
```

> 📖 **See Also**: [Installing the NFS CSI Driver](install-csi-nfs.md) for how CSI drivers are deployed in general.

### Choosing

| Requirement | Best fit |
|-------------|----------|
| Nothing extra to run, values out of Git | Native Secret + encryption at rest + CI injection |
| GitOps, no external store, small team | Sealed Secrets |
| Central store already exists (Vault, cloud KMS), no app changes | External Secrets Operator |
| Secret must never enter etcd | Secrets Store CSI Driver (without `secretObjects`) or Vault agent injection |
| Dynamic, short lived database credentials | Vault agent injection |
| Multi cloud consistency for file based secrets | Secrets Store CSI Driver |

---

## Rotation Strategy

Kubernetes does not rotate anything for you. Rotation is a process you build.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Rotation, End to End                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. GENERATE the new credential in the system of record              │
│     (database, cloud IAM, CA). Do NOT invalidate the old one yet.    │
│                                                                      │
│  2. DUAL VALIDITY window: both old and new credentials work. This    │
│     is the single most important step, and the one most often        │
│     skipped. Without it, rotation is an outage.                      │
│                                                                      │
│  3. UPDATE the Kubernetes Secret (or the external store, and let     │
│     the operator sync it).                                           │
│                                                                      │
│  4. PROPAGATE to workloads:                                          │
│       env var consumers   → MUST restart. No exceptions.             │
│       volume consumers    → files refresh automatically, but the     │
│                             app must re-read or be restarted.        │
│       immutable Secrets   → new object, new name, template change.   │
│                                                                      │
│  5. VERIFY every consumer is using the new credential. Check         │
│     application logs and the backend's authentication logs.          │
│                                                                      │
│  6. REVOKE the old credential in the system of record.               │
│                                                                      │
│  7. AUDIT: confirm nothing still authenticates with the old one.     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Rotating a Mutable Secret

```bash
NS=production

# 1. update in place
kubectl create secret generic db-credentials -n "$NS" \
  --from-literal=username=admin \
  --from-file=password=/dev/shm/new_pw \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. force every consumer to pick it up
kubectl rollout restart deployment/app     -n "$NS"
kubectl rollout restart deployment/worker  -n "$NS"
kubectl rollout status  deployment/app     -n "$NS" --timeout=5m
kubectl rollout status  deployment/worker  -n "$NS" --timeout=5m

# 3. only now revoke the old credential at the database
```

Find every workload you must restart:

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(
      (.spec.volumes // [])[]?.secret.secretName == "db-credentials"
      or ((.spec.containers[].envFrom // [])[]?.secretRef.name == "db-credentials")
      or ((.spec.containers[].env // [])[]?.valueFrom.secretKeyRef.name == "db-credentials")
    )
  | "\(.metadata.namespace)\t\(.metadata.name)"' | sort -u
```

### Rotating an Immutable Secret

```bash
kubectl apply -f secrets/app-secrets-v8.yaml       # new name, immutable: true

# point the Deployment at the new object; this changes the Pod template
# and therefore triggers a normal rolling update on its own
kubectl set env deployment/app --from=secret/app-secrets-v8 -n production
# or edit the manifest and apply it, which is the GitOps way

kubectl rollout status deployment/app -n production
kubectl delete secret app-secrets-v7 -n production  # after verification
```

### Rotating TLS Certificates

Certificates are the one case where automation is genuinely mature. cert-manager issues a `kubernetes.io/tls` Secret and renews it before expiry.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: web-tls
  namespace: production
spec:
  secretName: web-tls
  duration: 2160h        # 90 days
  renewBefore: 360h      # renew 15 days before expiry
  dnsNames:
  - www.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

The Secret is updated in place, the kubelet refreshes the mounted files, and then the server must reload. Ingress controllers watch the Secret and reload automatically. Applications terminating TLS themselves must either watch the files or be restarted.

Monitor expiry independently of the automation:

```bash
kubectl get secrets -A -o json \
  | jq -r '.items[] | select(.type=="kubernetes.io/tls")
           | "\(.metadata.namespace)/\(.metadata.name) \(.data["tls.crt"])"' \
  | while read -r name crt; do
      exp=$(echo "$crt" | base64 -d | openssl x509 -noout -enddate | cut -d= -f2)
      printf '%-50s %s\n' "$name" "$exp"
    done
```

### Rotation Cadence

| Credential | Suggested cadence | Notes |
|-----------|-------------------|-------|
| TLS server certificates | 90 days or less, automated | cert-manager or the cloud provider |
| Database passwords | 90 days, or per Pod if dynamic | Vault dynamic secrets make this trivial |
| Cloud API keys | 90 days, or eliminate with workload identity | Prefer no static key at all |
| Registry pull credentials | 180 days | Or use a token exchanged from workload identity |
| Service account tokens (bound) | automatic, hourly | The kubelet handles it |
| Service account tokens (legacy) | eliminate them | Replace with bound tokens |
| etcd encryption keys | annually, or on any suspected compromise | Follow the four step procedure exactly |
| Any credential after an incident | immediately | Assume compromise, rotate everything in scope |

---

## Command Reference

```bash
# ── CREATE ────────────────────────────────────────────────────────────
kubectl create secret generic NAME --from-literal=k=v
kubectl create secret generic NAME --from-file=path
kubectl create secret generic NAME --from-file=key=path
kubectl create secret generic NAME --from-file=dir/
kubectl create secret generic NAME --from-env-file=file.env
kubectl create secret generic NAME --type=example.com/custom --from-literal=k=v

kubectl create secret docker-registry NAME \
  --docker-server=HOST --docker-username=U --docker-password=P --docker-email=E

kubectl create secret tls NAME --cert=fullchain.pem --key=privkey.pem

kubectl create secret generic NAME --from-literal=k=v --dry-run=client -o yaml

# ── READ ──────────────────────────────────────────────────────────────
kubectl get secrets
kubectl get secrets -A
kubectl describe secret NAME                       # values are redacted

kubectl get secret NAME -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secret NAME -o jsonpath='{.data.tls\.crt}' | base64 -d
kubectl get secret NAME -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq

kubectl get secret NAME -o json | jq -r '.data | to_entries[] | "\(.key)=\(.value|@base64d)"'
kubectl get secret NAME -o go-template='{{range $k,$v := .data}}{{$k}}={{$v|base64decode}}
{{end}}'

# just the key names, no values
kubectl get secret NAME -o jsonpath='{.data}' | jq -r 'keys[]'

# all secrets of a given type
kubectl get secrets -A --field-selector type=kubernetes.io/tls

# ── UPDATE ────────────────────────────────────────────────────────────
kubectl apply -f secret.yaml

kubectl create secret generic NAME --from-literal=k=newvalue \
  --dry-run=client -o yaml | kubectl apply -f -

# patch a single key (value MUST be base64 for `data`)
kubectl patch secret NAME --type=merge \
  -p "{\"data\":{\"password\":\"$(printf '%s' 'newpass' | base64 -w0)\"}}"

# patch using stringData (plaintext, the API server encodes it)
kubectl patch secret NAME --type=merge -p '{"stringData":{"password":"newpass"}}'

# ── SERVICE ACCOUNTS ──────────────────────────────────────────────────
kubectl create token SA
kubectl create token SA --duration=10m --audience=vault.example.com
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regcred"}]}'

# ── ROLL CONSUMERS ────────────────────────────────────────────────────
kubectl rollout restart deployment/NAME
kubectl rollout status  deployment/NAME

# ── RBAC CHECKS ───────────────────────────────────────────────────────
kubectl auth can-i get secrets --as=system:serviceaccount:NS:SA -n NS
kubectl auth can-i list secrets --as=USER -n NS
kubectl auth can-i create pods  --as=USER -n NS          # equivalent power
kubectl auth can-i --list --as=system:serviceaccount:NS:SA -n NS

# ── ENCRYPTION AT REST ────────────────────────────────────────────────
head -c 32 /dev/urandom | base64                          # generate a key
kubectl get secrets -A -o json | kubectl replace -f -     # rewrite everything

sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/NAME | hexdump -C | head

# ── TLS INSPECTION ────────────────────────────────────────────────────
kubectl get secret NAME -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -text | head -20
kubectl get secret NAME -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -dates

# ── DELETE ────────────────────────────────────────────────────────────
kubectl delete secret NAME
kubectl delete secret -l app.kubernetes.io/name=myapp
```

---

## Troubleshooting

### Pod Stuck in CreateContainerConfigError

```bash
kubectl describe pod POD | tail -20
```

| Message | Cause |
|---------|-------|
| `secret "X" not found` | Wrong name, or the Secret is in a different namespace |
| `couldn't find key K in Secret ns/X` | Key typo, or the key was removed by a later apply |
| `failed to sync secret cache` | Transient API server or kubelet issue; usually resolves |

The kubelet retries forever, so creating the missing Secret repairs the Pod without recreating it.

### ImagePullBackOff on a Private Registry

```bash
kubectl describe pod POD | grep -A10 Events
kubectl get pod POD -o jsonpath='{.spec.imagePullSecrets}' | jq
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths|keys[]'
```

Checklist:

1. Is `regcred` in the **same namespace** as the Pod?
2. Does the `auths` key **exactly** match the registry host in the image reference, including any port?
3. Did you add the pull secret to the ServiceAccount **after** the Pods were created? The merge happens at Pod creation; recreate them.
4. Is the Secret type `kubernetes.io/dockerconfigjson` with the key `.dockerconfigjson`?
5. Do the credentials still work outside the cluster? Test a pull from a node.

### Authentication Fails but the Password Looks Right

Almost always a trailing newline:

```bash
kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d | xxd | tail -2
```

If the final byte is `0a`, you encoded `password\n`. Fix:

```bash
kubectl patch secret db-credentials --type=merge -p '{"stringData":{"password":"s3cr3tP@ss"}}'
kubectl rollout restart deployment/app
```

Other candidates:

- Shell mangling: an unquoted `$`, `!` or backtick in the password was expanded by your shell before `kubectl` ever saw it. Always single quote.
- Whitespace from a copy and paste, especially a non breaking space.
- The application is reading the file including its newline. Compare `wc -c` inside the container with the expected length.

### Environment Variable Contains the Stale Credential

Expected. Environment variables are frozen at container start. Restart the Pod. If you need rotation without restarts, mount the Secret as a volume and make the application re-read the file.

### Mounted Secret Is Stale

```bash
kubectl get secret NAME -o jsonpath='{.data.password}' | base64 -d; echo
kubectl exec POD -- cat /etc/creds/password; echo
kubectl exec POD -- readlink /etc/creds/..data
```

Diagnosis:

- **`subPath` used?** Never refreshes. Mount the directory instead, or restart.
- **`immutable: true`?** The object cannot have changed.
- **Changed within the last couple of minutes?** Wait for the kubelet sync period plus cache propagation delay.
- **`..data` timestamp is old?** Confirm the Pod references the Secret you think it does with `kubectl get pod POD -o jsonpath='{.spec.volumes}'`.
- **File is fresh but the app is not?** The application loaded it at startup. Restart it, or trigger its reload mechanism.

### Permission Denied Reading a Secret File

```bash
kubectl exec POD -- id
kubectl exec POD -- ls -l /etc/creds/..data/
```

A `defaultMode` of `0400` grants read access only to the owner, and the kubelet decides the owner. Either relax to `0440` and set `spec.securityContext.fsGroup` to a group the container belongs to, or use `0444` if the value tolerates it. Note that SSH clients require restrictive modes, so for `ssh-privatekey` the correct fix is `fsGroup`, not loosening the mode.

### API Server Will Not Start After Enabling Encryption

`kubectl` is dead, so read the container logs on the node:

```bash
sudo crictl ps -a --name kube-apiserver
sudo crictl logs "$(sudo crictl ps -a --name kube-apiserver -q | head -1)" 2>&1 | tail -40
```

| Symptom | Cause |
|---------|-------|
| `error while parsing file` | Malformed EncryptionConfiguration YAML |
| `secret is not base64 encoded` | The key value is not valid base64 |
| `key must be 32 bytes` | Wrong key length for the chosen provider |
| `no such file or directory` | The `hostPath` volume for the config is missing or not mounted |
| `did not find provider` | Empty or misspelled `providers` list |

Recover by moving the static Pod manifest aside, letting the API server come back with the previous configuration, then fixing the file:

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
# restore your known good manifest, then retry
```

Always keep a copy of the working manifest before editing it.

### Secrets Readable in etcd After Enabling Encryption

You skipped the rewrite step:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

Then re verify with `etcdctl`. If specific secrets remain plaintext, check that they were included in the `resources` list in your EncryptionConfiguration, and that every API server has the same config.

### Cannot Update a Secret: Field Is Immutable

Either `immutable: true` is set (create a new object with a new name), or you tried to change `type`, which is immutable for every Secret regardless. Delete and recreate.

### Secret Exists but the Application Cannot Find the ServiceAccount Token

```bash
kubectl get pod POD -o jsonpath='{.spec.automountServiceAccountToken}'
kubectl get sa SA -o jsonpath='{.automountServiceAccountToken}'
kubectl exec POD -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

If `automountServiceAccountToken: false` is set at either level, the token is not mounted. The Pod level setting overrides the ServiceAccount level.

### Client Gets 401 After About an Hour

The bound projected token rotated and your client cached the original value. Re-read the token file on every request, or use an official Kubernetes client library, which does this for you.

---

## Exam and Interview Traps

1. **Base64 is not encryption.** It is an encoding with no key. This is the number one Secrets question in every interview.
2. **Secrets are stored in etcd in plaintext by default.** Encryption at rest is opt in via `--encryption-provider-config`.
3. **Enabling encryption does not encrypt existing Secrets.** You must run `kubectl get secrets -A -o json | kubectl replace -f -`. Forgetting this is the classic mistake.
4. **The first provider in the list is used for writes; all providers are tried for reads.** Putting `identity` first silently disables encryption.
5. **`identity` means no encryption.** It belongs last, so that data written before encryption was enabled can still be read.
6. **Anyone who can create a Pod in a namespace can read every Secret in it.** They do not need `get secrets`.
7. **`list secrets` is equivalent to reading every secret in scope**, because list responses contain the object data. `resourceNames` cannot restrict `list`.
8. **`stringData` is write only.** It never appears when you read the object back; it is base64 encoded and merged into `data`.
9. **On a key collision, `stringData` wins over `data`.**
10. **The volume field is `secretName`, not `name`.** A `configMap` volume uses `name`. This asymmetry causes constant validation errors.
11. **`echo` without `-n` adds a newline before base64.** `YWRtaW4=` and `YWRtaW4K` are different values, and the second one fails authentication in a way that looks like a wrong password.
12. **Secret volumes are tmpfs**, so contents never touch node disk, unless the node has swap enabled.
13. **Environment variables never refresh; volume mounts do; `subPath` mounts do not.** Identical to ConfigMaps.
14. **Environment variables are inherited by every child process** and appear in `/proc/<pid>/environ`, crash dumps and many diagnostic tools. Volumes are strictly safer.
15. **A literal `value:` for a credential is visible to anyone with `get pods`,** without any secrets permission at all.
16. **`type` is immutable after creation.** Changing `Opaque` to `kubernetes.io/tls` requires delete and recreate.
17. **`kubernetes.io/tls` requires `tls.crt` and `tls.key`.** `kubernetes.io/dockerconfigjson` requires `.dockerconfigjson`, with a leading dot that must be escaped in JSONPath.
18. **`kubernetes.io/dockercfg` is the legacy format; `kubernetes.io/dockerconfigjson` is the current one.**
19. **A bootstrap token Secret must live in `kube-system` and be named `bootstrap-token-<token-id>`,** and the full token is `<token-id>.<token-secret>`.
20. **`imagePullSecrets` on a ServiceAccount are merged into the Pod spec at creation time**, so adding one does not affect existing Pods.
21. **Pull secrets must exist in the same namespace as the Pod.** Registry credentials have to be replicated per namespace.
22. **Modern Kubernetes does not auto create `kubernetes.io/service-account-token` Secrets for ServiceAccounts.** Bound, projected, expiring tokens replaced them.
23. **A bound token is invalidated when its Pod is deleted**, because the JWT carries a Pod UID claim. A legacy token is valid forever.
24. **The kubelet rotates projected tokens, so clients must re-read the file.** Caching the token at startup causes 401s after roughly an hour.
25. **`aesgcm` requires frequent key rotation** because of nonce reuse concerns; the documentation states every 200,000 writes. `secretbox` and `aescbc` are the usual choices for local keys.
26. **Local encryption keys sit next to the data they protect.** They defend against a stolen etcd backup, not against control plane compromise. Use `kms` for real key separation.
27. **Key rotation is a four step dance**: add the new key second, wait for every API server, promote it to first, then rewrite all Secrets. Removing the old key before the rewrite destroys data.
28. **Verify encryption with `etcdctl` and look for the `k8s:enc:<provider>:v1:<keyname>:` prefix.** Do not trust the config file alone.
29. **The audit policy level for Secrets must be `Metadata`.** `RequestResponse` writes secret values into the audit log.
30. **Every API server in an HA control plane needs the same EncryptionConfiguration and the same keys**, or reads fail non deterministically depending on which one serves them.
31. **Secrets are namespaced with no cross namespace reference**, and the roughly 1 MiB etcd limit applies just as it does to ConfigMaps.
32. **The Secrets Store CSI Driver's synced Secret only exists while a consuming Pod exists.** It is created on first mount and removed with the last one.
33. **External Secrets Operator and Sealed Secrets both end with a normal Secret in etcd.** Encryption at rest is still required.
34. **`automountServiceAccountToken: false` on the Pod overrides the ServiceAccount setting**, and is free security for workloads that never call the API server.

---

## Related Topics

- [ConfigMaps](configmaps.md)
- [Downward API](downward-api.md)
- [Pods](pods.md)
- [Deployments](deployments.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [Controllers](controllers.md)
- [etcd](etcd.md)
- [kube-apiserver](kube-apiserver.md)
- [kubelet](kubelet.md)
- [Control Plane Node](control-plane-node.md)
- [Worker Node](worker-node.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [Network Policy](network-policy.md)
- [Installing the NFS CSI Driver](install-csi-nfs.md)
- [Manual Kubernetes Cluster Install](manual-install-k8s-cluster.md)

---

## Key Takeaways

1. **Base64 is an encoding, not an encryption.** A Secret provides no confidentiality by itself; `echo <value> | base64 -d` is all anyone needs.
2. **Secrets are stored in etcd in plaintext until you configure encryption at rest**, and enabling it only affects new writes. The `kubectl get secrets -A -o json | kubectl replace -f -` rewrite step is mandatory, and must be repeated after every key rotation.
3. What a Secret genuinely buys you: **tmpfs backed volumes, redaction in `kubectl describe`, a separate RBAC resource, node scoped distribution enforced by the Node authorizer, targeted audit logging, and a place to hang encryption at rest.**
4. **`data` is base64 and readable; `stringData` is plaintext, write only, merged into `data`, and wins on key collisions.** It never comes back on read.
5. `echo` without `-n` silently appends a newline before base64, producing an authentication failure that looks exactly like a wrong password. Check with `base64 -d | xxd | tail -1`.
6. The built in types (`Opaque`, `service-account-token`, `dockercfg`, `dockerconfigjson`, `basic-auth`, `ssh-auth`, `tls`, `bootstrap.kubernetes.io/token`) each carry expected keys, and **`type` is immutable after creation**.
7. **Volume mounts beat environment variables for anything sensitive**: environment variables are inherited by every child process, appear in `/proc/<pid>/environ` and crash dumps, are frozen at container start so they never rotate, and a literal `value:` is visible to anyone with `get pods`.
8. The volume field is **`secretName`**, not `name`. Use `defaultMode: 0400` in octal for private keys, and `fsGroup` when a non root container must read them.
9. **`imagePullSecrets` belong on the ServiceAccount**, are merged into the Pod spec at creation time (so existing Pods are unaffected), and must live in the Pod's own namespace.
10. Volume refresh works exactly as it does for ConfigMaps: eventual, via an atomic `..data` symlink swap, and **never with `subPath`**. The application still has to re-read the file.
11. Encryption at rest is configured with an `EncryptionConfiguration` and `--encryption-provider-config`. **The first provider encrypts; all providers can decrypt; `identity` means plaintext and belongs last.** Every API server in an HA control plane needs identical configuration.
12. **Local keys (`aescbc`, `aesgcm`, `secretbox`) sit on the same machine as the data.** They defend against stolen backups and disks, not against control plane compromise. The **`kms` provider** uses envelope encryption so the key encryption key never leaves the external KMS.
13. **Verify, do not assume.** Read the raw value from etcd with `etcdctl` and look for the `k8s:enc:<provider>:v1:<key>:` prefix.
14. **Anyone who can create a Pod in a namespace can read every Secret in it,** and `list secrets` is equivalent to reading them all because `resourceNames` cannot restrict `list`. The namespace is your real security boundary.
15. Set the audit policy for Secrets to **`Metadata`**, never `RequestResponse`, or the audit log becomes a credential store.
16. **Bound, projected service account tokens replaced long lived token Secrets.** They expire, are audience scoped, carry a Pod UID claim so they die with the Pod, and are rotated by the kubelet, which means **clients must re-read the token file**.
17. External tooling fills the gaps Kubernetes leaves: **External Secrets Operator** (sync from a central store), **Sealed Secrets** (safe to commit to Git), **Vault agent injection** (never touches etcd, supports dynamic credentials), and the **Secrets Store CSI Driver** (mount directly from a cloud store). The first two still end with a normal Secret in etcd.
18. **Rotation is a process you build, not a feature you enable.** Always create a dual validity window, propagate (restarting every environment variable consumer), verify, and only then revoke the old credential.

---

## References

- [Secrets concept](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Managing Secrets using kubectl](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/)
- [Managing Secrets using Configuration File](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-config-file/)
- [Managing Secrets using Kustomize](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kustomize/)
- [Distribute Credentials Securely Using Secrets](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/)
- [Good practices for Kubernetes Secrets](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
- [Encrypting Confidential Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Using a KMS provider for data encryption](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [Pull an Image from a Private Registry](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)
- [Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [Managing Service Accounts](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)
- [Authenticating: Service Account Tokens](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#service-account-tokens)
- [Authenticating with Bootstrap Tokens](https://kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens/)
- [Using Node Authorization](https://kubernetes.io/docs/reference/access-authn-authz/node/)
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Projected Volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
- [Secret API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/secret-v1/)
- [EncryptionConfiguration API reference](https://kubernetes.io/docs/reference/config-api/apiserver-encryption.v1/)
- [Operating etcd clusters for Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
