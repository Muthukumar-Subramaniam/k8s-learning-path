# 🧠 Kubernetes Control Plane Node - Core Architecture

---

## 🔹 What is a Control Plane Node?

The **Control Plane Node** in a Kubernetes cluster is the **brain** of the system. It makes global decisions about the cluster (e.g., scheduling), detects and responds to cluster events, and exposes the Kubernetes API.

> It orchestrates how, when, and where containers (Pods) run across the cluster.

---

## 🔹 Core Responsibilities

1. **Cluster-Wide Decision Making**
   - Schedules workloads (Pods) to appropriate worker nodes.
   - Maintains overall cluster state.

2. **Cluster State Management**
   - Maintains desired state vs actual state reconciliation.
   - Stores all cluster data (etcd).

3. **Lifecycle & Health Control**
   - Ensures correct number of Pods are running.
   - Handles node failures and automatic restarts/rescheduling.

4. **API Server Exposure**
   - Acts as the frontend for users, automation, and controllers.

---

## 🔹 Core Components of Control Plane Node

| Component            | Role                                                                 |
|----------------------|----------------------------------------------------------------------|
| **kube-apiserver**   | Exposes Kubernetes API. All internal/external communication happens through it. |
| **etcd**             | Consistent and highly-available **key-value store** for all cluster data. |
| **kube-scheduler**   | Assigns Pods to Nodes based on resource availability, constraints, and policies. |
| **kube-controller-manager** | Runs multiple logical controllers to ensure cluster reaches desired state. |

---

## 🔹 Component Breakdown

### 📡 1. kube-apiserver
- Gateway for **all commands and queries** to the cluster.
- Receives REST requests (kubectl, clients, controllers).
- Validates, authenticates, authorizes, and processes data.
- Writes accepted objects to **etcd**.

### 🧠 2. etcd
- Stores:
  - All object definitions (Pods, Deployments, Services, etc.).
  - Cluster configuration and state.
- Strongly consistent and distributed.
- Can be backed up for disaster recovery.

### 📅 3. kube-scheduler
- Watches for newly created Pods with **no node assigned**.
- Selects the most appropriate Node for them.
- Considers:
  - Resource requirements (CPU, Memory)
  - Affinity/anti-affinity
  - Taints and tolerations
  - Node selector and constraints

### 🎮 4. kube-controller-manager
- Manages:
  - Node Controller: Monitors node health and status.
  - Replication Controller: Ensures correct Pod replicas.
  - Endpoints Controller: Maintains endpoint objects.
  - Namespace and Service Account controllers.
- Runs as a **single binary** with multiple controller loops inside.

---

## 🔹 Control Plane Node Characteristics

| Characteristic            | Description |
|---------------------------|-------------|
| **Cluster Brain**         | Orchestrates the cluster’s entire operation. |
| **Stateless Workload-Free** | Does not run application Pods (unless in single-node clusters). |
| **Highly Available**      | Production clusters often use multiple control plane nodes (HA). |
| **Secure Gateway**        | All kube components talk through the kube-apiserver. |
| **Backed by etcd**        | etcd is the **source of truth** for cluster state. |

---

## 🔹 Control Plane Deployment Options

1. **Single Control Plane (non-HA)**  
   - Simple and suitable for dev/test clusters.

2. **High Availability (HA) Control Plane**
   - Multiple control plane nodes (odd number recommended).
   - Load balancer fronting all kube-apiservers.

---
