# 🗂️ kubeconfig and Static Pod Manifests: The Two Files That Run Your Cluster

Two unrelated-looking artifacts sit at the heart of every kubeadm cluster. A **kubeconfig** tells a client where the cluster is, who you are, and how to prove it. A **static pod manifest** is how the control plane itself gets started, before any control plane exists to start it. This document covers the kubeconfig schema field by field, the five kubeconfigs kubeadm generates and the identity each embeds, merging and context workflows, then the manifests in `/etc/kubernetes/manifests` and how to edit them without bricking the cluster.

## 📋 Table of Contents
- [Part One: kubeconfig](#part-one-kubeconfig)
- [The Schema](#the-schema)
- [An Annotated kubeconfig](#an-annotated-kubeconfig)
- [The Three Lists and How They Join](#the-three-lists-and-how-they-join)
- [Credential Types](#credential-types)
- [Exec Credential Plugins](#exec-credential-plugins)
- [The kubeadm-Generated kubeconfigs](#the-kubeadm-generated-kubeconfigs)
- [admin.conf vs super-admin.conf](#adminconf-vs-super-adminconf)
- [KUBECONFIG and File Merging](#kubeconfig-and-file-merging)
- [Managing Contexts](#managing-contexts)
- [Part Two: Static Pod Manifests](#part-two-static-pod-manifests)
- [How the Kubelet Finds Them](#how-the-kubelet-finds-them)
- [Mirror Pods](#mirror-pods)
- [The Four kubeadm Manifests](#the-four-kubeadm-manifests)
- [Editing a Manifest Safely](#editing-a-manifest-safely)
- [Recovering From a Broken Manifest](#recovering-from-a-broken-manifest)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

# Part One: kubeconfig

## The Schema

A kubeconfig answers three questions, and its structure mirrors them exactly.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                                                                      │
   │   clusters:   WHERE is the API server, and what CA do I trust?      │
   │        │                                                             │
   │   users:      WHO am I, and how do I prove it?                       │
   │        │                                                             │
   │   contexts:   PAIR a cluster with a user, plus a default namespace   │
   │        │                                                             │
   │   current-context:  which pairing is active right now                │
   │                                                                      │
   └──────────────────────────────────────────────────────────────────────┘
```

The important structural insight: `clusters` and `users` are **independent lists**. A context joins one of each. That is what lets you use the same identity against three clusters, or three identities against one cluster, without duplicating anything.

```
        clusters                users                contexts
     ┌────────────┐         ┌────────────┐      ┌──────────────────┐
     │ prod       │◄────────┼─ alice     │◄─────┤ alice@prod       │
     │ staging    │◄──┐     │  bob       │      │ alice@staging    │
     │ dev        │   └─────┼──┘         │      │ bob@prod         │
     └────────────┘         └────────────┘      └──────────────────┘
```

## An Annotated kubeconfig

```yaml
apiVersion: v1
kind: Config

# ═══════════════════════════════════════════════════════════════════════
#  CLUSTERS: where to connect and what to trust
# ═══════════════════════════════════════════════════════════════════════
clusters:
  - name: production                    # arbitrary label, referenced by contexts
    cluster:
      # Must include scheme and port. https is effectively mandatory.
      server: https://api.example.internal:6443

      # The CA that signed the API server's certificate.
      # Either inline base64 (portable) ...
      certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
      # ... or a path on disk (not portable, but easier to rotate)
      # certificate-authority: /etc/kubernetes/pki/ca.crt

      # Skip TLS verification. NEVER in production. Included only so you
      # recognise it in a broken config someone hands you.
      # insecure-skip-tls-verify: true

      # Override the hostname used for TLS verification. Occasionally
      # needed when connecting via IP to a cert that only names a DNS name.
      # tls-server-name: api.example.internal

      # Optional proxy for reaching this cluster.
      # proxy-url: socks5://localhost:1080

# ═══════════════════════════════════════════════════════════════════════
#  USERS: credentials. This is the sensitive half of the file.
# ═══════════════════════════════════════════════════════════════════════
users:
  - name: alice
    user:
      client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
      client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ==...

# ═══════════════════════════════════════════════════════════════════════
#  CONTEXTS: a cluster + user + default namespace
# ═══════════════════════════════════════════════════════════════════════
contexts:
  - name: alice@production
    context:
      cluster: production               # must match a clusters[].name
      user: alice                       # must match a users[].name
      namespace: payments               # default for commands without -n

current-context: alice@production

preferences: {}
```

### `-data` versus path

Every certificate field comes in two forms:

| Form | Stores | Portable? |
|---|---|---|
| `certificate-authority` | A filesystem path | No. Breaks when the file moves or you copy the config to another machine |
| `certificate-authority-data` | Base64 of the PEM content | Yes. Self contained |

`kubectl config` writes the path form by default. Use `--embed-certs=true` to get the inline form, which is what you want for anything you hand to another person.

```bash
kubectl config set-credentials alice \
  --client-certificate=alice.crt \
  --client-key=alice.key \
  --embed-certs=true            # inline the content
```

Note that `kubectl config view` **redacts** credential data. To see the real thing you need `--raw`:

```bash
kubectl config view                 # REDACTED
kubectl config view --raw           # actual base64 content
```

## The Three Lists and How They Join

A frequent source of confusion: changing `namespace` on a context is not the same as changing the user or the cluster.

```bash
# Where am I pointed?
kubectl config current-context
# alice@production

# Everything about the active context only
kubectl config view --minify

# Just the pieces
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}'; echo

# Who does the server think I am? (asks the API, authoritative)
kubectl auth whoami
```

`kubectl config view --minify` is the single most useful diagnostic here: it strips everything except the active context, so you see exactly what a command will use.

## Credential Types

A `users[]` entry can hold several different credential shapes.

### Client Certificate

The kubeadm default and the most common for humans on self-managed clusters.

```yaml
users:
  - name: alice
    user:
      client-certificate-data: LS0tLS1CRUdJTi...
      client-key-data: LS0tLS1CRUdJTi...
```

Identity comes from the certificate subject. See [certificates.md](certificates.md).

### Bearer Token

Used by service accounts and by some SSO integrations.

```yaml
users:
  - name: ci-deployer
    user:
      token: eyJhbGciOiJSUzI1NiIsImtpZCI6...
```

```bash
# Mint a short-lived token for a service account
kubectl -n ci create token deployer --duration=1h
```

Long-lived static tokens in a file are legacy and a poor practice. Prefer bound service account tokens or OIDC.

### Exec Credential Plugin

The modern answer for anything dynamic: cloud IAM, SSO, hardware tokens.

```yaml
users:
  - name: eks-user
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        # The binary to run. Must be on PATH, or give an absolute path.
        command: aws
        args:
          - eks
          - get-token
          - --cluster-name
          - production
          - --output
          - json
        env:
          - name: AWS_PROFILE
            value: prod
        # Never  : no stdin
        # IfAvailable: give the plugin a TTY if one exists
        # Always : require a TTY, for interactive MFA prompts
        interactiveMode: IfAvailable
        # Pass cluster info (server, CA) to the plugin on stdin.
        provideClusterInfo: false
```

The plugin writes an `ExecCredential` to stdout, and `kubectl` uses the returned token or certificate:

```json
{
  "apiVersion": "client.authentication.k8s.io/v1",
  "kind": "ExecCredential",
  "status": {
    "expirationTimestamp": "2026-09-17T15:04:05Z",
    "token": "k8s-aws-v1.aHR0cHM6Ly9zdHMu..."
  }
}
```

`kubectl` caches the credential until `expirationTimestamp`, so the plugin is not invoked on every command.

This is how EKS, GKE and AKS authentication works today. The old `auth-provider` block that embedded cloud logic into `kubectl` itself was removed; if you meet a config using it, it needs migrating.

### Username and Password

```yaml
users:
  - name: legacy
    user:
      username: admin
      password: hunter2
```

HTTP basic auth was removed from Kubernetes. This exists in the schema for historical reasons and will not work against any current cluster.

### Impersonation Fields

```yaml
users:
  - name: alice-as-deployer
    user:
      client-certificate-data: ...
      client-key-data: ...
      # Every request is made AS this identity, if alice may impersonate.
      as: system:serviceaccount:production:deployer
      as-groups:
        - system:serviceaccounts
      as-uid: "12345"
```

Equivalent to `--as` on the command line, but persistent. See [authorization.md](authorization.md).

## The kubeadm-Generated kubeconfigs

kubeadm writes five, each with a deliberately different identity.

```
/etc/kubernetes/
├── admin.conf                  ← for humans
├── super-admin.conf            ← break glass
├── controller-manager.conf     ← used by kube-controller-manager
├── scheduler.conf              ← used by kube-scheduler
└── kubelet.conf                ← used by the kubelet on this node
```

| File | CN (username) | O (group) | Purpose |
|---|---|---|---|
| `admin.conf` | `kubernetes-admin` | `kubeadm:cluster-admins` | Day to day administration |
| `super-admin.conf` | `kubernetes-super-admin` | `system:masters` | Break glass, bypasses RBAC |
| `controller-manager.conf` | `system:kube-controller-manager` | none | The controller manager's identity |
| `scheduler.conf` | `system:kube-scheduler` | none | The scheduler's identity |
| `kubelet.conf` | `system:node:<nodename>` | `system:nodes` | This node's kubelet |

Inspect any of them:

```bash
sudo grep client-certificate-data /etc/kubernetes/admin.conf \
  | awk '{print $2}' | base64 -d | openssl x509 -noout -subject
# subject=O = kubeadm:cluster-admins, CN = kubernetes-admin
```

Note that `kubelet.conf` on a running node usually does **not** embed a certificate. It points at the rotating file instead:

```yaml
users:
  - name: system:node:worker-01
    user:
      client-certificate: /var/lib/kubelet/pki/kubelet-client-current.pem
      client-key: /var/lib/kubelet/pki/kubelet-client-current.pem
```

That indirection is what allows certificate rotation to work without rewriting the kubeconfig.

## admin.conf vs super-admin.conf

A change many people have not absorbed. Historically `admin.conf` carried `system:masters`, which bypasses RBAC entirely in code. Current kubeadm splits this in two.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  admin.conf                                                          │
   │    O = kubeadm:cluster-admins                                        │
   │    Power comes from a normal ClusterRoleBinding to cluster-admin.    │
   │    ► Subject to RBAC. Auditable. Can be scoped down or revoked.      │
   │    ► This is what you should use.                                    │
   ├──────────────────────────────────────────────────────────────────────┤
   │  super-admin.conf                                                    │
   │    O = system:masters                                                │
   │    Hardcoded bypass in the RBAC authorizer. No binding involved.     │
   │    ► Cannot be revoked with kubectl. Cannot be scoped.               │
   │    ► Works even if you delete every RBAC object in the cluster.      │
   │    ► Exists ONLY to recover from a broken RBAC configuration.        │
   └──────────────────────────────────────────────────────────────────────┘
```

Treat `super-admin.conf` like a root password in a safe:

```bash
# It should be root-only and mode 600.
sudo ls -l /etc/kubernetes/super-admin.conf
# -rw------- 1 root root 5657 ... /etc/kubernetes/super-admin.conf

# It should NOT be in anyone's ~/.kube/config
grep -l 'kubernetes-super-admin' ~/.kube/config 2>/dev/null \
  && echo "WARNING: super-admin credential in your default kubeconfig"
```

The normal setup step copies `admin.conf`, not `super-admin.conf`:

```bash
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
```

## KUBECONFIG and File Merging

`kubectl` locates configuration in a fixed order:

```
   1. --kubeconfig flag             (highest precedence)
   2. KUBECONFIG environment variable
   3. ~/.kube/config                (default)
```

`KUBECONFIG` accepts a colon-separated list, and the files are **merged**:

```bash
export KUBECONFIG=~/.kube/config:~/.kube/prod.conf:~/.kube/staging.conf
kubectl config get-contexts
```

Merge rules that matter:

- For a conflicting key, the **first file wins**. Later files cannot override earlier ones.
- `current-context` comes from the first file that sets it.
- Nothing is written back automatically. The merge is in memory only.

To flatten a merge into a single real file:

```bash
KUBECONFIG=~/.kube/config:~/.kube/prod.conf \
  kubectl config view --flatten --raw > ~/.kube/merged.conf

# --flatten inlines all file references as -data
# --raw keeps the credentials rather than redacting them

chmod 600 ~/.kube/merged.conf
mv ~/.kube/merged.conf ~/.kube/config
```

Always `chmod 600`. A merged kubeconfig usually contains several sets of live credentials.

### Keeping Clusters Separate

Merging everything into one file is convenient and dangerous: one careless `kubectl delete` in the wrong context hits production. A safer pattern is per-cluster files with an explicit switch:

```bash
# ~/.bashrc
kc() { export KUBECONFIG="$HOME/.kube/$1.conf"; kubectl config current-context; }

# usage
kc dev
kc prod
```

Combined with a shell prompt that shows the current context, this removes most of the risk.

## Managing Contexts

Every operation has a `kubectl config` subcommand. Editing the YAML by hand is rarely necessary.

```bash
# ---------- Inspect ----------
kubectl config view                      # redacted
kubectl config view --raw                # with credentials
kubectl config view --minify             # active context only
kubectl config get-contexts
kubectl config get-clusters
kubectl config get-users
kubectl config current-context

# ---------- Build ----------
kubectl config set-cluster prod \
  --server=https://api.example.internal:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true

kubectl config set-credentials alice \
  --client-certificate=alice.crt \
  --client-key=alice.key \
  --embed-certs=true

kubectl config set-context alice@prod \
  --cluster=prod --user=alice --namespace=payments

# ---------- Switch ----------
kubectl config use-context alice@prod

# Change the namespace of the CURRENT context
kubectl config set-context --current --namespace=billing

# ---------- Remove ----------
kubectl config delete-context alice@prod
kubectl config delete-cluster prod
kubectl config unset users.alice

# ---------- Rename ----------
kubectl config rename-context old-name new-name
```

The namespace line is worth internalising. Typing `-n` on every command is how people end up running things in `default` by accident:

```bash
kubectl config set-context --current --namespace=payments
```

---

# Part Two: Static Pod Manifests

## How the Kubelet Finds Them

A bootstrapping paradox: the control plane runs as pods, but pods are created by the control plane. Static pods break the cycle.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  A NORMAL POD                          A STATIC POD                  │
   │  ─────────────                         ────────────                  │
   │  you ──► API server                    you ──► a FILE on the node    │
   │              │                                      │                │
   │              ▼                                      ▼                │
   │          scheduler                              kubelet reads it     │
   │              │                                      │                │
   │              ▼                                      ▼                │
   │          kubelet                                container runtime    │
   │              │                                                       │
   │              ▼                             No API server involved.   │
   │      container runtime                     No scheduler involved.    │
   │                                            Works with the cluster    │
   │                                            completely down.          │
   └──────────────────────────────────────────────────────────────────────┘
```

The kubelet watches a directory, configured in its own config file:

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
staticPodPath: /etc/kubernetes/manifests
```

```bash
sudo grep staticPodPath /var/lib/kubelet/config.yaml
ls -l /etc/kubernetes/manifests/
# etcd.yaml
# kube-apiserver.yaml
# kube-controller-manager.yaml
# kube-scheduler.yaml
```

The kubelet watches this directory continuously. **Writing a file starts a pod. Deleting the file stops it.** There is no other control surface.

## Mirror Pods

So that static pods are visible in `kubectl get pods`, the kubelet creates a read-only **mirror pod** in the API for each one.

```bash
kubectl -n kube-system get pods -l component=kube-apiserver
# NAME                     READY   STATUS    RESTARTS   AGE
# kube-apiserver-cp-01     1/1     Running   0          4d
```

Note the name: the static pod's name with the node name appended. That suffix is the giveaway that something is a mirror pod.

```bash
# The annotation that marks it
kubectl -n kube-system get pod kube-apiserver-cp-01 \
  -o jsonpath='{.metadata.annotations}' | jq
# { "kubernetes.io/config.source": "file", ... }
```

Mirror pods are read-only projections. Deleting one does nothing useful:

```bash
kubectl -n kube-system delete pod kube-apiserver-cp-01
# pod "kube-apiserver-cp-01" deleted

# ...and it immediately comes back, because the FILE is still there.
```

The kubelet simply recreates the mirror. To actually stop a static pod you must move or delete its manifest.

## The Four kubeadm Manifests

### kube-apiserver.yaml

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    component: kube-apiserver
    tier: control-plane
  annotations:
    # Used to detect config drift across a kubeadm upgrade.
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 192.168.1.10:6443
spec:
  # Shares the node's network namespace, so it binds 6443 on the host
  # directly. Essential: the CNI is not up yet when this starts.
  hostNetwork: true

  # Highest possible priority. Never evicted under node pressure.
  priorityClassName: system-node-critical
  priority: 2000001000

  # Do not inject a service account token; this pod authenticates
  # with certificates.
  automountServiceAccountToken: false

  # DNS from the host, since CoreDNS may not exist yet.
  dnsPolicy: ClusterFirst

  containers:
    - name: kube-apiserver
      image: registry.k8s.io/kube-apiserver:v1.31.2
      command:
        - kube-apiserver
        # Address advertised to cluster members.
        - --advertise-address=192.168.1.10
        # The security-critical flags.
        - --authorization-mode=Node,RBAC
        - --enable-admission-plugins=NodeRestriction
        - --anonymous-auth=false
        # Serving certificate and its key.
        - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
        - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
        # CA used to validate CLIENT certificates.
        - --client-ca-file=/etc/kubernetes/pki/ca.crt
        # Credentials for calling kubelets.
        - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
        - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
        # etcd connection, using the SEPARATE etcd CA.
        - --etcd-servers=https://127.0.0.1:2379
        - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
        - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
        - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
        # Service account token verification and issuance.
        - --service-account-key-file=/etc/kubernetes/pki/sa.pub
        - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
        - --service-account-issuer=https://kubernetes.default.svc.cluster.local
        # Aggregation layer.
        - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
        - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
        - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
        - --service-cluster-ip-range=10.96.0.0/12
        - --secure-port=6443

      # Probes hit the API server's own health endpoints.
      livenessProbe:
        httpGet:
          host: 192.168.1.10
          path: /livez
          port: 6443
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 8
      readinessProbe:
        httpGet:
          host: 192.168.1.10
          path: /readyz
          port: 6443
          scheme: HTTPS
        periodSeconds: 1
        timeoutSeconds: 15
        failureThreshold: 3
      # Gives a slow-starting API server up to ~2 minutes before the
      # liveness probe starts killing it.
      startupProbe:
        httpGet:
          host: 192.168.1.10
          path: /livez
          port: 6443
          scheme: HTTPS
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 15
        failureThreshold: 24

      resources:
        requests:
          cpu: 250m
        # Note: NO memory limit. A limit here risks OOMKilling the API
        # server under load, which is worse than using more memory.

      volumeMounts:
        - name: k8s-certs
          mountPath: /etc/kubernetes/pki
          readOnly: true
        - name: ca-certs
          mountPath: /etc/ssl/certs
          readOnly: true

  volumes:
    # Everything a static pod needs must come from hostPath. There is
    # no ConfigMap or Secret available at this stage of startup.
    - name: k8s-certs
      hostPath:
        path: /etc/kubernetes/pki
        type: DirectoryOrCreate
    - name: ca-certs
      hostPath:
        path: /etc/ssl/certs
        type: DirectoryOrCreate
```

The `hostPath`-only constraint is the key structural fact. **Any flag you add that references a file requires a matching `volume` and `volumeMount`**, or the file simply does not exist inside the container. This is the single most common way people break their control plane, and it is why [encryption-at-rest.md](encryption-at-rest.md) and [audit-logging.md](audit-logging.md) both labour the point.

### kube-controller-manager.yaml

```yaml
    command:
      - kube-controller-manager
      # Its own identity, as a kubeconfig.
      - --kubeconfig=/etc/kubernetes/controller-manager.conf
      - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
      - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
      # The CA key, so it can sign CSRs. This is why the controller
      # manager is as sensitive as the API server.
      - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
      - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
      # Signs service account tokens.
      - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
      - --root-ca-file=/etc/kubernetes/pki/ca.crt
      # Each controller uses its own service account rather than the
      # controller manager's blanket identity. A real hardening item.
      - --use-service-account-credentials=true
      # Only one instance acts at a time in an HA cluster.
      - --leader-elect=true
      - --controllers=*,bootstrapsigner,tokencleaner
      - --allocate-node-cidrs=true
      - --cluster-cidr=10.244.0.0/16
      - --bind-address=127.0.0.1        # not reachable off-node
```

### kube-scheduler.yaml

```yaml
    command:
      - kube-scheduler
      - --kubeconfig=/etc/kubernetes/scheduler.conf
      - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
      - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
      - --leader-elect=true
      - --bind-address=127.0.0.1
```

The smallest of the four. Custom scheduler profiles are supplied with `--config` pointing at a `KubeSchedulerConfiguration` file, which of course needs its own hostPath mount. See [scheduling.md](scheduling.md).

### etcd.yaml

```yaml
    command:
      - etcd
      - --name=cp-01
      - --data-dir=/var/lib/etcd
      # Client traffic: loopback for the local API server, plus the
      # node IP for other control plane members.
      - --listen-client-urls=https://127.0.0.1:2379,https://192.168.1.10:2379
      - --advertise-client-urls=https://192.168.1.10:2379
      # Peer traffic between etcd members.
      - --listen-peer-urls=https://192.168.1.10:2380
      - --initial-advertise-peer-urls=https://192.168.1.10:2380
      # Certificates, all from the etcd CA.
      - --cert-file=/etc/kubernetes/pki/etcd/server.crt
      - --key-file=/etc/kubernetes/pki/etcd/server.key
      - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
      - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
      - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
      - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
      # Mutual TLS is mandatory, both directions.
      - --client-cert-auth=true
      - --peer-client-cert-auth=true
      # Compaction and defragmentation tuning.
      - --auto-compaction-retention=8
      - --snapshot-count=10000
    volumeMounts:
      - name: etcd-data
        mountPath: /var/lib/etcd            # the actual cluster state
      - name: etcd-certs
        mountPath: /etc/kubernetes/pki/etcd
```

`/var/lib/etcd` is the entire cluster. Back it up. See [etcd-backup-restore.md](etcd-backup-restore.md).

## Editing a Manifest Safely

The kubelet watches the directory and reacts to **any** write, including a partial one from a slow editor. The discipline matters.

```bash
# 1. ALWAYS back up first.
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml \
        /root/kube-apiserver.yaml.$(date +%s).bak

# 2. Edit OUTSIDE the watched directory, then move the finished file in.
#    An atomic move avoids the kubelet reading a half-written file.
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/apiserver-edit.yaml
sudo vi /tmp/apiserver-edit.yaml

# 3. Validate the YAML before it goes anywhere near the kubelet.
python3 -c "import yaml,sys; yaml.safe_load(open('/tmp/apiserver-edit.yaml'))" \
  && echo "YAML OK"

# 4. Move it in atomically.
sudo mv /tmp/apiserver-edit.yaml /etc/kubernetes/manifests/kube-apiserver.yaml

# 5. Watch it come back.
until kubectl get --raw /healthz 2>/dev/null; do sleep 2; done; echo
```

If you must edit in place, at least confirm your editor writes atomically. `vi` does, by default, via a rename. Some editors truncate and rewrite, which the kubelet can catch mid-write.

### Restarting Without Changing Anything

```bash
# Method A: move out, wait, move back.
cd /etc/kubernetes/manifests
sudo mv kube-apiserver.yaml /tmp/ && sleep 15 && sudo mv /tmp/kube-apiserver.yaml .

# Method B: kill the container; the kubelet recreates it.
sudo crictl ps --name kube-apiserver -q | xargs -r sudo crictl stop

# Method C: touch the file. Some kubelet versions treat mtime change
# as a modification; less reliable than A or B.
sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml
```

Method A is the most reliable and the one to remember for exams.

## Recovering From a Broken Manifest

When the API server will not start, `kubectl` is dead and you must work from the node.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  kubectl does not work                                               │
   │        │                                                             │
   │        ▼                                                             │
   │  Is the container even being created?                                │
   │        sudo crictl ps -a | grep kube-apiserver                       │
   │        │                                                             │
   │        ├─ container exists, exited ──► read its logs                 │
   │        │      sudo crictl logs <id>                                  │
   │        │      usually: bad flag, missing mounted file                │
   │        │                                                             │
   │        └─ no container at all ──► the kubelet never accepted the     │
   │               manifest. Usually invalid YAML.                        │
   │               sudo journalctl -u kubelet -n 100                      │
   └──────────────────────────────────────────────────────────────────────┘
```

```bash
# The container's own failure output
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -40

# The kubelet's view, which catches YAML parse failures
sudo journalctl -u kubelet -n 100 --no-pager | grep -i -A5 'static\|manifest'

# Restore the backup
sudo cp /root/kube-apiserver.yaml.<timestamp>.bak \
        /etc/kubernetes/manifests/kube-apiserver.yaml

until kubectl get --raw /healthz 2>/dev/null; do sleep 2; done; echo
```

If no backup exists, regenerate the manifest from kubeadm's stored configuration:

```bash
sudo kubeadm init phase control-plane apiserver \
  --config <(kubectl -n kube-system get cm kubeadm-config \
             -o jsonpath='{.data.ClusterConfiguration}')
```

That only works if the API is reachable to read the ConfigMap, so on a fully dead cluster you need a local copy of the kubeadm config. Keeping one is a cheap insurance policy:

```bash
kubectl -n kube-system get cm kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}' | sudo tee /root/kubeadm-config.yaml
```

---

## Recipes

### Recipe: Build a kubeconfig for a Service Account

Useful for CI systems that cannot run an exec plugin.

```bash
#!/usr/bin/env bash
set -euo pipefail
NS="${1:?namespace}" SA="${2:?serviceaccount}" OUT="${3:-sa.kubeconfig}"

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --raw --minify \
      -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Bound, short-lived token. Far better than a long-lived Secret.
TOKEN=$(kubectl -n "$NS" create token "$SA" --duration=24h)

cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: cluster
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: ${SA}
    user:
      token: ${TOKEN}
contexts:
  - name: ${SA}@cluster
    context:
      cluster: cluster
      user: ${SA}
      namespace: ${NS}
current-context: ${SA}@cluster
EOF

chmod 600 "$OUT"
KUBECONFIG="$OUT" kubectl auth whoami
```

### Recipe: Audit Every kubeconfig on a Machine

```bash
#!/usr/bin/env bash
find "$HOME/.kube" /etc/kubernetes -maxdepth 1 -name '*.conf' -o -name 'config' 2>/dev/null \
| while read -r f; do
  echo "=== $f"
  printf '  perms:   '; stat -c '%A %U:%G' "$f"
  printf '  server:  '; kubectl --kubeconfig "$f" config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null; echo
  printf '  subject: '
  kubectl --kubeconfig "$f" config view --raw --minify \
    -o jsonpath='{.users[0].user.client-certificate-data}' 2>/dev/null \
    | base64 -d 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
    || echo "(token or exec credential)"
  echo
done
```

Anything mode 644 or group readable holding a live credential is a finding.

### Recipe: Safe Flag Addition to the API Server

A reusable pattern for the many tasks that require adding a flag plus a mount.

```bash
#!/usr/bin/env bash
set -euo pipefail
M=/etc/kubernetes/manifests/kube-apiserver.yaml
B=/root/kube-apiserver.$(date +%s).bak

echo "== backing up to $B"
sudo cp "$M" "$B"

echo "== edit /tmp/apiserver.yaml, then this script validates and installs it"
sudo cp "$M" /tmp/apiserver.yaml
"${EDITOR:-vi}" /tmp/apiserver.yaml

echo "== validating YAML"
python3 -c "import yaml;yaml.safe_load(open('/tmp/apiserver.yaml'))" \
  || { echo "INVALID YAML, aborting"; exit 1; }

echo "== installing"
sudo mv /tmp/apiserver.yaml "$M"

echo "== waiting for the API server"
for i in $(seq 1 60); do
  if kubectl get --raw /healthz >/dev/null 2>&1; then
    echo "OK after ${i}s"; exit 0
  fi
  sleep 1
done

echo "!! API server did not return. Rolling back."
sudo cp "$B" "$M"
echo "restored $B"
```

---

## Command Reference

```bash
# ---------- kubeconfig inspection ----------
kubectl config view
kubectl config view --raw
kubectl config view --minify
kubectl config get-contexts
kubectl config current-context
kubectl auth whoami

# ---------- kubeconfig building ----------
kubectl config set-cluster NAME --server=URL --certificate-authority=CA --embed-certs=true
kubectl config set-credentials NAME --client-certificate=C --client-key=K --embed-certs=true
kubectl config set-context NAME --cluster=C --user=U --namespace=NS
kubectl config use-context NAME
kubectl config set-context --current --namespace=NS
kubectl config rename-context OLD NEW
kubectl config delete-context NAME

# ---------- merging ----------
export KUBECONFIG=~/.kube/config:~/.kube/prod.conf
kubectl config view --flatten --raw > merged.conf

# ---------- decode embedded certs ----------
kubectl config view --raw --minify \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -dates

# ---------- static pods ----------
ls -l /etc/kubernetes/manifests/
sudo grep staticPodPath /var/lib/kubelet/config.yaml
kubectl -n kube-system get pods -l tier=control-plane
kubectl -n kube-system get pod NAME -o jsonpath='{.metadata.annotations}' | jq

# ---------- restart a static pod ----------
cd /etc/kubernetes/manifests
sudo mv NAME.yaml /tmp/ && sleep 15 && sudo mv /tmp/NAME.yaml .

# ---------- diagnose from the node ----------
sudo crictl ps -a
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1)
sudo journalctl -u kubelet -n 100 --no-pager

# ---------- regenerate manifests ----------
sudo kubeadm init phase control-plane apiserver --config kubeadm-config.yaml
sudo kubeadm init phase control-plane all --config kubeadm-config.yaml
sudo kubeadm init phase kubeconfig all
```

---

## Troubleshooting

### `The connection to the server localhost:8080 was refused`

The classic. `kubectl` found **no kubeconfig at all** and fell back to its compiled-in default.

```bash
echo "$KUBECONFIG"
ls -l ~/.kube/config

# Fix
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
```

Usually seen when running `kubectl` as a different user, under `sudo`, or on a worker node that never had a kubeconfig placed.

### `error: You must be logged in to the server (Unauthorized)`

The credential was presented and rejected. Check whether the certificate expired:

```bash
kubectl config view --raw --minify \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -dates
```

If it has, regenerate `admin.conf`. See [certificates.md](certificates.md).

```bash
sudo kubeadm init phase kubeconfig admin
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
```

### Commands Hit the Wrong Cluster

```bash
kubectl config current-context
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
```

Add the context to your shell prompt. This single change prevents more production incidents than most tooling:

```bash
# ~/.bashrc
__kctx() { kubectl config current-context 2>/dev/null; }
PS1='[$(__kctx)] \w\$ '
```

### An Exec Plugin Is Not Working

```bash
# Run the plugin by hand, exactly as configured.
kubectl config view --minify -o jsonpath='{.users[0].user.exec}' | jq

aws eks get-token --cluster-name production --output json

# Is the binary on PATH for the shell kubectl runs from?
command -v aws
```

A common failure is a plugin that works in an interactive shell but not from cron or CI, because `PATH` or credential environment variables differ.

### Static Pod Does Not Start and Nothing Appears in kubectl

The kubelet rejected the manifest before creating anything.

```bash
sudo journalctl -u kubelet -n 100 --no-pager | grep -i -B2 -A5 'manifest\|static'
python3 -c "import yaml;yaml.safe_load(open('/etc/kubernetes/manifests/kube-apiserver.yaml'))"
```

Also confirm the file is actually in the watched directory and readable by root, and that its `metadata.name` does not collide with another manifest.

### Deleting a Control Plane Pod Does Not Delete It

Expected. It is a mirror pod. The file is the source of truth. Move the manifest to stop it.

### Cannot Add a Flag That Points at a File

The file exists on the host but not in the container. Add the `volume` and `volumeMount`:

```yaml
      volumeMounts:
        - name: my-config
          mountPath: /etc/kubernetes/myconfig
          readOnly: true
  volumes:
    - name: my-config
      hostPath:
        path: /etc/kubernetes/myconfig
        type: DirectoryOrCreate
```

Verify from inside the running container:

```bash
sudo crictl exec $(sudo crictl ps --name kube-apiserver -q) \
  ls -la /etc/kubernetes/myconfig
```

### HA Cluster Behaves Inconsistently

A manifest was changed on one control plane node but not the others. Behaviour then depends on which API server the load balancer sends you to.

```bash
for n in cp-01 cp-02 cp-03; do
  echo "== $n"
  ssh "$n" 'sudo md5sum /etc/kubernetes/manifests/kube-apiserver.yaml'
done
```

The hashes will differ on the node that is out of step. Note that some fields legitimately differ per node (`--advertise-address`), so diff the flags rather than the whole file when in doubt.

---

## Exam and Interview Traps

1. **`kubectl` says "connection to localhost:8080 refused". Why?** No kubeconfig was found at all, so it fell back to the compiled-in default. Not an auth problem.

2. **Which file should a human administrator use, `admin.conf` or `super-admin.conf`?** `admin.conf`. It uses a normal RBAC binding. `super-admin.conf` carries `system:masters`, bypasses RBAC in code, and is break-glass only.

3. **What does `--embed-certs=true` change?** It inlines certificate content as `-data` fields instead of writing filesystem paths, making the kubeconfig portable.

4. **How does `KUBECONFIG` merging resolve conflicts?** First file wins. Later files cannot override earlier ones.

5. **How do you change the default namespace?** `kubectl config set-context --current --namespace=NS`.

6. **How do you restart a static pod?** Move its manifest out of the directory, wait, move it back. `kubectl delete` only removes the mirror pod, which is instantly recreated.

7. **Why can't you `kubectl delete` a control plane pod?** It is a mirror pod, a read-only projection of a file on the node.

8. **Why is `hostNetwork: true` on the API server manifest?** It must bind port 6443 on the host before any CNI exists. Pod networking is not available at that point in startup.

9. **You added a flag referencing a file and the API server will not start. Why?** The `volume` and `volumeMount` are missing, so the file does not exist inside the container.

10. **Where does the kubelet learn the static pod directory?** `staticPodPath` in `/var/lib/kubelet/config.yaml`.

11. **Which identity does `kubelet.conf` carry?** `CN=system:node:<nodename>`, `O=system:nodes`, which is what the Node authorizer keys off.

12. **Why does `kubelet.conf` usually point at a file rather than embedding a certificate?** So certificate rotation can replace the file without rewriting the kubeconfig.

13. **Why does the API server manifest have no memory limit?** OOMKilling the API server under load is worse than letting it use more memory.

14. **What does `kubectl config view` hide, and how do you see it?** Credential data is redacted. Use `--raw`.

15. **Where does the controller manager get the power to sign certificates?** `--cluster-signing-key-file=/etc/kubernetes/pki/ca.key`. It holds the cluster CA key, making it as sensitive as the API server.

---

## Related Topics

- [certificates.md](certificates.md) for the credentials these files carry
- [authentication.md](authentication.md) for how the API server interprets them
- [authorization.md](authorization.md) for what an identity is allowed to do
- [static-pods.md](static-pods.md) for the static pod mechanism in general use
- [kubectl.md](kubectl.md) for the client that reads kubeconfig
- [kubelet.md](kubelet.md) for the agent that watches the manifest directory
- [kube-apiserver.md](kube-apiserver.md) for the component the largest manifest starts
- [etcd.md](etcd.md) for the datastore behind `etcd.yaml`
- [encryption-at-rest.md](encryption-at-rest.md) and [audit-logging.md](audit-logging.md), both of which require manifest edits
- [cluster-upgrades.md](cluster-upgrades.md) for how kubeadm rewrites these manifests
- [disaster-recovery.md](disaster-recovery.md) for when all of this has gone wrong

---

## Key Takeaways

- A kubeconfig is three independent lists (clusters, users, contexts) plus a pointer at the active pairing. Contexts join a cluster to a user.
- `kubectl config view` redacts credentials; `--raw` shows them; `--minify` narrows to the active context and is the best first diagnostic.
- `--embed-certs=true` makes a kubeconfig portable by inlining certificate content instead of referencing paths.
- `admin.conf` is RBAC-governed and auditable. `super-admin.conf` carries `system:masters`, bypasses RBAC in code, cannot be revoked, and is strictly break-glass.
- `KUBECONFIG` merges colon-separated files, first file wins, and nothing is written back unless you `--flatten` it yourself.
- Static pods exist so the control plane can start without a control plane. The kubelet watches a directory; writing a file starts a pod, deleting it stops one.
- Mirror pods make static pods visible in the API but are read-only. Deleting one changes nothing.
- Static pods can only use `hostPath` volumes, so **every flag referencing a file needs a matching volume and mount**. This is the number one way people break their control plane.
- Always back up a manifest before editing, edit outside the watched directory, validate the YAML, then move it in atomically.
- When `kubectl` is dead, `crictl` and `journalctl -u kubelet` are your only windows into what happened.

---

## References

- [Organizing Cluster Access Using kubeconfig Files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- [Configure Access to Multiple Clusters](https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/)
- [kubeconfig File Reference](https://kubernetes.io/docs/reference/config-api/kubeconfig.v1/)
- [Client Authentication Reference](https://kubernetes.io/docs/reference/config-api/client-authentication.v1/)
- [Create Static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
- [kubeadm Generated kubeconfig Files](https://kubernetes.io/docs/reference/setup-tools/kubeadm/implementation-details/)
- [kubectl config](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/)
- [Kubelet Configuration Reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
