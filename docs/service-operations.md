# 🛠️ Service Operations: The Hands On Handbook

Everything you actually type: creating Services imperatively and declaratively, reading every column and block of the output, verifying connectivity from inside and outside the cluster, and a systematic runbook for "my Service does not work".

## 📋 Table of Contents
- [Creating Services Imperatively](#creating-services-imperatively)
- [kubectl expose in Depth](#kubectl-expose-in-depth)
- [kubectl create service in Depth](#kubectl-create-service-in-depth)
- [Generating Manifests with Dry Run](#generating-manifests-with-dry-run)
- [Creating Services Declaratively](#creating-services-declaratively)
- [Inspecting Services](#inspecting-services)
- [Reading kubectl describe svc](#reading-kubectl-describe-svc)
- [Inspecting Endpoints and EndpointSlices](#inspecting-endpoints-and-endpointslices)
- [Verifying Connectivity from Inside the Cluster](#verifying-connectivity-from-inside-the-cluster)
- [DNS Verification](#dns-verification)
- [Testing NodePort from Outside](#testing-nodeport-from-outside)
- [Port Forwarding](#port-forwarding)
- [The Service Troubleshooting Runbook](#the-service-troubleshooting-runbook)
- [Common Scenarios and Root Causes](#common-scenarios-and-root-causes)
- [Editing and Deleting Services](#editing-and-deleting-services)
- [Quick Command Reference](#quick-command-reference)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Creating Services Imperatively

Two commands create Services from the command line, and they are not interchangeable.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  kubectl expose                                                          │
│    Takes an EXISTING workload (deployment, pod, replicaset, service)     │
│    and DERIVES the selector from that object's labels.                   │
│    ► Use when the workload already exists. Selector is correct by        │
│      construction, which removes the most common Service bug.            │
│                                                                          │
│  kubectl create service <type>                                           │
│    Builds a Service from scratch with an app=<name> selector.            │
│    ► Use for headless Services, ExternalName, explicit node ports, or    │
│      when the workload does not exist yet.                               │
└──────────────────────────────────────────────────────────────────────────┘
```

```bash
# Fastest correct path: create the workload, then expose it
kubectl create deployment web --image=nginx:1.27 --replicas=3
kubectl expose deployment web --port=80 --target-port=80

kubectl get svc web
# NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
# web    ClusterIP   10.96.171.44   <none>        80/TCP    3s
```

---

## kubectl expose in Depth

`kubectl expose` reads the source object, copies its labels into `spec.selector`, and builds the Service around that.

```bash
kubectl expose deployment web \
  --name=web-svc \          # Service name; defaults to the source object name
  --port=80 \               # REQUIRED: the port on the Service VIP
  --target-port=8080 \      # port on the Pod; defaults to --port when omitted
  --protocol=TCP \          # TCP (default), UDP, SCTP
  --type=ClusterIP          # ClusterIP (default), NodePort, LoadBalancer, ExternalName
```

### The Flags That Matter

| Flag | Effect |
|------|--------|
| `--port` | Service port. Required unless the source object declares container ports. |
| `--target-port` | Pod port, numeric or a `containerPort` **name**. Defaults to `--port`. |
| `--type` | Service type. |
| `--name` | Service name, defaults to the source object name. |
| `--selector` | **Overrides** the derived selector. Use with care. |
| `--labels` / `-l` | Labels applied **to the Service object**, not the selector. |
| `--cluster-ip` | Pin the ClusterIP, or set `None` for a headless Service. |
| `--session-affinity` | `None` or `ClientIP`. |
| `--external-ip` | Populates `spec.externalIPs`. |
| `--dry-run=client -o yaml` | Print the manifest instead of creating it. |

```bash
# All four types from one Deployment
kubectl expose deployment web --port=80 --target-port=8080
kubectl expose deployment web --port=80 --target-port=8080 --type=NodePort --name=web-np
kubectl expose deployment web --port=80 --target-port=8080 --type=LoadBalancer --name=web-lb

# Headless, via --cluster-ip=None
kubectl expose deployment web --port=80 --target-port=8080 \
  --cluster-ip=None --name=web-headless

# Named target port, which must exist as a containerPort name in the Pod
kubectl expose deployment web --port=80 --target-port=http --name=web-named

# Client IP session affinity
kubectl expose deployment web --port=80 --session-affinity=ClientIP --name=web-sticky
```

### What Selector Gets Derived

```bash
kubectl create deployment web --image=nginx:1.27
kubectl get deployment web -o jsonpath='{.spec.selector.matchLabels}{"\n"}'
# {"app":"web"}

kubectl expose deployment web --port=80
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'
# {"app":"web"}
```

> ⚠️ `kubectl expose pod <name>` derives the selector from **that Pod's labels**. If the Pod carries a `pod-template-hash` label, the Service is pinned to one ReplicaSet generation and will lose its endpoints on the next rollout. Expose the Deployment or the Service, never a Deployment managed Pod.

### Exposing an Existing Service

```bash
# Re-expose an existing ClusterIP Service as a NodePort, reusing its selector
kubectl expose service web --type=NodePort --name=web-nodeport --port=80
```

---

## kubectl create service in Depth

`kubectl create service` needs no existing workload. It always writes the selector `app: <service-name>`, so the Pods must carry that label or you must edit the Service afterwards.

```bash
# ClusterIP; --tcp uses port:targetPort syntax and may repeat
kubectl create service clusterip web --tcp=80:8080

# Multiple ports, which forces generated names (tcp-80-8080 style)
kubectl create service clusterip web --tcp=80:8080 --tcp=443:8443

# Headless
kubectl create service clusterip web-headless --clusterip="None"

# NodePort, letting the API server allocate the node port
kubectl create service nodeport web --tcp=80:8080

# NodePort with an explicit node port (single port Services only)
kubectl create service nodeport web --tcp=80:8080 --node-port=30080

# LoadBalancer
kubectl create service loadbalancer web --tcp=80:8080

# ExternalName: no selector, no ports needed
kubectl create service externalname legacy-db --external-name=db.corp.example.com
```

### Generated Output

```bash
kubectl create service clusterip web --tcp=80:8080 --dry-run=client -o yaml
```

```yaml
apiVersion: v1
kind: Service
metadata:
  creationTimestamp: null
  labels:
    app: web              # label ON the Service
  name: web
spec:
  ports:
  - name: 80-8080         # auto generated name, derived from the port pair
    port: 80
    protocol: TCP
    targetPort: 8080
  selector:
    app: web              # ALWAYS app: <name>, regardless of your workload
  type: ClusterIP
status:
  loadBalancer: {}
```

> ⚠️ The selector is `app: <service-name>` and nothing else. If your Deployment uses `app.kubernetes.io/name: web`, this Service selects nothing. This is the single most common failure with `kubectl create service`.

### Comparison

| | `kubectl expose` | `kubectl create service` |
|---|---|---|
| Requires an existing workload | Yes | No |
| Selector source | The source object's labels | Always `app: <name>` |
| Headless | `--cluster-ip=None` | `--clusterip="None"` |
| ExternalName | Awkward | `externalname` subcommand |
| Explicit node port | Not supported | `--node-port` |
| Named target port | `--target-port=http` | Not supported by `--tcp` |
| Risk of a wrong selector | Low | High |

---

## Generating Manifests with Dry Run

Never hand write a Service from memory in an exam or an incident. Generate, then edit.

```bash
# Print instead of create
kubectl expose deployment web --port=80 --target-port=8080 \
  --dry-run=client -o yaml

# Write it to a file to edit and commit
kubectl expose deployment web --port=80 --target-port=8080 \
  --dry-run=client -o yaml > web-svc.yaml

# JSON if you prefer
kubectl create service nodeport web --tcp=80:8080 --dry-run=client -o json
```

| Mode | Behaviour |
|------|-----------|
| `--dry-run=client` | Renders locally. Nothing is sent to the API server. No validation against admission or quota. |
| `--dry-run=server` | Sends the object with the dry run flag. **Runs full validation, defaulting, admission and webhooks**, then discards it. |
| `--dry-run=none` | The default: actually create. |

```bash
# Server dry run catches things client dry run cannot, such as a node port clash
kubectl create service nodeport web --tcp=80:8080 --node-port=30080 \
  --dry-run=server -o yaml
# Error from server (Invalid): Service "web" is invalid:
#   spec.ports[0].nodePort: Invalid value: 30080: provided port is already allocated
```

A clean starting manifest, cleaned of the generated noise:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: prod
  labels:
    app: web
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
```

---

## Creating Services Declaratively

```bash
kubectl apply -f web-svc.yaml
kubectl apply -f ./manifests/            # a whole directory
kubectl apply -k ./overlays/prod/        # kustomize

kubectl diff -f web-svc.yaml             # what WOULD change, before applying
```

Keeping the workload and its Service in one file makes the label relationship reviewable:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web              # (1) Pod label
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - name: http
          containerPort: 8080  # (2) the port the process listens on
        readinessProbe:
          httpGet:
            path: /healthz
            port: http
          initialDelaySeconds: 3
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: prod
spec:
  selector:
    app: web                  # (1) must equal the Pod label
  ports:
  - name: http
    port: 80
    targetPort: http          # (2) resolves to containerPort 8080
```

The two numbered links are the whole contract. Almost every broken Service is a break in one of them.

---

## Inspecting Services

### kubectl get svc

```bash
kubectl get svc
kubectl get svc -A                    # every namespace
kubectl get svc -o wide               # adds the SELECTOR column
kubectl get svc web -o yaml
kubectl get svc --show-labels
kubectl get svc -l app=web
```

```
NAME         TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)                      AGE
kubernetes   ClusterIP      10.96.0.1       <none>          443/TCP                      87d
web          ClusterIP      10.96.171.44    <none>          80/TCP                       2d
web-np       NodePort       10.96.5.201     <none>          80:30080/TCP                 2d
web-lb       LoadBalancer   10.96.240.13    10.28.31.101    80:31456/TCP                 2d
web-pend     LoadBalancer   10.96.240.90    <pending>       80:32001/TCP                 9m
web-hl       ClusterIP      None            <none>          9042/TCP                     2d
legacy-db    ExternalName   <none>          db.corp.local   <none>                       2d
web-ext      ClusterIP      10.96.12.7      203.0.113.10    80/TCP                       2d
```

| Column | Meaning |
|--------|---------|
| `TYPE` | `spec.type`. `ExternalName` is the odd one out with no VIP. |
| `CLUSTER-IP` | The allocated VIP. `None` means headless. `<none>` means ExternalName. |
| `EXTERNAL-IP` | Shows `status.loadBalancer.ingress`, **or** `spec.externalIPs`, **or** `spec.externalName`. All three land in this one column. |
| `EXTERNAL-IP: <pending>` | A LoadBalancer Service that no controller has satisfied. **There is no timeout.** |
| `PORT(S)` | `port/protocol` for ClusterIP, `port:nodePort/protocol` when a node port exists. |
| `AGE` | Time since creation, not since the last endpoint change. |

```
Reading PORT(S):

  80/TCP          ► port 80 on the ClusterIP only
  80:30080/TCP    ► port 80 on the VIP, port 30080 on every node
  80:31456/TCP    ► same, allocated automatically for a LoadBalancer
  <none>          ► ExternalName; ports are not used

  targetPort NEVER appears in this column. Use describe or -o yaml.
```

### Targeted jsonpath Queries

```bash
kubectl get svc web -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl get svc web -o jsonpath='{.spec.ports[0].targetPort}{"\n"}'
kubectl get svc web -o jsonpath='{.spec.ports[*].nodePort}{"\n"}'
kubectl get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
kubectl get svc web -o jsonpath='{.spec.healthCheckNodePort}{"\n"}'

# Every Service and its selector, cluster wide
kubectl get svc -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,SELECTOR:.spec.selector

# Every LoadBalancer Service still waiting for an address
kubectl get svc -A -o json | jq -r '
  .items[] | select(.spec.type=="LoadBalancer")
  | select((.status.loadBalancer.ingress // []) | length == 0)
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

---

## Reading kubectl describe svc

```bash
kubectl describe svc web -n prod
```

```
Name:                     web
Namespace:                prod
Labels:                   app=web
Annotations:              metallb.io/address-pool: production
Selector:                 app=web
Type:                     LoadBalancer
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.96.240.13
IPs:                      10.96.240.13
LoadBalancer Ingress:     10.28.31.101
Port:                     http  80/TCP
TargetPort:               8080/TCP
NodePort:                 http  31456/TCP
Endpoints:                10.8.1.55:8080,10.8.2.44:8080,10.8.3.9:8080
Session Affinity:         None
External Traffic Policy:  Local
HealthCheck NodePort:     32100
Internal Traffic Policy:  Cluster
Events:                   <none>
```

Block by block:

| Block | What to check |
|-------|---------------|
| `Selector` | Copy it. Everything downstream depends on it matching real Pod labels. |
| `Type` | Confirms whether node ports and an external address should exist at all. |
| `IP Family Policy`, `IP Families` | Single or dual stack, and which family is primary. |
| `IP` / `IPs` | The ClusterIP. `None` here means headless. |
| `LoadBalancer Ingress` | Present only once a controller wrote `status`. Absent means still pending. |
| `Port` | The name and the port on the VIP. |
| `TargetPort` | **The critical field.** If a named port failed to resolve you see the name, not a number. |
| `NodePort` | Present for NodePort and LoadBalancer. |
| `Endpoints` | **The critical field.** Empty means the Service routes nowhere. |
| `Session Affinity` | `None` or `ClientIP`. |
| `External Traffic Policy` | `Local` explains node specific behaviour. |
| `HealthCheck NodePort` | Only for LoadBalancer plus `Local`. |
| `Events` | LB provisioning failures and node port allocation errors land here. |

The two lines that decide almost everything:

```
Endpoints:   <none>                  ► nothing to route to. Go to Step 2 of the runbook.
TargetPort:  8080/TCP                ► must equal the port the process really listens on.
```

For an ExternalName Service the output is much shorter and there is no VIP at all:

```
Name:              legacy-db
Type:              ExternalName
External Name:     db.corp.example.com
Endpoints:         <none>
```

---

## Inspecting Endpoints and EndpointSlices

```bash
# EndpointSlices for one Service: the modern, authoritative view
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web
```

```
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                            AGE
web-7x4kd   IPv4          8080    10.8.1.55,10.8.2.44,10.8.3.9         2d
```

```bash
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web -o yaml
```

```yaml
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: web-7x4kd
  namespace: prod
  labels:
    kubernetes.io/service-name: web
addressType: IPv4
ports:
- name: http
  port: 8080
  protocol: TCP
endpoints:
- addresses:
  - 10.8.1.55
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: node-01
  targetRef:
    kind: Pod
    name: web-6d4c7f8b9-x2k9p
    namespace: prod
```

```bash
# The legacy Endpoints object, still populated for compatibility
kubectl get endpoints web -n prod
# NAME   ENDPOINTS                                        AGE
# web    10.8.1.55:8080,10.8.2.44:8080,10.8.3.9:8080      2d

kubectl get endpoints web -n prod -o yaml
```

Fast triage forms:

```bash
# Just the addresses
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
# 10.8.1.55 ready=true
# 10.8.2.44 ready=true
# 10.8.3.9 ready=false

# Which node each endpoint lives on, essential for externalTrafficPolicy: Local
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.nodeName}{"\n"}{end}'

# Every Service in the namespace with zero endpoints
kubectl get endpoints -n prod -o json | jq -r '
  .items[] | select((.subsets // []) | length == 0) | .metadata.name'
```

> 📖 Slice packing, conditions, mirroring and hints are covered in [endpointslices.md](endpointslices.md).

---

## Verifying Connectivity from Inside the Cluster

The ClusterIP is only reachable from inside, so you need a Pod. Use a throwaway one.

```bash
# Full toolbox: curl, dig, nslookup, tcpdump, ss, nc, traceroute
kubectl run netshoot --rm -it --restart=Never --image=nicolaka/netshoot -- bash

# Minimal and always available: wget, nslookup, nc
kubectl run tmp --rm -it --restart=Never --image=busybox:1.36 -- sh

# curl only
kubectl run curl --rm -it --restart=Never --image=curlimages/curl -- sh

# One shot, no interactive shell
kubectl run probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -m 5 -o /dev/null -w 'code=%{http_code} time=%{time_total}\n' http://web.prod:80
```

> ⚠️ `--rm` only deletes the Pod when the command exits cleanly. After a `Ctrl-C` or a crash you may need `kubectl delete pod netshoot --force` manually.

Inside the debug Pod:

```bash
# 1. By DNS name, short form (same namespace only)
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://web

# 2. By DNS name, namespace qualified
curl -sS -m 5 http://web.prod

# 3. By FQDN, which removes the search path from the equation
curl -sS -m 5 http://web.prod.svc.cluster.local

# 4. By ClusterIP, which removes DNS from the equation entirely
curl -sS -m 5 http://10.96.171.44:80

# 5. Directly to a Pod IP and targetPort, which removes the Service entirely
curl -sS -m 5 http://10.8.1.55:8080
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  THE BISECTION LADDER: work downwards until something succeeds           │
│                                                                          │
│   DNS name works        ► everything is fine                             │
│   ClusterIP works, name fails      ► a DNS problem                       │
│   Pod IP works, ClusterIP fails    ► Service, endpoints or kube-proxy    │
│   Pod IP fails too                 ► the application, the port or a      │
│                                      NetworkPolicy                       │
└──────────────────────────────────────────────────────────────────────────┘
```

Useful variants:

```bash
# busybox has no curl
wget -qO- --timeout=5 http://web.prod.svc.cluster.local

# Raw TCP reachability, no HTTP involved
nc -zv -w 3 web.prod.svc.cluster.local 80
nc -zv -w 3 10.96.171.44 80

# What is the container actually listening on
kubectl exec -it deploy/web -- sh -c 'ss -tlnp 2>/dev/null || netstat -tlnp'
# LISTEN 0 511 0.0.0.0:8080  ► good
# LISTEN 0 511 127.0.0.1:8080  ► BROKEN: reachable only inside the container

# Attach a toolbox to a running Pod's network namespace, no image rebuild
kubectl debug -it web-6d4c7f8b9-x2k9p --image=nicolaka/netshoot --target=nginx
```

Repeated requests to confirm load balancing actually spreads:

```bash
for i in $(seq 1 20); do
  curl -sS http://web.prod/hostname
done | sort | uniq -c
#  7 web-6d4c7f8b9-x2k9p
#  6 web-6d4c7f8b9-q7m3z
#  7 web-6d4c7f8b9-l9v2t
```

---

## DNS Verification

```bash
kubectl run netshoot --rm -it --restart=Never --image=nicolaka/netshoot -- bash
```

```bash
# Basic forward lookup
nslookup web.prod.svc.cluster.local
# Server:   10.96.0.10
# Address:  10.96.0.10#53
# Name:     web.prod.svc.cluster.local
# Address:  10.96.171.44

# Headless Service: expect ONE A RECORD PER READY POD
nslookup cassandra.data.svc.cluster.local
# Address: 10.8.1.10
# Address: 10.8.2.31
# Address: 10.8.3.7

# Per Pod record behind a headless Service
nslookup cassandra-0.cassandra.data.svc.cluster.local

# SRV record for a named port
nslookup -type=SRV _http._tcp.web.prod.svc.cluster.local
dig +short SRV _http._tcp.web.prod.svc.cluster.local

# Ask CoreDNS directly, bypassing resolv.conf and the search path
dig @10.96.0.10 web.prod.svc.cluster.local +short

# Watch the search path expansion in action
dig +search +trace web

# ExternalName returns a CNAME, not an A record
dig legacy-db.prod.svc.cluster.local CNAME +short
```

```bash
# The Pod's resolver configuration: nameserver, search list, ndots
cat /etc/resolv.conf
# nameserver 10.96.0.10
# search prod.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
```

If DNS is broken for everything, check CoreDNS itself before touching the Service:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
```

> 📖 Corefile structure, plugin order, caching and DNS scaling are in [coredns.md](coredns.md).

---

## Testing NodePort from Outside

```bash
# 1. Confirm a node port exists and note it
kubectl get svc web-np
# NAME     TYPE       CLUSTER-IP    EXTERNAL-IP   PORT(S)        AGE
# web-np   NodePort   10.96.5.201   <none>        80:30080/TCP   4m

NODEPORT=$(kubectl get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')

# 2. Collect node addresses
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'

# 3. Test EVERY node, not just one
for NODE in 10.28.28.11 10.28.28.12 10.28.28.13; do
  printf '%s -> ' "$NODE"
  curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://${NODE}:${NODEPORT}" || echo FAILED
done
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Interpreting the results                                                │
│                                                                          │
│  All nodes answer 200                ► working correctly                 │
│  Only nodes running a Pod answer     ► externalTrafficPolicy: Local      │
│  No node answers, ClusterIP works    ► host firewall or security group   │
│  Connection refused immediately      ► nothing is listening: wrong port, │
│                                        or the Service is not NodePort    │
│  Connection times out                ► a firewall is DROPPING, not       │
│                                        rejecting; check the path         │
└──────────────────────────────────────────────────────────────────────────┘
```

Verify the node is actually listening and that the firewall permits it:

```bash
# On the node itself
sudo ss -tlnp | grep 30080
sudo iptables -t nat -L KUBE-NODEPORTS -n | grep 30080

# firewalld
sudo firewall-cmd --list-ports
sudo firewall-cmd --permanent --add-port=30080/tcp && sudo firewall-cmd --reload

# ufw
sudo ufw status
sudo ufw allow 30080/tcp
```

Test a `LoadBalancer` Service the same way, against the external address:

```bash
LB=$(kubectl get svc web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://${LB}"

# And the health check port when externalTrafficPolicy is Local
HC=$(kubectl get svc web-lb -o jsonpath='{.spec.healthCheckNodePort}')
for NODE in 10.28.28.11 10.28.28.12; do
  printf '%s hc -> ' "$NODE"
  curl -sS -m 3 -o /dev/null -w '%{http_code}\n' "http://${NODE}:${HC}"
done
# 10.28.28.11 hc -> 503   (no local endpoint: LB should stop sending here)
# 10.28.28.12 hc -> 200   (has a local endpoint)
```

---

## Port Forwarding

`kubectl port-forward` tunnels through the API server, which makes it invaluable for reaching a ClusterIP Service from your laptop without exposing anything.

```bash
# Local 8080 to Service port 80
kubectl port-forward svc/web 8080:80 -n prod

# Same local and remote port
kubectl port-forward svc/web 80:80 -n prod

# Let the OS pick the local port
kubectl port-forward svc/web :80 -n prod

# Bind on all interfaces instead of localhost only
kubectl port-forward --address 0.0.0.0 svc/web 8080:80

# Forward to a Pod or a Deployment instead
kubectl port-forward pod/web-6d4c7f8b9-x2k9p 8080:8080
kubectl port-forward deploy/web 8080:8080
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  What port-forward actually does                                         │
│                                                                          │
│   laptop:8080 ──► kubectl ──► kube-apiserver ──► kubelet ──► ONE Pod     │
│                                                                          │
│  ⚠️  It resolves the Service to a SINGLE Pod and forwards to that Pod.   │
│      There is NO load balancing, and kube-proxy is NOT in the path.      │
│      A working port-forward therefore does NOT prove the Service works.  │
│      It only proves the Pod and the port work.                           │
└──────────────────────────────────────────────────────────────────────────┘
```

Also note that `kubectl port-forward svc/web 8080:80` resolves `80` through the Service to the Pod's `targetPort`, so a named `targetPort` must exist in the Pod. Forwarding is TCP only; UDP is not supported.

---

## The Service Troubleshooting Runbook

Work the steps in order. Each one narrows the problem, and skipping ahead is how people waste an hour on DNS when the selector was wrong.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  START: "I cannot reach my Service"                                      │
│    1. Does the Service exist, in the right namespace?                    │
│    2. Do the selector and the Pod labels match?                          │
│    3. Are there READY endpoints?                                         │
│    4. Are the readiness probes passing?                                  │
│    5. Is targetPort correct and is the process bound to 0.0.0.0?         │
│    6. Does DNS resolve the name?                                         │
│    7. Is kube-proxy healthy on the client's node?                        │
│    8. Is a NetworkPolicy blocking it?                                    │
│    9. External only: is externalTrafficPolicy Local dropping traffic?    │
└──────────────────────────────────────────────────────────────────────────┘
```

### Step 1: Does the Service Exist

```bash
kubectl get svc web -n prod
```

```
# Expected
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.171.44   <none>        80/TCP    2d

# Failure
Error from server (NotFound): services "web" not found
```

If it is not found, you are in the wrong namespace or the name differs.

```bash
kubectl get svc -A | grep web
kubectl config view --minify -o jsonpath='{..namespace}{"\n"}'   # current namespace
```

Remember that a Service is only reachable by its short name from **its own namespace**. From elsewhere use `web.prod` or the FQDN.

### Step 2: Does the Selector Match the Pod Labels

This is the most common failure. Do not eyeball it, run it.

```bash
# 2a. Read the exact selector
kubectl get svc web -n prod -o jsonpath='{.spec.selector}{"\n"}'
# {"app":"web","tier":"frontend"}

# 2b. Query Pods with EXACTLY that selector
kubectl get pods -n prod --selector=app=web,tier=frontend
```

```
# Expected
NAME                   READY   STATUS    RESTARTS   AGE
web-6d4c7f8b9-x2k9p    1/1     Running   0          2d
web-6d4c7f8b9-q7m3z    1/1     Running   0          2d

# Failure
No resources found in prod namespace.
```

If the second command returns nothing, the selector is wrong. Compare against reality:

```bash
kubectl get pods -n prod --show-labels
# NAME                  READY  STATUS   AGE  LABELS
# web-6d4c7f8b9-x2k9p   1/1    Running  2d   app=web,pod-template-hash=6d4c7f8b9,tier=web

# Selector wanted tier=frontend, Pods carry tier=web. That is the bug.
```

Typical causes: a typo, a `kubectl create service` default selector of `app: <name>` that does not match, labels on the Deployment rather than on the Pod template, or a Service exposed from a Pod so that it selects on `pod-template-hash`.

```bash
# Where the Pod template labels really live
kubectl get deploy web -n prod -o jsonpath='{.spec.template.metadata.labels}{"\n"}'
```

### Step 3: Are There Ready Endpoints

```bash
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web
```

```
# Expected
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                       AGE
web-7x4kd   IPv4          8080    10.8.1.55,10.8.2.44,10.8.3.9    2d

# Failure A: no slice at all      ► selector matches nothing, go back to Step 2
No resources found in prod namespace.

# Failure B: a slice with no addresses  ► Pods matched but none is Ready, go to Step 4
NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
web-7x4kd   IPv4          8080    <unset>     2d
```

```bash
# Same answer from describe
kubectl describe svc web -n prod | grep -A1 '^Endpoints'
# Endpoints:  <none>          ► nothing to route to

# Ready state per endpoint
kubectl get endpointslices -n prod -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{" node="}{.nodeName}{"\n"}{end}'
```

### Step 4: Are Readiness Probes Passing

Only **ready** Pods become ready endpoints.

```bash
kubectl get pods -n prod -l app=web
# NAME                  READY   STATUS    RESTARTS   AGE
# web-6d4c7f8b9-x2k9p   0/1     Running   0          4m      ► Running but NOT Ready
```

```bash
kubectl describe pod web-6d4c7f8b9-x2k9p -n prod | sed -n '/Conditions/,/Events/p'
# Conditions:
#   Type              Status
#   Initialized       True
#   Ready             False      ◄── here
#   ContainersReady   False
#   PodScheduled      True

kubectl describe pod web-6d4c7f8b9-x2k9p -n prod | grep -A5 Events
# Warning  Unhealthy  2m (x18 over 5m)  kubelet
#   Readiness probe failed: HTTP probe failed with statuscode: 404
```

```bash
# Test the probe path yourself, from inside the container
kubectl exec -it web-6d4c7f8b9-x2k9p -n prod -- \
  curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/healthz

kubectl get pod web-6d4c7f8b9-x2k9p -n prod -o jsonpath='{.spec.containers[0].readinessProbe}{"\n"}'
```

Frequent causes: the probe path does not exist, the probe port is wrong, `initialDelaySeconds` is too short for a slow starting application, or the probe requires a dependency that is itself down.

### Step 5: Is targetPort Correct

```bash
kubectl get svc web -n prod -o jsonpath='{.spec.ports[*].targetPort}{"\n"}'
# 8080

kubectl get pods -n prod -l app=web \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].ports[*].containerPort}{"\n"}{end}'
# web-6d4c7f8b9-x2k9p   8080
```

Then confirm what the process is **really** bound to, which is what actually matters:

```bash
kubectl exec -it deploy/web -n prod -- sh -c 'ss -tlnp 2>/dev/null || netstat -tlnp'
# LISTEN 0 511 0.0.0.0:8080     ► correct
# LISTEN 0 511 127.0.0.1:8080   ► BROKEN: loopback only, unreachable from outside
#                                 the container. Fix the app's bind address.
```

Prove it end to end by bypassing the Service:

```bash
POD_IP=$(kubectl get pod -n prod -l app=web -o jsonpath='{.items[0].status.podIP}')
kubectl run probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://${POD_IP}:8080"
# 200 ► the Pod is fine, the problem is the Service or the network
# 000 ► the Pod itself is the problem
```

If `targetPort` is a **name**, verify it exists in the Pod:

```bash
kubectl get pods -n prod -l app=web -o jsonpath='{.items[0].spec.containers[*].ports[*].name}{"\n"}'
# http metrics
```

### Step 6: Does DNS Resolve

```bash
kubectl run netshoot --rm -it --restart=Never --image=nicolaka/netshoot -- \
  nslookup web.prod.svc.cluster.local
```

```
# Expected
Name:    web.prod.svc.cluster.local
Address: 10.96.171.44

# Failure
** server can't find web.prod.svc.cluster.local: NXDOMAIN
```

Bisect DNS out of the picture:

```bash
CIP=$(kubectl get svc web -n prod -o jsonpath='{.spec.clusterIP}')
kubectl run probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://${CIP}:80"
# Works by IP but not by name ► the problem is DNS, not the Service
```

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50 | grep -i error
```

### Step 7: Is kube-proxy Healthy

```bash
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
# Confirm one Running Pod PER NODE, especially on the CLIENT's node.

kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=50 | grep -iE 'error|fail'
```

On the client's node, confirm the rules were actually programmed:

```bash
# iptables mode
sudo iptables -t nat -L KUBE-SERVICES -n | grep 10.96.171.44
sudo iptables -t nat -L KUBE-NODEPORTS -n | grep 30080

# IPVS mode
sudo ipvsadm -Ln | grep -A5 10.96.171.44
```

No rules for a Service that has endpoints means kube-proxy is stuck, crash looping, or not running on that node.

> 📖 Proxy modes and rule structure are covered in [kube-proxy.md](kube-proxy.md).

### Step 8: Is a NetworkPolicy Blocking It

```bash
kubectl get networkpolicy -n prod
kubectl describe networkpolicy -n prod
```

The classic signature: connections **time out** rather than being refused, direct Pod IP access fails too, and adding a permissive policy immediately fixes it.

```bash
# Does any policy select the destination Pods
kubectl get networkpolicy -n prod -o json | jq -r '
  .items[] | "\(.metadata.name): \(.spec.podSelector)"'
```

Remember that a policy is namespace scoped, that once **any** ingress policy selects a Pod everything not explicitly allowed is denied, and that egress policies on the **client** side can block the connection just as effectively, including blocking DNS to CoreDNS on port 53.

> 📖 Rule semantics, selector types and default deny patterns are in [network-policy.md](network-policy.md).

### Step 9: Is externalTrafficPolicy Local Dropping Traffic

Only relevant for traffic entering through a node port, an external IP or a load balancer.

```bash
kubectl get svc web-lb -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
# Local
```

```bash
# Which nodes actually have an endpoint
kubectl get endpointslices -l kubernetes.io/service-name=web-lb \
  -o jsonpath='{range .items[*].endpoints[*]}{.nodeName}{"\n"}{end}' | sort -u
# node-02
# node-03

# Test every node's node port and compare
NP=$(kubectl get svc web-lb -o jsonpath='{.spec.ports[0].nodePort}')
for N in 10.28.28.11 10.28.28.12 10.28.28.13; do
  printf '%s -> ' "$N"
  curl -sS -m 3 -o /dev/null -w '%{http_code}\n' "http://${N}:${NP}" || echo DROPPED
done
# 10.28.28.11 -> DROPPED   ◄── no local endpoint, this is expected with Local
# 10.28.28.12 -> 200
# 10.28.28.13 -> 200
```

Fixes, in order of preference: make the external load balancer honour `healthCheckNodePort`; spread Pods with `topologySpreadConstraints` or anti-affinity; run the front end as a DaemonSet; or switch to `externalTrafficPolicy: Cluster` and accept losing the client IP.

---

## Common Scenarios and Root Causes

### Scenario 1: Endpoints Empty Right After a Rename

**Symptom.** The Service worked, someone changed a label, and `Endpoints: <none>` appeared with no other change.

**Root cause.** The Deployment's Pod template labels changed but the Service selector did not, or the reverse.

```bash
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl get deploy web -o jsonpath='{.spec.template.metadata.labels}{"\n"}'
```

**Fix.** Align them. Note that a Deployment's `spec.selector` is immutable, so a label change often means recreating the Deployment.

### Scenario 2: Works by Pod IP, Fails by ClusterIP

**Symptom.** `curl http://10.8.1.55:8080` succeeds, `curl http://10.96.171.44:80` hangs.

**Root cause.** Usually `targetPort` mismatch, sometimes kube-proxy not running on the client's node.

```bash
kubectl describe svc web | grep -E 'Port:|TargetPort:|Endpoints:'
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide | grep <client-node>
```

### Scenario 3: Intermittent 502 or Connection Reset During Deploys

**Symptom.** A small burst of failures every rollout.

**Root cause.** Terminating Pods remain in the endpoint set briefly while kube-proxy rules converge, and the application closes listeners immediately on SIGTERM.

**Fix.** Add a `preStop` sleep so the container keeps serving while endpoints propagate, make the readiness probe fail first, and set a `terminationGracePeriodSeconds` longer than the drain.

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 10"]
```

### Scenario 4: Only One Pod Ever Receives Traffic

**Symptom.** Load lands entirely on one replica.

**Root causes.** A headless Service where the client caches the first A record; a single long lived HTTP/2 or gRPC connection pinned through the VIP; `sessionAffinity: ClientIP` with a small number of distinct client IPs; or `externalTrafficPolicy: Local` where only one node has a Pod.

```bash
kubectl get svc web -o jsonpath='{.spec.clusterIP}{" "}{.spec.sessionAffinity}{" "}{.spec.externalTrafficPolicy}{"\n"}'
```

### Scenario 5: Cross Namespace Call Fails

**Symptom.** `curl http://web` works in `prod` and fails in `dev`.

**Root cause.** Short names only resolve within the Service's own namespace.

```bash
curl http://web.prod.svc.cluster.local     # correct from any namespace
```

### Scenario 6: EXTERNAL-IP Pending Forever

**Symptom.** A LoadBalancer Service never gets an address.

**Root causes.** No LB implementation installed; MetalLB installed with no `IPAddressPool` or advertisement; the pool is exhausted; `loadBalancerClass` names a controller that does not exist.

```bash
kubectl describe svc web-lb | sed -n '/Events/,$p'
kubectl -n metallb-system logs deploy/controller --tail=50
kubectl -n metallb-system get ipaddresspools,l2advertisements,bgpadvertisements
```

> 📖 See [metallb.md](metallb.md).

### Scenario 7: NodePort Unreachable from Outside, Fine Inside

**Symptom.** `curl 10.96.5.201:80` works from a Pod, `curl <node>:30080` times out from a laptop.

**Root cause.** A host firewall or cloud security group. A timeout means DROP; a refusal means nothing is listening.

```bash
sudo ss -tlnp | grep 30080
sudo firewall-cmd --list-ports
```

### Scenario 8: Application Sees Node IPs Instead of Client IPs

**Symptom.** Every access log line shows a node address.

**Root cause.** `externalTrafficPolicy: Cluster` SNATs at the entry node.

**Fix.** Switch to `Local`, or terminate at Layer 7 and read `X-Forwarded-For`.

### Scenario 9: Service Reaches Old Pods After a Rollout

**Symptom.** Traffic goes to Pods that no longer exist.

**Root causes.** A client caching DNS beyond the record TTL for a headless Service, or stale conntrack entries for a UDP Service where the endpoint changed.

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web -o yaml   # what is CURRENT
sudo conntrack -L -d 10.96.171.44                                      # what the kernel remembers
```

### Scenario 10: Two Services Fighting over One Node Port

**Symptom.** `provided port is already allocated`.

```bash
kubectl get svc -A -o json | jq -r '
  .items[] | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer")
  | .metadata.namespace as $ns | .metadata.name as $n
  | .spec.ports[]? | select(.nodePort != null)
  | "\(.nodePort)\t\($ns)/\($n)"' | sort -n
```

---

## Editing and Deleting Services

```bash
kubectl edit svc web -n prod                    # interactive
kubectl apply -f web-svc.yaml                   # declarative, preferred

# Targeted changes
kubectl patch svc web -p '{"spec":{"type":"NodePort"}}'
kubectl patch svc web -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl patch svc web -p '{"spec":{"selector":{"app":"web","tier":"web"}}}'
kubectl patch svc web --type=json \
  -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":9090}]'

kubectl delete svc web -n prod
kubectl delete svc -l app=web -n prod
```

| Change | Allowed in place |
|--------|------------------|
| `spec.selector` | Yes, endpoints recompute within seconds |
| `spec.ports` | Yes |
| `spec.type` | Yes, in both directions |
| `spec.externalTrafficPolicy` | Yes |
| `spec.sessionAffinity` | Yes, existing affinity state is cleared when set to `None` |
| `spec.clusterIP` | **No**, immutable |
| `clusterIP: None` to a real VIP | **No**, delete and recreate |
| Primary entry of `spec.ipFamilies` | **No** |
| `spec.healthCheckNodePort` once set | **No** |

Deleting a Service releases its ClusterIP and node ports and removes the kernel rules on every node. Existing connections through those rules break immediately.

---

## Quick Command Reference

```bash
# === CREATE ===
kubectl expose deployment web --port=80 --target-port=8080
kubectl expose deployment web --port=80 --type=NodePort --name=web-np
kubectl expose deployment web --port=80 --cluster-ip=None --name=web-hl
kubectl create service clusterip web --tcp=80:8080
kubectl create service nodeport web --tcp=80:8080 --node-port=30080
kubectl create service loadbalancer web --tcp=80:8080
kubectl create service externalname db --external-name=db.corp.example.com
kubectl expose deployment web --port=80 --dry-run=client -o yaml > svc.yaml

# === INSPECT ===
kubectl get svc -A -o wide
kubectl describe svc web
kubectl get svc web -o yaml
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl get endpoints web
kubectl get svc web -o jsonpath='{.spec.selector}{"\n"}'
kubectl get svc web -o jsonpath='{.spec.ports[*].targetPort}{"\n"}'

# === VERIFY SELECTOR ===
kubectl get pods --selector=app=web
kubectl get pods -l app=web --show-labels
kubectl get deploy web -o jsonpath='{.spec.template.metadata.labels}{"\n"}'

# === TEST FROM INSIDE ===
kubectl run netshoot --rm -it --restart=Never --image=nicolaka/netshoot -- bash
kubectl run tmp --rm -it --restart=Never --image=busybox:1.36 -- sh
kubectl run probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -m 5 http://web.prod.svc.cluster.local
kubectl exec -it deploy/web -- sh -c 'ss -tlnp || netstat -tlnp'
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>

# === DNS ===
nslookup web.prod.svc.cluster.local
dig @10.96.0.10 web.prod.svc.cluster.local +short
dig +short SRV _http._tcp.web.prod.svc.cluster.local
cat /etc/resolv.conf

# === TEST FROM OUTSIDE ===
curl http://<node-ip>:<nodePort>
curl http://<loadbalancer-ip>
kubectl port-forward svc/web 8080:80

# === DATAPATH ===
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
sudo iptables -t nat -L KUBE-SERVICES -n | grep <clusterIP>
sudo ipvsadm -Ln | grep -A5 <clusterIP>
sudo conntrack -L -d <clusterIP>
```

---

## Exam and Interview Traps

1. **`kubectl create service` always writes `app: <service-name>` as the selector**, no matter what your Pods are labelled. `kubectl expose` derives the correct one.
2. **`kubectl expose pod <name>` can capture `pod-template-hash`**, pinning the Service to one ReplicaSet and losing endpoints at the next rollout.
3. **`--dry-run=client` performs no server validation.** Node port clashes and admission failures only surface with `--dry-run=server` or a real create.
4. **`--labels` sets labels on the Service object, not the selector.** Use `--selector` to change matching.
5. **`kubectl get svc` never shows `targetPort`.** Use `describe` or `-o yaml`; assuming it from `PORT(S)` is a classic error.
6. **`EXTERNAL-IP` is one column showing three different things**: the LB address, `spec.externalIPs`, or `spec.externalName`.
7. **`CLUSTER-IP: None` means headless; `<none>` means ExternalName.** They are different states.
8. **`Endpoints: <none>` almost always means a selector mismatch**, not a networking failure. Verify with `kubectl get pods --selector=`.
9. **Running is not Ready.** Only Ready Pods become ready endpoints, so a failing readiness probe empties a Service silently.
10. **`kubectl port-forward` bypasses kube-proxy and the Service load balancing.** A working port-forward does not prove the Service works.
11. **`kubectl port-forward` is TCP only** and forwards to a single Pod.
12. **`kubectl run --rm` only cleans up on a clean exit.** Interrupted debug Pods linger.
13. **Short names resolve only in the Service's own namespace.** Cross namespace calls need `svc.ns` or the FQDN.
14. **A connection timeout suggests a DROP** (firewall or NetworkPolicy); **connection refused suggests nothing is listening**.
15. **A process bound to `127.0.0.1` passes an exec test and fails every Service test.** Always check the bind address, not just the port.
16. **`busybox` has no `curl` and no `dig`.** Use `wget -qO-` and `nslookup`, or a fuller image.
17. **`spec.clusterIP` is immutable**, so retyping a Service between ClusterIP and headless requires delete and recreate.
18. **Changing a Deployment's Pod labels may require recreating the Deployment**, because `spec.selector` there is immutable.
19. **NodePort testing must cover every node.** Passing on one node hides `externalTrafficPolicy: Local` behaviour.
20. **`healthCheckNodePort` returning 503 on some nodes is correct behaviour** with `Local`, not a fault.
21. **NetworkPolicy on the client's egress can break a Service call**, including by blocking DNS on port 53.
22. **Deleting a Service releases its ClusterIP and node ports immediately** and breaks established connections.

---

## Related Topics

- [Services](services.md)
- [EndpointSlices](endpointslices.md)
- [kube-proxy](kube-proxy.md)
- [CoreDNS](coredns.md)
- [MetalLB](metallb.md)
- [Network Policy](network-policy.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
- [kubectl](kubectl.md)
- [Imperative Kubernetes](imperative-kubernetes.md)
- [Pods](pods.md)
- [Deployments](deployments.md)
- [StatefulSets](statefulsets.md)
- [Kubernetes API](k8s-api.md)

---

## Key Takeaways

1. **`kubectl expose` derives the selector from a real object; `kubectl create service` hardcodes `app: <name>`.** Choosing wrongly is the fastest way to a Service with no endpoints.
2. Always generate manifests with `--dry-run=client -o yaml` and edit, rather than writing Services from memory. Use `--dry-run=server` when you need real validation.
3. `kubectl get svc` shows type, VIP, external address and the `port:nodePort` pair, but **never `targetPort`**. `describe` is where the two decisive lines live: `TargetPort` and `Endpoints`.
4. `EXTERNAL-IP` conflates load balancer addresses, `externalIPs` and `externalName`, and `<pending>` means no controller has claimed the Service, with no timeout.
5. **EndpointSlices are the authoritative membership view**, and `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` should be an early reflex.
6. Debug from inside with a throwaway Pod and **bisect deliberately**: name, then ClusterIP, then Pod IP. Each step eliminates a layer.
7. `ss -tlnp` inside the container catches the `127.0.0.1` bind that every other test misses.
8. Test NodePorts on **every** node. Passing on one node hides `externalTrafficPolicy: Local` and firewall differences.
9. **`kubectl port-forward` proves the Pod works, not the Service**, because it bypasses kube-proxy entirely and targets a single Pod.
10. The runbook order matters: existence, selector match, ready endpoints, readiness probes, targetPort, DNS, kube-proxy, NetworkPolicy, traffic policy. Most incidents end at step 2 or 3.
11. Verify a selector with `kubectl get pods --selector=<exact selector>` rather than by reading YAML. The command cannot lie to you.
12. **Running is not Ready.** A failing readiness probe silently empties a Service, and `describe pod` shows exactly why.
13. Timeouts point at DROP rules (firewall, NetworkPolicy); refusals point at nothing listening.
14. Rollout blips are usually endpoint propagation racing container shutdown; a `preStop` sleep and a longer grace period fix them.
15. `spec.clusterIP`, the headless state and the primary IP family are **immutable**: those changes mean delete and recreate.

---

## References

- [Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
- [Connecting Applications with Services](https://kubernetes.io/docs/tutorials/services/connect-applications-service/)
- [Service concept](https://kubernetes.io/docs/concepts/services-networking/service/)
- [kubectl expose reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_expose/)
- [kubectl create service reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_service/)
- [kubectl port-forward reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/)
- [Use Port Forwarding to Access Applications in a Cluster](https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/)
- [kubectl debug and ephemeral containers](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
- [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [Service Traffic Policies](https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/)
- [Using Source IP](https://kubernetes.io/docs/tutorials/services/source-ip/)
- [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [kubectl Quick Reference](https://kubernetes.io/docs/reference/kubectl/quick-reference/)
- [JSONPath Support](https://kubernetes.io/docs/reference/kubectl/jsonpath/)
