# 🚀 Bootstrapping a Cluster With kubeadm

`kubeadm init` looks like one command. It is actually twenty or so ordered phases, each of which can be run, skipped or replaced individually. Understanding those phases is the difference between a cluster you installed and a cluster you understand. This document covers preflight checks, the full `ClusterConfiguration` file, every phase and what it produces on disk, single-node versus HA initialisation, the CNI gap, `kubeadm reset`, and how to recover when init fails partway through.

## 📋 Table of Contents
- [What kubeadm Does and Does Not Do](#what-kubeadm-does-and-does-not-do)
- [Before You Run Anything](#before-you-run-anything)
- [The Simplest Possible Init](#the-simplest-possible-init)
- [The Configuration File](#the-configuration-file)
- [The Phases](#the-phases)
- [Preflight](#preflight)
- [Certificates](#certificates)
- [kubeconfig](#kubeconfig)
- [Control Plane Manifests](#control-plane-manifests)
- [etcd](#etcd)
- [Waiting for the Control Plane](#waiting-for-the-control-plane)
- [Upload Config and Mark Control Plane](#upload-config-and-mark-control-plane)
- [Bootstrap Token and Addons](#bootstrap-token-and-addons)
- [What Init Leaves You With](#what-init-leaves-you-with)
- [Installing a CNI](#installing-a-cni)
- [Initialising for High Availability](#initialising-for-high-availability)
- [Running Individual Phases](#running-individual-phases)
- [kubeadm reset](#kubeadm-reset)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What kubeadm Does and Does Not Do

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  kubeadm DOES                        kubeadm DOES NOT                │
   │  ────────────                        ────────────────                │
   │  generate the entire PKI             install a container runtime     │
   │  write control plane static pods     install kubelet/kubeadm/kubectl │
   │  bootstrap etcd                      install a CNI plugin            │
   │  write the four kubeconfigs          provision machines              │
   │  configure the kubelet               configure your firewall         │
   │  deploy CoreDNS and kube-proxy       manage the cluster afterwards   │
   │  issue bootstrap tokens              install anything else           │
   │  handle version upgrades                                             │
   └──────────────────────────────────────────────────────────────────────┘
```

kubeadm is deliberately scoped to "make a conformant cluster exist". Everything about provisioning machines and everything above the cluster is explicitly out of scope. That is why a fresh `kubeadm init` gives you a cluster whose only node is `NotReady`: there is no CNI, and that is by design.

Its sibling tools:

| Tool | Role |
|---|---|
| `kubeadm` | Bootstraps and upgrades the cluster |
| `kubelet` | The node agent, must be installed and running on every node |
| `kubectl` | The client, only needed where you administer from |

See [installing-k8s-packages.md](installing-k8s-packages.md).

---

## Before You Run Anything

Four things must be true, or init will fail or produce a broken cluster.

```bash
# 1. Container runtime working
sudo crictl version
sudo crictl info | jq '.status.conditions'
sudo containerd config dump | grep SystemdCgroup      # must be true

# 2. Swap off
free -h | grep -i swap                                 # must be 0

# 3. Required kernel modules and sysctls
lsmod | grep -E 'overlay|br_netfilter'
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# 4. kubelet installed and enabled (it will crashloop until init runs,
#    which is normal and expected)
systemctl is-enabled kubelet
kubeadm version
```

The kubelet crashlooping before `kubeadm init` is **not** a problem. It has no configuration yet. It settles the moment init writes `/var/lib/kubelet/config.yaml`.

Also decide your CIDRs now, because changing them later means rebuilding the cluster.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  THREE NETWORKS, NONE MAY OVERLAP                                    │
   │                                                                      │
   │    node network     192.168.1.0/24     your actual LAN               │
   │    pod network      10.244.0.0/16      assigned by the CNI           │
   │    service network  10.96.0.0/12       virtual, never on the wire    │
   │                                                                      │
   │  Overlap between any two produces routing failures that are          │
   │  extremely unpleasant to diagnose. Check against your real LAN,      │
   │  your VPN ranges and any peered networks BEFORE init.                │
   └──────────────────────────────────────────────────────────────────────┘
```

See [k8s-networking-fundamentals.md](k8s-networking-fundamentals.md).

---

## The Simplest Possible Init

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.1.10
```

Output, abbreviated:

```
[init] Using Kubernetes version: v1.31.2
[preflight] Running pre-flight checks
[preflight] Pulling images required for setting up a Kubernetes cluster
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
...
[kubeconfig] Writing "admin.conf" kubeconfig file
[kubeconfig] Writing "super-admin.conf" kubeconfig file
...
[control-plane] Creating static Pod manifest for "kube-apiserver"
[etcd] Creating static Pod manifest for local etcd
[wait-control-plane] Waiting for the kubelet to boot up the control plane
[apiclient] All control plane components are healthy after 8.502 seconds
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config"
[mark-control-plane] Marking the node cp-01 as control-plane
[bootstrap-token] Using token: abcdef.0123456789abcdef
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!
```

Then, as instructed:

```bash
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

kubectl get nodes
# NAME    STATUS     ROLES           AGE   VERSION
# cp-01   NotReady   control-plane   30s   v1.31.2
#         ^^^^^^^^ expected. No CNI yet.
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  SAVE THE JOIN COMMAND. It is printed once and the token expires     │
   │  in 24 hours. If you lose it:                                        │
   │      sudo kubeadm token create --print-join-command                  │
   └──────────────────────────────────────────────────────────────────────┘
```

Note the doc recommends `admin.conf`, not `super-admin.conf`. The latter carries `system:masters` and bypasses RBAC entirely. See [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md).

---

## The Configuration File

Flags are fine for a lab. For anything you will rebuild, reproduce or upgrade, use a config file: it is version controllable, it exposes settings that have no flag, and `kubeadm upgrade` reads it back.

```yaml
# kubeadm-config.yaml
# Multiple documents in one file. kubeadm reads all of them.

---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration

# The bootstrap token created during init.
bootstrapTokens:
  - token: "abcdef.0123456789abcdef"
    ttl: "2h"                       # short lived; create fresh ones later
    usages: ["signing", "authentication"]
    groups: ["system:bootstrappers:kubeadm:default-node-token"]

localAPIEndpoint:
  # The address this API server advertises. On a multi-homed host you
  # MUST set this, or kubeadm picks the interface with the default route,
  # which is frequently the wrong one.
  advertiseAddress: "192.168.1.10"
  bindPort: 6443

nodeRegistration:
  name: "cp-01"
  criSocket: "unix:///run/containerd/containerd.sock"
  imagePullPolicy: "IfNotPresent"
  # The taint that keeps ordinary workloads off control plane nodes.
  # Set to [] to allow scheduling, which is what you want on a
  # single-node cluster.
  taints:
    - key: "node-role.kubernetes.io/control-plane"
      effect: "NoSchedule"
  kubeletExtraArgs:
    - name: "node-labels"
      value: "topology.kubernetes.io/zone=zone-a"

---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration

kubernetesVersion: "v1.31.2"

# The stable endpoint clients and joining nodes use.
# For HA this is a load balancer in front of all control plane nodes.
# SET THIS EVEN ON A SINGLE NODE if you might add control plane nodes
# later: it cannot be changed without regenerating certificates.
controlPlaneEndpoint: "192.168.1.10:6443"

clusterName: "production"

networking:
  # Must match what your CNI is configured for.
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"

apiServer:
  # Extra names the API server certificate must cover. Adding one
  # later means regenerating the certificate. See certificates.md.
  certSANs:
    - "192.168.1.10"
    - "api.example.internal"
    - "kubernetes.example.internal"
  extraArgs:
    - name: "authorization-mode"
      value: "Node,RBAC"
    - name: "enable-admission-plugins"
      value: "NodeRestriction"
    - name: "anonymous-auth"
      value: "false"
    - name: "audit-log-path"
      value: "/var/log/kubernetes/audit/audit.log"
    - name: "audit-policy-file"
      value: "/etc/kubernetes/audit/audit-policy.yaml"
    - name: "profiling"
      value: "false"
  # Any extraArgs referencing a file NEEDS a matching mount here.
  # This is the same trap as editing the manifest by hand.
  extraVolumes:
    - name: "audit-policy"
      hostPath: "/etc/kubernetes/audit"
      mountPath: "/etc/kubernetes/audit"
      readOnly: true
      pathType: DirectoryOrCreate
    - name: "audit-log"
      hostPath: "/var/log/kubernetes/audit"
      mountPath: "/var/log/kubernetes/audit"
      pathType: DirectoryOrCreate

controllerManager:
  extraArgs:
    - name: "bind-address"
      value: "127.0.0.1"
    - name: "profiling"
      value: "false"
    - name: "use-service-account-credentials"
      value: "true"

scheduler:
  extraArgs:
    - name: "bind-address"
      value: "127.0.0.1"
    - name: "profiling"
      value: "false"

etcd:
  local:
    dataDir: "/var/lib/etcd"
    extraArgs:
      - name: "auto-compaction-retention"
        value: "8"

# Where to pull control plane images from. Point at an internal
# mirror for air-gapped installs.
imageRepository: "registry.k8s.io"

---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# Must match containerd's SystemdCgroup setting.
cgroupDriver: systemd

# Security hardening. See cluster-hardening.md.
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook
readOnlyPort: 0
protectKernelDefaults: true
seccompDefault: true
rotateCertificates: true
serverTLSBootstrap: true
streamingConnectionIdleTimeout: "5m"

# Resource reserved for the OS and for Kubernetes components, so a
# runaway pod cannot starve the kubelet itself.
systemReserved:
  cpu: "200m"
  memory: "512Mi"
kubeReserved:
  cpu: "200m"
  memory: "512Mi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"

---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration

# iptables or ipvs. ipvs scales better with many services.
mode: "iptables"
```

```bash
# Validate before using it. Catches schema errors early.
kubeadm config validate --config kubeadm-config.yaml

# Migrate an older config to the current API version
kubeadm config migrate --old-config old.yaml --new-config new.yaml

# Then init
sudo kubeadm init --config kubeadm-config.yaml --upload-certs
```

Note the `extraArgs` format changed in `v1beta4` from a map to a list of name/value pairs. Configs written for `v1beta3` need migrating.

---

## The Phases

```
   kubeadm init
        │
   ┌────▼──────────────────────────────────────────────────────────────┐
   │  preflight            checks, and pulls images                    │
   ├───────────────────────────────────────────────────────────────────┤
   │  certs                generates the ENTIRE PKI                    │
   │    ca, apiserver, apiserver-kubelet-client,                       │
   │    front-proxy-ca, front-proxy-client,                            │
   │    etcd/ca, etcd/server, etcd/peer, etcd/healthcheck-client,      │
   │    apiserver-etcd-client, sa (keypair)                            │
   ├───────────────────────────────────────────────────────────────────┤
   │  kubeconfig           admin.conf, super-admin.conf,               │
   │                       controller-manager.conf, scheduler.conf,    │
   │                       kubelet.conf                                │
   ├───────────────────────────────────────────────────────────────────┤
   │  etcd                 static pod manifest for local etcd          │
   ├───────────────────────────────────────────────────────────────────┤
   │  control-plane        static pod manifests for apiserver,         │
   │                       controller-manager, scheduler               │
   ├───────────────────────────────────────────────────────────────────┤
   │  kubelet-start        writes kubelet config, starts the kubelet   │
   │                       ── the kubelet now reads the manifests and  │
   │                          the control plane comes up               │
   ├───────────────────────────────────────────────────────────────────┤
   │  wait-control-plane   polls /healthz until the API answers        │
   ├───────────────────────────────────────────────────────────────────┤
   │  upload-config        ConfigMaps kubeadm-config, kubelet-config   │
   ├───────────────────────────────────────────────────────────────────┤
   │  upload-certs         (only with --upload-certs) encrypts the PKI │
   │                       into a Secret so other CP nodes can fetch it│
   ├───────────────────────────────────────────────────────────────────┤
   │  mark-control-plane   labels and taints this node                 │
   ├───────────────────────────────────────────────────────────────────┤
   │  bootstrap-token      creates the join token and its RBAC         │
   ├───────────────────────────────────────────────────────────────────┤
   │  kubelet-finalize     switches kubelet.conf to the rotating cert  │
   ├───────────────────────────────────────────────────────────────────┤
   │  addon                deploys CoreDNS, then kube-proxy            │
   └───────────────────────────────────────────────────────────────────┘
```

List them on your own version, since the set shifts between releases:

```bash
sudo kubeadm init phase --help
```

---

## Preflight

```bash
# Run the checks WITHOUT doing anything else. Always worth doing first.
sudo kubeadm init phase preflight --config kubeadm-config.yaml
```

What it validates: swap off, required ports free, CRI reachable, `conntrack` and `iptables` present, cgroup driver consistency, kernel version, sufficient CPU (2+), the hostname resolving, and `/etc/kubernetes` being empty.

Skipping checks is occasionally legitimate and frequently a mistake:

```bash
# Skip specific checks
sudo kubeadm init --ignore-preflight-errors=NumCPU,Mem

# Skip all. Almost never correct.
sudo kubeadm init --ignore-preflight-errors=all
```

`Swap` is the one people most want to skip. Do not. Swap undermines memory limits and lets the kernel page container memory, including secrets, to disk.

### Pulling Images First

```bash
# See what is needed
kubeadm config images list --kubernetes-version v1.31.2
# registry.k8s.io/kube-apiserver:v1.31.2
# registry.k8s.io/kube-controller-manager:v1.31.2
# registry.k8s.io/kube-scheduler:v1.31.2
# registry.k8s.io/kube-proxy:v1.31.2
# registry.k8s.io/coredns/coredns:v1.11.3
# registry.k8s.io/pause:3.10
# registry.k8s.io/etcd:3.5.15-0

# Pull them, so init is fast and does not depend on the registry
sudo kubeadm config images pull --kubernetes-version v1.31.2
sudo crictl images
```

Essential for air-gapped installs, where you mirror these into an internal registry and set `imageRepository` in the config.

---

## Certificates

```bash
sudo kubeadm init phase certs all --config kubeadm-config.yaml
sudo ls -R /etc/kubernetes/pki/
```

This creates three independent CAs and everything they sign. The full tree, what each file is for, and the renewal procedure are in [certificates.md](certificates.md).

Two things worth knowing at init time:

**Bring your own CA.** If the files already exist, kubeadm uses them rather than generating new ones. This is how you use an organisational CA:

```bash
sudo mkdir -p /etc/kubernetes/pki
sudo cp org-ca.crt /etc/kubernetes/pki/ca.crt
sudo cp org-ca.key /etc/kubernetes/pki/ca.key
sudo chmod 600 /etc/kubernetes/pki/ca.key
# kubeadm now signs everything with your CA
sudo kubeadm init --config kubeadm-config.yaml
```

You can even omit `ca.key` entirely for an external CA setup, but then you must pre-generate every certificate yourself, since kubeadm cannot sign.

**certSANs are permanent-ish.** Adding a name later requires regenerating `apiserver.crt` and restarting. Put every name you might use in the config now.

---

## kubeconfig

```bash
sudo kubeadm init phase kubeconfig all --config kubeadm-config.yaml
sudo ls -l /etc/kubernetes/*.conf
```

| File | Identity | Used by |
|---|---|---|
| `admin.conf` | `kubernetes-admin`, group `kubeadm:cluster-admins` | You |
| `super-admin.conf` | `kubernetes-super-admin`, group `system:masters` | Break glass only |
| `controller-manager.conf` | `system:kube-controller-manager` | The controller manager |
| `scheduler.conf` | `system:kube-scheduler` | The scheduler |
| `kubelet.conf` | `system:node:<name>`, group `system:nodes` | This node's kubelet |

Regenerate one at any time, which is the fix for an expired `admin.conf`:

```bash
sudo kubeadm init phase kubeconfig admin
```

See [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md).

---

## Control Plane Manifests

```bash
sudo kubeadm init phase control-plane all --config kubeadm-config.yaml
ls -l /etc/kubernetes/manifests/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

Writing these files is all that "starting the control plane" means. The kubelet watches `/etc/kubernetes/manifests`, sees them appear, and starts the containers. There is no orchestrator involved, which is exactly how the bootstrapping paradox is solved.

Every `extraArgs` and `extraVolumes` entry from your `ClusterConfiguration` ends up here. Verify after init:

```bash
sudo grep -E 'anonymous-auth|authorization-mode|audit' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## etcd

```bash
sudo kubeadm init phase etcd local --config kubeadm-config.yaml
```

Creates `/etc/kubernetes/manifests/etcd.yaml` for a **stacked** etcd: etcd runs on the same nodes as the control plane.

```
   STACKED (kubeadm default)          EXTERNAL
   ─────────────────────────          ────────
   ┌──────────────────┐               ┌──────────────┐  ┌───────────┐
   │ cp-01            │               │ cp-01        │  │ etcd-01   │
   │  apiserver       │               │  apiserver   │──│ etcd-02   │
   │  scheduler       │               │  scheduler   │  │ etcd-03   │
   │  controller-mgr  │               │  controller  │  └───────────┘
   │  etcd  ◄─────────│               └──────────────┘
   └──────────────────┘
   Simpler. Losing a node            More machines, better
   loses an etcd member too.         isolation and independent
                                     scaling.
```

For external etcd, replace the `etcd.local` block:

```yaml
etcd:
  external:
    endpoints:
      - https://10.0.1.10:2379
      - https://10.0.1.11:2379
      - https://10.0.1.12:2379
    caFile: /etc/kubernetes/pki/etcd/ca.crt
    certFile: /etc/kubernetes/pki/apiserver-etcd-client.crt
    keyFile: /etc/kubernetes/pki/apiserver-etcd-client.key
```

See [etcd.md](etcd.md) and [ha-control-plane.md](ha-control-plane.md).

---

## Waiting for the Control Plane

```
[wait-control-plane] Waiting for the kubelet to boot up the control plane
as static Pods from directory "/etc/kubernetes/manifests"
[apiclient] All control plane components are healthy after 8.502 seconds
```

This is where most init failures surface, because it is the first point that requires everything upstream to actually work. If it hangs, the problem is in the runtime, the kubelet or a manifest, not in kubeadm.

While it waits, in another terminal:

```bash
sudo crictl ps -a
sudo journalctl -u kubelet -f
sudo crictl logs "$(sudo crictl ps -a --name kube-apiserver -q | head -1)"
```

---

## Upload Config and Mark Control Plane

```bash
sudo kubeadm init phase upload-config all --config kubeadm-config.yaml
sudo kubeadm init phase mark-control-plane --config kubeadm-config.yaml
```

The uploaded configuration is what makes upgrades and node joins work later:

```bash
kubectl -n kube-system get configmap kubeadm-config -o yaml
kubectl -n kube-system get configmap kubelet-config -o yaml
```

Keep a local copy. If the cluster is down you cannot read a ConfigMap, and several recovery procedures need it:

```bash
kubectl -n kube-system get cm kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}' | sudo tee /root/kubeadm-config.yaml
```

`mark-control-plane` applies the label and the taint:

```bash
kubectl get node cp-01 --show-labels | tr ',' '\n' | grep control-plane
kubectl describe node cp-01 | grep -A2 Taints
# Taints: node-role.kubernetes.io/control-plane:NoSchedule
```

### Single-Node Clusters

Remove the taint, or nothing will schedule:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

The trailing `-` removes the taint. See [scheduling.md](scheduling.md).

---

## Bootstrap Token and Addons

```bash
sudo kubeadm init phase bootstrap-token --config kubeadm-config.yaml
sudo kubeadm init phase addon all --config kubeadm-config.yaml
```

The bootstrap token lets a joining kubelet authenticate just long enough to submit a CSR and get a real certificate. Full mechanism in [certificates.md](certificates.md).

```bash
sudo kubeadm token list
sudo kubeadm token create --print-join-command
sudo kubeadm token create --ttl 1h --print-join-command
sudo kubeadm token delete <token>
```

The addon phase deploys CoreDNS and kube-proxy. CoreDNS will sit `Pending` until a CNI exists, which is expected:

```bash
kubectl -n kube-system get pods
# coredns-xxx      0/1   Pending   ← waiting for a CNI
# coredns-yyy      0/1   Pending
# etcd-cp-01       1/1   Running
# kube-apiserver   1/1   Running
# kube-proxy-zzz   1/1   Running
```

---

## What Init Leaves You With

```
/etc/kubernetes/
├── admin.conf                  your credential
├── super-admin.conf            break glass credential
├── controller-manager.conf
├── scheduler.conf
├── kubelet.conf
├── manifests/
│   ├── etcd.yaml
│   ├── kube-apiserver.yaml
│   ├── kube-controller-manager.yaml
│   └── kube-scheduler.yaml
└── pki/
    ├── ca.crt / ca.key
    ├── apiserver.crt / .key
    ├── apiserver-kubelet-client.crt / .key
    ├── apiserver-etcd-client.crt / .key
    ├── front-proxy-ca.crt / .key
    ├── front-proxy-client.crt / .key
    ├── sa.key / sa.pub
    └── etcd/
        ├── ca.crt / ca.key
        ├── server.crt / .key
        ├── peer.crt / .key
        └── healthcheck-client.crt / .key

/var/lib/kubelet/
├── config.yaml                 the kubelet's configuration
└── pki/                        rotating kubelet certificates

/var/lib/etcd/                  THE CLUSTER. Back this up.
```

Verify the result:

```bash
kubectl get --raw '/healthz?verbose'
kubectl -n kube-system get pods
kubectl get nodes
sudo kubeadm certs check-expiration
```

---

## Installing a CNI

The cluster is not usable until this is done. kubeadm deliberately does not choose for you.

```bash
# The node tells you what is missing
kubectl describe node cp-01 | grep -A3 'Ready'
# KubeletNotReady  container runtime network not ready:
#   NetworkReady=false ... cni plugin not initialized
```

Pick one. The pod CIDR must match what you passed to `kubeadm init`.

```bash
# ── Calico ─────────────────────────────────────────────────────────
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/custom-resources.yaml
# Edit custom-resources.yaml so cidr matches your podSubnet
kubectl create -f custom-resources.yaml
```

```bash
# ── Cilium ─────────────────────────────────────────────────────────
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.16.3 \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=false
```

```bash
# ── Flannel ────────────────────────────────────────────────────────
# Requires podSubnet exactly 10.244.0.0/16 unless you edit the manifest.
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Then:

```bash
kubectl get nodes -w
# NAME    STATUS   ROLES           AGE   VERSION
# cp-01   Ready    control-plane   3m    v1.31.2

kubectl -n kube-system get pods     # CoreDNS should now be Running
```

See [cni.md](cni.md) and [cni-comparison.md](cni-comparison.md).

---

## Initialising for High Availability

Two additions to the single-node procedure.

**1. `controlPlaneEndpoint` must point at a load balancer**, not at one node. This cannot be changed later without regenerating certificates and rewriting every kubeconfig.

```yaml
controlPlaneEndpoint: "api.example.internal:6443"
```

**2. `--upload-certs`** encrypts the PKI into a Secret so other control plane nodes can fetch it during join.

```bash
sudo kubeadm init \
  --config kubeadm-config.yaml \
  --upload-certs
```

The output now includes two different join commands:

```
You can now join any number of control-plane node running the following
command on each as root:

  kubeadm join api.example.internal:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234... \
    --control-plane --certificate-key f8902e11...

Then you can join any number of worker nodes by running the following
on each as root:

  kubeadm join api.example.internal:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234...
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  The certificate key expires after TWO HOURS. If you are slow        │
   │  adding control plane nodes, regenerate it:                          │
   │      sudo kubeadm init phase upload-certs --upload-certs             │
   └──────────────────────────────────────────────────────────────────────┘
```

Full treatment, including the load balancer and etcd quorum arithmetic, in [ha-control-plane.md](ha-control-plane.md).

---

## Running Individual Phases

Every phase can be run alone. This is what makes kubeadm a repair tool as well as an installer.

```bash
# Regenerate an expired admin kubeconfig
sudo kubeadm init phase kubeconfig admin

# Regenerate the API server certificate after adding a SAN
sudo kubeadm init phase certs apiserver --config kubeadm-config.yaml

# Regenerate a corrupted control plane manifest
sudo kubeadm init phase control-plane apiserver --config kubeadm-config.yaml

# Re-upload configuration after editing it
sudo kubeadm init phase upload-config kubeadm --config kubeadm-config.yaml

# Redeploy CoreDNS
sudo kubeadm init phase addon coredns --config kubeadm-config.yaml

# Refresh the certificate key for HA joins
sudo kubeadm init phase upload-certs --upload-certs
```

Skipping phases during init is equally useful:

```bash
# Init without deploying kube-proxy, because Cilium will replace it
sudo kubeadm init --config kubeadm-config.yaml --skip-phases=addon/kube-proxy
```

---

## kubeadm reset

Undoes what init or join did on **this node**. It is the correct way to start over.

```bash
sudo kubeadm reset -f
```

What it removes: static pod manifests, `/etc/kubernetes/pki`, the kubeconfigs, etcd data (on a control plane node), and the kubelet configuration.

What it leaves behind, and you must clean yourself:

```bash
# iptables rules from kube-proxy
sudo iptables -F && sudo iptables -t nat -F
sudo iptables -t mangle -F && sudo iptables -X

# IPVS rules, if you used ipvs mode
sudo ipvsadm -C 2>/dev/null

# CNI configuration and interfaces
sudo rm -rf /etc/cni/net.d
sudo ip link delete cni0 2>/dev/null
sudo ip link delete flannel.1 2>/dev/null

# Leftover kubeconfig
rm -rf "$HOME/.kube"

# Confirm
sudo ls /etc/kubernetes/
sudo crictl ps
```

Skipping the CNI and iptables cleanup is the reason a second `kubeadm init` on the same machine often produces a cluster with broken networking. The stale `cni0` bridge carries an address from the previous pod CIDR.

---

## Recipes

### Recipe: Single-Node Cluster for Learning

```bash
#!/usr/bin/env bash
set -euo pipefail

sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address="$(hostname -I | awk '{print $1}')"

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

# CNI
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Allow workloads on the only node there is
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes
kubectl -n kube-system get pods
```

### Recipe: Hardened Init From a Config File

```bash
#!/usr/bin/env bash
set -euo pipefail

# Directories the config references. Omitting these means the API
# server cannot start, because the hostPath mounts point at nothing.
sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
sudo chmod 700 /var/log/kubernetes/audit

# A minimal audit policy so the flag has something to read
cat <<'EOF' | sudo tee /etc/kubernetes/audit/audit-policy.yaml >/dev/null
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["*"]
  - level: Metadata
EOF

kubeadm config validate --config kubeadm-config.yaml
sudo kubeadm config images pull --config kubeadm-config.yaml
sudo kubeadm init --config kubeadm-config.yaml --upload-certs

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# Verify the hardening actually landed
sudo grep -E 'anonymous-auth|authorization-mode|audit-log-path' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

### Recipe: Dry Run Everything First

```bash
# Shows every file that WOULD be written, without touching the system.
sudo kubeadm init --config kubeadm-config.yaml --dry-run

# Files are staged in a temp directory named in the output
sudo ls /etc/kubernetes/tmp/kubeadm-init-dryrun*/
```

Genuinely useful for reviewing generated manifests before committing to them.

---

## Command Reference

```bash
# ---------- Init ----------
sudo kubeadm init
sudo kubeadm init --config kubeadm-config.yaml
sudo kubeadm init --config kubeadm-config.yaml --upload-certs
sudo kubeadm init --dry-run
sudo kubeadm init --skip-phases=addon/kube-proxy
sudo kubeadm init --ignore-preflight-errors=NumCPU

# ---------- Phases ----------
sudo kubeadm init phase --help
sudo kubeadm init phase preflight
sudo kubeadm init phase certs all
sudo kubeadm init phase certs apiserver
sudo kubeadm init phase kubeconfig all
sudo kubeadm init phase kubeconfig admin
sudo kubeadm init phase control-plane all
sudo kubeadm init phase etcd local
sudo kubeadm init phase upload-config all
sudo kubeadm init phase upload-certs --upload-certs
sudo kubeadm init phase mark-control-plane
sudo kubeadm init phase bootstrap-token
sudo kubeadm init phase addon all

# ---------- Config ----------
kubeadm config print init-defaults
kubeadm config print init-defaults --component-configs KubeletConfiguration
kubeadm config validate --config kubeadm-config.yaml
kubeadm config migrate --old-config old.yaml --new-config new.yaml
kubeadm config images list
sudo kubeadm config images pull

# ---------- Tokens ----------
sudo kubeadm token list
sudo kubeadm token create --print-join-command
sudo kubeadm token create --ttl 1h --print-join-command
sudo kubeadm token delete TOKEN

# ---------- Certificates ----------
sudo kubeadm certs check-expiration
sudo kubeadm certs renew all

# ---------- Reset ----------
sudo kubeadm reset -f

# ---------- Verify ----------
kubectl get --raw '/healthz?verbose'
kubectl -n kube-system get pods
kubectl -n kube-system get cm kubeadm-config -o yaml
```

---

## Troubleshooting

### Init Hangs at `wait-control-plane`

```
[wait-control-plane] Waiting for the kubelet to boot up the control plane...
[kubelet-check] Initial timeout of 40s passed.
```

The kubelet is not successfully starting the static pods. Work down the stack.

```bash
# 1. Is the kubelet even running?
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100 --no-pager

# 2. Did any container get created?
sudo crictl ps -a

# 3. If a container exists but exits, read its logs
sudo crictl logs "$(sudo crictl ps -a --name kube-apiserver -q | head -1)"

# 4. If NO container was created, the kubelet rejected the manifest
sudo journalctl -u kubelet | grep -i -A5 'static\|manifest'
```

Most common causes, in order:

| Cause | Check |
|---|---|
| Cgroup driver mismatch | `sudo containerd config dump \| grep SystemdCgroup` |
| Sandbox image mismatch | `sudo containerd config dump \| grep sandbox_image` |
| Swap still enabled | `free -h` |
| `extraArgs` file with no matching `extraVolumes` | read the apiserver container logs |
| Port 6443 already in use | `sudo ss -lntp \| grep 6443` |
| Wrong `advertiseAddress` on a multi-homed host | `ip -brief addr` |

### `port 6443 is in use` During Preflight

A previous cluster is still running, or the reset was incomplete.

```bash
sudo ss -lntp | grep 6443
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd
```

### Node Stays `NotReady` Forever

```bash
kubectl describe node cp-01 | grep -A5 Conditions
# KubeletNotReady  ... cni plugin not initialized
```

Install a CNI. This is expected and is not a fault.

If a CNI is installed and the node is still `NotReady`:

```bash
kubectl -n kube-system get pods -o wide | grep -Ei 'calico|cilium|flannel'
ls /etc/cni/net.d/         # should contain a config
ls /opt/cni/bin/           # should contain plugin binaries
```

An empty `/opt/cni/bin` with a running CNI DaemonSet usually means the plugin binaries were never installed. See [installing-containerd.md](installing-containerd.md).

### CoreDNS Stuck `Pending` or `CrashLoopBackOff`

`Pending` means no CNI. Install one.

`CrashLoopBackOff` with a resolution loop:

```bash
kubectl -n kube-system logs -l k8s-app=kube-dns | tail -20
# [FATAL] plugin/loop: Loop ... detected
```

The node's `/etc/resolv.conf` points at a local stub resolver (`127.0.0.53` from systemd-resolved), and CoreDNS forwards to itself.

```bash
# Point the kubelet at the real upstream resolv.conf
sudo sed -i '/resolvConf/d' /var/lib/kubelet/config.yaml
echo 'resolvConf: /run/systemd/resolve/resolv.conf' | sudo tee -a /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
kubectl -n kube-system rollout restart deployment coredns
```

See [coredns.md](coredns.md).

### Init Succeeded But kubectl Cannot Connect

```
The connection to the server localhost:8080 was refused
```

No kubeconfig. This is not an auth failure; `kubectl` fell back to its compiled-in default.

```bash
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

### Nothing Schedules on a Single-Node Cluster

```bash
kubectl describe pod POD | tail -5
# 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }

kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### Lost the Join Command

```bash
sudo kubeadm token create --print-join-command
```

If you also need the CA hash manually:

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl rsa -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex | sed 's/^.* //'
```

### Certificate Key Expired for HA Join

```
error execution phase control-plane-prepare/download-certs:
error downloading certs: error downloading the secret: Secret "kubeadm-certs" was not found
```

The two-hour window elapsed.

```bash
sudo kubeadm init phase upload-certs --upload-certs
# prints a fresh certificate key
```

---

## Exam and Interview Traps

1. **Why is the node `NotReady` right after `kubeadm init`?** No CNI. kubeadm deliberately does not install one.

2. **What does kubeadm not install?** Container runtime, kubelet/kubeadm/kubectl packages, and a CNI plugin.

3. **Which kubeconfig should you copy to `~/.kube/config`?** `admin.conf`. Not `super-admin.conf`, which carries `system:masters` and bypasses RBAC.

4. **How long is the default bootstrap token valid?** 24 hours. Regenerate with `kubeadm token create --print-join-command`.

5. **How long is the HA certificate key valid?** Two hours. Refresh with `kubeadm init phase upload-certs --upload-certs`.

6. **What must be set at init time and is painful to change later?** `controlPlaneEndpoint`, the pod and service CIDRs, and `certSANs`.

7. **Why can nothing schedule on a single-node cluster?** The control plane `NoSchedule` taint. Remove it with a trailing dash.

8. **How does the control plane start when there is no control plane?** Static pod manifests in `/etc/kubernetes/manifests`, which the kubelet reads directly from disk.

9. **Where does kubeadm store the configuration for later upgrades and joins?** The `kubeadm-config` ConfigMap in `kube-system`.

10. **What does `--upload-certs` do?** Encrypts the PKI into a `kubeadm-certs` Secret so additional control plane nodes can fetch it during join.

11. **Stacked versus external etcd?** Stacked runs etcd on the control plane nodes (the kubeadm default). External runs it on separate machines for better isolation.

12. **What does `kubeadm reset` fail to clean up?** iptables and IPVS rules, CNI configuration in `/etc/cni/net.d`, CNI interfaces like `cni0`, and `~/.kube`. Stale CNI state is why a second init often has broken networking.

13. **You added a DNS name for the API server and TLS now fails. Why?** It is not in the certificate SANs. Add it to `certSANs`, regenerate `apiserver.crt`, restart.

14. **How do you fix an expired `admin.conf` without reinstalling?** `sudo kubeadm init phase kubeconfig admin`.

15. **Why does `extraArgs` referencing a file often break the API server?** Because the matching `extraVolumes` entry was omitted, so the file does not exist inside the static pod.

---

## Related Topics

- [preparing-linux-node.md](preparing-linux-node.md) for node prerequisites
- [installing-containerd.md](installing-containerd.md) for the runtime
- [installing-k8s-packages.md](installing-k8s-packages.md) for kubelet, kubeadm and kubectl
- [adding-worker-node.md](adding-worker-node.md) for the join side
- [ha-control-plane.md](ha-control-plane.md) for multi-master clusters
- [certificates.md](certificates.md) for the PKI the certs phase creates
- [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md) for the files init produces
- [cni.md](cni.md) for the networking layer you must install
- [etcd.md](etcd.md) for the datastore
- [cluster-upgrades.md](cluster-upgrades.md) for what happens next
- [cluster-hardening.md](cluster-hardening.md) for the flags worth setting at init
- [local-clusters.md](local-clusters.md) if you would rather not build this by hand

---

## Key Takeaways

- `kubeadm init` is a sequence of discrete phases, each of which can be run alone. That makes kubeadm a repair tool, not just an installer.
- kubeadm makes a conformant cluster and nothing else. Runtime, packages and CNI are your responsibility.
- A `NotReady` node immediately after init is correct. It is waiting for a CNI.
- Use a config file rather than flags for anything you will rebuild or upgrade. `extraArgs` referencing a file always needs a matching `extraVolumes`.
- Decide the pod and service CIDRs before init and make sure neither overlaps your real network. Changing them later means rebuilding.
- Set `controlPlaneEndpoint` even on a single node if you might ever add control plane nodes, because changing it later means regenerating certificates.
- Copy `admin.conf`, never `super-admin.conf`, into your home directory.
- The bootstrap token lasts 24 hours and the HA certificate key lasts two. Both are regenerable.
- Most init failures surface at `wait-control-plane`, and the cause is almost always below kubeadm: cgroup driver, sandbox image, swap, or a missing volume mount.
- `kubeadm reset` leaves iptables rules and CNI state behind. Clean them, or your next install will have mysterious networking faults.
- Save a local copy of the `kubeadm-config` ConfigMap. Several recovery procedures need it when the API is unreachable.

---

## References

- [Creating a Cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [kubeadm init](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/)
- [kubeadm init phase](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init-phase/)
- [kubeadm Configuration API v1beta4](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/)
- [Customizing Components with the kubeadm API](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/control-plane-flags/)
- [Options for Highly Available Topology](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/)
- [kubeadm reset](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-reset/)
- [Troubleshooting kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/)
- [Installing a Pod Network Add-on](https://kubernetes.io/docs/concepts/cluster-administration/addons/)
