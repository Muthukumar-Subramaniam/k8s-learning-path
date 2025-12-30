# Kubernetes API and API Objects

## Overview

The **Kubernetes API** is the foundation of Kubernetes. All operations and communications within the cluster go through the API. Everything in Kubernetes is represented as an API object - from Pods and Services to Deployments and ConfigMaps.

## The Kubernetes API Server

### What is the API Server?

The **kube-apiserver** is the central management component of Kubernetes:

```
┌──────────────────────────────────────────────┐
│           Kubernetes API Server              │
├──────────────────────────────────────────────┤
│                                              │
│  • RESTful HTTP API                          │
│  • Authentication & Authorization            │
│  • Admission Control                         │
│  • Validation                                │
│  • Persistence to etcd                       │
│  • Watches & Events                          │
│                                              │
└──────────────────────────────────────────────┘
           ▲        ▲        ▲        ▲
           │        │        │        │
      ┌────┴──┐ ┌───┴───┐ ┌──┴───┐ ┌──┴────┐
      │kubectl│ │kubelet│ │Ctrl  │ │Custom │
      │       │ │       │ │Mgr   │ │Client │
      └───────┘ └───────┘ └──────┘ └───────┘
```

### API Request Flow

```
1. Client Request
   └─▶ kubectl apply -f pod.yaml

2. Authentication
   └─▶ Verify identity (certs, tokens)

3. Authorization
   └─▶ Check RBAC permissions

4. Admission Control
   └─▶ Mutating & Validating webhooks

5. Validation
   └─▶ Schema validation

6. Persistence
   └─▶ Store in etcd

7. Response
   └─▶ Return to client

8. Watch/Notify
   └─▶ Inform controllers
```

## API Resources and Objects

### What is an API Object?

An **API Object** is a persistent entity in Kubernetes that represents the desired state of your cluster.

**Key Characteristics:**
- **Declarative**: You specify what you want
- **Persistent**: Stored in etcd
- **Versioned**: Multiple API versions (v1, v1beta1, etc.)
- **Typed**: Each object has a specific Kind

### Object Structure

Every Kubernetes object follows this structure:

```yaml
apiVersion: <API_GROUP>/<VERSION>
kind: <OBJECT_TYPE>
metadata:
  name: <NAME>
  namespace: <NAMESPACE>
  labels:
    <KEY>: <VALUE>
  annotations:
    <KEY>: <VALUE>
spec:
  # Desired state
status:
  # Current state (managed by Kubernetes)
```

### Required Fields

```yaml
# Every object must have these fields:

apiVersion: apps/v1          # API version
kind: Deployment             # Type of object
metadata:                    # Identifying information
  name: my-app
  namespace: default
spec:                        # Desired state
  replicas: 3
  # ... more specification
```

## API Groups and Versions

### Core API Group (Legacy Group)

No group name in apiVersion:

```yaml
apiVersion: v1
kind: Pod
---
apiVersion: v1
kind: Service
---
apiVersion: v1
kind: ConfigMap
```

### Named API Groups

Format: `<group>/<version>`

```yaml
# apps group
apiVersion: apps/v1
kind: Deployment
---
# batch group
apiVersion: batch/v1
kind: Job
---
# networking group
apiVersion: networking.k8s.io/v1
kind: Ingress
```

### API Groups Hierarchy

```
Core Group (v1)
├── Pod
├── Service
├── ConfigMap
├── Secret
├── PersistentVolume
└── Namespace

apps/v1
├── Deployment
├── StatefulSet
├── DaemonSet
└── ReplicaSet

batch/v1
├── Job
└── CronJob

networking.k8s.io/v1
├── Ingress
├── NetworkPolicy
└── IngressClass

storage.k8s.io/v1
├── StorageClass
├── VolumeAttachment
└── CSIDriver

rbac.authorization.k8s.io/v1
├── Role
├── ClusterRole
├── RoleBinding
└── ClusterRoleBinding
```

### Viewing API Resources

```bash
# List all API resources
kubectl api-resources

# List API versions
kubectl api-versions

# Explain an object
kubectl explain pod
kubectl explain deployment.spec
```

## Common API Objects Overview

### 1. Workload Resources

**Pod** - Smallest deployable unit:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
spec:
  containers:
  - name: nginx
    image: nginx:1.21
```

**Deployment** - Manages ReplicaSets:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.21
```

**StatefulSet** - For stateful applications:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
spec:
  serviceName: "nginx"
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.21
```

**DaemonSet** - One Pod per node:
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
spec:
  selector:
    matchLabels:
      app: fluentd
  template:
    metadata:
      labels:
        app: fluentd
    spec:
      containers:
      - name: fluentd
        image: fluentd:v1.11
```

**Job** - Run-to-completion:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pi
spec:
  template:
    spec:
      containers:
      - name: pi
        image: perl:5.34
        command: ["perl", "-Mbignum=bpi", "-wle", "print bpi(2000)"]
      restartPolicy: Never
```

**CronJob** - Scheduled jobs:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hello
spec:
  schedule: "*/1 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: hello
            image: busybox:1.35
            command: ["/bin/sh", "-c", "date; echo Hello from Kubernetes"]
          restartPolicy: OnFailure
```

### 2. Service Resources

**Service** - Expose applications:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  selector:
    app: myapp
  ports:
  - port: 80
    targetPort: 8080
  type: LoadBalancer
```

**Ingress** - HTTP/HTTPS routing:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
spec:
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 80
```

### 3. Configuration Resources

**ConfigMap** - Configuration data:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  database_url: "postgres://db:5432/myapp"
  log_level: "info"
```

**Secret** - Sensitive data:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  username: YWRtaW4=
  password: cGFzc3dvcmQxMjM=
```

### 4. Storage Resources

**PersistentVolume** - Storage resource:
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-nfs
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: nfs-server.example.com
    path: "/exports/data"
```

**PersistentVolumeClaim** - Storage request:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nfs
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
```

## Working with the API

### Using kubectl

```bash
# Create resources
kubectl create -f resource.yaml
kubectl apply -f resource.yaml

# Read resources
kubectl get pods
kubectl get deployment my-app -o yaml
kubectl describe pod my-pod

# Update resources
kubectl edit deployment my-app
kubectl patch deployment my-app -p '{"spec":{"replicas":5}}'
kubectl apply -f updated-resource.yaml

# Delete resources
kubectl delete pod my-pod
kubectl delete -f resource.yaml
kubectl delete deployment my-app
```

### Direct API Access

```bash
# Get API server address
kubectl cluster-info

# Access with kubectl proxy
kubectl proxy --port=8080 &

# Make API calls
curl http://localhost:8080/api/v1/namespaces/default/pods
curl http://localhost:8080/apis/apps/v1/namespaces/default/deployments
```

### Using Client Libraries

**Python Example:**
```python
from kubernetes import client, config

# Load config
config.load_kube_config()

# Create API client
v1 = client.CoreV1Api()

# List pods
pods = v1.list_namespaced_pod(namespace="default")
for pod in pods.items:
    print(f"Pod: {pod.metadata.name}")

# Create deployment
apps_v1 = client.AppsV1Api()
deployment = client.V1Deployment(
    metadata=client.V1ObjectMeta(name="nginx"),
    spec=client.V1DeploymentSpec(
        replicas=3,
        selector=client.V1LabelSelector(
            match_labels={"app": "nginx"}
        ),
        template=client.V1PodTemplateSpec(
            metadata=client.V1ObjectMeta(labels={"app": "nginx"}),
            spec=client.V1PodSpec(
                containers=[
                    client.V1Container(
                        name="nginx",
                        image="nginx:1.21"
                    )
                ]
            )
        )
    )
)
apps_v1.create_namespaced_deployment(namespace="default", body=deployment)
```

## Labels and Selectors

### Labels

Labels are key-value pairs attached to objects:

```yaml
metadata:
  labels:
    app: nginx
    tier: frontend
    environment: production
    version: v1.0
```

### Label Selectors

Select objects based on labels:

```bash
# Equality-based
kubectl get pods -l app=nginx
kubectl get pods -l environment=production,tier=frontend

# Set-based
kubectl get pods -l 'environment in (production, staging)'
kubectl get pods -l 'tier notin (frontend)'
```

**In Resource Definitions:**
```yaml
selector:
  matchLabels:
    app: nginx
  matchExpressions:
  - key: tier
    operator: In
    values:
    - frontend
    - backend
```

## Annotations

Annotations attach non-identifying metadata:

```yaml
metadata:
  annotations:
    description: "Production web server"
    managed-by: "ansible"
    deployment-date: "2024-01-15"
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
```

## Namespaces

Namespaces provide scope for names:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: development
---
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: development
spec:
  containers:
  - name: nginx
    image: nginx:1.21
```

```bash
# List namespaces
kubectl get namespaces

# Create namespace
kubectl create namespace staging

# Use namespace
kubectl get pods -n development
kubectl apply -f pod.yaml -n development
```

## Field Selectors

Select objects based on field values:

```bash
# Select by status
kubectl get pods --field-selector status.phase=Running

# Select by metadata
kubectl get pods --field-selector metadata.namespace=default

# Combine multiple selectors
kubectl get pods --field-selector status.phase=Running,metadata.namespace=production
```

## API Conventions

### Naming Conventions

- **Names**: DNS subdomain format (lowercase, hyphens)
- **Labels/Annotations**: prefix/name format
- **UID**: System-generated unique identifier

### Resource Names

```yaml
# Good names
metadata:
  name: my-app-deployment
  name: web-server-01
  name: payment-service-v2

# Bad names (will be rejected)
metadata:
  name: MyApp_Deployment  # uppercase, underscore
  name: web server        # space
```

### Status Subresource

Objects have `spec` (desired) and `status` (current):

```yaml
spec:
  replicas: 3  # Desired state

status:
  replicas: 3  # Current state
  readyReplicas: 2
  availableReplicas: 2
  conditions:
  - type: Available
    status: "True"
```

## Custom Resource Definitions (CRDs)

Extend Kubernetes API with custom objects:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.example.com
spec:
  group: example.com
  names:
    kind: Database
    plural: databases
    singular: database
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              size:
                type: string
              version:
                type: string
```

**Using Custom Resources:**
```yaml
apiVersion: example.com/v1
kind: Database
metadata:
  name: my-database
spec:
  size: "10Gi"
  version: "14.5"
```

## Best Practices

### 1. Use Declarative Configuration

```bash
# Preferred: Declarative
kubectl apply -f deployment.yaml

# Avoid: Imperative (except for testing)
kubectl create deployment nginx --image=nginx
```

### 2. Version Control

```bash
# Keep all YAML files in Git
git add deployments/
git commit -m "Add nginx deployment"
git push
```

### 3. Use Namespaces

```yaml
# Organize resources
apiVersion: v1
kind: Namespace
metadata:
  name: production
---
apiVersion: v1
kind: Namespace
metadata:
  name: staging
```

### 4. Label Everything

```yaml
metadata:
  labels:
    app: myapp
    component: frontend
    environment: production
    version: v1.0
    managed-by: helm
```

### 5. Use Resource Limits

```yaml
spec:
  containers:
  - name: app
    resources:
      requests:
        memory: "64Mi"
        cpu: "250m"
      limits:
        memory: "128Mi"
        cpu: "500m"
```

## References

- [Kubernetes API Concepts](https://kubernetes.io/docs/reference/using-api/)
- [API Reference](https://kubernetes.io/docs/reference/kubernetes-api/)
- [API Conventions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md)

### Related Documentation
- [Understanding Pods](pods.md)
- [Controllers Overview](controllers.md)
- [Services](services.md)
- [Storage](storage.md)
- [kubectl Guide](kubectl.md)

---

**Next Steps**: Explore specific object types: [Pods](pods.md), [Controllers](controllers.md), [Services](services.md), and [Storage](storage.md).
