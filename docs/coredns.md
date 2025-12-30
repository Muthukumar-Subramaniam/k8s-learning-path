# CoreDNS

## Overview

**CoreDNS** is a flexible, extensible DNS server that serves as the default DNS service for Kubernetes clusters. It provides service discovery by translating service names to their corresponding IP addresses, enabling Pods to communicate with each other using human-readable names instead of IP addresses.

---

## What is CoreDNS?

CoreDNS is a **cloud-native DNS server** written in Go that:

- Provides DNS-based service discovery for Kubernetes
- Resolves service names to ClusterIP addresses
- Supports custom DNS configurations
- Enables external DNS resolution
- Implements DNS-based load balancing for headless services
- Is highly extensible through plugins

**Key Responsibilities**:

```
┌──────────────────────────────────────────────────────────────┐
│                       CoreDNS Functions                       │
├──────────────────────────────────────────────────────────────┤
│  1. Service name → ClusterIP resolution                      │
│  2. Pod name → Pod IP resolution                             │
│  3. Headless service → Multiple Pod IPs                      │
│  4. External DNS queries forwarding                          │
│  5. Custom DNS entries via ConfigMap                         │
│  6. DNS caching for performance                              │
│  7. Health checking and monitoring                           │
└──────────────────────────────────────────────────────────────┘
```

---

## CoreDNS Architecture in Kubernetes

### Deployment Structure

```
┌──────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                         │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐     │
│  │              kube-system namespace                  │     │
│  │                                                     │     │
│  │  ┌──────────────────────────────────────────────┐  │     │
│  │  │     CoreDNS Deployment (2 replicas)         │  │     │
│  │  │                                              │  │     │
│  │  │  ┌────────────────┐  ┌────────────────┐    │  │     │
│  │  │  │  CoreDNS Pod1  │  │  CoreDNS Pod2  │    │  │     │
│  │  │  │  10.8.0.50     │  │  10.8.1.50     │    │  │     │
│  │  │  └────────────────┘  └────────────────┘    │  │     │
│  │  │           ▲                    ▲            │  │     │
│  │  └───────────┼────────────────────┼────────────┘  │     │
│  │              │                    │                │     │
│  │              └────────┬───────────┘                │     │
│  │                       │                            │     │
│  │              ┌────────▼────────────┐               │     │
│  │              │   kube-dns Service  │               │     │
│  │              │   ClusterIP:        │               │     │
│  │              │   10.96.0.10:53     │               │     │
│  │              └─────────────────────┘               │     │
│  └─────────────────────────────────────────────────────┘     │
│                         ▲                                     │
│                         │                                     │
│              DNS queries from Pods                            │
│                                                               │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐         │
│  │   Pod A    │    │   Pod B    │    │   Pod C    │         │
│  │ /etc/      │    │ /etc/      │    │ /etc/      │         │
│  │ resolv.conf│    │ resolv.conf│    │ resolv.conf│         │
│  │ →10.96.0.10│    │ →10.96.0.10│    │ →10.96.0.10│         │
│  └────────────┘    └────────────┘    └────────────┘         │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### Components

1. **CoreDNS Pods**: 
   - Run as a Deployment in `kube-system` namespace
   - Usually 2 replicas for high availability
   - Listen on port 53 (DNS)

2. **kube-dns Service**:
   - ClusterIP service (default: `10.96.0.10`)
   - Named `kube-dns` for backward compatibility
   - Points to CoreDNS pods

3. **ConfigMap**:
   - `coredns` ConfigMap stores Corefile configuration
   - Defines DNS zones, plugins, and behaviors

---

## DNS Resolution Flow

### Service Name Resolution

```
┌──────────────────────────────────────────────────────────────┐
│                  DNS Resolution Process                       │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  1. Pod queries: "my-service.default.svc.cluster.local"      │
│                                                               │
│  ┌─────────────┐                                             │
│  │    Pod      │                                             │
│  │             │  Query: my-service                          │
│  └──────┬──────┘                                             │
│         │                                                     │
│         │ /etc/resolv.conf → nameserver 10.96.0.10           │
│         │                                                     │
│         ▼                                                     │
│  ┌─────────────────────────────────────┐                     │
│  │        kube-dns Service             │                     │
│  │        (ClusterIP: 10.96.0.10)      │                     │
│  └──────────────┬──────────────────────┘                     │
│                 │                                             │
│                 ▼                                             │
│  ┌─────────────────────────────────────┐                     │
│  │          CoreDNS Pod                │                     │
│  │  ┌───────────────────────────────┐  │                     │
│  │  │  2. Kubernetes Plugin         │  │                     │
│  │  │     - Queries Kubernetes API  │  │                     │
│  │  │     - Looks up Service        │  │                     │
│  │  │     - Returns ClusterIP       │  │                     │
│  │  └───────────────────────────────┘  │                     │
│  └─────────────────────────────────────┘                     │
│                 │                                             │
│                 ▼                                             │
│  3. Response: 10.96.0.100 (Service ClusterIP)                │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### Resolution Types

**1. Service Resolution (Standard)**:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: default
spec:
  clusterIP: 10.96.0.100
  selector:
    app: backend
  ports:
  - port: 8080
```

DNS Query Results:
```bash
# From any pod
nslookup my-service

# Returns:
# Name: my-service.default.svc.cluster.local
# Address: 10.96.0.100
```

**2. Headless Service Resolution**:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-headless
  namespace: default
spec:
  clusterIP: None  # Headless
  selector:
    app: database
  ports:
  - port: 5432
```

DNS Query Results:
```bash
nslookup my-headless

# Returns all Pod IPs:
# Name: my-headless.default.svc.cluster.local
# Address: 10.8.0.10
# Address: 10.8.0.11
# Address: 10.8.1.5
```

**3. Pod DNS Resolution**:

Pod DNS format: `<pod-ip-with-dashes>.<namespace>.pod.<cluster-domain>`

```bash
# For Pod with IP 10.8.0.5 in default namespace
nslookup 10-8-0-5.default.pod.cluster.local

# Returns:
# Name: 10-8-0-5.default.pod.cluster.local
# Address: 10.8.0.5
```

---

## DNS Naming Convention

### Service DNS Names

Kubernetes follows a hierarchical DNS naming structure:

```
<service-name>.<namespace>.svc.<cluster-domain>
```

**Components**:
- **service-name**: Name of the Service resource
- **namespace**: Kubernetes namespace (default: `default`)
- **svc**: Service indicator (fixed)
- **cluster-domain**: Cluster DNS domain (default: `cluster.local`)

**Examples**:

```bash
# Short form (same namespace)
my-service

# Namespace-specific
my-service.default

# Fully Qualified Domain Name (FQDN)
my-service.default.svc.cluster.local

# Cross-namespace access
database.production.svc.cluster.local
```

### Search Domains

Each Pod's `/etc/resolv.conf` includes search domains for DNS shortcuts:

```bash
# Inside a pod in 'default' namespace
cat /etc/resolv.conf

# Output:
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

**How search domains work**:

```bash
# Query: "my-service"
# Actual queries tried:
1. my-service.default.svc.cluster.local    ✓ Found
2. my-service.svc.cluster.local
3. my-service.cluster.local
4. my-service
```

---

## CoreDNS Configuration (Corefile)

CoreDNS is configured via a `Corefile` stored in a ConfigMap.

### Default Configuration

```bash
# View CoreDNS configuration
kubectl get configmap coredns -n kube-system -o yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
```

### Plugin Explanations

| Plugin | Purpose |
|--------|---------|
| **errors** | Logs errors to stdout |
| **health** | Health check endpoint at `:8080/health` |
| **ready** | Readiness check endpoint at `:8181/ready` |
| **kubernetes** | Kubernetes service/pod DNS resolution |
| **prometheus** | Metrics endpoint at `:9153/metrics` |
| **forward** | Forward non-cluster DNS queries to upstream DNS |
| **cache** | Cache DNS responses (TTL in seconds) |
| **loop** | Detect and prevent forwarding loops |
| **reload** | Auto-reload when Corefile changes |
| **loadbalance** | Round-robin load balancing for DNS responses |

---

## Custom DNS Configuration

### Adding Custom DNS Entries

**Method 1: Via CoreDNS Hosts Plugin**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
        }
        hosts {
           192.168.1.100 custom-host.example.com
           192.168.1.101 another-host.example.com
           fallthrough
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
```

**Method 2: Via Pod hostAliases**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  hostAliases:
  - ip: "192.168.1.100"
    hostnames:
    - "custom-host.example.com"
    - "custom-host"
  containers:
  - name: app
    image: nginx
```

### Custom Upstream DNS Servers

```yaml
# Modify forward plugin in Corefile
forward . 8.8.8.8 8.8.4.4 {
   max_concurrent 1000
}
```

---

## Pod DNS Configuration

### DNS Policy Options

Pods can customize their DNS behavior via `dnsPolicy`:

| DNS Policy | Behavior |
|------------|----------|
| **ClusterFirst** (default) | Use cluster DNS (CoreDNS), fall back to node DNS |
| **Default** | Inherit DNS config from node |
| **ClusterFirstWithHostNet** | For pods with `hostNetwork: true` |
| **None** | Use custom `dnsConfig` |

### Custom DNS Configuration

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-dns-pod
spec:
  dnsPolicy: "None"
  dnsConfig:
    nameservers:
    - 1.1.1.1
    - 8.8.8.8
    searches:
    - custom.svc.cluster.local
    - svc.cluster.local
    options:
    - name: ndots
      value: "2"
    - name: edns0
  containers:
  - name: app
    image: nginx
```

**Result in `/etc/resolv.conf`**:

```bash
nameserver 1.1.1.1
nameserver 8.8.8.8
search custom.svc.cluster.local svc.cluster.local
options ndots:2 edns0
```

---

## Troubleshooting DNS Issues

### Common Commands

```bash
# 1. Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# 2. Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns

# 3. Check CoreDNS service
kubectl get svc -n kube-system kube-dns

# 4. Verify CoreDNS configuration
kubectl get configmap coredns -n kube-system -o yaml

# 5. Check DNS from a test pod
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default

# 6. Check resolv.conf in a pod
kubectl exec -it <pod-name> -- cat /etc/resolv.conf

# 7. Test DNS resolution
kubectl exec -it <pod-name> -- nslookup my-service

# 8. Check CoreDNS metrics
kubectl port-forward -n kube-system svc/kube-dns 9153:9153
curl http://localhost:9153/metrics
```

### Debug Pod for DNS Testing

```bash
# Create a debug pod
kubectl run dns-test --image=busybox:1.28 --rm -it --restart=Never -- sh

# Inside the pod, test DNS:
nslookup kubernetes.default
nslookup my-service
nslookup google.com
```

### Common Issues and Solutions

**1. Pods can't resolve service names**

```bash
# Check CoreDNS is running
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check if kube-dns service exists
kubectl get svc -n kube-system kube-dns

# Verify pod's resolv.conf
kubectl exec <pod> -- cat /etc/resolv.conf
# Should contain: nameserver 10.96.0.10
```

**2. External DNS not working**

```bash
# Check forward configuration in CoreDNS
kubectl get configmap coredns -n kube-system -o yaml | grep forward

# Should have:
# forward . /etc/resolv.conf
# or
# forward . 8.8.8.8 8.8.4.4

# Test external resolution from CoreDNS pod
kubectl exec -n kube-system <coredns-pod> -- nslookup google.com
```

**3. DNS resolution very slow**

Check `ndots` configuration:

```bash
# High ndots (default: 5) causes many queries
kubectl exec <pod> -- cat /etc/resolv.conf | grep ndots

# Solution: Reduce ndots or use FQDNs
```

Example: Query for `google.com` with `ndots:5`:
- Tries: `google.com.default.svc.cluster.local`
- Tries: `google.com.svc.cluster.local`
- Tries: `google.com.cluster.local`
- Finally: `google.com` ✓

**Solution**: Use FQDN with trailing dot: `google.com.`

**4. CoreDNS CrashLoopBackOff**

```bash
# Common cause: Loop detection
kubectl logs -n kube-system <coredns-pod>

# Look for: "plugin/loop: Loop ... detected"

# Solution: Fix node's /etc/resolv.conf
# Should not point to 127.0.0.53 (systemd-resolved)
```

---

## Performance Tuning

### Caching Configuration

```yaml
# Increase cache TTL for better performance
.:53 {
    # ... other plugins ...
    cache 300  # Cache for 5 minutes (default: 30)
}
```

### Resource Limits

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
spec:
  template:
    spec:
      containers:
      - name: coredns
        resources:
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
```

### Autoscaling CoreDNS

```bash
# Enable DNS autoscaling
kubectl scale deployment coredns --replicas=3 -n kube-system

# Or use cluster-proportional-autoscaler
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/cluster-proportional-autoscaler/master/examples/coredns.yaml
```

---

## CoreDNS vs kube-dns

CoreDNS replaced **kube-dns** as the default DNS server in Kubernetes 1.13+.

### Comparison

| Feature | kube-dns | CoreDNS |
|---------|----------|---------|
| **Architecture** | 3 containers per pod | Single container |
| **Memory** | Higher | Lower (~50% less) |
| **Configuration** | Multiple ConfigMaps | Single Corefile |
| **Extensibility** | Limited | Highly extensible (plugins) |
| **Performance** | Good | Better |
| **Custom DNS** | Limited | Flexible |
| **Maintenance** | More complex | Simpler |

---

## Advanced Features

### DNS-Based Load Balancing

For headless services, CoreDNS returns all Pod IPs in round-robin fashion:

```bash
# Query headless service multiple times
for i in {1..5}; do
  nslookup my-headless | grep Address
done

# Each query returns Pod IPs in different order
# Client-side load balancing
```

### Service Discovery Patterns

**1. Direct Service Access**:
```bash
curl http://my-service:8080
```

**2. Cross-Namespace Access**:
```bash
curl http://api-service.production:8080
```

**3. StatefulSet Pod Discovery**:
```bash
# StatefulSet: my-statefulset with 3 replicas
# Individual pod DNS:
nslookup my-statefulset-0.my-service.default.svc.cluster.local
nslookup my-statefulset-1.my-service.default.svc.cluster.local
nslookup my-statefulset-2.my-service.default.svc.cluster.local
```

### External DNS Integration

For services accessible from outside the cluster:

```yaml
# Using ExternalDNS (separate project)
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    external-dns.alpha.kubernetes.io/hostname: myapp.example.com
spec:
  type: LoadBalancer
  ports:
  - port: 80
  selector:
    app: my-app
```

ExternalDNS automatically creates DNS records in external DNS providers (Route53, CloudDNS, etc.).

---

## Monitoring CoreDNS

### Prometheus Metrics

CoreDNS exposes metrics at `:9153/metrics`:

```bash
# Port-forward to access metrics
kubectl port-forward -n kube-system svc/kube-dns 9153:9153

# View metrics
curl http://localhost:9153/metrics
```

**Key Metrics**:
- `coredns_dns_request_duration_seconds`: Query latency
- `coredns_dns_requests_total`: Total requests
- `coredns_dns_responses_total`: Total responses by rcode
- `coredns_cache_hits_total`: Cache hit rate
- `coredns_cache_misses_total`: Cache misses

### Health Checks

```bash
# Health endpoint
kubectl port-forward -n kube-system <coredns-pod> 8080:8080
curl http://localhost:8080/health

# Readiness endpoint
curl http://localhost:8181/ready
```

---

## Security Considerations

### DNS Spoofing Protection

CoreDNS validates responses and uses DNSSEC when configured:

```yaml
# Enable DNSSEC validation
.:53 {
    dnssec {
        validate
    }
    # ... other plugins ...
}
```

### Network Policies for DNS

```yaml
# Allow DNS traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
```

---

## Installation and Configuration

### Checking Current Installation

```bash
# Check if CoreDNS is installed
kubectl get deployment coredns -n kube-system

# Check version
kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Manual Installation

```bash
# Install CoreDNS
kubectl apply -f https://raw.githubusercontent.com/coredns/deployment/master/kubernetes/coredns.yaml

# Or using Helm
helm repo add coredns https://coredns.github.io/helm
helm install coredns coredns/coredns -n kube-system
```

### Upgrading CoreDNS

```bash
# Update image version in deployment
kubectl set image deployment/coredns coredns=k8s.gcr.io/coredns/coredns:v1.11.1 -n kube-system

# Or edit deployment directly
kubectl edit deployment coredns -n kube-system
```

---

## Best Practices

1. **Use FQDNs for external domains**:
   ```bash
   # Instead of: google.com
   # Use: google.com. (with trailing dot)
   ```

2. **Reduce ndots for performance**:
   ```yaml
   dnsConfig:
     options:
     - name: ndots
       value: "2"  # Default is 5
   ```

3. **Monitor DNS performance**:
   - Track query latency
   - Monitor cache hit rates
   - Set up alerts for DNS failures

4. **Scale CoreDNS appropriately**:
   - Large clusters: 3+ replicas
   - Use horizontal pod autoscaling

5. **Configure resource limits**:
   - Prevent OOM issues
   - Ensure consistent performance

6. **Test DNS regularly**:
   ```bash
   # Periodic DNS tests in monitoring
   kubectl run dns-test --image=busybox --rm -it --restart=Never -- nslookup kubernetes.default
   ```

---

## Related Components

- **[kube-proxy](kube-proxy.md)**: Handles Service ClusterIP traffic routing
- **[Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)**: Overall networking architecture
- **[CNI Plugin](cni.md)**: Pod network implementation

---

## Key Takeaways

1. **CoreDNS is essential** for service discovery in Kubernetes
2. **DNS naming follows a hierarchy**: `service.namespace.svc.cluster.local`
3. **Headless services** enable direct Pod discovery without load balancing
4. **Custom DNS configurations** are flexible via Corefile and Pod dnsConfig
5. **DNS caching** significantly improves performance
6. **Proper monitoring** prevents DNS-related outages
7. **Understanding search domains** helps troubleshoot DNS issues

---

## References

- [CoreDNS Official Documentation](https://coredns.io/manual/toc/)
- [Kubernetes DNS Documentation](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [CoreDNS Plugins](https://coredns.io/plugins/)
- [Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
