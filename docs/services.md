# 🔗 Services: Stable Networking for Ephemeral Pods

A deep dive into the Kubernetes Service abstraction: why it exists, how the port fields relate, every Service type with its packet path, DNS discovery, traffic policies, dual stack, and the operational traps that bite in production.

## 📋 Table of Contents
- [Why Services Exist](#why-services-exist)
- [The Service Abstraction](#the-service-abstraction)
- [A Fully Annotated Service Manifest](#a-fully-annotated-service-manifest)
- [Port Fields Disambiguated](#port-fields-disambiguated)
- [Named Target Ports](#named-target-ports)
- [Multi Port Services](#multi-port-services)
- [Service Types Overview](#service-types-overview)
- [ClusterIP](#clusterip)
- [NodePort](#nodeport)
- [LoadBalancer](#loadbalancer)
- [ExternalName](#externalname)
- [Headless Services](#headless-services)
- [Selectorless Services and External Backends](#selectorless-services-and-external-backends)
- [The Default kubernetes Service](#the-default-kubernetes-service)
- [Service Discovery with DNS](#service-discovery-with-dns)
- [Service Discovery with Environment Variables](#service-discovery-with-environment-variables)
- [Session Affinity](#session-affinity)
- [External Traffic Policy](#external-traffic-policy)
- [Internal Traffic Policy](#internal-traffic-policy)
- [External IPs](#external-ips)
- [LoadBalancer Tuning Fields](#loadbalancer-tuning-fields)
- [Dual Stack Services](#dual-stack-services)
- [Traffic Distribution and Topology Aware Routing](#traffic-distribution-and-topology-aware-routing)
- [From Service Object to Datapath Rules](#from-service-object-to-datapath-rules)
- [Bare Metal LoadBalancer with MetalLB](#bare-metal-loadbalancer-with-metallb)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why Services Exist

Pods are **ephemeral**, and that single fact is the entire justification for the Service API. A Pod receives an IP from the cluster Pod CIDR at creation, keeps it for its whole life, and loses it permanently when it dies. A rolling update replaces every backing IP. A node reboot reschedules Pods elsewhere. An autoscaler adds and removes addresses continuously.

Four problems have to be solved together:

| Problem | What is needed |
|---------|----------------|
| Pod IPs churn constantly | A **stable identity** that outlives any individual Pod |
| Multiple replicas serve one role | **Load balancing** across the healthy set |
| Consumers must find the backend | **Service discovery**, ideally by name |
| Unhealthy or terminating Pods exist | **Readiness aware membership** |

```
┌──────────────────────────────────────────────────────────────────────┐
│   frontend  ──►  backend.prod.svc.cluster.local  ──►  10.96.42.17    │
│                        (stable name)                 (stable VIP)    │
│                                                            │         │
│                          load balanced, readiness filtered │         │
│                    ┌───────────────┬───────────────┬───────┘         │
│                    ▼               ▼               ▼                 │
│              10.8.1.55:8080  10.8.3.9:8080  10.8.2.44:8080           │
│                                                                      │
│   Pods come and go. The name and the VIP never change.               │
└──────────────────────────────────────────────────────────────────────┘
```

> 📖 The Pod, node and Service networks themselves are described in [k8s-networking-fundamentals.md](k8s-networking-fundamentals.md).

---

## The Service Abstraction

### 1. A Stable Virtual IP

The ClusterIP is allocated by the API server from the Service CIDR (`--service-cluster-ip-range` on kube-apiserver). It is virtual in the strictest sense: no interface owns it, nothing answers ARP for it, and it exists only as a match condition in kernel rules on every node.

```bash
kubectl get svc web -o jsonpath='{.spec.clusterIP}{"\n"}'   # 10.96.42.17
ip addr | grep 10.96.42.17                                  # no output, ever
```

The ClusterIP is **immutable** once assigned. You delete and recreate to change it. The one exception is converting to and from `type: ExternalName`, which clears the field.

### 2. A Label Selector

`spec.selector` is a plain **equality based** map. Every key must match exactly. There is no `matchLabels`, no `matchExpressions` and no set based operator, unlike Deployment and ReplicaSet selectors.

```yaml
selector:
  app: web
  tier: frontend     # both keys must be present on the Pod, with these values
```

The selector only matches Pods **in the Service's own namespace**. Membership is not stored in the Service; the EndpointSlice controller computes it and writes it elsewhere.

### 3. A Port Mapping

`spec.ports` maps the port clients dial to the port the container listens on.

```
┌──────────────────────────────────────────────────────────────────────┐
│   Service object (API)      EndpointSlice (API)      Node kernel     │
│   ┌─────────────────┐       ┌────────────────┐    ┌──────────────┐   │
│   │ name: web       │       │ 10.8.1.55:8080 │    │ iptables /   │   │
│   │ clusterIP: ...  │──────►│ 10.8.3.9:8080  │───►│ IPVS / eBPF  │   │
│   │ selector: ...   │       │ 10.8.2.44:8080 │    │ rules        │   │
│   │ ports: 80→8080  │       └────────────────┘    └──────────────┘   │
│   └─────────────────┘                                                │
│      you write this      controller writes this   kube-proxy writes  │
└──────────────────────────────────────────────────────────────────────┘
```

You declare intent, controllers turn it into membership, kube-proxy turns membership into packets.

> 📖 Full membership anatomy in [endpointslices.md](endpointslices.md).

---

## A Fully Annotated Service Manifest

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web                      # becomes the DNS label: web.<ns>.svc.cluster.local
  namespace: prod
  labels:
    app: web
  annotations:
    # Cloud and LB implementations read annotations; none are core API fields
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: ClusterIP                # ClusterIP (default) | NodePort | LoadBalancer | ExternalName

  selector:                      # equality only, same namespace only
    app: web

  ports:
  - name: http                   # REQUIRED once there is more than one port
    protocol: TCP                # TCP (default) | UDP | SCTP
    port: 80                     # port on the Service VIP that clients dial
    targetPort: 8080             # port on the Pod: a number or a containerPort NAME
    appProtocol: http            # hint for implementations, no core behaviour

  clusterIP: 10.96.42.17         # usually omit; "None" makes the Service headless
  clusterIPs:                    # dual stack form; [0] must equal clusterIP
  - 10.96.42.17

  ipFamilyPolicy: SingleStack    # SingleStack | PreferDualStack | RequireDualStack
  ipFamilies:                    # ordered: [IPv4], [IPv6], [IPv4,IPv6], [IPv6,IPv4]
  - IPv4

  sessionAffinity: None          # None (default) | ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800      # default 3 hours, maximum 86400

  internalTrafficPolicy: Cluster # Cluster (default) | Local
  externalTrafficPolicy: Cluster # Cluster (default) | Local; NodePort and LoadBalancer only

  publishNotReadyAddresses: false  # true exposes not ready endpoints (peer discovery)

  externalIPs:                   # IPs you route to nodes yourself; nothing is allocated
  - 203.0.113.10
```

LoadBalancer only fields, and the ExternalName form:

```yaml
spec:
  type: LoadBalancer
  loadBalancerClass: metallb.universe.tf/metallb  # which implementation should claim it
  allocateLoadBalancerNodePorts: true             # default true
  loadBalancerSourceRanges:                       # implementation dependent allow list
  - 10.0.0.0/8
  healthCheckNodePort: 32100                      # only with externalTrafficPolicy: Local
---
spec:
  type: ExternalName
  externalName: db.example.com   # a DNS name, NOT an IP address
  # selector, clusterIP, ports and endpoints are unused
```

---

## Port Fields Disambiguated

Four port fields, three on the Service and one on the Pod. This is the most common source of confusion, so here is the whole picture at once.

```
┌────────────────────────────────────────────────────────────────────────────┐
│  External client ──► http://<any-node-ip>:30080                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ NODE 10.28.28.11                                                     │  │
│  │   nodePort: 30080  ◄── Service.spec.ports[].nodePort                 │  │
│  │        │               opened on EVERY node, 30000-32767 by default  │  │
│  │        │               only for type NodePort and LoadBalancer       │  │
│  │        ▼                                                             │  │
│  │   ┌──────────────────────────────────────────────┐                   │  │
│  │   │ ClusterIP 10.96.42.17                        │                   │  │
│  │   │   port: 80       ◄── Service.spec.ports[].port                   │  │
│  │   │       │              what in-cluster clients dial: curl web:80   │  │
│  │   │       ▼                                                          │  │
│  │   │   targetPort: 8080 ◄── Service.spec.ports[].targetPort           │  │
│  │   │       │                the port ON THE POD to DNAT to            │  │
│  │   └───────┼──────────────────────────────────────┘                   │  │
│  └───────────┼──────────────────────────────────────────────────────────┘  │
│              ▼                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ POD 10.8.1.55                                                        │  │
│  │   containerPort: 8080 ◄── Pod.spec.containers[].ports[].containerPort │ │
│  │                           PURELY DOCUMENTATION for TCP/UDP reach.    │  │
│  │                           Omitting it does NOT block traffic.        │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

| Field | Lives on | Meaning | Default | Range |
|-------|----------|---------|---------|-------|
| `port` | Service | Port exposed on the ClusterIP | required | 1 to 65535 |
| `targetPort` | Service | Port on the Pod to forward to | **equals `port`** | number or a `containerPort` name |
| `nodePort` | Service | Port opened on every node | auto allocated | 30000 to 32767 by default |
| `containerPort` | Pod | Declared listening port | none | 1 to 65535 |

Three rules that clear up most confusion:

1. **`targetPort` defaults to `port`.** If the container listens on 8080 and you write only `port: 80`, the Service forwards to port 80 on the Pod and everything times out.
2. **`containerPort` is documentation.** kube-proxy never reads it for routing. It documents intent and is the anchor a *named* `targetPort` resolves against. A container listening on an undeclared port is still reachable.
3. **`nodePort` is not a container port.** Traffic arriving there is still DNATed to `targetPort` on a Pod, possibly on a different node.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - port: 80          # clients: curl http://web
    targetPort: 8080  # container listens here
---
apiVersion: v1
kind: Pod
metadata:
  name: web
  labels:
    app: web
spec:
  containers:
  - name: app
    image: myapp:1.0
    ports:
    - containerPort: 8080   # documentation, and a name anchor
```

The node port range is set cluster wide with `--service-node-port-range` on kube-apiserver and defaults to `30000-32767`.

---

## Named Target Ports

`targetPort` accepts a string that refers to a `containerPort` **name** in the Pod, not a well known name from `/etc/services`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  labels:
    app: web
spec:
  containers:
  - name: app
    image: myapp:1.0
    ports:
    - name: http-web        # max 15 chars, lowercase alphanumeric and '-'
      containerPort: 8080
    - name: metrics
      containerPort: 9090
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - name: http
    port: 80
    targetPort: http-web    # resolved PER POD when endpoints are computed
```

Because resolution is per Pod, two Pods behind one Service may listen on different numbers as long as both declare the same port name. A port migration becomes a rolling update rather than a Service edit:

```
Service targetPort: http-web
  Pod v1  ports: [{name: http-web, containerPort: 8080}]  ► :8080
  Pod v2  ports: [{name: http-web, containerPort: 9000}]  ► :9000
  Both are valid endpoints simultaneously during the rollout.
```

Name constraints: maximum **15 characters**, lowercase letters, digits and `-`, at least one letter, no leading, trailing or consecutive `-`, and unique within the Pod across all containers.

> ⚠️ If no container declares that name, the Pod is still **selected** but produces **no endpoint port**, so it silently receives nothing.

---

## Multi Port Services

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - name: http          # name is MANDATORY once there is more than one port
    port: 80
    targetPort: 8080
    protocol: TCP
  - name: https
    port: 443
    targetPort: 8443
    protocol: TCP
  - name: metrics
    port: 9090
    targetPort: metrics
    protocol: TCP
```

1. **`name` is required on every entry** when `spec.ports` has more than one element. With a single port it may be omitted. The API server rejects unnamed entries in a multi port Service, which is why the field is not simply optional everywhere.
2. Names must be unique within the Service and follow DNS label rules, since they become SRV labels.
3. The `(port, protocol)` pair must be unique. Exposing `port: 53` twice, once UDP and once TCP, is legal and is exactly what the cluster DNS Service does.
4. Each named port yields an SRV record: `_http._tcp.web.prod.svc.cluster.local`.
5. Each entry gets its own `nodePort` for NodePort and LoadBalancer Services, so a three port Service consumes three node ports.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: dns
spec:
  selector:
    app: coredns
  ports:
  - name: dns
    port: 53
    protocol: UDP
    targetPort: 53
  - name: dns-tcp
    port: 53
    protocol: TCP
    targetPort: 53
```

> ⚠️ A Service cannot map one `port` to different `targetPort` values by path or host. That is Layer 7 routing, which belongs to Ingress or Gateway API.

---

## Service Types Overview

The types are **cumulative**: NodePort includes everything ClusterIP does, LoadBalancer includes everything NodePort does unless node port allocation is disabled.

```
┌──────────────────────────────────────────────────────────────────────────┐
│   ┌────────────────────────────────────────────────────────────────┐     │
│   │ LoadBalancer: external IP from an LB implementation            │     │
│   │  ┌──────────────────────────────────────────────────────────┐  │     │
│   │  │ NodePort: port 30000-32767 on every node                 │  │     │
│   │  │  ┌────────────────────────────────────────────────────┐  │  │     │
│   │  │  │ ClusterIP: virtual IP, cluster internal only       │  │  │     │
│   │  │  └────────────────────────────────────────────────────┘  │  │     │
│   │  └──────────────────────────────────────────────────────────┘  │     │
│   └────────────────────────────────────────────────────────────────┘     │
│   Outside the hierarchy:                                                 │
│     ExternalName ► pure DNS CNAME, no VIP, no proxying, no endpoints     │
│     Headless     ► clusterIP: None, DNS returns Pod IPs directly         │
└──────────────────────────────────────────────────────────────────────────┘
```

| Type | VIP | Node ports | Reachable from | Typical use |
|------|-----|-----------|----------------|-------------|
| `ClusterIP` | Yes | No | Inside cluster | All internal traffic |
| `NodePort` | Yes | Yes | Any node IP | Dev, on prem behind an external LB |
| `LoadBalancer` | Yes | Yes by default | External IP | Production entry point |
| `ExternalName` | No | No | Inside cluster (DNS only) | Aliasing an external hostname |
| Headless | No | No | Inside cluster (DNS only) | StatefulSets, client side LB |

---

## ClusterIP

The default type, reachable from Pods, from the nodes themselves, and from anything explicitly routed into the Service CIDR.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: prod
spec:
  type: ClusterIP        # may be omitted, this is the default
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 8080
```

```
┌────────────────────────────────────────────────────────────────────────┐
│  NODE A                                       NODE B                   │
│  ┌───────────────┐                            ┌───────────────┐        │
│  │ frontend Pod  │ curl http://backend.prod   │ backend Pod   │        │
│  │ 10.8.1.20     │ dst = 10.96.42.17:80       │ 10.8.2.44     │        │
│  └───────┬───────┘                            └───────▲───────┘        │
│          ▼                                            │                │
│  ┌───────────────────────────────┐                    │                │
│  │ kernel rules from kube-proxy  │                    │                │
│  │  1. match dst ClusterIP       │                    │                │
│  │  2. pick an endpoint          │                    │                │
│  │  3. DNAT to 10.8.2.44:8080    │                    │                │
│  │  4. record in conntrack       │                    │                │
│  └───────────┬───────────────────┘                    │                │
│              │ src 10.8.1.20 PRESERVED ───────────────┘                │
│  Return path: conntrack reverses the DNAT, so the client sees the      │
│  reply come from 10.96.42.17:80, exactly what it dialed.               │
└────────────────────────────────────────────────────────────────────────┘
```

Two properties worth internalising: the **source IP is preserved** for Pod to Pod traffic, which is what makes ingress NetworkPolicy on the receiving side work; and the **DNAT happens on the client's node**, so there is no central proxy and no extra hop.

Use ClusterIP for every internal service to service call and for Ingress controller backends. It is the overwhelming majority of Services in a real cluster.

> 📖 The exact chains and virtual servers involved are dissected in [kube-proxy.md](kube-proxy.md).

---

## NodePort

Allocates a port in the node port range and opens it on **every node**, whether or not that node runs a backing Pod.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: NodePort
  selector:
    app: web
  ports:
  - port: 80          # still creates a working ClusterIP on 10.96.x.x:80
    targetPort: 8080
    nodePort: 30080   # optional; omit to let the API server allocate one
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  client 192.0.2.50 ──► curl http://10.28.28.11:30080                     │
│  ┌────────────────────────────┐          ┌────────────────────────────┐  │
│  │ NODE A 10.28.28.11         │          │ NODE B 10.28.28.12         │  │
│  │ (no backend Pod here)      │          │ (backend Pod here)         │  │
│  │  :30080 matched            │          │                            │  │
│  │    ├─ SNAT src to node IP  │          │  ┌──────────────────────┐  │  │
│  │    │  (policy Cluster)     │ overlay  │  │ web Pod 10.8.2.44    │  │  │
│  │    └─ DNAT to 10.8.2.44 ───┼─────────►│  │ sees src=10.28.28.11 │  │  │
│  └────────────────────────────┘          │  └──────────────────────┘  │  │
│  SNAT is required so the reply returns via Node A, which holds the      │
│  conntrack entry needed to undo the DNAT.                               │
└──────────────────────────────────────────────────────────────────────────┘
```

```bash
kubectl get svc web -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
curl http://10.28.28.11:30080     # any node works, same result
curl http://10.28.28.12:30080
```

- Node ports are allocated cluster wide; two Services cannot share one.
- The port opens on **all** node IPs unless kube-proxy is configured with `nodePortAddresses` to restrict it to specific CIDRs.
- Host firewalls and cloud security groups must allow it. This is the number one reason a NodePort "does not work".

Use it in labs, or on premises behind an external load balancer or an HAProxy pair. Do not use it as the general way to expose many HTTP applications; put an Ingress controller behind one entry point instead.

---

## LoadBalancer

Asks an external implementation to provision a load balancer and publish an address. Kubernetes itself does **not** implement load balancers; it publishes intent and waits.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 8080
  externalTrafficPolicy: Local     # very common with LoadBalancer
status:
  loadBalancer:
    ingress:
    - ip: 203.0.113.42             # written by the LB controller, not by you
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  1. You create Service type: LoadBalancer                                │
│  2. API server allocates a ClusterIP and (by default) node ports         │
│  3. EXTERNAL-IP shows <pending>                                          │
│  4. An LB controller notices: cloud controller manager, MetalLB,         │
│     kube-vip, Cilium LB IPAM, OpenStack Octavia, an appliance CIS, ...   │
│  5. It provisions or claims an address                                   │
│  6. It writes status.loadBalancer.ingress[].ip (or .hostname)            │
│  7. EXTERNAL-IP shows the address and traffic flows                      │
│                                                                          │
│  If nothing implements LoadBalancer, <pending> lasts FOREVER.            │
│  That is not a bug and there is no timeout.                              │
└──────────────────────────────────────────────────────────────────────────┘
```

Two datapath shapes exist:

```
Shape A: LB targets node ports (most cloud LBs, MetalLB)
   client ──► LB VIP ──► node:30080 ──► kube-proxy rules ──► Pod

Shape B: LB targets Pod IPs directly (cloud "IP mode", CNI integrated LBs)
   client ──► LB VIP ──────────────────────────────────────► Pod
   (node ports can then be disabled with allocateLoadBalancerNodePorts: false)
```

Use it for a single production entry point per cluster, usually pointing at an Ingress controller rather than at each application, and for non HTTP workloads that need raw TCP or UDP from outside.

---

## ExternalName

A pure DNS construct: no ClusterIP, no endpoints, no proxying and no kube-proxy rules at all. CoreDNS returns a **CNAME** pointing at `spec.externalName`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: legacy-db
  namespace: prod
spec:
  type: ExternalName
  externalName: db-prod-01.corp.example.com
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Pod: mysql -h legacy-db.prod.svc.cluster.local                          │
│    CoreDNS answers:                                                      │
│      legacy-db.prod.svc.cluster.local. CNAME db-prod-01.corp.example.com.│
│    Resolver follows the CNAME, CoreDNS forwards upstream                 │
│    Pod connects DIRECTLY to 192.0.2.77:3306                              │
│                                                                          │
│  kube-proxy never sees this traffic. No VIP exists.                      │
└──────────────────────────────────────────────────────────────────────────┘
```

Rules and limitations:

- `externalName` **must be a DNS name**. An IP there is treated as a name and resolution fails. Use a selectorless Service for an IP.
- **No port remapping.** `spec.ports` is meaningless; the client connects to whatever port it dials on the external host.
- **TLS and HTTP Host headers are not rewritten.** The client still sends `Host: legacy-db` unless you change it, and certificate validation happens against the real host, a frequent source of name mismatch errors.
- The target must be resolvable by CoreDNS upstream.

The best use is migration: point `legacy-db` at the external host today and later replace the same Service name with a ClusterIP Service backed by in cluster Pods, without callers changing.

> 📖 CoreDNS plugin behaviour and forwarding are described in [coredns.md](coredns.md).

---

## Headless Services

Setting `clusterIP: None` creates a **headless** Service: no virtual IP, no load balancing and no kube-proxy rules. Its entire purpose is DNS.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cassandra
  namespace: data
spec:
  clusterIP: None        # THIS is what makes it headless
  selector:
    app: cassandra
  ports:
  - name: cql
    port: 9042
    targetPort: 9042
```

### With a Selector: DNS Returns Pod A Records

```
┌──────────────────────────────────────────────────────────────────────┐
│  Normal ClusterIP Service                                            │
│    nslookup web.prod.svc.cluster.local  ►  10.96.42.17               │
│    (one answer, the VIP; the kernel load balances)                   │
│                                                                      │
│  Headless Service                                                    │
│    nslookup cassandra.data.svc.cluster.local                         │
│      ►  10.8.1.10                                                    │
│      ►  10.8.2.31                                                    │
│      ►  10.8.3.7                                                     │
│    (one A record per READY endpoint; the client chooses)             │
└──────────────────────────────────────────────────────────────────────┘
```

Consequences:

- **Load balancing moves to the client.** Many resolvers take the first record, so a naive HTTP client with connection reuse pins to one Pod forever. Smart clients (database drivers, gRPC with a DNS resolver and round robin policy) use the whole list deliberately.
- **DNS caching becomes your problem.** A client that resolves once at startup keeps dialling a dead Pod IP.
- Only **ready** endpoints are returned, unless `publishNotReadyAddresses: true`.

### Per Pod DNS Records

Each Pod behind a headless Service gets its own stable name, `<pod-hostname>.<service>.<namespace>.svc.cluster.local`. For a StatefulSet the Pod hostname is the Pod name, so the records are deterministic:

```
cassandra-0.cassandra.data.svc.cluster.local  ►  10.8.1.10
cassandra-1.cassandra.data.svc.cluster.local  ►  10.8.2.31
cassandra-2.cassandra.data.svc.cluster.local  ►  10.8.3.7
```

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: cassandra
  namespace: data
spec:
  serviceName: cassandra        # MUST name the headless Service
  replicas: 3
  selector:
    matchLabels:
      app: cassandra
  template:
    metadata:
      labels:
        app: cassandra          # must match the Service selector
    spec:
      containers:
      - name: cassandra
        image: cassandra:4.1
        ports:
        - name: cql
          containerPort: 9042
```

A plain Pod gets the same records if you set `hostname` and a `subdomain` equal to the headless Service name:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-a
  labels:
    app: cassandra
spec:
  hostname: node-a
  subdomain: cassandra          # ► node-a.cassandra.data.svc.cluster.local
  containers:
  - name: c
    image: cassandra:4.1
```

### publishNotReadyAddresses

Clustered software has a bootstrap paradox: a member is not ready until it joins, and it cannot join until it resolves its peers. This field breaks the deadlock by publishing endpoints regardless of readiness.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cassandra
spec:
  clusterIP: None
  publishNotReadyAddresses: true    # peers discoverable before they are Ready
  selector:
    app: cassandra
  ports:
  - port: 9042
```

A common pattern is two Services: one headless with `publishNotReadyAddresses: true` for peer discovery, and one normal ClusterIP Service with strict readiness for client traffic.

### Selectorless Headless Services

A headless Service with no selector and no endpoints returns **NXDOMAIN** for its own name. The genuinely useful variants are:

1. Headless, no selector, plus **manually written EndpointSlices**: DNS returns exactly the addresses you listed, with no VIP and no proxying. Good for exposing a fixed set of external hosts under a cluster local name when you want the client to see all of them.
2. Headless, no selector, with endpoints of `addressType: FQDN`, which gives CNAME style behaviour, though support varies by DNS implementation.

### When to Use Headless

| Use case | Why headless |
|----------|--------------|
| StatefulSet peer discovery | Stable per Pod DNS names tied to the ordinal |
| Databases with cluster aware drivers | The driver wants the member list, not a VIP |
| gRPC client side load balancing | Long lived HTTP/2 connections otherwise pin to one Pod |
| Kafka, Cassandra, Elasticsearch, etcd, Zookeeper | Protocols that redirect clients to specific members |
| Latency sensitive paths | One fewer NAT translation |

> 📖 StatefulSet identity and `serviceName` are covered in [statefulsets.md](statefulsets.md).

---

## Selectorless Services and External Backends

Omit `spec.selector` and the EndpointSlice controller leaves the Service alone; you own the endpoint data. You still get a cluster local name, a ClusterIP, load balancing and port remapping, pointing at addresses that are not Pods.

```yaml
# 1. The Service: no selector, so nothing manages its endpoints
apiVersion: v1
kind: Service
metadata:
  name: external-postgres
  namespace: prod
spec:
  ports:
  - name: pg
    port: 5432          # what in-cluster clients dial
    targetPort: 5432    # port on the external host
    protocol: TCP
---
# 2. The membership, written by you
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: external-postgres-1        # convention: <service-name>-<suffix>
  namespace: prod
  labels:
    kubernetes.io/service-name: external-postgres   # REQUIRED: binds slice to Service
addressType: IPv4
ports:
- name: pg                          # MUST match the Service port name
  port: 5432
  protocol: TCP
endpoints:
- addresses:
  - "192.0.2.77"                    # the real database
  conditions:
    ready: true
```

Now `psql -h external-postgres.prod.svc.cluster.local` works from any Pod, and the external IP appears in exactly one place in your manifests.

### ExternalName versus Selectorless

| Aspect | ExternalName | Selectorless plus EndpointSlice |
|--------|--------------|---------------------------------|
| Mechanism | DNS CNAME | Real VIP plus kube-proxy DNAT |
| Target | A DNS name | IP addresses (or FQDN address type) |
| Port remapping | Not possible | Yes, `port` to `targetPort` |
| Load balancing across targets | No | Yes, across all listed addresses |
| Survives target IP change | Yes, DNS handles it | No, you must update the slice |
| TLS and Host implications | Client uses the original hostname | Client uses the Service name |

Constraints: the addresses must not be link local (`169.254.0.0/16`, `fe80::/64`) or loopback, the API server rejects those. Pointing a selectorless Service at another Service's ClusterIP is unsupported, because the resulting double DNAT does not behave. And you now own health: nothing removes a dead external host from the slice.

> 📖 Full EndpointSlice anatomy, mirroring and validation live in [endpointslices.md](endpointslices.md).

---

## The Default kubernetes Service

Every cluster has a Service named `kubernetes` in the `default` namespace. It is how in cluster workloads reach the API server.

```bash
kubectl get svc kubernetes -n default
# NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
# kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP   87d
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kubernetes
  namespace: default
  labels:
    component: apiserver
    provider: kubernetes
spec:
  type: ClusterIP
  clusterIP: 10.96.0.1        # the FIRST usable address of the Service CIDR
  ports:
  - name: https
    port: 443
    targetPort: 6443          # the real API server port
    protocol: TCP
  sessionAffinity: None
  # NOTE: no selector. Control plane endpoints are not selected by labels.
```

### How It Is Maintained

It is **not** managed by the EndpointSlice controller. The **API server itself** reconciles it:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Each kube-apiserver instance, on a timer:                           │
│   1. Renews its own lease / registration                             │
│   2. Reads the set of live apiserver advertise addresses             │
│   3. Reconciles the "kubernetes" Endpoints and EndpointSlice so      │
│      they list exactly those addresses on the secure port            │
│                                                                      │
│  Reconciler chosen by --endpoint-reconciler-type on kube-apiserver:  │
│   lease         (default) leases in etcd, self healing               │
│   master-count  legacy, requires a static --apiserver-count          │
│   none          you manage the endpoints yourself                    │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o yaml
kubectl get leases -n kube-system | grep apiserver
```

Why it matters: every Pod is given `KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT`, and in cluster controllers, operators and CSI drivers all reach the API through this Service. Test it early:

```bash
kubectl run apitest --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sk https://kubernetes.default.svc/version
```

---

## Service Discovery with DNS

CoreDNS watches Services and EndpointSlices and serves records under the cluster domain, `cluster.local` by default.

For a Service `web` in namespace `prod`, all of these resolve, subject to the client's search path:

```
web                                    # same namespace only, via search path
web.prod                               # cross namespace, via search path
web.prod.svc                           # cross namespace, via search path
web.prod.svc.cluster.local             # fully qualified
web.prod.svc.cluster.local.            # absolute (trailing dot), fastest
```

A typical Pod `/etc/resolv.conf`:

```
nameserver 10.96.0.10
search prod.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ndots:5 means any name with fewer than 5 dots is tried against the      │
│  search list FIRST, before being tried as an absolute name.              │
│                                                                          │
│  "web" from namespace prod:                                              │
│    web.prod.svc.cluster.local              ► 10.96.42.17  ✅ one query   │
│                                                                          │
│  "api.example.com" (2 dots, still fewer than 5):                         │
│    api.example.com.prod.svc.cluster.local  ► NXDOMAIN                    │
│    api.example.com.svc.cluster.local       ► NXDOMAIN                    │
│    api.example.com.cluster.local           ► NXDOMAIN                    │
│    api.example.com                         ► ✅ finally answered         │
│                                                                          │
│  Four queries (eight counting IPv6) for one external name. A trailing    │
│  dot, "api.example.com.", goes straight to the answer.                   │
└──────────────────────────────────────────────────────────────────────────┘
```

| Record | Example | Returned for |
|--------|---------|--------------|
| A / AAAA | `web.prod.svc.cluster.local` to the ClusterIP | Normal Service |
| A / AAAA | `cassandra.data.svc.cluster.local` to all Pod IPs | Headless Service |
| A / AAAA | `cassandra-0.cassandra.data.svc.cluster.local` | Pod behind a headless Service |
| SRV | `_cql._tcp.cassandra.data.svc.cluster.local` | Named ports |
| CNAME | `legacy-db.prod.svc.cluster.local` | ExternalName Service |
| PTR | reverse lookup of a ClusterIP | Normal Service |

Any Service is reachable from any namespace by qualifying the name; DNS provides no isolation. If you need isolation, that is NetworkPolicy's job.

> 📖 Corefile, plugins, caching and DNS scaling are in [coredns.md](coredns.md).

---

## Service Discovery with Environment Variables

kubelet injects Service information into container environments. For a Service `redis-master` on port 6379 with ClusterIP 10.96.5.10, every Pod in the same namespace receives:

```bash
# Kubernetes style
REDIS_MASTER_SERVICE_HOST=10.96.5.10
REDIS_MASTER_SERVICE_PORT=6379

# Docker link compatible style
REDIS_MASTER_PORT=tcp://10.96.5.10:6379
REDIS_MASTER_PORT_6379_TCP=tcp://10.96.5.10:6379
REDIS_MASTER_PORT_6379_TCP_PROTO=tcp
REDIS_MASTER_PORT_6379_TCP_PORT=6379
REDIS_MASTER_PORT_6379_TCP_ADDR=10.96.5.10
```

The Service name is uppercased and `-` becomes `_`, so `my-web` produces `MY_WEB_SERVICE_HOST`.

### The Ordering Gotcha

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ⚠️  ENVIRONMENT VARIABLES ARE SET ONCE, AT CONTAINER START              │
│                                                                          │
│  Broken order                          Working order                     │
│  10:00 create frontend Pod             10:00 create redis Service        │
│  10:00 container starts, no REDIS_*    10:01 create frontend Pod         │
│  10:05 create redis Service            10:01 container starts WITH       │
│  10:05 Pod env UNCHANGED, forever            REDIS_MASTER_SERVICE_HOST   │
│                                                                          │
│  Fix for the broken order: delete the Pod so it is recreated. Better:    │
│  use DNS, which has no ordering requirement at all.                      │
└──────────────────────────────────────────────────────────────────────────┘
```

Other problems: only same namespace Services are injected, and in a namespace with hundreds of Services the environment becomes enormous, slowing startup and colliding with application variables. A Service named `postgres` injecting `POSTGRES_PORT=tcp://10.96.5.10:5432` famously breaks images that expect `POSTGRES_PORT=5432`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  enableServiceLinks: false      # default is true
  containers:
  - name: app
    image: myapp:1.0
```

`KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT` are injected regardless of `enableServiceLinks`, because client libraries depend on them.

---

## Session Affinity

By default each new connection is balanced independently. `sessionAffinity: ClientIP` pins a client IP to one backend.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800     # default 10800 (3 hours), maximum 86400
  ports:
  - port: 80
    targetPort: 8080
```

```
sessionAffinity: None (default)        sessionAffinity: ClientIP
  10.8.1.20 conn 1 ► Pod A               10.8.1.20 conn 1 ► Pod A
  10.8.1.20 conn 2 ► Pod C               10.8.1.20 conn 2 ► Pod A
  10.8.1.20 conn 3 ► Pod B               10.8.1.20 conn 3 ► Pod A
                                         (until timeoutSeconds of idle)
```

- Affinity is on **source IP only**. There are no cookies; this is Layer 4.
- Behind SNAT (NodePort with `externalTrafficPolicy: Cluster`, or a NAT gateway) every client shares one source IP and affinity collapses them onto a single Pod.
- The timeout is an **idle** timeout, refreshed by traffic.
- Removing an endpoint drops its affinity entries and those clients are rebalanced; setting affinity back to `None` clears the state.
- Real sticky sessions for HTTP belong at Layer 7: an Ingress controller with cookie affinity, or a service mesh.

---

## External Traffic Policy

`externalTrafficPolicy` applies to traffic entering through a **node port**, an **external IP** or a **load balancer**. It has no effect on ClusterIP traffic.

```yaml
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local     # Cluster (default) | Local
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Cluster (default)                                                       │
│    client 192.0.2.50 ──► NODE A :30080 (no local Pod)                    │
│                            SNAT src to 10.28.28.11  ◄── client IP LOST   │
│                            DNAT to a Pod anywhere ──► NODE B ──► Pod     │
│    ✅ every node is a valid entry point                                  │
│    ✅ even spread across all endpoints                                   │
│    ❌ original client IP lost, one extra hop                             │
│                                                                          │
│  Local                                                                   │
│    client 192.0.2.50 ──► NODE A :30080 (no local Pod) ► PACKET DROPPED   │
│    client 192.0.2.50 ──► NODE B :30080 (has local Pod)                   │
│                            DNAT only ──► Pod sees src = 192.0.2.50       │
│    ✅ true client source IP, no second hop                               │
│    ❌ endpoint-free nodes blackhole traffic, load is skewed              │
└──────────────────────────────────────────────────────────────────────────┘
```

### The Imbalance Problem

External load balancers usually spread connections evenly across **nodes**, not Pods, and with `Local` a node only forwards to its own Pods.

```
3 nodes, 4 Pods, LB sends 50% to each healthy node:
  NODE A: 1 Pod  ► 50% to 1 Pod  = 50.0% per Pod
  NODE B: 3 Pods ► 50% to 3 Pods = 16.7% per Pod
  NODE C: 0 Pods ► fails the health check, receives nothing

The Pod on Node A carries three times the load of each Pod on Node B.
Mitigate with topologySpreadConstraints, pod anti-affinity, or a DaemonSet.
```

### healthCheckNodePort

For `type: LoadBalancer` with `externalTrafficPolicy: Local`, Kubernetes allocates an extra node port used **only** for the load balancer's health check.

```bash
kubectl get svc web -o jsonpath='{.spec.healthCheckNodePort}{"\n"}'
# 32100

curl -s http://10.28.28.12:32100                                # node WITH endpoints: 200
curl -s -o /dev/null -w '%{http_code}\n' http://10.28.28.11:32100  # node WITHOUT: 503
```

```
  LB health check ► node:healthCheckNodePort
     200 ► node has at least one local ready endpoint ► keep in rotation
     503 ► node has zero local ready endpoints        ► remove from rotation

  If the external LB is NOT configured to use this port, Local WILL
  blackhole traffic on endpoint-free nodes.
```

It is allocated automatically, may be pinned, and is immutable once set. It exists **only** for LoadBalancer plus `Local`; a NodePort Service with `Local` gets no health check port, so whatever sits in front must avoid endpoint-free nodes by other means.

| Requirement | Setting |
|-------------|---------|
| Real client IP for audit, geo, rate limiting or allow lists | `Local` |
| Lowest latency for external traffic | `Local` |
| Few backend Pods, unevenly spread | `Cluster` |
| Front end runs as a DaemonSet on every node | `Local` is ideal |
| Simplicity and even distribution over client IP | `Cluster` |

---

## Internal Traffic Policy

The equivalent knob for **in cluster** traffic to the ClusterIP.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: node-agent
spec:
  selector:
    app: node-agent
  internalTrafficPolicy: Local     # Cluster (default) | Local
  ports:
  - port: 80
    targetPort: 8080
```

```
  Cluster (default): Pod on Node A dials the ClusterIP ► any endpoint, cluster wide
  Local:             Pod on Node A dials the ClusterIP ► ONLY endpoints on Node A
                     no local endpoint                ► connection DROPPED
                                                        (no remote fallback)
```

The canonical use is a node local DaemonSet: a logging agent, metrics collector, node local DNS cache or per node proxy. Every client talks to the agent on its own node, eliminating cross node traffic and keeping node scoped data on the right node.

> ⚠️ There is **no fallback**. If the DaemonSet Pod on a node is not ready, every client on that node fails. Pair it with a solid readiness probe and accept the failure domain, or stay with `Cluster`.

| | `internalTrafficPolicy` | `externalTrafficPolicy` |
|---|---|---|
| Applies to | ClusterIP traffic from inside | NodePort, LB and externalIP traffic |
| Values | `Cluster`, `Local` | `Cluster`, `Local` |
| Source IP effect | None, already preserved | `Local` preserves the external client IP |
| Health check port | None | `healthCheckNodePort` for LB plus `Local` |

---

## External IPs

`spec.externalIPs` tells kube-proxy to also match traffic destined to arbitrary IPs, for any Service type.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 8080
  externalIPs:
  - 203.0.113.10        # an IP that ALREADY routes to one or more nodes
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  YOU are responsible for making 203.0.113.10 arrive at a node:           │
│    routing, ARP, keepalived, an interface alias, upstream routers, ...   │
│  KUBERNETES is responsible for matching dst 203.0.113.10:80 once the     │
│    packet reaches a node and DNATing it to an endpoint.                  │
│  Nothing is allocated, nothing is advertised, no status is written.      │
└──────────────────────────────────────────────────────────────────────────┘
```

> ⚠️ Security: any user who can create Services can claim any address in `externalIPs`, including addresses belonging to other systems, and intercept traffic to them. Treat it as a privileged field and restrict it with admission policy.

`externalIPs` appear in the `EXTERNAL-IP` column of `kubectl get svc` alongside load balancer addresses, which sometimes makes people think an LB was provisioned.

---

## LoadBalancer Tuning Fields

### loadBalancerClass

```yaml
spec:
  type: LoadBalancer
  loadBalancerClass: metallb.universe.tf/metallb
```

Selects which implementation handles the Service when more than one could. If unset, the default implementation (typically the cloud controller manager) takes it. If set, only the controller claiming that class acts, and every other controller must ignore it, so a misspelled class leaves the Service `<pending>` forever with no error. The field may only be set on a `type: LoadBalancer` Service and cannot be modified while the Service remains that type. Use it when running MetalLB for internal VIPs alongside an appliance controller for public ones.

### allocateLoadBalancerNodePorts

```yaml
spec:
  type: LoadBalancer
  allocateLoadBalancerNodePorts: false
```

Defaults to `true`, giving every port of a LoadBalancer Service a node port as well. Set it to `false` when the load balancer sends traffic **directly to Pod IPs**, which conserves the node port range in clusters with hundreds of LoadBalancer Services and removes an unintended way in from any node. Setting it to `false` on an existing Service does not release already allocated node ports; you must also remove the `nodePort` values from `spec.ports`.

### loadBalancerSourceRanges

```yaml
spec:
  type: LoadBalancer
  loadBalancerSourceRanges:
  - 10.0.0.0/8
  - 203.0.113.0/24
```

Restricts which client CIDRs may reach the load balancer. **Enforcement is entirely up to the implementation**; cloud providers translate it into firewall or security group rules, while an implementation that ignores it silently gives you no protection, so verify rather than assume. An empty list means allow all. It filters at the load balancer only: the node port, if allocated, may still be open, so firewall it separately and add NetworkPolicy. With `externalTrafficPolicy: Cluster` and SNAT in the path, some implementations cannot apply it meaningfully at all.

---

## Dual Stack Services

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ipFamilyPolicy: RequireDualStack
  ipFamilies:
  - IPv6            # order matters: [0] is the primary family
  - IPv4
  ports:
  - port: 80
    targetPort: 8080
```

| `ipFamilyPolicy` | Behaviour |
|------------------|-----------|
| `SingleStack` | One family only. The default, even on a dual stack cluster. |
| `PreferDualStack` | Allocate both if the cluster supports it, silently fall back if not. |
| `RequireDualStack` | Allocate both. Creation **fails** on a single stack cluster. |

`ipFamilies` is ordered; the first entry is the **primary** family and determines `spec.clusterIP`.

```yaml
spec:
  clusterIP: fd00:10:96::a1b2          # always equals clusterIPs[0]
  clusterIPs:
  - fd00:10:96::a1b2                   # primary, matches ipFamilies[0]
  - 10.96.42.17                        # secondary
```

DNS publishes an A record and an AAAA record; the client's own address selection decides which is used. Kubernetes does not choose for it.

Rules and gotchas:

- The cluster must genuinely be dual stack: dual `--service-cluster-ip-range` and `--cluster-cidr` values across the control plane and kube-proxy, plus a CNI assigning dual stack Pod IPs.
- `spec.clusterIP` and `spec.clusterIPs[0]` must agree; inconsistent edits are rejected.
- You may convert `SingleStack` to `PreferDualStack` or `RequireDualStack` on an existing Service, which adds a secondary IP, and back again, which removes it.
- **You cannot change the primary family** of an existing Service. Reordering `ipFamilies` so that element 0 changes is rejected; delete and recreate.
- `type: ExternalName` ignores both fields entirely.
- Each family gets its **own** EndpointSlices, distinguished by `addressType`. A slice never mixes families.

```bash
kubectl get svc web -o jsonpath='{.spec.ipFamilies}{"\n"}{.spec.clusterIPs}{"\n"}'
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o custom-columns=NAME:.metadata.name,TYPE:.addressType
```

---

## Traffic Distribution and Topology Aware Routing

Cross zone traffic costs money and latency, so Kubernetes can bias Service routing toward endpoints close to the client.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Default: zone blind                                                     │
│    client in zone-a ─┬─► endpoint in zone-a  (free, fast)                │
│                      ├─► endpoint in zone-b  (cross zone, billed)        │
│                      └─► endpoint in zone-c  (cross zone, billed)        │
│                      each equally likely                                 │
│                                                                          │
│  Topology aware: zone preferring                                         │
│    client in zone-a ───► endpoints in zone-a, when there are enough      │
│                          of them to carry the expected load              │
│                                                                          │
│  If a zone is under-provisioned the control plane DECLINES to apply      │
│  hints and falls back to cluster wide routing. Safety over savings.      │
└──────────────────────────────────────────────────────────────────────────┘
```

The control plane does not change kube-proxy's algorithm directly; it writes **hints** into each EndpointSlice endpoint and kube-proxy filters on them:

```yaml
endpoints:
- addresses: ["10.8.1.55"]
  conditions:
    ready: true
  zone: zone-a
  hints:
    forZones:
    - name: zone-a          # kube-proxy in zone-a may use this endpoint
```

Two mechanisms exist and availability depends on your cluster version, so check first:

```bash
kubectl explain service.spec.trafficDistribution
```

```yaml
# Newer, explicit Service field
spec:
  trafficDistribution: PreferClose
---
# Older annotation driven mechanism
metadata:
  annotations:
    service.kubernetes.io/topology-mode: "Auto"
```

Caveats: nodes must carry `topology.kubernetes.io/zone` labels, endpoints must be spread across zones roughly in proportion to per zone CPU capacity or the heuristic silently declines, and with very few replicas losing one Pod can push a whole zone back to cluster wide routing. It is a **preference with a fallback**, not a guarantee, and it is unrelated to `internalTrafficPolicy: Local`, which is a hard restriction with no fallback at all.

---

## From Service Object to Datapath Rules

```
┌──────────────────────────────────────────────────────────────────────────┐
│  1. kubectl apply -f service.yaml                                        │
│  2. kube-apiserver validates and allocates the ClusterIP, nodePort and   │
│     healthCheckNodePort where applicable, then persists to etcd          │
│  3. The EndpointSlice controller watches Services and Pods, evaluates    │
│     the selector, and writes EndpointSlices with ready, serving and      │
│     terminating endpoint state                                           │
│         ├──────────────────────────────┐                                 │
│         ▼                              ▼                                 │
│  4a. kube-proxy on EVERY node     4b. CoreDNS watches Services and       │
│      watches Services and             EndpointSlices and serves A,       │
│      EndpointSlices                   AAAA, SRV, CNAME and PTR records   │
│         ▼                                                                │
│  5. kube-proxy programs the kernel:                                      │
│       iptables ► KUBE-SERVICES ► KUBE-SVC-xxx ► KUBE-SEP-xxx (DNAT)      │
│       IPVS     ► one virtual server per Service, real server per endpoint│
│       nftables / eBPF ► equivalent structures in newer datapaths         │
│  6. Packets to the ClusterIP are DNATed in the kernel on the client's    │
│     node, and conntrack reverses the translation on the return path      │
└──────────────────────────────────────────────────────────────────────────┘
```

```bash
sudo iptables -t nat -L KUBE-SERVICES -n | grep 10.96.42.17   # iptables mode
sudo ipvsadm -Ln | grep -A5 10.96.42.17                       # IPVS mode
```

> 📖 Proxy modes, chain by chain walkthroughs, conntrack behaviour and performance characteristics are all in [kube-proxy.md](kube-proxy.md). This document deliberately does not repeat them.

---

## Bare Metal LoadBalancer with MetalLB

On bare metal there is no cloud controller manager, so `type: LoadBalancer` stays `<pending>` until you install an implementation.

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: production
  namespace: metallb-system
spec:
  addresses:
  - 10.28.31.100-10.28.31.150
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: production
  namespace: metallb-system
spec:
  ipAddressPools:
  - production
---
apiVersion: v1
kind: Service
metadata:
  name: web
  annotations:
    metallb.io/address-pool: production
    metallb.io/loadBalancerIPs: 10.28.31.101
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 8080
```

Two headline facts: **Layer 2 mode is failover, not load balancing**, because one elected node answers ARP for the VIP and receives all of its traffic, bounding throughput at one node's capacity; and **BGP mode is real multi path**, because every speaker advertises the VIP and upstream routers ECMP across them, at the cost of needing routers that speak BGP.

> 📖 Layer 2 versus BGP, the double hop problem and production guidance are in [metallb.md](metallb.md); routing concepts are in [bgp.md](bgp.md) and [ecmp.md](ecmp.md).

---

## Troubleshooting

A field guide. The full ordered runbook lives in [service-operations.md](service-operations.md).

### EXTERNAL-IP Stuck in Pending

```bash
kubectl get svc web
# NAME  TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
# web   LoadBalancer   10.96.42.17   <pending>     80:31234/TCP   14m
```

In order of likelihood: no LB implementation is installed; MetalLB has no `IPAddressPool`, the pool is exhausted, or there is no advertisement object; `loadBalancerClass` names a controller that does not exist; the cloud controller manager is down or lacks permissions.

```bash
kubectl describe svc web | sed -n '/Events/,$p'
kubectl -n metallb-system logs deploy/controller --tail=50
```

### Service Has No Endpoints

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl get pods -l app=web -o wide --show-labels
```

The selector does not match the Pod labels, or no Pod is Ready.

### Connection Refused or Timeout Despite Endpoints

- `targetPort` does not match the port the process actually listens on.
- The process binds `127.0.0.1` instead of `0.0.0.0`, so it is reachable inside the container and nowhere else.
- A named `targetPort` does not exist in the Pod's `ports` list.
- A NetworkPolicy is dropping the connection.

```bash
kubectl exec -it deploy/web -- sh -c 'netstat -tlnp 2>/dev/null || ss -tlnp'
```

### DNS Name Does Not Resolve

```bash
kubectl run dns --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup web.prod.svc.cluster.local
```

Check CoreDNS health, the Pod's `/etc/resolv.conf`, and that the Service exists in the namespace you assumed.

### Traffic Reaches Some Nodes Only

Almost always `externalTrafficPolicy: Local` with Pods on a subset of nodes and an upstream balancer that ignores `healthCheckNodePort`.

### Source IP Is Always a Node IP

`externalTrafficPolicy: Cluster` is SNATing. Switch to `Local`, or terminate at Layer 7 and read `X-Forwarded-For`.

---

## Exam and Interview Traps

1. **`targetPort` defaults to `port`, not to the container's port.** Omitting it when the container listens elsewhere is the most common Service bug there is.
2. **`containerPort` is documentation.** A Service can target a port that was never declared, and removing the declaration breaks nothing.
3. **Service selectors are equality only.** Writing `selector: {matchLabels: {app: web}}` in a Service is wrong.
4. **A Service with no selector is legal** and still gets a ClusterIP; it simply has no endpoints until you supply them.
5. **`clusterIP` is immutable**, and **`clusterIP: None` cannot be toggled** on an existing Service.
6. **NodePort opens the port on every node**, including nodes running none of the Pods.
7. **A LoadBalancer Service still has a ClusterIP and, by default, a NodePort.** The types are cumulative.
8. **`EXTERNAL-IP: <pending>` never times out.** It waits forever for a controller that may not exist.
9. **ExternalName requires a DNS name**, performs **no port remapping** and involves kube-proxy not at all.
10. **Headless Services do not load balance.** The client picks from the returned A records, and many pick the first every time.
11. **StatefulSet per Pod DNS requires a headless Service named in `spec.serviceName`.**
12. **`publishNotReadyAddresses` is a Service field**, not a StatefulSet field.
13. **Environment variable discovery requires the Service to exist before the Pod**, and is never updated afterwards.
14. **`enableServiceLinks: false` disables env injection**, but `KUBERNETES_SERVICE_HOST` is always injected.
15. **`sessionAffinity: ClientIP` is source IP based only** and collapses entirely behind SNAT.
16. **`externalTrafficPolicy: Local` drops traffic on nodes with no local ready endpoint**; it does not forward it onward.
17. **`healthCheckNodePort` exists only for LoadBalancer plus `Local`**, never for NodePort plus `Local`.
18. **`internalTrafficPolicy: Local` has no fallback either.** No local endpoint means failure, not a remote hop.
19. **`externalIPs` are unmanaged and privileged.** Kubernetes matches the packets, you must deliver them.
20. **`loadBalancerSourceRanges` is only as real as the implementation makes it.**
21. **`allocateLoadBalancerNodePorts: false` does not free existing node ports** unless you also clear the `nodePort` values.
22. **The primary IP family of a dual stack Service cannot be changed** after creation.
23. **The `kubernetes` Service in `default` has no selector** and is reconciled by the API server, not by the EndpointSlice controller.
24. **Named ports are resolved per Pod**, so replicas may listen on different numbers.
25. **Multi port Services require a `name` on every port**, and `port: 53` twice is legal when the protocols differ.
26. **A Service cannot route by path or hostname.** That is Ingress or Gateway API.

---

## Related Topics

- [kube-proxy](kube-proxy.md)
- [EndpointSlices](endpointslices.md)
- [Service Operations](service-operations.md)
- [CoreDNS](coredns.md)
- [MetalLB](metallb.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
- [Network Policy](network-policy.md)
- [Pods](pods.md)
- [Deployments](deployments.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [CNI](cni.md)
- [NAT](nat.md)
- [BGP](bgp.md)
- [ECMP](ecmp.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)

---

## Key Takeaways

1. Services exist because **Pod IPs are ephemeral**. A Service supplies a stable name, a stable virtual IP, readiness aware membership and Layer 4 load balancing.
2. The ClusterIP is **virtual and immutable**: no interface owns it, and it exists only as kernel rules that kube-proxy programs on every node.
3. Service selectors are **equality only** and match Pods in the **same namespace**; there is no set based syntax here.
4. `port` is on the VIP, `targetPort` is on the Pod, `nodePort` is on every node, `containerPort` is documentation, and **`targetPort` defaults to `port`**, which causes more outages than any other Service detail.
5. Named `targetPort` values resolve **per Pod**, letting replicas listen on different numbers during a migration; a missing name yields a selected Pod with no endpoint port and silent failure.
6. `name` is **mandatory** on every entry of a multi port Service, and each named port produces its own SRV record and its own node port.
7. The types are cumulative, while **ExternalName and headless sit outside the hierarchy** and create no kube-proxy rules at all.
8. **Headless Services return Pod A records**, move balancing to the client, and give StatefulSet Pods their per Pod DNS names through `spec.serviceName`.
9. **Selectorless Services with manually written EndpointSlices** are the clean way to give an external database a cluster local name with real port remapping and load balancing.
10. The `kubernetes` Service in `default` is selectorless and reconciled by the **API server's endpoint reconciler**, which is why it works before any controller starts.
11. DNS is the discovery mechanism that scales; **environment variable injection requires the Service to exist first**, is never updated, and is worth disabling with `enableServiceLinks: false`.
12. `ndots:5` makes short names cost several queries, so fully qualify hot external names with a trailing dot.
13. `sessionAffinity: ClientIP` pins by **source IP only** and collapses entirely behind SNAT.
14. `externalTrafficPolicy: Local` preserves the real client IP and removes a hop, but **blackholes traffic on endpoint-free nodes** and skews load; `healthCheckNodePort` is what keeps an external LB honest about that.
15. `internalTrafficPolicy: Local` is a hard node local restriction **with no fallback**, ideal for per node DaemonSet agents.
16. `externalIPs`, `loadBalancerClass`, `allocateLoadBalancerNodePorts` and `loadBalancerSourceRanges` are all **unmanaged or implementation dependent**: verify the behaviour on your platform instead of assuming it.
17. Dual stack is controlled by `ipFamilyPolicy` and the ordered `ipFamilies`; the **primary family is immutable** and each family gets its own EndpointSlices.
18. Topology aware routing and `trafficDistribution` are **preferences with safety fallbacks**, dependent on zone labels and balanced endpoint spread.
19. A Service is pure Layer 4. Paths, hostnames, TLS termination and headers belong to Ingress, Gateway API or a service mesh.

---

## References

- [Service concept](https://kubernetes.io/docs/concepts/services-networking/service/)
- [Service API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/)
- [Connecting Applications with Services](https://kubernetes.io/docs/tutorials/services/connect-applications-service/)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Headless Services](https://kubernetes.io/docs/concepts/services-networking/service/#headless-services)
- [Services without selectors](https://kubernetes.io/docs/concepts/services-networking/service/#services-without-selectors)
- [Type NodePort](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport)
- [Type LoadBalancer](https://kubernetes.io/docs/concepts/services-networking/service/#loadbalancer)
- [Type ExternalName](https://kubernetes.io/docs/concepts/services-networking/service/#externalname)
- [Service Traffic Policies](https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/)
- [Using Source IP](https://kubernetes.io/docs/tutorials/services/source-ip/)
- [Topology Aware Routing](https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/)
- [IPv4/IPv6 dual-stack](https://kubernetes.io/docs/concepts/services-networking/dual-stack/)
- [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
- [Virtual IPs and Service Proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/)
- [Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
- [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/)
