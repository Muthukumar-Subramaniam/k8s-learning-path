# ⚙️ Kubernetes Installation Requirements

Essential prerequisites for installing Kubernetes using `kubeadm` or other self-managed methods.

---

## 🖥️ Operating System

Kubernetes control plane components are supported **only on Linux**.

### ✅ Supported Linux Families:
- **Red Hat-based**  
  _(e.g., RHEL, CentOS, AlmaLinux, Rocky Linux, **Oracle Linux**)_
- **Debian-based**  
  _(e.g., Ubuntu, Debian)_
- **SUSE-based**  
  _(e.g., openSUSE, SLES)_

> 🪟 **Windows nodes** can be added as **worker nodes only** in hybrid clusters, but are **rare and used for specific workloads**.

---

## 🧠 Minimum System Specifications

| Component | Requirement |
|----------|-------------|
| CPU      | 2 cores
| RAM      | 2 GB
| Disk     | 20 GB
| Network  | Stable connectivity between all nodes |

---

## 🚫 Swap Must Be Disabled

Kubernetes requires swap to be turned off.

---

## 🧱 Container Runtime Interface (CRI)

Kubernetes uses the **Container Runtime Interface (CRI)** to interact with container runtimes.  
You must install and configure a CRI-compatible runtime **before** initializing the cluster.

### ✅ Supported CRI Runtimes:

| Runtime    | Notes |
|------------|-------|
| **containerd** | ✅ Default and recommended since Kubernetes 1.24+ |
| **CRI-O**      | Lightweight, OpenShift-compatible alternative |
| **Docker (via cri-dockerd)** | Deprecated since v1.24; supported only through `cri-dockerd` shim |

> 🔥 As of Kubernetes **v1.24**, **Docker is no longer supported natively** — use `containerd` or `CRI-O` for production clusters.

---

## 🧬 Node Identity & System Uniqueness

Each Kubernetes node must have a **unique identity** to prevent conflicts during registration and scheduling.

### ✅ Required Unique Identifiers per Node:

| Component     | Purpose |
|---------------|---------|
| **Hostname**  | Used internally by kubelet and DNS |
| **MAC Address** | Important for network identification (CNI, DHCP) |
| **Machine ID** (`/etc/machine-id`) | Used by systemd and kubelet |
| **Product UUID** (`/sys/class/dmi/id/product_uuid`) | Used by kubelet to identify the node |

> ⚠️ **In case of VM cloning**, ensure the above identifiers are unique on each node before joining the cluster.

---
