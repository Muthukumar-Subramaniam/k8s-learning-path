# 🛡️ Cluster Hardening: The Whole Security Posture

Every preceding security document covers one control in depth. This one is the map: what the realistic attack paths into a Kubernetes cluster actually are, which control closes each one, and in what order to apply them for the most risk reduction per hour spent. It synthesises rather than repeats, and links to the deep dive for each topic.

## 📋 Table of Contents
- [The 4C Model](#the-4c-model)
- [The Attack Tree](#the-attack-tree)
- [Control Plane Hardening](#control-plane-hardening)
- [etcd Hardening](#etcd-hardening)
- [Kubelet Hardening](#kubelet-hardening)
- [Node OS Hardening](#node-os-hardening)
- [Workload Hardening](#workload-hardening)
- [Network Hardening](#network-hardening)
- [The Metadata Endpoint](#the-metadata-endpoint)
- [Multi-Tenancy: An Honest Assessment](#multi-tenancy-an-honest-assessment)
- [CIS Benchmark and kube-bench](#cis-benchmark-and-kube-bench)
- [Runtime Detection With Falco](#runtime-detection-with-falco)
- [Testing Your Own Cluster](#testing-your-own-cluster)
- [Prioritised Roadmap](#prioritised-roadmap)
- [The Checklist](#the-checklist)
- [Command Reference](#command-reference)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The 4C Model

Security in Kubernetes is layered, and each layer can only be as strong as the one beneath it.

```
   ┌────────────────────────────────────────────────────────────────────┐
   │  CLOUD / DATACENTRE                                                │
   │  Physical access, hypervisor, network fabric, IAM, VPC             │
   │  ┌──────────────────────────────────────────────────────────────┐  │
   │  │  CLUSTER                                                     │  │
   │  │  API server, etcd, kubelet, RBAC, admission, network policy  │  │
   │  │  ┌────────────────────────────────────────────────────────┐  │  │
   │  │  │  CONTAINER                                             │  │  │
   │  │  │  Image provenance, runtime, capabilities, seccomp       │  │  │
   │  │  │  ┌──────────────────────────────────────────────────┐  │  │  │
   │  │  │  │  CODE                                            │  │  │  │
   │  │  │  │  Your application, its dependencies, its secrets │  │  │  │
   │  │  │  └──────────────────────────────────────────────────┘  │  │  │
   │  │  └────────────────────────────────────────────────────────┘  │  │
   │  └──────────────────────────────────────────────────────────────┘  │
   └────────────────────────────────────────────────────────────────────┘

   You cannot secure the Cluster layer if the Cloud layer is compromised.
   You cannot secure Code with cluster controls alone.
```

The practical use of the model is triage. When someone asks "is our cluster secure", the honest answer decomposes into four questions with four different owners.

---

## The Attack Tree

Concrete paths, roughly ordered by how often they are actually seen.

```
                        GOAL: cluster admin / node root
                                      ▲
        ┌─────────────────┬───────────┴────────┬──────────────────┐
        │                 │                    │                  │
   ┌────┴─────┐    ┌──────┴──────┐     ┌───────┴──────┐   ┌───────┴──────┐
   │ A. POD   │    │ B. EXPOSED  │     │ C. EXPOSED   │   │ D. SUPPLY    │
   │ COMPROM. │    │ KUBELET     │     │ etcd         │   │ CHAIN        │
   └────┬─────┘    └──────┬──────┘     └───────┬──────┘   └───────┬──────┘
        │                 │                    │                  │
        │            port 10250           port 2379           malicious or
        │            anonymous-auth        no client cert      vulnerable
        │            or readOnlyPort       auth                image pulled
        │                 │                    │                  │
        │            run any command       read EVERY          code executes
        │            in any pod on         secret in the       with whatever
        │            that node             cluster             the pod has
        │
        ├──► A1. mounted service account token
        │        └─ token has excessive RBAC ──► API access as that SA
        │        └─ can create pods           ──► schedule a privileged pod
        │        └─ can read secrets          ──► credentials elsewhere
        │
        ├──► A2. privileged: true
        │        └─ mount /dev/sda1, chroot ──► NODE ROOT
        │           └─ read /etc/kubernetes/pki/ca.key ──► FORGE ADMIN CERT
        │
        ├──► A3. hostPath volume
        │        └─ mount /  or /etc/kubernetes ──► NODE ROOT
        │        └─ mount /var/run/containerd.sock ──► run any container
        │
        ├──► A4. hostPID + SYS_PTRACE
        │        └─ read other processes' memory ──► steal their credentials
        │
        ├──► A5. hostNetwork
        │        └─ bypasses NetworkPolicy entirely
        │        └─ reach 169.254.169.254 ──► CLOUD IAM CREDENTIALS
        │        └─ reach services on node loopback
        │
        └──► A6. kernel exploit
                 └─ shared kernel ──► escape to node
```

Each branch maps to a specific control:

| Path | Closed by | Deep dive |
|---|---|---|
| A1 | `automountServiceAccountToken: false`, least-privilege RBAC | [service-accounts.md](service-accounts.md), [rbac.md](rbac.md) |
| A2, A3, A4, A5 | Pod Security Admission `restricted` | [pod-security-standards.md](pod-security-standards.md) |
| A6 | seccomp, RuntimeClass sandboxing, patching | [security-context.md](security-context.md), [runtime-class.md](runtime-class.md) |
| B | Kubelet authn/authz, `readOnlyPort: 0` | [Kubelet Hardening](#kubelet-hardening) |
| C | etcd client cert auth, firewall, encryption at rest | [encryption-at-rest.md](encryption-at-rest.md) |
| D | Registry allowlist, signing, scanning | [image-security.md](image-security.md) |

Note the recurring endpoint of path A2 and A3: **`/etc/kubernetes/pki/ca.key`**. Node root means cluster admin, because the CA key mints an unrevocable `system:masters` certificate. There is no recovery from that short of rotating the entire PKI. See [certificates.md](certificates.md).

---

## Control Plane Hardening

### kube-apiserver

The flags that matter, in `/etc/kubernetes/manifests/kube-apiserver.yaml`.

```yaml
    command:
      - kube-apiserver

      # ── AUTHENTICATION ────────────────────────────────────────────
      # Anonymous requests become system:anonymous. Disabling this is
      # the single highest-value flag on the list.
      - --anonymous-auth=false

      # Verify a token's ServiceAccount still exists before accepting it.
      # Without this, deleting a ServiceAccount does not invalidate its
      # legacy tokens.
      - --service-account-lookup=true

      # ── AUTHORIZATION ─────────────────────────────────────────────
      # Node constrains kubelets; RBAC handles everything else.
      - --authorization-mode=Node,RBAC

      # ── ADMISSION ─────────────────────────────────────────────────
      # NodeRestriction is NOT in the default set and is mandatory
      # alongside the Node authorizer.
      - --enable-admission-plugins=NodeRestriction,PodSecurity,AlwaysPullImages
      - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml

      # ── AUDIT ─────────────────────────────────────────────────────
      - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
      - --audit-log-path=/var/log/kubernetes/audit/audit.log
      - --audit-log-maxage=30
      - --audit-log-maxbackup=10
      - --audit-log-maxsize=100

      # ── ENCRYPTION ────────────────────────────────────────────────
      - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
      - --encryption-provider-config-automatic-reload=true

      # ── TLS ───────────────────────────────────────────────────────
      - --tls-min-version=VersionTLS12
      - --tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305

      # Verify kubelet serving certificates. Without this the API server
      # accepts ANY certificate from a kubelet, which is a real MITM gap.
      - --kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt

      # ── HARDENING MISC ────────────────────────────────────────────
      # pprof endpoints leak internal state and are a DoS vector.
      - --profiling=false
      # Bound long-running requests.
      - --request-timeout=60s
      # Cap in-flight requests so a single client cannot exhaust the server.
      - --max-requests-inflight=400
      - --max-mutating-requests-inflight=200
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Remember: any flag pointing at a file needs a matching hostPath     │
   │  volume and volumeMount, or the API server will not start.           │
   │  See kubeconfig-and-manifests.md.                                     │
   └──────────────────────────────────────────────────────────────────────┘
```

Verify anonymous access is genuinely off:

```bash
# Should return 401, not 403 and not a body.
curl -sk https://127.0.0.1:6443/api/v1/namespaces -o /dev/null -w '%{http_code}\n'
# 401

# What can an anonymous user do?
kubectl auth can-i --list --as=system:anonymous 2>&1 | head
```

### kube-controller-manager and kube-scheduler

Smaller surfaces, three flags each.

```yaml
# kube-controller-manager.yaml
      - --bind-address=127.0.0.1      # not reachable off-node
      - --profiling=false
      # Each controller authenticates as its own ServiceAccount rather
      # than using the controller-manager's blanket identity. This makes
      # the audit log meaningful and limits blast radius.
      - --use-service-account-credentials=true
      - --terminated-pod-gc-threshold=1000
```

```yaml
# kube-scheduler.yaml
      - --bind-address=127.0.0.1
      - --profiling=false
```

The controller manager holds `ca.key` in order to sign CSRs, which makes it exactly as sensitive as the API server. Anyone who can exec into it can mint certificates.

---

## etcd Hardening

etcd is the cluster. Every Secret, every RBAC binding, every object.

```yaml
# /etc/kubernetes/manifests/etcd.yaml
      - --cert-file=/etc/kubernetes/pki/etcd/server.crt
      - --key-file=/etc/kubernetes/pki/etcd/server.key
      - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
      - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
      - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
      - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt

      # Mutual TLS mandatory in BOTH directions. Without these, a client
      # that can reach the port needs no credential at all.
      - --client-cert-auth=true
      - --peer-client-cert-auth=true

      # Listen only on loopback (for the local API server) and the peer
      # network. NEVER 0.0.0.0.
      - --listen-client-urls=https://127.0.0.1:2379,https://192.168.1.10:2379
      - --listen-peer-urls=https://192.168.1.10:2380
```

Firewall it regardless, because defence in depth matters most for the thing that holds everything:

```bash
# Only control plane peers may reach etcd.
for peer in 192.168.1.11 192.168.1.12; do
  sudo iptables -A INPUT -p tcp -s "$peer" --dport 2379:2380 -j ACCEPT
done
sudo iptables -A INPUT -p tcp --dport 2379:2380 -j DROP
```

Prove it is not exposed:

```bash
# From a worker node or anywhere off the control plane. Should fail.
curl -sk --max-time 5 https://192.168.1.10:2379/version && echo "EXPOSED" \
  || echo "correctly refused"
```

Three further controls, each with its own document:

- **Encrypt at rest**, so a snapshot is not a credential dump. See [encryption-at-rest.md](encryption-at-rest.md).
- **Encrypt backups**, since they contain the same data. See [etcd-backup-restore.md](etcd-backup-restore.md).
- **Restrict the data directory**: `/var/lib/etcd` should be mode 700, root owned.

```bash
sudo stat -c '%a %U:%G' /var/lib/etcd
# 700 root:root
```

---

## Kubelet Hardening

The most commonly neglected component, and the one that gives an attacker the most for the least effort. The kubelet API on port 10250 can execute commands in any pod on the node.

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

authentication:
  anonymous:
    # Critical. Anonymous access to 10250 means anyone who can reach the
    # port can exec into every pod on the node.
    enabled: false
  webhook:
    # Delegate authentication to the API server via TokenReview.
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt

authorization:
  # Webhook delegates to the API server's authorizer via
  # SubjectAccessReview. AlwaysAllow means no authorization at all.
  mode: Webhook

# The legacy unauthenticated read-only API. 0 disables it.
# It leaks the full pod spec of everything on the node, including
# env vars, which routinely contain credentials.
readOnlyPort: 0

# Honour the kernel parameter defaults the kubelet expects rather than
# silently overwriting them.
protectKernelDefaults: true

# Let the kubelet manage its iptables chains.
makeIPTablesUtilChains: true

# Close idle exec and port-forward streams.
streamingConnectionIdleTimeout: 5m

# Rate limit event creation to protect etcd.
eventRecordQPS: 5

# Apply RuntimeDefault seccomp to pods that do not specify a profile.
# Very high value, very low risk.
seccompDefault: true

# Rotate the client certificate automatically.
rotateCertificates: true
# Request a proper serving certificate from the cluster CA rather than
# self-signing. Note: these CSRs are NOT auto-approved.
serverTLSBootstrap: true

tlsCipherSuites:
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
```

```bash
sudo systemctl restart kubelet
sudo systemctl status kubelet
```

### Verifying the Kubelet Is Not Open

Run this from a pod or another node, not from the node itself.

```bash
NODE=192.168.1.21

# Read-only port. Should refuse to connect.
curl -s --max-time 5 "http://${NODE}:10255/pods" \
  && echo "!! READ-ONLY PORT EXPOSED" || echo "10255 closed"

# Authenticated port, anonymously. Should be 401.
curl -sk --max-time 5 "https://${NODE}:10250/pods" -o /dev/null -w '%{http_code}\n'
# 401 = good. 200 = anonymous auth is ON and every pod on that node is exposed.
```

A `200` from that second command is one of the most serious findings possible in a Kubernetes cluster. It means anyone with network reach to the node can list pods and, via `/run` and `/exec`, execute arbitrary commands inside them with no credential whatsoever.

Remember also that direct kubelet access is **invisible to the API server audit log**. See [audit-logging.md](audit-logging.md).

---

## Node OS Hardening

The layer beneath Kubernetes, and outside its control.

```bash
# ── File permissions on cluster credentials ────────────────────────
sudo chmod 700 /etc/kubernetes/pki
sudo chmod 600 /etc/kubernetes/pki/*.key
sudo chmod 600 /etc/kubernetes/pki/etcd/*.key
sudo chmod 600 /etc/kubernetes/*.conf
sudo chmod 700 /var/lib/etcd
sudo chmod 600 /var/lib/kubelet/config.yaml
sudo chown -R root:root /etc/kubernetes

# Verify nothing is world readable
sudo find /etc/kubernetes -type f -perm /o+r -ls
```

```bash
# ── Kernel parameters ──────────────────────────────────────────────
cat <<'EOF' | sudo tee /etc/sysctl.d/99-k8s-hardening.conf
# Required by Kubernetes networking
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# Hardening
kernel.dmesg_restrict               = 1
kernel.kptr_restrict                = 2
kernel.yama.ptrace_scope            = 1
fs.protected_hardlinks              = 1
fs.protected_symlinks               = 1
net.ipv4.conf.all.rp_filter         = 1
net.ipv4.conf.all.accept_redirects  = 0
net.ipv4.conf.all.send_redirects    = 0
EOF
sudo sysctl --system
```

Note `kernel.yama.ptrace_scope = 1`. It restricts `ptrace` to direct descendants, which blunts attack path A4 even when `SYS_PTRACE` is somehow available.

```bash
# ── Swap must be off ───────────────────────────────────────────────
# The kubelet historically refused to start with swap enabled, and
# swap undermines memory limits and can page secrets to disk.
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
```

```bash
# ── auditd rules for Kubernetes binaries ───────────────────────────
cat <<'EOF' | sudo tee /etc/audit/rules.d/k8s.rules
-w /usr/bin/kubelet          -p x    -k kubelet_exec
-w /usr/bin/kubeadm          -p x    -k kubeadm_exec
-w /usr/local/bin/runc       -p x    -k runc_exec
-w /etc/kubernetes/          -p wa   -k k8s_config
-w /etc/kubernetes/pki/      -p wa   -k k8s_pki
-w /var/lib/kubelet/         -p wa   -k kubelet_data
-w /var/lib/etcd/            -p wa   -k etcd_data
-w /etc/containerd/config.toml -p wa -k containerd_config
EOF
sudo augenrules --load
sudo systemctl restart auditd

# Query later
sudo ausearch -k k8s_pki -ts recent
```

This is the layer that catches an intruder who already has node access, which the API audit log cannot see.

Beyond that: minimal OS install, no shared SSH keys across nodes, no kubeconfigs left on workers, and unattended security updates.

```bash
# A frequent finding: admin.conf copied to a worker "temporarily"
sudo find / -name 'admin.conf' -o -name 'super-admin.conf' 2>/dev/null
```

---

## Workload Hardening

The controls with the widest blast-radius reduction per unit of effort.

```yaml
apiVersion: v1
kind: Pod
spec:
  # 1. No API credential unless the workload actually calls the API.
  automountServiceAccountToken: false

  # 2. No host namespaces.
  hostNetwork: false
  hostPID: false
  hostIPC: false

  securityContext:
    # 3. Never root.
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    # 4. Syscall filtering.
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: app
      # 5. Immutable, verified image reference.
      image: registry.internal.example.com/app@sha256:9f2a7c...
      securityContext:
        # 6. No setuid escalation.
        allowPrivilegeEscalation: false
        privileged: false
        # 7. Immutable filesystem.
        readOnlyRootFilesystem: true
        # 8. No capabilities at all.
        capabilities:
          drop: ["ALL"]
      # 9. Bounded resources, so one pod cannot starve a node.
      resources:
        requests: { cpu: 100m, memory: 128Mi }
        limits:   { cpu: 500m, memory: 512Mi }

  # 10. No hostPath. Anywhere. Ever, in application workloads.
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
```

Rather than policing this per manifest, enforce it at the namespace level with Pod Security Admission, which covers items 2, 3, 4, 6, 7, 8 and 10 automatically:

```bash
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.31 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted \
  --overwrite
```

And disable token automounting cluster wide:

```bash
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in kube-system|kube-public|kube-node-lease) continue ;; esac
  kubectl patch serviceaccount default -n "$ns" \
    -p '{"automountServiceAccountToken": false}' 2>/dev/null
done
```

Full detail in [pod-security-standards.md](pod-security-standards.md) and [security-context.md](security-context.md).

---

## Network Hardening

By default every pod can reach every other pod in the cluster. That is a flat network with no segmentation.

### Default Deny Everywhere

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  # Empty selector = every pod in this namespace.
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  # No rules = deny everything in both directions.
```

Then allow only what is needed. DNS is almost always the first exception, and forgetting it produces baffling failures:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: production
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

Apply default-deny to every namespace:

```bash
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in kube-system|kube-public|kube-node-lease) continue ;; esac
  kubectl apply -n "$ns" -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
EOF
done
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  NetworkPolicy does NOT apply to pods with hostNetwork: true.        │
   │  They use the host's network namespace and bypass it entirely.       │
   │  This is another reason Pod Security `restricted` matters.           │
   └──────────────────────────────────────────────────────────────────────┘
```

Full treatment in [network-policy.md](network-policy.md).

---

## The Metadata Endpoint

On any cloud, `169.254.169.254` returns the node's IAM credentials to whoever asks. A compromised pod that can reach it inherits the node's cloud permissions, which are frequently far broader than the pod's.

```bash
# From inside a pod on a cloud cluster, if unprotected:
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

This is one of the most reliably exploited paths in real cloud Kubernetes incidents.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-cloud-metadata
  namespace: production
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32     # cloud metadata
              - 169.254.170.2/32       # ECS task metadata
              - 10.0.0.0/8             # keep internal traffic explicit
              - 172.16.0.0/12
              - 192.168.0.0/16
```

Better still, use the cloud's workload identity mechanism (IRSA on EKS, Workload Identity on GKE, Managed Identity on AKS) so pods get scoped credentials directly and the node role is minimal.

---

## Multi-Tenancy: An Honest Assessment

A namespace is not a security boundary. This needs saying plainly, because a great deal of architecture is built on the assumption that it is.

| Isolated by a namespace? | |
|---|---|
| Object names and RBAC scope | ✅ Yes |
| ResourceQuota and LimitRange | ✅ Yes |
| Network traffic | ❌ **No**, not without NetworkPolicy |
| The node kernel | ❌ **No**, pods from different namespaces share nodes |
| Node filesystem | ❌ **No**, if hostPath is permitted |
| CPU cache and memory bus | ❌ **No**, side channels are possible |
| The control plane | ❌ **No**, shared API server and etcd |
| CRDs and other cluster-scoped objects | ❌ **No**, they are cluster-wide |
| DNS | ❌ **No**, every service is resolvable cluster-wide by default |

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  SOFT MULTI-TENANCY   namespaces + RBAC + quotas + NetworkPolicy     │
   │                       + Pod Security                                 │
   │     Appropriate for: teams within one organisation that trust        │
   │     each other and share a blast radius.                             │
   ├──────────────────────────────────────────────────────────────────────┤
   │  HARDENED             the above + RuntimeClass sandboxing + node     │
   │                       pools per tenant + no shared nodes             │
   │     Appropriate for: semi-trusted workloads, internal customers.     │
   ├──────────────────────────────────────────────────────────────────────┤
   │  HARD MULTI-TENANCY   SEPARATE CLUSTERS                              │
   │     Appropriate for: mutually hostile tenants, regulated             │
   │     separation, anything where a kernel bug must not cross the       │
   │     boundary.                                                        │
   │                                                                      │
   │  If the consequence of a tenant escape is unacceptable, the answer   │
   │  is separate clusters. It always has been.                           │
   └──────────────────────────────────────────────────────────────────────┘
```

See [runtime-class.md](runtime-class.md) for the middle tier.

---

## CIS Benchmark and kube-bench

The CIS Kubernetes Benchmark is a structured checklist of configuration controls. `kube-bench` automates checking against it.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-master
  namespace: kube-system
spec:
  template:
    spec:
      restartPolicy: Never
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:latest
          command: ["kube-bench", "run", "--targets", "master"]
          volumeMounts:
            - { name: var-lib-etcd,   mountPath: /var/lib/etcd,   readOnly: true }
            - { name: var-lib-kubelet,mountPath: /var/lib/kubelet,readOnly: true }
            - { name: etc-kubernetes, mountPath: /etc/kubernetes, readOnly: true }
            - { name: usr-bin,        mountPath: /usr/local/mount-from-host/bin, readOnly: true }
      volumes:
        - { name: var-lib-etcd,    hostPath: { path: /var/lib/etcd } }
        - { name: var-lib-kubelet, hostPath: { path: /var/lib/kubelet } }
        - { name: etc-kubernetes,  hostPath: { path: /etc/kubernetes } }
        - { name: usr-bin,         hostPath: { path: /usr/bin } }
```

```bash
kubectl apply -f kube-bench-master.yaml
kubectl -n kube-system logs job/kube-bench-master

# Just the failures
kubectl -n kube-system logs job/kube-bench-master | grep -E '^\[FAIL\]'
```

### Triaging the Output

Not every FAIL is real. On a kubeadm cluster several are expected:

| Common FAIL | Verdict |
|---|---|
| "Ensure that the --kubelet-certificate-authority argument is set" | **Real.** Fix it. |
| "Ensure anonymous-auth is false" | **Real.** Fix it immediately. |
| "Ensure that the admission control plugin PodSecurityPolicy is set" | False positive on modern clusters. PSP was removed; PodSecurity replaces it. |
| "Ensure that the --peer-cert-file argument is set" on a single-node etcd | Low priority. No peers exist. |
| File permission checks on paths that do not exist in your layout | Layout difference, not a finding. |
| "Ensure that the --encryption-provider-config is set" | **Real** if you hold sensitive data. |

Run it, then work the genuine FAILs in the order given by the roadmap below rather than top to bottom.

---

## Runtime Detection With Falco

Admission control stops bad *configuration*. It cannot stop bad *behaviour* from an already-admitted pod. Falco watches syscalls and alerts on suspicious activity.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  ADMISSION                          RUNTIME DETECTION                │
   │  "may this pod exist?"              "what is this pod doing?"        │
   │                                                                      │
   │  blocks privileged: true            notices a shell spawned in a     │
   │  blocks hostPath                    container that should never      │
   │  blocks :latest                     spawn one                        │
   │                                                                      │
   │  one decision, at creation          continuous                       │
   └──────────────────────────────────────────────────────────────────────┘
```

Falco gets syscall data either from a kernel module or, preferably, a modern eBPF probe:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true
```

`modern_ebpf` uses CO-RE and needs no kernel headers or module compilation, which removes the main operational pain of running Falco. See [ebpf.md](ebpf.md).

Rules worth understanding:

```yaml
- rule: Terminal shell in container
  desc: A shell was spawned inside a container, which for most workloads
        should never happen in normal operation.
  condition: >
    spawned_process and container
    and shell_procs and proc.tty != 0
    and container_entrypoint
  output: >
    Shell spawned in container (user=%user.name container=%container.name
    shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline
    pod=%k8s.pod.name ns=%k8s.ns.name)
  priority: NOTICE

- rule: Read sensitive file untrusted
  desc: An unexpected process read a credential file.
  condition: >
    open_read and sensitive_files and not proc.name in (known_readers)
  output: >
    Sensitive file opened for reading (user=%user.name file=%fd.name
    pod=%k8s.pod.name ns=%k8s.ns.name)
  priority: WARNING

- rule: Contact cloud metadata service
  desc: A pod reached the cloud instance metadata endpoint.
  condition: >
    outbound and fd.sip="169.254.169.254" and container
  output: >
    Pod contacted cloud metadata (pod=%k8s.pod.name ns=%k8s.ns.name
    command=%proc.cmdline)
  priority: WARNING
```

What Falco catches that admission cannot: a process spawning a shell, reading `/etc/shadow`, opening an outbound connection to an unexpected address, writing below `/etc`, or loading a kernel module. All of these are behaviours of a pod that was perfectly compliant at admission time.

---

## Testing Your Own Cluster

Assess your own infrastructure, with authorisation, before someone else does.

### The External View

```bash
# What is listening on a node?
nmap -Pn -p 6443,2379,2380,10250,10255,10256,30000-32767 192.168.1.21

# Ports that should NEVER be open to a general network:
#   2379, 2380   etcd
#   10250        kubelet API
#   10255        kubelet read-only (should not exist at all)
```

```bash
# kube-hunter, for a structured external assessment
kubectl run kube-hunter --rm -it --restart=Never \
  --image=aquasec/kube-hunter -- --remote 192.168.1.21
```

### The "Can I Escalate From This Pod" Methodology

The single most useful exercise you can run. Land in a normal pod and work outward.

```bash
kubectl run assess --rm -it --image=nicolaka/netshoot --restart=Never -- bash
```

Then, inside:

```bash
# ── 1. Do I have an API credential at all? ─────────────────────────
ls -la /var/run/secrets/kubernetes.io/serviceaccount/
# If this directory is absent, automountServiceAccountToken is off.
# That is the desired state.

TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null)
NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# ── 2. What can that credential do? ────────────────────────────────
curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" \
  -X POST "https://kubernetes.default.svc/apis/authorization.k8s.io/v1/selfsubjectrulesreviews" \
  -H 'Content-Type: application/json' \
  -d "{\"spec\":{\"namespace\":\"$NS\"}}" | jq '.status.resourceRules'

# The dangerous answers: secrets get/list, pods create, pods/exec create,
# serviceaccounts/token create, any escalate or bind verb.

# ── 3. Am I root? What capabilities do I hold? ─────────────────────
id
grep CapEff /proc/1/status
capsh --decode=$(grep CapEff /proc/1/status | awk '{print $2}')
# CapEff 0000000000000000 is the goal.

# ── 4. Is the host filesystem reachable? ───────────────────────────
ls /host 2>/dev/null && echo "!! hostPath mount present"
mount | grep -E '/etc/kubernetes|/var/run/docker.sock|containerd.sock'

# ── 5. Can I see host processes? ───────────────────────────────────
ps aux | wc -l
# A large number including systemd means hostPID is on.

# ── 6. Cloud metadata reachable? ───────────────────────────────────
curl -s --max-time 3 http://169.254.169.254/latest/meta-data/ \
  && echo "!! METADATA REACHABLE" || echo "metadata blocked"

# ── 7. Is the kubelet reachable and open? ──────────────────────────
NODE=$(getent hosts kubernetes.default | awk '{print $1}')
curl -sk --max-time 3 "https://${NODE}:10250/pods" -o /dev/null -w '%{http_code}\n'
# 401 good, 200 catastrophic

# ── 8. Is the network flat? ────────────────────────────────────────
# Can I reach a pod in another namespace I have no business reaching?
nc -zv -w2 <some-other-namespace-pod-ip> 80
```

Every "yes" in that list is a finding with a named remedy in the table at the top of this document.

---

## Prioritised Roadmap

Ordered by risk reduced per hour of effort, which is not the order the CIS benchmark presents them in.

| # | Control | Effort | Risk reduced | Where |
|---|---|---|---|---|
| 1 | `--anonymous-auth=false` on the API server | minutes | **Critical** | [Control Plane](#control-plane-hardening) |
| 2 | Kubelet `anonymous.enabled: false`, `readOnlyPort: 0`, `authorization.mode: Webhook` | minutes | **Critical** | [Kubelet](#kubelet-hardening) |
| 3 | etcd not listening on a public interface, client cert auth on | minutes | **Critical** | [etcd](#etcd-hardening) |
| 4 | `automountServiceAccountToken: false` on every default SA | 1 hour | **High** | [Workload](#workload-hardening) |
| 5 | `NodeRestriction` admission enabled | minutes | **High** | [Control Plane](#control-plane-hardening) |
| 6 | Pod Security `warn`/`audit: restricted` everywhere (observe only) | 1 hour | Enables everything else | [pod-security-standards.md](pod-security-standards.md) |
| 7 | Audit logging enabled with a real policy | half day | **High**, forensics | [audit-logging.md](audit-logging.md) |
| 8 | Default-deny NetworkPolicy per namespace | 1 to 3 days | **High** | [network-policy.md](network-policy.md) |
| 9 | Block the cloud metadata endpoint | 1 hour | **High** on cloud | [Metadata](#the-metadata-endpoint) |
| 10 | Pod Security `enforce: baseline` | days | **High** | [pod-security-standards.md](pod-security-standards.md) |
| 11 | RBAC review, remove wildcards and stray cluster-admin | 2 to 5 days | **High** | [rbac.md](rbac.md) |
| 12 | Encryption at rest for Secrets | half day | Medium to High | [encryption-at-rest.md](encryption-at-rest.md) |
| 13 | `seccompDefault: true` on the kubelet | minutes | Medium | [Kubelet](#kubelet-hardening) |
| 14 | Registry allowlist at admission | 1 day | Medium | [image-security.md](image-security.md) |
| 15 | Pod Security `enforce: restricted` | weeks | **High** | [pod-security-standards.md](pod-security-standards.md) |
| 16 | Image scanning in CI, gated on criticals | days | Medium | [image-security.md](image-security.md) |
| 17 | `--kubelet-certificate-authority` set | 1 hour | Medium | [certificates.md](certificates.md) |
| 18 | Image signing and admission verification | 1 to 2 weeks | Medium | [image-security.md](image-security.md) |
| 19 | Falco runtime detection | 1 week | Medium, detection | [Falco](#runtime-detection-with-falco) |
| 20 | RuntimeClass sandboxing for untrusted workloads | 2+ weeks | High **if applicable** | [runtime-class.md](runtime-class.md) |

Items 1 to 5 take under an hour in total and close the paths most likely to be exploited. If you do nothing else this week, do those.

---

## The Checklist

```
CONTROL PLANE
  ☐ --anonymous-auth=false
  ☐ --authorization-mode=Node,RBAC
  ☐ --enable-admission-plugins includes NodeRestriction
  ☐ --enable-admission-plugins includes PodSecurity
  ☐ --audit-policy-file and --audit-log-path set
  ☐ --encryption-provider-config set
  ☐ --profiling=false
  ☐ --service-account-lookup=true
  ☐ --kubelet-certificate-authority set
  ☐ --tls-min-version=VersionTLS12 and a modern cipher list
  ☐ controller-manager and scheduler --bind-address=127.0.0.1
  ☐ controller-manager --use-service-account-credentials=true

etcd
  ☐ --client-cert-auth=true and --peer-client-cert-auth=true
  ☐ not listening on 0.0.0.0
  ☐ 2379 and 2380 firewalled to control plane peers only
  ☐ /var/lib/etcd is mode 700, root owned
  ☐ encryption at rest enabled
  ☐ backups taken, encrypted, and RESTORE TESTED

KUBELET (every node)
  ☐ authentication.anonymous.enabled = false
  ☐ authorization.mode = Webhook
  ☐ readOnlyPort = 0
  ☐ protectKernelDefaults = true
  ☐ seccompDefault = true
  ☐ streamingConnectionIdleTimeout set
  ☐ rotateCertificates = true
  ☐ curl to :10250 from off-node returns 401
  ☐ :10255 refuses to connect

NODE OS
  ☐ /etc/kubernetes mode 700, keys 600, root owned
  ☐ swap disabled
  ☐ hardening sysctls applied
  ☐ auditd rules for kubernetes binaries and paths
  ☐ no admin.conf on worker nodes
  ☐ automatic security updates enabled
  ☐ SSH restricted, no shared keys across nodes

WORKLOADS
  ☐ Pod Security enforce at baseline minimum, restricted preferred
  ☐ warn and audit set alongside enforce
  ☐ enforce-version pinned
  ☐ automountServiceAccountToken false on every default SA
  ☐ no privileged containers outside kube-system and CNI/CSI
  ☐ no hostPath in application namespaces
  ☐ resource requests and limits on everything

NETWORK
  ☐ default-deny NetworkPolicy in every application namespace
  ☐ DNS egress explicitly allowed
  ☐ cloud metadata endpoint blocked
  ☐ ingress controller TLS configured and modern

IDENTITY
  ☐ no wildcard verbs or resources in custom ClusterRoles
  ☐ cluster-admin bound to as few subjects as possible
  ☐ no ServiceAccount with cluster-admin
  ☐ super-admin.conf not in anyone's ~/.kube/config
  ☐ certificate expiry monitored

SUPPLY CHAIN
  ☐ registry allowlist enforced at admission
  ☐ images pinned by digest in production
  ☐ CI scanning gated on CRITICAL
  ☐ base images minimal

DETECTION
  ☐ audit logs shipped off-node to append-only storage
  ☐ alerts on RBAC changes, exec, secret reads, anonymous requests
  ☐ runtime detection deployed
```

---

## Command Reference

```bash
# ---------- Quick posture assessment ----------
sudo grep -E 'anonymous-auth|authorization-mode|enable-admission-plugins|audit-policy|encryption-provider|profiling' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
sudo grep -E 'anonymous|authorization|readOnlyPort|seccompDefault|protectKernelDefaults' \
  /var/lib/kubelet/config.yaml
kubectl get ns -o custom-columns='NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'

# ---------- Anonymous access ----------
curl -sk https://127.0.0.1:6443/api/v1/namespaces -o /dev/null -w '%{http_code}\n'
kubectl auth can-i --list --as=system:anonymous

# ---------- Kubelet exposure (run from OFF the node) ----------
curl -sk --max-time 5 https://NODE_IP:10250/pods -o /dev/null -w '%{http_code}\n'
curl -s  --max-time 5 http://NODE_IP:10255/pods -o /dev/null -w '%{http_code}\n'

# ---------- etcd exposure ----------
curl -sk --max-time 5 https://NODE_IP:2379/version

# ---------- Dangerous workloads ----------
kubectl get pods -A -o json | jq -r '
  .items[] | . as $p | .spec.containers[]
  | select(.securityContext.privileged == true)
  | "PRIVILEGED \($p.metadata.namespace)/\($p.metadata.name)"'

kubectl get pods -A -o json | jq -r '
  .items[] | select(.spec.hostNetwork or .spec.hostPID or .spec.hostIPC)
  | "HOSTNS \(.metadata.namespace)/\(.metadata.name)"'

kubectl get pods -A -o json | jq -r '
  .items[] | select(.spec.volumes[]?.hostPath)
  | "HOSTPATH \(.metadata.namespace)/\(.metadata.name)"'

# ---------- Dangerous RBAC ----------
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name == "cluster-admin")
  | "\(.metadata.name): \(.subjects // [] | map(.kind+"/"+.name) | join(", "))"'

kubectl get clusterroles -o json | jq -r '
  .items[] | select(.metadata.name | startswith("system:") | not)
  | select(.rules[]? | (.verbs[]? == "*") and (.resources[]? == "*"))
  | "WILDCARD \(.metadata.name)"'

# ---------- Namespaces without NetworkPolicy ----------
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  [ "$(kubectl get netpol -n "$ns" -o name 2>/dev/null | wc -l)" -eq 0 ] \
    && echo "NO NETPOL: $ns"
done

# ---------- Benchmarks ----------
kubectl apply -f kube-bench-master.yaml
kubectl -n kube-system logs job/kube-bench-master | grep '^\[FAIL\]'
```

---

## Exam and Interview Traps

1. **Name the 4Cs.** Cloud, Cluster, Container, Code. Each layer depends on the one outside it.

2. **Single highest-value API server flag?** `--anonymous-auth=false`.

3. **Why is the kubelet read-only port dangerous?** Port 10255 serves the full pod spec unauthenticated, including environment variables that routinely hold credentials. Set `readOnlyPort: 0`.

4. **What does an unauthenticated `200` from port 10250 mean?** Anyone with network reach can exec into every pod on that node with no credential. One of the most serious possible findings.

5. **Is a namespace a security boundary?** No. It scopes names and RBAC. It does not isolate the network, the kernel, the node filesystem or the control plane.

6. **When do you need separate clusters?** When a tenant escape would be unacceptable. Namespaces and even sandboxing do not give you a hard boundary.

7. **Why must `NodeRestriction` accompany the Node authorizer?** The authorizer cannot inspect the request body. NodeRestriction stops a kubelet setting arbitrary labels or taints on its own Node object.

8. **What does a `privileged: true` pod give an attacker?** Node root, via mounting the host disk and chrooting. From there, `/etc/kubernetes/pki/ca.key` and an unrevocable forged admin certificate.

9. **Which single file compromise equals total cluster compromise?** `/etc/kubernetes/pki/ca.key`.

10. **Does NetworkPolicy apply to `hostNetwork: true` pods?** No. They bypass it entirely.

11. **Why block `169.254.169.254`?** It serves the node's cloud IAM credentials to any pod that asks, which are usually far broader than the pod's own permissions.

12. **What does Falco catch that admission control cannot?** Behaviour rather than configuration: a shell spawning in a container, a sensitive file being read, an unexpected outbound connection. Admission decides once, at creation.

13. **Are all kube-bench FAILs real?** No. PodSecurityPolicy checks are obsolete, and single-node etcd peer checks are irrelevant. Triage rather than chase the score.

14. **Is direct kubelet access recorded in the audit log?** No. The API server audit log only sees requests to the API server. Direct access to port 10250 is a blind spot, which is why kubelet authn and authz matter so much.

15. **What are the first five things to fix on an unhardened cluster?** API server anonymous auth, kubelet anonymous auth and read-only port, etcd exposure, `automountServiceAccountToken`, and `NodeRestriction`. Under an hour, largest risk reduction available.

---

## Related Topics

- [authentication.md](authentication.md) for identity
- [authorization.md](authorization.md) for the authorizer chain
- [rbac.md](rbac.md) for least privilege
- [service-accounts.md](service-accounts.md) for workload identity and token automounting
- [admission-controllers.md](admission-controllers.md) for policy enforcement
- [pod-security-standards.md](pod-security-standards.md) for workload baselines
- [security-context.md](security-context.md) for the pod-level fields
- [encryption-at-rest.md](encryption-at-rest.md) for protecting etcd data
- [audit-logging.md](audit-logging.md) for the forensic record
- [image-security.md](image-security.md) for the supply chain
- [runtime-class.md](runtime-class.md) for stronger isolation
- [certificates.md](certificates.md) for the PKI an attacker targets
- [network-policy.md](network-policy.md) for segmentation
- [kubelet.md](kubelet.md) and [kube-apiserver.md](kube-apiserver.md) for the components
- [etcd-backup-restore.md](etcd-backup-restore.md) and [disaster-recovery.md](disaster-recovery.md) for recovery

---

## Key Takeaways

- Security layers as Cloud, Cluster, Container, Code. Cluster controls cannot compensate for a compromised layer beneath them.
- The five highest-value fixes take under an hour: API server anonymous auth off, kubelet anonymous auth off and read-only port closed, etcd not publicly reachable, token automounting disabled, `NodeRestriction` enabled.
- The kubelet is the most neglected component and the cheapest win for an attacker. An unauthenticated port 10250 is equivalent to handing over every pod on the node.
- Almost every pod-escape path terminates at `/etc/kubernetes/pki/ca.key`, because node root means an unrevocable forged cluster-admin certificate.
- `privileged: true`, `hostPath`, `hostPID` and `hostNetwork` are the four fields that turn a pod compromise into a node compromise. Pod Security `restricted` blocks all four.
- A namespace is not a security boundary. It does not isolate the network, the kernel or the node. If a tenant escape is unacceptable, use separate clusters.
- The cluster network is flat by default. Default-deny NetworkPolicy per namespace, and remember to allow DNS.
- On cloud, block `169.254.169.254` or any compromised pod inherits the node's IAM permissions.
- Admission control governs configuration; runtime detection governs behaviour. You need both, and they catch different things.
- Direct kubelet access does not appear in the API audit log. Harden the kubelet and run node-level auditing to cover that gap.
- Run kube-bench, but triage the output. Chasing a perfect score wastes effort on obsolete and irrelevant checks.
- Assess your own cluster from inside a pod. The "can I escalate from here" walkthrough finds more real problems in an hour than any document.

---

## References

- [Kubernetes Security Concepts](https://kubernetes.io/docs/concepts/security/)
- [Securing a Cluster](https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/)
- [Cloud Native Security Overview](https://kubernetes.io/docs/concepts/security/overview/)
- [Controlling Access to the Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)
- [Kubelet Authentication and Authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/)
- [Kubelet Configuration Reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- [Multi-tenancy](https://kubernetes.io/docs/concepts/security/multi-tenancy/)
- [Ports and Protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [kube-bench](https://github.com/aquasecurity/kube-bench)
- [Falco Documentation](https://falco.org/docs/)
