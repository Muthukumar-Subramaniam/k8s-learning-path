# 🧰 Preparing a Linux Node for Kubernetes

Every prerequisite that must be true on a Linux machine before `kubeadm` will touch it, and the reason each one exists.

## 📋 Table of Contents

- [Why Node Preparation Matters](#why-node-preparation-matters)
- [Hardware and OS Baselines](#hardware-and-os-baselines)
- [Node Identity: Hostname, MAC and product_uuid](#node-identity-hostname-mac-and-product_uuid)
- [Setting Hostnames and /etc/hosts](#setting-hostnames-and-etchosts)
- [Disabling Swap](#disabling-swap)
- [Kernel Modules: overlay and br_netfilter](#kernel-modules-overlay-and-br_netfilter)
- [Sysctl Settings for the Kubernetes Datapath](#sysctl-settings-for-the-kubernetes-datapath)
- [Time Synchronisation](#time-synchronisation)
- [Firewall Configuration](#firewall-configuration)
- [SELinux and AppArmor](#selinux-and-apparmor)
- [Package Repository Setup Context](#package-repository-setup-context)
- [Verification Checklist](#verification-checklist)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why Node Preparation Matters

`kubeadm init` and `kubeadm join` are thin orchestrators. They generate certificates, write manifests and talk to the API server, but they do almost nothing to the operating system itself. Every assumption kubeadm makes about the host must already be true, otherwise the preflight checks abort or, worse, the cluster comes up in a broken state that only shows itself hours later under load.

The owner's runnable sequence lives in [manual-install-k8s-cluster.md](manual-install-k8s-cluster.md) (Calico) and [manual-install-k8s-cluster-cilium.md](manual-install-k8s-cluster-cilium.md) (Cilium). This document explains what those steps actually do to the kernel and the filesystem.

```
┌──────────────────────────────────────────────────────────────────────┐
│                  Layers you build, bottom up                          │
├──────────────────────────────────────────────────────────────────────┤
│  5. Kubernetes control plane / workloads   <- kubeadm init            │
│  4. kubeadm, kubelet, kubectl packages     <- pkgs.k8s.io             │
│  3. Container runtime (containerd + runc)  <- CRI contract            │
│  2. Node preparation (THIS DOCUMENT)       <- kernel, network, time   │
│  1. Linux distribution + hardware                                     │
└──────────────────────────────────────────────────────────────────────┘
```

If layer 2 is wrong, layers 3, 4 and 5 fail in confusing ways. A cgroup driver mismatch looks like a runtime bug. A missing `br_netfilter` module looks like a CNI bug. Clock skew looks like a certificate bug. Almost every "Kubernetes is broken" incident in a fresh cluster is really a layer 2 problem.

---

## Hardware and OS Baselines

### Minimum sizing

| Resource | Control plane minimum | Worker minimum | Practical recommendation |
|----------|----------------------|----------------|--------------------------|
| CPU | 2 vCPU | 2 vCPU | 4 vCPU for control plane |
| RAM | 2 GB | 2 GB | 4 GB control plane, sized to workload on workers |
| Disk | 20 GB free | 20 GB free | Separate volume for `/var/lib/containerd` and `/var/lib/etcd` |
| Network | Full connectivity between all nodes | Same | Same L2 subnet or routed L3 with no NAT between nodes |

The 2 vCPU floor is not advisory. `kubeadm` has a preflight check named `NumCPU` that fails hard on a single core control plane node. The 2 GB memory floor is checked by `Mem` and produces a warning rather than a hard failure, but etcd plus the API server plus the kubelet on 1 GB will thrash.

> 📖 See [k8s-installation-requirements.md](k8s-installation-requirements.md) for the requirements table and [k8s-installation-considerations.md](k8s-installation-considerations.md) for where to place nodes.

### Disk layout that survives contact with reality

```
┌──────────────────────────────────────────────────────────────────────┐
│  Path                     │ Consumer          │ Why it grows          │
├───────────────────────────┼───────────────────┼───────────────────────┤
│  /var/lib/containerd      │ containerd        │ Image layers, snapshots│
│  /var/lib/kubelet         │ kubelet           │ Pod volumes, plugins   │
│  /var/lib/etcd            │ etcd (CP only)    │ Cluster state + WAL    │
│  /var/log/pods            │ kubelet           │ Container logs         │
│  /etc/kubernetes          │ kubeadm           │ PKI, kubeconfig, static│
│  /opt/cni/bin             │ CNI plugins       │ Binaries               │
│  /etc/cni/net.d           │ CNI config        │ Network config files   │
└───────────────────────────┴───────────────────┴───────────────────────┘
```

The kubelet enforces disk pressure eviction against the filesystem backing `/var/lib/kubelet` (nodefs) and the filesystem backing the container runtime's image store (imagefs). If both live on a small root filesystem, image pulls will trigger `DiskPressure`, which taints the node and evicts pods.

```bash
# Inspect the filesystems the kubelet cares about
df -h /var/lib/kubelet /var/lib/containerd /var/lib/etcd /var/log 2>/dev/null

# Confirm inode headroom, exhausted inodes cause the same eviction as full disks
df -i /var
```

### Supported distributions

The owner's procedure targets three families:

| Family | Examples | Package manager | Firewall default |
|--------|----------|-----------------|------------------|
| Red Hat based | RHEL, Rocky, AlmaLinux, Fedora, Oracle Linux | `dnf` | `firewalld` |
| Debian based | Debian, Ubuntu | `apt` | `ufw` (often inactive) |
| SUSE based | openSUSE, SLES | `zypper` | `firewalld` |

Control plane components run on Linux only. Windows can join as a worker node for Windows workloads, but the control plane is never Windows.

### Kernel version

Use a kernel your distribution actively supports. Practical floors:

| Feature | Kernel requirement |
|---------|--------------------|
| overlayfs snapshotter for containerd | 4.x with overlay, universally available |
| cgroup v2 unified hierarchy | 4.15+, realistically 5.8+ for full support |
| Cilium eBPF datapath (basic) | 4.19+ |
| Cilium kube-proxy replacement | 4.19.57+ or 5.1+ depending on feature |
| Calico eBPF dataplane | 5.3+ |

```bash
uname -r
# Check whether the system is on cgroup v2
stat -fc %T /sys/fs/cgroup
# cgroup2fs  -> unified hierarchy (v2)
# tmpfs      -> legacy hybrid or v1
```

> 📖 [cgroups.md](cgroups.md) explains why this matters for resource limits and for the cgroup driver.

---

## Node Identity: Hostname, MAC and product_uuid

Kubernetes identifies a node by its name, which by default is the hostname reported by the kubelet. Three values must be unique across the cluster.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Identifier      │ Where it lives                    │ Who uses it    │
├──────────────────┼───────────────────────────────────┼────────────────┤
│  Hostname        │ /etc/hostname, hostnamectl        │ kubelet node   │
│                  │                                   │ name, certs    │
│  MAC address     │ ip link show                      │ CNI, DHCP,     │
│                  │                                   │ L2 forwarding  │
│  product_uuid    │ /sys/class/dmi/id/product_uuid    │ Node status,   │
│                  │                                   │ cloud provider │
│  machine-id      │ /etc/machine-id                   │ systemd, node  │
│                  │                                   │ systemInfo     │
└──────────────────┴───────────────────────────────────┴────────────────┘
```

### Why uniqueness matters

A Kubernetes `Node` object is keyed by name. If two machines register with the same name, the second one overwrites the first one's status and the cluster silently loses a node while pods scheduled on the "ghost" node never start. Duplicate MAC addresses break L2 forwarding for the pod network. Duplicate `product_uuid` values confuse cloud provider integrations and node problem detectors, and they are the classic symptom of a cloned VM template.

### Checking uniqueness

```bash
# Run on every node and compare the output
echo "hostname     : $(hostname)"
echo "fqdn         : $(hostname -f 2>/dev/null)"
echo "machine-id   : $(cat /etc/machine-id)"
echo "product_uuid : $(sudo cat /sys/class/dmi/id/product_uuid)"
ip -o link show | awk -F': ' '{print $2}' | while read -r i; do
  [ "$i" = "lo" ] && continue
  echo "mac ${i}    : $(cat /sys/class/net/${i}/address 2>/dev/null)"
done
```

Collect the output from all nodes and diff it. A one line comparison from the control plane once the cluster exists:

```bash
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,UUID:.status.nodeInfo.systemUUID,MACHINEID:.status.nodeInfo.machineID,KERNEL:.status.nodeInfo.kernelVersion'
```

### Fixing a cloned VM

If you cloned a template and the identifiers collide:

```bash
# Regenerate the systemd machine-id
sudo rm -f /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo systemd-machine-id-setup
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
cat /etc/machine-id
```

`product_uuid` comes from the SMBIOS/DMI table and is set by the hypervisor, not by Linux. You cannot change it from inside the guest. Fix it in the hypervisor: in VMware regenerate the VM UUID, in KVM/libvirt edit the `<uuid>` element in the domain XML, in VirtualBox use `VBoxManage internalcommands sethduuid` plus a new machine UUID.

MAC addresses are likewise a hypervisor or NIC property. In libvirt, remove the `<mac address=...>` line from the domain XML and let libvirt generate a new one.

---

## Setting Hostnames and /etc/hosts

### Choosing node names

The kubelet registers the node under `--hostname-override` if set, otherwise under the value returned by the `os.Hostname()` syscall, lowercased. Node names must be valid DNS subdomain names (RFC 1123): lowercase alphanumerics, `-` and `.`, starting and ending with an alphanumeric.

```bash
# Set a persistent, fully qualified hostname
sudo hostnamectl set-hostname k8s-cp-01.lab.internal

# Verify both the static and transient hostname
hostnamectl status
hostname
hostname -f
```

> ⚠️ Uppercase letters in the hostname are a classic footgun. The kubelet lowercases the name for registration but some tooling and certificate SANs do not, producing mismatches. Use lowercase from the start.

### /etc/hosts

Kubernetes needs every node to resolve every other node's name. Real DNS is preferable, but `/etc/hosts` is the reliable fallback in a lab. The owner's prerequisites explicitly call for either working DNS or matching host files on all nodes.

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
192.168.10.11  k8s-cp-01.lab.internal   k8s-cp-01
192.168.10.12  k8s-cp-02.lab.internal   k8s-cp-02
192.168.10.13  k8s-cp-03.lab.internal   k8s-cp-03
192.168.10.21  k8s-wk-01.lab.internal   k8s-wk-01
192.168.10.22  k8s-wk-02.lab.internal   k8s-wk-02
192.168.10.10  k8s-api.lab.internal     # control plane endpoint / VIP
EOF
```

Ordering matters: the canonical (FQDN) name goes first, aliases after. Tools that reverse resolve an address take the first name.

### The 127.0.1.1 trap on Debian and Ubuntu

Debian installers write a line like:

```
127.0.1.1  k8s-wk-01.lab.internal  k8s-wk-01
```

This makes `hostname -i` return `127.0.1.1`. Some components and CNI installers pick that up as the node IP and advertise a loopback address to the cluster, which nothing else can reach. Either remove that line and rely on the real interface address, or make sure the kubelet knows the correct address:

```bash
# Verify what the system thinks its own address is
hostname -I          # all addresses
ip route get 1.1.1.1 # the source address used for default egress
```

If the node has multiple interfaces, pin the node IP explicitly (details in [installing-k8s-packages.md](installing-k8s-packages.md) and [creating-control-plane.md](creating-control-plane.md)):

```bash
# /etc/default/kubelet  (Debian family) or /etc/sysconfig/kubelet (RHEL family)
KUBELET_EXTRA_ARGS="--node-ip=192.168.10.11"
```

---

## Disabling Swap

### The commands

```bash
# Immediate: disable all active swap devices and files
sudo swapoff -a

# Persistent: comment out every swap entry in fstab
sudo sed -i '/swap/s/^/#/' /etc/fstab

# Verify
free -h
swapon --show     # should print nothing
```

That two command form is exactly what [manual-install-k8s-cluster.md](manual-install-k8s-cluster.md) Step 1 runs.

### When fstab is not enough

Modern systemd systems can activate swap through units rather than fstab, particularly `zram-generator` on Fedora and openSUSE, and cloud images that ship `swap.img`.

```bash
# Find every swap unit systemd knows about
systemctl --type swap --all --no-pager

# Mask the unit so nothing can start it again
sudo systemctl mask 'dev-zram0.swap'
sudo systemctl mask 'swap.target'

# Fedora / openSUSE zram specifically
sudo systemctl stop  systemd-zram-setup@zram0.service
sudo systemctl mask  systemd-zram-setup@zram0.service
sudo dnf remove -y zram-generator-defaults 2>/dev/null || true
```

On cloud images that regenerate swap at boot via cloud-init:

```bash
# Disable the cloud-init module that creates swap
sudo tee /etc/cloud/cloud.cfg.d/99-disable-swap.cfg >/dev/null <<'EOF'
mounts: []
EOF
```

Always reboot once and re-check `swapon --show` before you trust it. A node that comes back with swap after a reboot will fail to start the kubelet on that boot only, which is the hardest kind of failure to diagnose.

### Why kubelet refused to start with swap on

The kubelet's job is to enforce memory limits and to make eviction decisions. Both assume that a container's resident memory is the whole story.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Without swap                                                         │
│  container asks for memory -> hits memory.max -> OOM kill -> restart  │
│  Fast, deterministic, observable via OOMKilled                        │
├──────────────────────────────────────────────────────────────────────┤
│  With swap and no accounting                                          │
│  container asks for memory -> kernel swaps pages to disk              │
│  -> container "stays alive" but latency explodes                      │
│  -> node appears healthy, QoS classes become meaningless              │
│  -> eviction thresholds never trip, the whole node degrades           │
└──────────────────────────────────────────────────────────────────────┘
```

Three concrete consequences:

1. **Memory limits stop meaning anything.** A container limited to 512 Mi can use 512 Mi of RAM plus an unbounded amount of swap, so the limit no longer isolates it from neighbours.
2. **QoS classes break.** `Guaranteed`, `Burstable` and `BestEffort` are enforced through cgroup memory settings and eviction ordering. Swap lets a `BestEffort` pod survive at the expense of a `Guaranteed` pod's latency.
3. **The scheduler is lied to.** The scheduler places pods based on allocatable memory. Swap makes the node accept more work than it can serve at acceptable latency.

Because of this, the kubelet historically hard failed at startup when swap was enabled, controlled by the `failSwapOn` field in `KubeletConfiguration` (default `true`), and `kubeadm` has a `Swap` preflight check.

### The modern nuance: NodeSwap

Kubernetes has been adding first class, accounted swap support behind the `NodeSwap` feature gate. The important points, stated carefully and version agnostically:

- The feature is configured in `KubeletConfiguration` under `memorySwap.swapBehavior`.
- The accepted values are `NoSwap` and `LimitedSwap`. An older `UnlimitedSwap` value existed during early development and was removed; do not use it.
- `LimitedSwap` only grants swap to `Burstable` QoS pods, and the amount is proportional to the pod's memory request relative to node capacity. `Guaranteed` and `BestEffort` pods get no swap.
- Swap support requires **cgroup v2**. On cgroup v1 the kubelet does not support it.
- Even with the feature enabled, you must still set `failSwapOn: false` for the kubelet to start on a node with swap active.

```yaml
# /var/lib/kubelet/config.yaml fragment, ONLY if you have deliberately
# opted into swap support and are on cgroup v2
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
memorySwap:
  swapBehavior: LimitedSwap
```

> 🚨 **Recommendation for this repository's clusters: keep swap off.** The owner's procedure disables it, the preflight check expects it off, and every troubleshooting path in these documents assumes it. Enabling swap is a deliberate, benchmarked decision for specific workloads (large in memory caches with cold pages), not a default.

If you insist on running with swap for a lab, you must also pass `--ignore-preflight-errors=Swap` to `kubeadm init` and `kubeadm join`, which is a strong hint that you are off the paved road.

---

## Kernel Modules: overlay and br_netfilter

### The command

```bash
# Persist the module list, load them now, verify
(echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/k8s.conf >/dev/null) \
  && (xargs -r -a /etc/modules-load.d/k8s.conf -n1 sudo modprobe) \
  && (lsmod | grep -E "overlay|br_netfilter")
```

This is Step 3 of [manual-install-k8s-cluster.md](manual-install-k8s-cluster.md). Break it into its three parts:

1. `/etc/modules-load.d/k8s.conf` is read by `systemd-modules-load.service` at every boot, so the modules survive a reboot.
2. `modprobe` loads them into the running kernel immediately, so you do not have to reboot now.
3. `lsmod` proves they are actually resident.

### Why `overlay`

`overlay` is the kernel implementation of OverlayFS, a union filesystem that stacks a read only "lower" directory and a writable "upper" directory into a single merged view.

```
┌──────────────────────────────────────────────────────────────────────┐
│                    OverlayFS and container images                     │
│                                                                       │
│   merged (what the container sees)   /run/containerd/.../rootfs       │
│        ▲                                                              │
│        │                                                              │
│   ┌────┴───────────────────────────────────────────────────────┐     │
│   │ upperdir  (container writable layer, deleted on removal)    │     │
│   ├─────────────────────────────────────────────────────────────┤    │
│   │ lowerdir  image layer N   (read only, shared)               │     │
│   │ lowerdir  image layer N-1 (read only, shared)               │     │
│   │ lowerdir  image layer 1   (read only, shared)               │     │
│   └─────────────────────────────────────────────────────────────┘    │
│                                                                       │
│   Ten pods from the same image share one copy of every lower layer.   │
└──────────────────────────────────────────────────────────────────────┘
```

containerd's default snapshotter is `overlayfs`. Without the module, containerd falls back to the `native` snapshotter, which performs a full copy of every layer for every container. That works, but disk usage and container start time both explode. Confirm which snapshotter is actually in use:

```bash
sudo ctr plugins ls | grep snapshot
# io.containerd.snapshotter.v1  overlayfs  linux/amd64  ok
```

If the row shows `error` instead of `ok`, the module is missing or the backing filesystem does not support overlay (see Troubleshooting).

### Why `br_netfilter`

This is the module that makes bridged traffic traverse the netfilter (iptables/nftables) hooks.

```
┌──────────────────────────────────────────────────────────────────────┐
│  WITHOUT br_netfilter                                                 │
│                                                                       │
│  pod A ──veth──┐                          ┌──veth── pod B            │
│                ├──── Linux bridge cni0 ───┤                          │
│                └───────────────────────────┘                          │
│                        │                                              │
│                        └─ frames forwarded at L2, netfilter NEVER     │
│                           sees them                                   │
│                                                                       │
│  Result: kube-proxy Service rules bypassed, NetworkPolicy bypassed    │
├──────────────────────────────────────────────────────────────────────┤
│  WITH br_netfilter + bridge-nf-call-iptables=1                        │
│                                                                       │
│  pod A ──veth──┐                          ┌──veth── pod B            │
│                ├──── Linux bridge cni0 ───┤                          │
│                └───────────┬───────────────┘                          │
│                            ▼                                          │
│                  netfilter PREROUTING / FORWARD / POSTROUTING         │
│                  (kube-proxy DNAT, NetworkPolicy drops, masquerade)   │
│                                                                       │
│  Result: Services resolve, policies enforce, SNAT works               │
└──────────────────────────────────────────────────────────────────────┘
```

Every CNI that uses a Linux bridge for the node local segment (the reference `bridge` plugin, Flannel, Calico in certain modes, kind, and others) needs this. Even CNIs that avoid a bridge on the pod path frequently need it for host networking and for the `cbr0`-style interfaces created by helper components.

Loading the module alone is necessary but not sufficient. The module creates the sysctl knobs; you still have to turn them on, which is the next section.

### Additional modules worth knowing

| Module | Needed when |
|--------|-------------|
| `ip_vs`, `ip_vs_rr`, `ip_vs_wrr`, `ip_vs_sh`, `nf_conntrack` | kube-proxy in IPVS mode |
| `nf_conntrack` | Always in practice, autoloaded by netfilter |
| `xt_set`, `ip_set` | Calico with ipsets, Cilium legacy paths |
| `vxlan` | VXLAN overlay (Calico VXLAN, Cilium VXLAN, Flannel) |
| `wireguard` | Calico or Cilium transparent encryption |

```bash
# If you plan to run kube-proxy in IPVS mode, persist these too
sudo tee /etc/modules-load.d/ipvs.conf >/dev/null <<'EOF'
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
sudo systemctl restart systemd-modules-load.service
lsmod | grep -E '^ip_vs|^nf_conntrack'
```

> 📖 [kube-proxy.md](kube-proxy.md) covers iptables versus IPVS mode in detail.

---

## Sysctl Settings for the Kubernetes Datapath

### The command

```bash
(echo -e "net.ipv4.ip_forward = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1" \
  | sudo tee /etc/sysctl.d/k8s.conf >/dev/null) && sudo sysctl --system
```

This is Step 4 of [manual-install-k8s-cluster.md](manual-install-k8s-cluster.md). `sysctl --system` reloads every file under `/etc/sysctl.d`, `/run/sysctl.d`, `/usr/lib/sysctl.d` and `/etc/sysctl.conf`, in that precedence order, so the settings apply immediately and at every boot.

### What each knob actually changes

#### `net.ipv4.ip_forward = 1`

This flips the kernel from "host" behaviour to "router" behaviour for IPv4. With it set to `0`, a packet that arrives on one interface with a destination address that does not belong to this machine is silently dropped at the `ip_rcv_finish` stage. With it set to `1`, the packet enters the routing decision and is eligible for the `FORWARD` chain.

```
┌──────────────────────────────────────────────────────────────────────┐
│  ip_forward = 0                     │  ip_forward = 1                 │
│                                     │                                 │
│  eth0 ──► routing decision          │  eth0 ──► routing decision      │
│           │                         │           │                     │
│           ├─ for me? ──► INPUT      │           ├─ for me? ──► INPUT  │
│           └─ not me?  ──► DROP      │           └─ not me?  ──► FORWARD│
│                                     │                       └──► veth │
└──────────────────────────────────────────────────────────────────────┘
```

Everything in Kubernetes pod networking is forwarding. Traffic from a pod on node A to a pod on node B enters node B on the physical NIC with a destination address inside the pod CIDR, which is not a node address. Without forwarding, cross node pod traffic dies at the receiving node. Symptom: pods on the same node talk fine, pods on different nodes never connect, and CoreDNS lookups time out from half the cluster.

For IPv6 clusters or dual stack, add the equivalent:

```bash
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/k8s.conf
```

#### `net.bridge.bridge-nf-call-iptables = 1`

Created by the `br_netfilter` module. When set, frames traversing a Linux bridge are pushed up into the IPv4 netfilter hooks (`PREROUTING`, `FORWARD`, `POSTROUTING`) before being forwarded at L2.

Concretely this is what makes the following work:

- **Service ClusterIP resolution from a pod.** kube-proxy installs DNAT rules in `PREROUTING`/`OUTPUT`. A pod connecting to `10.96.0.10:53` sends the packet out its veth into the bridge. If netfilter never sees it, the DNAT never happens and the packet is forwarded to a nonexistent ClusterIP.
- **NetworkPolicy enforcement between pods on the same node.** Calico's iptables dataplane hangs policy rules off the `FORWARD` chain. Bypass netfilter and every same node policy silently allows.
- **Outbound SNAT/masquerade for pod egress.** The masquerade rule lives in `POSTROUTING`.

#### `net.bridge.bridge-nf-call-ip6tables = 1`

Identical semantics for IPv6. Set it even in an IPv4 only cluster: the preflight and many CNI installers check for it, and mixed IPv6 link local traffic on the bridge still benefits from consistent handling.

### The ordering trap

`net.bridge.bridge-nf-call-iptables` does not exist until `br_netfilter` is loaded. Writing it to `/etc/sysctl.d/k8s.conf` and running `sysctl --system` before loading the module produces:

```
sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory
```

This is exactly why the owner's procedure loads modules in Step 3 and applies sysctls in Step 4, in that order. At boot, `systemd-modules-load.service` runs before `systemd-sysctl.service`, so the persisted ordering is correct too.

### Additional sysctls that matter at scale

```bash
sudo tee /etc/sysctl.d/99-k8s-tuning.conf >/dev/null <<'EOF'
# Connection tracking table, exhausted on busy nodes -> random packet drops
net.netfilter.nf_conntrack_max = 1048576

# inotify limits, exhausted by many pods -> kubelet and CNI watch failures
fs.inotify.max_user_watches   = 524288
fs.inotify.max_user_instances = 8192

# ARP cache, overflowed in large flat pod networks
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# Do not let reverse path filtering drop asymmetric CNI traffic
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0

# Allow processes to bind to addresses not yet configured (VIP failover)
net.ipv4.ip_nonlocal_bind = 1

# PID exhaustion protection
kernel.pid_max = 4194304
EOF
sudo sysctl --system
```

> ⚠️ `rp_filter` is genuinely contentious. Calico documentation asks for `rp_filter=1` on the veth interfaces it manages for anti spoofing, while some overlay setups require loose or disabled mode. Follow your CNI's documentation; the values above are a starting point for a lab, not a universal truth.

> 📖 [linux-networking.md](linux-networking.md) explains routing, veth pairs, bridges and netfilter in depth. [nat.md](nat.md) covers SNAT/DNAT and masquerade.

### Verifying the applied values

```bash
sysctl net.ipv4.ip_forward \
       net.bridge.bridge-nf-call-iptables \
       net.bridge.bridge-nf-call-ip6tables

# Expected:
# net.ipv4.ip_forward = 1
# net.bridge.bridge-nf-call-iptables = 1
# net.bridge.bridge-nf-call-ip6tables = 1

# Prove they persist: which file set each value
sudo sysctl --system 2>&1 | grep -B1 -E 'ip_forward|bridge-nf'
```

---

## Time Synchronisation

### Why clock skew breaks TLS

Kubernetes is a mesh of mutually authenticated TLS connections. Every X.509 certificate carries `notBefore` and `notAfter` timestamps, and every TLS peer validates them against its own clock.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Node clock 10 minutes BEHIND the CA that issued the certificate      │
│                                                                       │
│  cert notBefore = 12:00:00                                            │
│  node thinks it is 11:52:00                                           │
│  ==> "certificate is not valid before 12:00:00" -> handshake fails    │
├──────────────────────────────────────────────────────────────────────┤
│  Node clock AHEAD past notAfter                                       │
│  ==> "certificate has expired or is not yet valid" -> handshake fails │
└──────────────────────────────────────────────────────────────────────┘
```

Beyond TLS, skew corrupts other things:

| Subsystem | Effect of clock skew |
|-----------|---------------------|
| etcd | Raft leases and lease expiry, leader election flapping |
| Lease based leader election (controller manager, scheduler) | Split brain or constant failover |
| Node heartbeat (`Lease` objects in `kube-node-lease`) | Node marked `NotReady` even though it is healthy |
| Bootstrap tokens | TTL evaluated wrongly, token appears expired |
| ServiceAccount projected tokens | `exp` claim rejected by the API server |
| Certificate rotation | Rotation triggered too early or too late |
| Log correlation | Every debugging session becomes guesswork |

### Configuring NTP

```bash
# --- chrony (RHEL family, SUSE, and available on Debian family) ---
sudo dnf install -y chrony      # or: apt-get install -y chrony / zypper install -y chrony
sudo systemctl enable --now chronyd

chronyc tracking      # offset, stratum, leap status
chronyc sources -v    # which servers, reachability, jitter

# --- systemd-timesyncd (default on many Ubuntu/Debian images) ---
sudo timedatectl set-ntp true
timedatectl status
# Expect: "System clock synchronized: yes" and "NTP service: active"
```

Pin an internal NTP server in air gapped or corporate environments:

```bash
# /etc/chrony.conf  (RHEL family path; Debian uses /etc/chrony/chrony.conf)
sudo sed -i 's/^pool .*/# &/' /etc/chrony.conf
echo 'server ntp1.corp.internal iburst' | sudo tee -a /etc/chrony.conf
echo 'server ntp2.corp.internal iburst' | sudo tee -a /etc/chrony.conf
sudo systemctl restart chronyd
```

### Timezone

Set every node to UTC. Mixed timezones make log correlation across nodes miserable, and while Kubernetes stores everything in UTC internally, `journalctl` and `crictl logs` render in local time.

```bash
sudo timedatectl set-timezone UTC
timedatectl
```

### Verifying skew across the fleet

```bash
# From a jump host, compare every node's clock to your own
for n in k8s-cp-01 k8s-wk-01 k8s-wk-02; do
  printf '%-12s %s\n' "$n" "$(ssh "$n" date -u +%s)"
done
printf '%-12s %s\n' "local" "$(date -u +%s)"
# Any difference greater than a couple of seconds needs investigating
```

---

## Firewall Configuration

### The port map

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          CONTROL PLANE NODE                               │
├──────────┬──────────┬───────────────────────────┬────────────────────────┤
│ Port     │ Protocol │ Component                 │ Who connects           │
├──────────┼──────────┼───────────────────────────┼────────────────────────┤
│ 6443     │ TCP      │ kube-apiserver            │ Everyone: kubectl,     │
│          │          │                           │ kubelets, controllers  │
│ 2379     │ TCP      │ etcd client API           │ kube-apiserver,        │
│          │          │                           │ etcdctl, backups       │
│ 2380     │ TCP      │ etcd peer API             │ Other etcd members     │
│ 10250    │ TCP      │ kubelet API               │ kube-apiserver, metrics│
│ 10257    │ TCP      │ kube-controller-manager   │ Self / metrics scrapers│
│ 10259    │ TCP      │ kube-scheduler            │ Self / metrics scrapers│
│30000-32767│ TCP/UDP │ NodePort Services         │ External clients       │
├──────────┴──────────┴───────────────────────────┴────────────────────────┤
│                             WORKER NODE                                   │
├──────────┬──────────┬───────────────────────────┬────────────────────────┤
│ 10250    │ TCP      │ kubelet API               │ kube-apiserver         │
│ 10256    │ TCP      │ kube-proxy health check   │ External load balancers│
│30000-32767│ TCP/UDP │ NodePort Services         │ External clients       │
└──────────┴──────────┴───────────────────────────┴────────────────────────┘
```

Notes on the less obvious entries:

- **10257 and 10259** are the HTTPS serving ports of the controller manager and scheduler. They expose `/healthz` and `/metrics`. They bind to `127.0.0.1` by default in a kubeadm cluster unless you change `--bind-address`, so they often need no firewall rule at all; open them only if you scrape metrics from another host.
- **10250** is the single most security sensitive port on a worker. It is the kubelet API: `exec`, `logs`, `portforward`, `run` all land there. It must be reachable from the API server and from nothing else. It requires client certificate authentication in a kubeadm cluster (anonymous auth off, webhook authorization on).
- **10255** was the deprecated read only kubelet port. Modern kubeadm clusters do not enable it. If you find it open, close it.
- **2379/2380** must only be reachable from other control plane nodes. etcd is the crown jewels: anyone who can reach it with the right client certificate reads every Secret in the cluster.

### CNI specific ports

| CNI | Port | Protocol | Purpose |
|-----|------|----------|---------|
| Calico | 179 | TCP | BGP peering between nodes and route reflectors |
| Calico | 4789 | UDP | VXLAN overlay (when IP-in-IP is not used) |
| Calico | 5473 | TCP | Typha, the datastore fan out proxy for large clusters |
| Calico | 51820 / 51821 | UDP | WireGuard encryption (IPv4 / IPv6) |
| Calico | IP protocol 4 | IPIP | IP-in-IP overlay mode (not a TCP/UDP port, a protocol number) |
| Cilium | 8472 | UDP | VXLAN overlay tunnel |
| Cilium | 6081 | UDP | Geneve overlay tunnel (alternative to VXLAN) |
| Cilium | 4240 | TCP | Cilium agent health checks between nodes |
| Cilium | 4244 | TCP | Hubble relay |
| Cilium | 4245 | TCP | Hubble UI |
| Cilium | 51871 | UDP | WireGuard encryption |
| Cilium | ICMP echo | ICMP | Node to node health probing |

> 📖 [bgp.md](bgp.md), [overlay-networks.md](overlay-networks.md) and [cni.md](cni.md) explain what those protocols carry.

### firewalld (Red Hat family, SUSE)

The owner's procedure takes the pragmatic path: rather than enumerate ports, trust the pod CIDR and the management network wholesale.

```bash
k8s_pod_network_cidr="10.8.0.0/22"                       # pod network of your choice

sudo firewall-cmd --permanent --zone=trusted --add-source="${k8s_pod_network_cidr}"
sudo firewall-cmd --permanent --zone=trusted --add-source=192.168.10.0/24   # node/mgmt network
sudo firewall-cmd --reload
```

Adding a source to the `trusted` zone means every packet from that source is accepted regardless of port. That is appropriate for a lab where the node network is already isolated, and it saves you from chasing every ephemeral port a CNI opens.

The explicit, least privilege alternative:

```bash
# --- Control plane ---
sudo firewall-cmd --permanent --add-port=6443/tcp          # kube-apiserver
sudo firewall-cmd --permanent --add-port=2379-2380/tcp     # etcd client + peer
sudo firewall-cmd --permanent --add-port=10250/tcp         # kubelet API
sudo firewall-cmd --permanent --add-port=10257/tcp         # controller-manager
sudo firewall-cmd --permanent --add-port=10259/tcp         # scheduler
sudo firewall-cmd --permanent --add-port=30000-32767/tcp   # NodePort

# --- Worker ---
sudo firewall-cmd --permanent --add-port=10250/tcp         # kubelet API
sudo firewall-cmd --permanent --add-port=10256/tcp         # kube-proxy healthz
sudo firewall-cmd --permanent --add-port=30000-32767/tcp   # NodePort

# --- Calico ---
sudo firewall-cmd --permanent --add-port=179/tcp           # BGP
sudo firewall-cmd --permanent --add-port=4789/udp          # VXLAN
sudo firewall-cmd --permanent --add-port=5473/tcp          # Typha
sudo firewall-cmd --permanent --add-protocol=ipip          # IP-in-IP mode

# --- Cilium ---
sudo firewall-cmd --permanent --add-port=8472/udp          # VXLAN
sudo firewall-cmd --permanent --add-port=4240/tcp          # health checks
sudo firewall-cmd --permanent --add-port=4244/tcp          # Hubble relay
sudo firewall-cmd --permanent --add-port=4245/tcp          # Hubble UI

sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

> ⚠️ **The firewalld masquerade trap.** If `firewall-cmd --list-all` shows `masquerade: yes` on the default zone, firewalld installs its own `POSTROUTING` masquerade that can conflict with the CNI's SNAT rules, producing pod traffic that arrives with the wrong source address. Also, firewalld reloads flush and rebuild the nftables ruleset, which on older combinations wiped kube-proxy and Calico rules. Always run `sudo firewall-cmd --reload` **before** installing the CNI, and if you must reload later, restart the CNI DaemonSet and kube-proxy afterwards and verify connectivity.

### ufw (Debian and Ubuntu)

```bash
sudo ufw status verbose      # frequently "inactive" on server images; then do nothing

# If it is active, control plane:
sudo ufw allow 6443/tcp
sudo ufw allow 2379:2380/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 10257/tcp
sudo ufw allow 10259/tcp
sudo ufw allow 30000:32767/tcp

# Worker:
sudo ufw allow 10250/tcp
sudo ufw allow 10256/tcp
sudo ufw allow 30000:32767/tcp

# Trust the pod and node networks outright (simplest for a lab)
sudo ufw allow from 10.8.0.0/22
sudo ufw allow from 192.168.10.0/24

# ufw defaults DROP on FORWARD, which kills pod-to-pod routing
sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw reload
```

> ⚠️ The `DEFAULT_FORWARD_POLICY` line is the one people miss. `ip_forward=1` makes the kernel willing to forward; ufw's `FORWARD` chain policy of `DROP` then throws the packet away anyway. Symptom is identical to forgetting `ip_forward`: same node pod traffic works, cross node does not.

### nftables directly

```bash
sudo tee /etc/nftables.d/k8s.nft >/dev/null <<'EOF'
table inet k8s {
  chain input {
    type filter hook input priority filter; policy drop;

    ct state established,related accept
    iif "lo" accept

    # Trust the node/management and pod networks
    ip saddr 192.168.10.0/24 accept
    ip saddr 10.8.0.0/22     accept

    # Control plane
    tcp dport 6443       accept comment "kube-apiserver"
    tcp dport 2379-2380  accept comment "etcd client and peer"
    tcp dport 10250      accept comment "kubelet API"
    tcp dport 10257      accept comment "kube-controller-manager"
    tcp dport 10259      accept comment "kube-scheduler"

    # Workers
    tcp dport 10256      accept comment "kube-proxy healthz"

    # NodePort range
    tcp dport 30000-32767 accept
    udp dport 30000-32767 accept

    # CNI overlays
    udp dport 4789 accept comment "Calico VXLAN"
    udp dport 8472 accept comment "Cilium VXLAN"
    tcp dport 179  accept comment "Calico BGP"
    tcp dport 4240 accept comment "Cilium health"
    tcp dport 5473 accept comment "Calico Typha"

    icmp type echo-request accept
  }

  chain forward {
    # Kubernetes needs to forward, do not drop here
    type filter hook forward priority filter; policy accept;
  }
}
EOF
sudo nft -f /etc/nftables.d/k8s.nft
sudo nft list ruleset | head -50
```

> 🚨 Hand written nftables rules and kube-proxy coexist, but kube-proxy (and Calico, and Cilium) install their own tables and chains. Never run `nft flush ruleset` on a running node: it deletes every Service DNAT rule and every policy rule in one keystroke, and the only fix is restarting kube-proxy and the CNI agents.

### Testing reachability before you install anything

```bash
# From a worker, prove the API server port is open on the control plane
nc -vz 192.168.10.11 6443
# or, without netcat:
timeout 3 bash -c '</dev/tcp/192.168.10.11/6443' && echo open || echo closed

# From a control plane node, prove kubelet ports are reachable on workers
for n in 192.168.10.21 192.168.10.22; do nc -vz "$n" 10250; done
```

---

## SELinux and AppArmor

### SELinux on the Red Hat family

SELinux enforces mandatory access control by labelling every file and process. Container runtimes need specific labels (`container_file_t`, `container_t`, `container_runtime_t`) and specific booleans to work correctly. Historically, upstream Kubernetes documentation recommended setting SELinux to permissive because several CNI plugins and CSI drivers write to host paths whose labels the base policy does not permit.

```bash
# Inspect current state
getenforce                 # Enforcing | Permissive | Disabled
sestatus

# Set permissive for the running system
sudo setenforce 0

# Persist across reboots
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
grep '^SELINUX=' /etc/selinux/config
```

**Why permissive rather than disabled.** In permissive mode the policy is still loaded and every denial is logged to the audit log but not enforced. That means you keep the ability to see exactly what would have been blocked, and you can move back to enforcing later after building the needed policy. Fully disabling SELinux unloads the policy and, critically, stops labelling the filesystem; returning to enforcing then requires a full relabel (`touch /.autorelabel && reboot`) which on a large filesystem takes a long time.

**Working towards enforcing.** If your compliance posture requires enforcing:

```bash
# Ensure container SELinux policy is installed
sudo dnf install -y container-selinux policycoreutils-python-utils

# Watch what would be denied while you exercise the cluster
sudo ausearch -m AVC,USER_AVC -ts recent
sudo audit2allow -a          # human readable summary of denials
sudo audit2why  -a           # why each denial happened
```

Kubernetes itself supports SELinux contexts on pods via `securityContext.seLinuxOptions`, and CSI drivers can support the `SELinuxMountReadWriteOncePod` behaviour to mount volumes with the right label. Confirm your CNI and CSI drivers document enforcing support before you commit.

### AppArmor on the Debian family

AppArmor is path based rather than label based and rarely blocks Kubernetes components, so it is normally left enabled.

```bash
sudo aa-status
# Profiles for containerd and runc are usually in complain or unconfined mode already
```

Kubernetes supports AppArmor profiles for containers via the `appArmorProfile` field in `securityContext`. Leave AppArmor enabled unless you have a specific denial.

---

## Package Repository Setup Context

Node preparation ends where package installation begins. Two categories of packages are involved.

### System packages

The owner's Step 2 updates the base system and installs the small toolkit the rest of the procedure depends on:

```bash
# Red Hat family
sudo dnf clean all && sudo dnf update --refresh -y && sudo dnf install -y curl wget rsync jq

# Debian family
sudo apt clean all && sudo apt update && sudo apt upgrade -y && sudo apt install -y curl wget rsync jq

# SUSE family
sudo zypper clean -a && sudo zypper rr && sudo zypper update -y && sudo zypper install -y curl wget rsync jq
```

Why each tool:

| Tool | Used for |
|------|----------|
| `curl` | Querying the GitHub releases API to resolve the latest versions dynamically |
| `wget` | Downloading release tarballs and the containerd systemd unit |
| `rsync` | Copying extracted containerd binaries into `/usr/bin` preserving permissions |
| `jq` | Parsing the JSON from the releases API to extract `tag_name` |

Reboot if the update replaced the kernel:

```bash
# Red Hat family
sudo dnf needs-restarting -r ; echo "exit code $? (1 means reboot needed)"
# Debian family
[ -f /var/run/reboot-required ] && echo "reboot required"
sudo reboot
```

Reboot **before** installing containerd and Kubernetes, not after. Rebooting later means the kernel modules and sysctls you set get re-applied under a new kernel that may not have the same modules built.

### The Kubernetes package repository

Kubernetes packages come from `pkgs.k8s.io`, which is organised per minor version. That structure and the exact commands per distribution are covered in [installing-k8s-packages.md](installing-k8s-packages.md), which links to the owner's runnable per distribution documents:

- [install-k8s-pkgs-debian.md](install-k8s-pkgs-debian.md)
- [install-k8s-pkgs-redhat.md](install-k8s-pkgs-redhat.md)
- [install-k8s-pkgs-suse.md](install-k8s-pkgs-suse.md)

### Air gapped considerations

If the node cannot reach the internet, you need, before you start:

1. A local mirror of the Kubernetes RPM or DEB repository, or the `.rpm`/`.deb` files staged locally.
2. The containerd, runc and CNI plugin tarballs staged locally.
3. A registry mirror holding every image in `kubeadm config images list`, plus the CNI images.
4. `containerd` configured with a registry mirror pointing at that registry (see [installing-containerd.md](installing-containerd.md)).
5. `--image-repository` set in the kubeadm configuration so `kubeadm init` pulls from your registry rather than `registry.k8s.io`.

---

## Verification Checklist

Run this on every node before proceeding to the container runtime. It is deliberately one screen of output.

```bash
#!/usr/bin/env bash
# Kubernetes node readiness check. Run with sudo.
set -u
pass() { printf '  [ OK ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }

echo "=== Identity ==="
printf '  hostname     : %s\n' "$(hostname)"
printf '  machine-id   : %s\n' "$(cat /etc/machine-id)"
printf '  product_uuid : %s\n' "$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)"

echo "=== Resources ==="
cpus=$(nproc); [ "$cpus" -ge 2 ] && pass "CPU cores: $cpus" || fail "CPU cores: $cpus (need >= 2)"
memk=$(awk '/MemTotal/{print $2}' /proc/meminfo)
[ "$memk" -ge 1900000 ] && pass "Memory: $((memk/1024)) MB" || warn "Memory: $((memk/1024)) MB (need >= 2048)"

echo "=== Swap ==="
[ -z "$(swapon --show --noheadings 2>/dev/null)" ] && pass "swap is off" || fail "swap is ACTIVE"
grep -qE '^[^#].*\sswap\s' /etc/fstab && fail "active swap entry still in /etc/fstab" || pass "fstab clean"

echo "=== Kernel modules ==="
for m in overlay br_netfilter; do
  lsmod | grep -q "^${m}" && pass "module $m loaded" || fail "module $m NOT loaded"
done
[ -f /etc/modules-load.d/k8s.conf ] && pass "modules persisted" || fail "/etc/modules-load.d/k8s.conf missing"

echo "=== Sysctl ==="
for k in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables; do
  v=$(sysctl -n "$k" 2>/dev/null)
  [ "$v" = "1" ] && pass "$k = 1" || fail "$k = ${v:-missing}"
done

echo "=== Time ==="
timedatectl show -p NTPSynchronized --value | grep -q yes \
  && pass "clock synchronised" || warn "clock NOT synchronised"

echo "=== cgroups ==="
printf '  hierarchy    : %s\n' "$(stat -fc %T /sys/fs/cgroup)"

echo "=== SELinux ==="
command -v getenforce >/dev/null && printf '  selinux      : %s\n' "$(getenforce)"

echo "=== Disk ==="
df -h /var | tail -1
```

Expected result: every line `[ OK ]`, warnings acceptable only if you understand them.

---

## Troubleshooting

### `swapoff -a` succeeds but swap returns after reboot

```bash
swapon --show
systemctl --type swap --all --no-pager
grep -n swap /etc/fstab
ls -l /swap.img /swapfile 2>/dev/null
```

**Causes and fixes:**

| Cause | Fix |
|-------|-----|
| Entry still uncommented in `/etc/fstab` | Comment the line, `sudo sed -i '/swap/s/^/#/' /etc/fstab` |
| A systemd `.swap` unit is enabled | `sudo systemctl mask <unit>.swap` |
| `zram-generator` recreating zram swap | Mask `systemd-zram-setup@zram0.service`, remove the defaults package |
| cloud-init recreating `/swap.img` | Add a cloud-init override disabling the `mounts` module |
| Anaconda/kickstart created a swap LV | Comment fstab **and** consider removing the LV |

### `modprobe br_netfilter` fails with "Module not found"

```bash
# Is the module present for the running kernel at all?
find /lib/modules/$(uname -r) -name 'br_netfilter*'
modinfo br_netfilter
```

If the file is missing, the running kernel does not match the installed modules, almost always because the system was updated but not rebooted. Reboot into the new kernel. On minimal cloud images you may need the extra modules package:

```bash
# Ubuntu cloud images
sudo apt-get install -y linux-modules-extra-$(uname -r)
# RHEL family
sudo dnf install -y kernel-modules-$(uname -r)
```

### sysctl says "cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables"

The `br_netfilter` module is not loaded. Load it, then reapply:

```bash
sudo modprobe br_netfilter
sudo sysctl --system
```

If it persists across reboots, `systemd-modules-load.service` is failing:

```bash
systemctl status systemd-modules-load.service
journalctl -u systemd-modules-load.service -b --no-pager
```

### Pods on the same node talk, pods on different nodes cannot

Work down this list in order:

```bash
# 1. Forwarding enabled?
sysctl net.ipv4.ip_forward

# 2. FORWARD chain policy not DROP?
sudo iptables -S FORWARD | head -5
sudo nft list chain inet filter forward 2>/dev/null

# 3. Overlay port reachable between nodes?
#    Calico VXLAN
sudo nc -uvz <other-node-ip> 4789
#    Cilium VXLAN
sudo nc -uvz <other-node-ip> 8472
#    Calico BGP
nc -vz <other-node-ip> 179

# 4. MTU mismatch? Overlays add 50 bytes of header.
ip link show | grep -E 'mtu|vxlan'
ping -M do -s 1472 <other-node-ip>   # 1472 + 28 = 1500, should succeed
ping -M do -s 1422 <other-node-ip>   # 1422 + 28 = 1450, VXLAN safe size
```

### Node registers with the wrong IP address

```bash
kubectl get nodes -o wide            # look at INTERNAL-IP
hostname -I
ip route get 1.1.1.1
grep -n '127.0.1.1' /etc/hosts
```

Fix by pinning the node IP:

```bash
# Debian family
echo 'KUBELET_EXTRA_ARGS="--node-ip=192.168.10.21"' | sudo tee /etc/default/kubelet
# RHEL family
echo 'KUBELET_EXTRA_ARGS="--node-ip=192.168.10.21"' | sudo tee /etc/sysconfig/kubelet

sudo systemctl daemon-reload && sudo systemctl restart kubelet
```

### Two nodes registered under the same name

Symptom: `kubectl get nodes` shows fewer nodes than you joined, and the node that "disappeared" is running pods that never become Ready.

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,UUID:.status.nodeInfo.systemUUID'
# Two entries with the same name is impossible; instead you will see one entry
# whose systemUUID keeps flipping between two values in describe output.
kubectl describe node <name> | grep -i 'System UUID'
```

Fix: `kubeadm reset` on the duplicate, set a unique hostname, rejoin.

### Kubelet fails with "running with swap on is not supported"

```bash
journalctl -u kubelet -n 50 --no-pager | grep -i swap
swapon --show
```

Turn swap off (preferred) or, if you have deliberately opted in, set `failSwapOn: false` in the kubelet configuration and confirm you are on cgroup v2.

### firewalld reload broke the cluster

Symptom: everything was working, someone ran `firewall-cmd --reload`, now Services do not resolve and cross node pod traffic stopped.

```bash
sudo iptables-save | grep -c KUBE-      # if very low or zero, kube-proxy rules were flushed
```

Fix:

```bash
kubectl -n kube-system rollout restart daemonset kube-proxy
kubectl -n kube-system rollout restart daemonset calico-node   # or cilium
```

Prevent recurrence by putting the pod and node CIDRs in the `trusted` zone as the owner's procedure does, so reloads have less to rebuild, and by avoiding reloads on running nodes.

### Clock skew symptoms without an obvious cause

```bash
chronyc tracking | grep -E 'System time|Leap status'
timedatectl status
journalctl -u kubelet -b | grep -iE 'x509|certificate|expired|not yet valid'
```

If a VM was suspended and resumed, the clock can jump wildly. Force a step correction:

```bash
sudo chronyc makestep
sudo systemctl restart kubelet
```

---

## Exam and Interview Traps

1. **"Disable swap" is not one command.** `swapoff -a` is runtime only. Persisting requires fstab edits **and** checking for systemd swap units and zram. Interviewers ask "how do you make it survive a reboot".

2. **`br_netfilter` versus the sysctls.** The module creates the knobs; the sysctls turn them on. Loading the module alone does not enable bridge netfilter, and setting the sysctl before loading the module fails. Order matters, and it matters at boot too.

3. **`net.ipv4.ip_forward` and the ufw FORWARD policy are separate gates.** Both must allow forwarding. Passing one and failing the other produces identical symptoms.

4. **10250 is the kubelet API, not a metrics port.** It grants `exec` and `logs` on every pod on the node. 10255 was the old read only port and should not be open.

5. **The kubelet default port list has 10259 for the scheduler and 10257 for the controller manager.** Candidates routinely swap these two. Mnemonic: scheduler is the higher number.

6. **`product_uuid` cannot be changed from inside the guest.** It comes from DMI/SMBIOS. Only `machine-id` is regenerable from Linux.

7. **Minimum 2 vCPU is a hard preflight failure, 2 GB RAM is a warning.** Know which is which.

8. **NodeSwap requires cgroup v2 and `failSwapOn: false`, and `swapBehavior` has exactly two valid values now: `NoSwap` and `LimitedSwap`.** Naming `UnlimitedSwap` as a current option is a wrong answer.

9. **`sysctl --system` reads several directories with a precedence order.** A value in `/etc/sysctl.d` beats one in `/usr/lib/sysctl.d`. Distributions ship files in the latter that can surprise you.

10. **SELinux permissive, not disabled.** Permissive keeps the policy loaded and file labels intact, so you can return to enforcing without a full filesystem relabel.

11. **Overlay MTU.** VXLAN adds 50 bytes, IP-in-IP adds 20, WireGuard adds 60 or more. A cluster where small packets work and large ones hang is an MTU problem, not a firewall problem.

12. **`hostname -f` failing is a real prerequisite failure.** Node names must be resolvable by every other node; the owner's prerequisites state this explicitly.

13. **Cloned VMs are the number one cause of mysterious node problems.** Check hostname, MAC, `machine-id` and `product_uuid` on any node that behaves strangely and was created from a template.

14. **NodePort range 30000-32767 is the default, not a law.** It is set with `--service-node-port-range` on the API server, and both TCP and UDP need opening.

---

## Related Topics

- [manual-install-k8s-cluster.md](manual-install-k8s-cluster.md) - the runnable step by step procedure with Calico
- [manual-install-k8s-cluster-cilium.md](manual-install-k8s-cluster-cilium.md) - the same procedure with Cilium and kube-proxy replacement
- [k8s-installation-requirements.md](k8s-installation-requirements.md) - requirements summary
- [k8s-installation-considerations.md](k8s-installation-considerations.md) - where and how to install
- [k8s-installation-methods.md](k8s-installation-methods.md) - kubeadm versus other installers
- [installing-containerd.md](installing-containerd.md) - the next layer up
- [installing-k8s-packages.md](installing-k8s-packages.md) - kubeadm, kubelet, kubectl
- [linux-networking.md](linux-networking.md) - routing, bridges, veth, netfilter
- [linux-namespaces.md](linux-namespaces.md) - the isolation primitives containers use
- [cgroups.md](cgroups.md) - resource accounting and the cgroup driver
- [nat.md](nat.md) - SNAT, DNAT, masquerade
- [kube-proxy.md](kube-proxy.md) - iptables and IPVS modes
- [cni.md](cni.md) - the CNI specification and plugin landscape

---

## Key Takeaways

1. `kubeadm` assumes a correctly prepared host; it does not prepare one for you, so every failure at layer 2 surfaces as a confusing failure at layer 5.
2. Hostname, MAC address, `machine-id` and `product_uuid` must be unique on every node; cloned VM templates are the single most common source of collisions.
3. Disable swap in the running system **and** persistently, checking fstab, systemd swap units and zram; verify with `swapon --show` after a reboot.
4. `overlay` gives containerd its efficient snapshotter; `br_netfilter` makes bridged pod traffic visible to iptables so Services and NetworkPolicies work at all.
5. Load kernel modules before applying sysctls, both interactively and at boot; the bridge sysctls do not exist until `br_netfilter` is resident.
6. `net.ipv4.ip_forward=1` turns the node into a router, which is exactly what cross node pod traffic requires; the firewall's FORWARD policy must agree.
7. Clock synchronisation is a hard requirement because every internal connection is mutual TLS and every certificate is time bound.
8. Open 6443, 2379-2380, 10250, 10257, 10259 and 30000-32767 on control planes, 10250, 10256 and 30000-32767 on workers, plus your CNI's ports.
9. On the Red Hat family set SELinux to permissive rather than disabled so you retain file labels and audit visibility.
10. Verify everything with a scripted checklist before installing the runtime; five minutes of verification saves hours of cluster archaeology.

---

## References

- [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Ports and Protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
- [Container Runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [Swap memory management](https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory)
- [Kubelet Configuration (v1beta1)](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- [Nodes](https://kubernetes.io/docs/concepts/architecture/nodes/)
- [About cgroup v2](https://kubernetes.io/docs/concepts/architecture/cgroups/)
- [Validate node setup](https://kubernetes.io/docs/setup/best-practices/node-conformance/)
- [Cluster Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/)
- [kubeadm init reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/)
