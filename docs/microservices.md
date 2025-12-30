# Microservices Architecture

## What Are Microservices?

**Microservices** is an architectural style that structures an application as a collection of small, autonomous services, each running in its own process and communicating through well-defined APIs. Each microservice is focused on a specific business capability and can be developed, deployed, and scaled independently.

## Monolithic vs Microservices

### Monolithic Architecture

```
┌──────────────────────────────────────┐
│      Monolithic Application          │
│                                      │
│  ┌────────────────────────────────┐ │
│  │                                │ │
│  │    User Interface Layer        │ │
│  │                                │ │
│  ├────────────────────────────────┤ │
│  │                                │ │
│  │    Business Logic Layer        │ │
│  │  • Auth  • Orders  • Payment   │ │
│  │  • Inventory  • Shipping       │ │
│  │                                │ │
│  ├────────────────────────────────┤ │
│  │                                │ │
│  │    Data Access Layer           │ │
│  │                                │ │
│  └────────────────────────────────┘ │
│              ▼                       │
│  ┌────────────────────────────────┐ │
│  │     Single Database            │ │
│  └────────────────────────────────┘ │
└──────────────────────────────────────┘
     Single Deployment Unit
```

### Microservices Architecture

```
┌─────────────────────────────────────────────────────────┐
│               Microservices Application                 │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────┐ │
│  │   Auth   │  │  Orders  │  │ Payment  │  │Shipping│ │
│  │ Service  │  │ Service  │  │ Service  │  │Service │ │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───┬────┘ │
│       │             │              │             │      │
│       ▼             ▼              ▼             ▼      │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  │
│  │Auth DB  │  │Order DB │  │ Pay DB  │  │Ship DB  │  │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘  │
│                                                         │
│  Each service: Independent, Deployable, Scalable       │
└─────────────────────────────────────────────────────────┘
```

## Comparison: Monolith vs Microservices

| Aspect | Monolithic | Microservices |
|--------|-----------|---------------|
| **Deployment** | Single unit | Independent services |
| **Scalability** | Scale entire app | Scale specific services |
| **Technology** | Single stack | Polyglot (multiple languages) |
| **Development** | Single team | Multiple teams |
| **Failure** | Entire app down | Isolated failures |
| **Updates** | Redeploy all | Update individual services |
| **Complexity** | Lower initially | Higher overall |
| **Data** | Shared database | Database per service |
| **Testing** | Simpler initially | Requires integration testing |
| **Performance** | In-process calls | Network calls (overhead) |

## Core Principles of Microservices

### 1. Single Responsibility
Each service focuses on one business capability:
```
✅ Good:
- Order Service: Handles order processing only
- Payment Service: Handles payments only
- Inventory Service: Manages inventory only

❌ Bad:
- Monolithic Service: Handles orders, payments, inventory, shipping
```

### 2. Loose Coupling
Services are independent and communicate via APIs:
```
Service A ←→ API ←→ Service B
    ↓                   ↓
   DB A               DB B
```

### 3. High Cohesion
Related functionality grouped together within a service.

### 4. Autonomy
Each service can be:
- Developed independently
- Deployed independently
- Scaled independently
- Failed independently

### 5. Decentralized Data Management
Each service owns its database:
```yaml
# Order Service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  template:
    spec:
      containers:
      - name: order-api
        image: order-service:v1
        env:
        - name: DATABASE_URL
          value: "postgres://order-db:5432/orders"

---
# Payment Service (separate DB)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
spec:
  template:
    spec:
      containers:
      - name: payment-api
        image: payment-service:v1
        env:
        - name: DATABASE_URL
          value: "postgres://payment-db:5432/payments"
```

## Microservices Communication Patterns

### 1. Synchronous Communication (HTTP/gRPC)

```
┌─────────────┐                ┌─────────────┐
│   Order     │─────REST────▶  │  Payment    │
│   Service   │                │  Service    │
│             │◀────Response───│             │
└─────────────┘                └─────────────┘
```

**Example: REST API**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-service
spec:
  selector:
    app: payment
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
```

```bash
# Order service calls payment service
curl http://payment-service/api/process-payment \
  -d '{"amount": 100, "currency": "USD"}'
```

### 2. Asynchronous Communication (Message Queue)

```
┌─────────────┐     ┌──────────┐     ┌─────────────┐
│   Order     │────▶│  Message │────▶│  Inventory  │
│   Service   │     │  Queue   │     │  Service    │
└─────────────┘     └──────────┘     └─────────────┘
```

**Example: RabbitMQ/Kafka**
```yaml
# Order service publishes event
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  template:
    spec:
      containers:
      - name: order-api
        image: order-service:v1
        env:
        - name: RABBITMQ_URL
          value: "amqp://rabbitmq:5672"
```

### 3. Service Mesh (Advanced)

```
┌─────────────────────────────────────┐
│          Service Mesh               │
│  (Istio, Linkerd)                   │
│                                     │
│  • Traffic Management               │
│  • Security (mTLS)                  │
│  • Observability                    │
│  • Load Balancing                   │
└─────────────────────────────────────┘
```

## Microservices Design Patterns

### 1. API Gateway Pattern

```
                    ┌─────────────┐
    Clients ───────▶│ API Gateway │
                    └──────┬──────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
    ┌──────────┐    ┌──────────┐    ┌──────────┐
    │ Service  │    │ Service  │    │ Service  │
    │    A     │    │    B     │    │    C     │
    └──────────┘    └──────────┘    └──────────┘
```

**Benefits:**
- Single entry point
- Authentication/Authorization
- Rate limiting
- Request routing

**Kubernetes Example:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-gateway
spec:
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /orders
        pathType: Prefix
        backend:
          service:
            name: order-service
            port:
              number: 80
      - path: /payments
        pathType: Prefix
        backend:
          service:
            name: payment-service
            port:
              number: 80
```

### 2. Database per Service

```
┌───────────────┐         ┌───────────────┐
│  Order        │         │  Payment      │
│  Service      │         │  Service      │
└───────┬───────┘         └───────┬───────┘
        │                         │
        ▼                         ▼
┌───────────────┐         ┌───────────────┐
│  Order        │         │  Payment      │
│  Database     │         │  Database     │
└───────────────┘         └───────────────┘
```

**Benefits:**
- Data isolation
- Independent scaling
- Technology choice per service

### 3. Circuit Breaker Pattern

```
Service A ──┐
            ├──▶ Circuit Breaker ──▶ Service B
Service C ──┘
            
States:
• Closed: Normal operation
• Open: Service B is down, fail fast
• Half-Open: Testing if Service B recovered
```

**Example: Using Istio**
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: payment-circuit-breaker
spec:
  host: payment-service
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s
```

### 4. Service Discovery

```
┌─────────────────────────────────┐
│     Service Registry            │
│  (Kubernetes DNS, Consul)       │
└──────────────┬──────────────────┘
               │
    ┌──────────┼──────────┐
    ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐
│Service │ │Service │ │Service │
│   A    │ │   B    │ │   C    │
└────────┘ └────────┘ └────────┘
```

**Kubernetes Built-in Service Discovery:**
```bash
# Services are discoverable via DNS
curl http://payment-service.default.svc.cluster.local
```

### 5. Saga Pattern (Distributed Transactions)

```
Order ─▶ Payment ─▶ Inventory ─▶ Shipping
  │         │           │            │
  │ Success │   Success │    Success │
  └─────────┴───────────┴────────────┘

If any fails:
Order ◀─ Compensate ◀─ Compensate ◀─ Failed
```

## Deploying Microservices on Kubernetes

### Complete Example: E-Commerce Application

```yaml
# Order Service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  labels:
    app: order
    tier: backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: order
  template:
    metadata:
      labels:
        app: order
    spec:
      containers:
      - name: order-api
        image: ecommerce/order-service:v1
        ports:
        - containerPort: 8080
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: order-db-secret
              key: url
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: order-service
spec:
  selector:
    app: order
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP

---
# Payment Service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  labels:
    app: payment
    tier: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment
  template:
    metadata:
      labels:
        app: payment
    spec:
      containers:
      - name: payment-api
        image: ecommerce/payment-service:v1
        ports:
        - containerPort: 8080
        env:
        - name: PAYMENT_GATEWAY_KEY
          valueFrom:
            secretKeyRef:
              name: payment-secret
              key: gateway-key
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service
spec:
  selector:
    app: payment
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
```

## Benefits of Microservices in Kubernetes

### 1. Independent Scaling
```bash
# Scale only the order service
kubectl scale deployment order-service --replicas=10

# Payment service remains at 2 replicas
kubectl scale deployment payment-service --replicas=2
```

### 2. Independent Deployment
```bash
# Update order service
kubectl set image deployment/order-service \
  order-api=ecommerce/order-service:v2

# Other services unaffected
```

### 3. Technology Diversity
```yaml
# Order Service: Node.js
containers:
- name: order-api
  image: node:16-alpine

# Payment Service: Go
containers:
- name: payment-api
  image: golang:1.19-alpine

# Inventory Service: Python
containers:
- name: inventory-api
  image: python:3.10-slim
```

### 4. Fault Isolation
```
If Payment Service crashes:
✅ Order Service: Still running
✅ Inventory Service: Still running
❌ Payment Service: Kubernetes auto-restarts
```

### 5. Resilience
```yaml
# Liveness and readiness probes
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
```

## Challenges of Microservices

### 1. Increased Complexity
- More services to manage
- Complex inter-service communication
- Distributed system challenges

### 2. Data Consistency
- No ACID transactions across services
- Eventual consistency
- Need for Saga pattern

### 3. Network Latency
- Service-to-service calls over network
- Cascading failures
- Need for timeouts and retries

### 4. Testing Complexity
- Integration testing across services
- End-to-end testing
- Contract testing

### 5. Operational Overhead
- More deployments
- Monitoring and logging complexity
- Service mesh configuration

## Best Practices

### 1. Design for Failure
```yaml
# Health checks
livenessProbe:
  httpGet:
    path: /health
    
# Timeouts
readinessProbe:
  timeoutSeconds: 5

# Retry logic in application code
```

### 2. Implement Proper Monitoring
```yaml
# Prometheus monitoring
apiVersion: v1
kind: Service
metadata:
  name: order-service
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
```

### 3. Use Service Mesh for Advanced Features
```bash
# Install Istio
istioctl install

# Enable automatic sidecar injection
kubectl label namespace default istio-injection=enabled
```

### 4. Implement API Gateway
```yaml
# Use Ingress or API Gateway
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-gateway
  annotations:
    nginx.ingress.kubernetes.io/rate-limit: "100"
```

### 5. Use ConfigMaps and Secrets
```yaml
# Configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: "info"
  
# Secrets
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
data:
  username: YWRtaW4=
  password: cGFzc3dvcmQxMjM=
```

## When to Use Microservices

### ✅ Use Microservices When:
- Large, complex applications
- Multiple teams working independently
- Need for different scaling requirements
- Long-term project with evolving requirements
- Different technology stacks needed

### ❌ Avoid Microservices When:
- Small, simple applications
- Small team (< 5 people)
- Tight deadlines
- Limited operational expertise
- No clear service boundaries

## Microservices on Kubernetes: Perfect Match

```
┌────────────────────────────────────────┐
│   Why Kubernetes for Microservices?   │
├────────────────────────────────────────┤
│  ✅ Service discovery (DNS)            │
│  ✅ Load balancing (Services)          │
│  ✅ Self-healing (Controllers)         │
│  ✅ Scaling (HPA, VPA)                 │
│  ✅ Rolling updates (Deployments)      │
│  ✅ Configuration (ConfigMaps/Secrets) │
│  ✅ Storage (Persistent Volumes)       │
│  ✅ Networking (CNI, Network Policies) │
└────────────────────────────────────────┘
```

## References

- [Martin Fowler on Microservices](https://martinfowler.com/articles/microservices.html)
- [12-Factor App](https://12factor.net/)
- [Kubernetes Services](services.md)
- [Kubernetes Deployments](deployments.md)
- [Service Mesh (Istio, Linkerd)](https://istio.io/)

### Related Documentation
- [Kubernetes Networking](k8s-networking-fundamentals.md)
- [Deploying Applications](deployments.md)
- [Services and Load Balancing](services.md)
- [ConfigMaps and Secrets Management](https://kubernetes.io/docs/concepts/configuration/)

---

**Next Steps**: Learn about [Kubernetes Services](services.md) and [Deployment strategies](deployment-strategies.md) for microservices.
