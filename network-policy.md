# Network Policy

## Overview

**Network Policy** is a Kubernetes resource that acts as a firewall for Pod-to-Pod communication. It allows you to control traffic flow at the IP address or port level (OSI Layer 3/4) using label selectors to identify Pods.

By default, Kubernetes allows all Pods to communicate with each other without restrictions. Network Policies enable you to implement **Zero Trust** networking by explicitly defining which connections are allowed.

---

## What is Network Policy?

Network Policies are specifications that define:

- **Which Pods** can communicate with each other
- **What protocols and ports** are allowed
- **Direction of traffic** (ingress/egress)
- **Sources and destinations** (Pod selectors, namespace selectors, IP blocks)

**Key Characteristics**:

```
┌──────────────────────────────────────────────────────────────┐
│                  Network Policy Features                      │
├──────────────────────────────────────────────────────────────┤
│  • Namespace-scoped resource                                 │
│  • Applied to Pods via label selectors                       │
│  • Additive (multiple policies combine)                      │
│  • Whitelist-based (deny by default when policy exists)     │
│  • Enforced by CNI plugin (not all CNIs support it)         │
│  • Stateful (return traffic automatically allowed)          │
│  • Layer 3/4 only (IP/port level)                           │
└──────────────────────────────────────────────────────────────┘
```

---

## How Network Policies Work

### Default Behavior (No Policies)

Without any Network Policies, all traffic is allowed:

```
┌──────────────────────────────────────────────────────────────┐
│              Default: All Traffic Allowed                     │
│                                                               │
│  ┌──────────┐         ┌──────────┐         ┌──────────┐     │
│  │ Frontend │◄───────►│ Backend  │◄───────►│ Database │     │
│  │   Pod    │         │   Pod    │         │   Pod    │     │
│  └──────────┘         └──────────┘         └──────────┘     │
│       ▲                    ▲                    ▲           │
│       │                    │                    │           │
│       └────────────────────┴────────────────────┘           │
│              All connections allowed                        │
│                                                               │
│  External ───► Any Pod ───► Any Pod ───► External           │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### With Network Policy Applied

Once a Network Policy selects a Pod, **default deny** is enforced:

```
┌──────────────────────────────────────────────────────────────┐
│           With Network Policy: Selective Allow                │
│                                                               │
│  ┌──────────┐         ┌──────────┐         ┌──────────┐     │
│  │ Frontend │────✓───►│ Backend  │────✓───►│ Database │     │
│  │   Pod    │         │   Pod    │         │   Pod    │     │
│  └──────────┘         └──────────┘         └──────────┘     │
│       │                                          ▲           │
│       │                                          │           │
│       └──────────────────✗───────────────────────┘           │
│         Frontend → Database: BLOCKED                         │
│                                                               │
│  External ───✗───► Backend Pod (BLOCKED)                     │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### Policy Enforcement

Network Policies are enforced by the **CNI plugin**, not by Kubernetes itself:

```
┌──────────────────────────────────────────────────────────────┐
│                  Enforcement Flow                             │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  1. User creates NetworkPolicy resource                      │
│                    ▼                                          │
│  2. Kubernetes API stores the policy                         │
│                    ▼                                          │
│  3. CNI plugin watches for NetworkPolicy objects             │
│                    ▼                                          │
│  4. CNI translates policy to iptables/eBPF/OVS rules        │
│                    ▼                                          │
│  5. Rules enforced at network layer on each node            │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

---

## CNI Plugin Support

**Not all CNI plugins support Network Policies!**

### Support Matrix

| CNI Plugin | Network Policy Support | Implementation |
|------------|------------------------|----------------|
| **Calico** | ✅ Full (L3/L4 + L7) | iptables or eBPF |
| **Cilium** | ✅ Full (L3/L4 + L7) | eBPF |
| **Weave Net** | ✅ Basic (L3/L4) | iptables |
| **Antrea** | ✅ Full (L3/L4 + L7) | OVS |
| **kube-router** | ✅ Basic (L3/L4) | IPVS |
| **Flannel** | ❌ No support | N/A |
| **Canal** | ✅ Via Calico | Flannel + Calico |

> 📖 **See Also**: [cni.md](cni.md) for detailed CNI plugin information

### Checking Support

```bash
# Check if your CNI supports Network Policies
# Create a test policy and see if it's enforced

# If using Calico
kubectl get felixconfigurations.crd.projectcalico.org -o yaml

# If using Cilium
cilium status | grep -i policy
```

---

## Network Policy Specification

### Basic Structure

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: my-network-policy
  namespace: default
spec:
  podSelector:           # Which pods this policy applies to
    matchLabels:
      app: backend
  policyTypes:           # Types of traffic to control
  - Ingress
  - Egress
  ingress:               # Incoming traffic rules
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:                # Outgoing traffic rules
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 5432
```

### Key Fields

| Field | Description | Default |
|-------|-------------|---------|
| **podSelector** | Selects which Pods the policy applies to | Empty = all pods in namespace |
| **policyTypes** | `Ingress`, `Egress`, or both | Based on rules present |
| **ingress** | Rules for incoming traffic | If specified, default deny |
| **egress** | Rules for outgoing traffic | If specified, default deny |

---

## Ingress Rules

Ingress rules control **incoming** traffic to the selected Pods.

### Ingress Components

```yaml
ingress:
- from:                    # Source specification
  - podSelector: {}        # From pods (in same namespace)
  - namespaceSelector: {}  # From specific namespaces
  - ipBlock:              # From IP ranges
      cidr: 0.0.0.0/0
  ports:                   # Which ports to allow
  - protocol: TCP
    port: 8080
```

### Example: Allow Frontend to Backend

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
      tier: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
```

**Effect**:
- Applies to: Pods with labels `app=backend` and `tier=api`
- Allows: Traffic from Pods with label `app=frontend`
- Port: Only TCP port 8080
- **Blocks all other ingress traffic**

### Example: Allow from Specific Namespace

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-monitoring
  namespace: production
spec:
  podSelector: {}  # All pods in production namespace
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 9090  # Prometheus scrape port
```

**Effect**:
- Applies to: All Pods in `production` namespace
- Allows: Traffic from any Pod in `monitoring` namespace
- Port: Only TCP 9090

### Example: Allow from External IP Range

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-clients
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - ipBlock:
        cidr: 192.168.1.0/24
        except:
        - 192.168.1.100/32  # Block this specific IP
    ports:
    - protocol: TCP
      port: 80
```

**Effect**:
- Allows traffic from `192.168.1.0/24` except `192.168.1.100`
- Only to TCP port 80

---

## Egress Rules

Egress rules control **outgoing** traffic from the selected Pods.

### Egress Components

```yaml
egress:
- to:                      # Destination specification
  - podSelector: {}        # To pods (in same namespace)
  - namespaceSelector: {}  # To specific namespaces
  - ipBlock:              # To IP ranges
      cidr: 0.0.0.0/0
  ports:                   # Which ports to allow
  - protocol: TCP
    port: 443
```

### Example: Allow Backend to Database

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-to-database
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 5432
```

**Effect**:
- Applies to: Pods with label `app=backend`
- Allows: Traffic to Pods with label `app=database`
- Port: Only TCP 5432
- **Blocks all other egress traffic** (including DNS!)

### Example: Allow External HTTPS

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-https
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32  # Block AWS metadata service
    ports:
    - protocol: TCP
      port: 443
```

---

## Selector Types

### 1. podSelector

Selects Pods by labels within the **same namespace**:

```yaml
- from:
  - podSelector:
      matchLabels:
        app: frontend
        version: v2
```

### 2. namespaceSelector

Selects all Pods from namespaces matching labels:

```yaml
- from:
  - namespaceSelector:
      matchLabels:
        environment: production
```

### 3. Combined Selectors (AND)

Both conditions must match:

```yaml
- from:
  - namespaceSelector:
      matchLabels:
        environment: production
    podSelector:
      matchLabels:
        app: frontend
```

**Meaning**: Pods with `app=frontend` in namespaces with `environment=production`

### 4. Multiple Selectors (OR)

Separate list items are OR'd:

```yaml
- from:
  - namespaceSelector:
      matchLabels:
        environment: production
  - podSelector:
      matchLabels:
        app: monitoring
```

**Meaning**: Pods from production namespace **OR** pods with `app=monitoring` in same namespace

### 5. ipBlock

Selects based on IP CIDR:

```yaml
- from:
  - ipBlock:
      cidr: 10.0.0.0/8
      except:
      - 10.1.0.0/16
```

---

## Common Patterns

### 1. Default Deny All Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}  # Applies to all pods
  policyTypes:
  - Ingress
  # No ingress rules = deny all
```

### 2. Default Deny All Egress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Egress
  # No egress rules = deny all
```

### 3. Default Deny All Traffic

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

### 4. Allow All Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-ingress
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - {}  # Empty rule = allow all
```

### 5. Allow DNS (Essential for Egress Policies)

```yaml
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
    - protocol: TCP
      port: 53
```

### 6. Allow Kubernetes API Access

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-k8s-api
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: default
    podSelector:
      matchLabels:
        component: apiserver
    ports:
    - protocol: TCP
      port: 6443
```

### 7. Three-Tier Application

```yaml
# Frontend Network Policy
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
  namespace: app
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0  # Allow from internet
    ports:
    - protocol: TCP
      port: 80
  egress:
  - to:
    - podSelector:
        matchLabels:
          tier: backend  # Can call backend
    ports:
    - protocol: TCP
      port: 8080
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53  # DNS

---
# Backend Network Policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: app
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: frontend  # Only from frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          tier: database  # Can call database
    ports:
    - protocol: TCP
      port: 5432
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53  # DNS

---
# Database Network Policy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-policy
  namespace: app
spec:
  podSelector:
    matchLabels:
      tier: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: backend  # Only from backend
    ports:
    - protocol: TCP
      port: 5432
```

---

## Advanced Patterns

### Multi-Namespace Policy

Allow communication between production and staging:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-staging-to-production
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          environment: staging
    - namespaceSelector:
        matchLabels:
          environment: production
```

### Allow Monitoring/Observability

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring
  namespace: production
spec:
  podSelector: {}  # All pods
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 9090  # Prometheus
    - protocol: TCP
      port: 8080  # Metrics endpoints
```

### Restrict to NodePort/LoadBalancer

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-loadbalancer-only
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: TCP
      port: 80
```

---

## Policy Behavior Details

### Policy Combination (Additive)

Multiple policies selecting the same Pod are **combined (OR logic)**:

```
Policy 1: Allow from Frontend on port 8080
Policy 2: Allow from Monitoring on port 9090

Result: Allow from Frontend on 8080 OR from Monitoring on 9090
```

### Empty Selectors

- **Empty podSelector `{}`**: Applies to all Pods in namespace
- **Empty ingress/egress rule `- {}`**: Allows all traffic

### Stateful Connections

Network Policies are **stateful**:
- If Pod A is allowed to connect to Pod B
- Return traffic from B to A is automatically allowed
- No need to define bidirectional rules

### Protocol Support

Supported protocols:
- `TCP`
- `UDP`
- `SCTP`

### Named Ports

You can reference named ports from Pod specs:

```yaml
# Pod definition
ports:
- name: http
  containerPort: 8080

# Network Policy
ingress:
- from:
  - podSelector: {}
  ports:
  - protocol: TCP
    port: http  # References the named port
```

---

## Troubleshooting Network Policies

### Verify Policy is Applied

```bash
# List network policies
kubectl get networkpolicy -A

# Describe a policy
kubectl describe networkpolicy <policy-name> -n <namespace>

# Check if pods are selected
kubectl get pods -n <namespace> --show-labels
```

### Test Connectivity

```bash
# From one pod to another
kubectl exec -it <source-pod> -n <namespace> -- curl <target-service>:8080

# Check if connection succeeds or times out
```

### Common Issues

**1. Pods can't communicate after applying policy**

```bash
# Check if policy selects the right pods
kubectl describe networkpolicy <policy-name> -n <namespace>

# Verify pod labels
kubectl get pods -n <namespace> --show-labels

# Check if ingress/egress rules are correct
```

**2. DNS not working**

Most common issue with egress policies!

```bash
# Pods need DNS access - add DNS egress rule
egress:
- to:
  - namespaceSelector:
      matchLabels:
        name: kube-system
  ports:
  - protocol: UDP
    port: 53
```

**3. Policy not enforced**

```bash
# Check if CNI supports Network Policies
kubectl get pods -n kube-system | grep -E 'calico|cilium|weave'

# If using Flannel (doesn't support policies)
# Consider Canal (Flannel + Calico)
```

### Debug Tools

```bash
# Create a debug pod
kubectl run debug --image=nicolaka/netshoot --rm -it -- bash

# Inside debug pod:
# Test connectivity
curl -v http://target-service:8080

# Check DNS
nslookup target-service

# Test specific port
nc -zv target-service 8080

# Traceroute
traceroute target-service
```

### CNI-Specific Debugging

**Calico**:
```bash
# Check Calico policy
kubectl get networkpolicy -A
calicoctl get networkpolicy -A

# View applied rules
calicoctl get workloadendpoint -o wide

# Check Felix logs
kubectl logs -n calico-system -l k8s-app=calico-node
```

**Cilium**:
```bash
# Check Cilium policy enforcement
cilium endpoint list

# View policy verdict
cilium policy get

# Monitor traffic
cilium monitor
```

---

## Best Practices

### 1. Start with Default Deny

```yaml
# First, deny all traffic in namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

Then add specific allow rules.

### 2. Always Allow DNS

```yaml
# Essential for egress policies
egress:
- to:
  - namespaceSelector: {}
    podSelector:
      matchLabels:
        k8s-app: kube-dns
  ports:
  - protocol: UDP
    port: 53
```

### 3. Use Namespace Labels

Label namespaces for easier selection:

```bash
kubectl label namespace production environment=production
kubectl label namespace kube-system name=kube-system
```

### 4. Document Policies

Add annotations to explain the policy:

```yaml
metadata:
  name: backend-policy
  annotations:
    description: "Allows frontend to backend on port 8080"
    owner: "platform-team"
    ticket: "SEC-1234"
```

### 5. Test in Non-Production First

- Apply policies in dev/staging first
- Verify application works correctly
- Monitor for connection failures
- Then promote to production

### 6. Monitor Policy Effects

- Use CNI observability tools (Cilium Hubble, Calico logs)
- Set up alerts for denied connections
- Regular policy audits

### 7. Principle of Least Privilege

- Only allow necessary connections
- Specific ports rather than port ranges
- Specific sources rather than `0.0.0.0/0`

### 8. Use GitOps for Policy Management

- Store policies in version control
- Review changes via pull requests
- Automated validation and testing
- Audit trail of changes

---

## Network Policy vs Firewall

| Aspect | Network Policy | Traditional Firewall |
|--------|----------------|---------------------|
| **Scope** | Pod-to-Pod | Host-to-Host |
| **Configuration** | Declarative YAML | Imperative rules |
| **Granularity** | Label-based | IP/port-based |
| **Dynamic** | ✅ Adapts to pod changes | ❌ Static rules |
| **Cloud Native** | ✅ Yes | ❌ No |
| **Layer** | L3/L4 (some CNIs L7) | L3/L4 (L7 with DPI) |

---

## Limitations

1. **No Layer 7 filtering** (in standard NetworkPolicy)
   - Can't filter by HTTP path, headers, etc.
   - Some CNIs (Calico, Cilium) have extensions

2. **No logging** (in standard spec)
   - Can't see which connections are denied
   - CNI plugins may provide logging

3. **No rate limiting**
   - Can't limit connection rate
   - Use service mesh for this

4. **CNI dependent**
   - Requires CNI that implements NetworkPolicy
   - Behavior may vary between CNIs

5. **No global policies** (in standard spec)
   - Policies are namespace-scoped
   - Calico has GlobalNetworkPolicy CRD

---

## Advanced: CNI-Specific Extensions

### Calico GlobalNetworkPolicy

```yaml
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: deny-egress-external
spec:
  selector: tier == 'restricted'
  types:
  - Egress
  egress:
  - action: Deny
    destination:
      notNets:
      - 10.0.0.0/8      # Allow internal
      - 172.16.0.0/12
      - 192.168.0.0/16
```

### Cilium Network Policy (L7)

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-policy
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: "/api/v1/.*"
```

---

## Migration Strategy

### Phase 1: Audit Current Traffic

```bash
# Use observability tools to understand traffic patterns
# Calico: Use Flow Logs
# Cilium: Use Hubble
```

### Phase 2: Create Policies in Audit Mode

```yaml
# Calico example: Log instead of deny
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: audit-policy
spec:
  selector: app == 'web'
  types:
  - Ingress
  ingress:
  - action: Log
```

### Phase 3: Apply Permissive Policies

Start with allow-all policies for critical apps:

```yaml
# Allow all traffic initially
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: temporary-allow-all
spec:
  podSelector:
    matchLabels:
      app: critical-app
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - {}
  egress:
  - {}
```

### Phase 4: Gradually Restrict

Progressively tighten policies based on observed traffic.

### Phase 5: Default Deny

Finally, apply default deny to namespace.

---

## Related Components

- **[CNI Plugin](cni.md)**: Implements Network Policy enforcement
- **[kube-proxy](kube-proxy.md)**: Handles Service traffic (separate from Network Policy)
- **[Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)**: Overall networking architecture

---

## Key Takeaways

1. **Network Policies are whitelist-based** - once a policy selects a pod, default deny is enforced
2. **CNI plugin support required** - Flannel doesn't support policies, Calico/Cilium do
3. **Multiple policies are additive** - They combine with OR logic
4. **Always allow DNS** - Essential for egress policies to work
5. **Start with default deny** - Then add specific allow rules
6. **Policies are stateful** - Return traffic is automatically allowed
7. **Test thoroughly** - Breaking network connectivity can take down applications
8. **Use labels effectively** - Both for pod and namespace selection

---

## References

- [Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Network Policy Recipes](https://github.com/ahmetb/kubernetes-network-policy-recipes)
- [Calico Network Policy](https://docs.tigera.io/calico/latest/network-policy/)
- [Cilium Network Policy](https://docs.cilium.io/en/stable/security/policy/)
