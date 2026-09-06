# 🚪 Kubernetes Ingress

Ingress is the Kubernetes API for HTTP and HTTPS routing at the edge of the cluster, letting one load balancer IP serve many hostnames, many paths and many TLS certificates instead of paying for one cloud load balancer per Service.

> **Reference**: [Kubernetes Ingress Documentation](https://kubernetes.io/docs/concepts/services-networking/ingress/)

---

## 📋 Table of Contents

1. [The L7 Problem Ingress Solves](#the-l7-problem-ingress-solves)
2. [The API Object vs The Controller](#the-api-object-vs-the-controller)
3. [How an Ingress Controller Actually Works](#how-an-ingress-controller-actually-works)
4. [Anatomy of an Ingress Manifest](#anatomy-of-an-ingress-manifest)
5. [Path Matching and pathType](#path-matching-and-pathtype)
6. [Host Based Routing and Wildcards](#host-based-routing-and-wildcards)
7. [The Default Backend](#the-default-backend)
8. [IngressClass and Controller Selection](#ingressclass-and-controller-selection)
9. [TLS Termination](#tls-termination)
10. [Automated Certificates with cert-manager](#automated-certificates-with-cert-manager)
11. [Routing Patterns](#routing-patterns)
12. [Exposing the Controller on Bare Metal](#exposing-the-controller-on-bare-metal)
13. [Rewrites and Redirects](#rewrites-and-redirects)
14. [Common ingress-nginx Annotations](#common-ingress-nginx-annotations)
15. [Ingress Controller Comparison](#ingress-controller-comparison)
16. [Why Ingress Stalled as an API](#why-ingress-stalled-as-an-api)
17. [Troubleshooting](#troubleshooting)
18. [Exam and Interview Traps](#exam-and-interview-traps)
19. [Related Topics](#related-topics)
20. [Key Takeaways](#key-takeaways)
21. [References](#references)

---

## The L7 Problem Ingress Solves

### What You Have Without Ingress

Kubernetes gives you three ways to expose a Service to the outside world, and all three operate at Layer 4 (TCP/UDP), not Layer 7 (HTTP).

| Type | How it exposes | Layer | Problem |
|------|----------------|-------|---------|
| **ClusterIP** | Internal virtual IP only | L4 | Not reachable from outside the cluster |
| **NodePort** | Port 30000 to 32767 on every node | L4 | Ugly ports, no TLS, no hostname routing, one port per Service |
| **LoadBalancer** | External IP from a cloud LB or MetalLB | L4 | One load balancer and one IP per Service |

### The Cost and Capability Wall

```
┌────────────────────────────────────────────────────────────────────┐
│          10 microservices exposed with LoadBalancer Services        │
│                                                                     │
│   LB #1  203.0.113.10 ──► svc/api        (billed separately)       │
│   LB #2  203.0.113.11 ──► svc/web        (billed separately)       │
│   LB #3  203.0.113.12 ──► svc/auth       (billed separately)       │
│   LB #4  203.0.113.13 ──► svc/orders     (billed separately)       │
│   LB #5  203.0.113.14 ──► svc/payments   (billed separately)       │
│   ...                                                               │
│   LB #10 203.0.113.19 ──► svc/reports    (billed separately)       │
│                                                                     │
│   Result:                                                           │
│     • 10 public IPs to buy, firewall and document                  │
│     • 10 cloud load balancers to pay for, monthly                  │
│     • 10 DNS A records                                             │
│     • 10 places to install and rotate a TLS certificate            │
│     • Zero HTTP awareness: no path routing, no host routing,       │
│       no redirects, no header manipulation, no shared certs        │
└────────────────────────────────────────────────────────────────────┘
```

A LoadBalancer Service forwards packets. It cannot read the `Host:` header, it cannot read the request path, and it cannot terminate TLS for you in a way Kubernetes manages.

### What Ingress Gives You Instead

```
┌────────────────────────────────────────────────────────────────────┐
│          10 microservices exposed behind one Ingress controller     │
│                                                                     │
│                     ONE LoadBalancer IP                             │
│                       203.0.113.10                                  │
│                            │                                        │
│                            ▼                                        │
│              ┌──────────────────────────────┐                       │
│              │   Ingress Controller Pods    │                       │
│              │   (reverse proxy, L7 aware)  │                       │
│              │   terminates TLS, reads      │                       │
│              │   Host: and path             │                       │
│              └──────────────┬───────────────┘                       │
│                             │                                       │
│   Host: api.example.com     ├──► pods of svc/api                    │
│   Host: www.example.com /   ├──► pods of svc/web                    │
│   Host: www.example.com     │                                       │
│         /auth               ├──► pods of svc/auth                   │
│   Host: shop.example.com    ├──► pods of svc/orders                 │
│   ...                       └──► pods of svc/reports                │
│                                                                     │
│   Result: 1 IP, 1 load balancer bill, 1 DNS wildcard,              │
│           certificates managed as Kubernetes Secrets                │
└────────────────────────────────────────────────────────────────────┘
```

### The Layer 7 Capabilities You Unlock

- **Name based virtual hosting**: many hostnames on one IP, distinguished by the HTTP `Host` header and by TLS SNI.
- **Path based fanout**: `/api` to one Service, `/static` to another.
- **TLS termination**: certificates stored as Kubernetes Secrets, hot reloaded, selected per hostname via SNI.
- **HTTP semantics**: redirects, rewrites, header injection, request size limits, timeouts, sticky sessions, basic auth, rate limiting.
- **Health aware proxying**: the proxy tracks live endpoints and stops sending traffic to terminating pods.

---

## The API Object vs The Controller

This is the single most misunderstood point about Ingress, and it is the most common exam question.

```
┌────────────────────────────────────────────────────────────────────┐
│                   TWO COMPLETELY SEPARATE THINGS                    │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. The Ingress OBJECT                                             │
│     apiVersion: networking.k8s.io/v1, kind: Ingress                │
│     A piece of declarative data stored in etcd.                    │
│     Built into every Kubernetes cluster.                           │
│     It routes NOTHING. It is a wish, not an action.                │
│                                                                     │
│  2. The Ingress CONTROLLER                                         │
│     A Deployment or DaemonSet of proxy pods you install yourself.  │
│     NOT shipped with Kubernetes. NOT started by kube-controller-    │
│     manager. There is no default.                                  │
│     It watches Ingress objects and turns them into real proxy      │
│     configuration.                                                 │
│                                                                     │
│  NO CONTROLLER INSTALLED  ==>  kubectl apply -f ingress.yaml       │
│                                succeeds, ADDRESS stays empty,      │
│                                nothing is ever routed.             │
└────────────────────────────────────────────────────────────────────┘
```

`kube-controller-manager` runs the built in controllers for Deployments, ReplicaSets, Jobs and so on (see [kube-controller-manager.md](kube-controller-manager.md)), but it deliberately does **not** run an Ingress controller. Ingress is one of the very few core Kubernetes APIs whose controller is out of tree by design.

### Proving It To Yourself

```bash
# Does the cluster have any ingress controller at all?
kubectl get ingressclass

# No resources found  ==>  no controller, your Ingress objects are inert

# An Ingress with no controller looks like this forever:
kubectl get ingress -A
# NAME        CLASS   HOSTS              ADDRESS   PORTS   AGE
# web-app     nginx   web.example.com              80      14m
#                                        ^^^^^^^
#                                        empty ADDRESS is the symptom
```

The `ADDRESS` column is populated by the controller writing to `status.loadBalancer.ingress[]` on the Ingress object. If it stays empty, either no controller exists, or no controller has claimed this Ingress (see [IngressClass and Controller Selection](#ingressclass-and-controller-selection)).

### Where the Controller Comes From

```bash
# The repository owner's working install script:
#   k8s-workshop/ingress-nginx/setup-ingress-inginx-for-metlallb.sh
kubectl create namespace ingress-nginx
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p '{"spec": {"type": "LoadBalancer"}}'
```

That script installs the bare metal manifest (which creates a NodePort Service) and then flips the Service to `LoadBalancer` so that MetalLB assigns it a real external IP. See [Exposing the Controller on Bare Metal](#exposing-the-controller-on-bare-metal).

---

## How an Ingress Controller Actually Works

### The Reconciliation Loop

```
┌────────────────────────────────────────────────────────────────────┐
│                ingress-nginx control loop (simplified)              │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  WATCH via the Kubernetes API (see k8s-api.md)                │  │
│  │    • Ingress objects (filtered by ingressClassName)           │  │
│  │    • IngressClass objects                                     │  │
│  │    • Services, EndpointSlices                                 │  │
│  │    • Secrets referenced by spec.tls                           │  │
│  │    • The controller ConfigMap                                 │  │
│  └───────────────────────────┬──────────────────────────────────┘  │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  BUILD an in-memory model                                     │  │
│  │    servers[]  = one per unique host (nginx server block)      │  │
│  │    locations[]= one per path (nginx location block)           │  │
│  │    upstreams[]= one per Service+port, filled with POD IPs     │  │
│  └───────────────────────────┬──────────────────────────────────┘  │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  RENDER the Go template nginx.tmpl  ->  /etc/nginx/nginx.conf │  │
│  └───────────────────────────┬──────────────────────────────────┘  │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  DECIDE: structural change or endpoint-only change?           │  │
│  │                                                               │  │
│  │   New host / new path / changed annotation / new cert         │  │
│  │        -> write nginx.conf and RELOAD nginx                   │  │
│  │                                                               │  │
│  │   Pod scaled, pod restarted, endpoint added or removed        │  │
│  │        -> push the new endpoint list into the Lua shared      │  │
│  │           dictionary over the controller's internal HTTP      │  │
│  │           endpoint, NO reload at all                          │  │
│  └───────────────────────────┬──────────────────────────────────┘  │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  WRITE STATUS back: status.loadBalancer.ingress[] on every    │  │
│  │  Ingress it owns, taken from the Service named by             │  │
│  │  --publish-service                                            │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

The dynamic endpoint update path matters in production: a Deployment rollout that replaces 50 pods does not cause 50 nginx reloads, which would otherwise drop keepalive connections and spike memory.

### The Data Path Bypasses the Service ClusterIP

This surprises almost everyone.

```
┌────────────────────────────────────────────────────────────────────┐
│           What people THINK happens                                 │
│                                                                     │
│   Client ──► Controller Pod ──► Service ClusterIP ──► kube-proxy    │
│                                 10.96.14.7           DNAT rules     │
│                                                       │             │
│                                                       ▼             │
│                                                    Pod 10.244.1.9   │
├────────────────────────────────────────────────────────────────────┤
│           What ACTUALLY happens (ingress-nginx default)             │
│                                                                     │
│   Client ──► Controller Pod ──► Pod IP directly                     │
│                    │             10.244.1.9:8080                    │
│                    │             10.244.2.4:8080                    │
│                    │             10.244.3.7:8080                    │
│                    │                                                │
│                    └── upstream list built from EndpointSlices,     │
│                        load balanced inside nginx (round robin,     │
│                        ewma, or consistent hashing)                 │
│                                                                     │
│   The ClusterIP and kube-proxy are NEVER touched on this path.      │
└────────────────────────────────────────────────────────────────────┘
```

Consequences you must internalise:

1. **The Service is used only for discovery**, to find the port name and the EndpointSlices. Its ClusterIP is not on the data path.
2. **`sessionAffinity: ClientIP` on the Service does nothing** for Ingress traffic. Use the controller's own affinity annotations instead.
3. **NetworkPolicy must allow the controller pods to reach your application pods directly**, pod to pod. A policy that only allows the Service CIDR will silently break Ingress. See [network-policy.md](network-policy.md).
4. **Load balancing quality is better**: nginx sees real per-endpoint latency and can use least-connections style algorithms instead of kube-proxy's random or round robin DNAT.
5. **`headless` Services still work** for discovery because EndpointSlices exist regardless of ClusterIP.

If you genuinely need traffic to go through the ClusterIP (for example because a service mesh sidecar must intercept it), ingress-nginx offers `nginx.ingress.kubernetes.io/service-upstream: "true"`.

### Inspecting the Generated Configuration

```bash
# Find the controller pod
kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller

# Read the rendered nginx.conf
kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- cat /etc/nginx/nginx.conf

# Just the server blocks and their locations
kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
  cat /etc/nginx/nginx.conf | grep -E 'server_name|location|proxy_pass'

# Live logs, one line per request
kubectl -n ingress-nginx logs -f deploy/ingress-nginx-controller

# Health and Prometheus metrics are served on port 10254 inside the pod
kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- curl -s localhost:10254/healthz

# With the krew plugin installed (kubectl krew install ingress-nginx)
kubectl ingress-nginx backends -n ingress-nginx     # live upstream/endpoint table
kubectl ingress-nginx conf -n ingress-nginx         # the generated config
kubectl ingress-nginx ingresses -n ingress-nginx    # every Ingress the controller sees
```

---

## Anatomy of an Ingress Manifest

Every field, annotated.

```yaml
apiVersion: networking.k8s.io/v1        # GA since Kubernetes 1.19. extensions/v1beta1
                                        # and networking.k8s.io/v1beta1 are REMOVED.
kind: Ingress
metadata:
  name: shop-ingress
  namespace: web                        # NAMESPACED. It can only reference Services
                                        # and Secrets in THIS namespace.
  annotations:
    # Controller specific behaviour lives here. These are NOT part of the
    # Ingress API, they are strings the controller happens to understand.
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"

spec:
  # ------------------------------------------------------------------
  # WHICH CONTROLLER owns this object. Replaces the old
  # kubernetes.io/ingress.class annotation.
  # ------------------------------------------------------------------
  ingressClassName: nginx               # must match an existing IngressClass name

  # ------------------------------------------------------------------
  # TLS: which hostnames get which certificate.
  # ------------------------------------------------------------------
  tls:
  - hosts:                              # must match the hosts in rules below
    - shop.example.com
    - www.shop.example.com
    secretName: shop-tls                # Secret of type kubernetes.io/tls,
                                        # in namespace "web", same as this Ingress

  # ------------------------------------------------------------------
  # Fallback when nothing in rules matches. Optional.
  # ------------------------------------------------------------------
  defaultBackend:
    service:
      name: fallback-page
      port:
        number: 80

  # ------------------------------------------------------------------
  # The routing table. A list of host rules, each with a list of paths.
  # ------------------------------------------------------------------
  rules:
  - host: shop.example.com              # optional. Omit it to match ANY Host header.
                                        # Wildcards allowed: "*.example.com"
    http:
      paths:
      - path: /api                      # must start with / when pathType is
                                        # Exact or Prefix
        pathType: Prefix                # Exact | Prefix | ImplementationSpecific
                                        # REQUIRED field, no default
        backend:
          service:                      # EITHER service ...
            name: api-svc               # Service name in THIS namespace
            port:
              number: 8080              # use number: OR name:, never both
              # name: http              # the Service port NAME, often nicer

      - path: /static
        pathType: Prefix
        backend:
          service:
            name: static-svc
            port:
              name: http

      - path: /healthz
        pathType: Exact
        backend:
          resource:                     # ... OR resource (mutually exclusive
            apiGroup: k8s.example.com   # with service). Used by controllers that
            kind: StorageBucket         # can serve non-Service backends.
            name: static-assets

status:                                 # written by the CONTROLLER, never by you
  loadBalancer:
    ingress:
    - ip: 192.168.1.240
```

### Field Rules That Bite

| Rule | Consequence if violated |
|------|-------------------------|
| `pathType` is required | API server rejects the object |
| `backend.service` and `backend.resource` are mutually exclusive | API server rejects the object |
| `port.number` and `port.name` are mutually exclusive | API server rejects the object |
| Service must be in the same namespace as the Ingress | Backend resolves to nothing, 503 |
| TLS Secret must be in the same namespace as the Ingress | Controller serves its own fake certificate |
| Only ports 80 and 443 are addressable at the edge | You cannot expose port 8443 through an Ingress |
| HTTP only (plus HTTPS) | No raw TCP, no UDP, no arbitrary protocols |

### The Minimal Valid Ingress

The repository owner's working example, from `k8s-workshop/ingress-nginx/web-app-nginx-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-app-nginx-ingress
spec:
  ingressClassName: nginx    # must match the IngressClass name
  rules:
  - host: web-app-nginx.__DOMAIN__
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-app-nginx
            port:
              number: 80
```

Paired with `k8s-workshop/ingress-nginx/test-web-app-nginx.yaml`, which supplies the Deployment and the ClusterIP Service that this Ingress points at.

### Imperative Shortcut

```bash
kubectl create ingress shop \
  --class=nginx \
  --rule="shop.example.com/api*=api-svc:8080" \
  --rule="shop.example.com/*=web-svc:80,tls=shop-tls" \
  --dry-run=client -o yaml
```

The trailing `*` in the rule string produces `pathType: Prefix`; without it you get `pathType: Exact`. See [imperative-kubernetes.md](imperative-kubernetes.md).

---

## Path Matching and pathType

`pathType` is a required field with three legal values, and the difference between them decides whether your requests reach your app.

### The Three Types

| pathType | Semantics | Case sensitive | Regex allowed |
|----------|-----------|----------------|---------------|
| **Exact** | The URL path must equal the value, byte for byte | Yes | No |
| **Prefix** | Split both paths on `/` and compare **element by element** | Yes | No |
| **ImplementationSpecific** | Whatever the controller decides; ingress-nginx treats it as an nginx regex/location | Controller defined | Yes, for ingress-nginx |

### The Element Boundary Rule

`Prefix` is **not** a string prefix. Both the rule path and the request path are split on `/` into elements, and every element of the rule must equal the corresponding element of the request.

```
Rule:    /aaa/bbb   ->  elements: [ "aaa", "bbb" ]
Request: /aaa/bbbxyz ->  elements: [ "aaa", "bbbxyz" ]

Element 2: "bbb" != "bbbxyz"   ==>  NO MATCH

A naive string prefix check would have matched. Kubernetes does not.
```

Trailing slashes on the rule path are ignored.

### Precise Matching Table

| pathType | Rule path | Request path | Match | Why |
|----------|-----------|--------------|:-----:|-----|
| Prefix | `/` | anything | ✅ | The root prefix matches every request |
| Prefix | `/aaa` | `/aaa` | ✅ | Exact element list |
| Prefix | `/aaa` | `/aaa/` | ✅ | Trailing slash on the request is fine |
| Prefix | `/aaa/` | `/aaa` | ✅ | Trailing slash on the rule is ignored |
| Prefix | `/aaa` | `/aaa/bbb` | ✅ | Subpath under the prefix |
| Prefix | `/aaa` | `/aaabbb` | ❌ | `aaa` != `aaabbb`, element boundary |
| Prefix | `/aaa/bbb` | `/aaa/bbb` | ✅ | All elements equal |
| Prefix | `/aaa/bbb` | `/aaa/bbbxyz` | ❌ | Element boundary |
| Prefix | `/aaa/bbb` | `/aaa/bbb/` | ✅ | Trailing slash ignored |
| Prefix | `/aaa/bbb/` | `/aaa/bbb` | ✅ | Trailing slash on rule ignored |
| Prefix | `/aaa/bbb` | `/aaa/bbb/ccc` | ✅ | Deeper subpath |
| Prefix | `/aaa/bbb` | `/aaa/bbbb` | ❌ | Element boundary |
| Prefix | `/aaa/bbb` | `/aaa` | ❌ | Request is shorter than the rule |
| Exact | `/foo` | `/foo` | ✅ | Byte identical |
| Exact | `/foo` | `/foo/` | ❌ | Trailing slash makes it a different path |
| Exact | `/foo/` | `/foo` | ❌ | Trailing slash makes it a different path |
| Exact | `/foo` | `/Foo` | ❌ | Path matching is case sensitive |
| Exact | `/foo` | `/foo/bar` | ❌ | Exact means exact, no subpaths |
| Exact | `/foo` | `/foo?x=1` | ✅ | The query string is not part of the path |

### Precedence When Several Paths Match

```
┌────────────────────────────────────────────────────────────────────┐
│                    Path selection algorithm                         │
│                                                                     │
│  1. Select the matching host rule (see host precedence below)       │
│  2. Among matching paths in that rule:                              │
│         a. LONGEST matching path wins                               │
│         b. If two paths are the same length,                        │
│            Exact beats Prefix                                       │
│  3. If nothing matches, use spec.defaultBackend                     │
│  4. If there is no defaultBackend, the controller's own             │
│     default backend answers (ingress-nginx: 404)                    │
└────────────────────────────────────────────────────────────────────┘
```

### Worked Example

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-precedence-demo
  namespace: web
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /                       # catch all
        pathType: Prefix
        backend:
          service: { name: web-svc,     port: { number: 80 } }
      - path: /api                    # everything under /api
        pathType: Prefix
        backend:
          service: { name: api-svc,     port: { number: 8080 } }
      - path: /api/v2                 # longer, so it wins over /api
        pathType: Prefix
        backend:
          service: { name: api-v2-svc,  port: { number: 8080 } }
      - path: /api/v2/health          # Exact, same length as a Prefix would be
        pathType: Exact
        backend:
          service: { name: health-svc,  port: { number: 80 } }
```

Resulting routing:

| Request | Wins | Reason |
|---------|------|--------|
| `/` | `web-svc` | Only `/` matches |
| `/login` | `web-svc` | Only `/` matches |
| `/api` | `api-svc` | `/api` is longer than `/` |
| `/api/v1/users` | `api-svc` | `/api/v2` does not match |
| `/api/v2/users` | `api-v2-svc` | `/api/v2` is longer than `/api` |
| `/api/v2/health` | `health-svc` | Same length as the Prefix rule, Exact wins |
| `/api/v2/health/` | `api-v2-svc` | Exact rejects the trailing slash, falls back |
| `/apiary` | `web-svc` | `/api` fails the element boundary rule |

That second to last row is the classic production bug: a health check that works from `curl /api/v2/health` and 404s from a monitoring tool that appends a slash.

### ImplementationSpecific and Regex

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: regex-demo
  namespace: web
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /users/[0-9]+/profile
        pathType: ImplementationSpecific   # regex requires this (or use-regex)
        backend:
          service: { name: profile-svc, port: { number: 80 } }
```

`ImplementationSpecific` is the escape hatch, and it is also a portability trap: the same manifest moved from ingress-nginx to Contour or Traefik may behave completely differently or be rejected outright.

---

## Host Based Routing and Wildcards

### Host Matching Rules

- The controller compares the rule `host` against the HTTP `Host` header (and, for HTTPS, against the TLS SNI server name).
- Host matching is **case insensitive** (DNS names are), unlike path matching.
- The port is stripped from the `Host` header before comparison.
- A rule with **no** `host` field matches **every** hostname. It becomes the catch all server block.

### Wildcard Hosts

```yaml
rules:
- host: "*.example.com"        # must be quoted in YAML, * starts an alias otherwise
  http:
    paths:
    - path: /
      pathType: Prefix
      backend:
        service: { name: tenant-router, port: { number: 80 } }
```

**The wildcard covers exactly one DNS label, and it must be the leftmost label.**

| Rule host | Request Host | Match | Why |
|-----------|--------------|:-----:|-----|
| `*.example.com` | `foo.example.com` | ✅ | One label substituted |
| `*.example.com` | `bar.example.com` | ✅ | One label substituted |
| `*.example.com` | `foo.bar.example.com` | ❌ | Two labels, wildcard covers only one |
| `*.example.com` | `example.com` | ❌ | Wildcard requires a label to be present |
| `*.example.com` | `FOO.EXAMPLE.COM` | ✅ | Host matching is case insensitive |
| `foo.*.com` | `foo.bar.com` | ❌ | Wildcard must be the first label |
| `*.*.example.com` | `a.b.example.com` | ❌ | Only one wildcard label is allowed |
| (no host) | anything | ✅ | Catch all |

### Precedence Between Host Rules

```
Exact host        beats   wildcard host   beats   no host (catch all)

  api.example.com    >     *.example.com    >     (rule with no host)
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: host-precedence
  namespace: web
spec:
  ingressClassName: nginx
  rules:
  - host: api.example.com          # 1st: exact match wins for api.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: api-svc, port: { number: 8080 } }
  - host: "*.example.com"          # 2nd: everything else *.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: tenant-svc, port: { number: 80 } }
  - http:                          # 3rd: no host, absolute catch all
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: parking-page, port: { number: 80 } }
```

### Testing Host Routing Without DNS

```bash
LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Force the Host header, no DNS needed
curl -H "Host: api.example.com" http://$LB_IP/

# For HTTPS you must also fake SNI, --resolve does both at once
curl -k --resolve api.example.com:443:$LB_IP https://api.example.com/

# Wrong way: this sends Host: <IP> and hits the catch all instead
curl http://$LB_IP/
```

---

## The Default Backend

### Two Different Default Backends

```
┌────────────────────────────────────────────────────────────────────┐
│  1. spec.defaultBackend on ONE Ingress object                       │
│     Applies when a request reaches THIS Ingress's rules             │
│     and no path matches.                                            │
│                                                                     │
│  2. The CONTROLLER's global default backend                         │
│     A flag on the controller Deployment                             │
│     (ingress-nginx: --default-backend-service).                     │
│     Applies when NO Ingress matches at all.                         │
│     Built in behaviour: return 404 with the body                    │
│     "default backend - 404".                                        │
└────────────────────────────────────────────────────────────────────┘
```

### Per Ingress Default Backend

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: with-default-backend
  namespace: web
spec:
  ingressClassName: nginx
  defaultBackend:
    service:
      name: friendly-404
      port:
        number: 80
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service: { name: api-svc, port: { number: 8080 } }
```

A request to `app.example.com/anything-else` goes to `friendly-404` instead of the controller's blunt 404 page.

### An Ingress With Only a Default Backend

Perfectly legal, and useful as a single service catch all:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: catch-everything
  namespace: web
spec:
  ingressClassName: nginx
  defaultBackend:
    service:
      name: monolith
      port:
        number: 8080
```

---

## IngressClass and Controller Selection

### Why It Exists

Clusters routinely run more than one controller: an internal only ingress-nginx for private traffic and a second one exposed publicly, or ingress-nginx alongside a Traefik installation. Without a class marker every controller would claim every Ingress and route the same hostname twice.

### The IngressClass Resource

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx                                    # the string used in ingressClassName
  annotations:
    # At most ONE IngressClass in the cluster should carry this.
    # Ingresses with NO ingressClassName and NO deprecated annotation
    # get assigned to this class by an admission plugin at creation time.
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: k8s.io/ingress-nginx               # IMMUTABLE. Identifies which
                                                 # controller implementation
                                                 # should watch this class.
  parameters:                                    # optional, controller defined
    apiGroup: k8s.example.com
    kind: IngressParameters
    name: external-lb
    scope: Namespace                             # Cluster | Namespace
    namespace: ingress-nginx                     # required when scope: Namespace
```

`IngressClass` is **cluster scoped**. `spec.controller` is immutable after creation; to change it you delete and recreate.

### Three Ways an Ingress Gets Claimed

```
┌────────────────────────────────────────────────────────────────────┐
│  ① spec.ingressClassName: nginx           ← CORRECT, current API   │
│     Typed field, validated, works everywhere.                       │
│                                                                     │
│  ② metadata.annotations:                  ← DEPRECATED             │
│       kubernetes.io/ingress.class: nginx                            │
│     Predates IngressClass. Still honoured by ingress-nginx and      │
│     several other controllers for backward compatibility, but it    │
│     is not part of the API, is not validated, and should not be     │
│     used in new manifests.                                          │
│                                                                     │
│  ③ Neither is set                                                   │
│     • If an IngressClass carries                                    │
│       ingressclass.kubernetes.io/is-default-class: "true", the      │
│       API server stamps that class onto the Ingress at admission.   │
│     • Otherwise the Ingress belongs to no class and is ignored by   │
│       every well behaved controller. ADDRESS stays empty.           │
└────────────────────────────────────────────────────────────────────┘
```

### Precedence Between the Two

If both the annotation and the field are present, `ingress-nginx` prefers the **annotation** for historical reasons. Never set both; you will get behaviour that differs between controllers.

### Inspecting and Setting the Default

```bash
# What classes exist and who implements them?
kubectl get ingressclass -o custom-columns=\
'NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class'

# Make nginx the cluster default
kubectl annotate ingressclass nginx \
  ingressclass.kubernetes.io/is-default-class="true" --overwrite

# Remove the default marker from another class
kubectl annotate ingressclass traefik \
  ingressclass.kubernetes.io/is-default-class-

# Which class did an existing Ingress end up with?
kubectl get ingress -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName'
```

> ⚠️ The default class is applied **only at creation time**. Annotating an IngressClass as default does not retroactively fix Ingress objects that already exist with an empty `ingressClassName`.

### Controller Side Flags (ingress-nginx)

| Flag | Purpose |
|------|---------|
| `--ingress-class` | The IngressClass **name** this controller instance answers to |
| `--controller-class` | The `spec.controller` value it matches on, default `k8s.io/ingress-nginx` |
| `--watch-ingress-without-class` | Also pick up Ingresses that have no class at all |
| `--publish-service` | The Service whose external IP is copied into every Ingress `status` |
| `--default-backend-service` | Global fallback backend |
| `--enable-ssl-passthrough` | Enable TLS passthrough support (adds a TCP pre-read layer) |

---

## TLS Termination

### The Model

```
┌────────────────────────────────────────────────────────────────────┐
│                         TLS Termination                             │
│                                                                     │
│   Browser                Controller Pod              App Pod        │
│      │                        │                         │           │
│      │  1. TCP connect :443   │                         │           │
│      ├───────────────────────►│                         │           │
│      │                        │                         │           │
│      │  2. ClientHello        │                         │           │
│      │     SNI: shop.example.com                        │           │
│      ├───────────────────────►│                         │           │
│      │                        │ 3. Look up which        │           │
│      │                        │    Secret serves that   │           │
│      │                        │    SNI name             │           │
│      │  4. Certificate        │                         │           │
│      │◄───────────────────────┤                         │           │
│      │                        │                         │           │
│      │  5. Encrypted HTTP     │                         │           │
│      ├═══════════════════════►│                         │           │
│      │                        │ 6. PLAINTEXT HTTP       │           │
│      │                        │    to the pod IP        │           │
│      │                        ├────────────────────────►│           │
│      │                        │                         │           │
│   TLS ends here. The hop from controller to pod is cleartext        │
│   unless you set backend-protocol: HTTPS or run a service mesh.     │
└────────────────────────────────────────────────────────────────────┘
```

### The Secret Format

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: shop-tls
  namespace: web                # MUST be the Ingress's namespace
type: kubernetes.io/tls         # this exact type is required
data:
  tls.crt: <base64 of the full chain: leaf cert first, then intermediates>
  tls.key: <base64 of the private key, unencrypted>
```

The two keys `tls.crt` and `tls.key` are mandatory for this Secret type. Anything else is rejected by the API server.

### Complete Self Signed Walkthrough

```bash
# ------------------------------------------------------------------
# 1. Generate a key and a self signed certificate with SANs.
#    Modern browsers and Go clients IGNORE the legacy CN field,
#    so subjectAltName is not optional.
# ------------------------------------------------------------------
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=shop.example.com/O=k8s-learning-path" \
  -addext "subjectAltName=DNS:shop.example.com,DNS:www.shop.example.com"

# ------------------------------------------------------------------
# 2. Verify what you actually produced before you ship it
# ------------------------------------------------------------------
openssl x509 -in tls.crt -noout -text | grep -A1 "Subject Alternative Name"
openssl x509 -in tls.crt -noout -dates
openssl x509 -in tls.crt -noout -issuer -subject

# The modulus of cert and key MUST match, otherwise nginx refuses the pair
openssl x509 -noout -modulus -in tls.crt | openssl md5
openssl rsa  -noout -modulus -in tls.key | openssl md5

# ------------------------------------------------------------------
# 3. Create the Secret
# ------------------------------------------------------------------
kubectl create namespace web --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls shop-tls \
  --cert=tls.crt \
  --key=tls.key \
  --namespace web

# Idempotent version, safe to re-run in a script when rotating
kubectl create secret tls shop-tls \
  --cert=tls.crt --key=tls.key -n web \
  --dry-run=client -o yaml | kubectl apply -f -

# ------------------------------------------------------------------
# 4. Confirm the Secret
# ------------------------------------------------------------------
kubectl -n web get secret shop-tls -o jsonpath='{.type}{"\n"}'
# kubernetes.io/tls

kubectl -n web get secret shop-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -dates
```

### The Ingress That Uses It

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-tls-ingress
  namespace: web
  annotations:
    # Send a 308 redirect from http:// to https://.
    # This is ON by default in ingress-nginx whenever a host has a
    # certificate, so setting it to "true" is documentation, and
    # setting it to "false" is the meaningful action.
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - shop.example.com
    - www.shop.example.com
    secretName: shop-tls
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: shop-svc, port: { number: 80 } }
  - host: www.shop.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: shop-svc, port: { number: 80 } }
```

### SNI: Many Certificates on One IP

Server Name Indication is the TLS extension that carries the hostname in the **unencrypted** ClientHello. Without it, one IP could serve exactly one certificate, because the server would have to pick a certificate before knowing which site was requested.

```
┌────────────────────────────────────────────────────────────────────┐
│                 One IP, three certificates, via SNI                 │
│                                                                     │
│  ClientHello SNI=shop.example.com  ──► serve Secret shop-tls        │
│  ClientHello SNI=blog.example.com  ──► serve Secret blog-tls        │
│  ClientHello SNI=api.example.com   ──► serve Secret api-tls         │
│  ClientHello SNI=unknown.host      ──► serve the controller's       │
│                                        self signed fake certificate │
│                                        (browser shows a warning)    │
│  No SNI at all (curl https://IP)   ──► same fake certificate        │
└────────────────────────────────────────────────────────────────────┘
```

Multiple Ingress objects, in multiple namespaces, each with their own `tls` block, all share the same controller and the same IP. The controller assembles one nginx server block per hostname and attaches the right certificate to each.

### Verifying TLS

```bash
LB_IP=192.168.1.240

# Which certificate is served for this SNI name?
openssl s_client -connect $LB_IP:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# Full curl test without DNS
curl -kv --resolve shop.example.com:443:$LB_IP https://shop.example.com/

# Confirm the http to https redirect
curl -sI --resolve shop.example.com:80:$LB_IP http://shop.example.com/ | head -5

# If you see "Kubernetes Ingress Controller Fake Certificate",
# the controller did NOT find a usable Secret for that SNI name.
```

### Backend Protocol and Passthrough

| Goal | Mechanism |
|------|-----------|
| Terminate TLS at the controller, plaintext to pod | Default behaviour |
| Terminate at the controller, re-encrypt to the pod | `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` |
| Proxy gRPC | `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"` |
| Do not terminate at all, hand the TLS stream to the pod | `nginx.ingress.kubernetes.io/ssl-passthrough: "true"` plus the controller flag `--enable-ssl-passthrough` |

> ⚠️ With `ssl-passthrough` the controller cannot read the path, so path based rules for that host are meaningless. Routing is by SNI only.

---

## Automated Certificates with cert-manager

Self signed certificates are fine for a lab. In production you want automatic issuance and automatic renewal. `cert-manager` is the de facto Kubernetes add on for that. It is a separate project, installed as CRDs plus a controller.

### The Object Model

```
┌────────────────────────────────────────────────────────────────────┐
│                       cert-manager objects                          │
│                                                                     │
│   ClusterIssuer  (cluster scoped)   or   Issuer  (namespaced)       │
│        │  "how and where do I get certificates from"                │
│        │  ACME (Let's Encrypt), Vault, Venafi, a private CA,        │
│        │  or selfSigned                                             │
│        ▼                                                            │
│   Certificate  (namespaced)                                         │
│        │  "I want a cert for these DNS names, stored in             │
│        │   Secret <name>, renewed before it expires"                │
│        ▼                                                            │
│   CertificateRequest  ──►  Order  ──►  Challenge   (ACME only)      │
│        │                                                            │
│        ▼                                                            │
│   Secret of type kubernetes.io/tls                                  │
│        │                                                            │
│        ▼                                                            │
│   Referenced by Ingress spec.tls[].secretName                       │
└────────────────────────────────────────────────────────────────────┘
```

### The ACME HTTP01 Solver Flow

```
┌────────────────────────────────────────────────────────────────────┐
│  1. cert-manager asks the ACME server (Let's Encrypt) for an Order  │
│     covering shop.example.com.                                      │
│                                                                     │
│  2. The ACME server replies with a challenge token and expects      │
│     a specific response to be served at:                            │
│         http://shop.example.com/.well-known/acme-challenge/<token>  │
│                                                                     │
│  3. cert-manager creates a TEMPORARY solver Pod, Service and        │
│     Ingress that serve exactly that one path.                       │
│                                                                     │
│  4. Your existing ingress controller routes the challenge request   │
│     to that solver pod, because the temporary Ingress is a more     │
│     specific path than your catch all rule.                         │
│                                                                     │
│  5. The ACME server fetches the URL over PLAIN HTTP from the        │
│     public internet and validates the response.                     │
│                                                                     │
│  6. Validation succeeds, the certificate is issued, cert-manager    │
│     writes it into the Secret and deletes the temporary objects.    │
│                                                                     │
│  7. Well before expiry, cert-manager repeats the whole flow and     │
│     rewrites the Secret. The ingress controller notices the Secret  │
│     change and hot reloads the certificate.                         │
└────────────────────────────────────────────────────────────────────┘
```

Preconditions that people forget:

- The DNS name must resolve publicly to the ingress controller's IP.
- Port 80 must be reachable from the internet, because HTTP01 validation is plain HTTP. A blanket http to https redirect can break it, which is why cert-manager's solver Ingress opts out of the redirect.
- HTTP01 **cannot** issue wildcard certificates. Wildcards require the DNS01 solver, which proves control by writing a TXT record.

### Issuer and Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key   # the ACME ACCOUNT key, not a cert
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx          # which controller serves the challenge
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: shop-tls
  namespace: web
spec:
  secretName: shop-tls                     # the Secret cert-manager will create
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - shop.example.com
  - www.shop.example.com
```

### The Ingress Shim

You rarely write the `Certificate` by hand. Annotate the Ingress and cert-manager creates it for you, deriving `dnsNames` from `spec.tls[].hosts` and `secretName` from `spec.tls[].secretName`.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-ingress
  namespace: web
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod   # this one line is enough
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - shop.example.com
    secretName: shop-tls          # cert-manager creates and maintains this Secret
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: shop-svc, port: { number: 80 } }
```

### Debugging Issuance

```bash
kubectl -n web get certificate
kubectl -n web describe certificate shop-tls
kubectl -n web get certificaterequest,order,challenge
kubectl -n web describe challenge          # the reason field explains failures
kubectl -n cert-manager logs deploy/cert-manager
```

> 💡 Use the Let's Encrypt **staging** directory (`https://acme-staging-v02.api.letsencrypt.org/directory`) while you are getting the flow to work. Production has strict rate limits and you will lock yourself out for a week.

---

## Routing Patterns

### Pattern 1: Simple Fanout

One hostname, several paths, several backing Services.

```
                          ┌──────────────────────────┐
   shop.example.com  ────►│   Ingress Controller     │
                          └────────────┬─────────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              │                        │                        │
        /api  ▼                 /static▼                  /     ▼
      ┌───────────────┐      ┌───────────────┐      ┌───────────────┐
      │  api-svc:8080 │      │ static-svc:80 │      │  web-svc:80   │
      └───────────────┘      └───────────────┘      └───────────────┘
```

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: shop
spec:
  replicas: 2
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
      - name: nginx
        image: nginx:stable
        ports:
        - name: http
          containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: shop
spec:
  selector: { app: web }
  ports:
  - name: http
    port: 80
    targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: shop
spec:
  replicas: 3
  selector:
    matchLabels: { app: api }
  template:
    metadata:
      labels: { app: api }
    spec:
      containers:
      - name: api
        image: hashicorp/http-echo
        args: ["-text=hello from api", "-listen=:8080"]
        ports:
        - name: http
          containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: shop
spec:
  selector: { app: api }
  ports:
  - name: http
    port: 8080
    targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-fanout
  namespace: shop
spec:
  ingressClassName: nginx
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-svc
            port: { name: http }
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port: { name: http }
```

> 💡 Referencing the Service port by **name** rather than number decouples the Ingress from the port number, so changing the container port only touches the Deployment and Service.

### Pattern 2: Name Based Virtual Hosting

Several hostnames, one Service each, one IP.

```
                    ┌───────────────────────────────┐
   DNS A records    │      Ingress Controller       │
   all point at     │        192.168.1.240          │
   the same IP      └───────────────┬───────────────┘
                                    │
   Host: web-app-nginx.example.com  ├──► svc/web-app-nginx
   Host: web-app-apache.example.com └──► svc/web-app-apache
```

This is exactly the layout in `k8s-workshop/ingress-nginx/`, which pairs `test-web-app-nginx.yaml` and `test-web-app-apache.yaml` with `web-app-nginx-ingress.yaml` and `web-app-apache-ingress.yaml`.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-app-nginx-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: web-app-nginx.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-app-nginx
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-app-apache-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: web-app-apache.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-app-apache
            port:
              number: 80
```

Two separate Ingress objects rather than one with two rules is the better pattern here: each team owns its own object, and deleting one app does not touch the other's routing.

```bash
kubectl apply -f k8s-workshop/ingress-nginx/test-web-app-nginx.yaml
kubectl apply -f k8s-workshop/ingress-nginx/test-web-app-apache.yaml
kubectl apply -f k8s-workshop/ingress-nginx/web-app-nginx-ingress.yaml
kubectl apply -f k8s-workshop/ingress-nginx/web-app-apache-ingress.yaml

kubectl get ingress -o wide
```

### Pattern 3: Per Namespace Ingress, Shared Hostname

Different teams own different paths of the same hostname, in their own namespaces.

```yaml
# In namespace "team-a"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: team-a-routes
  namespace: team-a
spec:
  ingressClassName: nginx
  rules:
  - host: portal.example.com
    http:
      paths:
      - path: /billing
        pathType: Prefix
        backend:
          service: { name: billing-svc, port: { number: 80 } }
---
# In namespace "team-b"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: team-b-routes
  namespace: team-b
spec:
  ingressClassName: nginx
  rules:
  - host: portal.example.com
    http:
      paths:
      - path: /reports
        pathType: Prefix
        backend:
          service: { name: reports-svc, port: { number: 80 } }
```

ingress-nginx merges these into a single `server` block for `portal.example.com`. This works, but it is exactly the weakness that Gateway API set out to fix: nothing stops team-b from also claiming `/billing`, and there is no Kubernetes level way to grant a namespace only part of a hostname. See [gateway-api.md](gateway-api.md).

---

## Exposing the Controller on Bare Metal

On a cloud provider, `Service type: LoadBalancer` provisions a real load balancer. On bare metal there is nothing behind that API, so the Service sits in `<pending>` forever. There are three practical answers.

```
┌────────────────────────────────────────────────────────────────────┐
│  OPTION A: LoadBalancer Service backed by MetalLB   ★ recommended  │
│                                                                     │
│   Client ──► 192.168.1.240:443 (MetalLB VIP, ARP or BGP announced)  │
│                  │                                                  │
│                  ▼ node that owns the VIP                           │
│              kube-proxy DNAT                                        │
│                  │                                                  │
│                  ▼                                                  │
│        ingress-nginx controller pod                                 │
│                                                                     │
│   + Clean ports 80/443, real IP, DNS friendly                       │
│   + Ingress status gets a real ADDRESS                              │
│   - Needs a spare IP range on the LAN                               │
├────────────────────────────────────────────────────────────────────┤
│  OPTION B: NodePort                                                 │
│                                                                     │
│   Client ──► any-node-ip:31080 / :31443                             │
│                                                                     │
│   + Zero extra components                                           │
│   - Non standard ports, you need an external LB or DNS SRV hacks    │
│   - Source IP is NAT'd unless externalTrafficPolicy: Local          │
├────────────────────────────────────────────────────────────────────┤
│  OPTION C: hostNetwork on the controller pods                       │
│                                                                     │
│   Client ──► node-ip:80 / :443 directly, no kube-proxy hop          │
│                                                                     │
│   + Lowest latency, true client source IP, real ports               │
│   - One controller pod per node maximum (port conflict)             │
│   - Pod shares the node network namespace, weaker isolation         │
│   - You must handle failover yourself (DNS round robin, keepalived) │
└────────────────────────────────────────────────────────────────────┘
```

### Option A with MetalLB

This is what `k8s-workshop/ingress-nginx/setup-ingress-inginx-for-metlallb.sh` does.

```bash
kubectl create namespace ingress-nginx

# The "baremetal" provider manifest creates a NodePort Service
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml

# Flip it to LoadBalancer so MetalLB assigns a VIP from its pool
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p '{"spec": {"type": "LoadBalancer"}}'

# Watch MetalLB hand out the address
kubectl -n ingress-nginx get svc ingress-nginx-controller -w
# NAME                       TYPE           EXTERNAL-IP       PORT(S)
# ingress-nginx-controller   LoadBalancer   192.168.1.240     80:31234/TCP,443:31235/TCP
```

MetalLB must already be installed with an `IPAddressPool` covering that range. See [metallb.md](metallb.md) for Layer 2 versus BGP mode, and `k8s-workshop/metallb-ip-pool.yaml` for the pool definition used in this repository.

```
┌────────────────────────────────────────────────────────────────────┐
│              Full bare metal path, MetalLB + ingress-nginx          │
│                                                                     │
│  Browser                                                            │
│    │  https://shop.example.com                                      │
│    ▼                                                                │
│  DNS ──► 192.168.1.240                                              │
│    │                                                                │
│    ▼                                                                │
│  MetalLB speaker on the elected node answers ARP for the VIP        │
│    │                    (L2 mode; in BGP mode the router ECMPs)     │
│    ▼                                                                │
│  Node NIC ──► kube-proxy DNAT ──► ingress-nginx pod :443            │
│    │                                                                │
│    ▼                                                                │
│  TLS terminated, Host and path inspected                            │
│    │                                                                │
│    ▼                                                                │
│  proxy_pass straight to application POD IPs 10.244.x.y              │
└────────────────────────────────────────────────────────────────────┘
```

### Preserving the Client Source IP

By default kube-proxy SNATs traffic arriving at a NodePort or LoadBalancer to the node IP, so your access logs show node IPs instead of real clients.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local    # do not SNAT, do not forward to other nodes
  ports:
  - name: http
    port: 80
    targetPort: http
  - name: https
    port: 443
    targetPort: https
```

`externalTrafficPolicy: Local` preserves the source IP but only sends traffic to nodes that actually run a controller pod. With MetalLB in Layer 2 mode, the speaker will only announce the VIP from nodes with a local endpoint, so this combination works well. Run the controller as a DaemonSet, or scale it to at least as many replicas as you have nodes in the announce set.

---

## Rewrites and Redirects

### The Problem Rewrites Solve

Your app was written to serve `/`, but you want to expose it at `/legacy`. Without a rewrite, the app receives `/legacy/dashboard` and returns 404 because it only knows `/dashboard`.

```
Without rewrite:
   Browser  GET /legacy/dashboard  ──► pod receives  GET /legacy/dashboard  ✗

With rewrite-target:
   Browser  GET /legacy/dashboard  ──► pod receives  GET /dashboard        ✓
```

### Simple Rewrite

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: simple-rewrite
  namespace: web
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /legacy
        pathType: Prefix
        backend:
          service: { name: legacy-svc, port: { number: 80 } }
```

> ⚠️ This rewrites **every** request under `/legacy` to exactly `/`. `/legacy/a/b/c` becomes `/`. That is almost never what you want, which is why capture groups exist.

### Rewrite With Capture Groups

This is the canonical, correct form.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: capture-rewrite
  namespace: web
  annotations:
    # $2 refers to the SECOND capture group in the path regex below
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      # Group 1 = (/|$)   Group 2 = (.*)
      - path: /legacy(/|$)(.*)
        pathType: ImplementationSpecific   # regex paths need this
        backend:
          service: { name: legacy-svc, port: { number: 80 } }
```

Resulting transformations:

| Browser requests | Regex captures | Pod receives |
|------------------|----------------|--------------|
| `/legacy` | `$1=""`, `$2=""` | `/` |
| `/legacy/` | `$1="/"`, `$2=""` | `/` |
| `/legacy/dashboard` | `$1="/"`, `$2="dashboard"` | `/dashboard` |
| `/legacy/a/b/c?x=1` | `$1="/"`, `$2="a/b/c"` | `/a/b/c?x=1` |

The `(/|$)` group is what makes `/legacy` (no trailing slash) work as well as `/legacy/`.

> ⚠️ Rewrites break relative links in HTML. The browser still thinks it is at `/legacy/`, so an asset referenced as `./app.css` resolves to `/legacy/app.css`, which the rewrite turns into `/app.css`, which usually works, but an absolute link written by the app as `/app.css` will not be prefixed and will 404. Apps that are served under a subpath need to be told their base path (for example a `PUBLIC_URL` or `--base-href` build setting).

### Redirects

| Goal | Annotation |
|------|-----------|
| Redirect `/` to a subpath | `nginx.ingress.kubernetes.io/app-root: /dashboard` |
| Permanent redirect (301) to another URL | `nginx.ingress.kubernetes.io/permanent-redirect: https://new.example.com` |
| Change the permanent redirect code | `nginx.ingress.kubernetes.io/permanent-redirect-code: "308"` |
| Temporary redirect (302) | `nginx.ingress.kubernetes.io/temporal-redirect: https://maintenance.example.com` |
| `example.com` to `www.example.com` | `nginx.ingress.kubernetes.io/from-to-www-redirect: "true"` |
| Force http to https even without a cert on this host | `nginx.ingress.kubernetes.io/force-ssl-redirect: "true"` |
| Disable the automatic http to https redirect | `nginx.ingress.kubernetes.io/ssl-redirect: "false"` |

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: retired-site
  namespace: web
  annotations:
    nginx.ingress.kubernetes.io/permanent-redirect: "https://new.example.com/"
    nginx.ingress.kubernetes.io/permanent-redirect-code: "301"
spec:
  ingressClassName: nginx
  rules:
  - host: old.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          # A backend is still syntactically required even though every
          # request is redirected before it is ever proxied.
          service: { name: placeholder-svc, port: { number: 80 } }
```

---

## Common ingress-nginx Annotations

Annotations are the reason Ingress became a portability problem, but they are also how real work gets done. Everything below is prefixed with `nginx.ingress.kubernetes.io/`.

### Routing and Rewriting

| Annotation | Example value | Effect |
|------------|---------------|--------|
| `rewrite-target` | `/$2` | Rewrite the upstream path, capture groups supported |
| `use-regex` | `"true"` | Interpret `path` values as regular expressions |
| `app-root` | `/dashboard` | Redirect requests for `/` to this path |
| `permanent-redirect` | `https://new.example.com` | 301 redirect |
| `temporal-redirect` | `https://tmp.example.com` | 302 redirect |
| `from-to-www-redirect` | `"true"` | Redirect the apex host to the `www` host |
| `upstream-vhost` | `internal.svc.local` | Override the `Host` header sent upstream |

### TLS and Protocol

| Annotation | Example value | Effect |
|------------|---------------|--------|
| `ssl-redirect` | `"true"` / `"false"` | Redirect http to https (defaults to true when the host has a certificate) |
| `force-ssl-redirect` | `"true"` | Redirect even when no certificate is configured for the host |
| `backend-protocol` | `HTTP`, `HTTPS`, `GRPC`, `GRPCS`, `AJP`, `FCGI` | How to speak to the pod |
| `ssl-passthrough` | `"true"` | Do not terminate TLS, route by SNI only (needs the controller flag) |

### Limits, Timeouts and Buffers

| Annotation | Example value | Effect |
|------------|---------------|--------|
| `proxy-body-size` | `50m`, `0` | Maximum request body; `0` disables the limit |
| `proxy-connect-timeout` | `"10"` | Seconds to establish the upstream connection |
| `proxy-read-timeout` | `"3600"` | Seconds between reads from the upstream, raise for websockets and SSE |
| `proxy-send-timeout` | `"3600"` | Seconds between writes to the upstream |
| `proxy-buffer-size` | `16k` | Raise when upstreams send large headers, for example big JWTs |

### Access Control and Traffic Shaping

| Annotation | Example value | Effect |
|------------|---------------|--------|
| `whitelist-source-range` | `10.0.0.0/8,192.168.1.0/24` | Allow only these client CIDRs |
| `limit-rps` | `"10"` | Requests per second per client IP |
| `limit-connections` | `"20"` | Concurrent connections per client IP |
| `auth-type` | `basic` | Enable HTTP basic auth |
| `auth-secret` | `basic-auth` | Secret holding the htpasswd file |
| `auth-realm` | `Restricted` | Realm string shown by the browser |
| `auth-url` | `https://auth.example.com/verify` | External authentication subrequest |
| `auth-signin` | `https://auth.example.com/start` | Where to send unauthenticated users |
| `enable-cors` | `"true"` | Emit CORS headers |
| `cors-allow-origin` | `https://app.example.com` | Allowed origin |
| `affinity` | `cookie` | Enable session affinity |
| `session-cookie-name` | `INGRESSCOOKIE` | Name of the affinity cookie |
| `canary` | `"true"` | Mark this Ingress as a canary for an existing host and path |
| `canary-weight` | `"10"` | Percentage of traffic sent to the canary |
| `canary-by-header` | `X-Canary` | Route to the canary when this header is present |

### Escape Hatches

| Annotation | Effect |
|------------|--------|
| `configuration-snippet` | Raw nginx directives injected into the `location` block |
| `server-snippet` | Raw nginx directives injected into the `server` block |

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Request-Id: $req_id";
      more_set_headers "X-Frame-Options: DENY";
```

> 🔒 **Security note**: snippet annotations let anyone who can create an Ingress inject arbitrary nginx configuration, which is a privilege escalation path in a multi tenant cluster. Recent ingress-nginx releases therefore ship with the ConfigMap setting `allow-snippet-annotations` defaulting to `false`. If your snippets are silently ignored, that setting is why. Enable it deliberately, and only if you trust everyone who can create Ingress objects.

### Canary Example

```yaml
# The stable Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-stable
  namespace: web
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: app-v1, port: { number: 80 } }
---
# The canary Ingress: SAME host, SAME path, different backend
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-canary
  namespace: web
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "10"     # 10 percent to v2
spec:
  ingressClassName: nginx
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: { name: app-v2, port: { number: 80 } }
```

This works, but notice what it costs: two Ingress objects that must be kept in lockstep, a behaviour that exists only because of a vendor annotation, and no way for the API to validate that the pair is consistent. Gateway API expresses the same thing as two weighted `backendRefs` inside one route. See [deployment-strategies.md](deployment-strategies.md) and [gateway-api.md](gateway-api.md).

---

## Ingress Controller Comparison

| Controller | `spec.controller` value | Data plane | Configuration style | Notable strengths |
|------------|-------------------------|------------|---------------------|-------------------|
| **ingress-nginx** | `k8s.io/ingress-nginx` | NGINX + Lua | Annotations, ConfigMap, snippets | Kubernetes project owned, huge install base, most documented, dynamic endpoint updates without reload |
| **Traefik** | `traefik.io/ingress-controller` | Traefik (Go) | CRDs (IngressRoute, Middleware) plus annotations | First class CRDs, clean middleware chaining, built in ACME, good dashboard |
| **HAProxy Ingress** | `haproxy.org/ingress-controller` | HAProxy | Annotations, ConfigMap | Very high throughput, mature TCP handling, excellent connection management |
| **Contour** | `projectcontour.io/ingress-controller` | Envoy | CRD (HTTPProxy) plus Ingress | Delegation model for multi tenancy, no config reloads (xDS), strong Gateway API support |
| **Istio ingress gateway** | `istio.io/ingress-controller` | Envoy | Gateway plus VirtualService CRDs, or Gateway API | Full mesh integration, mTLS, rich L7 policy, fault injection, retries |

Practical selection guidance:

- **Learning, home lab, bare metal**: ingress-nginx. It is what this repository uses, it is the most searchable when things break, and it pairs cleanly with MetalLB.
- **Already running a service mesh**: use the mesh's own gateway rather than adding a second proxy tier.
- **Multi tenant platform with strict namespace boundaries**: Contour's delegation model or, better, Gateway API.
- **New greenfield build**: strongly consider going straight to Gateway API with an implementation of your choice.

```bash
# Which controller is actually installed here?
kubectl get ingressclass -o custom-columns='NAME:.metadata.name,CONTROLLER:.spec.controller'

# Confirm the running image
kubectl -n ingress-nginx get deploy ingress-nginx-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# Ask the controller itself
kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /nginx-ingress-controller --version
```

---

## Why Ingress Stalled as an API

Ingress reached GA in `networking.k8s.io/v1` and then essentially stopped evolving. That was deliberate. The API had four structural problems that could not be fixed without breaking changes.

### Problem 1: Annotation Sprawl

```
┌────────────────────────────────────────────────────────────────────┐
│  The Ingress SPEC covers:  host, path, pathType, backend, tls      │
│                                                                     │
│  Everything else lives in ANNOTATIONS, which are:                   │
│    • untyped strings, so "10" and "ten" both pass validation       │
│    • unvalidated, so typos fail silently at runtime                │
│    • vendor specific, so nginx.ingress.kubernetes.io/* means        │
│      nothing to Traefik, Contour or HAProxy                        │
│    • undiscoverable, kubectl explain tells you nothing             │
│    • unversioned, with no deprecation machinery                    │
│                                                                     │
│  ingress-nginx alone documents well over a hundred of them.        │
│  Migrating between controllers means rewriting all of them.        │
└────────────────────────────────────────────────────────────────────┘
```

### Problem 2: No Separation of Roles

Everything lives in one object in one namespace. The person who owns the TLS certificate and the hostname (the platform team) and the person who owns the path to Service mapping (the app team) must edit the same YAML. Kubernetes RBAC is per resource kind, so you cannot grant "you may add paths but not change the hostname or the certificate".

```
┌────────────────────────────────────────────────────────────────────┐
│  ONE Ingress object mixes three concerns:                          │
│                                                                     │
│    Infrastructure  : which load balancer, which IP                 │
│    Cluster policy  : which hostnames, which certificates           │
│    Application     : which path goes to which Service              │
│                                                                     │
│  RBAC can only say yes or no to the whole object.                  │
└────────────────────────────────────────────────────────────────────┘
```

### Problem 3: HTTP Only

No TCP, no UDP, no first class gRPC, no TLS passthrough in the API. Every controller invented its own answer: ingress-nginx uses a ConfigMap called `tcp-services`, Traefik uses `IngressRouteTCP`, Contour uses `HTTPProxy` with TCP proxying. None of it is portable.

### Problem 4: No Traffic Management Primitives

Canary releases, blue green cutovers, header based A/B routing, request mirroring, header rewriting, retries and timeouts are all standard requirements and none of them exist in the Ingress API. They are annotations, or paired canary Ingress objects, or vendor CRDs.

### The Consequence

```
┌────────────────────────────────────────────────────────────────────┐
│  The Ingress API is FROZEN. It is not deprecated, it is not going  │
│  away, and it will keep working. But no new features will be       │
│  added to it.                                                       │
│                                                                     │
│  All new work happens in Gateway API, which was designed from the  │
│  start around:                                                      │
│     • role oriented resources (GatewayClass / Gateway / Route)     │
│     • typed fields instead of annotations                          │
│     • protocols beyond HTTP                                        │
│     • traffic splitting, mirroring and filters in the spec          │
│     • explicit cross namespace permission via ReferenceGrant       │
│     • a conformance test suite so "portable" means something       │
└────────────────────────────────────────────────────────────────────┘
```

Continue to [gateway-api.md](gateway-api.md).

---

## Troubleshooting

### Diagnostic Order

```
┌────────────────────────────────────────────────────────────────────┐
│  Work outside in. Do not skip steps.                                │
│                                                                     │
│  1. Is there a controller?         kubectl get ingressclass         │
│  2. Is it running?                 kubectl -n ingress-nginx get pod │
│  3. Did it claim the Ingress?      kubectl get ing (ADDRESS column) │
│  4. Does DNS resolve to the LB?    dig +short host                  │
│  5. Does the LB have an IP?        kubectl get svc -n ingress-nginx │
│  6. Does the Service have          kubectl get endpointslice        │
│     endpoints?                                                      │
│  7. Do the pods answer directly?   kubectl exec ... curl podIP      │
│  8. What does the access log say?  kubectl logs -f deploy/...       │
└────────────────────────────────────────────────────────────────────┘
```

### Symptom: 404 With Body "default backend - 404"

Your request reached the controller but matched **no** rule.

| Cause | Check | Fix |
|-------|-------|-----|
| Wrong `Host` header (you curled the IP) | `curl -H "Host: app.example.com" http://$LB_IP/` | Use the real hostname, or `--resolve` |
| Ingress not claimed by this controller | `kubectl get ing -o yaml \| grep ingressClassName` | Set `ingressClassName` to a class the controller serves |
| Ingress in a namespace the controller does not watch | Controller `--watch-namespace` flag | Move the Ingress or widen the watch scope |
| `pathType: Exact` and the client sent a trailing slash | Access log shows the exact request path | Use `Prefix`, or add a second `Exact` rule |
| `Prefix` element boundary (`/api` vs `/apiary`) | Compare elements, not string prefixes | Correct the path |
| Host typo or wrong wildcard depth | `kubectl get ing -o wide` | Fix the host, remember wildcards cover one label |

```bash
# See exactly what the controller believes it is serving
kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
  cat /etc/nginx/nginx.conf | grep -B2 -A8 'server_name app.example.com'
```

### Symptom: 503 Service Temporarily Unavailable

The rule matched but the upstream is empty.

```bash
# The Service exists?
kubectl -n web get svc api-svc

# The Service actually selects pods? THIS is the usual culprit.
kubectl -n web get endpointslice -l kubernetes.io/service-name=api-svc -o yaml

# Empty endpoints means the selector does not match any READY pod
kubectl -n web get pods --show-labels
kubectl -n web describe svc api-svc | grep -i selector
```

| Cause | Fix |
|-------|-----|
| Service selector does not match pod labels | Align `spec.selector` with the pod template labels |
| Pods are not Ready (failing readiness probe) | Fix the probe or the app; unready pods are excluded from EndpointSlices |
| Ingress references the wrong Service port | Reference the port by name to avoid drift |
| Service is in a different namespace than the Ingress | Ingress cannot cross namespaces; move it or use an ExternalName Service |
| Service name typo | `kubectl get ing -o yaml` and compare |

### Symptom: 502 Bad Gateway

The upstream exists but the conversation failed.

| Cause | Signature in the log | Fix |
|-------|----------------------|-----|
| App listens on a different port than `targetPort` | `connect() failed (111: Connection refused)` | Correct `targetPort` |
| App listens on `127.0.0.1` instead of `0.0.0.0` | Connection refused from the controller only | Bind to all interfaces |
| App speaks HTTPS, controller sends HTTP | `SSL_ERROR` or immediate reset | `backend-protocol: "HTTPS"` |
| App speaks gRPC | Protocol errors | `backend-protocol: "GRPC"` |
| Response headers too large (big JWT) | `upstream sent too big header` | Raise `proxy-buffer-size` |
| App is slow, controller gave up | `upstream timed out` | Raise `proxy-read-timeout` |
| NetworkPolicy blocks controller to pod | Timeouts, nothing in the app log | Allow ingress from the controller namespace |

```yaml
# NetworkPolicy that permits the controller to reach the app pods.
# Remember: the controller talks to POD IPs, not the ClusterIP.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-controller
  namespace: web
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
          kubernetes.io/metadata.name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
```

See [network-policy.md](network-policy.md).

### Symptom: TLS Not Served, Fake Certificate Presented

```bash
openssl s_client -connect $LB_IP:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject
# subject=O = Acme Co, CN = Kubernetes Ingress Controller Fake Certificate
```

| Cause | Check | Fix |
|-------|-------|-----|
| Secret in the wrong namespace | `kubectl -n web get secret shop-tls` | Create it in the Ingress's namespace |
| Secret has the wrong type | `kubectl get secret shop-tls -o jsonpath='{.type}'` | Must be `kubernetes.io/tls` |
| `spec.tls[].hosts` does not include the requested host | `kubectl get ing -o yaml` | Add the host to the tls block |
| Certificate SANs do not cover the host | `openssl x509 -text \| grep -A1 "Alternative Name"` | Reissue with the right SANs |
| Cert and key do not match | Compare the two modulus md5 values | Regenerate the pair |
| Client sent no SNI | You used `https://IP` | Use the hostname or `--resolve` |
| Secret created after the Ingress and the controller missed it | Controller logs | Re-apply the Ingress to trigger a resync |

```bash
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller | grep -i -E 'ssl|cert|secret'
```

### Symptom: ADDRESS Column Stays Empty

| Cause | Fix |
|-------|-----|
| No controller installed | Install one |
| `ingressClassName` names a class no controller serves | `kubectl get ingressclass`, then correct the field |
| Controller has no `--publish-service` and cannot find an IP to report | Set the flag to `<namespace>/<service-name>` |
| The controller Service itself is `<pending>` | Install MetalLB, or use NodePort or hostNetwork |
| Controller pods are crash looping | `kubectl -n ingress-nginx describe pod`, check RBAC and admission webhook |

### Symptom: Controller Rejects the Ingress at Apply Time

ingress-nginx installs a `ValidatingWebhookConfiguration` that renders your Ingress into nginx config and refuses it if nginx would fail to load.

```
Error from server (BadRequest): error when creating "ingress.yaml":
admission webhook "validate.nginx.ingress.kubernetes.io" denied the request
```

```bash
# Read the real reason
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller | tail -50

# If the webhook Service is unreachable, EVERY Ingress apply fails
kubectl get validatingwebhookconfiguration
kubectl -n ingress-nginx get svc ingress-nginx-controller-admission
kubectl -n ingress-nginx get job          # the cert generation jobs must have completed
```

### General Purpose Commands

```bash
kubectl describe ingress <name> -n <ns>          # events plus resolved backends
kubectl get ingress -A -o wide                    # class, hosts, address, ports
kubectl -n ingress-nginx logs -f deploy/ingress-nginx-controller
kubectl -n ingress-nginx get events --sort-by=.lastTimestamp

# Reproduce the request from INSIDE the cluster to isolate DNS and firewall
kubectl run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sv -H "Host: app.example.com" http://ingress-nginx-controller.ingress-nginx.svc/

# Talk straight to a pod, bypassing the Service and the controller
kubectl -n web port-forward pod/<api-pod> 8080:8080
curl -v localhost:8080/health
```

---

## Exam and Interview Traps

1. **"I applied an Ingress and nothing happened."** No controller is installed. The API object is inert data. This is the number one question.
2. **`pathType` is mandatory.** There is no default. The manifest is rejected without it.
3. **`Prefix` is element based, not string based.** `/api` does not match `/apiary`.
4. **`Exact` is trailing slash sensitive.** `/foo` does not match `/foo/`.
5. **Path matching is case sensitive; host matching is not.**
6. **Longest path wins; on a tie, `Exact` beats `Prefix`.**
7. **A wildcard host covers exactly one label**, and must be the leftmost label. `*.example.com` does not match `a.b.example.com` and does not match `example.com`.
8. **Ingress cannot reference a Service in another namespace.** Both the Service and the TLS Secret must be local.
9. **The TLS Secret must be type `kubernetes.io/tls` with keys `tls.crt` and `tls.key`.**
10. **Only ports 80 and 443 are addressable.** Ingress is not a way to expose arbitrary TCP ports.
11. **ingress-nginx proxies to pod IPs, not the ClusterIP.** So Service `sessionAffinity` is ignored and NetworkPolicy must allow pod to pod traffic from the controller.
12. **`ingressclass.kubernetes.io/is-default-class` is applied at creation time only.** Existing Ingress objects are not retrofitted.
13. **`kubernetes.io/ingress.class` is the deprecated annotation**; `spec.ingressClassName` is the current field. If both are present, ingress-nginx prefers the annotation.
14. **`IngressClass` is cluster scoped and `spec.controller` is immutable.**
15. **`extensions/v1beta1` and `networking.k8s.io/v1beta1` Ingress are removed.** Only `networking.k8s.io/v1` exists.
16. **Annotations are not part of the API.** A typo does not fail validation, it silently does nothing.
17. **HTTP01 ACME challenges cannot issue wildcard certificates.** That requires DNS01.
18. **`rewrite-target: /` without capture groups collapses every subpath to `/`.**
19. **`configuration-snippet` may be disabled** by `allow-snippet-annotations: false` in the controller ConfigMap.
20. **`spec.defaultBackend` and the controller's global default backend are different things.**
21. **A rule with no `host` matches every hostname**, which makes it a catch all that can shadow your intent.
22. **`backend.service` and `backend.resource` are mutually exclusive**, as are `port.number` and `port.name`.
23. **On bare metal a LoadBalancer Service stays `<pending>` without MetalLB** or an equivalent, which is why the ADDRESS column stays empty.
24. **`externalTrafficPolicy: Local` preserves the client source IP** but only routes to nodes that host a controller pod.

---

## Related Topics

- **[k8s-networking-fundamentals.md](k8s-networking-fundamentals.md)**: the Pod, Service and Node networks that Ingress sits on top of
- **[gateway-api.md](gateway-api.md)**: the role oriented successor to Ingress
- **[metallb.md](metallb.md)**: how a LoadBalancer Service gets a real IP on bare metal
- **[install-metallb.md](install-metallb.md)**: MetalLB installation walkthrough
- **[network-policy.md](network-policy.md)**: allowing the controller to reach your pods
- **[kube-proxy.md](kube-proxy.md)**: how NodePort and LoadBalancer traffic reaches the controller pod
- **[coredns.md](coredns.md)**: in cluster DNS, used for Service discovery not for Ingress hostnames
- **[deployments.md](deployments.md)**: the workloads behind every backend Service
- **[deployment-strategies.md](deployment-strategies.md)**: canary and blue green, and why Ingress makes them awkward
- **[k8s-api.md](k8s-api.md)**: the watch mechanism every controller is built on
- **[imperative-kubernetes.md](imperative-kubernetes.md)**: `kubectl create ingress` and other fast paths

Working manifests in this repository: `k8s-workshop/ingress-nginx/`

---

## Key Takeaways

1. **Ingress is an API object; the Ingress controller is separate software you install.** Without a controller, an Ingress routes nothing and its `ADDRESS` stays empty forever.
2. **Ingress exists to solve the L7 problem** that LoadBalancer Services cannot: one IP, many hostnames, many paths, many certificates.
3. **The controller watches the API, renders proxy configuration, reloads, and proxies to pod IPs directly**, bypassing the Service ClusterIP and kube-proxy in most implementations.
4. **`pathType` is required and its semantics matter**: `Prefix` matches whole path elements, `Exact` is trailing slash sensitive, `ImplementationSpecific` is a portability hazard.
5. **Longest path wins, `Exact` breaks the tie; exact host beats wildcard host beats no host.**
6. **Wildcard hosts cover exactly one leftmost DNS label.**
7. **`spec.ingressClassName` is the correct way to select a controller.** The `kubernetes.io/ingress.class` annotation is deprecated, and the default class annotation only applies at creation time.
8. **TLS is a Secret of type `kubernetes.io/tls` in the Ingress's own namespace**, selected per hostname via SNI, terminated at the controller.
9. **cert-manager automates issuance and renewal**; the `cert-manager.io/cluster-issuer` annotation plus a `tls` block is usually all you need.
10. **Everything is namespace local**: the Service and the Secret must live beside the Ingress.
11. **On bare metal, pair ingress-nginx with MetalLB** so the controller Service gets a real IP, exactly as `k8s-workshop/ingress-nginx/setup-ingress-inginx-for-metlallb.sh` does.
12. **Annotations do the real work but are unvalidated, untyped and vendor specific.** That sprawl, plus the lack of role separation, non HTTP protocols and traffic splitting, is why the API is frozen and Gateway API exists.

---

## References

- [Kubernetes: Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Kubernetes: Ingress Controllers](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/)
- [Kubernetes: Service, Load Balancing and Networking](https://kubernetes.io/docs/concepts/services-networking/)
- [Kubernetes: TLS Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets)
- [ingress-nginx Documentation](https://kubernetes.github.io/ingress-nginx/)
- [ingress-nginx Annotations Reference](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [ingress-nginx Bare Metal Considerations](https://kubernetes.github.io/ingress-nginx/deploy/baremetal/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [cert-manager: ACME HTTP01 Solver](https://cert-manager.io/docs/configuration/acme/http01/)
- [MetalLB Documentation](https://metallb.universe.tf/)
- [Traefik Kubernetes Ingress](https://doc.traefik.io/traefik/providers/kubernetes-ingress/)
- [Project Contour](https://projectcontour.io/docs/)
- [HAProxy Kubernetes Ingress Controller](https://www.haproxy.com/documentation/kubernetes-ingress/)
- [Istio Ingress](https://istio.io/latest/docs/tasks/traffic-management/ingress/)
