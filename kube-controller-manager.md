# 🧬 kube-controller-manager (Deep Dive)

---

## 🔹 What is kube-controller-manager?

The `kube-controller-manager` is a **core control plane component** responsible for running **Kubernetes controllers** — background loops that **watch the cluster state and drive it toward the desired state**.

Each controller continuously:
1. **Monitors** cluster state via the API server
2. **Compares** it with the desired state (defined in specs)
3. **Takes action** to reconcile the differences (create, update, delete)

---

## 🔧 Controllers Run by kube-controller-manager

Here are some of the most critical built-in controllers:

| Controller                | Purpose |
|---------------------------|---------|
| **Node Controller**       | Detects and manages node availability and heartbeats |
| **Replication Controller**| Ensures correct number of Pod replicas |
| **Deployment Controller** | Manages rolling updates and scaling |
| **DaemonSet Controller**  | Ensures DaemonSet Pods run on each Node |
| **Job & CronJob Controllers** | Handles batch jobs and scheduled jobs |
| **Service Controller**    | Maintains service endpoints |
| **Namespace Controller**  | Cleans up objects in deleted namespaces |
| **EndpointSlice Controller** | Manages EndpointSlices instead of traditional Endpoints |
| **PersistentVolume & Claim Controllers** | Binds volumes to claims |
| **Garbage Collector**     | Cleans up unneeded resources (like orphaned Pods) |

---
