# 🧠 kube-scheduler – The Decision-Maker of Kubernetes

---

## 🔹 What is kube-scheduler?

The `kube-scheduler` is a **control plane component** in Kubernetes responsible for **assigning Pods to Nodes**.

It watches for **unscheduled Pods** and selects the most suitable Node to run each Pod based on a **set of rules and constraints**.

---

## 🔹 Key Responsibilities

| Responsibility            | Description |
|---------------------------|-------------|
| Pod Scheduling            | Assigns Pods to suitable Nodes based on policy and resource availability |
| Score & Filter Nodes      | Filters out Nodes that can't run the Pod, then scores remaining ones |
| Scheduling Decisions      | Writes the selected Node name into the Pod spec (`spec.nodeName`) |
| Extensibility             | Supports custom policies via plugins, extenders, and profiles |

---

## 🔹 When Does kube-scheduler Act?

1. A new Pod is created (e.g., via Deployment).
2. The Pod **does not yet have a `spec.nodeName`**.
3. kube-scheduler:
   - **Filters** nodes based on requirements
   - **Scores** nodes for best fit
   - **Assigns** the Pod to the best Node
4. kube-apiserver updates the Pod spec with the Node assignment.
5. The kubelet on the selected Node picks up the Pod and runs it.

---
