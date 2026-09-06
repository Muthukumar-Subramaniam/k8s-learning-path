# 🔄 Cluster Upgrades

Upgrading a kubeadm cluster is a controlled, one minor version at a time procedure that moves the control plane first, then the workers, while the version skew policy keeps the cluster functional at every intermediate step.

## 📋 Table of Contents

- [Why Upgrades Are Different in Kubernetes](#why-upgrades-are-different-in-kubernetes)
- [The Version Skew Policy](#the-version-skew-policy)
- [Release Cadence and Support Window](#release-cadence-and-support-window)
- [API Deprecation and Removal](#api-deprecation-and-removal)
- [Detecting Deprecated API Usage](#detecting-deprecated-api-usage)
- [Pre Upgrade Checklist](#pre-upgrade-checklist)
- [Upgrade Order at a Glance](#upgrade-order-at-a-glance)
- [Step 1: Upgrade the First Control Plane Node](#step-1-upgrade-the-first-control-plane-node)
- [Step 2: Upgrade Additional Control Plane Nodes](#step-2-upgrade-additional-control-plane-nodes)
- [Step 3: Upgrade the Worker Nodes](#step-3-upgrade-the-worker-nodes)
- [What kubeadm upgrade apply Actually Does](#what-kubeadm-upgrade-apply-actually-does)
- [What kubeadm upgrade node Actually Does](#what-kubeadm-upgrade-node-actually-does)
- [Upgrading Addons Separately](#upgrading-addons-separately)
- [OS Patching as a Separate Concern](#os-patching-as-a-separate-concern)
- [Rollback Reality](#rollback-reality)
- [Post Upgrade Verification](#post-upgrade-verification)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why Upgrades Are Different in Kubernetes

A Kubernetes cluster is not a single program. It is a set of independently versioned binaries that agree on an API contract:

```
┌───────────────────────────────────────────────────────────────────────┐
│                     Independently Versioned Pieces                     │
├───────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  Control plane node                        Worker node                 │
│  ┌──────────────────────────┐              ┌────────────────────────┐  │
│  │ kube-apiserver    vX.Y.Z │◄─────────────┤ kubelet       vX.Y-3.* │  │
│  │ kube-controller-  vX.Y.Z │              │ kube-proxy    vX.Y-3.* │  │
│  │ kube-scheduler    vX.Y.Z │              │ containerd    (own ver)│  │
│  │ etcd        (bundled ver)│              │ CNI plugin    (own ver)│  │
│  │ kubelet           vX.Y.Z │              │ CSI driver    (own ver)│  │
│  └──────────────────────────┘              └────────────────────────┘  │
│                                                                        │
│  Admin workstation                          Cluster addons             │
│  ┌──────────────────────────┐              ┌────────────────────────┐  │
│  │ kubectl   vX.Y+/-1       │              │ CoreDNS, metrics-server│  │
│  │ kubeadm   vX.Y.Z         │              │ ingress controller     │  │
│  └──────────────────────────┘              └────────────────────────┘  │
│                                                                        │
└───────────────────────────────────────────────────────────────────────┘
```

Because they version independently, an upgrade is a rolling operation, not a big bang. The version skew policy is the contract that makes the intermediate, mixed version states safe.

Three separate things are commonly confused, and they are upgraded by three separate procedures:

| Concern | What changes | Tool | Covered by kubeadm? |
|---|---|---|---|
| Kubernetes version | apiserver, scheduler, controller manager, kubelet, kube-proxy, CoreDNS | `kubeadm upgrade` plus the package manager | Yes, partially |
| OS packages and kernel | glibc, kernel, systemd, openssl, containerd | `dnf`, `apt`, `zypper` plus reboot | No |
| Cluster addons | CNI, CSI, ingress controller, metrics-server, MetalLB | Each project's own manifests or Helm chart | No |

Treat each as a separate change window. Combining a Kubernetes minor upgrade with a kernel upgrade and a CNI upgrade in one maintenance window means that when something breaks you have three suspects instead of one.

---

## The Version Skew Policy

Kubernetes publishes a formal, supported skew between components. Staying inside it is the difference between a supported cluster and an experiment.

### The Full Table

| Component | Reference point | Supported skew | Notes |
|---|---|---|---|
| `kube-apiserver` (HA members) | The other `kube-apiserver` instances | Newest and oldest may differ by at most **1 minor version** | This is what makes a rolling control plane upgrade legal at all |
| `kubelet` | The `kube-apiserver` it talks to | Up to **3 minor versions older**, never newer | Widened from 2 to 3 in Kubernetes v1.28 |
| `kube-proxy` | The `kubelet` on the same node | Must match the node's kubelet minor version | And therefore also up to 3 older than the apiserver, never newer |
| `kube-controller-manager` | The `kube-apiserver` it talks to | Up to **1 minor version older**, never newer | Expected to match in a steady state |
| `kube-scheduler` | The `kube-apiserver` it talks to | Up to **1 minor version older**, never newer | Expected to match in a steady state |
| `cloud-controller-manager` | The `kube-apiserver` it talks to | Up to **1 minor version older**, never newer | Same rule as the other controllers |
| `kubectl` | The `kube-apiserver` it talks to | **1 minor version older or newer** | The only component allowed to be newer |
| `kubeadm` | The target cluster version | Used to upgrade **one minor version at a time** | Install the target `kubeadm` before you run the upgrade |

### The Skew Visualised

Assume the API server is at `vX.Y`:

```
                    NEWER  ▲
                           │
   kubectl        vX.Y+1   │  ✅ allowed (kubectl is the only one)
                           │
   ══════════════ vX.Y ════╪════ kube-apiserver (the reference) ══════
                           │
   controller-mgr vX.Y-1   │  ✅ allowed
   scheduler      vX.Y-1   │  ✅ allowed
   kubectl        vX.Y-1   │  ✅ allowed
                           │
   kubelet        vX.Y-1   │  ✅ allowed
   kubelet        vX.Y-2   │  ✅ allowed
   kubelet        vX.Y-3   │  ✅ allowed (since v1.28)
   kubelet        vX.Y-4   │  ❌ unsupported
                           │
   controller-mgr vX.Y-2   │  ❌ unsupported
   scheduler      vX.Y-2   │  ❌ unsupported
                    OLDER  ▼
```

Two rules dominate everything else:

1. **Nothing in the cluster may be newer than the API server**, except `kubectl`.
2. **You upgrade one minor version at a time.** To go from `vX.Y` to `vX.Y+3` you run three separate upgrades, verifying the cluster between each one. There is no supported jump.

### Why One Minor at a Time

`kubeadm upgrade apply` performs schema migrations on its own ConfigMaps, rewrites static pod manifests using the conversion logic of a single release, and upgrades addons using the addon manifests bundled with that release. Skipping a release skips the migration logic for that release. `kubeadm` enforces this and refuses the jump in preflight:

```bash
# This will be rejected by preflight checks
sudo kubeadm upgrade apply vX.Y+2.0
```

### Patch Versions

Patch upgrades within the same minor version (`vX.Y.1` to `vX.Y.7`) are always allowed and can be applied in any order of magnitude, forwards. They contain no API removals and no schema migration. Patch upgrades are the ones you should be applying routinely for CVE remediation.

---

## Release Cadence and Support Window

```
┌────────────────────────────────────────────────────────────────────────┐
│                       Kubernetes Release Timeline                       │
│                                                                         │
│  ~3 minor releases per year (roughly every 4 months)                   │
│                                                                         │
│  vX.Y    ├──── standard patch support (~12 months) ────┤── maint ──┤   │
│  vX.Y+1        ├──── standard patch support ──────────────┤── maint ──┤│
│  vX.Y+2               ├──── standard patch support ──────────┤── ... │ │
│                                                                         │
│  Total patch support per minor release: about 14 months                │
│  (12 months standard + 2 months maintenance mode)                      │
│                                                                         │
│  Only the 3 most recent minor releases receive standard patches.       │
└────────────────────────────────────────────────────────────────────────┘
```

Practical consequences:

- If you upgrade once a year you will always be doing a two or three minor version chain, which means multiple sequential upgrades and multiple maintenance windows. If you upgrade twice a year you stay comfortably inside support with single hops.
- Running an out of support minor version means no CVE patches. That is a security posture decision, not a convenience decision.
- Plan the chain in advance. Going from `vX.Y` to `vX.Y+3` is four cluster states, each of which must be verified.

### Planning a Multi Hop Upgrade

```
Current: vX.Y        Target: vX.Y+3

  ┌────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
  │  vX.Y  │──►│  vX.Y+1  │──►│  vX.Y+2  │──►│  vX.Y+3  │
  └────────┘   └──────────┘   └──────────┘   └──────────┘
       │             │              │              │
   etcd backup   etcd backup    etcd backup    etcd backup
   read notes    read notes     read notes     read notes
   verify        verify         verify         verify
       │             │              │              │
       └── addon compatibility checked at every hop ──┘
```

At every hop, re-check that your CNI, CSI drivers and ingress controller still support the new version. A CNI that supports `vX.Y` and `vX.Y+3` may still have a broken intermediate.

---

## API Deprecation and Removal

Kubernetes removes API versions on a published schedule. This is the single most common cause of a "successful" upgrade that breaks every deployment pipeline the next morning.

### The Deprecation Rules

| API stability level | Minimum deprecation period before removal |
|---|---|
| GA (for example `v1`) | 12 months or 3 releases, whichever is **longer** |
| Beta (for example `v1beta1`) | 9 months or 3 releases, whichever is **longer** |
| Alpha (for example `v1alpha1`) | May be removed in any release with no deprecation period |

Important nuance: a removed API **version** does not mean a removed **resource**. When `extensions/v1beta1 Deployment` was removed, `Deployment` itself did not go away; it lives at `apps/v1`. Your job is to update the `apiVersion` field in your manifests, not to rewrite your workloads.

### What Removal Looks Like In Practice

```
BEFORE removal (deprecated but served)
────────────────────────────────────────────────────────────────
  kubectl apply -f old-manifest.yaml
  Warning: policy/v1beta1 PodDisruptionBudget is deprecated in
  vX.Y+, unavailable in vX.Y+2; use policy/v1 PodDisruptionBudget
  poddisruptionbudget.policy/my-pdb created      ← still works

AFTER removal
────────────────────────────────────────────────────────────────
  kubectl apply -f old-manifest.yaml
  error: unable to recognize "old-manifest.yaml": no matches for
  kind "PodDisruptionBudget" in version "policy/v1beta1"   ← broken
```

Objects that already exist in etcd are automatically served at the new version by the API server's storage conversion layer, so **existing objects do not disappear**. What breaks is:

- Your CI pipelines that `kubectl apply` old manifests.
- Helm charts pinned to old `apiVersion` values.
- Operators and controllers compiled against removed client-go types.
- Anything using `kubectl get <resource>.<removed-version>.<group>`.

### Checking What the Server Actually Serves

```bash
# Every API group and version this server serves right now
kubectl api-versions

# Every resource, with its preferred apiVersion and short names
kubectl api-resources -o wide

# Is a specific version still served?
kubectl api-versions | grep -x 'policy/v1beta1'

# What does the server prefer for a given kind?
kubectl api-resources | grep -i poddisruptionbudget
```

### kubectl convert

`kubectl convert` rewrites a manifest from one API version to another. It is **not** part of the `kubectl` binary; it is a separate plugin that must be installed.

```bash
# Install the plugin (choose the version matching your kubectl)
K8S_VER="vX.Y.Z"
curl -LO "https://dl.k8s.io/release/${K8S_VER}/bin/linux/amd64/kubectl-convert"
curl -LO "https://dl.k8s.io/release/${K8S_VER}/bin/linux/amd64/kubectl-convert.sha256"
echo "$(cat kubectl-convert.sha256) kubectl-convert" | sha256sum --check
sudo install -o root -g root -m 0755 kubectl-convert /usr/local/bin/kubectl-convert

# Verify
kubectl convert --help
```

```bash
# Convert a single manifest to a target version
kubectl convert -f ./old-pdb.yaml --output-version policy/v1

# Convert and write the result back
kubectl convert -f ./old-pdb.yaml --output-version policy/v1 -o yaml > ./new-pdb.yaml

# Convert everything in a directory
kubectl convert -f ./manifests/ --output-version apps/v1 -o yaml > ./converted.yaml
```

Caveats worth knowing:

- `kubectl convert` uses the **local** binary's conversion knowledge. If the version you are converting *from* was already removed from your local binary's scheme, conversion fails.
- It does not fix semantic changes, only structural ones. If a field changed meaning rather than location, you must fix it by hand.
- The safest workflow is to run `kubectl convert` **before** you upgrade, while the old version is still understood by everything.

---

## Detecting Deprecated API Usage

Do not guess. The API server tells you, in three places.

### 1. The Warning Response Header

Every request to a deprecated API returns an RFC 7234 `Warning` header. `kubectl` prints it to stderr. Client libraries can surface it too.

```bash
# Force the warning to show up explicitly
kubectl get poddisruptionbudgets.v1beta1.policy -A 2>&1 | head
```

```bash
# Suppress warnings when you already know (useful in scripts, dangerous as a habit)
kubectl get pdb -A --warnings-as-errors=false
```

### 2. API Server Metrics

The API server exposes a dedicated gauge for this. It is the best fleet wide signal.

```bash
# Scrape the metric directly through the API
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
```

Sample output shape:

```
# HELP apiserver_requested_deprecated_apis Gauge of deprecated APIs that have been
# requested, broken out by API group, version, resource, subresource and removed_release.
# TYPE apiserver_requested_deprecated_apis gauge
apiserver_requested_deprecated_apis{group="policy",removed_release="1.25",resource="poddisruptionbudgets",subresource="",version="v1beta1"} 1
apiserver_requested_deprecated_apis{group="batch",removed_release="1.25",resource="cronjobs",subresource="",version="v1beta1"} 1
```

The gauge tells you **that** a deprecated API was requested and **when it will be removed**, but not **who** requested it. Join it against `apiserver_request_total` in Prometheus to get the client:

```promql
# Which clients are calling APIs that will be removed in a given release
apiserver_requested_deprecated_apis{removed_release="1.29"}
  * on(group, version, resource, subresource)
  group_right() sum by (group, version, resource, subresource, client) (
    rate(apiserver_request_total[7d])
  )
```

A useful alert:

```yaml
# Prometheus alerting rule
groups:
- name: kubernetes-deprecations
  rules:
  - alert: KubernetesDeprecatedAPIInUse
    expr: apiserver_requested_deprecated_apis > 0
    for: 15m
    labels:
      severity: warning
    annotations:
      summary: "Deprecated API {{ $labels.group }}/{{ $labels.version }} {{ $labels.resource }} in use"
      description: "Scheduled for removal in {{ $labels.removed_release }}. Migrate before upgrading."
```

### 3. Audit Logs

If audit logging is enabled, the API server annotates audit events for deprecated API requests. This is the only source that reliably identifies the caller.

```yaml
# Audit policy fragment: capture metadata for every request so annotations survive
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  omitStages:
  - RequestReceived
```

The relevant annotations on the resulting audit event:

| Annotation | Meaning |
|---|---|
| `k8s.io/deprecated` | Set to `"true"` when the request targeted a deprecated API |
| `k8s.io/removed-release` | The minor release in which the API version will be removed, for example `"1.29"` |

```bash
# Find every deprecated API call and who made it
sudo jq -r 'select(.annotations["k8s.io/deprecated"] == "true")
  | [.annotations["k8s.io/removed-release"],
     .user.username,
     .verb,
     .objectRef.apiGroup + "/" + .objectRef.apiVersion,
     .objectRef.resource,
     .sourceIPs[0]] | @tsv' /var/log/kubernetes/audit.log | sort -u
```

```bash
# Count by caller, most talkative first
sudo jq -r 'select(.annotations["k8s.io/deprecated"] == "true") | .user.username' \
  /var/log/kubernetes/audit.log | sort | uniq -c | sort -rn
```

### Detection Workflow

```
┌─────────────────────────────────────────────────────────────────────┐
│                Deprecated API Migration Workflow                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. Read the target release's "Deprecations and Removals" notes     │
│                          ▼                                           │
│  2. Query apiserver_requested_deprecated_apis for removed_release   │
│     matching the target version                                     │
│                          ▼                                           │
│  3. If any hits, enable/inspect audit logs to identify the caller   │
│                          ▼                                           │
│  4. Fix manifests with kubectl convert; rebuild operator images     │
│                          ▼                                           │
│  5. Re-deploy; confirm the gauge drops back to zero                 │
│                          ▼                                           │
│  6. Only now schedule the upgrade                                   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Pre Upgrade Checklist

Nothing here is optional. The upgrade is not reversible in place, so the checklist is the safety net.

### 1. Back Up etcd

```bash
# On a control plane node
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/backups/etcd-pre-upgrade-$(date +%F-%H%M).db

# Verify the snapshot is readable
sudo ETCDCTL_API=3 etcdctl snapshot status \
  /var/backups/etcd-pre-upgrade-*.db --write-out=table
```

Also back up the PKI and manifests, because an etcd snapshot alone cannot rebuild a control plane:

```bash
sudo tar czf /var/backups/k8s-etc-$(date +%F).tar.gz \
  /etc/kubernetes/pki \
  /etc/kubernetes/manifests \
  /etc/kubernetes/*.conf \
  /var/lib/kubelet/config.yaml \
  /var/lib/kubelet/kubeadm-flags.env
```

Copy both **off the node**. See [etcd-backup-restore.md](etcd-backup-restore.md) for the full procedure and restore path.

### 2. Confirm PDBs Will Not Deadlock the Drain

The drain step uses the Eviction API, which honours PodDisruptionBudgets. A PDB that can never be satisfied will hang the drain forever.

```bash
# List every PDB with its current allowed disruptions
kubectl get pdb -A

# The column that matters is ALLOWED DISRUPTIONS
kubectl get pdb -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,MIN:.spec.minAvailable,MAX:.spec.maxUnavailable,'\
'DESIRED:.status.desiredHealthy,CURRENT:.status.currentHealthy,ALLOWED:.status.disruptionsAllowed'
```

Red flags:

| Condition | Why it deadlocks |
|---|---|
| `ALLOWED = 0` and `CURRENT = DESIRED` | Evicting anything violates the budget; drain blocks indefinitely |
| `minAvailable` equals the replica count | Zero headroom by construction |
| A single replica Deployment with `minAvailable: 1` | The one pod can never be evicted |
| PDB selecting pods with no controller | Evicted pods never come back, so the budget never recovers |

Fix before the window, not during it: scale up temporarily, or relax the PDB, or accept an outage for that workload and delete the PDB for the duration.

### 3. Verify Capacity

Draining a node moves its pods elsewhere. If the remaining nodes cannot fit them, the drain "succeeds" but leaves pods `Pending`.

```bash
# Allocatable versus requested, per node
kubectl describe nodes | grep -A 8 "Allocated resources"

# Quick fleet view
kubectl top nodes

# Sum of requests on the node you are about to drain
kubectl get pods --all-namespaces --field-selector spec.nodeName=<node> \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,'\
'CPU:.spec.containers[*].resources.requests.cpu,MEM:.spec.containers[*].resources.requests.memory'
```

Rule of thumb: with `N` nodes you need roughly `N/(N-1)` headroom to survive draining one at a time. On a three node cluster that is about 50 percent free capacity on each node.

### 4. Read the Release Notes and the Urgent Upgrade Notes

Every Kubernetes release has a `CHANGELOG-X.Y.md` in the `kubernetes/kubernetes` repository. Two sections matter more than the rest:

- **Urgent Upgrade Notes / "Actions Required"**: things that will break if you do nothing.
- **Deprecations and Removals**: the API version removals for this release.

Do not skim. Every genuinely bad upgrade story starts with someone skipping this.

### 5. Confirm CNI and CSI Support

```bash
# What CNI and version is running?
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|flannel|weave'
kubectl get daemonset -n kube-system -o wide

# Calico specifically
kubectl get installation default -o jsonpath='{.status.calicoVersion}' 2>/dev/null; echo
kubectl get pods -n calico-system -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null; echo

# CSI drivers registered in the cluster
kubectl get csidrivers
kubectl get csinodes -o wide

# CSI controller and node plugin images
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}' \
  | grep -i csi
```

Check each project's compatibility matrix against your **target** Kubernetes version. If the CNI needs upgrading too, upgrade the CNI **first** on the old Kubernetes version if it supports both, so you are only changing one variable at a time.

### 6. Certificate Health

`kubeadm upgrade apply` renews control plane certificates by default, but expired certificates can prevent the upgrade from starting because `kubectl` and `kubeadm` cannot authenticate.

```bash
sudo kubeadm certs check-expiration
```

If anything is already expired, renew before upgrading:

```bash
sudo kubeadm certs renew all
sudo systemctl restart kubelet
# Refresh your personal kubeconfig, kubeadm does not touch $HOME/.kube/config
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown "$(id -u):$(id -g)" $HOME/.kube/config
```

### 7. Record the Current State

```bash
kubectl get nodes -o wide > /var/backups/pre-upgrade-nodes.txt
kubectl get pods -A -o wide > /var/backups/pre-upgrade-pods.txt
kubectl get --raw='/readyz?verbose'
kubeadm version -o short
kubelet --version
kubectl version
```

This is the baseline you will compare against afterwards. Without it, "was that pod already crashlooping?" has no answer.

### Checklist Summary

| # | Item | Command or artifact |
|---|---|---|
| 1 | etcd snapshot taken and verified, copied off node | `etcdctl snapshot save` / `snapshot status` |
| 2 | `/etc/kubernetes` tarball taken | `tar czf` |
| 3 | PDBs reviewed, none with zero allowed disruptions | `kubectl get pdb -A` |
| 4 | Spare capacity confirmed | `kubectl describe nodes` |
| 5 | Release notes and urgent upgrade notes read | `CHANGELOG-X.Y.md` |
| 6 | Deprecated API usage is zero | `apiserver_requested_deprecated_apis` |
| 7 | CNI supports target version | Vendor compatibility matrix |
| 8 | CSI drivers support target version | Vendor compatibility matrix |
| 9 | Certificates not expired | `kubeadm certs check-expiration` |
| 10 | Baseline state captured | `kubectl get nodes,pods -A -o wide` |
| 11 | Maintenance window agreed, rollback expectation set | Change record |

---

## Upgrade Order at a Glance

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Upgrade Order (Mandatory)                        │
├────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ PHASE 0: Backup                                              │     │
│   │  etcd snapshot + /etc/kubernetes tarball, copied off cluster  │     │
│   └───────────────────────────┬──────────────────────────────────┘     │
│                               ▼                                         │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ PHASE 1: FIRST control plane node                            │     │
│   │  repo → kubeadm → upgrade plan → upgrade apply               │     │
│   │  → drain → kubelet+kubectl → restart → uncordon              │     │
│   │  (this is the node that upgrades etcd and the addons)        │     │
│   └───────────────────────────┬──────────────────────────────────┘     │
│                               ▼                                         │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ PHASE 2: REMAINING control plane nodes, one at a time        │     │
│   │  repo → kubeadm → kubeadm upgrade node                       │     │
│   │  → drain → kubelet+kubectl → restart → uncordon              │     │
│   └───────────────────────────┬──────────────────────────────────┘     │
│                               ▼                                         │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ PHASE 3: WORKER nodes, one at a time (or small batches)      │     │
│   │  repo → kubeadm → kubeadm upgrade node                       │     │
│   │  → drain → kubelet+kube-proxy pkg → restart → uncordon       │     │
│   └───────────────────────────┬──────────────────────────────────┘     │
│                               ▼                                         │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ PHASE 4: Addons (CNI, CSI, metrics-server, ingress)          │     │
│   └───────────────────────────┬──────────────────────────────────┘     │
│                               ▼                                         │
│   ┌──────────────────────────────────────────────────────────────┐     │
│   │ PHASE 5: Verification                                        │     │
│   └──────────────────────────────────────────────────────────────┘     │
│                                                                         │
│   NEVER upgrade a worker before the control plane.                     │
│   A kubelet newer than the apiserver is unsupported and will misbehave.│
└────────────────────────────────────────────────────────────────────────┘
```

---

## Step 1: Upgrade the First Control Plane Node

This is the node that does the real work: it upgrades etcd, rewrites the shared cluster configuration and upgrades the addons.

### 1.1 Point the Package Repository at the New Minor Version

Since the community moved to `pkgs.k8s.io`, **each minor version has its own repository**. Upgrading without changing the repository URL will only ever find patch versions of the current minor, and `apt-cache madison` will silently show nothing new. This trips up more people than any other step.

**Debian and Ubuntu:**

```bash
# Inspect the current repo definition
cat /etc/apt/sources.list.d/kubernetes.list
# deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
#   https://pkgs.k8s.io/core:/stable:/vX.Y/deb/ /

NEW_MINOR="vX.Y"   # for example v1.31

# Replace the key for the new minor version repo
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

# Repoint the list file
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
```

**RedHat family (RHEL, Rocky, AlmaLinux, Fedora, Oracle Linux):**

```bash
NEW_MINOR="vX.Y"

sudo tee /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo dnf makecache
```

**SUSE (openSUSE, SLES):**

```bash
NEW_MINOR="vX.Y"

sudo zypper removerepo kubernetes 2>/dev/null || true
sudo zypper addrepo --gpgcheck \
  "https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/rpm/" kubernetes
sudo rpm --import "https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/rpm/repodata/repomd.xml.key"
sudo zypper refresh
```

### 1.2 Find the Exact Package Version

```bash
# Debian family
sudo apt-cache madison kubeadm | head
#    kubeadm | X.Y.Z-1.1 | https://pkgs.k8s.io/core:/stable:/vX.Y/deb/  Packages

# RedHat family
sudo dnf --showduplicates list --disableexcludes=kubernetes kubeadm | tail

# SUSE
sudo zypper search -s kubeadm
```

Note the package version format: `X.Y.Z-1.1` for deb and `X.Y.Z-150500.1.1` style for rpm. The Kubernetes version is `vX.Y.Z`; the trailing part is the packaging revision. The workshop script captures exactly this distinction:

```bash
# Pattern used in k8s-workshop/k8s-cluster-upgrade.sh
v_k8s_version="X.Y.Z-1.1"                                  # package version
v_k8s_version_name="v$(echo $v_k8s_version | cut -d '-' -f 1)"  # -> vX.Y.Z for kubeadm
```

### 1.3 Install the Target kubeadm Only

`kubeadm` is upgraded first and alone. `kubelet` and `kubectl` stay behind until after `upgrade apply`.

```bash
# Debian family
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm="${v_k8s_version}" && \
sudo apt-mark hold kubeadm

# RedHat family
sudo dnf install -y kubeadm-"${v_k8s_version}" --disableexcludes=kubernetes

# SUSE
sudo zypper install --oldpackage -y kubeadm="${v_k8s_version}"
```

```bash
# Verify you got what you asked for
kubeadm version -o short
```

The `apt-mark hold` / `dnf exclude` pattern exists so that a routine `apt upgrade` or `dnf update` never drags Kubernetes packages forward accidentally. Keep it.

### 1.4 Run kubeadm upgrade plan

```bash
sudo kubeadm upgrade plan
```

What it prints and what to look for:

```
[upgrade/config] Making sure the configuration is correct:
[upgrade] Running cluster health checks
[upgrade] Fetching available versions to upgrade to
[upgrade/versions] Cluster version: vX.Y-1.Z
[upgrade/versions] kubeadm version: vX.Y.Z

Components that must be upgraded manually after you have upgraded the
control plane with 'kubeadm upgrade apply':
COMPONENT   NODE      CURRENT      TARGET
kubelet     k8s-cp1   vX.Y-1.Z     vX.Y.Z
kubelet     k8s-w1    vX.Y-1.Z     vX.Y.Z
kubelet     k8s-w2    vX.Y-1.Z     vX.Y.Z

Upgrade to the latest stable version:

COMPONENT                 NODE      CURRENT     TARGET
kube-apiserver            k8s-cp1   vX.Y-1.Z    vX.Y.Z
kube-controller-manager   k8s-cp1   vX.Y-1.Z    vX.Y.Z
kube-scheduler            k8s-cp1   vX.Y-1.Z    vX.Y.Z
kube-proxy                          vX.Y-1.Z    vX.Y.Z
CoreDNS                             v1.a.b      v1.c.d
etcd                      k8s-cp1   3.a.b-0     3.c.d-0

You can now apply the upgrade by executing the following command:

        kubeadm upgrade apply vX.Y.Z
```

| Line | Why it matters |
|---|---|
| `Running cluster health checks` | If this fails, stop. Fix the cluster, do not force the upgrade |
| The "manually after" table | Explicit reminder that kubeadm does **not** upgrade kubelet binaries |
| `etcd` row | Confirms the etcd version bump that will happen; this is the risky part |
| `CoreDNS` row | Addon version that `upgrade apply` will change |

If you want to see the actual manifest changes before committing:

```bash
sudo kubeadm upgrade diff vX.Y.Z
```

### 1.5 Apply the Upgrade

```bash
# Dry run first if this is a production cluster you have not rehearsed
sudo kubeadm upgrade apply vX.Y.Z --dry-run

# The real thing
sudo kubeadm upgrade apply vX.Y.Z
```

Useful flags:

| Flag | Effect | When to use |
|---|---|---|
| `--dry-run` | Simulate, write nothing | Always, the first time |
| `-y`, `--yes` | Skip the interactive confirmation | Automation only |
| `--etcd-upgrade=false` | Leave etcd at its current version | External etcd, or a deliberately staged etcd change |
| `--certificate-renewal=false` | Do not renew control plane certificates | Rarely; renewal is a feature, not a nuisance |
| `-f`, `--force` | Bypass some preflight failures | Almost never; you are overriding a safety check |
| `--print-config` | Show the configuration used | Debugging config drift |

This step can take several minutes. It restarts the control plane static pods one at a time and waits for each to become healthy. The API server **will** be briefly unavailable on a single control plane cluster.

### 1.6 Drain the Node

The official ordering drains after `upgrade apply`; the workshop script `k8s-workshop/k8s-cluster-upgrade.sh` drains before it. Both work, because the control plane components are static pods that a drain cannot evict anyway. Draining before simply means user workloads are off the node for longer.

```bash
CP_NODE="k8s-cp1"
kubectl drain "${CP_NODE}" --ignore-daemonsets --delete-emptydir-data

# Confirm
kubectl get nodes
kubectl get pods --all-namespaces -o wide | grep "${CP_NODE}"
```

On a control plane node that is tainted `node-role.kubernetes.io/control-plane:NoSchedule`, the drain is usually trivial: only DaemonSets and static pods live there. On a single node cluster where the taint was removed, this is a real workload move.

### 1.7 Upgrade kubelet and kubectl

```bash
# Debian family
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get update && \
sudo apt-get install -y kubelet="${v_k8s_version}" kubectl="${v_k8s_version}" && \
sudo apt-mark hold kubelet kubectl

# RedHat family
sudo dnf install -y kubelet-"${v_k8s_version}" kubectl-"${v_k8s_version}" \
  --disableexcludes=kubernetes

# SUSE
sudo zypper install --oldpackage -y kubelet="${v_k8s_version}" kubectl="${v_k8s_version}"
```

### 1.8 Restart the kubelet

```bash
sudo systemctl daemon-reload
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager

# Watch it register at the new version
kubectl get nodes -o wide
```

`daemon-reload` is required because the package may have changed the systemd unit or the `10-kubeadm.conf` drop in. Skipping it means systemd keeps running the old unit definition.

### 1.9 Uncordon

```bash
kubectl uncordon "${CP_NODE}"
kubectl get nodes -o wide
```

### The Complete First Control Plane Sequence

```bash
#!/bin/bash
set -euo pipefail

CP_NODE="k8s-cp1"
NEW_MINOR="vX.Y"
v_k8s_version="X.Y.Z-1.1"
v_k8s_version_name="v$(echo "${v_k8s_version}" | cut -d '-' -f 1)"

# 0) Baseline
kubectl get nodes -o wide
kubeadm version -o short
kubelet --version

# 1) Repository
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-cache madison kubeadm | head -3

# 2) kubeadm only
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm="${v_k8s_version}"
sudo apt-mark hold kubeadm
kubeadm version -o short

# 3) Plan
sudo kubeadm upgrade plan

# 4) Apply
sudo kubeadm upgrade apply "${v_k8s_version_name}" -y

# 5) Drain
kubectl drain "${CP_NODE}" --ignore-daemonsets --delete-emptydir-data

# 6) kubelet + kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet="${v_k8s_version}" kubectl="${v_k8s_version}"
sudo apt-mark hold kubelet kubectl

# 7) Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# 8) Uncordon
kubectl uncordon "${CP_NODE}"
kubectl get nodes -o wide
```

---

## Step 2: Upgrade Additional Control Plane Nodes

On every control plane node **other than the first**, the difference is one command: `kubeadm upgrade node` instead of `kubeadm upgrade apply`. Never run `upgrade apply` twice.

```bash
#!/bin/bash
set -euo pipefail

CP_NODE="k8s-cp2"    # then k8s-cp3, one at a time
NEW_MINOR="vX.Y"
v_k8s_version="X.Y.Z-1.1"

# 1) Repository (same change as the first node)
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# 2) kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm="${v_k8s_version}"
sudo apt-mark hold kubeadm

# 3) Upgrade this node's control plane components (NOT 'apply')
sudo kubeadm upgrade node

# 4) Drain from a working kubectl
kubectl drain "${CP_NODE}" --ignore-daemonsets --delete-emptydir-data

# 5) kubelet + kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet="${v_k8s_version}" kubectl="${v_k8s_version}"
sudo apt-mark hold kubelet kubectl

# 6) Restart
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# 7) Uncordon
kubectl uncordon "${CP_NODE}"
```

Between each control plane node, verify:

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
kubectl get --raw='/readyz?verbose' | tail -5

# etcd membership must still be complete and healthy
kubectl -n kube-system exec etcd-k8s-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster --write-out=table
```

The `k8s-workshop/nginx-lb-setup-scripts/get-leader.sh` script does exactly this across `k8s-cp{1..3}`, which is a convenient one liner during an HA upgrade to confirm every member is still in the raft cluster and to see which one is the leader.

One at a time is not a suggestion. With three control plane nodes, taking two down at once loses etcd quorum and the cluster goes read only, then unavailable. See [ha-control-plane.md](ha-control-plane.md).

---

## Step 3: Upgrade the Worker Nodes

Workers are drained from the control plane and upgraded on the node itself. The workshop script splits this exactly the same way.

```bash
# ── Run this part from a machine with a working kubectl ────────────────
WORKER="k8s-w1"
kubectl drain "${WORKER}" --ignore-daemonsets --delete-emptydir-data
kubectl get nodes
kubectl get pods --all-namespaces -o wide
```

```bash
# ── Then SSH to the worker node ────────────────────────────────────────
set -euo pipefail
NEW_MINOR="vX.Y"
v_k8s_version="X.Y.Z-1.1"

# 1) Repository
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${NEW_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# 2) kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm="${v_k8s_version}"
sudo apt-mark hold kubeadm

# 3) Refresh the local kubelet configuration from the cluster ConfigMap
sudo kubeadm upgrade node

# 4) kubelet (and kubectl if you keep one on workers)
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet="${v_k8s_version}" kubectl="${v_k8s_version}"
sudo apt-mark hold kubelet kubectl

# 5) Restart
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

```bash
# ── Back on the control plane ──────────────────────────────────────────
kubectl uncordon "${WORKER}"
kubectl get nodes -o wide
```

### Batching Workers

On a large cluster, one at a time is slow. Batch carefully:

```bash
# Upgrade workers in batches of 2, respecting PDBs
for W in k8s-w1 k8s-w2; do
  kubectl drain "${W}" --ignore-daemonsets --delete-emptydir-data --timeout=600s &
done
wait
```

Constraints on batching:

- The batch size must be smaller than the disruption budget of every workload spread across those nodes.
- The remaining nodes must have capacity for the drained pods.
- If you use topology spread constraints or pod anti affinity across zones, do not batch nodes from the same zone.

### Where kube-proxy Fits

`kube-proxy` runs as a DaemonSet. Its image was already updated to the new version by `kubeadm upgrade apply` on the first control plane node. The DaemonSet rolling update replaces the kube-proxy pod on each node independently of the node upgrade. The `kube-proxy` **package** on the node is irrelevant on a kubeadm cluster; there is no such package. What matters is the DaemonSet image.

```bash
kubectl -n kube-system get daemonset kube-proxy -o wide
kubectl -n kube-system rollout status daemonset/kube-proxy
```

---

## What kubeadm upgrade apply Actually Does

Understanding the internals is what lets you debug a failed upgrade instead of guessing.

```
┌───────────────────────────────────────────────────────────────────────────┐
│                     kubeadm upgrade apply vX.Y.Z                           │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│  1. PREFLIGHT                                                              │
│     • Cluster health check (all control plane pods, all nodes Ready)      │
│     • Version skew validation (is vX.Y.Z exactly one minor ahead?)        │
│     • kubeadm binary version must match the requested target              │
│     • Confirms it is running on a control plane node                      │
│                          ▼                                                 │
│  2. READ CLUSTER CONFIGURATION                                             │
│     • Pulls the ClusterConfiguration from the                             │
│       kubeadm-config ConfigMap in kube-system                             │
│                          ▼                                                 │
│  3. PULL IMAGES                                                            │
│     • Pre-pulls the new control plane images via CRI so the               │
│       static pod restart is fast                                          │
│                          ▼                                                 │
│  4. BACKUP                                                                 │
│     • Old static pod manifests →                                          │
│       /etc/kubernetes/tmp/kubeadm-backup-manifests-<timestamp>/           │
│     • etcd data directory backup →                                        │
│       /etc/kubernetes/tmp/kubeadm-backup-etcd-<timestamp>/                │
│                          ▼                                                 │
│  5. RENEW CERTIFICATES                                                     │
│     • All kubeadm-managed certs under /etc/kubernetes/pki                 │
│       (unless --certificate-renewal=false)                                │
│     • Regenerates the kubeconfig files in /etc/kubernetes/*.conf          │
│                          ▼                                                 │
│  6. UPGRADE etcd (stacked topology only)                                   │
│     • Rewrites /etc/kubernetes/manifests/etcd.yaml with the new           │
│       etcd image, waits for the member to be healthy                      │
│     • Rolls back the manifest automatically if it fails                   │
│                          ▼                                                 │
│  7. REWRITE CONTROL PLANE STATIC POD MANIFESTS                             │
│     • kube-apiserver.yaml, kube-controller-manager.yaml,                  │
│       kube-scheduler.yaml in /etc/kubernetes/manifests                    │
│     • The kubelet notices the file change and restarts each pod           │
│     • kubeadm waits for each component's health endpoint                  │
│                          ▼                                                 │
│  8. UPDATE CLUSTER-WIDE CONFIGMAPS                                          │
│     • kubeadm-config       (new ClusterConfiguration, new version)        │
│     • kubelet-config       (new KubeletConfiguration for all nodes)       │
│     • Writes the local /var/lib/kubelet/config.yaml on this node          │
│     • RBAC objects for those ConfigMaps                                   │
│                          ▼                                                 │
│  9. UPGRADE ADDONS                                                         │
│     • CoreDNS Deployment (image + the Corefile ConfigMap if changed)      │
│     • kube-proxy DaemonSet (image + kube-proxy ConfigMap)                 │
│                          ▼                                                 │
│ 10. BOOTSTRAP TOKEN AND RBAC REFRESH                                       │
│     • Ensures the node bootstrap RBAC rules still exist                   │
│                                                                            │
└───────────────────────────────────────────────────────────────────────────┘
```

### What It Explicitly Does NOT Do

| Not touched | Who owns it |
|---|---|
| The `kubelet` binary | Your package manager |
| The `kubectl` binary | Your package manager |
| The `kubeadm` binary | Your package manager (you installed it in step 1.3) |
| The CNI plugin | The CNI project's manifests |
| CSI drivers | Each CSI project |
| `containerd` / `runc` | Your package manager |
| Ingress controllers, metrics-server, MetalLB | Their own manifests |
| Your `$HOME/.kube/config` | You, by copying `/etc/kubernetes/admin.conf` |
| Operating system packages | `apt` / `dnf` / `zypper` |

### The Backup Directory Is Your Friend

```bash
sudo ls -la /etc/kubernetes/tmp/
# kubeadm-backup-manifests-2026-01-15-10-32-01/
# kubeadm-backup-etcd-2026-01-15-10-32-01/

sudo ls -la /etc/kubernetes/tmp/kubeadm-backup-manifests-*/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

If `upgrade apply` fails partway through, kubeadm restores manifests from here automatically. If it fails in a way that leaves the node wedged, you can restore them manually:

```bash
BACKUP="/etc/kubernetes/tmp/kubeadm-backup-manifests-2026-01-15-10-32-01"
sudo cp "${BACKUP}"/*.yaml /etc/kubernetes/manifests/
# The kubelet picks up the change within seconds
sudo crictl ps -a | head
```

Note that restoring old manifests recovers the **binaries**, not the **data**. If etcd has already been upgraded and has written data in a newer format, going back is not clean. That is why the pre upgrade snapshot exists.

---

## What kubeadm upgrade node Actually Does

`kubeadm upgrade node` behaves differently depending on where you run it, and this is the single most important asymmetry in the whole procedure.

| Where it runs | What it does |
|---|---|
| **Additional control plane node** | Runs the `control-plane` phase (rewrites this node's static pod manifests to the new version), renews this node's certificates, runs the `kubelet-config` phase, and skips addons (already done on the first node) |
| **Worker node** | Runs only the `kubelet-config` phase: downloads the `kubelet-config` ConfigMap from `kube-system` and writes `/var/lib/kubelet/config.yaml` |

### The Phases

```bash
# See the phases available for your kubeadm version
sudo kubeadm upgrade node phase --help
```

Common phases:

| Phase | Purpose |
|---|---|
| `preflight` | Health and skew checks for this node |
| `control-plane` | Rewrite this node's control plane static pod manifests |
| `kubelet-config` | Write `/var/lib/kubelet/config.yaml` from the cluster ConfigMap |
| `addon` | Ensure the addons exist (control plane nodes) |

Running a phase individually is useful when you only want part of the behaviour:

```bash
# Refresh only the kubelet config on a node, without touching anything else
sudo kubeadm upgrade node phase kubelet-config
sudo systemctl restart kubelet
```

That last command is also the supported way to roll out a cluster wide `KubeletConfiguration` change, covered in [kubelet-configuration.md](kubelet-configuration.md).

---

## Upgrading Addons Separately

Addons live outside the kubeadm lifecycle. Every one of them is a separate change with its own compatibility matrix.

### CNI: Calico

The repository already has the two scripts for this in `k8s-workshop`.

`k8s-workshop/upgrade-tigera-operator.sh` upgrades the operator:

```bash
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/projectcalico/calico/vA.B.C/manifests/tigera-operator.yaml
```

`k8s-workshop/upgrade-calico.sh` upgrades the manifest based install:

```bash
v_calico_version="A.B.C"
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/projectcalico/calico/v${v_calico_version}/manifests/calico.yaml
```

Two details in those scripts are doing real work and are worth calling out:

| Flag | Why it is there |
|---|---|
| `--server-side` | Uses server side apply, so field ownership is tracked properly and the upgrade does not clobber fields owned by the operator or by you |
| `--force-conflicts` | Takes ownership of fields that a previous client side apply left in an ambiguous state; without it a manifest based install upgraded from an older Calico release will fail with conflict errors |

Use the operator script for an operator based install and the manifest script for a manifest based install. Do not mix them on the same cluster.

Verify after:

```bash
kubectl -n kube-system rollout status daemonset/calico-node
# or, for an operator install
kubectl -n calico-system rollout status daemonset/calico-node
kubectl -n calico-system get pods -o wide

# Confirm pod networking still works end to end
kubectl run netcheck --rm -it --image=busybox:1.36 --restart=Never -- \
  sh -c 'wget -qO- --timeout=3 http://kubernetes.default.svc.cluster.local:443 || echo reachable-tls'
```

Ordering guidance: check the Calico compatibility matrix. If your current Calico supports both your current and target Kubernetes version, upgrade Kubernetes first and Calico second. If it does not, upgrade Calico first to a release that supports both, then Kubernetes.

### CoreDNS

`kubeadm upgrade apply` upgrades CoreDNS on the first control plane node. You normally do nothing extra. Two situations need attention:

```bash
# What is running now
kubectl -n kube-system get deployment coredns -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

# The Corefile
kubectl -n kube-system get configmap coredns -o yaml
```

- If you customised the `coredns` ConfigMap, kubeadm may not overwrite it, and a new CoreDNS image may need Corefile changes (plugin renames, removed directives). Diff your Corefile against the upstream default for the new CoreDNS version.
- If CoreDNS pods crashloop after the upgrade, the Corefile is the first suspect:

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
```

### metrics-server

Not managed by kubeadm at all.

```bash
kubectl -n kube-system get deployment metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

# Upgrade by re-applying the release manifest for a supported version
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/vA.B.C/components.yaml

kubectl -n kube-system rollout status deployment/metrics-server
kubectl top nodes
```

### CSI Drivers

CSI drivers are the highest risk addon because a broken one silently blocks pod startup on any node with persistent volumes.

```bash
# What drivers are registered
kubectl get csidrivers
kubectl get csinodes -o wide

# The images in play
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.containers[*].image}{"\n"}{end}' \
  | grep -i csi
```

For the drivers used in this repository, see [install-csi-nfs.md](install-csi-nfs.md) and [install-csi-smb.md](install-csi-smb.md). Upgrade by re-applying the driver's manifests for a version listed as compatible with your target Kubernetes version, then verify:

```bash
# Prove the driver still works: bind a PVC end to end
kubectl get pv,pvc -A
kubectl apply -f k8s-workshop/nfs-pvc-web-share.yaml
kubectl get pvc -w
```

### MetalLB and Ingress

```bash
# MetalLB
kubectl -n metallb-system get pods -o wide
kubectl -n metallb-system get deployment controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

# ingress-nginx
kubectl -n ingress-nginx get deployment ingress-nginx-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

Ingress controllers are a common casualty of API removals because they historically used `networking.k8s.io/v1beta1 Ingress` and admission webhook API versions that get removed. Check the controller's supported Kubernetes range before, not after.

### Addon Upgrade Order

```
┌──────────────────────────────────────────────────────────────────┐
│  Safe addon ordering around a Kubernetes minor upgrade           │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  BEFORE the K8s upgrade:                                          │
│    • Any addon whose current version does NOT support the        │
│      target K8s version, moved to a version that supports BOTH   │
│                                                                   │
│  THE K8s UPGRADE                                                  │
│                                                                   │
│  AFTER the K8s upgrade, one at a time, verifying between each:   │
│    1. CNI            (network first, everything depends on it)   │
│    2. CoreDNS        (if it needs more than kubeadm did)         │
│    3. CSI drivers    (storage)                                   │
│    4. metrics-server (HPA depends on it)                         │
│    5. Ingress / MetalLB (external traffic)                       │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

---

## OS Patching as a Separate Concern

Kernel and userspace patching has nothing to do with the Kubernetes version, but it uses the same drain and uncordon primitives. The repository already encodes the approach.

### The Worker Pattern

`k8s-workshop/os-patch-upgrade-worker.sh`:

```bash
#!/bin/bash
v_worker_node="k8s-w1"
apt update
kubectl drain ${v_worker_node} --ignore-daemonsets
kubectl get nodes
kubectl get pods --all-namespaces
apt upgrade
reboot
kubectl get nodes
watch kubectl get pods --all-namespaces
kubectl uncordon ${v_worker_node}
kubectl get nodes
watch kubectl get pods --all-namespaces
```

### The Control Plane Pattern

`k8s-workshop/os-patch-upgrade-ctrl-plane.sh` is the same shape with one meaningful difference:

```bash
#!/bin/bash
v_ctrl_plane_node="k8s-cp1"
apt update
kubectl drain ${v_ctrl_plane_node} --ignore-daemonsets --delete-emptydir-data
...
```

The control plane variant adds `--delete-emptydir-data`. That is deliberate: control plane nodes tend to run system components with `emptyDir` scratch volumes that would otherwise block the drain. See the flag discussion in [node-maintenance.md](node-maintenance.md).

### The Pattern Generalised

```
┌────────────────────────────────────────────────────────────────┐
│                     OS Patch Cycle, One Node                    │
├────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌───────────┐                                                 │
│   │  DRAIN    │  kubectl drain <node> --ignore-daemonsets       │
│   │           │                     --delete-emptydir-data      │
│   └─────┬─────┘  Node is cordoned + workloads relocated         │
│         ▼                                                       │
│   ┌───────────┐                                                 │
│   │  VERIFY   │  kubectl get pods -A -o wide                    │
│   │           │  Everything rescheduled and Running elsewhere?  │
│   └─────┬─────┘                                                 │
│         ▼                                                       │
│   ┌───────────┐                                                 │
│   │  PATCH    │  apt upgrade  /  dnf update  /  zypper update   │
│   └─────┬─────┘                                                 │
│         ▼                                                       │
│   ┌───────────┐                                                 │
│   │  REBOOT   │  reboot (only if kernel/glibc/systemd changed)  │
│   └─────┬─────┘                                                 │
│         ▼                                                       │
│   ┌───────────┐                                                 │
│   │  WAIT     │  Node returns; kubelet + containerd healthy;    │
│   │           │  DaemonSet pods Running again                   │
│   └─────┬─────┘                                                 │
│         ▼                                                       │
│   ┌───────────┐                                                 │
│   │ UNCORDON  │  kubectl uncordon <node>                        │
│   └─────┬─────┘                                                 │
│         ▼                                                       │
│   ┌───────────┐                                                 │
│   │  SETTLE   │  Watch until the cluster is fully green,        │
│   │           │  THEN move to the next node                     │
│   └───────────┘                                                 │
│                                                                 │
└────────────────────────────────────────────────────────────────┘
```

### Practical Additions to the Script Pattern

```bash
# Does this patch actually need a reboot?
# Debian family
[ -f /var/run/reboot-required ] && echo "reboot needed" && cat /var/run/reboot-required.pkgs
# RedHat family
sudo dnf needs-restarting -r ; echo "exit=$?"   # exit 1 means reboot required
```

```bash
# Hold Kubernetes packages so an OS patch never moves them
# Debian family
sudo apt-mark showhold
# RedHat family: the 'exclude=' line in /etc/yum.repos.d/kubernetes.repo does this
grep -n exclude /etc/yum.repos.d/kubernetes.repo
```

This matters enormously. If `kubelet` is not held, `apt upgrade` during an OS patch can pull a newer `kubelet` than the API server, which is an unsupported skew, and the node will start behaving strangely without an obvious cause.

```bash
# Wait for the node to come back properly rather than eyeballing it
kubectl wait --for=condition=Ready node/"${v_worker_node}" --timeout=600s
```

```bash
# Confirm the container runtime is healthy after reboot before uncordoning
sudo systemctl is-active containerd
sudo crictl info | jq '.status.conditions'
```

### containerd and runc

These are upgraded with the OS, not with Kubernetes. Restarting `containerd` restarts every container on the node, so treat it as a node level disruption and drain first.

```bash
containerd --version
runc --version
sudo systemctl restart containerd    # drain the node first
```

If containerd's configuration is regenerated by the package upgrade, re-check the cgroup driver setting, which must match the kubelet's:

```bash
sudo containerd config dump | grep -i SystemdCgroup
grep -i cgroupDriver /var/lib/kubelet/config.yaml
```

A mismatch here is one of the classic causes of a node that will not go Ready after patching. See [kubelet-configuration.md](kubelet-configuration.md).

---

## Rollback Reality

This section exists because the honest answer surprises people.

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Can I roll back a kubeadm upgrade?                   │
├────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Scenario A: 'kubeadm upgrade apply' FAILED mid-flight                 │
│    → kubeadm automatically restores the static pod manifests from      │
│      /etc/kubernetes/tmp/kubeadm-backup-manifests-<ts>/                │
│    → Usually recoverable. Read the error, fix it, retry.               │
│                                                                         │
│  Scenario B: 'kubeadm upgrade apply' SUCCEEDED, but you hate the result│
│    → There is NO 'kubeadm downgrade'.                                  │
│    → Downgrading Kubernetes minor versions is NOT SUPPORTED.           │
│    → etcd has been upgraded and may have written data in a format      │
│      the older etcd cannot read.                                       │
│    → The stored API objects have been migrated to the new storage      │
│      versions.                                                          │
│    → Your only real recovery is: RESTORE FROM THE etcd SNAPSHOT.       │
│                                                                         │
│  Which is exactly why the pre-upgrade backup is not optional.          │
└────────────────────────────────────────────────────────────────────────┘
```

### Why In Place Downgrade Does Not Work

| Layer | What changed forward | Why it cannot go back |
|---|---|---|
| etcd | Data directory format, possibly a major etcd version bump | Older etcd may refuse to open a newer data directory |
| API storage versions | Objects written at a newer storage version | Older apiserver has no decoder for them |
| Removed API versions | Objects only exist at the new version | Older clients cannot read what was migrated |
| CRDs and operators | Reconciled to new schemas | Downgraded controllers may fight the new state |
| kubelet on disk state | `/var/lib/kubelet` pod state format | Not guaranteed backward compatible |

### The Actual Recovery Path

```
1. STOP. Do not let anything else write to the cluster.
2. Reinstall the OLD kubeadm/kubelet/kubectl packages on control plane nodes.
3. Restore the etcd snapshot taken before the upgrade.
4. Restore /etc/kubernetes/pki and the static pod manifests from the tarball.
5. Start the control plane; verify.
6. Rejoin or rebuild worker nodes as needed.
7. Accept the data loss: everything created after the snapshot is gone.
```

The full command sequence is in [etcd-backup-restore.md](etcd-backup-restore.md).

### The Practical Alternative: Blue/Green Clusters

For production, many teams do not upgrade in place at all. They build a new cluster at the target version, deploy the workloads to it from Git, shift traffic, and delete the old cluster. This gives a real rollback (shift traffic back) at the cost of running two clusters briefly. It is the only approach that gives a genuine, tested rollback path.

### Mitigations If You Must Upgrade In Place

| Mitigation | Effect |
|---|---|
| Rehearse on an identical non production cluster first | Finds the failure before it matters |
| `--dry-run` on the real cluster | Catches configuration and preflight problems |
| Snapshot etcd immediately before, verified | Makes the recovery path real |
| Tarball `/etc/kubernetes` on every control plane node | The snapshot alone cannot rebuild the PKI |
| Upgrade one minor at a time, verify between | Smaller blast radius per step |
| Keep the old packages available in a local mirror | You cannot downgrade if the packages are gone |

---

## Post Upgrade Verification

Do not declare success on `kubectl get nodes` alone.

### Versions

```bash
# Every node's kubelet and container runtime
kubectl get nodes -o wide

# Client and server versions
kubectl version

# Explicit per node kubelet version
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,'\
'PROXY:.status.nodeInfo.kubeProxyVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,'\
'OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion'
```

### Control Plane Health

```bash
kubectl get --raw='/healthz?verbose'
kubectl get --raw='/readyz?verbose'
kubectl get --raw='/livez?verbose'

kubectl -n kube-system get pods -o wide
kubectl get componentstatuses 2>/dev/null   # deprecated, but still informative on older clusters
```

### etcd Health

```bash
kubectl -n kube-system exec etcd-k8s-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster --write-out=table

kubectl -n kube-system exec etcd-k8s-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  alarm list
```

### Workloads

```bash
# Anything not Running or Completed
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Restart counts that jumped
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail -20

# Deployments that did not converge
kubectl get deployments -A -o json | jq -r '
  .items[] | select(.status.readyReplicas != .status.replicas)
  | "\(.metadata.namespace)/\(.metadata.name) \(.status.readyReplicas)/\(.status.replicas)"'

# Recent warnings
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -30
```

### Networking

```bash
# DNS resolution from inside the cluster
kubectl run dnstest --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local

# Service connectivity
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get endpointslices -l k8s-app=kube-dns

# kube-proxy rolled everywhere
kubectl -n kube-system rollout status daemonset/kube-proxy
```

### Storage

```bash
kubectl get storageclass
kubectl get pv,pvc -A
kubectl get volumeattachments
```

### Certificates

```bash
sudo kubeadm certs check-expiration
```

`kubeadm upgrade apply` renewed them, so expiry dates should now be roughly one year out. If they are not, the renewal did not happen and you should investigate before you forget.

### Deprecation Signal for the Next Hop

```bash
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
```

Zero results here means the next upgrade will be easier. Non zero means start migrating now, not in the next maintenance window.

### Verification Checklist

| Area | Passing looks like |
|---|---|
| Nodes | All `Ready`, all at the new `kubeletVersion`, none `SchedulingDisabled` |
| Control plane | `/readyz` returns `ok`, all `kube-system` pods Running |
| etcd | All members healthy, no alarms, one leader |
| Workloads | No new CrashLoopBackOff, no new Pending, restart counts stable |
| DNS | In cluster resolution works |
| Storage | PVCs `Bound`, new PVC provisioning works |
| Certificates | ~1 year of validity remaining |
| Deprecations | Gauge at zero for the next release |

---

## Troubleshooting

### A Stuck Upgrade

**Symptom:** `kubeadm upgrade apply` hangs at "waiting for the kubelet to boot up the control plane as static Pods".

kubeadm is waiting for a static pod that never becomes healthy. The API server may be down, so `kubectl` is useless. Use the node level tools.

```bash
# 1. Is the kubelet even running?
sudo systemctl status kubelet --no-pager
sudo journalctl -u kubelet -n 200 --no-pager

# 2. What containers does the runtime actually have?
sudo crictl ps -a
sudo crictl pods

# 3. Logs from the failing control plane container
sudo crictl ps -a --name kube-apiserver
sudo crictl logs --tail 100 <container-id>

# 4. Did the image pull succeed?
sudo crictl images | grep -E 'kube-apiserver|kube-controller|kube-scheduler|etcd'

# 5. Inspect the manifest kubeadm just wrote
sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml
```

Common root causes:

| Cause | Signal | Fix |
|---|---|---|
| Image pull failure (no registry access, or an air gapped node) | `crictl logs` shows nothing, `crictl images` missing the new tag | Pre-pull with `sudo kubeadm config images pull`, or fix the registry mirror |
| Port 6443 still bound by the old apiserver process | apiserver container exits with "address already in use" | `sudo ss -ltnp | grep 6443`, kill the stale process |
| Insufficient memory on the node | OOM kills in `dmesg` | Free memory or grow the node |
| etcd not healthy before the apiserver starts | etcd container crashlooping | Fix etcd first; check disk space and permissions on `/var/lib/etcd` |
| Bad `extraArgs` in `kubeadm-config` | apiserver exits immediately with a flag parse error | `kubectl -n kube-system get cm kubeadm-config -o yaml` before you start; correct the args |
| Disk full | Everything fails oddly | `df -h /var /var/lib/etcd` |

To bail out safely:

```bash
# Restore the pre-upgrade manifests
BACKUP=$(sudo ls -d /etc/kubernetes/tmp/kubeadm-backup-manifests-* | tail -1)
sudo cp "${BACKUP}"/*.yaml /etc/kubernetes/manifests/
sudo systemctl restart kubelet
sudo crictl ps
```

### A Failed Drain

**Symptom:** `kubectl drain` prints `evicting pod ...` repeatedly and never returns.

```bash
# Which pods are still on the node?
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>

# Ask the eviction API directly what it thinks
kubectl get pdb -A

# The exact error
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=120s
# error when evicting pod "web-0" (will retry after 5s):
#   Cannot evict pod as it would violate the pod's disruption budget.
```

| Cause | Fix |
|---|---|
| PDB with `disruptionsAllowed: 0` | Scale the workload up, or relax/remove the PDB for the window |
| Single replica workload with a PDB | Accept the outage, or scale to 2 first |
| Bare pod (no owning controller) | Add `--force`; the pod is deleted and not recreated |
| `emptyDir` volume in use | Add `--delete-emptydir-data`; the data is destroyed |
| DaemonSet pods | Add `--ignore-daemonsets`; they are left running by design |
| Pod stuck `Terminating` with a finalizer | Inspect `metadata.finalizers`, resolve the owning controller |
| Pod with a long `terminationGracePeriodSeconds` | Wait, or set `--grace-period` (which overrides the pod's value) |
| No capacity elsewhere | Evicted pods go `Pending`; add capacity before draining |

Detailed treatment in [node-maintenance.md](node-maintenance.md) and [pod-disruption-budgets.md](pod-disruption-budgets.md).

### A Node That Will Not Rejoin or Go Ready

**Symptom:** after upgrading and restarting the kubelet, the node stays `NotReady` or vanishes.

```bash
# The single most useful command
sudo journalctl -u kubelet -f --no-pager

# Or the last burst of failures
sudo journalctl -u kubelet -n 300 --no-pager | grep -iE 'error|fail|refus|expire'
```

| Cause | Signal in the kubelet log | Fix |
|---|---|---|
| cgroup driver mismatch | `misconfiguration: kubelet cgroup driver ... is different from docker/containerd cgroup driver` | Set `SystemdCgroup = true` in `/etc/containerd/config.toml` and `cgroupDriver: systemd` in `/var/lib/kubelet/config.yaml`, restart both |
| CRI endpoint wrong | `failed to get container runtime version` / connection refused on the CRI socket | Check `containerRuntimeEndpoint` in the kubelet config and that `containerd` is active |
| Expired kubelet client certificate | `certificate has expired or is not yet valid` | `sudo kubeadm certs renew all` on a control plane node; for the node's own cert, delete `/etc/kubernetes/kubelet.conf` and re-bootstrap, or fix rotation |
| CNI not ready | `Network plugin returns error: cni plugin not initialized` | The CNI DaemonSet pod on that node is not running; check it, and check `/etc/cni/net.d` |
| Swap re-enabled by the OS patch | `running with swap on is not supported` (on older configurations) | `sudo swapoff -a` and comment the fstab entry, or configure swap support deliberately |
| Version skew (kubelet newer than apiserver) | Odd API errors, unexpected field rejections | Downgrade the kubelet package to a supported version |
| kubelet config file missing after upgrade | `failed to load Kubelet config file /var/lib/kubelet/config.yaml` | `sudo kubeadm upgrade node phase kubelet-config` then restart the kubelet |
| Node object deleted while the node was down | Node simply absent from `kubectl get nodes` | Re-run `kubeadm join` with a fresh token after `kubeadm reset` on that node |

Rejoining a worker properly:

```bash
# On a control plane node, mint a fresh join command (tokens expire after 24h)
sudo kubeadm token create --print-join-command

# On the worker, clean up first if it was previously joined
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
# then run the printed join command
```

For an additional control plane node, the join needs the certificate key too:

```bash
sudo kubeadm token create --print-join-command \
  --certificate-key "$(sudo kubeadm init phase upload-certs --upload-certs | tail -n 1 | tr -d '[:space:]')"
```

### CoreDNS CrashLoopBackOff After Upgrade

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=100
kubectl -n kube-system get cm coredns -o yaml
```

A new CoreDNS version can reject a Corefile that an older version tolerated (removed plugins, renamed options). Compare against the default Corefile for the new CoreDNS version and adjust.

### kubectl Suddenly Cannot Authenticate

```bash
kubectl get nodes
# error: You must be logged in to the server (Unauthorized)
```

`kubeadm upgrade apply` regenerated `/etc/kubernetes/admin.conf`. Your personal copy is stale.

```bash
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
kubectl get nodes
```

### Pods Pending After the Upgrade

```bash
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <pod> -n <ns> | tail -30
```

| Message | Meaning |
|---|---|
| `0/N nodes are available: N node(s) were unschedulable` | You forgot to `uncordon` a node |
| `Insufficient cpu` / `Insufficient memory` | Genuine capacity shortfall |
| `node(s) had untolerated taint` | A node kept a maintenance taint |
| `waiting for a volume to be created` | CSI driver not healthy after the upgrade |

```bash
# The classic: check for leftover cordons
kubectl get nodes | grep SchedulingDisabled
```

---

## Exam and Interview Traps

1. **`kubeadm upgrade apply` runs on exactly one node.** Every other control plane node gets `kubeadm upgrade node`. Running `apply` on a second node is a very common wrong answer.

2. **kubeadm does not upgrade the kubelet.** It says so in `upgrade plan` output. You upgrade `kubelet` and `kubectl` with your package manager, on every node, separately.

3. **You must change the package repository URL.** Each minor version has its own repository at `pkgs.k8s.io/core:/stable:/vX.Y/`. Forgetting this is why `apt-cache madison kubeadm` shows no new version.

4. **kubectl is the only component allowed to be newer than the API server.** Everything else must be equal or older.

5. **kubelet may be up to three minor versions behind the API server** (widened from two in v1.28), but the controller manager and scheduler may only be one behind.

6. **kube-proxy must match the kubelet on its own node**, not the API server.

7. **One minor version at a time.** No jumping. Patch versions within a minor are unconstrained going forward.

8. **`kubeadm upgrade` is not reversible.** There is no downgrade subcommand. Rollback means restoring an etcd snapshot.

9. **A removed API version does not delete your objects.** They are converted on read. What breaks is manifests, pipelines, Helm charts and operators.

10. **Drain uses the Eviction API, so it respects PDBs.** `kubectl delete pod` does not. That difference is the entire point of a drain.

11. **`--ignore-daemonsets` is almost always required**, because DaemonSet pods are immediately recreated on the same node and would make the drain impossible to complete.

12. **`--delete-emptydir-data` destroys data.** It is required when any pod on the node uses an `emptyDir`, and there is no way to preserve that data.

13. **`--force` deletes bare pods permanently.** Nothing recreates a pod with no owning controller.

14. **`--grace-period` on drain overrides the pod's `terminationGracePeriodSeconds`**, including making it shorter, which can cut off graceful shutdown.

15. **`kubeadm upgrade node` on a worker only refreshes the kubelet config.** It does not upgrade any binary.

16. **`daemon-reload` before `restart kubelet`.** The package upgrade may have changed the systemd unit or the kubeadm drop in.

17. **Held packages matter.** `apt-mark hold` and the `exclude=` line in the yum repo exist so OS patching cannot silently move Kubernetes versions.

18. **The CNI is not upgraded by kubeadm.** Neither are CSI drivers, metrics-server, ingress controllers or MetalLB.

19. **`kubeadm upgrade apply` renews control plane certificates**, which means your `$HOME/.kube/config` copy of `admin.conf` becomes stale and must be re-copied.

20. **On a single control plane cluster the API server goes down during the upgrade.** That is expected, not a failure. On an HA cluster with a load balancer in front, clients only see the one node's connections drop.

21. **Losing quorum during an HA control plane upgrade is self inflicted.** Upgrade one control plane node at a time; two down out of three means no quorum.

22. **etcd is upgraded as part of `upgrade apply`** on a stacked topology. With external etcd you upgrade it yourself and should pass `--etcd-upgrade=false`.

23. **`kubectl convert` is a separate binary**, not a built in subcommand, and must be installed.

24. **`apiserver_requested_deprecated_apis` tells you what, not who.** Audit logs tell you who.

25. **Draining a node does not stop the kubelet or the static pods.** A drained control plane node is still running the API server.

---

## Related Topics

- [etcd](etcd.md): the datastore that the whole upgrade risk model revolves around
- [etcd Backup and Restore](etcd-backup-restore.md): the mandatory pre upgrade backup and the only real rollback path
- [Node Maintenance](node-maintenance.md): cordon, drain and eviction in full detail
- [HA Control Plane](ha-control-plane.md): why control plane nodes are upgraded one at a time
- [Static Pods](static-pods.md): what `kubeadm upgrade apply` actually rewrites
- [kubelet Configuration](kubelet-configuration.md): the `kubelet-config` ConfigMap and `kubeadm upgrade node phase kubelet-config`
- [kubelet](kubelet.md): the node agent overview
- [Pod Disruption Budgets](pod-disruption-budgets.md): why drains hang
- [Pod Lifecycle](pod-lifecycle.md): what eviction does to a pod
- [Manual Kubernetes Cluster Install](manual-install-k8s-cluster.md): how the cluster was built in the first place
- [Install Kubernetes Packages (Debian)](install-k8s-pkgs-debian.md): repository configuration reference
- [Install Kubernetes Packages (RedHat)](install-k8s-pkgs-redhat.md): repository configuration reference
- [Install Kubernetes Packages (SUSE)](install-k8s-pkgs-suse.md): repository configuration reference
- [CNI](cni.md): the addon most likely to need its own upgrade
- [CSI](csi.md): storage drivers with their own compatibility matrix
- [CoreDNS](coredns.md): the addon kubeadm does upgrade

---

## Key Takeaways

1. **Upgrade one minor version at a time**, control plane first, workers last, and never let a kubelet get ahead of the API server.
2. **The version skew policy is the contract** that makes the mixed version window safe: kubelet up to three minors behind, controller manager and scheduler one behind, kubectl one either way.
3. **Change the package repository URL** to the new minor version before anything else, or you will never see the new packages.
4. **`kubeadm upgrade apply` runs once, on the first control plane node.** Everything else uses `kubeadm upgrade node`.
5. **kubeadm does not upgrade the kubelet, kubectl, the CNI, CSI drivers or the OS.** Those are separate, deliberate changes.
6. **`upgrade apply` renews certificates, rewrites the static pod manifests, upgrades etcd and the addons, and updates the kubeadm-config and kubelet-config ConfigMaps.**
7. **Deprecated API removal is the most common post upgrade surprise.** Find it in advance using the API server warning headers, the `apiserver_requested_deprecated_apis` metric and the audit log annotations.
8. **Drain respects PodDisruptionBudgets**, so review every PDB for zero allowed disruptions before the window, not during it.
9. **There is no in place rollback.** Recovery from a bad upgrade means restoring an etcd snapshot, which is why the verified pre upgrade backup is mandatory.
10. **A complete backup is the etcd snapshot plus `/etc/kubernetes`**, copied off the node. One without the other does not rebuild a cluster.
11. **Keep OS patching separate** from Kubernetes upgrades, and keep the Kubernetes packages held so a routine `apt upgrade` cannot move them.
12. **Verify with more than `kubectl get nodes`**: control plane readiness endpoints, etcd health, workload restart counts, DNS, storage and certificate expiry.

---

## References

- [Version Skew Policy](https://kubernetes.io/releases/version-skew-policy/)
- [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Kubernetes Release Cycle](https://kubernetes.io/releases/release/)
- [Patch Releases and Support Period](https://kubernetes.io/releases/patch-releases/)
- [Kubernetes Deprecation Policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/)
- [Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/)
- [kubectl convert plugin](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-kubectl-convert-plugin)
- [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [kubeadm upgrade reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-upgrade/)
- [Certificate Management with kubeadm](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/)
- [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [System Metrics of the API Server](https://kubernetes.io/docs/reference/instrumentation/metrics/)
- [Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
