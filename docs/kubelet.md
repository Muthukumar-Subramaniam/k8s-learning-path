# ⚙️ kubelet – The Node Agent in Kubernetes

---

## 🔹 What is kubelet?

The **kubelet** is the **primary "node agent"** that runs on every Kubernetes worker node (and optionally control plane nodes).

Its job is to:
- Ensure the **containers** described by the control plane **are running and healthy**
- Interact with the **container runtime** (like containerd)
- Sync the **actual state** of the node with the **desired state** defined in the API server

---

## 🔹 Key Responsibilities of kubelet

| Function                  | Description |
|---------------------------|-------------|
| ✅ **Pod Management**      | Ensures that containers in assigned Pods are running properly |
| 🔁 **Sync Loop**           | Constantly polls the API server for new Pod specs and updates |
| 💬 **API Communication**   | Talks to the kube-apiserver to get Pod definitions |
| 📦 **Container Runtime**   | Uses CRI (Container Runtime Interface) to start/stop containers |
| 📍 **Node Status Update**  | Regularly posts node health and resource usage to kube-apiserver |
| 🔬 **Probes Execution**    | Runs liveness and readiness probes to monitor container health |
| 🔐 **Certificate Rotation**| Manages TLS credentials for secure communication (optional) |

---

## 🔹 kubelet Does **NOT**:

- Schedule Pods — that's done by `kube-scheduler`
- Directly talk to etcd — only the API server does that
- Handle networking — that’s the job of `kube-proxy` and CNI plugins

---

## 🔹 Deployment

- Installed on **every node** in the cluster
- Runs as a **systemd service** or a **static Pod**
- Default secure port: `10250`

---

## ✅ Summary

| Attribute        | Value |
|------------------|-------|
| Role             | Node agent to manage Pod lifecycle |
| Communicates With| kube-apiserver & container runtime |
| Runs On          | All worker nodes (and optionally control plane nodes) |
| Core Function    | Ensures actual node state matches desired Pod spec |
| Security         | Uses TLS, certs, service accounts |
| HA               | No leader election — every node runs its own kubelet independently |

---

> The `kubelet` is the **field-agent and babysitter** of each node — constantly watching, verifying, and reacting to ensure containers are alive and compliant with what the control plane asked for.
