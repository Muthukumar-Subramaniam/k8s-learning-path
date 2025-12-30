# What Is Kubernetes?

## Overview

**Kubernetes (K8s)** is an open-source container orchestration platform that automates the deployment, scaling, and management of containerized applications. It was originally designed by Google and is now maintained by the Cloud Native Computing Foundation (CNCF).

> **Etymology**: The name "Kubernetes" originates from Greek, meaning "helmsman" or "pilot" — the person who steers a ship. The abbreviation "K8s" represents the 8 letters between 'K' and 's'.

## What Problem Does Kubernetes Solve?

### Before Kubernetes

```
┌──────────────────────────────────────────┐
│    Traditional Deployment Challenges     │
├──────────────────────────────────────────┤
│  ❌ Manual container management          │
│  ❌ No automatic failover                │
│  ❌ Difficult scaling                    │
│  ❌ Complex networking                   │
│  ❌ Manual load balancing                │
│  ❌ No standardized deployment           │
│  ❌ Resource waste                       │
└──────────────────────────────────────────┘
```

### With Kubernetes

```
┌──────────────────────────────────────────┐
│    Kubernetes Solutions                  │
├──────────────────────────────────────────┤
│  ✅ Automated orchestration              │
│  ✅ Self-healing systems                 │
│  ✅ Horizontal & vertical scaling        │
│  ✅ Advanced networking (CNI)            │
│  ✅ Built-in load balancing              │
│  ✅ Declarative configuration            │
│  ✅ Efficient resource utilization       │
└──────────────────────────────────────────┘
```

## Core Concepts

### 1. Declarative Configuration

Instead of telling Kubernetes **how** to do something, you tell it **what** you want:

```yaml
# Declarative: "I want 3 replicas of my app"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.21
        ports:
        - containerPort: 80
```

Kubernetes continuously works to maintain this desired state.

### 2. Control Loop Pattern

```
┌─────────────────────────────────────────────────┐
│           Kubernetes Control Loop               │
│                                                 │
│  ┌──────────┐     ┌──────────┐                │
│  │ Desired  │────▶│ Current  │                │
│  │  State   │     │  State   │                │
│  └──────────┘     └──────────┘                │
│        │               │                       │
│        │     Compare   │                       │
│        └───────┬───────┘                       │
│                ▼                               │
│         ┌─────────────┐                        │
│         │  Different? │                        │
│         └──────┬──────┘                        │
│                │ YES                           │
│                ▼                               │
│         ┌─────────────┐                        │
│         │   Take      │                        │
│         │   Action    │                        │
│         └─────────────┘                        │
│                                                 │
│  Continuously reconcile actual state with      │
│  desired state                                  │
└─────────────────────────────────────────────────┘
```

### 3. Pods: The Smallest Unit

A **Pod** is the smallest deployable unit in Kubernetes:
- One or more containers that share storage and network
- Co-located and co-scheduled
- Share the same IP address

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: myapp:1.0
  - name: sidecar
    image: logger:1.0
```

## Kubernetes Architecture

### High-Level View

```
┌─────────────────────────────────────────────────────────┐
│                 Kubernetes Cluster                      │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────────────────────────────────────────┐     │
│  │          Control Plane (Master)              │     │
│  │  ┌──────────────────────────────────────┐   │     │
│  │  │  • kube-apiserver (API Gateway)      │   │     │
│  │  │  • etcd (Key-Value Store)            │   │     │
│  │  │  • kube-scheduler (Pod Placement)    │   │     │
│  │  │  • kube-controller-manager           │   │     │
│  │  │  • cloud-controller-manager          │   │     │
│  │  └──────────────────────────────────────┘   │     │
│  └──────────────────────────────────────────────┘     │
│                       ▼                                │
│  ┌──────────────────────────────────────────────┐     │
│  │              Worker Nodes                    │     │
│  │  ┌────────────┐  ┌────────────┐            │     │
│  │  │  Node 1    │  │  Node 2    │  ...       │     │
│  │  │            │  │            │            │     │
│  │  │ • kubelet  │  │ • kubelet  │            │     │
│  │  │ • kube-    │  │ • kube-    │            │     │
│  │  │   proxy    │  │   proxy    │            │     │
│  │  │ • Runtime  │  │ • Runtime  │            │     │
│  │  │            │  │            │            │     │
│  │  │ ┌────────┐ │  │ ┌────────┐ │            │     │
│  │  │ │  Pods  │ │  │ │  Pods  │ │            │     │
│  │  │ └────────┘ │  │ └────────┘ │            │     │
│  │  └────────────┘  └────────────┘            │     │
│  └──────────────────────────────────────────────┘     │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Control Plane Components

#### 1. **kube-apiserver**
- Central management entity
- RESTful API for all operations
- Validates and processes API requests
- Updates etcd

#### 2. **etcd**
- Distributed key-value store
- Stores all cluster data
- Source of truth for cluster state

#### 3. **kube-scheduler**
- Assigns Pods to Nodes
- Considers resource requirements
- Respects constraints and policies

#### 4. **kube-controller-manager**
- Runs controller processes
- Node controller, Replication controller, Endpoints controller, etc.
- Ensures desired state

### Worker Node Components

#### 1. **kubelet**
- Agent on each node
- Ensures containers are running in Pods
- Reports node and Pod status

#### 2. **kube-proxy**
- Network proxy
- Maintains network rules
- Enables Service abstraction

#### 3. **Container Runtime**
- Runs containers (containerd, CRI-O, Docker)
- Implements Container Runtime Interface (CRI)

## Key Features

### 1. Automatic Scheduling
```
┌──────────────────────────────────────┐
│  Scheduler Decision Factors:         │
│  • Resource requirements (CPU/RAM)   │
│  • Quality of Service (QoS)          │
│  • Affinity/Anti-affinity            │
│  • Data locality                     │
│  • Taints and tolerations            │
└──────────────────────────────────────┘
```

### 2. Self-Healing

Kubernetes automatically:
- Restarts failed containers
- Replaces and reschedules containers when nodes die
- Kills containers that don't respond to health checks
- Doesn't advertise them to clients until ready

```yaml
# Liveness probe example
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 3
  periodSeconds: 3
```

### 3. Horizontal Scaling

```bash
# Manual scaling
kubectl scale deployment web-app --replicas=10

# Auto-scaling
kubectl autoscale deployment web-app --min=3 --max=10 --cpu-percent=80
```

```yaml
# Horizontal Pod Autoscaler
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
```

### 4. Service Discovery and Load Balancing

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 8080
  type: LoadBalancer
```

Kubernetes provides:
- DNS names for Services
- Internal load balancing
- External load balancing (cloud providers)

### 5. Automated Rollouts and Rollbacks

```bash
# Update deployment
kubectl set image deployment/web-app nginx=nginx:1.22

# Check rollout status
kubectl rollout status deployment/web-app

# Rollback if needed
kubectl rollout undo deployment/web-app
```

### 6. Secret and Configuration Management

```yaml
# ConfigMap for configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  database_url: "postgres://db:5432/myapp"
  log_level: "info"

---
# Secret for sensitive data
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
type: Opaque
data:
  password: cGFzc3dvcmQxMjM=  # base64 encoded
```

### 7. Storage Orchestration

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: fast-ssd
```

## Where Is Kubernetes?

### Official Repository
- **GitHub**: https://github.com/kubernetes/kubernetes
- **Website**: https://kubernetes.io/
- **Documentation**: https://kubernetes.io/docs/

### Ecosystem
```
┌─────────────────────────────────────────────┐
│        Kubernetes Ecosystem                 │
├─────────────────────────────────────────────┤
│  Core: kubernetes/kubernetes               │
│  Registry: Container Registries             │
│  Networking: CNI Plugins (Calico, Cilium)  │
│  Storage: CSI Drivers                       │
│  Monitoring: Prometheus, Grafana           │
│  Logging: ELK, Fluentd                     │
│  Security: OPA, Falco                      │
│  Service Mesh: Istio, Linkerd             │
│  CI/CD: Argo, Flux, Tekton                │
└─────────────────────────────────────────────┘
```

## Kubernetes Distributions

### Managed Services
- **Google Kubernetes Engine (GKE)**
- **Amazon Elastic Kubernetes Service (EKS)**
- **Azure Kubernetes Service (AKS)**
- **DigitalOcean Kubernetes**
- **Red Hat OpenShift**

### Self-Managed
- **kubeadm** (official tool)
- **kops** (Kubernetes Operations)
- **Kubespray** (Ansible-based)
- **Rancher** (Management platform)

### Local Development
- **Minikube** (single-node cluster)
- **kind** (Kubernetes in Docker)
- **k3s** (lightweight K8s)
- **Docker Desktop** (built-in K8s)

## Why Is It Called K8s?

**Numeronym**: K8s is a numeronym where:
- **K** = First letter
- **8** = Eight letters between K and s (ubernete)
- **s** = Last letter

Similar pattern to:
- **i18n** = internationalization (18 letters between i and n)
- **a11y** = accessibility (11 letters between a and y)

This shorthand became popular due to:
1. Easier typing and communication
2. Twitter character limits (historical reason)
3. Common practice in the tech community

## K8s Benefits and Operating Principles

### Benefits

#### 1. **Portability**
- Run anywhere: on-premises, cloud, hybrid
- Avoid vendor lock-in
- Consistent behavior across environments

#### 2. **Scalability**
- Horizontal scaling (add more Pods)
- Vertical scaling (increase resources)
- Cluster scaling (add more Nodes)

#### 3. **Extensibility**
- Custom Resource Definitions (CRDs)
- Operators for complex applications
- Plugin architecture

#### 4. **High Availability**
- Multi-master setup
- Distributed architecture
- Self-healing capabilities

#### 5. **Resource Efficiency**
- Bin packing for optimal resource use
- Resource quotas and limits
- Multi-tenancy support

### Operating Principles

#### 1. **Declarative Configuration**
State what you want, not how to achieve it:
```yaml
# Desired state
spec:
  replicas: 3
# Kubernetes ensures 3 replicas are always running
```

#### 2. **Controller Pattern**
Controllers watch for changes and reconcile state:
```
while true:
    desired = get_desired_state()
    current = get_current_state()
    if desired != current:
        reconcile(desired, current)
```

#### 3. **API-Driven**
Everything is an API object:
```bash
kubectl get pods        # List API objects
kubectl apply -f app.yaml  # Create/Update objects
kubectl delete pod my-pod  # Delete objects
```

#### 4. **Immutable Infrastructure**
- Containers are immutable
- Updates create new Pods
- No in-place modifications

#### 5. **Label-Based Selection**
```yaml
# Labels
metadata:
  labels:
    app: web
    tier: frontend
    version: v1

# Selectors
selector:
  matchLabels:
    app: web
```

## Real-World Use Cases

### 1. Microservices Architecture
Deploy and manage hundreds of microservices efficiently

### 2. CI/CD Pipelines
Automated testing and deployment workflows

### 3. Machine Learning
Distribute training jobs across GPU clusters

### 4. Hybrid Cloud
Run workloads across multiple cloud providers

### 5. Edge Computing
Manage applications at edge locations

## Kubernetes vs Other Solutions

| Feature | Kubernetes | Docker Swarm | Nomad |
|---------|-----------|--------------|-------|
| Complexity | High | Low | Medium |
| Features | Comprehensive | Basic | Flexible |
| Community | Largest | Moderate | Growing |
| Learning Curve | Steep | Gentle | Moderate |
| Ecosystem | Extensive | Limited | Moderate |
| Use Case | Any scale | Small-medium | Multi-workload |

## Getting Started

### Prerequisites
- Understanding of containers
- Basic Linux knowledge
- Networking fundamentals

### Learning Path
1. [Understand Containers](containers.md)
2. [Learn Docker](docker-and-orchestration.md)
3. [Study K8s Architecture](k8s-architecture.md)
4. [Set up a cluster](manual-install-k8s-cluster.md)
5. [Deploy applications](deployments.md)

## References

- [Kubernetes Official Website](https://kubernetes.io/)
- [Kubernetes GitHub](https://github.com/kubernetes/kubernetes)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [CNCF (Cloud Native Computing Foundation)](https://www.cncf.io/)
- [Kubernetes API Reference](https://kubernetes.io/docs/reference/kubernetes-api/)

### Related Documentation
- [Kubernetes Architecture Overview](k8s-architecture.md)
- [Control Plane Components](control-plane-node.md)
- [Worker Node Components](worker-node.md)
- [Container Runtimes](container-runtime.md)
- [Networking Fundamentals](k8s-networking-fundamentals.md)

---

**Next Steps**: Dive deeper into [Kubernetes architecture](k8s-architecture.md) and explore [control plane components](control-plane-node.md).
