# 📡 kube-apiserver – The Heart of the Kubernetes Control Plane

---

## 🔹 What is kube-apiserver?

The `kube-apiserver` is the **core component of the Kubernetes control plane** that exposes the **Kubernetes API**.   
It acts as the **central communication hub** for all cluster operations.  

- It is the **entry point** for all external and internal requests to the cluster.
- Every command or control signal goes through the API server.
- It is a **RESTful service** that speaks HTTP(S) and serves JSON or YAML.

---

## 🔹 Core Characteristics

| Property             | Description |
|----------------------|-------------|
| Stateless            | Can run multiple replicas for high availability |
| RESTful              | Follows REST API design principles |
| HTTPS-secured        | Serves over encrypted TLS |
| Extensible           | Supports custom APIs and dynamic admission |

---

## 🔹 Responsibilities of kube-apiserver

1. **API Gateway**  
   - Serves all Kubernetes APIs (e.g., Pods, Deployments, Services).
   - Routes requests to the appropriate control plane component.

2. **Authentication**  
   - Validates the identity of the request sender.
   - Supports tokens, client certs, OIDC, etc.

3. **Authorization**  
   - Checks if the authenticated user is permitted to perform the requested action.
   - Supports RBAC, ABAC, Webhooks.

4. **Admission Control**  
   - Pluggable chain of checks and policies run after authorization.
   - Can mutate, reject, or validate incoming requests.

5. **Object Validation**  
   - Ensures all API requests are schema-compliant before persisting.

6. **Persistence to etcd**  
   - Writes valid and accepted Kubernetes objects into the etcd datastore.
   - Reads cluster state from etcd to serve requests.

7. **Cluster Coordination**  
   - Notifies controllers, schedulers, and other components when resources are created or updated.

---
