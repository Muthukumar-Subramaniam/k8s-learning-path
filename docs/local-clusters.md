# 💻 Local Clusters: Kubernetes on Your Laptop

You do not need servers to learn Kubernetes. A laptop runs a real, conformant cluster in about sixty seconds, and roughly ninety percent of everything in this repository can be practised on it. This document covers kind, minikube, k3s and Docker Desktop: what each is actually doing, how to create single and multi-node clusters, how to get images, Ingress, LoadBalancer Services and persistent storage working locally, what genuinely cannot be learned this way, and how to tear it all down.

## 📋 Table of Contents
- [Which Tool](#which-tool)
- [Prerequisites](#prerequisites)
- [kind](#kind)
- [A Multi-Node kind Cluster](#a-multi-node-kind-cluster)
- [Getting Images Into kind](#getting-images-into-kind)
- [Ingress on kind](#ingress-on-kind)
- [minikube](#minikube)
- [minikube Addons](#minikube-addons)
- [k3s](#k3s)
- [Docker Desktop](#docker-desktop)
- [LoadBalancer Services Locally](#loadbalancer-services-locally)
- [Persistent Storage Locally](#persistent-storage-locally)
- [What You Cannot Learn Locally](#what-you-cannot-learn-locally)
- [Resource Tuning](#resource-tuning)
- [Managing Multiple Local Clusters](#managing-multiple-local-clusters)
- [Cleanup](#cleanup)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Which Tool

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  What are you doing?                                                 │
   │                                                                      │
   │  Learning Kubernetes, following this repo                            │
   │       └──►  kind        fast, multi-node, disposable                 │
   │                                                                      │
   │  CI pipelines that need a cluster                                    │
   │       └──►  kind        designed for exactly this                    │
   │                                                                      │
   │  Want addons and a GUI dashboard without assembly                    │
   │       └──►  minikube    batteries included                           │
   │                                                                      │
   │  Want something that survives reboots and feels like a server        │
   │       └──►  k3s         a real systemd service, genuinely lightweight│
   │                                                                      │
   │  Already run Docker Desktop and want a checkbox                      │
   │       └──►  Docker Desktop   simplest, least flexible                │
   │                                                                      │
   │  Practising CKA / CKAD / CKS                                         │
   │       └──►  kind for most of it, but do at least one kubeadm         │
   │             install on VMs. The exam assumes kubeadm.                │
   └──────────────────────────────────────────────────────────────────────┘
```

| | kind | minikube | k3s | Docker Desktop |
|---|---|---|---|---|
| Runs as | containers | VM or container | host process | VM |
| Startup | ~30 to 60 s | ~60 to 120 s | ~20 s | ~60 s |
| Multi-node | ✅ easy | ✅ `--nodes` | ✅ agents | ❌ |
| Multiple clusters | ✅ | ✅ profiles | awkward | ❌ |
| Survives reboot | ❌ by default | ✅ | ✅ | ✅ |
| RAM (1 node) | ~1.5 GB | ~2 GB | ~512 MB | ~2 GB |
| Upstream Kubernetes | ✅ | ✅ | ✅ (with omissions) | ✅ |
| LoadBalancer | needs cloud-provider-kind | ✅ `minikube tunnel` | ✅ built-in ServiceLB | ✅ localhost |
| Ingress | manual, one flag | ✅ addon | ✅ built-in Traefik | manual |
| Best for | learning, CI | exploring addons | persistent local env | convenience |

My recommendation for working through this repository: **kind**. It is fastest, the multi-node support is genuine (each node is a real kubelet), and destroying and recreating a cluster takes under a minute, which encourages experimentation.

---

## Prerequisites

### Container Runtime

kind and Docker Desktop need Docker or Podman. minikube can use either, or a hypervisor. k3s needs neither.

```bash
# Docker on Debian/Ubuntu
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker          # or log out and back in

docker run --rm hello-world
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Adding yourself to the `docker` group is equivalent to passwordless │
   │  root on that machine. The Docker daemon runs as root and will mount │
   │  any host path you ask it to.                                        │
   │                                                                      │
   │  Fine on a personal laptop. Not fine on a shared or production host. │
   │  Use rootless Docker or Podman there.                                │
   └──────────────────────────────────────────────────────────────────────┘
```

### kubectl

Always install `kubectl` separately rather than relying on a bundled one, so you control the version.

```bash
# Latest stable
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Verify the checksum. Skipping this is how you end up running someone
# else's kubectl.
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check

sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl kubectl.sha256

kubectl version --client
```

Worth adding immediately:

```bash
# Shell completion and a short alias
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc

# Show the current context in your prompt. Prevents a whole class of
# "wrong cluster" accidents once you have more than one.
echo '__kctx() { kubectl config current-context 2>/dev/null; }' >> ~/.bashrc
echo 'PS1="[\$(__kctx)] \w\\$ "' >> ~/.bashrc
```

See [kubectl.md](kubectl.md).

---

## kind

**K**ubernetes **in** **D**ocker. Each node is a container running a full kubelet and containerd, and the control plane runs as static pods inside the control plane container exactly as it would on a real machine.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                        HOW kind WORKS                                │
   │                                                                      │
   │   your laptop                                                        │
   │   ┌────────────────────────────────────────────────────────────┐    │
   │   │  Docker                                                     │    │
   │   │                                                             │    │
   │   │  ┌───────────────────────┐   ┌───────────────────────┐     │    │
   │   │  │ container:            │   │ container:            │     │    │
   │   │  │ kind-control-plane    │   │ kind-worker           │     │    │
   │   │  │                       │   │                       │     │    │
   │   │  │  containerd           │   │  containerd           │     │    │
   │   │  │  kubelet              │   │  kubelet              │     │    │
   │   │  │  static pods:         │   │  pods...              │     │    │
   │   │  │    kube-apiserver     │   │                       │     │    │
   │   │  │    etcd               │   │                       │     │    │
   │   │  │    scheduler          │   │                       │     │    │
   │   │  │    controller-manager │   │                       │     │    │
   │   │  └───────────────────────┘   └───────────────────────┘     │    │
   │   │            └──────── docker network "kind" ───────┘         │    │
   │   └────────────────────────────────────────────────────────────┘    │
   └──────────────────────────────────────────────────────────────────────┘
```

This is why kind is genuinely useful for learning internals: you can `docker exec` into a node and find `/etc/kubernetes/manifests`, the PKI directory, and a real kubelet config, exactly as described in [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md).

### Install

```bash
# Linux amd64
[ "$(uname -m)" = "x86_64" ] && \
  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

kind version
```

### First Cluster

```bash
kind create cluster
```

```
Creating cluster "kind" ...
 ✓ Ensuring node image (kindest/node:v1.31.2) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-kind"
```

```bash
kubectl cluster-info --context kind-kind
kubectl get nodes
# NAME                 STATUS   ROLES           AGE   VERSION
# kind-control-plane   Ready    control-plane   45s   v1.31.2
```

kind merges the new context into `~/.kube/config` and switches to it automatically. The context is always named `kind-<clustername>`.

### Look Inside a Node

The exercise that makes kind worth using for learning:

```bash
docker exec -it kind-control-plane bash

# Inside the node container:
ls /etc/kubernetes/manifests/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml

ls /etc/kubernetes/pki/
crictl ps
cat /var/lib/kubelet/config.yaml
systemctl status kubelet
```

Everything in [certificates.md](certificates.md), [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md) and [cluster-hardening.md](cluster-hardening.md) can be explored here, on a cluster you can destroy and recreate in a minute.

### Pinning the Kubernetes Version

```bash
# Use the node image digest for reproducibility
kind create cluster --name k131 \
  --image kindest/node:v1.31.2

kind create cluster --name k130 \
  --image kindest/node:v1.30.6
```

Running several versions side by side is how you learn version skew and upgrade behaviour without touching a real cluster. See [cluster-upgrades.md](cluster-upgrades.md).

---

## A Multi-Node kind Cluster

This is where kind earns its place. Real workers, real scheduling, real DaemonSets.

```yaml
# kind-multi.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lab

nodes:
  - role: control-plane
    # Node labels, so you can practise nodeSelector and affinity.
    labels:
      tier: control
    kubeadmConfigPatches:
      # kind passes these through to kubeadm, so you can configure the
      # cluster exactly as you would on real machines.
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # Map host ports to the node, so Ingress works from your browser.
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP

  - role: worker
    labels:
      tier: apps
      topology.kubernetes.io/zone: zone-a

  - role: worker
    labels:
      tier: apps
      topology.kubernetes.io/zone: zone-b

  - role: worker
    labels:
      tier: data
      topology.kubernetes.io/zone: zone-c

networking:
  # Disable the default CNI so you can install Calico or Cilium yourself.
  # Leave this out unless you actually want to do that: without a CNI,
  # nodes stay NotReady.
  # disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  # kube-proxy mode. Set to "none" if installing Cilium with
  # kube-proxy replacement.
  kubeProxyMode: "iptables"
```

```bash
kind create cluster --config kind-multi.yaml

kubectl get nodes --show-labels
# NAME                STATUS   ROLES           VERSION
# lab-control-plane   Ready    control-plane   v1.31.2
# lab-worker          Ready    <none>          v1.31.2
# lab-worker2         Ready    <none>          v1.31.2
# lab-worker3         Ready    <none>          v1.31.2
```

Those zone labels make topology spread constraints and pod anti-affinity genuinely testable:

```bash
kubectl get nodes -L topology.kubernetes.io/zone,tier
```

See [scheduling.md](scheduling.md).

### Installing Your Own CNI

Uncomment `disableDefaultCNI: true`, then:

```bash
# Calico
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/custom-resources.yaml

# Or Cilium
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.16.3 \
  --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes

kubectl get nodes -w   # NotReady until the CNI is up
```

This makes everything in [cni.md](cni.md), [network-policy.md](network-policy.md) and [ebpf.md](ebpf.md) practisable locally.

---

## Getting Images Into kind

The single most common kind confusion. **kind nodes do not see your local Docker images.** They have their own containerd content store.

```bash
docker build -t myapp:dev .
kubectl run myapp --image=myapp:dev
# ErrImagePull  ← kind tried to pull myapp:dev from Docker Hub
```

Three fixes.

```bash
# 1. Load the image into the cluster. Simplest for iteration.
kind load docker-image myapp:dev --name lab

# Multiple images at once
kind load docker-image myapp:dev sidecar:dev --name lab

# 2. Load from a tar archive
docker save myapp:dev -o myapp.tar
kind load image-archive myapp.tar --name lab

# 3. Verify what a node actually has
docker exec -it lab-control-plane crictl images | grep myapp
```

Always set `imagePullPolicy: IfNotPresent` for locally loaded images, or the kubelet tries to pull anyway:

```yaml
containers:
  - name: app
    image: myapp:dev
    # Without this, a :latest-style tag defaults to Always and fails.
    imagePullPolicy: IfNotPresent
```

See [image-security.md](image-security.md) for why the defaulting works this way.

### A Local Registry

For a tighter loop, run a registry kind can pull from:

```bash
#!/usr/bin/env bash
set -euo pipefail
REG=kind-registry
PORT=5001

# 1. Start a registry container if it is not already running.
if [ "$(docker inspect -f '{{.State.Running}}' "$REG" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${PORT}:5000" \
    --name "$REG" registry:2
fi

# 2. Create a cluster that trusts it.
cat <<EOF | kind create cluster --name lab --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
  - role: worker
EOF

# 3. Point each node at the registry.
for node in $(kind get nodes --name lab); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${PORT}"
  cat <<EOF | docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:${PORT}/hosts.toml"
[host."http://${REG}:5000"]
EOF
done

# 4. Put the registry on the kind network.
docker network connect kind "$REG" 2>/dev/null || true

echo "Push with:  docker tag myapp:dev localhost:${PORT}/myapp:dev"
echo "            docker push localhost:${PORT}/myapp:dev"
echo "Use image:  localhost:${PORT}/myapp:dev"
```

---

## Ingress on kind

Requires the `extraPortMappings` and `ingress-ready` label from the config above.

```bash
# 1. Install ingress-nginx, kind variant
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# 2. Wait for it
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

```yaml
# demo.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 2
  selector:
    matchLabels: { app: hello }
  template:
    metadata:
      labels: { app: hello }
    spec:
      containers:
        - name: hello
          image: nginxdemos/hello:plain-text
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  selector: { app: hello }
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
spec:
  ingressClassName: nginx
  rules:
    - host: hello.localdev.me     # resolves to 127.0.0.1, no /etc/hosts edit
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello
                port:
                  number: 80
```

```bash
kubectl apply -f demo.yaml

# hostPort 8080 was mapped to containerPort 80 in the kind config
curl http://hello.localdev.me:8080
```

`localdev.me` and its subdomains resolve to `127.0.0.1` publicly, which saves editing `/etc/hosts` for every hostname you want to test. `nip.io` works similarly.

See [ingress.md](ingress.md).

---

## minikube

Older than kind, more batteries included. Its distinguishing feature is the addon system.

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64

minikube start
```

### Drivers

minikube can run the cluster several ways, and the choice matters.

```bash
minikube start --driver=docker     # container, like kind. Fastest.
minikube start --driver=kvm2       # a real VM on Linux
minikube start --driver=podman     # rootless capable
minikube start --driver=none       # directly on the host, Linux only, root
```

`--driver=none` runs components straight on your machine with no isolation. It is occasionally useful in CI but will scatter state across your host.

### Multi-Node

```bash
minikube start --nodes=3 --cpus=2 --memory=2g
kubectl get nodes
```

### Profiles

Named clusters, roughly equivalent to kind's `--name`:

```bash
minikube start -p learning --kubernetes-version=v1.31.2
minikube start -p testing  --kubernetes-version=v1.30.6

minikube profile list
minikube profile learning       # switch
kubectl config use-context learning
```

### Images

Same problem as kind, different verbs:

```bash
minikube image load myapp:dev

# Or build directly inside minikube's Docker daemon, which avoids
# the load step entirely.
eval $(minikube docker-env)
docker build -t myapp:dev .
# Images built now are immediately visible to the cluster.
eval $(minikube docker-env -u)      # revert when done
```

---

## minikube Addons

The reason to choose minikube over kind.

```bash
minikube addons list
```

```
| ADDON                | STATUS   |
| ingress              | disabled |
| metrics-server       | disabled |
| dashboard            | disabled |
| storage-provisioner  | enabled  |
| registry             | disabled |
| csi-hostpath-driver  | disabled |
| volumesnapshots      | disabled |
```

```bash
# Ingress, no port mapping gymnastics required
minikube addons enable ingress

# metrics-server, so kubectl top and HPA work
minikube addons enable metrics-server
kubectl top nodes

# The web dashboard
minikube addons enable dashboard
minikube dashboard

# CSI driver with snapshot support, genuinely useful for practising
# the storage chapters
minikube addons enable volumesnapshots
minikube addons enable csi-hostpath-driver
```

That last pair makes [volume-snapshots.md](volume-snapshots.md) and [csi.md](csi.md) practisable locally, which is otherwise awkward.

### Reaching Services

```bash
# Open a Service in your browser
minikube service hello

# Just print the URL
minikube service hello --url

# Ingress host resolution
echo "$(minikube ip) hello.local" | sudo tee -a /etc/hosts
```

---

## k3s

A single binary, fully conformant, that runs as a systemd service. Not a toy: it is used in production at the edge. Lightweight because it strips optional alpha features and replaces some components.

```bash
curl -sfL https://get.k3s.io | sh -

sudo systemctl status k3s
sudo k3s kubectl get nodes
```

### Using Your Own kubectl

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config

kubectl get nodes
```

### What k3s Bundles

```
   INCLUDED BY DEFAULT               REPLACED OR OMITTED
   ───────────────────               ───────────────────
   Flannel CNI                       etcd → SQLite (single node)
   Traefik Ingress Controller        in-tree cloud providers removed
   ServiceLB (LoadBalancer)          legacy and alpha APIs dropped
   local-path StorageClass           Docker shim removed
   CoreDNS
   metrics-server
```

The bundling is convenient and occasionally in the way. Disable what you want to replace:

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --disable traefik \
  --disable servicelb \
  --flannel-backend=none \
  --disable-network-policy
```

Then install Calico or Cilium yourself.

### Adding Agents

```bash
# On the server
sudo cat /var/lib/rancher/k3s/server/node-token

# On another machine
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<server-ip>:6443 \
  K3S_TOKEN=<token> sh -
```

This makes a genuine multi-machine cluster out of spare hardware or VMs, and it survives reboots, which is the main reason to choose k3s for a persistent home lab.

---

## Docker Desktop

Simplest possible option if you already have it: Settings, Kubernetes, Enable Kubernetes, Apply.

```bash
kubectl config use-context docker-desktop
kubectl get nodes
```

| Pros | Cons |
|---|---|
| One checkbox | Single node only |
| Local images work with no loading step | One cluster only |
| `LoadBalancer` Services get `localhost` | No addon system |
| Integrated with the Docker GUI | Slower to reset |
| | Licence required for larger organisations |

Genuinely useful for quick application testing. Not adequate for learning multi-node behaviour, scheduling, DaemonSets or node failure, which is most of what makes Kubernetes interesting.

---

## LoadBalancer Services Locally

A `LoadBalancer` Service normally requires a cloud controller. Without one it stays `<pending>` forever.

```bash
kubectl get svc myapp
# NAME    TYPE           EXTERNAL-IP   PORT(S)
# myapp   LoadBalancer   <pending>     80:31234/TCP
```

Solutions per tool:

```bash
# ── kind: cloud-provider-kind ──────────────────────────────────────
# Run it alongside the cluster; it watches for LoadBalancer Services
# and provisions Docker-network addresses for them.
go install sigs.k8s.io/cloud-provider-kind@latest
sudo ~/go/bin/cloud-provider-kind

# ── minikube ───────────────────────────────────────────────────────
# Creates a route to the cluster. Runs in the foreground and needs sudo.
minikube tunnel

# ── k3s ────────────────────────────────────────────────────────────
# ServiceLB is built in. It just works, using the node IP.

# ── Docker Desktop ─────────────────────────────────────────────────
# EXTERNAL-IP becomes localhost automatically.
```

Or install MetalLB, which is the closest to how bare metal actually works and therefore the most educational:

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

kubectl wait --namespace metallb-system \
  --for=condition=ready pod --selector=app=metallb --timeout=120s

# Pick a range inside the kind Docker network
docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
# 172.18.0.0/16
```

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: local-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.18.255.200-172.18.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: local
  namespace: metallb-system
spec:
  ipAddressPools:
    - local-pool
```

See [metallb.md](metallb.md).

---

## Persistent Storage Locally

Every local tool ships a default StorageClass, so PVCs bind without configuration.

```bash
kubectl get storageclass
# kind:      standard (rancher.io/local-path)
# minikube:  standard (k8s.io/minikube-hostpath)
# k3s:       local-path (rancher.io/local-path)
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
  # storageClassName omitted, so the default is injected by the
  # DefaultStorageClass admission controller.
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  These provisioners are all node-local hostPath under the covers.    │
   │                                                                      │
   │  Consequence: ReadWriteMany does NOT work, and a pod bound to a PVC  │
   │  cannot move to another node. On a multi-node kind cluster this      │
   │  looks like a StatefulSet pod stuck Pending after a node is deleted. │
   │  That behaviour is correct, and worth seeing.                        │
   └──────────────────────────────────────────────────────────────────────┘
```

For `ReadWriteMany` locally, install the NFS CSI driver against an in-cluster NFS server, or use minikube's `csi-hostpath-driver` addon which supports snapshots.

See [persistent-volumes.md](persistent-volumes.md) and [storage-classes.md](storage-classes.md).

---

## What You Cannot Learn Locally

Be clear about the boundary so you know what still needs real infrastructure.

```
   ✗ True HA control plane behaviour       Needs 3 real machines and a
                                            load balancer. See ha-control-plane.md

   ✗ Real network partitions               Containers on one Docker bridge
                                            do not partition realistically

   ✗ Node failure and recovery             You can delete a kind node
                                            container, but disk, kernel and
                                            hardware failure modes are absent

   ✗ Cloud provider integration            Cloud LoadBalancers, cloud volumes,
                                            IRSA, node autoscaling

   ✗ Realistic performance and scale       Everything shares one kernel,
                                            one disk and one NIC

   ✗ etcd under real load                  Single-node etcd on a laptop SSD
                                            tells you nothing about latency

   ✗ Cluster Autoscaler                    No infrastructure to scale

   ⚠ kubeadm itself                        kind uses kubeadm internally, but
                                            you never run it. For CKA, do a
                                            manual install at least once.
```

That last point matters for certification. The CKA assumes a kubeadm cluster on real machines, and tasks like adding a node, upgrading a control plane or recovering etcd are muscle memory you only get from doing it. See [manual-install-k8s-cluster.md](manual-install-k8s-cluster.md).

A reasonable progression:

```
   1. kind          learn the API, workloads, services, storage, RBAC
   2. kind          multi-node: scheduling, affinity, DaemonSets, drain
   3. VMs + kubeadm build a cluster by hand, once, properly
   4. managed       see what a cloud provider does for you
```

---

## Resource Tuning

Local clusters are memory hungry. Keep them small.

```bash
# kind uses whatever Docker has. Limit the number of nodes rather
# than trying to cap the cluster itself.

# minikube is explicit
minikube start --cpus=2 --memory=2048 --disk-size=20g

# Check what is actually being used
docker stats --no-stream
kubectl top nodes        # needs metrics-server
```

On macOS and Windows, Docker Desktop runs a VM and its resource allocation caps everything inside it. Raise it in Settings, Resources before blaming Kubernetes for slowness.

Rough guidance:

| Cluster | RAM to allow |
|---|---|
| kind, 1 node | 2 GB |
| kind, 3 nodes | 4 GB |
| kind, 3 nodes plus Cilium plus monitoring | 8 GB |
| minikube with several addons | 4 GB |
| k3s, 1 node | 1 GB |

If your laptop has 8 GB total, use k3s or a single-node kind cluster and skip the observability stack.

---

## Managing Multiple Local Clusters

```bash
kind get clusters
minikube profile list
kubectl config get-contexts
```

```bash
# Switch
kubectl config use-context kind-lab
kubectl config use-context minikube

# kind writes its kubeconfig into ~/.kube/config automatically, but
# you can export one separately.
kind get kubeconfig --name lab > ~/.kube/lab.conf
KUBECONFIG=~/.kube/lab.conf kubectl get nodes
```

`kubectx` and `kubens` are worth installing once you have more than two:

```bash
sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens  /usr/local/bin/kubens

kubectx              # list and switch contexts
kubens kube-system   # switch namespace
```

See [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md) for what these are manipulating.

---

## Cleanup

Local clusters leak disk. Clean up deliberately.

```bash
# ── kind ───────────────────────────────────────────────────────────
kind delete cluster --name lab
kind delete clusters --all

# ── minikube ───────────────────────────────────────────────────────
minikube delete
minikube delete --all --purge      # also removes ~/.minikube

# ── k3s ────────────────────────────────────────────────────────────
sudo /usr/local/bin/k3s-uninstall.sh
sudo /usr/local/bin/k3s-agent-uninstall.sh    # on agents

# ── Reclaim Docker disk ────────────────────────────────────────────
docker system df
docker system prune -a --volumes      # removes ALL unused images/volumes
```

```
   ⚠ `docker system prune -a --volumes` removes every unused image and
     volume on the machine, not just Kubernetes ones. Check `docker system df`
     first and be sure nothing else needs them.
```

Stale contexts accumulate even after clusters are gone:

```bash
kubectl config get-contexts
kubectl config delete-context kind-old-cluster
kubectl config delete-cluster kind-old-cluster
kubectl config unset users.kind-old-cluster
```

---

## Recipes

### Recipe: A Complete Learning Cluster in One Command

Multi-node, Ingress, metrics-server, and a local registry.

```bash
#!/usr/bin/env bash
set -euo pipefail
CLUSTER=lab
REG=kind-registry
PORT=5001

echo "== registry"
if [ "$(docker inspect -f '{{.State.Running}}' "$REG" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${PORT}:5000" --name "$REG" registry:2
fi

echo "== cluster"
cat <<EOF | kind create cluster --name "$CLUSTER" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - { containerPort: 80,  hostPort: 8080, protocol: TCP }
      - { containerPort: 443, hostPort: 8443, protocol: TCP }
  - role: worker
    labels: { topology.kubernetes.io/zone: zone-a }
  - role: worker
    labels: { topology.kubernetes.io/zone: zone-b }
EOF

echo "== wire the registry into each node"
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${PORT}"
  echo "[host.\"http://${REG}:5000\"]" \
    | docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:${PORT}/hosts.toml"
done
docker network connect kind "$REG" 2>/dev/null || true

echo "== ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

echo "== metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# kind's kubelet serving certs are self-signed, so the scrape must skip verification.
kubectl -n kube-system patch deployment metrics-server --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}
]'

echo
echo "Ready."
echo "  Ingress:  http://<host>.localdev.me:8080"
echo "  Registry: localhost:${PORT}"
kubectl get nodes
```

That `--kubelet-insecure-tls` patch is worth understanding rather than copying blindly: it exists because kind's kubelets use self-signed serving certificates that were never approved through the CSR API. See [certificates.md](certificates.md).

### Recipe: Practise a Cluster Upgrade

```bash
# Build on the older version
kind create cluster --name upgrade-lab --image kindest/node:v1.30.6
kubectl get nodes

# kind cannot upgrade in place, but you can observe version skew by
# running both and comparing.
kind create cluster --name upgrade-lab-new --image kindest/node:v1.31.2

kubectl --context kind-upgrade-lab     version
kubectl --context kind-upgrade-lab-new version

# For a REAL upgrade exercise, use VMs and kubeadm. See cluster-upgrades.md.
```

### Recipe: Simulate Node Failure

```bash
# Deploy something with multiple replicas
kubectl create deployment web --image=nginx:1.27 --replicas=6
kubectl get pods -o wide

# Cordon and drain, the graceful path
kubectl cordon lab-worker
kubectl drain lab-worker --ignore-daemonsets --delete-emptydir-data
kubectl get pods -o wide        # rescheduled onto the remaining workers

kubectl uncordon lab-worker

# Now the ungraceful path: stop the node container outright
docker stop lab-worker2
kubectl get nodes -w            # NotReady after ~40s
# Pods are evicted after the toleration period, default 300s

docker start lab-worker2
```

This makes [node-maintenance.md](node-maintenance.md) and [pod-disruption-budgets.md](pod-disruption-budgets.md) concrete, on a cluster you cannot damage.

---

## Command Reference

```bash
# ---------- kind ----------
kind create cluster
kind create cluster --name lab --config kind.yaml
kind create cluster --image kindest/node:v1.31.2
kind get clusters
kind get nodes --name lab
kind get kubeconfig --name lab
kind load docker-image myapp:dev --name lab
kind load image-archive myapp.tar --name lab
kind export logs ./kind-logs --name lab
kind delete cluster --name lab

# ---------- minikube ----------
minikube start
minikube start --nodes=3 --cpus=2 --memory=2g
minikube start -p profile --kubernetes-version=v1.31.2
minikube status
minikube profile list
minikube addons list
minikube addons enable ingress
minikube image load myapp:dev
eval $(minikube docker-env)
minikube service NAME --url
minikube tunnel
minikube dashboard
minikube ssh
minikube delete --all --purge

# ---------- k3s ----------
curl -sfL https://get.k3s.io | sh -
sudo systemctl status k3s
sudo cat /var/lib/rancher/k3s/server/node-token
sudo k3s kubectl get nodes
sudo /usr/local/bin/k3s-uninstall.sh

# ---------- inspecting kind nodes ----------
docker exec -it lab-control-plane bash
docker exec lab-control-plane crictl ps
docker exec lab-control-plane crictl images
docker exec lab-control-plane cat /var/lib/kubelet/config.yaml
docker exec lab-control-plane ls /etc/kubernetes/manifests

# ---------- contexts ----------
kubectl config get-contexts
kubectl config use-context kind-lab
kubectl config delete-context kind-old

# ---------- cleanup ----------
kind delete clusters --all
minikube delete --all --purge
docker system df
docker system prune -a --volumes
```

---

## Troubleshooting

### `ErrImagePull` for an Image You Just Built

kind and minikube have their own image stores.

```bash
kind load docker-image myapp:dev --name lab
# or
minikube image load myapp:dev

# Confirm it landed
docker exec lab-control-plane crictl images | grep myapp
```

Also set `imagePullPolicy: IfNotPresent`, or a `:latest` tag will trigger a pull attempt regardless.

### Nodes Stay `NotReady`

```bash
kubectl get nodes
kubectl describe node lab-control-plane | grep -A5 Conditions
```

Almost always the CNI. If you set `disableDefaultCNI: true` and did not install one, this is expected.

```bash
kubectl -n kube-system get pods
docker exec lab-control-plane journalctl -u kubelet -n 50 --no-pager
```

### Cluster Creation Hangs or Fails

```bash
# Not enough inotify watches is the classic cause on Linux, and the
# error message does not say so.
cat <<'EOF' | sudo tee /etc/sysctl.d/99-kind.conf
fs.inotify.max_user_watches  = 524288
fs.inotify.max_user_instances = 512
EOF
sudo sysctl --system

# Then retry
kind delete cluster --name lab
kind create cluster --name lab
```

Also check free disk and memory:

```bash
docker system df
free -h
```

### `LoadBalancer` Stuck `<pending>`

Expected without a load balancer implementation. See [LoadBalancer Services Locally](#loadbalancer-services-locally). For quick access, use `port-forward` instead:

```bash
kubectl port-forward svc/myapp 8080:80
curl http://localhost:8080
```

### Ingress Returns Connection Refused

```bash
# 1. Were the ports mapped when the cluster was created?
docker port lab-control-plane
# 80/tcp -> 0.0.0.0:8080

# 2. Is the controller running?
kubectl -n ingress-nginx get pods

# 3. Does the node carry the ingress-ready label?
kubectl get nodes -l ingress-ready=true
```

`extraPortMappings` cannot be added to an existing cluster. If they are missing, recreate it.

### `kubectl top` Fails

metrics-server is not installed, or cannot scrape the kubelets.

```bash
kubectl -n kube-system logs deploy/metrics-server | tail -20
# x509: cannot validate certificate ... because it doesn't contain any IP SANs
```

kind's kubelet serving certificates are self-signed:

```bash
kubectl -n kube-system patch deployment metrics-server --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}
]'
```

On minikube, `minikube addons enable metrics-server` handles this for you.

### PVC Stuck `Pending`

```bash
kubectl describe pvc data | tail -10
kubectl get storageclass
```

If no default StorageClass exists, either name one explicitly or mark one default:

```bash
kubectl patch storageclass standard \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

On a multi-node kind cluster, also check `WaitForFirstConsumer`: the PVC will not bind until a pod is scheduled, which is correct behaviour and not a fault.

### Laptop Grinds to a Halt

```bash
docker stats --no-stream
kubectl top nodes
```

Reduce node count, remove the monitoring stack, or switch to k3s. A three-node kind cluster plus Cilium plus Prometheus needs about 8 GB, and will make an 8 GB laptop unusable.

### Everything Broke After a Reboot

kind clusters do not survive a Docker restart cleanly, by design.

```bash
docker start lab-control-plane lab-worker lab-worker2
sleep 30
kubectl get nodes
```

Often it recovers. If not, recreate, which takes a minute. If you need persistence, use k3s.

---

## Exam and Interview Traps

1. **Why does kind not see my locally built image?** Each kind node has its own containerd content store, separate from your host Docker daemon. Use `kind load docker-image`.

2. **What is kind actually running?** Real Kubernetes. Each node is a container running a kubelet and containerd, with the control plane as static pods, created via kubeadm internally.

3. **Why is my `LoadBalancer` Service pending?** No cloud controller. Use `cloud-provider-kind`, `minikube tunnel`, k3s ServiceLB, MetalLB, or just `port-forward`.

4. **Can you practise the CKA entirely on kind?** Most of it, but not the kubeadm tasks. The exam assumes a kubeadm cluster on real machines, and cluster upgrade and etcd recovery need that.

5. **Why does a multi-node local cluster fail `ReadWriteMany`?** The default provisioners are node-local hostPath. They cannot serve a volume to pods on different nodes.

6. **What does `extraPortMappings` do and when can you set it?** Maps host ports to a kind node container, which is how Ingress becomes reachable. It can only be set at cluster creation.

7. **Why does `kubectl top` fail on kind?** metrics-server cannot verify kind's self-signed kubelet serving certificates. Add `--kubelet-insecure-tls`.

8. **What does k3s replace etcd with on a single node?** SQLite.

9. **Which local tool survives a reboot properly?** k3s, because it is a systemd service. kind clusters are disposable by design.

10. **What does adding your user to the `docker` group actually grant?** Effectively passwordless root, since the daemon runs as root and will mount any host path.

11. **Why does a StatefulSet pod stay Pending after you delete a kind node?** Its PVC is bound to node-local storage that no longer exists. Correct behaviour, and a useful thing to observe.

12. **`disableDefaultCNI: true` and now nodes are NotReady. Why?** There is no CNI. That is the point of the flag; install Calico or Cilium.

---

## Related Topics

- [kubectl.md](kubectl.md) for the client you will use constantly
- [kubeconfig-and-manifests.md](kubeconfig-and-manifests.md) for contexts and the static pods you can inspect inside a kind node
- [k8s-installation-methods.md](k8s-installation-methods.md) for how these compare to production installs
- [manual-install-k8s-cluster.md](manual-install-k8s-cluster.md) for the kubeadm install you should still do once
- [cni.md](cni.md) for installing your own CNI on kind
- [ingress.md](ingress.md) for what the controller is doing
- [metallb.md](metallb.md) for LoadBalancer Services without a cloud
- [persistent-volumes.md](persistent-volumes.md) and [storage-classes.md](storage-classes.md) for local storage behaviour
- [scheduling.md](scheduling.md) for using the zone labels a multi-node kind cluster gives you
- [node-maintenance.md](node-maintenance.md) for drain and cordon practice
- [cluster-upgrades.md](cluster-upgrades.md) for version skew

---

## Key Takeaways

- A laptop runs a real, conformant Kubernetes cluster. Roughly ninety percent of this repository is practisable locally.
- kind is the best default for learning: fastest, genuinely multi-node, and disposable in under a minute.
- kind nodes are containers running real kubelets, so you can `docker exec` in and explore static pod manifests, the PKI and the kubelet config exactly as on a real node.
- Local clusters have their own image stores. `kind load docker-image` or `minikube image load`, and set `imagePullPolicy: IfNotPresent`.
- `extraPortMappings` must be set at creation time and is what makes Ingress reachable from your browser.
- `LoadBalancer` Services need help locally: cloud-provider-kind, `minikube tunnel`, k3s ServiceLB, MetalLB, or `port-forward`.
- Default local StorageClasses are node-local hostPath, so `ReadWriteMany` does not work and pods cannot migrate between nodes.
- minikube's addon system is its distinguishing feature, especially `csi-hostpath-driver` and `volumesnapshots` for the storage chapters.
- k3s is the choice for a persistent local environment, since it runs as a systemd service and survives reboots.
- You cannot learn real HA, cloud integration, genuine node failure or scale locally. Do at least one kubeadm install on VMs before a CKA attempt.
- Clean up deliberately. Local clusters leak disk, and stale kubeconfig contexts accumulate.

---

## References

- [kind Documentation](https://kind.sigs.k8s.io/)
- [kind Configuration Reference](https://kind.sigs.k8s.io/docs/user/configuration/)
- [kind Ingress Guide](https://kind.sigs.k8s.io/docs/user/ingress/)
- [kind Local Registry](https://kind.sigs.k8s.io/docs/user/local-registry/)
- [minikube Documentation](https://minikube.sigs.k8s.io/docs/)
- [minikube Addons](https://minikube.sigs.k8s.io/docs/handbook/addons/)
- [k3s Documentation](https://docs.k3s.io/)
- [Install Tools: kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Learning Environment Options](https://kubernetes.io/docs/tasks/tools/#kind)
- [Docker Desktop Kubernetes](https://docs.docker.com/desktop/kubernetes/)
