# 🔒 Encryption at Rest: Protecting etcd Data

By default, every Secret in your cluster is stored in etcd as base64-encoded plaintext. Anyone who obtains an etcd snapshot, a backup tarball, or the disk under a control plane node owns every credential you have. This document covers proving that with `etcdctl`, the `EncryptionConfiguration` resource, every provider from `aescbc` to KMS v2, enabling encryption on a kubeadm cluster step by step, rewriting existing data, key rotation without downtime, and the recovery scenarios that make key custody a serious operational concern.

## 📋 Table of Contents
- [The Threat Model](#the-threat-model)
- [Proving It: Reading a Secret From etcd](#proving-it-reading-a-secret-from-etcd)
- [What Encryption at Rest Does and Does Not Solve](#what-encryption-at-rest-does-and-does-not-solve)
- [The EncryptionConfiguration Resource](#the-encryptionconfiguration-resource)
- [Provider Ordering Semantics](#provider-ordering-semantics)
- [The Providers](#the-providers)
- [Generating a Key](#generating-a-key)
- [Enabling Encryption on kubeadm](#enabling-encryption-on-kubeadm)
- [Rewriting Existing Data](#rewriting-existing-data)
- [Verifying Encryption Works](#verifying-encryption-works)
- [Key Rotation](#key-rotation)
- [Automatic Reload](#automatic-reload)
- [KMS v2](#kms-v2)
- [Encrypting Beyond Secrets](#encrypting-beyond-secrets)
- [HA Cluster Rollout](#ha-cluster-rollout)
- [Key Custody and Disaster Scenarios](#key-custody-and-disaster-scenarios)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The Threat Model

```
   ┌────────────────────────────────────────────────────────────────────────┐
   │                    WHERE SECRETS ACTUALLY LIVE                         │
   │                                                                        │
   │   kubectl create secret                                                │
   │        │                                                               │
   │        ▼                                                               │
   │   kube-apiserver  ── RBAC protects this door ──►  reasonably guarded   │
   │        │                                                               │
   │        ▼                                                               │
   │   etcd  ──►  /var/lib/etcd/member/snap/db  on the control plane node   │
   │              │                                                         │
   │              ├─► base64, NOT encrypted, by default                     │
   │              ├─► included verbatim in every etcd snapshot              │
   │              ├─► included in every backup you ship offsite             │
   │              └─► readable by anyone with root on the node              │
   └────────────────────────────────────────────────────────────────────────┘
```

RBAC guards the API. It does nothing for the storage layer. The attack paths that bypass the API entirely:

| Path | Who |
|---|---|
| Read the etcd data directory | Anyone with root on a control plane node |
| Restore an etcd snapshot elsewhere | Anyone with backup access |
| Recover a decommissioned disk or VM image | Anyone in the datacentre or cloud account |
| Read a backup in object storage | Anyone with bucket read access |
| A privileged pod with a hostPath mount of `/var/lib/etcd` | Any workload that escapes Pod Security |

The last one is worth dwelling on. A single `privileged: true` pod scheduled to a control plane node can read the entire etcd database. See [pod-security-standards.md](pod-security-standards.md).

---

## Proving It: Reading a Secret From etcd

Do this once. It changes how you think about Secrets permanently.

```bash
# Create something obviously identifiable.
kubectl create namespace enc-demo
kubectl -n enc-demo create secret generic canary \
  --from-literal=password='SuperSecretValue123'
```

Now read it straight out of etcd on the control plane node. On a kubeadm cluster the client certificates are in the standard PKI directory.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/enc-demo/canary | hexdump -C
```

If `etcdctl` is not installed on the node, run it inside the etcd static pod, which already has it:

```bash
kubectl -n kube-system exec -it etcd-$(hostname) -- sh -c '
  ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/enc-demo/canary' | hexdump -C
```

The output on an unencrypted cluster:

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 65 6e 63 2d 64 65  6d 6f 2f 63 61 6e 61 72  |s/enc-demo/canar|
00000020  79 0a 6b 38 73 00 0a 0c  0a 02 76 31 12 06 53 65  |y.k8s.....v1..Se|
...
000000d0  61 73 73 77 6f 72 64 12  13 53 75 70 65 72 53 65  |assword..SuperSe|
000000e0  63 72 65 74 56 61 6c 75  65 31 32 33              |cretValue123|
                                    ▲
                                    └── your password, in the clear
```

The `k8s` magic prefix at offset `0x22` indicates an unencrypted protobuf-serialised object. After encryption, that prefix becomes `k8s:enc:aescbc:v1:<keyname>:` followed by ciphertext.

---

## What Encryption at Rest Does and Does Not Solve

Be precise about this, because it is a common source of false confidence.

```
   ✅ SOLVES                                ❌ DOES NOT SOLVE
   ─────────                                ─────────────────
   Stolen etcd snapshot                     A user with RBAC get on secrets
   Stolen backup tarball                    A pod that mounts the secret
   Decommissioned disk                      A compromised API server process
   Offline disk access on the node          A compromised kubelet on a node
                                             running the pod
   hostPath read of /var/lib/etcd           Someone with the encryption key
```

The API server decrypts on read, transparently. Anyone authorized to `get` a Secret through the API sees plaintext, encrypted or not. Encryption at rest is a storage-layer control, and it must be paired with:

- Tight RBAC on `secrets` (see [rbac.md](rbac.md))
- `automountServiceAccountToken: false` by default (see [service-accounts.md](service-accounts.md))
- Audit logging of secret reads (see [audit-logging.md](audit-logging.md))
- Encrypted etcd backups (see [etcd-backup-restore.md](etcd-backup-restore.md))

---

## The EncryptionConfiguration Resource

A file on the control plane node, referenced by an API server flag. It is not a Kubernetes API object and cannot be managed with `kubectl`.

```yaml
# /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  # Each entry maps a set of resources to an ordered provider list.
  - resources:
      # Resource names as they appear in the API, optionally group-qualified.
      - secrets
      - configmaps
    providers:
      # ORDER MATTERS. See the next section.
      - aescbc:
          keys:
            - name: key-2026-01
              secret: <base64 of 32 random bytes>
      - identity: {}
```

Field notes:

| Field | Meaning |
|---|---|
| `resources[].resources` | Plural resource names. Use `resource.group` form for non-core groups, for example `events.events.k8s.io`. |
| `resources[].providers` | Ordered list. First is used for writes; all are tried for reads. |
| `keys[].name` | An arbitrary label. It is written into the stored value so the API server knows which key decrypts it. Never reuse a name for a different key. |
| `keys[].secret` | Base64 of the raw key bytes. 32 bytes for `aescbc`, `aesgcm` and `secretbox`. |

Lock the file down. It is a credential.

```bash
sudo mkdir -p /etc/kubernetes/enc
sudo chmod 700 /etc/kubernetes/enc
sudo chown root:root /etc/kubernetes/enc/encryption-config.yaml
sudo chmod 600 /etc/kubernetes/enc/encryption-config.yaml
```

---

## Provider Ordering Semantics

The single most important rule in this document.

```
   ┌────────────────────────────────────────────────────────────────────┐
   │  WRITE:  always uses the FIRST provider in the list.               │
   │  READ:   tries providers in order until one succeeds, matching     │
   │          on the prefix stored with the value.                      │
   └────────────────────────────────────────────────────────────────────┘
```

```
   providers:
     - aescbc:          ◄── encrypts all NEW writes
         keys:
           - name: key-2026-01
           - name: key-2025-07   ◄── can still DECRYPT old data
     - identity: {}     ◄── can read data written before encryption
                            was enabled
```

Two consequences:

**Putting `identity` first disables encryption for writes.** This is exactly how you *decrypt* a cluster, deliberately:

```yaml
providers:
  - identity: {}          # new writes are plaintext
  - aescbc:               # old encrypted data can still be read
      keys:
        - name: key-2026-01
          secret: ...
```

**Removing a key before rewriting data makes that data permanently unreadable.** If objects in etcd were encrypted with `key-2025-07` and you delete that key from the config, every read of those objects fails. The API server returns an error and the objects are effectively lost.

Within a single provider, multiple keys work the same way: the first key encrypts, all keys can decrypt.

---

## The Providers

| Provider | Algorithm | Key length | Strength | Speed | Notes |
|---|---|---|---|---|---|
| `identity` | none | n/a | **none** | fastest | Plaintext. The default. |
| `secretbox` | XSalsa20 + Poly1305 | 32 bytes | strong | fast | AEAD. Good choice. |
| `aescbc` | AES-CBC with PKCS#7 | 32 bytes | adequate | fast | Not authenticated. Vulnerable to padding oracle attacks in principle. Widely deployed. |
| `aesgcm` | AES-GCM | 16, 24 or 32 bytes | strong | fastest | AEAD, but **requires key rotation every ~200k writes**. Not recommended without automation. |
| `kms` v1 | envelope, external KMS | n/a | strongest | slower | Deprecated. A KMS call per encryption. |
| `kms` v2 | envelope, external KMS | n/a | strongest | fast | Current recommendation where a KMS exists. DEK caching. |

### Which To Choose

```
   Do you have a KMS (cloud KMS, Vault, HSM)?
        │
        ├─ Yes ──►  kms v2.  Key never touches the node's disk.
        │
        └─ No  ──►  Is this a bare metal or homelab cluster?
                         │
                         ├─ Yes ──►  secretbox  (modern AEAD, simple)
                         │           or aescbc  (the most commonly
                         │           documented, fine in practice)
                         │
                         └─ No  ──►  get a KMS
```

Avoid `aesgcm` unless you have automated rotation. GCM's security depends on never reusing a nonce with the same key, and the implementation's counter space is bounded. Upstream documentation is explicit that it must be rotated frequently.

`aescbc` lacks authentication, which means a sophisticated attacker with write access to etcd could in principle tamper with ciphertext. In practice, an attacker with etcd write access has already won. It remains the most widely used option and is a very large improvement over plaintext.

---

## Generating a Key

32 cryptographically random bytes, base64 encoded.

```bash
head -c 32 /dev/urandom | base64
# Wg8p3vQ2xK9mN4rT6yU8iO0pA1sD3fG5hJ7kL9zX2cV=
```

Or with openssl:

```bash
openssl rand -base64 32
```

Do **not** use a passphrase, a hash of a passphrase, or anything derived from a human-chosen string. The key must be full-entropy random bytes.

Verify the decoded length before using it:

```bash
KEY=$(head -c 32 /dev/urandom | base64)
echo -n "$KEY" | base64 -d | wc -c
# 32
```

A key of the wrong length causes the API server to fail at startup with a message about invalid key size, and since it is a static pod, that means no API server at all.

---

## Enabling Encryption on kubeadm

### Step 1: Create the Configuration

```bash
sudo mkdir -p /etc/kubernetes/enc
sudo chmod 700 /etc/kubernetes/enc

KEY=$(head -c 32 /dev/urandom | base64)
NAME="key-$(date +%Y%m)"

sudo tee /etc/kubernetes/enc/encryption-config.yaml >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      # New writes are encrypted with this key.
      - aescbc:
          keys:
            - name: ${NAME}
              secret: ${KEY}
      # Existing plaintext data remains readable.
      # This entry MUST stay until every object has been rewritten.
      - identity: {}
EOF

sudo chmod 600 /etc/kubernetes/enc/encryption-config.yaml
```

**Back the key up now, before going further.** Losing it after the cluster is encrypted means unrecoverable data.

### Step 2: Edit the API Server Manifest

Two changes are required. Adding the flag without the volume mount is the single most common mistake and produces a control plane that will not start.

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml \
        /root/kube-apiserver.yaml.bak
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
        # ── CHANGE 1: the flag ──────────────────────────────────────
        - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
        # Reload the file on change without restarting the API server.
        - --encryption-provider-config-automatic-reload=true
        # ...existing flags unchanged...
      volumeMounts:
        # ── CHANGE 2a: the mount ────────────────────────────────────
        - name: enc
          mountPath: /etc/kubernetes/enc
          readOnly: true
        # ...existing mounts unchanged...
  volumes:
    # ── CHANGE 2b: the volume ─────────────────────────────────────
    - name: enc
      hostPath:
        path: /etc/kubernetes/enc
        type: DirectoryOrCreate
    # ...existing volumes unchanged...
```

Saving the file causes the kubelet to restart the API server automatically. Watch it come back:

```bash
# The API will be briefly unavailable.
until kubectl get --raw /healthz 2>/dev/null; do sleep 2; done; echo

# Confirm the flag is live.
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' \
  | tr ',' '\n' | grep encryption
```

If the API server does not come back, jump to [Troubleshooting](#troubleshooting).

### Step 3: Confirm New Secrets Are Encrypted

```bash
kubectl -n enc-demo create secret generic canary2 \
  --from-literal=password='AnotherSecret456'

sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/enc-demo/canary2 | hexdump -C | head -6
```

You should now see:

```
00000020  79 32 0a 6b 38 73 3a 65  6e 63 3a 61 65 73 63 62  |y2.k8s:enc:aescb|
00000030  63 3a 76 31 3a 6b 65 79  2d 32 30 32 36 30 31 3a  |c:v1:key-202601:|
00000040  b3 7f 2e 91 c4 08 dd 6a  55 e0 1b 3c 9f 42 a7 d8  |.......jU..<.B..|
```

The `k8s:enc:aescbc:v1:key-202601:` prefix tells the API server which provider and key to use on read. Everything after it is ciphertext.

Note that `canary` (created before) is still plaintext. Encryption applies only to writes.

---

## Rewriting Existing Data

Enabling encryption does nothing to objects already in etcd. You must force a rewrite of every one.

The mechanism is a no-op read-modify-write: read every Secret and immediately replace it with itself. The API server encrypts on write.

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

### Doing It Safely on a Real Cluster

The one-liner reads every Secret in the cluster into memory and pipes them back. On a large cluster this is a lot of data and a lot of write load on etcd. Namespace by namespace is safer:

```bash
#!/usr/bin/env bash
set -euo pipefail

for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  count=$(kubectl -n "$ns" get secrets -o json | jq '.items | length')
  [[ "$count" -eq 0 ]] && continue
  printf 'rewriting %-30s (%s secrets) ... ' "$ns" "$count"
  if kubectl -n "$ns" get secrets -o json | kubectl replace -f - >/dev/null 2>&1; then
    echo ok
  else
    echo FAILED
  fi
  sleep 1        # be kind to etcd
done
```

### Caveats

- **Service account token Secrets of the legacy type may fail to replace.** They carry controller-managed fields. A failure on those is usually harmless, since modern clusters use projected bound tokens rather than stored Secrets.
- **`kubectl replace` bumps `resourceVersion`.** Any controller watching Secrets sees an update event. Expect a burst of reconciliation.
- **GitOps tools may flag drift.** The object content is unchanged, so most tools settle immediately.
- **Immutable Secrets cannot be replaced.** A Secret with `immutable: true` must be deleted and recreated, which means coordinating with whatever consumes it.

Find immutable Secrets first:

```bash
kubectl get secrets -A -o json | jq -r '
  .items[] | select(.immutable == true)
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

### Confirm the Rewrite Worked

```bash
# Every secret key in etcd that is still plaintext.
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets --prefix --keys-only | grep -v '^$' | \
while read -r key; do
  if ! sudo ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        get "$key" | grep -q 'k8s:enc:'; then
    echo "STILL PLAINTEXT: $key"
  fi
done
```

Silence means everything is encrypted.

### Step 4: Remove the identity Provider

Once nothing is plaintext, drop `identity` so that no future write can accidentally be stored in the clear.

```yaml
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key-202601
              secret: <key>
      # identity removed
```

With `--encryption-provider-config-automatic-reload=true` this takes effect within about a minute with no restart.

---

## Verifying Encryption Works

A compact verification script worth keeping.

```bash
#!/usr/bin/env bash
# check-encryption.sh NAMESPACE SECRETNAME
set -euo pipefail
NS="${1:-default}"
NAME="${2:?usage: $0 NAMESPACE SECRETNAME}"

E="--endpoints=https://127.0.0.1:2379"
C="--cacert=/etc/kubernetes/pki/etcd/ca.crt"
CE="--cert=/etc/kubernetes/pki/etcd/server.crt"
K="--key=/etc/kubernetes/pki/etcd/server.key"

raw=$(sudo ETCDCTL_API=3 etcdctl $E $C $CE $K \
        get "/registry/secrets/${NS}/${NAME}")

if grep -q 'k8s:enc:' <<<"$raw"; then
  prefix=$(grep -o 'k8s:enc:[a-z0-9]*:v[0-9]*:[^:]*:' <<<"$raw")
  echo "ENCRYPTED   ${NS}/${NAME}   ${prefix}"
else
  echo "PLAINTEXT   ${NS}/${NAME}"
fi
```

Also confirm the API server still decrypts correctly, which proves the read path:

```bash
kubectl -n enc-demo get secret canary2 -o jsonpath='{.data.password}' | base64 -d
# AnotherSecret456
```

If that returns the right value while etcd shows ciphertext, the whole pipeline is working.

---

## Key Rotation

Rotate on a schedule, and immediately on any suspicion of compromise. The procedure has four phases and never requires downtime.

```
   PHASE 1  Add the new key SECOND.
            Old key still encrypts. Both can decrypt.
            Purpose: every API server learns the new key before any
            of them starts using it.

   PHASE 2  Promote the new key to FIRST.
            New writes use the new key. Old key still decrypts.

   PHASE 3  Rewrite all data.
            Everything is re-encrypted with the new key.

   PHASE 4  Remove the old key.
            Nothing references it any more.
```

Skipping phase 1 on an HA cluster breaks reads: an API server that has not yet loaded the new key cannot decrypt data written by one that has.

### Phase 1: Add the New Key Second

```yaml
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key-202601        # still encrypting
              secret: <old key>
            - name: key-202607        # new, decrypt only for now
              secret: <new key>
```

Apply on **every** control plane node. Wait for the reload (or restart each API server in turn), then confirm all of them are healthy.

```bash
kubectl -n kube-system get pods -l component=kube-apiserver -o wide
```

### Phase 2: Promote

```yaml
providers:
  - aescbc:
      keys:
        - name: key-202607        # now encrypting
          secret: <new key>
        - name: key-202601        # decrypt only
          secret: <old key>
```

Again on every node.

### Phase 3: Rewrite

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

Verify no object still carries the old key name:

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets --prefix | grep -c 'key-202601'
# 0
```

### Phase 4: Remove the Old Key

```yaml
providers:
  - aescbc:
      keys:
        - name: key-202607
          secret: <new key>
```

Only do this after phase 3 reports zero. Removing a key that still encrypts live data destroys that data.

---

## Automatic Reload

```yaml
- --encryption-provider-config-automatic-reload=true
```

The API server polls the configuration file and picks up changes without a restart, typically within a minute.

Benefits:

- Key rotation with no API server restarts, which on an HA cluster is a meaningful reduction in risk.
- Fewer moments where the control plane is degraded.

Caveat: a **malformed** file after a reload is rejected and the previous configuration is kept, which is safe, but it also means a typo can leave you believing a change applied when it did not. Always verify after editing.

```bash
kubectl get --raw /metrics | grep apiserver_encryption_config_controller_automatic_reload
# apiserver_encryption_config_controller_automatic_reload_success_total 3
# apiserver_encryption_config_controller_automatic_reload_failure_total 0
```

A non-zero failure counter means your last edit was rejected.

---

## KMS v2

Envelope encryption using an external key manager. The data encryption key (DEK) encrypts the object; the KMS holds the key encryption key (KEK) and never releases it.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                        KMS v2 ENVELOPE FLOW                          │
   │                                                                      │
   │   WRITE                                                              │
   │     API server generates a DEK (or reuses a cached one)              │
   │           │                                                          │
   │           ├─► encrypts the object with the DEK  (local, fast)        │
   │           │                                                          │
   │           └─► asks the KMS plugin to encrypt the DEK with the KEK    │
   │                     │                                                │
   │                     ▼                                                │
   │               ┌──────────────┐   gRPC over    ┌──────────────────┐   │
   │               │ KMS plugin   │ ◄── UNIX ────► │  external KMS    │   │
   │               │ (a static    │     socket      │  Vault / cloud   │   │
   │               │  pod on the  │                 │  KMS / HSM       │   │
   │               │  node)       │                 └──────────────────┘   │
   │               └──────────────┘                                       │
   │           │                                                          │
   │           ▼                                                          │
   │     stores in etcd:  [encrypted DEK][ciphertext]                     │
   │                                                                      │
   │   READ                                                               │
   │     read the encrypted DEK, decrypt it via KMS (or hit the cache),   │
   │     then decrypt the object locally.                                 │
   └──────────────────────────────────────────────────────────────────────┘
```

### Why v2 Rather Than v1

| | KMS v1 | KMS v2 |
|---|---|---|
| KMS call frequency | one per encrypt operation | one per DEK, DEKs are cached and reused |
| Performance | poor under load | good |
| Key ID tracking | no | yes, `status.key_id` enables rotation detection |
| Health checking | limited | proper `Status` RPC |
| Status | deprecated | current |

### Configuration

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - kms:
          apiVersion: v2
          # An arbitrary name. Written into the stored prefix.
          name: vault-kms
          # UNIX socket the plugin listens on. Must be mounted into
          # the API server pod.
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}
```

Mount the socket directory:

```yaml
      volumeMounts:
        - name: kms-socket
          mountPath: /var/run/kmsplugin
  volumes:
    - name: kms-socket
      hostPath:
        path: /var/run/kmsplugin
        type: DirectoryOrCreate
```

The plugin itself is normally a static pod on each control plane node, so it is available before the API server needs it and does not depend on the cluster being up.

### Operational Notes

- **The KMS is on the critical path.** If it is unreachable, the API server cannot decrypt Secrets. Pods needing a Secret will not start. Choose a KMS with an availability target at least as good as your control plane.
- **KEK rotation is done in the KMS**, not in Kubernetes. The plugin reports a new `key_id`, and the API server re-encrypts DEKs as objects are written. Force a full re-encrypt with the usual rewrite.
- **Monitor it:**

```bash
kubectl get --raw /metrics | grep -E 'apiserver_envelope_encryption'
# apiserver_envelope_encryption_key_id_hash_total
# apiserver_envelope_encryption_dek_cache_fill_percent
# apiserver_envelope_encryption_invalid_key_id_from_status_total
```

---

## Encrypting Beyond Secrets

Secrets are the priority, but they are not the only sensitive storage.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  # Highest value first.
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key-202601
              secret: <key>

  # ConfigMaps routinely contain connection strings that should be Secrets.
  - resources:
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: key-202601
              secret: <key>

  # Non-core groups use the resource.group form.
  - resources:
      - tokenreviews.authentication.k8s.io
    providers:
      - aescbc:
          keys:
            - name: key-202601
              secret: <key>
```

A wildcard is supported:

```yaml
  # Every resource in every group. Correct in principle, but it encrypts
  # Leases, Events and Endpoints too, which are extremely high write rate.
  # Measure the etcd latency impact before doing this in production.
  - resources:
      - '*.*'
    providers:
      - aescbc:
          keys:
            - name: key-202601
              secret: <key>
```

A sensible middle ground for most clusters is `secrets` and `configmaps`, leaving the high-churn coordination objects unencrypted.

Rewrite for each resource type you add:

```bash
kubectl get configmaps -A -o json | kubectl replace -f -
```

Note that `kube-root-ca.crt` ConfigMaps are controller-managed and may reject replacement. That is harmless.

---

## HA Cluster Rollout

With three control plane nodes, ordering is the whole problem.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  WRONG                                                               │
   │    cp-1 gets the new config and starts encrypting with key-B.        │
   │    cp-2 and cp-3 have never seen key-B.                              │
   │    A client hits cp-2, asks for a Secret written by cp-1.            │
   │    cp-2 cannot decrypt it.  Error.                                    │
   ├──────────────────────────────────────────────────────────────────────┤
   │  RIGHT                                                               │
   │    1. Distribute the config with the new key in DECRYPT-ONLY         │
   │       position to ALL nodes.                                          │
   │    2. Confirm all API servers healthy and reloaded.                  │
   │    3. THEN promote the key to first position on all nodes.           │
   └──────────────────────────────────────────────────────────────────────┘
```

A distribution helper:

```bash
#!/usr/bin/env bash
set -euo pipefail
CPS=(cp-01 cp-02 cp-03)
SRC=/etc/kubernetes/enc/encryption-config.yaml

for node in "${CPS[@]}"; do
  echo "== $node"
  scp "$SRC" "${node}:/tmp/encryption-config.yaml"
  ssh "$node" 'sudo install -o root -g root -m 600 \
      /tmp/encryption-config.yaml /etc/kubernetes/enc/encryption-config.yaml &&
    rm -f /tmp/encryption-config.yaml'
done

# With automatic reload, wait and verify rather than restarting.
sleep 90
kubectl get --raw /metrics | \
  grep apiserver_encryption_config_controller_automatic_reload_failure_total
```

Without automatic reload, restart each API server one at a time and wait for it to become ready before moving on:

```bash
for node in "${CPS[@]}"; do
  ssh "$node" 'sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/ && \
               sleep 5 && \
               sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/'
  until kubectl get --raw /healthz >/dev/null 2>&1; do sleep 3; done
  sleep 20
done
```

---

## Key Custody and Disaster Scenarios

The uncomfortable truth: **encryption at rest converts an availability problem into a confidentiality guarantee, and the key becomes a single point of total data loss.**

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  LOSE THE KEY  ──►  every encrypted Secret is unrecoverable.         │
   │                     Not "hard to recover". Unrecoverable.            │
   │                     Your etcd backups are also useless for those     │
   │                     objects.                                          │
   └──────────────────────────────────────────────────────────────────────┘
```

### Backing the Key Up

Requirements:

1. **Stored somewhere other than the cluster.** A Secret inside the cluster it protects is circular.
2. **Stored somewhere other than the etcd backups.** A backup containing both ciphertext and key protects nothing.
3. **Multiple copies, geographically separated.**
4. **Access audited**, because reading the key is equivalent to reading every Secret.

Reasonable options: a password manager with an audit trail, an offline HSM, a sealed envelope in a safe for small clusters, or a KMS (which sidesteps the problem entirely, since the key never leaves the KMS).

```bash
# Back up the whole config file, not just the key material.
sudo cp /etc/kubernetes/enc/encryption-config.yaml \
        /root/encryption-config-$(date +%F).yaml.bak
sudo chmod 600 /root/encryption-config-*.yaml.bak

# Then move it OFF the node, into your secrets manager.
```

### Scenario: Config File Lost, Cluster Still Running

The API server has the keys in memory and continues to work. This is your window.

```bash
# Recover the config from the running pod immediately.
kubectl -n kube-system exec etcd-cp-01 -- true   # confirm access first

# The API server has the file mounted; read it back out.
kubectl -n kube-system exec \
  $(kubectl -n kube-system get pod -l component=kube-apiserver \
    -o name | head -1) -- \
  cat /etc/kubernetes/enc/encryption-config.yaml
```

Save it before anything restarts.

### Scenario: Config Lost and API Server Restarted

The API server will not start, because the flag points at a missing file. If no backup of the key exists, encrypted Secrets are gone.

Partial recovery is still possible: everything *other* than the encrypted resources is intact. You can bring the cluster back by removing the flag, and then recreate every Secret from source.

```bash
# On each control plane node, remove the encryption flag and mount.
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
# delete --encryption-provider-config, the volumeMount and the volume

# The API server starts. Encrypted secrets now fail to decode:
kubectl get secrets -A
# Error ... unable to transform key ... no matching prefix found
```

Delete and recreate them from your source of truth. This is why Secrets should be reproducible from an external system (a secrets manager, sealed secrets in git) rather than existing only in the cluster.

### Scenario: Restoring an Encrypted Snapshot to a New Cluster

The new cluster's API servers need the **same** `EncryptionConfiguration` before the restore is usable.

```bash
# 1. Place the ORIGINAL encryption config on the new control plane node
#    with identical key names and key material.
# 2. Restore the snapshot.
sudo ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-snapshot.db \
  --data-dir=/var/lib/etcd-restored
# 3. Point etcd at the restored data directory and start it.
# 4. Only then will the API server decrypt successfully.
```

Key names must match exactly. The stored prefix contains the key name, and the API server looks it up by that name.

See [etcd-backup-restore.md](etcd-backup-restore.md) and [disaster-recovery.md](disaster-recovery.md).

---

## Recipes

### Recipe: One-Shot Enablement on a Single Control Plane Cluster

```bash
#!/usr/bin/env bash
set -euo pipefail

ENC_DIR=/etc/kubernetes/enc
CFG="$ENC_DIR/encryption-config.yaml"
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
KEY_NAME="key-$(date +%Y%m%d)"

echo "== generating key"
KEY=$(head -c 32 /dev/urandom | base64)

echo "== writing $CFG"
sudo mkdir -p "$ENC_DIR" && sudo chmod 700 "$ENC_DIR"
sudo tee "$CFG" >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: ${KEY_NAME}
              secret: ${KEY}
      - identity: {}
EOF
sudo chmod 600 "$CFG"

echo
echo "!!! BACK THIS UP OFF THE NODE BEFORE CONTINUING !!!"
echo "key name: ${KEY_NAME}"
echo "key:      ${KEY}"
echo
read -rp "Backed up? type yes to continue: " ok
[[ "$ok" == "yes" ]] || exit 1

echo "== backing up the apiserver manifest"
sudo cp "$MANIFEST" "/root/kube-apiserver.yaml.$(date +%s).bak"

echo "== now edit $MANIFEST by hand:"
cat <<'EOF'
  add to command:
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
    - --encryption-provider-config-automatic-reload=true
  add to volumeMounts:
    - name: enc
      mountPath: /etc/kubernetes/enc
      readOnly: true
  add to volumes:
    - name: enc
      hostPath:
        path: /etc/kubernetes/enc
        type: DirectoryOrCreate
EOF
```

### Recipe: Continuous Verification as a CronJob

Catch a silent regression, for example someone reverting the manifest during an upgrade.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: encryption-canary
  namespace: kube-system
spec:
  schedule: "0 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: encryption-canary
          restartPolicy: OnFailure
          # Control plane only, since it needs etcd access.
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
          hostNetwork: true
          containers:
            - name: check
              image: registry.k8s.io/etcd:3.5.15-0
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  KEY=/registry/secrets/kube-system/encryption-canary
                  OUT=$(ETCDCTL_API=3 etcdctl \
                    --endpoints=https://127.0.0.1:2379 \
                    --cacert=/pki/ca.crt \
                    --cert=/pki/server.crt \
                    --key=/pki/server.key \
                    get "$KEY")
                  if echo "$OUT" | grep -q 'k8s:enc:'; then
                    echo "OK: canary secret is encrypted at rest"
                  else
                    echo "ALERT: canary secret is PLAINTEXT in etcd"
                    exit 1
                  fi
              volumeMounts:
                - name: pki
                  mountPath: /pki
                  readOnly: true
          volumes:
            - name: pki
              hostPath:
                path: /etc/kubernetes/pki/etcd
                type: Directory
```

Create the canary Secret it checks:

```bash
kubectl -n kube-system create secret generic encryption-canary \
  --from-literal=canary=please-encrypt-me
```

### Recipe: Decommissioning Encryption

Sometimes you need to reverse it, for example before handing a cluster to a team without key custody.

```yaml
# 1. identity first, so new writes are plaintext.
providers:
  - identity: {}
  - aescbc:
      keys:
        - name: key-202601
          secret: <key>
```

```bash
# 2. Rewrite everything to plaintext.
kubectl get secrets -A -o json | kubectl replace -f -

# 3. Verify nothing is still encrypted.
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets --prefix | grep -c 'k8s:enc:'
# 0

# 4. Only now remove the flag and the config file.
```

---

## Command Reference

```bash
# ---------- Key generation ----------
head -c 32 /dev/urandom | base64
openssl rand -base64 32
echo -n "$KEY" | base64 -d | wc -c        # must print 32

# ---------- etcd direct reads ----------
E="--endpoints=https://127.0.0.1:2379"
C="--cacert=/etc/kubernetes/pki/etcd/ca.crt"
CE="--cert=/etc/kubernetes/pki/etcd/server.crt"
K="--key=/etc/kubernetes/pki/etcd/server.key"

sudo ETCDCTL_API=3 etcdctl $E $C $CE $K get /registry/secrets/NS/NAME | hexdump -C
sudo ETCDCTL_API=3 etcdctl $E $C $CE $K get /registry/secrets --prefix --keys-only
sudo ETCDCTL_API=3 etcdctl $E $C $CE $K get /registry --prefix --keys-only | wc -l

# ---------- Configuration ----------
sudo cat /etc/kubernetes/enc/encryption-config.yaml
sudo grep encryption /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl -n kube-system get pod -l component=kube-apiserver \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep enc

# ---------- Rewrite ----------
kubectl get secrets -A -o json | kubectl replace -f -
kubectl get configmaps -A -o json | kubectl replace -f -
kubectl -n NS get secrets -o json | kubectl replace -f -

# ---------- Metrics ----------
kubectl get --raw /metrics | grep encryption_config_controller
kubectl get --raw /metrics | grep envelope_encryption
kubectl get --raw /metrics | grep storage_transformation

# ---------- Health ----------
kubectl get --raw /healthz
kubectl get --raw '/healthz?verbose' | grep -i etcd
```

---

## Troubleshooting

### API Server Will Not Start After Enabling

`kubectl` stops responding entirely because the API server is a static pod that is now crashlooping. Diagnose from the node.

```bash
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -40
sudo journalctl -u kubelet -n 100 --no-pager
```

The four causes, in order of frequency:

**1. The config file is not mounted into the pod.**

```
error: error while parsing file: open /etc/kubernetes/enc/encryption-config.yaml:
no such file or directory
```

You added the flag but not the `volume` and `volumeMount`. Add both.

**2. The key is not 32 bytes.**

```
error: --encryption-provider-config error: aescbc: expected key size 32,
got 24
```

Regenerate with `head -c 32 /dev/urandom | base64`.

**3. The base64 is malformed.**

Usually a stray newline from a copy-paste, or the key was wrapped across lines by an editor.

```bash
# Check it decodes cleanly
sudo grep 'secret:' /etc/kubernetes/enc/encryption-config.yaml | \
  awk '{print $2}' | base64 -d | wc -c
```

**4. Wrong `apiVersion` or `kind`.**

It is `apiserver.config.k8s.io/v1` and `EncryptionConfiguration`. Older documentation shows `v1beta1`, which is no longer accepted in current releases.

**Recovery** in all cases: restore the manifest backup.

```bash
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
until kubectl get --raw /healthz 2>/dev/null; do sleep 2; done; echo
```

If you have no backup, simply remove the encryption flag, volume and mount by hand. The cluster returns to its previous state.

### `no matching prefix found`

```
Error from server (InternalError): Internal error occurred:
unable to transform key "/registry/secrets/prod/db": no matching prefix found
```

The object in etcd was encrypted with a key or provider that is no longer in the configuration. Causes:

- A key was removed before the data was rewritten.
- The key `name` was changed while the material stayed the same, or vice versa.
- A snapshot was restored into a cluster with a different config.

The fix is to restore the missing key to the configuration, using its **exact original name**. If the key material is genuinely lost, those objects are unrecoverable and must be recreated.

Identify which key an object needs:

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/prod/db | grep -ao 'k8s:enc:[a-z0-9]*:v[0-9]*:[^:]*:'
# k8s:enc:aescbc:v1:key-202601:
```

That name is what must appear in the config.

### Some Secrets Encrypted, Some Not

Expected until you rewrite. Encryption applies to writes only.

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

### `kubectl replace` Fails for Some Secrets

```
Error from server (Invalid): Secret "sa-token-abc" is invalid:
data: Forbidden: field is immutable
```

Either the Secret is `immutable: true`, or it is a controller-managed service account token. For immutable Secrets, delete and recreate. For legacy SA token Secrets, they are safe to skip, and on a modern cluster they should not exist at all.

```bash
# Find legacy SA token secrets, which modern clusters do not need.
kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token
```

### Performance Degraded After Enabling

Measure rather than guess:

```bash
kubectl get --raw /metrics | grep storage_transformation_duration_seconds
kubectl get --raw /metrics | grep etcd_request_duration_seconds
```

If you enabled `'*.*'`, high-churn resources like `leases` and `events` are now being encrypted on every write, which is a lot of work for very little security value. Narrow the scope to `secrets` and `configmaps`.

For KMS, check the DEK cache:

```bash
kubectl get --raw /metrics | grep envelope_encryption_dek_cache
```

A low fill percentage means DEKs are being evicted and every write is hitting the KMS.

### Automatic Reload Is Not Picking Up Changes

```bash
kubectl get --raw /metrics | \
  grep apiserver_encryption_config_controller_automatic_reload_failure_total
```

Non-zero means the file was rejected. Validate the YAML and re-check the key length. Also confirm the flag is actually set:

```bash
sudo grep automatic-reload /etc/kubernetes/manifests/kube-apiserver.yaml
```

Note that on some setups the file is bind-mounted in a way that hides `inotify` events; if reload never works, fall back to restarting the API server by briefly moving its manifest out of the directory.

---

## Exam and Interview Traps

1. **Are Kubernetes Secrets encrypted by default?** No. They are base64 encoded, which is an encoding, not encryption. Storage is plaintext unless you configure encryption at rest.

2. **Which provider encrypts writes?** The first in the list. All providers are tried on read.

3. **How do you disable encryption without losing data?** Put `identity` first, rewrite all objects, then remove the encryption provider.

4. **Does enabling encryption encrypt existing Secrets?** No. You must rewrite them: `kubectl get secrets -A -o json | kubectl replace -f -`.

5. **What is the correct key length?** 32 bytes of random data, base64 encoded, for `aescbc`, `aesgcm` and `secretbox`.

6. **Why must the new key go second during rotation?** So every API server can decrypt data written by any other one before any of them starts using the new key. Skipping this breaks reads on an HA cluster.

7. **What happens if you delete a key that still protects live data?** Those objects become permanently unreadable. There is no recovery without the key.

8. **Why avoid `aesgcm`?** Its security requires frequent key rotation because of nonce constraints. Without automation you will eventually exceed safe usage.

9. **Does encryption at rest stop a user with RBAC `get` on secrets?** No. The API server decrypts transparently on read. It protects the storage layer only.

10. **What does the stored prefix look like?** `k8s:enc:<provider>:v1:<keyname>:` followed by ciphertext. Unencrypted objects begin with the `k8s` magic bytes and no `:enc:`.

11. **KMS v1 versus v2?** v1 calls the KMS on every encryption. v2 uses envelope encryption with a cached DEK, tracks a key ID, and is the current recommendation. v1 is deprecated.

12. **What must be true to restore an encrypted etcd snapshot elsewhere?** The target cluster needs the identical `EncryptionConfiguration`, with matching key names and key material.

13. **Where is the config file, and is it an API object?** A file on each control plane node, referenced by `--encryption-provider-config`. It is not an API object and cannot be managed with `kubectl`.

14. **What is the most common reason the API server will not start after enabling?** The flag was added but the `hostPath` volume and `volumeMount` were not.

---

## Related Topics

- [secrets.md](secrets.md) for the Secret object itself and safer alternatives
- [etcd.md](etcd.md) for how the datastore works
- [etcd-backup-restore.md](etcd-backup-restore.md) for snapshots, which contain this data
- [disaster-recovery.md](disaster-recovery.md) for the wider recovery picture
- [rbac.md](rbac.md) for controlling who may read Secrets through the API
- [audit-logging.md](audit-logging.md) for recording who reads them
- [cluster-hardening.md](cluster-hardening.md) for the overall posture
- [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md) for editing static pod manifests safely
- [kube-apiserver.md](kube-apiserver.md) for the component doing the encryption
- [service-accounts.md](service-accounts.md) for reducing how many pods carry credentials at all

---

## Key Takeaways

- Secrets are stored base64 encoded, not encrypted. Prove it once with `etcdctl` and the lesson sticks.
- Encryption at rest protects snapshots, backups and disks. It does nothing against an authorized API caller.
- The first provider in the list encrypts; all providers are tried for decryption. That single rule explains enablement, rotation and decommissioning.
- Enabling encryption does not touch existing data. You must rewrite every object.
- Keys are 32 random bytes, base64 encoded. Never derived from a passphrase.
- The flag alone is not enough on kubeadm: the `hostPath` volume and `volumeMount` are mandatory, and omitting them stops the API server from starting.
- Rotation is four phases: add second, promote to first, rewrite, remove old. Never skip the first phase on an HA cluster.
- Removing a key before rewriting destroys the data it protected. Permanently.
- Prefer KMS v2 where a key manager exists, since the key never touches the node's disk.
- Back the key up off the cluster, off the backups, in multiple places. It is now a total-loss single point of failure.
- Verify continuously. A cluster upgrade that reverts the API server manifest silently turns encryption off.

---

## References

- [Encrypting Confidential Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Using a KMS Provider for Data Encryption](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [EncryptionConfiguration API Reference](https://kubernetes.io/docs/reference/config-api/apiserver-encryption.v1/)
- [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Good Practices for Kubernetes Secrets](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
- [Operating etcd Clusters for Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
- [kube-apiserver Command Line Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
