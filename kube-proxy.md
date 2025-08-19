# 🌐 kube-proxy – The Traffic Director of Kubernetes Nodes

---

## 🔹 What is kube-proxy?

The **kube-proxy** is the **networking component** that runs on every node in a Kubernetes cluster. It manages the rules that allow **network traffic** to **reach Pods and Services**.

It acts like a **field-level traffic cop**, controlling access at the node level using **iptables**, **IPVS**, or **eBPF** (depending on config and OS).

---

## 🔹 Key Responsibilities

| Function                     | Description |
|------------------------------|-------------|
| 🧭 **Service Routing**        | Routes traffic destined for Services to the correct backend Pods |
| ⚙️ **Maintains NAT Rules**    | Configures iptables/ipvs/netfilter rules dynamically |
| 🔁 **Watches Services & Endpoints** | Watches the API server for changes to Services and Endpoints |
| 🚦 **Load Balancing**        | Distributes incoming traffic across Pods behind a Service |
| ⛑️ **NodePort Management**   | Listens on node ports and proxies traffic to target Pods |

---

## 🔌 How kube-proxy Works

1. Watches the **API server** for Services and Endpoints.
2. Generates or updates routing rules (iptables, IPVS, eBPF).
3. Routes traffic **from clients → Services → actual Pods**.

---

## 🔧 Proxy Modes

| Mode       | Description |
|------------|-------------|
| `iptables` | Default on most setups. Adds rules to Linux firewall for routing. |
| `ipvs`     | Kernel-based load balancing. Scales better than iptables. |
| `userspace`| Legacy mode. Slower. Only used in rare scenarios now. |
| `eBPF`     | Modern mode used by advanced CNIs (like Cilium). Extremely fast and programmable. |

---
