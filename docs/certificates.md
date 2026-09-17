# 🔑 Kubernetes Certificates: The PKI That Holds the Cluster Together

Kubernetes is a mutual TLS system from top to bottom. Every component proves its identity with an X.509 certificate, and the certificate's subject *is* the identity: the Common Name becomes the username, the Organization becomes the group. This document walks the entire kubeadm PKI tree file by file, shows which component presents which certificate to which peer, covers renewal and SAN changes, the CertificateSigningRequest API, kubelet bootstrapping and rotation, and how to recover when everything has expired and the cluster will not start.

## 📋 Table of Contents
- [Why Certificates Are Identity](#why-certificates-are-identity)
- [The PKI Tree](#the-pki-tree)
- [The Certificate Authorities](#the-certificate-authorities)
- [Every File Explained](#every-file-explained)
- [The Service Account Keypair](#the-service-account-keypair)
- [Who Presents What to Whom](#who-presents-what-to-whom)
- [Reading a Certificate](#reading-a-certificate)
- [Expiry and Renewal](#expiry-and-renewal)
- [Adding a SAN to the API Server](#adding-a-san-to-the-api-server)
- [The CertificateSigningRequest API](#the-certificatesigningrequest-api)
- [Creating a Human User End to End](#creating-a-human-user-end-to-end)
- [Kubelet Bootstrapping](#kubelet-bootstrapping)
- [Kubelet Certificate Rotation](#kubelet-certificate-rotation)
- [Expiry Disaster Recovery](#expiry-disaster-recovery)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why Certificates Are Identity

In most systems a certificate proves you are talking to the right server. In Kubernetes it does that **and** carries the client's identity into the authorization layer.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  A CLIENT CERTIFICATE SUBJECT                                        │
   │                                                                      │
   │     subject= O = system:masters, CN = kubernetes-admin               │
   │              │                        │                              │
   │              │                        └─► becomes the USERNAME       │
   │              └─► becomes a GROUP                                     │
   │                                                                      │
   │  The API server reads these fields after validating the chain,       │
   │  builds a user.Info, and hands it to the authorizer.                 │
   └──────────────────────────────────────────────────────────────────────┘
```

Three consequences that matter enormously:

**There is no user database.** Kubernetes has no `User` object. A user exists because a certificate signed by the cluster CA says so. Creating a user means issuing a certificate; there is nothing else to create.

**You cannot revoke a certificate.** Kubernetes does not check certificate revocation lists or OCSP. A leaked client certificate is valid until it expires. The only real remedies are to wait it out, remove the RBAC bindings that give it power, or rotate the entire CA.

**`O = system:masters` is a cluster takeover.** That group bypasses RBAC entirely in code. Anyone who can sign a certificate with that Organization owns the cluster, permanently, with no way to revoke it. This is why the CA private key is the single most sensitive file in Kubernetes.

```bash
# The file that is functionally the root password of your cluster.
sudo ls -l /etc/kubernetes/pki/ca.key
# -rw------- 1 root root 1679 ... /etc/kubernetes/pki/ca.key
```

---

## The PKI Tree

Everything kubeadm generates lives under `/etc/kubernetes/pki`. There are **three independent CAs**, which is a detail people routinely miss.

```
/etc/kubernetes/pki/
│
├── ca.crt                      ┐  CLUSTER CA
├── ca.key                      ┘  signs everything in the main cluster
│   │
│   ├── apiserver.crt/.key             API server's SERVING cert
│   │                                  presented to kubectl, kubelets, everyone
│   │
│   ├── apiserver-kubelet-client.crt/.key
│   │                                  API server as a CLIENT to kubelets
│   │                                  (logs, exec, port-forward)
│   │
│   └── (signs, via the CSR API)
│       ├── kubelet client certs       each node's identity
│       ├── kubelet serving certs      each node's HTTPS endpoint
│       ├── admin.conf credential      kubernetes-admin
│       ├── super-admin.conf cred.     system:masters break-glass
│       ├── controller-manager.conf
│       └── scheduler.conf
│
├── front-proxy-ca.crt          ┐  FRONT PROXY CA
├── front-proxy-ca.key          ┘  a SEPARATE trust root for the
│   │                              aggregation layer
│   └── front-proxy-client.crt/.key
│                                   API server as a client to
│                                   aggregated/extension API servers
│
├── etcd/
│   ├── ca.crt                  ┐  ETCD CA
│   ├── ca.key                  ┘  a SEPARATE trust root for etcd
│   │   │
│   │   ├── server.crt/.key            etcd's serving cert (client + peer)
│   │   ├── peer.crt/.key              etcd-to-etcd in an HA cluster
│   │   └── healthcheck-client.crt/.key  liveness probe client
│   │
│   └── (apiserver-etcd-client below is also signed by this CA)
│
├── apiserver-etcd-client.crt/.key
│                                   API server as a CLIENT to etcd
│                                   NOTE: signed by the ETCD CA, not the
│                                   cluster CA, despite living at the top level
│
├── sa.key                      ┐  SERVICE ACCOUNT KEYPAIR
└── sa.pub                      ┘  NOT a certificate. A raw RSA keypair
                                   used to sign and verify SA JWTs
```

### Why Three CAs

Separation of trust domains. If the cluster CA is compromised, the attacker cannot yet forge an etcd client certificate and read the datastore directly. If the front-proxy CA leaks, they cannot impersonate the API server to kubelets.

```
   ┌──────────────────┬────────────────────────────────────────────────────┐
   │ CA               │ Trust domain                                       │
   ├──────────────────┼────────────────────────────────────────────────────┤
   │ ca               │ The cluster itself: API server, kubelets, users,   │
   │                  │ controller-manager, scheduler                      │
   ├──────────────────┼────────────────────────────────────────────────────┤
   │ etcd/ca          │ The datastore. Only the API server and etcd        │
   │                  │ members should hold certificates from it           │
   ├──────────────────┼────────────────────────────────────────────────────┤
   │ front-proxy-ca   │ The aggregation layer. Lets an extension API       │
   │                  │ server trust identity headers from the API server  │
   └──────────────────┴────────────────────────────────────────────────────┘
```

---

## The Certificate Authorities

```bash
# Cluster CA, ten year validity by default
sudo openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -subject -dates
# subject=CN = kubernetes
# notBefore=... notAfter=... (+10 years)
```

All three CAs are self-signed and valid for ten years. The **leaf** certificates they sign are valid for **one year**, which is the source of the classic "my cluster stopped working after a year" incident.

```
   CA certificates       ████████████████████████████████  10 years
   Leaf certificates     ███                                1 year
                             ▲
                             └─ renew before here, or the cluster stops
```

kubeadm renews leaf certificates automatically on every `kubeadm upgrade`, which is why clusters that are upgraded regularly never hit this. Clusters left alone for a year do.

---

## Every File Explained

### Cluster CA Leaves

**`apiserver.crt` / `apiserver.key`**

The API server's serving certificate. The critical part is its Subject Alternative Name list, which must contain every name and address any client will use to reach it.

```bash
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text \
  | grep -A 2 'Subject Alternative Name'
```

```
X509v3 Subject Alternative Name:
    DNS:cp-01, DNS:kubernetes, DNS:kubernetes.default,
    DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local,
    DNS:api.example.internal,
    IP Address:10.96.0.1, IP Address:192.168.1.10
```

`10.96.0.1` is the in-cluster `kubernetes` Service IP, which is how pods reach the API. `192.168.1.10` is the node address. Any missing name produces a TLS hostname mismatch for clients using it.

**`apiserver-kubelet-client.crt` / `.key`**

The API server acting as a *client* when it calls a kubelet, which happens on `kubectl logs`, `exec`, `attach` and `port-forward`.

```bash
sudo openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt \
  -noout -subject
# subject=O = system:masters, CN = kube-apiserver-kubelet-client
```

Note the `system:masters` group. The API server has full authority over kubelets by design.

**`front-proxy-client.crt` / `.key`**

Used when the API server proxies a request to an aggregated API server (metrics-server, custom APIs). The extension server validates this certificate against `front-proxy-ca.crt` and then trusts the identity headers (`X-Remote-User`, `X-Remote-Group`) the API server attached.

```bash
sudo openssl x509 -in /etc/kubernetes/pki/front-proxy-client.crt -noout -subject
# subject=CN = front-proxy-client
```

Without this, aggregated APIs cannot authenticate the caller and `kubectl top` fails. See [api-aggregation.md](api-aggregation.md).

### etcd CA Leaves

**`etcd/server.crt` / `.key`** is etcd's serving certificate, presented to the API server and to healthchecks.

**`etcd/peer.crt` / `.key`** is used for etcd member to member traffic in an HA cluster. It is both a client and server certificate, since peer connections go both ways.

**`etcd/healthcheck-client.crt` / `.key`** is used by the etcd static pod's own liveness probe.

**`apiserver-etcd-client.crt` / `.key`** is the API server's client certificate for etcd. It lives in the top-level directory but is signed by the **etcd** CA, which is a common point of confusion.

```bash
sudo openssl x509 -in /etc/kubernetes/pki/apiserver-etcd-client.crt \
  -noout -subject -issuer
# subject=O = system:masters, CN = kube-apiserver-etcd-client
# issuer=CN = etcd-ca              ← note: etcd-ca, not kubernetes
```

---

## The Service Account Keypair

`sa.key` and `sa.pub` are **not certificates**. They are a bare RSA keypair with no subject, no validity period and no CA.

```bash
# This fails, because it is not an X.509 certificate.
sudo openssl x509 -in /etc/kubernetes/pki/sa.pub -noout -text
# unable to load certificate

# This works.
sudo openssl rsa -in /etc/kubernetes/pki/sa.pub -pubin -noout -text
```

Their job:

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  kube-controller-manager  ──uses sa.key──►  SIGNS service account    │
   │                                             JWT tokens               │
   │                                                                      │
   │  kube-apiserver           ──uses sa.pub──►  VERIFIES those tokens    │
   └──────────────────────────────────────────────────────────────────────┘
```

Two operational consequences:

**They never expire.** There is no validity period, so they are not part of the annual renewal cycle and `kubeadm certs check-expiration` does not list them.

**They must be identical across all control plane nodes.** A token signed by cp-01 must verify on cp-02. If the keypairs differ, service account authentication fails intermittently depending on which API server you reach, which is a maddening symptom to debug.

```bash
# Verify all control plane nodes share the same key.
sudo openssl rsa -in /etc/kubernetes/pki/sa.key -noout -modulus | sha256sum
# Run on every control plane node; the hashes must match.
```

Rotating `sa.key` invalidates every existing service account token in the cluster simultaneously, so it requires restarting every pod that holds one.

---

## Who Presents What to Whom

The matrix that makes the whole system click.

| Connection | Client presents | Validated against | Server presents | Validated against |
|---|---|---|---|---|
| kubectl → API server | user cert from kubeconfig | `ca.crt` | `apiserver.crt` | `ca.crt` (embedded in kubeconfig) |
| kubelet → API server | `kubelet-client-current.pem` | `ca.crt` | `apiserver.crt` | `ca.crt` |
| API server → kubelet | `apiserver-kubelet-client.crt` | kubelet's `ca.crt` | kubelet serving cert | `ca.crt` (if `--kubelet-certificate-authority` set) |
| API server → etcd | `apiserver-etcd-client.crt` | `etcd/ca.crt` | `etcd/server.crt` | `etcd/ca.crt` |
| etcd → etcd (peer) | `etcd/peer.crt` | `etcd/ca.crt` | `etcd/peer.crt` | `etcd/ca.crt` |
| API server → aggregated API | `front-proxy-client.crt` | `front-proxy-ca.crt` | extension's serving cert | `ca.crt` or provided bundle |
| controller-manager → API server | cert in `controller-manager.conf` | `ca.crt` | `apiserver.crt` | `ca.crt` |
| scheduler → API server | cert in `scheduler.conf` | `ca.crt` | `apiserver.crt` | `ca.crt` |

Notice the third row. By default the API server does **not** verify the kubelet's serving certificate, because kubelet serving certificates are often self-signed. Setting `--kubelet-certificate-authority` closes a real man-in-the-middle gap and is a CIS benchmark item.

---

## Reading a Certificate

The commands worth committing to muscle memory.

```bash
# Everything
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text

# Just the identity
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -issuer

# Just the validity window
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates

# Just the SANs
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName

# Is it expired? (silent = still valid)
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -checkend 0

# Will it expire in the next 30 days?
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -checkend 2592000 \
  || echo "expires within 30 days"

# What it is allowed to be used for
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext extendedKeyUsage
```

Extended Key Usage matters more than people expect:

```
   TLS Web Server Authentication    ── may act as a SERVER
   TLS Web Client Authentication    ── may act as a CLIENT
```

A certificate with only server auth cannot be used as a client credential, and vice versa. This is a frequent cause of "the certificate looks fine but authentication fails".

Inspect a certificate embedded in a kubeconfig:

```bash
sudo grep 'client-certificate-data' /etc/kubernetes/admin.conf \
  | awk '{print $2}' | base64 -d | openssl x509 -noout -subject -dates
```

Inspect what a live server presents:

```bash
openssl s_client -connect 192.168.1.10:6443 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates -ext subjectAltName
```

---

## Expiry and Renewal

### Checking

```bash
sudo kubeadm certs check-expiration
```

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
admin.conf                 Jan 15, 2027 08:12 UTC   351d            no
apiserver                  Jan 15, 2027 08:12 UTC   351d            no
apiserver-etcd-client      Jan 15, 2027 08:12 UTC   351d            no
apiserver-kubelet-client   Jan 15, 2027 08:12 UTC   351d            no
controller-manager.conf    Jan 15, 2027 08:12 UTC   351d            no
etcd-healthcheck-client    Jan 15, 2027 08:12 UTC   351d            no
etcd-peer                  Jan 15, 2027 08:12 UTC   351d            no
etcd-server                Jan 15, 2027 08:12 UTC   351d            no
front-proxy-client         Jan 15, 2027 08:12 UTC   351d            no
scheduler.conf             Jan 15, 2027 08:12 UTC   351d            no

CERTIFICATE AUTHORITY      EXPIRES                  RESIDUAL TIME
ca                         Jan 13, 2036 08:12 UTC   9y
etcd-ca                    Jan 13, 2036 08:12 UTC   9y
front-proxy-ca             Jan 13, 2036 08:12 UTC   9y
```

Note what is **absent** from this list: the kubelet's own client certificate. Kubelets manage their own via rotation and the CSR API, so `kubeadm` does not track them.

### Renewing

```bash
# Everything at once. The normal choice.
sudo kubeadm certs renew all

# Or one at a time
sudo kubeadm certs renew apiserver
sudo kubeadm certs renew admin.conf
```

Renewal rewrites the certificate files on disk but **does not restart anything**. The control plane components only read their certificates at startup, so they continue using the old ones until restarted.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  kubeadm certs renew all                                             │
   │        │                                                             │
   │        ▼  new certs written to /etc/kubernetes/pki                   │
   │        │                                                             │
   │        │  BUT the running processes still hold the OLD ones in       │
   │        │  memory. You are not done.                                   │
   │        ▼                                                             │
   │  restart the static pods                                             │
   └──────────────────────────────────────────────────────────────────────┘
```

The restart, on a control plane node:

```bash
# Move the manifests out, wait, move them back. The kubelet stops the
# pods when the files disappear and starts them when they reappear.
cd /etc/kubernetes/manifests
sudo mkdir -p /tmp/k8s-manifests
sudo mv kube-apiserver.yaml kube-controller-manager.yaml \
        kube-scheduler.yaml etcd.yaml /tmp/k8s-manifests/

sleep 20

sudo mv /tmp/k8s-manifests/*.yaml /etc/kubernetes/manifests/

# Wait for the API to return
until kubectl get --raw /healthz 2>/dev/null; do sleep 3; done; echo
```

A gentler alternative if `crictl` is available:

```bash
# Kill the containers; the kubelet recreates them from the unchanged manifests.
for c in kube-apiserver kube-controller-manager kube-scheduler etcd; do
  sudo crictl ps --name "$c" -q | xargs -r sudo crictl stop
done
```

Finally, refresh your own kubeconfig, because `admin.conf` was regenerated:

```bash
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

### On an HA Cluster

Renew and restart **one node at a time**, confirming each returns to health before moving on. Renewal is per node; the files are not shared.

```bash
for node in cp-01 cp-02 cp-03; do
  echo "== $node"
  ssh "$node" 'sudo kubeadm certs renew all'
  ssh "$node" 'cd /etc/kubernetes/manifests && \
    sudo mkdir -p /tmp/m && sudo mv *.yaml /tmp/m/ && sleep 20 && \
    sudo mv /tmp/m/*.yaml /etc/kubernetes/manifests/'
  until kubectl get --raw /healthz >/dev/null 2>&1; do sleep 3; done
  sleep 30
done
```

---

## Adding a SAN to the API Server

A real task the first time you put a load balancer in front of the control plane, or give it a DNS name.

The symptom:

```
Unable to connect to the server: x509: certificate is valid for
kubernetes, kubernetes.default, 10.96.0.1, 192.168.1.10,
not api.example.internal
```

The certificate cannot be edited. It must be regenerated with the new SAN included.

### Step 1: Declare the Name in the Cluster Configuration

kubeadm stores its configuration in a ConfigMap, and reads it when regenerating certificates.

```bash
kubectl -n kube-system get configmap kubeadm-config -o yaml > kubeadm-config.yaml
```

Edit the embedded `ClusterConfiguration`:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.31.2
controlPlaneEndpoint: api.example.internal:6443
apiServer:
  certSANs:
    - api.example.internal          # the new DNS name
    - 192.168.1.100                 # the load balancer VIP
    - kubernetes.example.internal
```

Apply it back:

```bash
kubectl -n kube-system apply -f kubeadm-config.yaml
```

### Step 2: Regenerate the Certificate

The old files must be moved aside; kubeadm will not overwrite an existing certificate.

```bash
sudo mv /etc/kubernetes/pki/apiserver.crt /root/apiserver.crt.bak
sudo mv /etc/kubernetes/pki/apiserver.key /root/apiserver.key.bak

sudo kubeadm init phase certs apiserver \
  --config <(kubectl -n kube-system get cm kubeadm-config \
             -o jsonpath='{.data.ClusterConfiguration}')
```

### Step 3: Verify and Restart

```bash
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
# confirm the new names are present

# Restart the API server
cd /etc/kubernetes/manifests
sudo mv kube-apiserver.yaml /tmp/ && sleep 15 && sudo mv /tmp/kube-apiserver.yaml .
until kubectl get --raw /healthz 2>/dev/null; do sleep 3; done; echo
```

Repeat on every control plane node.

---

## The CertificateSigningRequest API

Kubernetes exposes certificate signing as an API, which is how kubelets bootstrap and how you should issue user certificates.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  1. Client generates a private key and a CSR locally.                │
   │        The private key NEVER leaves the client.                       │
   │  2. Client submits the CSR to the API as a                            │
   │        CertificateSigningRequest object.                              │
   │  3. Someone with `approve` permission approves it.                    │
   │  4. A signer (usually kube-controller-manager) signs it.              │
   │  5. The signed certificate appears in status.certificate.             │
   └──────────────────────────────────────────────────────────────────────┘
```

### The Object

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice-csr
spec:
  # base64 of the PEM CSR. Note: base64 of the PEM, not of the DER.
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNU...

  # Which signer should handle this. Determines validation rules,
  # permitted usages, and who may approve.
  signerName: kubernetes.io/kube-apiserver-client

  # Optional. Requested lifetime in seconds. The signer may honour or
  # ignore it. 86400 = 1 day, 31536000 = 1 year.
  expirationSeconds: 31536000

  usages:
    - client auth
```

### The Signers

| `signerName` | Purpose | Auto-approved? |
|---|---|---|
| `kubernetes.io/kube-apiserver-client` | General client certificates for users and components | No, manual approval |
| `kubernetes.io/kube-apiserver-client-kubelet` | Kubelet **client** certificates during bootstrap | Yes, by the CSR approver controller |
| `kubernetes.io/kubelet-serving` | Kubelet **serving** certificates | **No.** Requires manual approval or a third party controller |
| `kubernetes.io/legacy-unknown` | Legacy. Not signed by the built-in signer in current releases | No |

The `kubelet-serving` row is the source of a classic operational surprise, covered below.

### Approving

```bash
kubectl get csr
# NAME        AGE   SIGNERNAME                              REQUESTOR        CONDITION
# alice-csr   10s   kubernetes.io/kube-apiserver-client     kubernetes-admin Pending

kubectl certificate approve alice-csr
kubectl certificate deny bad-csr

# Extract the signed certificate
kubectl get csr alice-csr -o jsonpath='{.status.certificate}' \
  | base64 -d > alice.crt
```

Approval is itself an RBAC-controlled action, scoped per signer:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: csr-approver
rules:
  - apiGroups: ["certificates.k8s.io"]
    resources: ["certificatesigningrequests"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["certificates.k8s.io"]
    resources: ["certificatesigningrequests/approval"]
    verbs: ["update"]
  # The approve permission is scoped to a SPECIFIC signer by resourceName.
  - apiGroups: ["certificates.k8s.io"]
    resources: ["signers"]
    resourceNames: ["kubernetes.io/kube-apiserver-client"]
    verbs: ["approve"]
```

The `CertificateSubjectRestriction` admission controller blocks any CSR requesting `O = system:masters`, which closes the obvious escalation path through this API.

---

## Creating a Human User End to End

There is no `kubectl create user`. Here is what actually creates one.

### Step 1: Generate a Key and CSR

Done by the user, on their own machine. The private key must never be transmitted.

```bash
# Private key
openssl genrsa -out alice.key 2048

# CSR. CN becomes the username, O becomes the group.
openssl req -new -key alice.key -out alice.csr \
  -subj "/CN=alice/O=developers"

# Sanity check before submitting
openssl req -in alice.csr -noout -subject
# subject=CN = alice, O = developers
```

### Step 2: Submit It

```bash
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: $(base64 -w0 < alice.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
    - client auth
EOF
```

`base64 -w0` disables line wrapping. Without it the field is invalid and the CSR is rejected with an unhelpful parse error.

### Step 3: Approve and Retrieve

```bash
kubectl certificate approve alice
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
openssl x509 -in alice.crt -noout -subject -dates
```

### Step 4: Grant Permissions

The certificate authenticates. It grants nothing on its own.

```bash
kubectl create namespace dev

kubectl create role developer \
  --namespace dev \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,deployments,services,configmaps

kubectl create rolebinding alice-developer \
  --namespace dev \
  --role=developer \
  --user=alice
```

### Step 5: Build the kubeconfig

```bash
CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

kubectl config set-cluster "$CLUSTER" \
  --server="$SERVER" \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=alice.kubeconfig

kubectl config set-credentials alice \
  --client-certificate=alice.crt \
  --client-key=alice.key \
  --embed-certs=true \
  --kubeconfig=alice.kubeconfig

kubectl config set-context alice \
  --cluster="$CLUSTER" \
  --user=alice \
  --namespace=dev \
  --kubeconfig=alice.kubeconfig

kubectl config use-context alice --kubeconfig=alice.kubeconfig
```

### Step 6: Verify

```bash
KUBECONFIG=alice.kubeconfig kubectl auth whoami
# Username  alice
# Groups    [developers system:authenticated]

KUBECONFIG=alice.kubeconfig kubectl auth can-i --list -n dev
KUBECONFIG=alice.kubeconfig kubectl get pods -n dev          # works
KUBECONFIG=alice.kubeconfig kubectl get pods -n kube-system  # Forbidden
```

**Remember there is no revocation.** If Alice leaves, delete the RoleBindings. The certificate remains cryptographically valid until it expires, so short `expirationSeconds` values are a genuine security control. For real organisations, OIDC is a better answer than certificates precisely because it supports revocation. See [authentication.md](authentication.md).

---

## Kubelet Bootstrapping

A brand new node has no credentials but needs a client certificate to join. The chicken-and-egg problem is solved with a short-lived bootstrap token.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  1. `kubeadm join` receives a bootstrap token.                       │
   │                                                                      │
   │  2. kubelet writes /etc/kubernetes/bootstrap-kubelet.conf using      │
   │     that token as its credential. The token maps to the group        │
   │     system:bootstrappers:kubeadm:default-node-token.                 │
   │                                                                      │
   │  3. kubelet generates a keypair and submits a CSR with               │
   │     signerName kubernetes.io/kube-apiserver-client-kubelet           │
   │     and subject O=system:nodes, CN=system:node:<nodename>.           │
   │                                                                      │
   │  4. The csrapproving controller AUTO-APPROVES it, because the        │
   │     requester is in the bootstrappers group and the subject          │
   │     matches the expected node form.                                  │
   │                                                                      │
   │  5. kube-controller-manager signs it with ca.key.                    │
   │                                                                      │
   │  6. kubelet writes /etc/kubernetes/kubelet.conf pointing at          │
   │     /var/lib/kubelet/pki/kubelet-client-current.pem and DELETES      │
   │     the bootstrap kubeconfig.                                        │
   └──────────────────────────────────────────────────────────────────────┘
```

Observe it happening:

```bash
# On the control plane, while a node joins
kubectl get csr -w

# NAME        SIGNERNAME                                      REQUESTOR                 CONDITION
# csr-x7k2p   kubernetes.io/kube-apiserver-client-kubelet     system:bootstrap:abcdef   Approved,Issued
```

Managing bootstrap tokens:

```bash
sudo kubeadm token list
sudo kubeadm token create --print-join-command
sudo kubeadm token create --ttl 1h --print-join-command
sudo kubeadm token delete <token>
```

Tokens default to 24 hour validity. A token is a credential that lets anyone join a node to your cluster, so treat it accordingly and prefer short TTLs.

---

## Kubelet Certificate Rotation

Two separate certificates with very different behaviour.

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# CLIENT certificate rotation: the kubelet's identity to the API server.
# Auto-approved by the csrapproving controller. Just works.
rotateCertificates: true

# SERVING certificate rotation: the kubelet's own HTTPS endpoint.
# NOT auto-approved. Requires manual approval or an external controller.
serverTLSBootstrap: true
```

### The Serving Certificate Trap

Enable `serverTLSBootstrap: true` and the kubelet requests a serving certificate. Nothing in core Kubernetes approves it.

```bash
kubectl get csr
# NAME        SIGNERNAME                        REQUESTOR               CONDITION
# csr-4h2nq   kubernetes.io/kubelet-serving     system:node:worker-01   Pending
# csr-8k3mx   kubernetes.io/kubelet-serving     system:node:worker-02   Pending
```

They sit `Pending` forever. Meanwhile `kubectl logs` and `kubectl exec` may fail, and `metrics-server` cannot scrape the kubelet without `--kubelet-insecure-tls`.

This is deliberate. Auto-approving serving certificates would let a compromised kubelet request a certificate for an arbitrary hostname. The options are:

```bash
# Manual approval, fine for a small static cluster
kubectl get csr -o name | xargs -r kubectl certificate approve

# Or approve only pending kubelet-serving CSRs
kubectl get csr -o json | jq -r '
  .items[]
  | select(.spec.signerName == "kubernetes.io/kubelet-serving")
  | select(.status.conditions == null)
  | .metadata.name' | xargs -r kubectl certificate approve
```

For anything dynamic, run an approver controller such as `kubelet-csr-approver`, which validates that the requested SANs actually match the node before approving.

Once approved, point the API server at the cluster CA so it actually verifies kubelet serving certificates:

```yaml
- --kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt
```

Without that flag the API server accepts any kubelet certificate, which is the man-in-the-middle gap mentioned earlier.

### Watching Rotation

```bash
sudo ls -l /var/lib/kubelet/pki/
# kubelet-client-2026-01-15-08-12-33.pem
# kubelet-client-current.pem -> kubelet-client-2026-01-15-08-12-33.pem
# kubelet-server-2026-01-15-08-12-40.pem
# kubelet-server-current.pem -> kubelet-server-2026-01-15-08-12-40.pem

sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem \
  -noout -subject -dates

sudo journalctl -u kubelet | grep -i 'rotat\|certificate'
```

The kubelet begins rotation at roughly 70 to 90 percent of the certificate's lifetime, so a one year certificate renews with months to spare.

---

## Expiry Disaster Recovery

The scenario: certificates expired, `kubectl` does not work, the control plane is down. You cannot use the API to fix the API.

```
Unable to connect to the server: x509: certificate has expired or is not yet valid
```

Everything below is done on the control plane node, using files rather than the API.

### Step 1: Confirm the Diagnosis

```bash
sudo kubeadm certs check-expiration
# or, if even that fails:
for f in /etc/kubernetes/pki/*.crt /etc/kubernetes/pki/etcd/*.crt; do
  printf '%-50s ' "$(basename "$f")"
  sudo openssl x509 -in "$f" -noout -checkend 0 >/dev/null 2>&1 \
    && echo VALID || echo EXPIRED
done
```

Confirm the **CA** is still valid. If the CA has expired (ten years on), this is a much larger job and effectively means rebuilding the cluster's trust.

```bash
sudo openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -dates
```

### Step 2: Back Everything Up First

```bash
sudo cp -a /etc/kubernetes /root/kubernetes-backup-$(date +%F-%H%M)
```

Do not skip this. A failed renewal with no backup is significantly worse than expired certificates.

### Step 3: Renew

```bash
sudo kubeadm certs renew all
```

This works without a functioning API server because it operates purely on local files and the CA key.

### Step 4: Restart the Control Plane

```bash
cd /etc/kubernetes/manifests
sudo mkdir -p /tmp/k8s-manifests
sudo mv *.yaml /tmp/k8s-manifests/
sleep 25
sudo mv /tmp/k8s-manifests/*.yaml /etc/kubernetes/manifests/

# Watch the containers come back
watch sudo crictl ps
```

If the kubelet itself will not start, its own certificate may have expired too:

```bash
sudo journalctl -u kubelet -n 50 --no-pager | grep -i certificate
```

### Step 5: Regenerate the Admin kubeconfig

```bash
sudo kubeadm init phase kubeconfig admin
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

kubectl get nodes
```

### Step 6: Fix the Kubelets

A kubelet whose client certificate expired while it was offline cannot rotate, because rotation requires a valid certificate to authenticate the renewal request. Re-bootstrap it:

```bash
# On the control plane, mint a fresh bootstrap token
sudo kubeadm token create --print-join-command

# On the affected worker
sudo rm -f /etc/kubernetes/kubelet.conf
sudo rm -f /var/lib/kubelet/pki/kubelet-client-*
sudo kubeadm join <endpoint> --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

### Preventing It Entirely

```bash
# A monthly cron on each control plane node
cat <<'EOF' | sudo tee /etc/cron.monthly/k8s-cert-check
#!/bin/sh
DAYS=$(kubeadm certs check-expiration 2>/dev/null \
  | awk '/apiserver /{print $4}' | tr -d 'd')
if [ -n "$DAYS" ] && [ "$DAYS" -lt 45 ]; then
  echo "Kubernetes certificates expire in ${DAYS} days on $(hostname)" \
    | logger -t k8s-certs -p daemon.crit
fi
EOF
sudo chmod +x /etc/cron.monthly/k8s-cert-check
```

Better still: upgrade the cluster at least annually. `kubeadm upgrade` renews all certificates as a side effect, which is why regularly maintained clusters never encounter this.

---

## Recipes

### Recipe: Full PKI Health Report

```bash
#!/usr/bin/env bash
echo "=== Certificate Authorities ==="
for ca in /etc/kubernetes/pki/ca.crt \
          /etc/kubernetes/pki/etcd/ca.crt \
          /etc/kubernetes/pki/front-proxy-ca.crt; do
  printf '%-45s ' "$(basename "$(dirname "$ca")")/$(basename "$ca")"
  sudo openssl x509 -in "$ca" -noout -enddate | cut -d= -f2
done

echo
echo "=== Leaf certificates ==="
sudo kubeadm certs check-expiration 2>/dev/null | sed -n '2,20p'

echo
echo "=== API server SANs ==="
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName

echo
echo "=== Service account key fingerprint (must match on all CP nodes) ==="
sudo openssl rsa -in /etc/kubernetes/pki/sa.key -noout -modulus 2>/dev/null | sha256sum

echo
echo "=== Kubelet certificates on this node ==="
for f in /var/lib/kubelet/pki/kubelet-*-current.pem; do
  [ -e "$f" ] || continue
  printf '%-45s ' "$(basename "$f")"
  sudo openssl x509 -in "$f" -noout -enddate | cut -d= -f2
done
```

### Recipe: Issue a Short-Lived Break-Glass Credential

For an incident, a one-day certificate is far safer than handing out `admin.conf`.

```bash
NAME="oncall-$(date +%Y%m%d)"

openssl genrsa -out "${NAME}.key" 2048
openssl req -new -key "${NAME}.key" -out "${NAME}.csr" \
  -subj "/CN=${NAME}/O=break-glass"

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${NAME}
spec:
  request: $(base64 -w0 < "${NAME}.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400        # one day, not one year
  usages: ["client auth"]
EOF

kubectl certificate approve "${NAME}"
kubectl get csr "${NAME}" -o jsonpath='{.status.certificate}' \
  | base64 -d > "${NAME}.crt"

# Bind to a real role, not cluster-admin, unless genuinely required.
kubectl create clusterrolebinding "${NAME}" \
  --clusterrole=view --group=break-glass --dry-run=client -o yaml
```

Every action taken with it is attributable to that CN in the audit log. See [audit-logging.md](audit-logging.md).

### Recipe: Verify a kubeconfig Before Handing It Over

```bash
#!/usr/bin/env bash
KC="${1:?usage: $0 path/to/kubeconfig}"

echo "== server =="
kubectl --kubeconfig "$KC" config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}'; echo

echo "== client identity =="
kubectl --kubeconfig "$KC" config view --raw --minify \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -dates

echo "== does it work? =="
kubectl --kubeconfig "$KC" auth whoami

echo "== what can it do? =="
kubectl --kubeconfig "$KC" auth can-i --list 2>/dev/null | head -20
```

---

## Command Reference

```bash
# ---------- Expiry ----------
sudo kubeadm certs check-expiration
sudo openssl x509 -in CERT -noout -dates
sudo openssl x509 -in CERT -noout -checkend 2592000   # 30 days

# ---------- Inspect ----------
sudo openssl x509 -in CERT -noout -text
sudo openssl x509 -in CERT -noout -subject -issuer
sudo openssl x509 -in CERT -noout -ext subjectAltName
sudo openssl x509 -in CERT -noout -ext extendedKeyUsage
openssl s_client -connect HOST:6443 </dev/null 2>/dev/null | openssl x509 -noout -text

# ---------- Renew ----------
sudo kubeadm certs renew all
sudo kubeadm certs renew apiserver
sudo kubeadm init phase kubeconfig admin
sudo kubeadm init phase certs apiserver --config kubeadm-config.yaml

# ---------- CSR API ----------
kubectl get csr
kubectl certificate approve NAME
kubectl certificate deny NAME
kubectl get csr NAME -o jsonpath='{.status.certificate}' | base64 -d > cert.crt
kubectl describe csr NAME

# ---------- Generate ----------
openssl genrsa -out user.key 2048
openssl req -new -key user.key -out user.csr -subj "/CN=user/O=group"
openssl req -in user.csr -noout -subject
base64 -w0 < user.csr

# ---------- Bootstrap tokens ----------
sudo kubeadm token list
sudo kubeadm token create --print-join-command
sudo kubeadm token create --ttl 1h --print-join-command
sudo kubeadm token delete TOKEN

# ---------- Kubelet certs ----------
sudo ls -l /var/lib/kubelet/pki/
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -dates
sudo journalctl -u kubelet | grep -i certificate

# ---------- Kubeconfig embedded certs ----------
sudo grep client-certificate-data /etc/kubernetes/admin.conf \
  | awk '{print $2}' | base64 -d | openssl x509 -noout -subject -dates
```

---

## Troubleshooting

### `x509: certificate has expired or is not yet valid`

Renew and restart. See [Expiry Disaster Recovery](#expiry-disaster-recovery).

Also check the node's clock. A certificate that is "not yet valid" usually means clock skew, not expiry.

```bash
timedatectl status
sudo chronyc sources   # or: sudo systemctl status systemd-timesyncd
```

### `x509: certificate is valid for X, not Y`

A hostname mismatch. The name you are connecting to is not in the SAN list. Either connect using a name that is present, or add the SAN. See [Adding a SAN to the API Server](#adding-a-san-to-the-api-server).

```bash
# What names does it actually cover?
openssl s_client -connect YOUR_HOST:6443 </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

### `x509: certificate signed by unknown authority`

Your client does not trust the CA that signed the server's certificate. Usually a kubeconfig with the wrong or missing `certificate-authority-data`.

```bash
# Compare what the kubeconfig trusts against the real cluster CA
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d | openssl x509 -noout -subject -fingerprint

sudo openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -subject -fingerprint
```

Fingerprints must match. If they do not, the kubeconfig is for a different cluster, or the CA was regenerated.

### CSR Stuck Pending

```bash
kubectl get csr
kubectl describe csr NAME
```

If `signerName` is `kubernetes.io/kubelet-serving`, this is expected: those are never auto-approved. Approve manually or deploy an approver controller.

If it is `kube-apiserver-client-kubelet` and still pending, the auto-approver may be misconfigured:

```bash
kubectl get clusterrolebindings | grep -i bootstrap
# Expect: kubeadm:node-autoapprove-bootstrap and
#         kubeadm:node-autoapprove-certificate-rotation
```

### CSR Rejected With a Subject Error

```
Forbidden: use of system:masters group during CSR is not allowed
```

The `CertificateSubjectRestriction` admission controller blocking a privilege escalation attempt. Use a different Organization and grant permissions with RBAC instead.

### Control Plane Will Not Start After Renewal

You almost certainly renewed but did not restart, or restarted incorrectly.

```bash
sudo crictl ps -a | grep -E 'apiserver|etcd'
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -30
sudo journalctl -u kubelet -n 80 --no-pager
```

If etcd is failing, check that its certificates were renewed with the correct CA:

```bash
sudo openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -noout -issuer
# issuer=CN = etcd-ca      ← must be etcd-ca, not kubernetes
```

### Service Account Tokens Fail Intermittently on an HA Cluster

The `sa.key` differs between control plane nodes. Tokens signed by one are rejected by another.

```bash
# Run on every control plane node and compare
sudo openssl rsa -in /etc/kubernetes/pki/sa.key -noout -modulus | sha256sum
```

Copy the authoritative keypair to the others and restart their API servers and controller managers.

### `kubectl top` Fails After Enabling serverTLSBootstrap

metrics-server cannot verify kubelet serving certificates that were never approved.

```bash
kubectl get csr | grep kubelet-serving
# approve them, then
kubectl -n kube-system rollout restart deployment metrics-server
```

---

## Exam and Interview Traps

1. **Where does a user's username come from?** The certificate's Common Name. Groups come from the Organization fields. There is no User object in Kubernetes.

2. **How do you revoke a certificate?** You cannot. Kubernetes checks no CRL and no OCSP. Remove the RBAC bindings, or wait for expiry. This is why short lifetimes matter.

3. **How many CAs does kubeadm create?** Three: cluster `ca`, `etcd/ca`, and `front-proxy-ca`.

4. **Which CA signs `apiserver-etcd-client.crt`?** The etcd CA, despite the file sitting in the top-level pki directory.

5. **Are `sa.key` and `sa.pub` certificates?** No. A bare RSA keypair used to sign and verify service account JWTs. They never expire and must be identical across control plane nodes.

6. **Default certificate lifetimes?** CAs ten years, leaf certificates one year.

7. **Does `kubeadm certs renew all` restart anything?** No. The components hold the old certificates in memory until restarted.

8. **How do you restart a static pod?** Move its manifest out of `/etc/kubernetes/manifests`, wait, move it back. There is no `kubectl delete` for a mirror pod.

9. **You need a new DNS name on the API server. What do you do?** Add it to `certSANs` in the kubeadm ClusterConfiguration, move the old `apiserver.crt/.key` aside, run `kubeadm init phase certs apiserver`, restart.

10. **Which CSR signer is auto-approved?** `kubernetes.io/kube-apiserver-client-kubelet`, for bootstrap and client rotation. `kubernetes.io/kubelet-serving` is deliberately **not** auto-approved.

11. **Why are kubelet serving CSRs not auto-approved?** A compromised kubelet could request a certificate for an arbitrary hostname. Approval must validate the requested SANs.

12. **What stops someone requesting a `system:masters` certificate through the CSR API?** The `CertificateSubjectRestriction` admission controller.

13. **What does `base64 -w0` matter for?** Without it, `base64` wraps lines and the CSR `request` field becomes invalid.

14. **Certificate says "not yet valid".** Clock skew, not expiry. Check NTP.

15. **Which single file, if leaked, means total cluster compromise?** `/etc/kubernetes/pki/ca.key`. It can mint a `system:masters` certificate that cannot be revoked.

---

## Related Topics

- [authentication.md](authentication.md) for all the ways identity is established, including OIDC
- [authorization.md](authorization.md) for what happens after identity is proven
- [rbac.md](rbac.md) for granting the permissions a certificate does not carry
- [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md) for the files that carry these credentials
- [service-accounts.md](service-accounts.md) for the token-based identity `sa.key` signs
- [etcd.md](etcd.md) for the datastore behind the etcd CA
- [api-aggregation.md](api-aggregation.md) for what the front-proxy CA exists to serve
- [kubelet.md](kubelet.md) for the agent that bootstraps and rotates its own certificates
- [cluster-upgrades.md](cluster-upgrades.md), which renews certificates as a side effect
- [cluster-hardening.md](cluster-hardening.md) for `--kubelet-certificate-authority` and related controls
- [disaster-recovery.md](disaster-recovery.md) for the wider recovery picture

---

## Key Takeaways

- Kubernetes is mutual TLS throughout, and a certificate's subject *is* an identity: CN becomes the username, O becomes a group.
- There is no user database and no revocation. Issuing a certificate creates a user; only expiry or removing RBAC bindings takes the power away.
- `/etc/kubernetes/pki/ca.key` is effectively the cluster root password. Anyone holding it can mint an unrevocable `system:masters` credential.
- kubeadm builds three independent CAs: cluster, etcd, and front-proxy. Mixing them up is a common debugging dead end.
- `sa.key` and `sa.pub` are not certificates, never expire, and must match on every control plane node.
- CAs last ten years, leaves last one year. Renewal does not restart anything; you must restart the static pods yourself.
- Regular `kubeadm upgrade` renews certificates as a side effect, which is why maintained clusters never hit the one-year wall.
- Adding a name to the API server means regenerating `apiserver.crt` with new `certSANs`, not editing the existing certificate.
- Kubelet **client** certificates auto-approve and rotate cleanly. Kubelet **serving** certificates do not auto-approve, by design.
- Short `expirationSeconds` on user certificates is a real security control, given revocation does not exist.
- Renewal works offline from local files, so an expired cluster can be recovered without a working API server.

---

## References

- [PKI Certificates and Requirements](https://kubernetes.io/docs/setup/best-practices/certificates/)
- [Certificate Management with kubeadm](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [Certificate Signing Requests](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
- [Certificates and Certificate Signing Requests](https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/)
- [Kubelet TLS Bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/)
- [Authenticating](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [Configure Certificate Rotation for the Kubelet](https://kubernetes.io/docs/tasks/tls/certificate-rotation/)
- [kubeadm certs](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-certs/)
