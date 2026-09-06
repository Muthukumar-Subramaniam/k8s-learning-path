# 🛡️ Gateway API

Gateway API is the role oriented, expressive and portable successor to Ingress, built as a set of CRDs that split edge routing into three layers owned by three different personas.

> **Reference**: [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)

---

## 📋 Table of Contents

1. [Why Gateway API Exists](#why-gateway-api-exists)
2. [The Role Oriented Model](#the-role-oriented-model)
3. [The Resource Model](#the-resource-model)
4. [Installing the CRDs](#installing-the-crds)
5. [GatewayClass](#gatewayclass)
6. [Gateway and Listeners](#gateway-and-listeners)
7. [HTTPRoute](#httproute)
8. [Matches](#matches)
9. [Filters](#filters)
10. [Backend References and Weights](#backend-references-and-weights)
11. [Traffic Splitting for Canary](#traffic-splitting-for-canary)
12. [Header Based Routing for A/B Testing](#header-based-routing-for-ab-testing)
13. [Cross Namespace Routing and ReferenceGrant](#cross-namespace-routing-and-referencegrant)
14. [BackendTLSPolicy](#backendtlspolicy)
15. [Other Route Types](#other-route-types)
16. [Route Attachment and Status Conditions](#route-attachment-and-status-conditions)
17. [Conformance and Release Channels](#conformance-and-release-channels)
18. [Implementation Comparison](#implementation-comparison)
19. [Migrating from Ingress](#migrating-from-ingress)
20. [Troubleshooting](#troubleshooting)
21. [Exam and Interview Traps](#exam-and-interview-traps)
22. [Related Topics](#related-topics)
23. [Key Takeaways](#key-takeaways)
24. [References](#references)

---

## Why Gateway API Exists

The Ingress API reached GA and then froze. It works, it is not deprecated, and it will keep working, but it will not grow. Gateway API is where all new edge routing work happens. See [ingress.md](ingress.md) for the full account of how Ingress got stuck.

### The Four Design Goals

```
┌────────────────────────────────────────────────────────────────────┐
│  1. ROLE ORIENTED                                                   │
│     Split one monolithic object into three, so infrastructure       │
│     providers, cluster operators and application developers each    │
│     own a resource that RBAC can actually protect.                  │
│                                                                     │
│  2. PORTABLE                                                        │
│     Behaviour lives in typed spec fields validated by the API       │
│     server, not in unvalidated vendor annotation strings. A         │
│     conformance test suite defines what "portable" means.           │
│                                                                     │
│  3. EXPRESSIVE                                                      │
│     Header matching, query parameter matching, method matching,     │
│     traffic splitting by weight, request mirroring, redirects,      │
│     rewrites and header manipulation are all in the core spec.      │
│                                                                     │
│  4. EXTENSIBLE                                                      │
│     A defined extension model (ExtensionRef filters, policy         │
│     attachment, parametersRef) so vendors add features without      │
│     inventing another annotation namespace.                         │
└────────────────────────────────────────────────────────────────────┘
```

### Side by Side With Ingress

| Concern | Ingress | Gateway API |
|---------|---------|-------------|
| Number of resources | One (plus IngressClass) | Three layers, plus policy resources |
| Ownership boundary | None, one object mixes all concerns | Explicit, one resource per persona |
| Header based routing | Vendor annotation | `matches.headers` in the spec |
| Query param routing | Vendor annotation or not at all | `matches.queryParams` in the spec |
| Method routing | Not possible | `matches.method` in the spec |
| Traffic splitting | Paired canary Ingress objects with annotations | `backendRefs[].weight` in one route |
| Request mirroring | Vendor annotation | `RequestMirror` filter |
| Header manipulation | Vendor annotation or raw config snippet | `RequestHeaderModifier` filter |
| Redirects and rewrites | Vendor annotation | `RequestRedirect` and `URLRewrite` filters |
| TCP, UDP, TLS passthrough | Vendor ConfigMap or CRD | `TCPRoute`, `UDPRoute`, `TLSRoute` |
| gRPC | `backend-protocol` annotation | `GRPCRoute` with method level matching |
| Cross namespace backends | Impossible | `backendRefs.namespace` plus `ReferenceGrant` |
| Multiple hostnames per listener | Multiple rules | Listener `hostname` plus route `hostnames` intersection |
| Status feedback | One `ADDRESS` field | Rich per listener and per parent conditions |
| Portability | Poor, annotations do not transfer | Good, backed by conformance profiles |

### What Gateway API Is Not

- It is **not** a service mesh, although meshes implement it (the GAMMA initiative applies the same routes to east west traffic).
- It is **not** built into Kubernetes. The CRDs and a controller must be installed, exactly like Ingress controllers.
- It does **not** remove the need for a data plane proxy. It is an API; Envoy, NGINX, Cilium or Traefik still does the work.
- It does **not** deprecate Ingress. Both can coexist in one cluster, often on the same proxy.

---

## The Role Oriented Model

```
┌────────────────────────────────────────────────────────────────────┐
│                       WHO OWNS WHAT                                 │
├──────────────────┬─────────────────────┬───────────────────────────┤
│  PERSONA         │  RESOURCE           │  DECIDES                  │
├──────────────────┼─────────────────────┼───────────────────────────┤
│  Infrastructure  │  GatewayClass       │  Which controller and     │
│  Provider        │  (cluster scoped)   │  which load balancer      │
│  (cloud vendor,  │                     │  implementation exists    │
│   platform team) │                     │  in this cluster          │
├──────────────────┼─────────────────────┼───────────────────────────┤
│  Cluster         │  Gateway            │  Which ports, protocols,  │
│  Operator        │  (namespaced,       │  hostnames and TLS certs  │
│  (netops, SRE)   │   usually in an     │  are exposed, and WHICH   │
│                  │   infra namespace)  │  namespaces may attach    │
│                  │                     │  routes to them           │
├──────────────────┼─────────────────────┼───────────────────────────┤
│  Application     │  HTTPRoute,         │  Which paths, headers and │
│  Developer       │  GRPCRoute,         │  methods map to which     │
│  (product team)  │  TCPRoute, ...      │  Services, with which     │
│                  │  (namespaced, in    │  weights and filters      │
│                  │   the app namespace)│                           │
└──────────────────┴─────────────────────┴───────────────────────────┘
```

### Why This Split Is the Headline Feature

With Ingress, granting a team the ability to add a path also grants them the ability to change the hostname, swap the TLS certificate, or hijack another team's route, because RBAC only understands whole objects.

With Gateway API:

```
RBAC for the app team:
  ✅ create/update/delete HTTPRoute in their own namespace
  ❌ no access to Gateway at all

Result:
  • They can route /orders to their Service.
  • They CANNOT change which hostname the Gateway serves.
  • They CANNOT replace the TLS certificate.
  • They CANNOT attach to a Gateway whose allowedRoutes excludes them.
  • The Gateway owner controls exactly which namespaces may attach.
```

The permission model is **bidirectional**: the route says which Gateway it wants (`parentRefs`), and the Gateway says which routes it accepts (`allowedRoutes`). Attachment happens only when both agree.

---

## The Resource Model

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        GATEWAY API RESOURCE MODEL                        │
│                                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐  │
│   │  GatewayClass                          cluster scoped            │  │
│   │  ─────────────────────────────────────────────────────────────   │  │
│   │  spec.controllerName: example.net/gateway-controller             │  │
│   │  spec.parametersRef:  vendor specific tuning object              │  │
│   │                                                                  │  │
│   │  Analogous to StorageClass: a template for what gets created.    │  │
│   └────────────────────────────┬─────────────────────────────────────┘  │
│                                │ gatewayClassName                        │
│                                ▼                                         │
│   ┌──────────────────────────────────────────────────────────────────┐  │
│   │  Gateway                               namespaced (infra ns)     │  │
│   │  ─────────────────────────────────────────────────────────────   │  │
│   │  spec.listeners:                                                 │  │
│   │    - name: http     port: 80   protocol: HTTP                    │  │
│   │    - name: https    port: 443  protocol: HTTPS                   │  │
│   │        hostname: "*.example.com"                                 │  │
│   │        tls: { mode: Terminate, certificateRefs: [...] }          │  │
│   │        allowedRoutes: { namespaces: { from: Selector, ... } }    │  │
│   │  status.addresses: the real IP that got provisioned              │  │
│   │                                                                  │  │
│   │  Creating this usually causes real infrastructure to appear:     │  │
│   │  a cloud load balancer, or a Deployment of proxy pods.           │  │
│   └───────▲──────────────────────────────────────────▲───────────────┘  │
│           │ parentRefs                                │ parentRefs       │
│           │ (route requests attachment)               │                  │
│           │ allowedRoutes must permit it              │                  │
│   ┌───────┴───────────────────┐        ┌──────────────┴───────────────┐  │
│   │  HTTPRoute   ns: team-a   │        │  HTTPRoute   ns: team-b      │  │
│   │  ───────────────────────  │        │  ──────────────────────────  │  │
│   │  hostnames:               │        │  hostnames:                  │  │
│   │    - a.example.com        │        │    - b.example.com           │  │
│   │  rules:                   │        │  rules:                      │  │
│   │    - matches: [path,hdr]  │        │    - matches: [path]         │  │
│   │      filters: [...]       │        │      backendRefs:            │  │
│   │      backendRefs:         │        │        - name: svc-b         │  │
│   │        - name: v1 wt: 90  │        │          port: 80            │  │
│   │        - name: v2 wt: 10  │        │                              │  │
│   └───────┬───────────────────┘        └──────────────┬───────────────┘  │
│           │ backendRefs                               │                   │
│           ▼                                           ▼                   │
│   ┌───────────────────┐                     ┌───────────────────┐        │
│   │ Service v1 / v2   │                     │ Service svc-b     │        │
│   │  ns: team-a       │                     │  ns: team-b       │        │
│   └───────────────────┘                     └───────────────────┘        │
│                                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐  │
│   │  ReferenceGrant            lives in the TARGET namespace          │  │
│   │  Grants permission for a cross namespace reference, in the        │  │
│   │  direction target-namespace-says-yes. Without it, any cross       │  │
│   │  namespace backendRef or certificateRef is REFUSED.               │  │
│   └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐  │
│   │  BackendTLSPolicy   targets a Service; describes how the gateway  │  │
│   │  must validate TLS on the connection TO the backend (re-encrypt). │  │
│   └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### The Ingress Analogy

```
   Ingress world                     Gateway API world
   ───────────────                   ─────────────────
   IngressClass          maps to     GatewayClass
   (the controller side              (the controller side of the
    of an Ingress)                    Gateway, plus parameters)

   Ingress                maps to    Gateway   +   HTTPRoute
   (one object doing                 (listener,     (routing rules,
    both jobs)                        TLS, ports)    backends, filters)
```

Or, in one line: **GatewayClass is to Gateway what StorageClass is to PersistentVolumeClaim.**

---

## Installing the CRDs

Gateway API ships as CRDs from the `kubernetes-sigs/gateway-api` project, released independently of Kubernetes itself. Nothing is built in.

```bash
# 1. Install the CRDs. Pick a release tag from the releases page.
#    The Standard channel contains the GA and beta resources.
GATEWAY_API_VERSION=<pick-a-release-tag>
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# The Experimental channel adds alpha resources (TCPRoute, UDPRoute,
# TLSRoute and experimental fields). Install ONE channel, not both.
# kubectl apply -f ".../${GATEWAY_API_VERSION}/experimental-install.yaml"

# 2. Verify what landed
kubectl get crd | grep gateway.networking.k8s.io
kubectl api-resources --api-group=gateway.networking.k8s.io

# Expect (Standard channel):
#   gatewayclasses    gc     gateway.networking.k8s.io/v1     false   GatewayClass
#   gateways          gtw    gateway.networking.k8s.io/v1     true    Gateway
#   grpcroutes               gateway.networking.k8s.io/v1     true    GRPCRoute
#   httproutes               gateway.networking.k8s.io/v1     true    HTTPRoute
#   referencegrants   refgrant gateway.networking.k8s.io/v1beta1 true ReferenceGrant

# 3. Confirm the exact served versions rather than assuming
kubectl explain gateway --recursive | head -40
kubectl explain httproute.spec.rules.filters
```

> ⚠️ Installing the CRDs alone does exactly nothing, just like creating an Ingress with no controller. You must then install an implementation. Some implementations (Istio, Cilium) can install the CRDs for you; installing them twice from two sources causes ownership conflicts.

```bash
# 4. Install an implementation, then confirm a GatewayClass appeared
kubectl get gatewayclass
# NAME       CONTROLLER                                      ACCEPTED   AGE
# nginx      gateway.nginx.org/nginx-gateway-controller      True       2m
```

---

## GatewayClass

Cluster scoped. Declares that a particular controller implementation is available and, optionally, points at vendor specific parameters.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: external-lb                     # the string Gateways put in gatewayClassName
spec:
  # REQUIRED and IMMUTABLE. A domain prefixed path that identifies the
  # controller implementation. Each project publishes its own value.
  controllerName: example.net/gateway-controller

  # Optional human readable text, surfaced by kubectl and dashboards.
  description: "Internet facing gateways, provisioned in the DMZ VLAN"

  # Optional vendor specific configuration object. The KIND and the
  # meaning are entirely defined by the controller, which is where
  # implementation specific tuning lives instead of in annotations.
  parametersRef:
    group: example.net
    kind: GatewayParameters
    name: dmz-defaults
    namespace: infra                    # required when the kind is namespaced

status:
  conditions:
  - type: Accepted                      # controller recognised this class
    status: "True"
    reason: Accepted
  - type: SupportedVersion              # CRD bundle version is compatible
    status: "True"
    reason: SupportedVersion
```

Key properties:

| Property | Value |
|----------|-------|
| Scope | Cluster |
| `spec.controllerName` | Required, immutable |
| Who creates it | The implementation's install manifests, or a platform admin |
| Analogy | `StorageClass`, `IngressClass` |
| Multiple per cluster | Yes, and normal: `internal`, `external`, `mesh` |

```bash
kubectl get gatewayclass -o custom-columns=\
'NAME:.metadata.name,CONTROLLER:.spec.controllerName,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status'

kubectl describe gatewayclass external-lb
```

> ⚠️ If `Accepted` is `False` or missing, no controller has claimed the class. Every Gateway referencing it will remain unprogrammed. Check that `controllerName` exactly matches what your installed implementation publishes; the strings are long and easy to mistype.

---

## Gateway and Listeners

A Gateway is a request for infrastructure. Creating one typically provisions a cloud load balancer or a Deployment of proxy pods.

### Fully Annotated Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: prod-gateway
  namespace: infra                      # cluster operators own this namespace;
                                        # app teams have no RBAC here
spec:
  gatewayClassName: external-lb         # which GatewayClass, and therefore
                                        # which controller, implements this

  # Optional. Request a specific address instead of a dynamic one.
  # Support varies by implementation; on bare metal with MetalLB this
  # is how you pin the VIP.
  addresses:
  - type: IPAddress
    value: 192.168.1.241

  listeners:
  # ------------------------------------------------------------------
  # Listener 1: plain HTTP, used only to redirect to HTTPS
  # ------------------------------------------------------------------
  - name: http                          # REQUIRED, unique within the Gateway.
                                        # Routes target it via sectionName.
    port: 80
    protocol: HTTP                      # HTTP | HTTPS | TLS | TCP | UDP
    hostname: "*.example.com"           # optional. Constrains which route
                                        # hostnames may attach here.
    allowedRoutes:
      namespaces:
        from: Same                      # All | Same | Selector

  # ------------------------------------------------------------------
  # Listener 2: HTTPS terminating a wildcard certificate
  # ------------------------------------------------------------------
  - name: https
    port: 443
    protocol: HTTPS
    hostname: "*.example.com"
    tls:
      mode: Terminate                   # Terminate | Passthrough
      certificateRefs:
      - kind: Secret
        group: ""                       # core group for Secret
        name: wildcard-example-tls      # type kubernetes.io/tls
        # namespace: certs              # cross namespace requires a
                                        # ReferenceGrant in that namespace
      options:                          # implementation specific TLS knobs,
        {}                              # for example minimum protocol version
    allowedRoutes:
      kinds:                            # restrict which route KINDS may attach
      - group: gateway.networking.k8s.io
        kind: HTTPRoute
      namespaces:
        from: Selector                  # only namespaces matching the selector
        selector:
          matchLabels:
            gateway-access: "true"

  # ------------------------------------------------------------------
  # Listener 3: TLS passthrough for a service that must terminate
  # its own TLS (client certificate auth, for example)
  # ------------------------------------------------------------------
  - name: passthrough
    port: 8443
    protocol: TLS
    hostname: mtls.example.com
    tls:
      mode: Passthrough                 # NO certificateRefs; the gateway
                                        # never decrypts, it routes by SNI
    allowedRoutes:
      kinds:
      - group: gateway.networking.k8s.io
        kind: TLSRoute                  # Passthrough needs a TLSRoute,
                                        # not an HTTPRoute
      namespaces:
        from: Same

status:
  addresses:                            # written by the controller
  - type: IPAddress
    value: 192.168.1.241
  conditions:
  - type: Accepted
    status: "True"
  - type: Programmed                    # the data plane is actually configured
    status: "True"
  listeners:
  - name: https
    attachedRoutes: 3                   # how many routes successfully attached
    conditions:
    - type: Accepted
      status: "True"
    - type: Programmed
      status: "True"
    - type: ResolvedRefs                # certificateRefs resolved successfully
      status: "True"
```

### Listener Fields Explained

| Field | Purpose | Notes |
|-------|---------|-------|
| `name` | Unique listener identifier | Required. Routes can target one listener via `parentRefs.sectionName` |
| `port` | Port the gateway listens on | Not restricted to 80/443, unlike Ingress |
| `protocol` | `HTTP`, `HTTPS`, `TLS`, `TCP`, `UDP` | Determines which route kinds may attach |
| `hostname` | Restricts hostnames served here | Wildcard covers one leftmost label, same rule as Ingress |
| `tls.mode` | `Terminate` or `Passthrough` | `Terminate` requires `certificateRefs`; `Passthrough` forbids them |
| `tls.certificateRefs` | Secrets of type `kubernetes.io/tls` | Multiple allowed; the gateway picks by SNI |
| `allowedRoutes.namespaces.from` | `All`, `Same`, `Selector` | Default is `Same` |
| `allowedRoutes.namespaces.selector` | Label selector over Namespaces | Required when `from: Selector` |
| `allowedRoutes.kinds` | Which route kinds may attach | Defaults to the kinds valid for the protocol |

### Terminate vs Passthrough

```
┌────────────────────────────────────────────────────────────────────┐
│  mode: Terminate                                                    │
│                                                                     │
│   Client ══TLS══► Gateway ──plaintext──► Backend Pod                │
│                      │                                              │
│                      └── can read Host, path, headers, method       │
│                          so HTTPRoute matching and filters work     │
│                                                                     │
│   Certificate lives in a Kubernetes Secret, managed by the          │
│   cluster operator or by cert-manager.                              │
├────────────────────────────────────────────────────────────────────┤
│  mode: Passthrough                                                  │
│                                                                     │
│   Client ══════════TLS════════════════► Backend Pod                 │
│                      │                                              │
│                      └── sees ONLY the SNI name in the ClientHello  │
│                          cannot read path, headers or method        │
│                                                                     │
│   Use TLSRoute, not HTTPRoute. Routing is by SNI only.              │
│   Required when the backend must see the client certificate.        │
└────────────────────────────────────────────────────────────────────┘
```

### Re-encryption

Gateway API separates the two TLS hops cleanly:

- **Frontend TLS** (client to gateway): `listeners[].tls`.
- **Backend TLS** (gateway to pod): `BackendTLSPolicy`, attached to the Service. See [BackendTLSPolicy](#backendtlspolicy).

That is a real improvement over Ingress, where the backend hop was a vendor annotation.

### Shared vs Dedicated Gateways

```
┌────────────────────────────────────────────────────────────────────┐
│  SHARED GATEWAY (recommended default)                               │
│    One Gateway in "infra", many namespaces attach routes.           │
│    + One IP, one certificate, one cost centre                       │
│    + Cluster operator keeps control of hostnames and TLS            │
│    - Blast radius: a misconfigured listener affects everyone        │
├────────────────────────────────────────────────────────────────────┤
│  DEDICATED GATEWAY PER TEAM                                         │
│    Each team gets its own Gateway, its own IP.                      │
│    + Full isolation, independent lifecycle                          │
│    - One load balancer and one IP per team, the Ingress cost        │
│      problem returns                                                │
├────────────────────────────────────────────────────────────────────┤
│  SPLIT BY EXPOSURE                                                  │
│    gatewayClassName: external-lb  ──► internet facing               │
│    gatewayClassName: internal-lb  ──► private VLAN only             │
│    The most common real world layout.                               │
└────────────────────────────────────────────────────────────────────┘
```

### Bare Metal Addressing

On bare metal, the Gateway controller creates a `Service type: LoadBalancer` for its proxy pods, which stays `<pending>` unless something assigns an external IP. MetalLB is the usual answer, exactly as it is for ingress-nginx.

```bash
# Find the Service the gateway controller provisioned
kubectl -n infra get svc -l gateway.networking.k8s.io/gateway-name=prod-gateway

# Once MetalLB assigns a VIP, it shows up in the Gateway status
kubectl -n infra get gateway prod-gateway \
  -o jsonpath='{.status.addresses[*].value}{"\n"}'
```

See [metallb.md](metallb.md) and [install-metallb.md](install-metallb.md); the pool used in this repository is `k8s-workshop/metallb-ip-pool.yaml`.

---

## HTTPRoute

The application developer's resource. Namespaced, lives beside the Services it routes to.

### Fully Annotated HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-route
  namespace: team-a
spec:
  # ------------------------------------------------------------------
  # WHICH Gateway (or Gateways) this route wants to attach to.
  # Attachment only happens if the Gateway's allowedRoutes agrees.
  # ------------------------------------------------------------------
  parentRefs:
  - group: gateway.networking.k8s.io   # defaults to this
    kind: Gateway                      # defaults to Gateway
    name: prod-gateway
    namespace: infra                   # omit to mean "this namespace"
    sectionName: https                 # optional: attach ONLY to the
                                       # listener named "https". Omit to
                                       # attach to every compatible listener.
    # port: 443                        # optional alternative to sectionName

  # ------------------------------------------------------------------
  # Hostnames this route serves. Intersected with the listener hostname.
  # Empty means "everything the listener allows".
  # ------------------------------------------------------------------
  hostnames:
  - shop.example.com
  - www.shop.example.com

  rules:
  # ----------------------------------------------------------------
  # Rule 1: API traffic, with a rewrite and an injected header
  # ----------------------------------------------------------------
  - matches:
    - path:
        type: PathPrefix               # Exact | PathPrefix | RegularExpression
        value: /api
      method: GET                      # optional HTTP method match
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch     # strips /api before proxying
          replacePrefixMatch: /
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: X-Gateway
          value: prod
    backendRefs:
    - name: api-svc
      port: 8080
      weight: 1                        # single backend, weight is irrelevant

  # ----------------------------------------------------------------
  # Rule 2: everything else to the web frontend
  # ----------------------------------------------------------------
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web-svc
      port: 80

status:
  parents:                             # ONE entry per parentRef
  - parentRef:
      name: prod-gateway
      namespace: infra
      sectionName: https
    controllerName: example.net/gateway-controller
    conditions:
    - type: Accepted
      status: "True"
      reason: Accepted
    - type: ResolvedRefs
      status: "True"
      reason: ResolvedRefs
```

### The Shape of a Rule

```
spec.rules[]
  ├── matches[]      WHEN does this rule apply?   (OR between entries,
  │                                                AND within one entry)
  ├── filters[]      WHAT do we do to the request before forwarding?
  ├── backendRefs[]  WHERE does it go, and in what proportion?
  └── timeouts       HOW long do we wait?  (availability varies by
                     API version and implementation, check kubectl explain)
```

Critical boolean logic:

```
matches:
- path: {type: PathPrefix, value: /api}      ┐
  headers:                                    │ entry 1: path AND header
  - name: X-Env                               │
    value: prod                               ┘
- path: {type: PathPrefix, value: /v2}       ┐ entry 2
                                              ┘

Rule applies if (entry 1) OR (entry 2).
Within entry 1, BOTH the path and the header must match.
```

---

## Matches

### Path Matching

| `type` | Semantics | Support level |
|--------|-----------|---------------|
| `Exact` | The path must equal `value` byte for byte | Core, every conformant implementation |
| `PathPrefix` | Element by element prefix, identical rule to Ingress `Prefix` | Core, every conformant implementation |
| `RegularExpression` | Implementation defined regex dialect | Implementation specific, not portable |

Default when `path` is omitted: `PathPrefix` with value `/`.

```
PathPrefix /api

  /api              ✅
  /api/             ✅
  /api/v1/users     ✅
  /apiary           ❌   element boundary, "api" != "apiary"
  /API              ❌   path matching is case sensitive
```

### Header Matching

```yaml
matches:
- headers:
  - type: Exact               # Exact | RegularExpression
    name: X-Environment       # header names are case insensitive
    value: staging            # values are case SENSITIVE
  - type: Exact
    name: X-Tenant
    value: acme
```

Multiple headers inside one match entry are ANDed. Header **names** are case insensitive per HTTP, header **values** are compared case sensitively. Duplicate header names within one match entry are invalid.

### Query Parameter Matching

```yaml
matches:
- queryParams:
  - type: Exact               # Exact | RegularExpression
    name: version
    value: beta
  path:
    type: PathPrefix
    value: /app
```

Query parameter names and values are both case sensitive. Behaviour with repeated parameters (`?a=1&a=2`) is implementation specific, so do not rely on it.

### Method Matching

```yaml
matches:
- method: POST                # GET POST PUT DELETE PATCH HEAD OPTIONS
                              # CONNECT TRACE
  path:
    type: PathPrefix
    value: /orders
```

Something Ingress simply cannot express. Useful for splitting reads and writes to different backends, or blocking mutating verbs on a read replica.

### Combined Example

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rich-matching
  namespace: team-a
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra
  hostnames:
  - api.example.com
  rules:
  # Writes go to the primary
  - matches:
    - path: { type: PathPrefix, value: /orders }
      method: POST
    - path: { type: PathPrefix, value: /orders }
      method: PUT
    - path: { type: PathPrefix, value: /orders }
      method: DELETE
    backendRefs:
    - name: orders-primary
      port: 8080

  # Reads from an internal client go to the read replica
  - matches:
    - path: { type: PathPrefix, value: /orders }
      method: GET
      headers:
      - type: Exact
        name: X-Client-Tier
        value: internal
    backendRefs:
    - name: orders-replica
      port: 8080

  # Everything else
  - matches:
    - path: { type: PathPrefix, value: / }
    backendRefs:
    - name: orders-primary
      port: 8080
```

### Matching Precedence

When several rules match one request, the spec defines a deterministic order so behaviour is portable.

```
┌────────────────────────────────────────────────────────────────────┐
│  STEP 1: pick the hostname                                          │
│    Exact hostname  >  wildcard hostname  >  no hostname             │
│    Among wildcards, the one with more characters wins.              │
│                                                                     │
│  STEP 2: among matching rules, the FIRST of these wins              │
│    a. an Exact path match                                           │
│    b. the LONGEST PathPrefix match (by character count)             │
│    c. a method match present                                        │
│    d. the LARGEST number of header matches                          │
│    e. the LARGEST number of query parameter matches                 │
│                                                                     │
│  STEP 3: still tied? break the tie across routes by                 │
│    a. the OLDEST route by creationTimestamp                         │
│    b. then alphabetically by "{namespace}/{name}"                   │
│    c. then by the order the rule appears inside the route           │
└────────────────────────────────────────────────────────────────────┘
```

The creation timestamp tie break has a real consequence: an existing route cannot be hijacked by a newer route in another namespace claiming the same hostname and path. First writer wins.

---

## Filters

Filters transform the request or response. They live at `rules[].filters` (broad support) or at `backendRefs[].filters` (implementation specific support, use rule level unless you have a reason not to).

| Filter type | Purpose | Support level |
|-------------|---------|---------------|
| `RequestHeaderModifier` | Add, set or remove request headers | Core |
| `ResponseHeaderModifier` | Add, set or remove response headers | Extended |
| `RequestRedirect` | Return a redirect without contacting a backend | Core |
| `URLRewrite` | Change the hostname or path sent upstream | Extended |
| `RequestMirror` | Copy traffic to a second backend, discard the response | Extended |
| `ExtensionRef` | Point at a vendor CRD, the sanctioned extension point | Implementation specific |

> ⚠️ `RequestHeaderModifier`, `ResponseHeaderModifier`, `RequestRedirect` and `URLRewrite` may each appear **at most once** per rule.

### RequestHeaderModifier

```yaml
filters:
- type: RequestHeaderModifier
  requestHeaderModifier:
    set:                         # replace the value, or create it
    - name: X-Environment
      value: production
    add:                         # append to an existing multi value header
    - name: X-Forwarded-Extra
      value: gateway-api
    remove:                      # strip headers before they reach the app
    - X-Internal-Debug
    - Authorization
```

`set` overwrites, `add` appends. Removing `Authorization` before it reaches an untrusted backend is a genuinely useful security pattern.

### ResponseHeaderModifier

```yaml
filters:
- type: ResponseHeaderModifier
  responseHeaderModifier:
    set:
    - name: Strict-Transport-Security
      value: "max-age=31536000; includeSubDomains"
    - name: X-Content-Type-Options
      value: nosniff
    remove:
    - Server
    - X-Powered-By
```

Security headers applied at the edge, without touching any application code.

### RequestRedirect

```yaml
filters:
- type: RequestRedirect
  requestRedirect:
    scheme: https                # http | https
    hostname: new.example.com    # optional, keeps the original if omitted
    port: 443                    # optional
    statusCode: 301              # 301 or 302 only
    path:
      type: ReplaceFullPath      # ReplaceFullPath | ReplacePrefixMatch
      replaceFullPath: /moved
```

> ⚠️ A rule containing a `RequestRedirect` filter **must not** also declare `backendRefs`. The request never reaches a backend, so the two are mutually exclusive and the API rejects the combination.

The classic http to https redirect, expressed as a whole listener:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: infra
spec:
  parentRefs:
  - name: prod-gateway
    sectionName: http            # attach ONLY to the port 80 listener
  hostnames:
  - "shop.example.com"
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
    # no backendRefs, deliberately
```

Compare with Ingress, where this is the `ssl-redirect` annotation with implicit, controller specific behaviour.

### URLRewrite

```yaml
filters:
- type: URLRewrite
  urlRewrite:
    hostname: internal.svc.cluster.local   # rewrite the Host header upstream
    path:
      type: ReplacePrefixMatch             # ReplacePrefixMatch | ReplaceFullPath
      replacePrefixMatch: /
```

`ReplacePrefixMatch` replaces the part of the path that the rule's `PathPrefix` match consumed, and preserves the remainder. That is the well behaved, typed version of the ingress-nginx `rewrite-target: /$2` regex dance.

```
Rule match:  PathPrefix /api
Filter:      ReplacePrefixMatch /

  /api            ──►  /
  /api/           ──►  /
  /api/v1/users   ──►  /v1/users
  /api/v1?x=1     ──►  /v1?x=1
```

```
Filter:      ReplacePrefixMatch /internal

  /api/v1/users   ──►  /internal/v1/users
```

> ⚠️ `ReplacePrefixMatch` is only meaningful when the rule's path match is `PathPrefix`. With an `Exact` match, use `ReplaceFullPath`.

### RequestMirror

```yaml
filters:
- type: RequestMirror
  requestMirror:
    backendRef:
      name: shadow-svc
      port: 8080
      # namespace: observability   # cross namespace needs a ReferenceGrant
backendRefs:
- name: prod-svc
  port: 8080
```

The mirrored request is **fire and forget**: the response from the mirror backend is discarded and never affects the client. This is how you validate a new version against real production traffic with zero user impact.

> ⚠️ Mirroring duplicates writes. If the mirrored request is a `POST` against a shared database, you will double the writes. Mirror to an isolated stack, or restrict mirroring to safe methods with a `method: GET` match.

### Combined Filter Chain

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: full-filter-chain
  namespace: team-a
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra
  hostnames:
  - shop.example.com
  rules:
  - matches:
    - path: { type: PathPrefix, value: /api }
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: X-Environment
          value: production
        remove:
        - X-Internal-Debug
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Content-Type-Options
          value: nosniff
        remove:
        - Server
    - type: RequestMirror
      requestMirror:
        backendRef:
          name: api-shadow
          port: 8080
    backendRefs:
    - name: api-svc
      port: 8080
```

---

## Backend References and Weights

```yaml
backendRefs:
- group: ""                 # "" is the core API group (Service)
  kind: Service             # defaults to Service; some implementations
                            # also accept ServiceImport or vendor kinds
  name: api-v1
  namespace: team-a         # omit for "same namespace as the route";
                            # cross namespace requires a ReferenceGrant
  port: 8080                # REQUIRED for Service backends
  weight: 90                # relative share, default 1, valid 0 to 1,000,000
  filters: []               # per backend filters, support is
                            # implementation specific
```

### Weight Semantics

```
┌────────────────────────────────────────────────────────────────────┐
│  Weights are RELATIVE, not percentages.                             │
│                                                                     │
│    share(backend) = weight(backend) / sum(all weights in the rule)  │
│                                                                     │
│  90 and 10   ──►  90% and 10%                                       │
│  9  and 1    ──►  90% and 10%     (identical behaviour)             │
│  3, 1, 1     ──►  60%, 20%, 20%                                     │
│                                                                     │
│  Special cases:                                                     │
│    • weight omitted            ──►  defaults to 1                   │
│    • weight: 0                 ──►  that backend receives NO traffic │
│                                     but stays configured, so you can │
│                                     flip it back instantly           │
│    • ALL weights are 0         ──►  the gateway returns 503          │
│    • backendRefs empty/absent  ──►  the gateway returns 500          │
│    • a backendRef cannot be    ──►  ResolvedRefs goes False and      │
│      resolved                       that backend returns 500         │
└────────────────────────────────────────────────────────────────────┘
```

Distribution is statistical, not a strict round robin. Over a small number of requests a 90/10 split will not land exactly nine to one.

---

## Traffic Splitting for Canary

This is the feature that most often triggers the migration from Ingress. In Ingress it needs two coupled objects and vendor annotations; here it is two lines.

### The Progression

```
┌────────────────────────────────────────────────────────────────────┐
│  Step 0  v1: 100    v2: 0     v2 deployed, receiving nothing        │
│  Step 1  v1: 99     v2: 1     1% smoke test                         │
│  Step 2  v1: 90     v2: 10    10% canary, watch error rate and p99  │
│  Step 3  v1: 50     v2: 50    half and half                         │
│  Step 4  v1: 10     v2: 90    mostly migrated                       │
│  Step 5  v1: 0      v2: 100   v1 idle but still configured          │
│  Step 6  remove the v1 backendRef entirely, scale down v1           │
│                                                                     │
│  Rollback at ANY step is a single kubectl patch of the weights.     │
│  No pod restarts, no config reload, no DNS change.                  │
└────────────────────────────────────────────────────────────────────┘
```

### Complete 90/10 Worked Example

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    gateway-access: "true"          # matches the Gateway's namespace selector
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-v1
  namespace: team-a
spec:
  replicas: 9
  selector:
    matchLabels: { app: shop, version: v1 }
  template:
    metadata:
      labels: { app: shop, version: v1 }
    spec:
      containers:
      - name: shop
        image: hashicorp/http-echo
        args: ["-text=v1", "-listen=:8080"]
        ports:
        - name: http
          containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: shop-v1
  namespace: team-a
spec:
  selector: { app: shop, version: v1 }
  ports:
  - name: http
    port: 8080
    targetPort: http
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-v2
  namespace: team-a
spec:
  replicas: 1
  selector:
    matchLabels: { app: shop, version: v2 }
  template:
    metadata:
      labels: { app: shop, version: v2 }
    spec:
      containers:
      - name: shop
        image: hashicorp/http-echo
        args: ["-text=v2", "-listen=:8080"]
        ports:
        - name: http
          containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: shop-v2
  namespace: team-a
spec:
  selector: { app: shop, version: v2 }
  ports:
  - name: http
    port: 8080
    targetPort: http
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-canary
  namespace: team-a
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra
    sectionName: https
  hostnames:
  - shop.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: shop-v1
      port: 8080
      weight: 90            # 90 / (90 + 10) = 90 percent
    - name: shop-v2
      port: 8080
      weight: 10            # 10 percent
```

### Driving the Rollout

```bash
NS=team-a
RT=shop-canary

shift_weights () {
  kubectl -n "$NS" patch httproute "$RT" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":$1},
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":$2}
  ]"
}

shift_weights 99 1        # 1 percent
shift_weights 90 10       # 10 percent
shift_weights 50 50       # half
shift_weights 0 100       # fully cut over
shift_weights 100 0       # INSTANT ROLLBACK

# Verify empirically
LB=$(kubectl -n infra get gateway prod-gateway -o jsonpath='{.status.addresses[0].value}')
for i in $(seq 1 200); do
  curl -s --resolve shop.example.com:80:$LB http://shop.example.com/
done | sort | uniq -c
#  179 v1
#   21 v2
```

> 💡 Weights control the **share of requests**, not the number of replicas. Keep replica counts proportional to the weight so the canary is not overwhelmed: 10 percent of traffic hitting a single pod that normally has nine peers means that pod carries roughly the same per pod load, which is exactly what you want for a fair comparison.

See [deployment-strategies.md](deployment-strategies.md) for how this compares with rolling updates and blue green.

---

## Header Based Routing for A/B Testing

Weight based splitting is random per request, so one user can bounce between versions. Header based routing is deterministic: the same client always lands on the same version.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-ab-test
  namespace: team-a
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra
    sectionName: https
  hostnames:
  - shop.example.com
  rules:
  # ----------------------------------------------------------------
  # Rule 1: explicit opt in. Beta testers and internal QA.
  # More header matches than the catch all rule, so this wins.
  # ----------------------------------------------------------------
  - matches:
    - headers:
      - type: Exact
        name: X-Beta-User
        value: "true"
      path:
        type: PathPrefix
        value: /
    filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Served-Version
          value: v2
    backendRefs:
    - name: shop-v2
      port: 8080

  # ----------------------------------------------------------------
  # Rule 2: cohort routing on a sticky value the client already sends
  # ----------------------------------------------------------------
  - matches:
    - headers:
      - type: RegularExpression
        name: X-User-Cohort
        value: "^(experiment-.*)$"
      path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: shop-v2
      port: 8080

  # ----------------------------------------------------------------
  # Rule 3: everyone else stays on v1
  # ----------------------------------------------------------------
  - matches:
    - path:
        type: PathPrefix
        value: /
    filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        set:
        - name: X-Served-Version
          value: v1
    backendRefs:
    - name: shop-v1
      port: 8080
```

```bash
LB=$(kubectl -n infra get gateway prod-gateway -o jsonpath='{.status.addresses[0].value}')

curl -s --resolve shop.example.com:80:$LB \
  -H "X-Beta-User: true" http://shop.example.com/        # always v2

curl -s --resolve shop.example.com:80:$LB \
  http://shop.example.com/                               # always v1
```

### Combining Both Strategies

```yaml
rules:
# Deterministic opt in first
- matches:
  - headers:
    - {type: Exact, name: X-Beta-User, value: "true"}
  backendRefs:
  - {name: shop-v2, port: 8080}

# Then a percentage of everyone else
- matches:
  - path: {type: PathPrefix, value: /}
  backendRefs:
  - {name: shop-v1, port: 8080, weight: 95}
  - {name: shop-v2, port: 8080, weight: 5}
```

> ⚠️ `RegularExpression` header matching is implementation specific. If portability matters, stick to `Exact`.

---

## Cross Namespace Routing and ReferenceGrant

### The Rule

```
┌────────────────────────────────────────────────────────────────────┐
│  Any reference that CROSSES a namespace boundary is DENIED by       │
│  default and must be explicitly permitted by the namespace being    │
│  referenced.                                                        │
│                                                                     │
│  This is the opposite of Ingress, which simply forbade cross        │
│  namespace references outright and had no permission model at all.  │
└────────────────────────────────────────────────────────────────────┘
```

Two directions to keep straight:

| Direction | Mechanism | Who grants |
|-----------|-----------|------------|
| Route in namespace A attaches to a Gateway in namespace B | `allowedRoutes` on the Gateway listener | The Gateway owner |
| Route in namespace A points at a Service in namespace C | `ReferenceGrant` in namespace C | The Service owner |

Also protected by `ReferenceGrant`: a Gateway's `certificateRefs` pointing at a Secret in another namespace, and a `RequestMirror` backendRef in another namespace.

### The Threat Being Prevented

```
Without a permission model:

  Attacker creates an HTTPRoute in namespace "evil" with
    backendRefs: [{name: postgres, namespace: production, port: 5432}]

  ==> The gateway happily proxies internet traffic straight into
      the production database, bypassing every NetworkPolicy that
      only considered pod to pod traffic.

With ReferenceGrant:

  ==> ResolvedRefs: False, reason RefNotPermitted. Nothing is exposed
      unless the "production" namespace explicitly said yes.
```

### The ReferenceGrant Object

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1   # note: still v1beta1
kind: ReferenceGrant
metadata:
  name: allow-team-a-routes
  namespace: shared-services      # MUST live in the namespace being
                                  # referenced, the one granting access
spec:
  # WHO is allowed to reference into this namespace
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: team-a             # required, no wildcards

  # WHAT they are allowed to reference
  to:
  - group: ""                     # core group
    kind: Service
    name: shared-api              # OPTIONAL. Omit to allow ALL Services
                                  # of this kind in the namespace.
```

Properties to memorise:

- Lives in the **target** namespace, the one that owns the resource being referenced.
- `from[].namespace` is **required**; there are no wildcards, which is deliberate.
- `to[].name` is optional; omitting it grants access to every object of that kind in the namespace, so name it whenever you can.
- One grant can list several `from` and several `to` entries.

### Full Cross Namespace Example

```yaml
# ============================================================
# infra namespace: the Gateway, owned by the cluster operator
# ============================================================
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: prod-gateway
  namespace: infra
spec:
  gatewayClassName: external-lb
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    hostname: "*.example.com"
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: wildcard-example-tls
    allowedRoutes:
      kinds:
      - group: gateway.networking.k8s.io
        kind: HTTPRoute
      namespaces:
        from: Selector
        selector:
          matchLabels:
            gateway-access: "true"     # only opted in namespaces
---
# ============================================================
# team-a namespace: the route, owned by the app team
# ============================================================
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    gateway-access: "true"             # required by the selector above
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: portal
  namespace: team-a
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra                   # CROSS NAMESPACE attachment,
                                       # permitted by allowedRoutes
  hostnames:
  - portal.example.com
  rules:
  # Local backend, no grant needed
  - matches:
    - path: { type: PathPrefix, value: /ui }
    backendRefs:
    - name: portal-ui
      port: 80

  # Backend in ANOTHER namespace, needs a ReferenceGrant over there
  - matches:
    - path: { type: PathPrefix, value: /api }
    backendRefs:
    - name: shared-api
      namespace: shared-services
      port: 8080
---
# ============================================================
# shared-services namespace: the grant, owned by that team
# ============================================================
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-team-a-to-shared-api
  namespace: shared-services
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: team-a
  to:
  - group: ""
    kind: Service
    name: shared-api
```

```
┌────────────────────────────────────────────────────────────────────┐
│                   THE THREE WAY HANDSHAKE                           │
│                                                                     │
│   team-a HTTPRoute      "I want to attach to infra/prod-gateway     │
│                          and send /api to shared-services/shared-api"│
│                                                                     │
│   infra Gateway         "Namespaces labelled gateway-access=true    │
│                          may attach HTTPRoutes"          ✅ team-a  │
│                                                                     │
│   shared-services       "HTTPRoutes from team-a may reference       │
│   ReferenceGrant         the Service named shared-api"   ✅          │
│                                                                     │
│   All three must agree. Remove any one and traffic stops.           │
└────────────────────────────────────────────────────────────────────┘
```

### Verifying

```bash
kubectl -n shared-services get referencegrant
kubectl -n team-a describe httproute portal | sed -n '/Status/,$p'

# The tell tale failure
#   Type:    ResolvedRefs
#   Status:  False
#   Reason:  RefNotPermitted
```

Note that `ReferenceGrant` is an authorisation control at the **API** layer. It does not create network level enforcement. Keep using [network-policy.md](network-policy.md) for defence in depth.

---

## BackendTLSPolicy

`BackendTLSPolicy` describes how the gateway must validate TLS on the connection **to** the backend, which is the re-encryption half of end to end TLS.

```
┌────────────────────────────────────────────────────────────────────┐
│                     End to end TLS, both hops typed                 │
│                                                                     │
│   Client ══TLS══► Gateway ══TLS══► Backend Pod                      │
│              │                │                                     │
│              │                └─ BackendTLSPolicy                   │
│              │                   • which CA validates the backend   │
│              │                   • which hostname to verify (SNI    │
│              │                     and certificate subject)         │
│              │                                                      │
│              └─ Gateway listener tls.certificateRefs                │
│                 • which certificate the client sees                 │
│                                                                     │
│   With Ingress this second hop was the untyped annotation           │
│   nginx.ingress.kubernetes.io/backend-protocol: "HTTPS", with       │
│   no way to express CA validation or hostname verification.         │
└────────────────────────────────────────────────────────────────────┘
```

Conceptual shape (the API group version for this resource is still evolving, so check `kubectl api-resources` and `kubectl explain backendtlspolicy` in your cluster before writing manifests):

```yaml
# Illustrative. Confirm the served apiVersion in YOUR cluster first:
#   kubectl api-resources --api-group=gateway.networking.k8s.io | grep -i backendtls
kind: BackendTLSPolicy
metadata:
  name: shared-api-tls
  namespace: shared-services
spec:
  # Policy attachment: this policy targets a Service, and applies to
  # every gateway connection to that Service.
  targetRefs:
  - group: ""
    kind: Service
    name: shared-api
  validation:
    # Either a ConfigMap holding a CA bundle ...
    caCertificateRefs:
    - group: ""
      kind: ConfigMap
      name: backend-ca
    # ... or the system trust store instead of caCertificateRefs
    # wellKnownCACertificates: System
    #
    # The hostname the gateway sends as SNI and verifies against the
    # backend certificate. Required.
    hostname: shared-api.shared-services.svc.cluster.local
```

Key ideas, independent of exact field names:

1. It uses the **policy attachment** pattern: a separate object targets an existing resource rather than embedding more fields into it.
2. It attaches to the **Service**, not to the route, because the trust requirement is a property of the backend.
3. It is owned by the **backend team**, which is the team that knows which CA signed their certificate.
4. It is deliberately narrower than a service mesh. If you need mutual TLS with automatic certificate rotation for all east west traffic, that is a mesh's job.

---

## Other Route Types

| Kind | API group version | Channel | Attaches to listener protocol | Purpose |
|------|-------------------|---------|-------------------------------|---------|
| `HTTPRoute` | `gateway.networking.k8s.io/v1` | Standard | `HTTP`, `HTTPS` | HTTP routing, the workhorse |
| `GRPCRoute` | `gateway.networking.k8s.io/v1` | Standard | `HTTP`, `HTTPS` | gRPC service and method matching |
| `TLSRoute` | `gateway.networking.k8s.io/v1alpha2` | Experimental | `TLS` (Passthrough) | Route by SNI without decrypting |
| `TCPRoute` | `gateway.networking.k8s.io/v1alpha2` | Experimental | `TCP` | Raw TCP, one listener port per service |
| `UDPRoute` | `gateway.networking.k8s.io/v1alpha2` | Experimental | `UDP` | Raw UDP, for example DNS or game servers |

### GRPCRoute

gRPC over an HTTPRoute means matching on a path like `/pkg.Service/Method`, which is fragile. `GRPCRoute` makes it first class.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: orders-grpc
  namespace: team-a
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra
    sectionName: https
  hostnames:
  - grpc.example.com
  rules:
  - matches:
    - method:
        type: Exact               # Exact | RegularExpression
        service: shop.v1.Orders
        method: CreateOrder
      headers:
      - type: Exact
        name: x-tenant
        value: acme
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: x-gateway
          value: prod
    backendRefs:
    - name: orders-grpc-v1
      port: 9090
      weight: 90
    - name: orders-grpc-v2
      port: 9090
      weight: 10
```

Canary weights, header matching and filters all work exactly as they do for HTTP, which is the whole point of a consistent API.

### TCPRoute and UDPRoute

```yaml
# Requires the Experimental channel CRDs
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute
metadata:
  name: postgres-tcp
  namespace: data
spec:
  parentRefs:
  - name: db-gateway
    namespace: infra
    sectionName: postgres        # a TCP listener on the Gateway
  rules:
  - backendRefs:
    - name: postgres
      port: 5432
```

There are no `hostnames` and no `matches`: raw TCP carries no routing metadata, so the listener port is the entire selector. That is why each TCP service needs its own listener port on the Gateway.

### TLSRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: mtls-app
  namespace: secure
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra
    sectionName: passthrough     # the mode: Passthrough listener
  hostnames:
  - mtls.example.com             # matched against the SNI name only
  rules:
  - backendRefs:
    - name: mtls-app
      port: 8443
```

`TLSRoute` gets hostnames because SNI is visible in the cleartext ClientHello, but nothing else is, so there are still no path or header matches.

---

## Route Attachment and Status Conditions

### The Attachment Checklist

```
┌────────────────────────────────────────────────────────────────────┐
│  A route attaches to a listener ONLY IF ALL of these hold:          │
│                                                                     │
│  ① parentRefs names an EXISTING Gateway                             │
│     (and sectionName, if set, names an existing listener)           │
│                                                                     │
│  ② The listener's allowedRoutes.namespaces permits the route's      │
│     namespace (All, Same, or a matching Selector)                   │
│                                                                     │
│  ③ The listener's allowedRoutes.kinds permits this route KIND       │
│                                                                     │
│  ④ The route's hostnames INTERSECT the listener's hostname          │
│     (empty on either side means "no constraint")                    │
│                                                                     │
│  ⑤ The route kind is compatible with the listener protocol          │
│     (HTTPRoute on an HTTP/HTTPS listener, TLSRoute on TLS, ...)     │
│                                                                     │
│  Fail any one, and the parent status carries                        │
│  Accepted: False with a reason such as NotAllowedByListeners,       │
│  NoMatchingListenerHostname or NoMatchingParent.                    │
└────────────────────────────────────────────────────────────────────┘
```

### Hostname Intersection

| Listener hostname | Route hostnames | Effective hostnames |
|-------------------|-----------------|---------------------|
| `*.example.com` | `foo.example.com` | `foo.example.com` |
| `*.example.com` | `foo.example.com`, `bar.other.com` | `foo.example.com` only |
| `*.example.com` | `other.com` | none, `Accepted: False` |
| `*.example.com` | (empty) | `*.example.com` |
| (empty) | `foo.example.com` | `foo.example.com` |
| (empty) | (empty) | everything |
| `foo.example.com` | `*.example.com` | `foo.example.com` |

### Condition Reference

**GatewayClass**

| Condition | True means |
|-----------|-----------|
| `Accepted` | A controller recognised `controllerName` and will serve this class |
| `SupportedVersion` | The installed CRD bundle version is compatible with the controller |

**Gateway (top level)**

| Condition | True means |
|-----------|-----------|
| `Accepted` | The Gateway spec is valid and the controller has taken ownership |
| `Programmed` | The data plane is actually configured and ready to serve traffic |

**Gateway listener (per listener)**

| Condition | True means |
|-----------|-----------|
| `Accepted` | This listener's configuration is valid |
| `Programmed` | This listener is live on the data plane |
| `ResolvedRefs` | All `certificateRefs` resolved, exist and are permitted |
| `Conflicted` | ⚠️ True is BAD: this listener conflicts with another (same port, incompatible protocol or overlapping hostname) |

**Route (one entry per parentRef)**

| Condition | True means |
|-----------|-----------|
| `Accepted` | The route attached to this parent successfully |
| `ResolvedRefs` | All `backendRefs` exist, have the required port, and are permitted |
| `PartiallyInvalid` | ⚠️ True is BAD: some rules were dropped but the rest are serving |

`Accepted` and `Programmed` are genuinely different. `Accepted: True, Programmed: False` means the API is happy but the load balancer has not appeared yet, which on bare metal usually means MetalLB has not assigned an address.

### Reading Status

```bash
# Gateway, including per listener detail
kubectl -n infra get gateway prod-gateway -o yaml | sed -n '/^status:/,$p'

kubectl -n infra get gateway prod-gateway -o jsonpath=\
'{range .status.listeners[*]}{.name}{"\t attached="}{.attachedRoutes}{"\t"}{range .conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}'

# Route status, one block per parent
kubectl -n team-a get httproute shop-route -o jsonpath=\
'{range .status.parents[*]}{.parentRef.name}{"\t"}{range .conditions[*]}{.type}={.status}{"("}{.reason}{") "}{end}{"\n"}{end}'

# Human readable
kubectl -n team-a describe httproute shop-route

# Everything at once
kubectl get gatewayclass,gateway,httproute -A
```

---

## Conformance and Release Channels

### Support Levels

Every field in the API is tagged with a support level, which is how "portable" is made concrete.

| Level | Meaning | Portable |
|-------|---------|:--------:|
| **Core** | Every conformant implementation MUST support it | ✅ Always |
| **Extended** | Portable, but implementations MAY omit it; if implemented, behaviour is specified | ⚠️ Check first |
| **Implementation specific** | Behaviour is entirely up to the vendor | ❌ No |

Examples: `PathPrefix` matching and `RequestRedirect` are Core. `URLRewrite`, `RequestMirror` and `ResponseHeaderModifier` are Extended. `RegularExpression` matching is implementation specific.

### Release Channels

```
┌────────────────────────────────────────────────────────────────────┐
│  STANDARD CHANNEL         standard-install.yaml                     │
│    GA and beta resources and fields only. Backward compatible.      │
│    Use this in production.                                          │
│    Contains: GatewayClass, Gateway, HTTPRoute, GRPCRoute (v1),      │
│              ReferenceGrant (v1beta1)                               │
│                                                                     │
│  EXPERIMENTAL CHANNEL     experimental-install.yaml                 │
│    Everything in Standard PLUS alpha resources and alpha fields.    │
│    May change or be removed between releases.                       │
│    Adds: TCPRoute, UDPRoute, TLSRoute and experimental fields.      │
│                                                                     │
│  ⚠️ Install ONE channel. The CRDs have the same names, so applying │
│     both leaves you with whichever was applied last and a very      │
│     confusing debugging session.                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Conformance Profiles

Implementations run an upstream test suite and publish a conformance report. Profiles are organised by protocol and by whether the traffic is north south (ingress) or east west (mesh), for example HTTP, GRPC and TLS profiles for Gateway, and HTTP and GRPC profiles for mesh.

```bash
# Some implementations publish their conformance report in the
# GatewayClass status or in their documentation.
kubectl get gatewayclass <name> -o yaml

# Before relying on an Extended feature, confirm it is implemented
kubectl explain httproute.spec.rules.filters.requestMirror
```

> 💡 Practical rule: build on Core features, treat Extended features as a deliberate decision that you document, and treat implementation specific features as vendor lock in.

---

## Implementation Comparison

| Implementation | `controllerName` | Data plane | Best fit |
|----------------|------------------|------------|----------|
| **Istio** | `istio.io/gateway-controller` | Envoy | You already run Istio, or you want mesh plus gateway from one control plane with mTLS and rich policy |
| **Cilium** | `io.cilium/gateway-controller` | Envoy, driven by eBPF | You already run Cilium as your CNI; no extra proxy tier to operate |
| **Envoy Gateway** | `gateway.envoyproxy.io/gatewayclass-controller` | Envoy | You want Envoy without adopting a full mesh; tracks the spec closely |
| **NGINX Gateway Fabric** | `gateway.nginx.org/nginx-gateway-controller` | NGINX | You are coming from ingress-nginx and want familiar operational behaviour |
| **Traefik** | `traefik.io/gateway-controller` | Traefik | You already run Traefik; Gateway API alongside its own CRDs |

> ⚠️ Do not copy these strings blindly. Confirm against the implementation's own documentation and, once installed, against `kubectl get gatewayclass -o wide`. A single character wrong in `controllerName` produces a GatewayClass that no controller ever claims.

Selection guidance:

- **Already running Cilium** (see [cni.md](cni.md) and [ebpf.md](ebpf.md)): use Cilium's Gateway API support and avoid a second proxy tier entirely.
- **Already running Istio**: use Istio's, so routes and mesh policy share one control plane.
- **Migrating from ingress-nginx on bare metal**: NGINX Gateway Fabric keeps the operational model familiar; pair it with MetalLB exactly as you did the ingress controller.
- **Greenfield, no mesh, want the most complete spec coverage**: Envoy Gateway.

```bash
# What is installed and which classes are accepted?
kubectl get gatewayclass -o custom-columns=\
'NAME:.metadata.name,CONTROLLER:.spec.controllerName,ACCEPTED:.status.conditions[?(@.type=="Accepted")].status'
```

---

## Migrating from Ingress

### Concept Mapping

| Ingress | Gateway API | Notes |
|---------|-------------|-------|
| `IngressClass` | `GatewayClass` | Both cluster scoped, both name a controller |
| `spec.ingressClassName` | `Gateway.spec.gatewayClassName` | Moves up to the Gateway |
| `Ingress` (whole object) | `Gateway` + `HTTPRoute` | The core split |
| `spec.rules[].host` | `HTTPRoute.spec.hostnames[]` plus listener `hostname` | Enforced on both sides |
| `spec.rules[].http.paths[].path` | `rules[].matches[].path.value` | Same idea |
| `pathType: Exact` | `path.type: Exact` | Identical semantics |
| `pathType: Prefix` | `path.type: PathPrefix` | Identical element boundary semantics |
| `pathType: ImplementationSpecific` | `path.type: RegularExpression` | Both are non portable |
| `backend.service.name` / `.port` | `backendRefs[].name` / `.port` | Now a list, with weights |
| `spec.tls[].secretName` | `listeners[].tls.certificateRefs[]` | Owned by the cluster operator |
| `spec.defaultBackend` | A final rule matching `PathPrefix: /` | No dedicated field |
| Port 80 and 443 only | Any `listeners[].port` | A real capability gain |
| `nginx.../rewrite-target` | `URLRewrite` filter | Typed, no regex capture groups needed |
| `nginx.../ssl-redirect` | `RequestRedirect` filter on the HTTP listener | Explicit instead of implicit |
| `nginx.../permanent-redirect` | `RequestRedirect` filter with `statusCode: 301` | Typed |
| `nginx.../canary` + `canary-weight` | `backendRefs[].weight` | One object instead of two |
| `nginx.../canary-by-header` | `matches[].headers[]` | Core feature, not an annotation |
| `nginx.../configuration-snippet` | `ExtensionRef` filter or a vendor policy CRD | Structured extension instead of raw config |
| `nginx.../backend-protocol: HTTPS` | `BackendTLSPolicy` | Typed, with CA and hostname validation |
| tcp-services ConfigMap | `TCPRoute` | First class |
| (impossible) | `matches[].method`, `matches[].queryParams` | New capability |
| (impossible) | `RequestMirror` filter | New capability |
| (impossible, cross namespace forbidden) | `backendRefs[].namespace` + `ReferenceGrant` | New capability, with an explicit permission model |
| `status.loadBalancer.ingress[]` | `Gateway.status.addresses[]` plus rich conditions | Far better observability |

### Worked Translation

```yaml
# ===================== BEFORE: Ingress =====================
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: team-a
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts: [shop.example.com]
    secretName: shop-tls
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: api-svc
            port: { number: 8080 }
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port: { number: 80 }
```

```yaml
# ===================== AFTER: Gateway API ==================
# Owned by the cluster operator, in the infra namespace
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: prod-gateway
  namespace: infra
spec:
  gatewayClassName: external-lb
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: shop.example.com
    allowedRoutes:
      namespaces: { from: All }
  - name: https
    port: 443
    protocol: HTTPS
    hostname: shop.example.com
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: shop-tls              # now lives in the infra namespace
    allowedRoutes:
      namespaces: { from: All }
---
# Replaces the ssl-redirect annotation, explicitly
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop-https-redirect
  namespace: infra
spec:
  parentRefs:
  - name: prod-gateway
    sectionName: http
  hostnames: [shop.example.com]
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
---
# Owned by the app team, in their own namespace
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: team-a
spec:
  parentRefs:
  - name: prod-gateway
    namespace: infra
    sectionName: https
  hostnames: [shop.example.com]
  rules:
  # Replaces the rewrite-target regex, with no regex at all
  - matches:
    - path: { type: PathPrefix, value: /api }
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: api-svc
      port: 8080
  - matches:
    - path: { type: PathPrefix, value: / }
    backendRefs:
    - name: web-svc
      port: 80
```

Three annotations disappear, the regex disappears, the certificate moves to the team that should own it, and the app team's object no longer contains anything they should not be able to change.

### Migration Strategy

```
┌────────────────────────────────────────────────────────────────────┐
│  Phase 1  Install the Gateway API CRDs and an implementation.       │
│           Change nothing else. Ingress keeps serving all traffic.   │
│                                                                     │
│  Phase 2  Create a Gateway with a NEW hostname or a NEW IP,         │
│           parallel to the existing ingress controller.              │
│                                                                     │
│  Phase 3  Translate one low risk application to an HTTPRoute.       │
│           Test it against the new hostname. Nothing in production   │
│           has moved yet.                                            │
│                                                                     │
│  Phase 4  Cut over that application's real hostname by moving the   │
│           DNS record, or by shifting weight if both sit behind the  │
│           same VIP. Rollback is a DNS change.                       │
│                                                                     │
│  Phase 5  Repeat per application. Ingress and Gateway API coexist   │
│           happily; there is no cluster wide flag day.               │
│                                                                     │
│  Phase 6  When the last Ingress is gone, remove the old controller. │
│                                                                     │
│  Tooling: the ingate / ingress2gateway conversion tool from the     │
│  gateway-api project can translate existing Ingress objects into    │
│  draft Gateway API manifests. Treat its output as a starting        │
│  point, not as finished configuration; annotations that have no     │
│  Gateway API equivalent cannot be converted automatically.          │
└────────────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

### Diagnostic Order

```
┌────────────────────────────────────────────────────────────────────┐
│  1. Are the CRDs installed?    kubectl get crd | grep gateway       │
│  2. Is a GatewayClass Accepted?kubectl get gatewayclass             │
│  3. Is the Gateway Programmed? kubectl get gateway -A               │
│  4. Does it have an address?   .status.addresses                    │
│  5. Are listeners Accepted,                                         │
│     Programmed, ResolvedRefs?  .status.listeners[]                  │
│  6. attachedRoutes > 0?        .status.listeners[].attachedRoutes   │
│  7. Route Accepted per parent? kubectl describe httproute           │
│  8. Route ResolvedRefs?        same place                           │
│  9. Does the Service have      kubectl get endpointslice            │
│     endpoints?                                                      │
│ 10. Data plane logs            kubectl logs on the proxy pods       │
└────────────────────────────────────────────────────────────────────┘
```

### Symptom: Route Not Attached

`kubectl describe httproute` shows `Accepted: False` under `status.parents`.

| `reason` | Cause | Fix |
|----------|-------|-----|
| `NoMatchingParent` | `parentRefs` names a Gateway or `sectionName` that does not exist | Fix the name, the namespace or the listener name; they are all case sensitive |
| `NotAllowedByListeners` | The listener's `allowedRoutes` rejects this namespace or this route kind | Label the namespace to match the selector, or ask the Gateway owner to widen `allowedRoutes` |
| `NoMatchingListenerHostname` | The route hostnames do not intersect the listener hostname | Align them; remember a wildcard covers one label |
| `UnsupportedValue` | A field value the implementation does not support | Check the support level and the implementation's conformance report |

```bash
# Full status, all conditions
kubectl -n team-a get httproute shop-route -o yaml | sed -n '/^status:/,$p'

# The Gateway side of the story: does it see any routes at all?
kubectl -n infra get gateway prod-gateway -o jsonpath=\
'{range .status.listeners[*]}{.name}{" attachedRoutes="}{.attachedRoutes}{"\n"}{end}'

# Namespace labels, the usual culprit with from: Selector
kubectl get ns team-a --show-labels
kubectl -n infra get gateway prod-gateway \
  -o jsonpath='{.spec.listeners[*].allowedRoutes.namespaces}{"\n"}'
```

### Symptom: Listener Not Programmed

| Condition seen | Cause | Fix |
|----------------|-------|-----|
| `Programmed: False`, `Accepted: True` | Infrastructure not provisioned yet; on bare metal the LoadBalancer Service is `<pending>` | Install and configure MetalLB, see [metallb.md](metallb.md) |
| `ResolvedRefs: False`, reason `InvalidCertificateRef` | The Secret is missing, is not type `kubernetes.io/tls`, or is malformed | Create the Secret correctly in the right namespace |
| `ResolvedRefs: False`, reason `RefNotPermitted` | `certificateRefs` points at another namespace with no `ReferenceGrant` | Create the grant in the Secret's namespace |
| `Conflicted: True` | Two listeners collide: same port with incompatible protocols, or overlapping hostnames | Give each listener a distinct port or a non overlapping hostname |
| `Accepted: False`, reason `UnsupportedProtocol` | The implementation does not support this listener protocol | Check the implementation's conformance report |
| Gateway has no status at all | No controller claimed the GatewayClass | Verify `controllerName` and that the implementation is running |

```bash
kubectl -n infra describe gateway prod-gateway
kubectl -n infra get secret shop-tls -o jsonpath='{.type}{"\n"}'
kubectl -n infra get svc -l gateway.networking.k8s.io/gateway-name=prod-gateway
kubectl -n <controller-ns> logs deploy/<controller> --tail=100
```

### Symptom: Backend Not Resolved

`ResolvedRefs: False` on the route.

| `reason` | Cause | Fix |
|----------|-------|-----|
| `BackendNotFound` | Service name typo, or it lives in a different namespace than assumed | Correct the name, or set `backendRefs[].namespace` explicitly |
| `RefNotPermitted` | Cross namespace backend with no `ReferenceGrant` | Create the grant in the backend's namespace |
| `InvalidKind` | `backendRefs[].kind` is something the implementation cannot route to | Use `Service` unless the implementation documents otherwise |
| Port missing or wrong | `port` omitted, or does not exist on the Service | `port` is required for Service backends; match a real Service port |

```bash
kubectl -n team-a get svc api-svc -o yaml | grep -A6 '^  ports:'
kubectl -n team-a get endpointslice -l kubernetes.io/service-name=api-svc
kubectl -n shared-services get referencegrant -o yaml
```

### Symptom: 500 or 503 From the Gateway

| Response | Cause |
|----------|-------|
| `500` | The rule has no `backendRefs`, or every `backendRef` failed to resolve |
| `503` | Every `backendRef` has `weight: 0`, or the resolved Services have no ready endpoints |
| `404` | No rule matched; check hostname intersection and path matching precedence |

```bash
# Are there ready endpoints at all?
kubectl -n team-a get endpointslice -l kubernetes.io/service-name=shop-v1 \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'

# Talk to the Service directly, bypassing the gateway entirely
kubectl -n team-a run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sv http://shop-v1:8080/
```

### Symptom: Wrong Rule Matched

Almost always precedence, not a bug. Re-read [Matching Precedence](#matching-precedence): `Exact` beats the longest `PathPrefix`, more header matches beat fewer, and across routes the older `creationTimestamp` wins.

```bash
# Every route claiming this hostname, oldest first, is the winner order
kubectl get httproute -A -o json | jq -r '
  .items[]
  | select(.spec.hostnames[]? == "shop.example.com")
  | "\(.metadata.creationTimestamp) \(.metadata.namespace)/\(.metadata.name)"' | sort
```

### Symptom: Cross Namespace Reference Silently Ignored

Check that the `ReferenceGrant` is in the **target** namespace, not the source, that `from[].namespace` names the source namespace exactly, and that `to[].name`, if present, matches the Service name exactly.

```bash
kubectl get referencegrant -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,FROM:.spec.from[*].namespace,TOKIND:.spec.to[*].kind,TONAME:.spec.to[*].name'
```

### General Purpose Commands

```bash
kubectl get gatewayclass,gateway,httproute,referencegrant -A
kubectl describe gateway <name> -n <ns>
kubectl describe httproute <name> -n <ns>
kubectl explain httproute.spec.rules --recursive | head -60
kubectl get events -A --sort-by=.lastTimestamp | grep -i -E 'gateway|route'

# Test with an explicit Host and no DNS
LB=$(kubectl -n infra get gateway prod-gateway -o jsonpath='{.status.addresses[0].value}')
curl -sv --resolve shop.example.com:80:$LB  http://shop.example.com/
curl -kv --resolve shop.example.com:443:$LB https://shop.example.com/
```

---

## Exam and Interview Traps

1. **Gateway API is not built into Kubernetes.** The CRDs plus an implementation must both be installed. CRDs alone do nothing, exactly like an Ingress with no controller.
2. **The role split is the headline feature**, not the extra syntax: GatewayClass for the infrastructure provider, Gateway for the cluster operator, Routes for the application developer.
3. **`GatewayClass` is cluster scoped; `Gateway` and all Route kinds are namespaced.**
4. **`spec.controllerName` is required and immutable** on a GatewayClass.
5. **Attachment is bidirectional.** The route's `parentRefs` and the listener's `allowedRoutes` must both agree. Either side alone is not enough.
6. **`allowedRoutes.namespaces.from` defaults to `Same`**, so a route in another namespace will not attach unless the Gateway owner opted in.
7. **Cross namespace `backendRefs` require a `ReferenceGrant` in the TARGET namespace**, created by the team that owns the referenced resource. Same for cross namespace `certificateRefs` and mirror backends.
8. **`ReferenceGrant` is still `gateway.networking.k8s.io/v1beta1`** while GatewayClass, Gateway, HTTPRoute and GRPCRoute are `v1`.
9. **`from[].namespace` in a ReferenceGrant is required and supports no wildcards.** Omitting `to[].name` grants access to every object of that kind.
10. **Weights are relative, not percentages.** `9` and `1` behave identically to `90` and `10`.
11. **All weights zero returns 503; no backendRefs at all returns 500.**
12. **A rule with a `RequestRedirect` filter must not have `backendRefs`.**
13. **`ReplacePrefixMatch` only makes sense with a `PathPrefix` match**; with `Exact`, use `ReplaceFullPath`.
14. **`RequestHeaderModifier`, `ResponseHeaderModifier`, `RequestRedirect` and `URLRewrite` may each appear at most once per rule.**
15. **Within one `matches` entry the conditions are ANDed; between entries they are ORed.**
16. **Matching precedence is specified**: exact path, then longest prefix, then method, then most headers, then most query params, then oldest route by `creationTimestamp`, then alphabetical namespace/name.
17. **The `creationTimestamp` tie break prevents hostname hijacking** by a newer route in another namespace.
18. **`Accepted` and `Programmed` are different.** Accepted means the config is valid; Programmed means the data plane is actually serving.
19. **`Conflicted: True` on a listener is a failure**, not a success, and so is `PartiallyInvalid: True` on a route.
20. **`tls.mode: Passthrough` forbids `certificateRefs`** and requires a `TLSRoute`; an HTTPRoute cannot attach because nothing above TLS is readable.
21. **`TCPRoute` and `UDPRoute` have no hostnames and no matches.** The listener port is the only selector, so each TCP service needs its own port.
22. **`TCPRoute`, `UDPRoute` and `TLSRoute` are in the Experimental channel** at `v1alpha2`; `HTTPRoute` and `GRPCRoute` are `v1` in Standard.
23. **Install exactly one channel.** Standard and Experimental define the same CRD names.
24. **`RegularExpression` matching is implementation specific**, so it is not portable, just like `pathType: ImplementationSpecific` was.
25. **Gateway API does not replace a service mesh**, though meshes implement it for east west traffic.
26. **On bare metal a Gateway needs MetalLB or equivalent** for `status.addresses` to be populated and `Programmed` to become True.
27. **`RequestMirror` discards the mirrored response**, but it does not discard the side effects; mirrored writes really happen.
28. **Ingress is not deprecated.** Both APIs can serve traffic in the same cluster during a gradual migration.

---

## Related Topics

- **[ingress.md](ingress.md)**: the API Gateway API replaces, and why it stalled
- **[k8s-networking-fundamentals.md](k8s-networking-fundamentals.md)**: the Pod, Service and Node networks underneath
- **[metallb.md](metallb.md)**: giving a Gateway a real IP on bare metal
- **[install-metallb.md](install-metallb.md)**: MetalLB installation walkthrough
- **[network-policy.md](network-policy.md)**: network level enforcement to complement ReferenceGrant's API level authorisation
- **[cni.md](cni.md)** and **[ebpf.md](ebpf.md)**: relevant if you use Cilium's Gateway API implementation
- **[kube-proxy.md](kube-proxy.md)**: how traffic reaches the gateway's proxy pods
- **[deployment-strategies.md](deployment-strategies.md)**: canary and blue green, made straightforward by weighted backendRefs
- **[deployments.md](deployments.md)**: the workloads behind every backendRef
- **[k8s-api.md](k8s-api.md)**: CRDs, the watch mechanism and controller reconciliation

Working Ingress examples in this repository, useful as migration inputs: `k8s-workshop/ingress-nginx/`

---

## Key Takeaways

1. **Gateway API is the successor to Ingress**, designed to be role oriented, portable, expressive and extensible, and it is where all new edge routing features land.
2. **Three resources for three personas**: GatewayClass for the infrastructure provider, Gateway for the cluster operator, Routes for the application developer. RBAC can finally enforce that boundary.
3. **Nothing is built in.** Install the CRDs from one channel, then install an implementation, then confirm a GatewayClass reaches `Accepted: True`.
4. **`GatewayClass` is cluster scoped with an immutable `controllerName`; Gateways and Routes are namespaced.**
5. **Listeners define ports, protocols, hostnames, TLS mode and which namespaces may attach.** `Terminate` lets the gateway read HTTP; `Passthrough` restricts you to SNI based `TLSRoute`.
6. **Route attachment requires agreement from both sides**, the route's `parentRefs` and the listener's `allowedRoutes`, plus an intersecting hostname and a compatible kind.
7. **Matches are typed and rich**: path, headers, query parameters and method, ANDed within an entry and ORed between entries, with a fully specified precedence order.
8. **Filters replace annotations**: RequestHeaderModifier, ResponseHeaderModifier, RequestRedirect, URLRewrite and RequestMirror are spec fields, not vendor strings.
9. **Weighted `backendRefs` make canary a one line change.** Weights are relative, all zero returns 503, and rollback is a single patch.
10. **Header based routing gives deterministic A/B testing**, where weight based splitting is random per request.
11. **Cross namespace references are denied by default** and must be granted by the target namespace with a `ReferenceGrant`, which closes a genuine attack path.
12. **`BackendTLSPolicy` types the second TLS hop**, replacing the untyped backend protocol annotation with real CA and hostname validation.
13. **Status conditions are the debugging interface**: `Accepted`, `ResolvedRefs`, `Programmed`, and the negative signals `Conflicted` and `PartiallyInvalid`.
14. **Core, Extended and Implementation specific support levels, plus conformance profiles, are what make portability a testable claim** rather than a marketing one.
15. **Migration is incremental.** Ingress and Gateway API coexist; move one application at a time and keep DNS as your rollback lever.

---

## References

- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Gateway API: API Overview](https://gateway-api.sigs.k8s.io/concepts/api-overview/)
- [Gateway API: Security Model](https://gateway-api.sigs.k8s.io/concepts/security-model/)
- [Gateway API: HTTP Routing Guide](https://gateway-api.sigs.k8s.io/guides/http-routing/)
- [Gateway API: Traffic Splitting](https://gateway-api.sigs.k8s.io/guides/traffic-splitting/)
- [Gateway API: HTTP Redirects and Rewrites](https://gateway-api.sigs.k8s.io/guides/http-redirect-rewrite/)
- [Gateway API: TLS Configuration](https://gateway-api.sigs.k8s.io/guides/tls/)
- [Gateway API: Migrating from Ingress](https://gateway-api.sigs.k8s.io/guides/migrating-from-ingress/)
- [Gateway API: Implementations](https://gateway-api.sigs.k8s.io/implementations/)
- [Gateway API: Conformance](https://gateway-api.sigs.k8s.io/concepts/conformance/)
- [Gateway API: Versioning and Release Channels](https://gateway-api.sigs.k8s.io/concepts/versioning/)
- [Gateway API GitHub Releases](https://github.com/kubernetes-sigs/gateway-api/releases)
- [Kubernetes: Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/)
- [Kubernetes: Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Istio: Kubernetes Gateway API](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- [Cilium: Gateway API Support](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- [Envoy Gateway](https://gateway.envoyproxy.io/docs/)
- [NGINX Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/)
