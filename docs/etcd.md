# 🗃️ etcd – The Backend Database of Kubernetes

---

## 🔹 What is etcd?

**etcd** stands for "**/etc distributed**", inspired by the Unix `/etc` directory for configurations — `etcd` is a distributed key-value store used as the **backing store** for all Kubernetes cluster data.

It is the **source of truth** for the entire Kubernetes control plane. Every object you create, modify, or delete in Kubernetes — such as Pods, ConfigMaps, Services, etc. — is stored in `etcd`.

---

## 🔹 Core Characteristics

| Feature               | Description |
|------------------------|-------------|
| Distributed            | Can run as a cluster of nodes |
| Consistent             | Uses the Raft consensus algorithm |
| Highly Available       | Supports HA setups with odd-numbered members |
| Strongly Consistent    | Ensures linearizable reads and writes |
| Secure (TLS-enabled)   | Communicates over encrypted channels |

---

## 🔹 Responsibilities of etcd in Kubernetes

1. **Persistent Storage**  
   - Stores the **entire cluster state** — including all objects and their current status.

2. **High Availability and Fault Tolerance**  
   - Can tolerate failure of minority members in an HA setup.

3. **Data Consistency**  
   - Guarantees strong consistency using the **Raft** consensus algorithm.

4. **Watch and Notification System**  
   - Allows components (like kube-apiserver) to **watch keys** and be notified when data changes.

5. **Key-Value Store Only**  
   - Doesn't understand Kubernetes natively; it's just a secure and reliable data store.

---

## 🔹 How it Works with Kubernetes

- `kube-apiserver` is the **only component** that directly interacts with `etcd`.
- Controllers, schedulers, and other components **watch the API server** — not etcd.
