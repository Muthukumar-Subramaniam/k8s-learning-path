# 🧱 Kubernetes Worker Nodes – Overview

---

## 🔹 What is a Worker Node?

A **worker node** in Kubernetes is a machine (virtual or physical) where **application workloads (Pods)** actually run.

It contains all the necessary components to **run, manage, and communicate** the containers scheduled to it by the control plane.

---

## 🔹 Core Components of a Worker Node

| Component     | Description |
|----------------|-------------|
| **kubelet**     | Agent that runs on each node; communicates with kube-apiserver and ensures containers are running as expected |
| **kube-proxy**  | Maintains network rules on the node; enables service discovery and routing to the correct Pod IPs |
| **Container Runtime** | The software that actually runs containers (e.g., containerd, CRI-O, Docker) |

---

> ✅ Worker nodes are where **your applications live** — each node follows orders from the control plane to run and manage Pods.
