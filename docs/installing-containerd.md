# 📦 Installing and Configuring containerd

Kubernetes does not run containers. It asks a container runtime to, over the Container Runtime Interface, and on the overwhelming majority of clusters that runtime is containerd. This document covers installing containerd on the major distributions, the generated configuration file in detail, the cgroup driver setting that causes more failed installs than anything else, the sandbox image version trap, registry mirrors and private registry authentication, and how to verify the whole stack with `crictl` before you ever run `kubeadm init`.

## 📋 Table of Contents
- [Where containerd Sits](#where-containerd-sits)
- [Prerequisites](#prerequisites)
- [Installing containerd](#installing-containerd)
- [Generating the Configuration](#generating-the-configuration)
- [The Cgroup Driver](#the-cgroup-driver)
- [The Sandbox Image](#the-sandbox-image)
- [The Full Annotated Config](#the-full-annotated-config)
- [Registry Configuration](#registry-configuration)
- [Private Registry Authentication](#private-registry-authentication)
- [Additional Runtimes](#additional-runtimes)
- [Verifying With crictl](#verifying-with-crictl)
- [Image Garbage Collection](#image-garbage-collection)
- [Proxies](#proxies)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Where containerd Sits

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                                                                      │
   │   kubelet                                                            │
   │      │                                                               │
   │      │  CRI  (gRPC over a unix socket)                               │
   │      │  /run/containerd/containerd.sock                              │
   │      ▼                                                               │
   │   containerd                                                         │
   │      │  ├─ CRI plugin        translates CRI into containerd calls    │
   │      │  ├─ snapshotter       manages image layers (overlayfs)        │
   │      │  ├─ content store     where image blobs live                  │
   │      │  └─ image service     pulls from registries                   │
   │      │                                                               │
   │      │  spawns a shim per container                                  │
   │      ▼                                                               │
   │   containerd-shim-runc-v2                                            │
   │      │                                                               │
   │      │  OCI runtime spec (config.json)                               │
   │      ▼                                                               │
   │   runc                                                               │
   │      │  clone(), setns(), capset(), seccomp(), pivot_root(), execve()│
   │      ▼                                                               │
   │   your container process                                             │
   │                                                                      │
   └──────────────────────────────────────────────────────────────────────┘
```

Two properties worth internalising:

**The shim outlives containerd.** Each container gets a shim process that is its actual parent. Restarting containerd does **not** kill running containers, because the shims keep them alive and reattach. This is why `systemctl restart containerd` is safe on a node with running pods.

**Docker is not in this path.** Modern Kubernetes talks to containerd directly. Docker Engine also uses containerd internally, but the `dockershim` that let the kubelet talk to Docker was removed in Kubernetes 1.24. Installing Docker on a node gives you containerd as a dependency, but the Docker daemon itself is not involved in running pods.

See [container-runtime.md](container-runtime.md) and [containers.md](containers.md).

---

## Prerequisites

These are prerequisites for the node generally, and are covered fully in [preparing-linux-node.md](preparing-linux-node.md). The runtime-critical subset:

```bash
# ── Kernel modules ─────────────────────────────────────────────────
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Verify
lsmod | grep -E 'overlay|br_netfilter'
```

`overlay` is the snapshotter containerd uses for image layers. `br_netfilter` makes bridged traffic traverse iptables, which pod networking depends on.

```bash
# ── Sysctls ────────────────────────────────────────────────────────
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Verify all three return 1
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward
```

```bash
# ── Swap off ───────────────────────────────────────────────────────
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
free -h | grep -i swap        # should show 0
```

---

## Installing containerd

Two approaches. Pick one and be consistent across the cluster.

### From the Distribution Repository

Simplest, and adequate for most clusters. The version lags upstream somewhat.

```bash
# ── Debian / Ubuntu ────────────────────────────────────────────────
sudo apt-get update
sudo apt-get install -y containerd
```

```bash
# ── RHEL / Rocky / Alma ────────────────────────────────────────────
# containerd.io comes from the Docker repository, not the base repos.
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y containerd.io
```

```bash
# ── SUSE / openSUSE ────────────────────────────────────────────────
sudo zypper install -y containerd
```

```bash
# ── Fedora ─────────────────────────────────────────────────────────
sudo dnf install -y containerd
```

### From the Upstream Binary

Gives you exact version control, which matters if you need a specific containerd feature or are matching an existing cluster.

```bash
CONTAINERD_VER=1.7.22
RUNC_VER=1.1.14
CNI_VER=1.5.1
ARCH=amd64

# 1. containerd
curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/containerd-${CONTAINERD_VER}-linux-${ARCH}.tar.gz"
sudo tar Cxzvf /usr/local "containerd-${CONTAINERD_VER}-linux-${ARCH}.tar.gz"

# 2. The systemd unit. The tarball does not include it.
sudo curl -fsSL -o /usr/local/lib/systemd/system/containerd.service \
  --create-dirs \
  https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

# 3. runc. containerd does NOT bundle it.
curl -fsSLO "https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.${ARCH}"
sudo install -m 755 "runc.${ARCH}" /usr/local/sbin/runc

# 4. CNI plugins. Required by every CNI, including Calico and Cilium.
curl -fsSLO "https://github.com/containernetworking/plugins/releases/download/v${CNI_VER}/cni-plugins-linux-${ARCH}-v${CNI_VER}.tgz"
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin "cni-plugins-linux-${ARCH}-v${CNI_VER}.tgz"

# Verify
containerd --version
runc --version
ls /opt/cni/bin
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Three separate things, frequently confused:                         │
   │                                                                      │
   │    containerd   the daemon the kubelet talks to                      │
   │    runc         the low-level OCI runtime containerd invokes         │
   │    CNI plugins  the binaries in /opt/cni/bin that wire up networking │
   │                                                                      │
   │  The containerd tarball contains only the first. Installing from a   │
   │  distribution package usually pulls all three; installing from the   │
   │  tarball does not.                                                    │
   └──────────────────────────────────────────────────────────────────────┘
```

---

## Generating the Configuration

**The packaged default configuration does not work with Kubernetes.** On Debian and Ubuntu, `/etc/containerd/config.toml` ships as a stub that disables the CRI plugin entirely. This is the single most common cause of a failed first install.

```bash
# Look at what the package gave you
cat /etc/containerd/config.toml
# disabled_plugins = ["cri"]       ← the kubelet cannot talk to this
```

Generate a proper one:

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo systemctl restart containerd
```

Confirm the CRI plugin is now active:

```bash
sudo ctr plugins ls | grep cri
# io.containerd.grpc.v1    cri    ...    ok
```

An `error` in that column, rather than `ok`, means the plugin failed to load. Check `journalctl -u containerd` for why.

---

## The Cgroup Driver

The most important setting in the file, and the cause of the most baffling failures.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  On a systemd host, systemd owns the cgroup hierarchy.               │
   │                                                                      │
   │  If containerd uses the `cgroupfs` driver while systemd manages      │
   │  cgroups, you get TWO cgroup managers writing to the same tree.      │
   │                                                                      │
   │  Result: resource limits are applied inconsistently, the node        │
   │  becomes unstable under memory pressure, and kubelet resource        │
   │  accounting drifts from reality.                                      │
   │                                                                      │
   │  Both containerd AND the kubelet must use `systemd`.                 │
   └──────────────────────────────────────────────────────────────────────┘
```

### Setting It in containerd

```bash
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

# Verify
sudo containerd config dump | grep SystemdCgroup
# SystemdCgroup = true
```

The setting lives here in the generated config:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

Be careful with `sed` here: older containerd versions had `systemd_cgroup` at a different path, which is a deprecated and *different* setting. Always verify with `containerd config dump` rather than trusting the edit.

### Setting It in the kubelet

kubeadm defaults to `systemd` in current versions, so usually there is nothing to do. Confirm:

```bash
sudo grep cgroupDriver /var/lib/kubelet/config.yaml
# cgroupDriver: systemd
```

If you are writing a kubeadm config yourself:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

### The Symptom of a Mismatch

A mismatch does not fail loudly at install time. It fails later, oddly:

```bash
kubectl get nodes
# NAME       STATUS     ROLES           AGE   VERSION
# worker-1   NotReady   <none>          2m    v1.31.2

sudo journalctl -u kubelet -n 50 --no-pager
# misconfiguration: kubelet cgroup driver: "systemd" is different from
# docker cgroup driver: "cgroupfs"
```

Or pods start, then get OOMKilled at values well below their limits, because the limit was written to a cgroup nobody is enforcing.

Check which cgroup version the host uses while you are here:

```bash
stat -fc %T /sys/fs/cgroup/
# cgroup2fs  = cgroup v2 (modern, preferred)
# tmpfs      = cgroup v1 (legacy)
```

See [cgroups.md](cgroups.md).

---

## The Sandbox Image

Every pod has a `pause` container holding its namespaces open. containerd has its own configured pause image, **separate from whatever kubeadm uses**, and the two drifting apart is a classic failure.

```toml
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.10"
```

```bash
# What does containerd think?
sudo containerd config dump | grep sandbox_image

# What does kubeadm want?
kubeadm config images list | grep pause
```

If they disagree, you get pods stuck in `ContainerCreating` and an error like:

```
Failed to create pod sandbox: rpc error: code = Unknown
desc = failed to get sandbox image "registry.k8s.io/pause:3.6":
failed to pull image ...
```

The usual cause is a stale `sandbox_image` in a config generated by an older containerd, while kubeadm has moved on to a newer pause version.

```bash
# Align them
PAUSE=$(kubeadm config images list 2>/dev/null | grep pause)
sudo sed -i "s#sandbox_image = .*#sandbox_image = \"${PAUSE}\"#" /etc/containerd/config.toml
sudo systemctl restart containerd
```

Also pre-pull it, so pod creation does not depend on registry availability:

```bash
sudo crictl pull registry.k8s.io/pause:3.10
```

See [pause-containers.md](pause-containers.md).

---

## The Full Annotated Config

The parts of `/etc/containerd/config.toml` that matter, with everything else omitted.

```toml
version = 2

# Where containerd keeps images, snapshots and container metadata.
# This grows. Put it on a filesystem with room, or move it here.
root = "/var/lib/containerd"

# Ephemeral runtime state. Cleared on reboot.
state = "/run/containerd"

[grpc]
  # The socket the kubelet connects to. If you change it, you must also
  # set --container-runtime-endpoint on the kubelet.
  address = "/run/containerd/containerd.sock"

[debug]
  # info by default. Set to "debug" when diagnosing, then set it back:
  # debug logging on a busy node is very noisy.
  level = "info"

[plugins."io.containerd.grpc.v1.cri"]

  # The pause image. MUST match what kubeadm expects.
  sandbox_image = "registry.k8s.io/pause:3.10"

  # Max size of a single log line before it is split. The kubelet
  # reassembles these; leave it alone unless you know why.
  max_container_log_line_size = 16384

  # Keep the CRI plugin serving even if it cannot reach a registry
  # at startup.
  disable_tcp_service = true

  [plugins."io.containerd.grpc.v1.cri".containerd]
    # Used when a pod specifies no runtimeClassName.
    default_runtime_name = "runc"

    # Setting this to true disables the pod sandbox image pull check.
    # Leave false.
    discard_unpacked_layers = false

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
        runtime_type = "io.containerd.runc.v2"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
          # THE critical setting. Must be true on any systemd host.
          SystemdCgroup = true

  [plugins."io.containerd.grpc.v1.cri".cni]
    # Where CNI plugin BINARIES live.
    bin_dir = "/opt/cni/bin"
    # Where CNI CONFIGURATION files live. Your CNI DaemonSet writes here.
    conf_dir = "/etc/cni/net.d"
    # Maximum CNI config files to read. 1 means "only the first,
    # alphabetically" which is usually what you want.
    max_conf_num = 1

  [plugins."io.containerd.grpc.v1.cri".registry]
    # Directory-based registry configuration. The modern form.
    # The older `mirrors` table under this section is deprecated.
    config_path = "/etc/containerd/certs.d"
```

After any edit:

```bash
# Validate before restarting. A malformed TOML stops containerd,
# which stops the whole node.
sudo containerd config dump >/dev/null && echo "config OK"

sudo systemctl restart containerd
sudo systemctl status containerd --no-pager
```

---

## Registry Configuration

The modern approach uses a directory per registry host, which is cleaner than the deprecated inline `mirrors` table.

```toml
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

### A Pull-Through Mirror for Docker Hub

Docker Hub rate limits anonymous pulls by source IP, and a cluster shares one egress address. This bites quickly.

```bash
sudo mkdir -p /etc/containerd/certs.d/docker.io
cat <<'EOF' | sudo tee /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://docker.io"

[host."https://registry.internal.example.com/v2/dockerhub-proxy"]
  capabilities = ["pull", "resolve"]
  # Fall through to the real registry if the mirror misses.
  skip_verify = false
EOF
```

### A Private Registry With a Custom CA

```bash
sudo mkdir -p /etc/containerd/certs.d/registry.internal.example.com
sudo cp registry-ca.crt /etc/containerd/certs.d/registry.internal.example.com/ca.crt

cat <<'EOF' | sudo tee /etc/containerd/certs.d/registry.internal.example.com/hosts.toml
server = "https://registry.internal.example.com"

[host."https://registry.internal.example.com"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/registry.internal.example.com/ca.crt"
EOF
```

### A Registry on a Non-Standard Port or Plain HTTP

```bash
sudo mkdir -p "/etc/containerd/certs.d/localhost:5000"
cat <<'EOF' | sudo tee "/etc/containerd/certs.d/localhost:5000/hosts.toml"
server = "http://localhost:5000"

[host."http://localhost:5000"]
  capabilities = ["pull", "resolve", "push"]
EOF
```

```
   ⚠ Never use `skip_verify = true` against a real registry. It turns a
     registry compromise, or anyone on the path, into a cluster compromise.
     Install the CA properly instead.
```

Changes under `certs.d` are picked up without restarting containerd, which is a genuine convenience. Test immediately:

```bash
sudo crictl pull registry.internal.example.com/myapp:1.4.2
```

---

## Private Registry Authentication

containerd itself can hold credentials, but on Kubernetes you almost always want `imagePullSecrets` instead, because node-level credentials let **any** pod on the node pull **any** image the node can reach, regardless of namespace.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  PREFER:  imagePullSecrets on the ServiceAccount                     │
   │           scoped per namespace, an actual authorization boundary     │
   │                                                                      │
   │  AVOID:   node-level credentials in containerd or                    │
   │           /var/lib/kubelet/config.json                                │
   │           every pod on the node inherits them                        │
   │                                                                      │
   │  BEST:    a kubelet credential provider plugin, so credentials are   │
   │           short-lived and never written to disk                       │
   └──────────────────────────────────────────────────────────────────────┘
```

Full treatment in [image-security.md](image-security.md).

If you genuinely need a node-level credential, for example to pull the pause image or CNI images before any Kubernetes object exists:

```bash
sudo mkdir -p /etc/containerd/certs.d/registry.internal.example.com
cat <<'EOF' | sudo tee -a /etc/containerd/certs.d/registry.internal.example.com/hosts.toml

[host."https://registry.internal.example.com".header]
  authorization = "Basic <base64 of user:password>"
EOF
sudo chmod 600 /etc/containerd/certs.d/registry.internal.example.com/hosts.toml
```

For `crictl` specifically, credentials can be passed per command rather than stored:

```bash
sudo crictl pull --creds 'user:password' registry.internal.example.com/myapp:1.4.2
```

---

## Additional Runtimes

Adding gVisor or Kata means adding a runtime table. The table key becomes the `handler` name a RuntimeClass refers to.

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = true
```

```bash
sudo systemctl restart containerd
sudo crictl info | jq '.config.containerd.runtimes | keys'
# [ "kata", "runc", "runsc" ]
```

That last command is the definitive check for whether a node supports a given handler. See [runtime-class.md](runtime-class.md).

---

## Verifying With crictl

`crictl` is the CRI-level equivalent of `docker`. It talks to containerd directly, below Kubernetes, which makes it the right tool for deciding whether a problem is a runtime problem or a Kubernetes problem.

### Configure It Once

Without configuration, `crictl` warns on every invocation about the endpoint.

```bash
cat <<'EOF' | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
```

### The Verification Sequence

Run this before `kubeadm init`. If any step fails, fix it now rather than debugging it through Kubernetes later.

```bash
# 1. Is containerd running and responding?
sudo crictl version
# RuntimeName:  containerd
# RuntimeVersion: v1.7.22

# 2. Is the CRI plugin healthy?
sudo crictl info | jq '.status.conditions'
# RuntimeReady: true
# NetworkReady: false   ← expected before a CNI is installed

# 3. Can it pull an image?
sudo crictl pull registry.k8s.io/pause:3.10
sudo crictl images

# 4. Is the cgroup driver right?
sudo containerd config dump | grep SystemdCgroup

# 5. Which runtimes are available?
sudo crictl info | jq '.config.containerd.runtimes | keys'
```

`NetworkReady: false` before a CNI is installed is normal and expected. It becomes `true` once a CNI writes its configuration into `/etc/cni/net.d`.

### Daily crictl

```bash
sudo crictl ps                    # running containers
sudo crictl ps -a                 # including exited
sudo crictl pods                  # pod sandboxes
sudo crictl images                # images on this node
sudo crictl logs <container-id>
sudo crictl exec -it <container-id> sh
sudo crictl inspect <container-id> | jq '.info.runtimeSpec.process'
sudo crictl inspectp <sandbox-id>
sudo crictl stats                 # live resource usage
sudo crictl rmi --prune           # remove unused images
```

```
   ⚠ `ctr` is NOT `crictl`.
                                                                          
     ctr     containerd's own low-level debug tool. Uses NAMESPACES.
             Kubernetes containers live in the `k8s.io` namespace, so
             plain `ctr containers ls` shows nothing useful.
                                                                          
     crictl  the CRI-level tool. Sees exactly what Kubernetes sees.
             This is almost always the one you want.
```

```bash
# ctr requires the namespace to see Kubernetes content
sudo ctr --namespace k8s.io images ls
sudo ctr --namespace k8s.io containers ls
```

---

## Image Garbage Collection

Images accumulate and fill the disk. The **kubelet** garbage collects them, not containerd, which surprises people looking in the wrong place for the setting.

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# Start deleting unused images when disk usage crosses this percentage.
imageGCHighThresholdPercent: 85
# Stop once usage falls to this.
imageGCLowThresholdPercent: 80
# Never delete an image younger than this, even if unused.
imageMinimumGCAge: 2m
```

```bash
# How much is containerd holding?
sudo du -sh /var/lib/containerd
sudo crictl images | wc -l

# Manual cleanup of unreferenced images
sudo crictl rmi --prune

# Check node disk pressure
kubectl describe node worker-1 | grep -A5 Conditions
```

A node under `DiskPressure` evicts pods, so this is a real availability concern on nodes that pull many distinct images. See [resource-management.md](resource-management.md).

---

## Proxies

If nodes reach the internet through a proxy, containerd needs telling. It is a systemd service, so this goes in a drop-in.

```bash
sudo mkdir -p /etc/systemd/system/containerd.service.d

cat <<'EOF' | sudo tee /etc/systemd/system/containerd.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://proxy.example.internal:3128"
Environment="HTTPS_PROXY=http://proxy.example.internal:3128"
# NO_PROXY must include the pod and service CIDRs, every node address,
# and the cluster domain. Omitting these sends INTERNAL traffic to the
# proxy, which breaks the cluster in confusing ways.
Environment="NO_PROXY=localhost,127.0.0.1,10.96.0.0/12,10.244.0.0/16,192.168.1.0/24,.svc,.cluster.local"
EOF

sudo systemctl daemon-reload
sudo systemctl restart containerd

# Verify it took
sudo systemctl show containerd --property=Environment
```

The `NO_PROXY` line is where people get hurt. If the service CIDR is absent, containerd tries to reach the in-cluster registry or the API server through an external proxy.

---

## Recipes

### Recipe: Complete Node Runtime Setup

Idempotent, suitable for running on every node.

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "== kernel modules"
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

echo "== sysctls"
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

echo "== swap off"
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab

echo "== install containerd"
if command -v apt-get >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y containerd
elif command -v dnf >/dev/null; then
  sudo dnf install -y dnf-plugins-core
  sudo dnf config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo
  sudo dnf install -y containerd.io
elif command -v zypper >/dev/null; then
  sudo zypper --non-interactive install containerd
else
  echo "unsupported distribution" >&2; exit 1
fi

echo "== generate config"
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

echo "== systemd cgroup driver"
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

echo "== registry config path"
sudo mkdir -p /etc/containerd/certs.d
if ! grep -q 'config_path' /etc/containerd/config.toml; then
  sudo sed -i '/\[plugins."io.containerd.grpc.v1.cri".registry\]/a\    config_path = "/etc/containerd/certs.d"' \
    /etc/containerd/config.toml
fi

echo "== crictl config"
cat <<'EOF' | sudo tee /etc/crictl.yaml >/dev/null
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

echo "== restart"
sudo systemctl daemon-reload
sudo systemctl enable --now containerd
sudo systemctl restart containerd
sleep 3

echo "== verify"
sudo crictl version
sudo containerd config dump | grep SystemdCgroup
sudo crictl info | jq '.status.conditions'
echo "containerd ready"
```

### Recipe: Pre-Pull Cluster Images

Makes `kubeadm init` fast and removes registry dependency from the critical path.

```bash
# On a control plane node
sudo kubeadm config images pull

# What it pulled
sudo crictl images

# Or explicitly, for a specific version
sudo kubeadm config images pull --kubernetes-version v1.31.2

# On a worker, only the pause image and kube-proxy are needed
sudo crictl pull registry.k8s.io/pause:3.10
sudo crictl pull registry.k8s.io/kube-proxy:v1.31.2
```

### Recipe: Health Check Across Every Node

```bash
#!/usr/bin/env bash
for node in cp-01 worker-01 worker-02 worker-03; do
  echo "=== $node"
  ssh "$node" '
    printf "  containerd: "; systemctl is-active containerd
    printf "  version:    "; sudo crictl version 2>/dev/null | grep RuntimeVersion | awk "{print \$2}"
    printf "  cgroup:     "; sudo containerd config dump 2>/dev/null | grep -m1 SystemdCgroup | tr -d " "
    printf "  sandbox:    "; sudo containerd config dump 2>/dev/null | grep -m1 sandbox_image | awk -F\" "{print \$2}"
    printf "  runtimes:   "; sudo crictl info 2>/dev/null | jq -rc ".config.containerd.runtimes | keys"
    printf "  disk:       "; sudo du -sh /var/lib/containerd 2>/dev/null | awk "{print \$1}"
  ' 2>/dev/null || echo "  UNREACHABLE"
done
```

Drift between nodes in cgroup driver or sandbox image is a common cause of "only some nodes are broken".

---

## Command Reference

```bash
# ---------- Service ----------
sudo systemctl status containerd
sudo systemctl restart containerd
sudo journalctl -u containerd -f
sudo journalctl -u containerd -n 100 --no-pager

# ---------- Configuration ----------
containerd config default | sudo tee /etc/containerd/config.toml
sudo containerd config dump
sudo containerd config dump | grep SystemdCgroup
sudo containerd config dump | grep sandbox_image
sudo ctr plugins ls | grep cri

# ---------- crictl ----------
sudo crictl version
sudo crictl info
sudo crictl info | jq '.status.conditions'
sudo crictl ps
sudo crictl ps -a
sudo crictl pods
sudo crictl images
sudo crictl pull IMAGE
sudo crictl logs CONTAINER_ID
sudo crictl exec -it CONTAINER_ID sh
sudo crictl inspect CONTAINER_ID | jq
sudo crictl inspectp SANDBOX_ID | jq
sudo crictl stats
sudo crictl rmi --prune

# ---------- ctr (low level, needs namespace) ----------
sudo ctr --namespace k8s.io images ls
sudo ctr --namespace k8s.io containers ls
sudo ctr --namespace k8s.io tasks ls

# ---------- Images for kubeadm ----------
kubeadm config images list
sudo kubeadm config images pull

# ---------- Disk ----------
sudo du -sh /var/lib/containerd
df -h /var/lib/containerd
```

---

## Troubleshooting

### `kubeadm init` Fails: "container runtime is not running"

```
[ERROR CRI]: container runtime is not running:
output: time="..." level=fatal msg="validate service connection:
CRI v1 runtime API is not implemented"
```

The CRI plugin is disabled. This is the packaged Debian and Ubuntu default.

```bash
grep disabled_plugins /etc/containerd/config.toml
# disabled_plugins = ["cri"]

containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo crictl version
```

### Node `NotReady` With a Cgroup Driver Complaint

```bash
sudo journalctl -u kubelet -n 50 --no-pager | grep -i cgroup
```

Make both sides agree on `systemd`:

```bash
sudo containerd config dump | grep SystemdCgroup     # must be true
sudo grep cgroupDriver /var/lib/kubelet/config.yaml  # must be systemd
sudo systemctl restart containerd kubelet
```

### Pods Stuck in `ContainerCreating`

```bash
kubectl describe pod POD | tail -20
```

Two dominant causes.

**Sandbox image mismatch:**

```
Failed to create pod sandbox: failed to get sandbox image
"registry.k8s.io/pause:3.6"
```

```bash
sudo containerd config dump | grep sandbox_image
kubeadm config images list | grep pause
# align them, restart containerd
```

**No CNI:**

```
Failed to create pod sandbox: plugin type="..." failed
network is not ready: cni plugin not initialized
```

```bash
ls /etc/cni/net.d/        # empty means no CNI is installed
ls /opt/cni/bin/          # empty means CNI plugin binaries are missing
```

Install a CNI, or install the CNI plugin binaries if the DaemonSet is running but `/opt/cni/bin` is empty. See [cni.md](cni.md).

### containerd Will Not Start After a Config Edit

```bash
sudo systemctl status containerd --no-pager
sudo journalctl -u containerd -n 50 --no-pager
```

Almost always malformed TOML. Validate before restarting next time:

```bash
sudo containerd config dump >/dev/null && echo OK
```

Recovery is to regenerate from scratch:

```bash
sudo mv /etc/containerd/config.toml /root/config.toml.broken
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
```

### Image Pulls Fail With a Certificate Error

```
failed to pull image: x509: certificate signed by unknown authority
```

```bash
# Option 1: trust the CA system wide
sudo cp registry-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
sudo systemctl restart containerd

# Option 2: per registry, preferred
sudo mkdir -p /etc/containerd/certs.d/registry.example.com
sudo cp registry-ca.crt /etc/containerd/certs.d/registry.example.com/ca.crt
# plus a hosts.toml referencing it
```

### `crictl` Warns About the Endpoint on Every Command

```
WARN[0000] runtime connect using default endpoints...
```

Write `/etc/crictl.yaml` as shown in [Verifying With crictl](#verifying-with-crictl).

### Disk Filling Up

```bash
sudo du -sh /var/lib/containerd/*
sudo crictl images | wc -l
sudo crictl rmi --prune
```

If it recurs, lower `imageGCHighThresholdPercent` in the kubelet config, or move `/var/lib/containerd` to a larger filesystem by setting `root` in `config.toml` and restarting.

### Restarting containerd Killed My Containers

It should not. The shims keep containers alive across a containerd restart.

If containers did die, check whether the shim binary is missing or mismatched:

```bash
ls -l /usr/local/bin/containerd-shim-runc-v2 /usr/bin/containerd-shim-runc-v2 2>/dev/null
sudo journalctl -u containerd -n 100 --no-pager | grep -i shim
```

A common cause is installing containerd from a tarball over a package install, leaving two versions of the shim on different paths.

---

## Exam and Interview Traps

1. **Why does `kubeadm init` fail immediately after `apt-get install containerd`?** The packaged config has `disabled_plugins = ["cri"]`. Regenerate it with `containerd config default`.

2. **What is the single most important containerd setting for Kubernetes?** `SystemdCgroup = true`, and it must match the kubelet's `cgroupDriver: systemd`.

3. **What happens on a cgroup driver mismatch?** The node goes `NotReady`, or worse, pods get OOMKilled below their limits because two managers are writing to the same cgroup tree.

4. **Does restarting containerd kill running containers?** No. Each container has a shim that is its real parent and survives the restart.

5. **Is Docker involved in running pods?** No. `dockershim` was removed in 1.24. The kubelet talks to containerd directly over CRI.

6. **Difference between `ctr` and `crictl`?** `crictl` is the CRI-level tool and sees what Kubernetes sees. `ctr` is containerd's low-level debug tool and needs `--namespace k8s.io` to see Kubernetes content at all.

7. **Why does `crictl info` show `NetworkReady: false` on a fresh node?** No CNI is installed yet. Expected before the CNI DaemonSet runs.

8. **What is the sandbox image and why does the version matter?** The pause image holding a pod's namespaces. If containerd's configured version differs from what kubeadm expects, pods stick in `ContainerCreating`.

9. **Who garbage collects images, containerd or the kubelet?** The kubelet, via `imageGCHighThresholdPercent`.

10. **Does the containerd tarball include runc?** No. containerd, runc and the CNI plugins are three separate installs when working from upstream binaries.

11. **What must `NO_PROXY` contain on a proxied node?** Pod CIDR, service CIDR, all node addresses, `.svc` and `.cluster.local`. Omitting them routes internal traffic through the proxy.

12. **Where does a RuntimeClass `handler` resolve to?** A table key under `plugins."io.containerd.grpc.v1.cri".containerd.runtimes` in `config.toml`.

13. **Why prefer `imagePullSecrets` over node-level registry credentials?** Node credentials let every pod on the node pull anything the node can reach, removing the namespace authorization boundary.

---

## Related Topics

- [container-runtime.md](container-runtime.md) for CRI and the runtime landscape
- [containers.md](containers.md) for images, layers and OCI
- [pause-containers.md](pause-containers.md) for what the sandbox image actually does
- [cgroups.md](cgroups.md) for why the cgroup driver matters
- [preparing-linux-node.md](preparing-linux-node.md) for the full node prerequisites
- [installing-k8s-packages.md](installing-k8s-packages.md) for kubelet, kubeadm and kubectl
- [bootstrapping-kubeadm.md](bootstrapping-kubeadm.md) for the next step
- [cni.md](cni.md) for the networking layer containerd calls
- [runtime-class.md](runtime-class.md) for adding gVisor or Kata
- [image-security.md](image-security.md) for registry credentials done properly
- [kubelet.md](kubelet.md) for the CRI client

---

## Key Takeaways

- containerd is what the kubelet actually talks to. Docker is not in the pod path, and has not been since 1.24.
- The packaged default config on Debian and Ubuntu disables the CRI plugin. Always regenerate with `containerd config default`.
- `SystemdCgroup = true` in containerd and `cgroupDriver: systemd` in the kubelet must agree. A mismatch produces a `NotReady` node or unpredictable OOM kills.
- The `sandbox_image` in containerd must match what kubeadm expects, or pods hang in `ContainerCreating`.
- containerd, runc and the CNI plugin binaries are three separate components. The upstream tarball only provides the first.
- Container shims outlive containerd, so restarting it does not kill running containers.
- Use `crictl`, not `ctr`, for anything Kubernetes related. `ctr` needs `--namespace k8s.io` and operates below the CRI.
- `NetworkReady: false` before a CNI is installed is normal.
- Registry configuration belongs in `/etc/containerd/certs.d`, which is read without a restart.
- Prefer `imagePullSecrets` over node-level credentials, which erase the namespace authorization boundary.
- Verify the runtime fully with `crictl` before running `kubeadm init`. Every minute spent there saves ten debugging through Kubernetes.

---

## References

- [Container Runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [containerd Documentation](https://github.com/containerd/containerd/tree/main/docs)
- [containerd CRI Plugin Configuration](https://github.com/containerd/containerd/blob/main/docs/cri/config.md)
- [containerd Registry Configuration](https://github.com/containerd/containerd/blob/main/docs/hosts.md)
- [crictl User Guide](https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md)
- [Configuring a cgroup Driver](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/configure-cgroup-driver/)
- [Kubelet Configuration Reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- [runc](https://github.com/opencontainers/runc)
- [CNI Plugins](https://github.com/containernetworking/plugins)
