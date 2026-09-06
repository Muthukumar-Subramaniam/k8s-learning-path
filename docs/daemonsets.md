# 🛡️ DaemonSets: One Pod Per Node

A deep dive into the DaemonSet controller: how it guarantees exactly one Pod per matching node, how those Pods are actually scheduled, why they survive cordons and drains, and how to operate them safely in production.

## 📋 Table of Contents
- [What Is a DaemonSet?](#what-is-a-daemonset)
- [The One Pod Per Node Model](#the-one-pod-per-node-model)
- [How the DaemonSet Controller Schedules Pods](#how-the-daemonset-controller-schedules-pods)
- [Default Tolerations Injected by the Controller](#default-tolerations-injected-by-the-controller)
- [Why DaemonSet Pods Run on Cordoned Nodes](#why-daemonset-pods-run-on-cordoned-nodes)
- [Real World Uses](#real-world-uses)
- [Creating DaemonSets](#creating-daemonsets)
- [Anatomy of a DaemonSet Manifest](#anatomy-of-a-daemonset-manifest)
- [Node Selectors](#node-selectors)
- [Updating DaemonSets](#updating-daemonsets)
- [Rollbacks and ControllerRevisions](#rollbacks-and-controllerrevisions)
- [Host Networking and Host Paths](#host-networking-and-host-paths)
- [Priority, Preemption and system-node-critical](#priority-preemption-and-system-node-critical)
- [Static Pods as an Alternative](#static-pods-as-an-alternative)
- [DaemonSet Status Fields](#daemonset-status-fields)
- [Deleting DaemonSets](#deleting-daemonsets)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## What Is a DaemonSet?

A **DaemonSet** ensures that all (or some) nodes run a copy of a Pod. As nodes are added to the cluster, Pods are added to them. As nodes are removed from the cluster, those Pods are garbage collected. Deleting a DaemonSet cleans up the Pods it created.

The workload controller lives in the **kube-controller-manager** and is one of the core controllers alongside Deployment, ReplicaSet, StatefulSet and Job.

```
┌───────────────────────────────────────────────────────────────────┐
│                     DaemonSet Mental Model                        │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   Deployment:  "I want N replicas, put them wherever they fit"    │
│   DaemonSet:   "I want exactly 1 replica on every matching node"  │
│   StatefulSet: "I want N replicas with stable identity and disk"  │
│   Job:         "I want N successful completions, then stop"       │
│                                                                   │
│   The DaemonSet replica count is NOT a number you set.            │
│   It is DERIVED from the set of nodes that match your selector.   │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

There is no `spec.replicas` on a DaemonSet. Attempting to scale a DaemonSet with `kubectl scale` fails, because the desired count is a function of the node inventory.

```bash
# This fails: DaemonSets have no scale subresource semantics for replicas
kubectl scale daemonset node-exporter --replicas=3
# Error: the server could not find the requested resource
```

---

## The One Pod Per Node Model

The DaemonSet controller runs a reconciliation loop. On each sync it lists all nodes, filters them down to those where the DaemonSet Pod **should** run (based on `nodeSelector`, `affinity`, taints and tolerations), lists existing Pods owned by this DaemonSet grouped by node, and then computes three sets: **nodes needing a Pod**, **nodes with surplus Pods**, and **nodes with a Pod that should not have one**. It creates and deletes Pods to converge.

```
┌───────────────────────────────────────────────────────────────────┐
│                DaemonSet Reconciliation Loop                      │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│   ┌──────────────┐                                                │
│   │ Watch Nodes  │──────┐                                         │
│   └──────────────┘      │                                         │
│                         ▼                                         │
│   ┌──────────────┐   ┌─────────────────────────┐                  │
│   │ Watch Pods   │──►│  DaemonSet Controller   │                  │
│   └──────────────┘   │  (kube-controller-mgr)  │                  │
│                      └───────────┬─────────────┘                  │
│                                  │                                │
│              ┌───────────────────┼───────────────────┐            │
│              ▼                   ▼                   ▼            │
│      nodesNeedingPods    nodesWithSurplus    misscheduledPods     │
│              │                   │                   │            │
│              ▼                   ▼                   ▼            │
│         CREATE Pod          DELETE Pod          DELETE Pod        │
│                                                                   │
│   Convergence target: exactly ONE ready Pod per matching node     │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

If two Pods somehow exist on the same node for the same DaemonSet (for example after a partial failure or a manual Pod creation), the controller deletes the surplus, keeping the oldest running Pod.

---

## How the DaemonSet Controller Schedules Pods

This is the single most misunderstood part of DaemonSets, and a favourite interview question.

### The History

In very early Kubernetes releases, the DaemonSet controller performed its **own** scheduling, creating Pods with `spec.nodeName` already set and bypassing the scheduler entirely. That meant resource requests were never checked, priority and preemption did not work, and scheduler features such as inter-pod affinity were unavailable.

### The Current Behaviour

Modern Kubernetes has the DaemonSet controller create Pods that are **scheduled by the default scheduler**, exactly like any other Pod. The controller pins the Pod to its intended node not with `nodeName`, but by injecting a **required node affinity term that matches on the node's `metadata.name` field**.

```yaml
# What the DaemonSet controller adds to every Pod it creates.
# You never write this yourself; it is injected at creation time.
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchFields:
          - key: metadata.name
            operator: In
            values:
            - node-02          # the exact node this Pod is destined for
```

Note the use of `matchFields` rather than `matchExpressions`. `matchExpressions` matches node **labels**; `matchFields` matches node **object fields**, and `metadata.name` is the supported field here. This makes the affinity term resolve to exactly one node.

```
┌───────────────────────────────────────────────────────────────────┐
│              DaemonSet Pod Creation and Scheduling                 │
├───────────────────────────────────────────────────────────────────┤
│  1. Controller decides node-02 needs a Pod                        │
│  2. Controller builds the Pod and INJECTS:                        │
│       • nodeAffinity matchFields metadata.name In [node-02]       │
│       • default tolerations (not-ready, unreachable, pressures,   │
│         unschedulable, and network-unavailable for hostNetwork)   │
│       • ownerReference pointing at the DaemonSet                  │
│  3. Pod POSTed to kube-apiserver with EMPTY spec.nodeName         │
│  4. kube-scheduler filters: only node-02 survives the affinity,   │
│     then checks resources, taints, ports, volume limits           │
│  5. Scheduler writes a Binding ──► spec.nodeName = node-02        │
│  6. kubelet on node-02 sees the Pod and starts containers         │
└───────────────────────────────────────────────────────────────────┘
```

### Consequences You Must Internalise

| Consequence | Why it matters |
|-------------|----------------|
| Resource requests **are** enforced | A DaemonSet Pod requesting 4Gi on a node with 1Gi free stays `Pending` |
| Priority and preemption **work** | A `system-node-critical` DaemonSet Pod can evict lower priority Pods |
| Scheduler events appear normally | `kubectl describe pod` shows `FailedScheduling` with a real reason |
| `hostPort` conflicts are detected | Two Pods wanting the same host port on one node cannot both bind |
| Scheduler downtime blocks new Pods | If kube-scheduler is down, new DaemonSet Pods sit unscheduled |

That last row is why **kube-apiserver, etcd, kube-scheduler and kube-controller-manager are normally static Pods, not DaemonSets**: you cannot rely on the scheduler to bootstrap the scheduler. See [Static Pods as an Alternative](#static-pods-as-an-alternative).

---
## Default Tolerations Injected by the Controller

The DaemonSet controller adds a fixed set of tolerations to every Pod it creates. These are what make node agents behave like node agents: they keep running while the node is unhealthy, under pressure, or administratively closed for business.

| Taint key | Effect tolerated | Purpose |
|-----------|------------------|---------|
| `node.kubernetes.io/not-ready` | `NoExecute` | Keep running while the node reports NotReady |
| `node.kubernetes.io/unreachable` | `NoExecute` | Keep running while the node controller cannot reach the kubelet |
| `node.kubernetes.io/disk-pressure` | `NoSchedule` | Still schedule onto nodes low on disk |
| `node.kubernetes.io/memory-pressure` | `NoSchedule` | Still schedule onto nodes low on memory |
| `node.kubernetes.io/pid-pressure` | `NoSchedule` | Still schedule onto nodes low on PIDs |
| `node.kubernetes.io/unschedulable` | `NoSchedule` | Still schedule onto cordoned nodes |
| `node.kubernetes.io/network-unavailable` | `NoSchedule` | Added only when the Pod uses `hostNetwork: true` |

The `network-unavailable` toleration is conditional on purpose. A CNI agent must be able to start on a node whose pod network is not yet configured, and it can only do that if it is using the host network stack. A Pod that needs the pod network cannot usefully start on a node whose network is unavailable, so no toleration is added for it.

### Seeing the Injected Tolerations

```bash
kubectl describe pod -n kube-system <daemonset-pod> | sed -n '/Tolerations/,/Events/p'
kubectl get pod -n kube-system <daemonset-pod> -o jsonpath='{.spec.tolerations}' | jq
```

Typical output for a host networked agent:

```
Tolerations:  node.kubernetes.io/disk-pressure:NoSchedule op=Exists
              node.kubernetes.io/memory-pressure:NoSchedule op=Exists
              node.kubernetes.io/network-unavailable:NoSchedule op=Exists
              node.kubernetes.io/not-ready:NoExecute op=Exists
              node.kubernetes.io/pid-pressure:NoSchedule op=Exists
              node.kubernetes.io/unreachable:NoExecute op=Exists
              node.kubernetes.io/unschedulable:NoSchedule op=Exists
```

### What Is NOT Tolerated by Default

The controller does **not** add a toleration for arbitrary custom taints, and it does **not** add one for the control plane taint. If you want your DaemonSet on control plane nodes, you must say so explicitly:

```yaml
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      # Tolerate everything, including future unknown taints:
      - operator: Exists
```

A bare `- operator: Exists` with no key and no effect tolerates **every** taint. That is the sledgehammer used by CNI agents and kube-proxy. Use it deliberately, not casually.
---

## Why DaemonSet Pods Run on Cordoned Nodes

`kubectl cordon` does two things: it sets `.spec.unschedulable: true` on the Node object, and the node lifecycle controller adds the taint `node.kubernetes.io/unschedulable:NoSchedule`.

Because the DaemonSet controller injects a toleration for exactly that taint, **DaemonSet Pods continue to be scheduled onto cordoned nodes**.

```
┌───────────────────────────────────────────────────────────────────┐
│                    Cordon vs DaemonSet                            │
├───────────────────────────────────────────────────────────────────┤
│   kubectl cordon node-02                                          │
│         ├──► node.spec.unschedulable = true                       │
│         └──► taint node.kubernetes.io/unschedulable:NoSchedule    │
│                                                                   │
│   Regular Pod  ──► ✗ cannot be scheduled to node-02               │
│   DaemonSet Pod──► ✓ tolerates the taint, schedules anyway        │
│                                                                   │
│   Rationale: you still want logs, metrics, networking and CSI     │
│   on a node you are about to maintain.                            │
└───────────────────────────────────────────────────────────────────┘
```

### Drain Behaviour

`kubectl drain` evicts Pods from a node. It **refuses to proceed** when DaemonSet managed Pods are present, unless you pass `--ignore-daemonsets`:

```bash
# Fails with: cannot delete DaemonSet-managed Pods
kubectl drain node-02 --delete-emptydir-data

# Correct form for maintenance
kubectl drain node-02 --ignore-daemonsets --delete-emptydir-data --force
```

`--ignore-daemonsets` does not delete the DaemonSet Pods. It tells drain to **leave them alone and continue**. This is intentional: evicting them would be pointless because the controller would immediately recreate them (the node still matches, and the unschedulable taint is tolerated).

To genuinely remove a DaemonSet Pod from a node you must either delete the node, change the DaemonSet's node selector, or add a custom taint that the DaemonSet does not tolerate.

---

## Real World Uses

DaemonSets are the correct abstraction whenever a piece of software must exist **once per machine** rather than once per workload.

| Category | Examples | Why per node |
|----------|----------|--------------|
| **CNI agents** | Calico `calico-node`, Cilium `cilium-agent`, Flannel | Program routes, iptables or eBPF on every node |
| **Service proxy** | `kube-proxy` | Maintains Service routing rules in every node's dataplane |
| **Log collection** | Fluent Bit, Fluentd, Vector, Filebeat | Tail `/var/log/containers/*.log` on the local disk |
| **Node metrics** | `node-exporter`, cAdvisor sidecars | Read `/proc`, `/sys` and host cgroups locally |
| **CSI node plugins** | `csi-nfs-node`, `csi-smb-node`, Ceph node plugins | Perform mounts inside the node's mount namespace |
| **Security agents** | Falco, osquery, EDR agents | Observe kernel events and processes on the host |
| **Device plugins** | NVIDIA GPU plugin, SR-IOV plugin | Advertise node local hardware to the kubelet |

> 📖 **See Also**: [cni.md](cni.md) for how CNI agents run, [kube-proxy.md](kube-proxy.md) for the service proxy, and [install-csi-nfs.md](install-csi-nfs.md) for a CSI node plugin in practice.

### Inspecting the DaemonSets You Already Have

```bash
# Every cluster ships with at least kube-proxy and a CNI agent
kubectl get daemonsets -A
# NAMESPACE     NAME          DESIRED CURRENT READY UP-TO-DATE AVAILABLE NODE SELECTOR
# calico-system calico-node        4       4     4          4         4   kubernetes.io/os=linux
# kube-system   kube-proxy         4       4     4          4         4   kubernetes.io/os=linux
```

---

## Creating DaemonSets

### There Is No Imperative Generator

`kubectl create` has generators for `deployment`, `job`, `cronjob`, `service`, `configmap` and others, but **not for `daemonset`**. This is a classic exam trap.

```bash
# This does NOT exist
kubectl create daemonset my-agent --image=nginx
# error: unknown command "daemonset"
```

The standard workaround is to generate a Deployment manifest and convert it:

```bash
# 1. Generate a Deployment skeleton without contacting the API server
kubectl create deployment node-agent --image=busybox:1.36 \
  --dry-run=client -o yaml > ds.yaml

# 2. Edit ds.yaml: kind Deployment -> DaemonSet, then delete
#    spec.replicas, spec.strategy and status.

# 3. Validate before applying
kubectl apply -f ds.yaml --dry-run=server
```

### Applying and Watching

```bash
kubectl apply -f ds.yaml
kubectl rollout status daemonset/node-agent
kubectl get pods -l app=node-agent -o wide -w
```

### Verifying One Pod Per Node

```bash
kubectl get nodes --no-headers | wc -l
kubectl get pods -l app=node-agent --no-headers | wc -l

# Show the node each Pod landed on, sorted
kubectl get pods -l app=node-agent \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' \
  --sort-by=.spec.nodeName
```

---

## Anatomy of a DaemonSet Manifest

A complete, production shaped node agent. Every field is annotated.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
  labels:
    app.kubernetes.io/name: node-exporter
spec:
  # selector is REQUIRED and IMMUTABLE in apps/v1.
  # It must match spec.template.metadata.labels.
  selector:
    matchLabels:
      app.kubernetes.io/name: node-exporter

  # Pods must be Ready for this long before counting as Available.
  # Useful to slow a rollout and let a probe genuinely settle.
  minReadySeconds: 15

  # Number of ControllerRevisions retained for rollback. Default 10.
  revisionHistoryLimit: 10

  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0

  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-exporter
    spec:
      # Node agents almost always want the host network stack so the
      # metrics endpoint is reachable at the node IP and so they can
      # start before the pod network exists.
      hostNetwork: true
      hostPID: true
      dnsPolicy: ClusterFirstWithHostNet

      # Make sure this Pod outranks ordinary workloads and can preempt.
      priorityClassName: system-node-critical

      serviceAccountName: node-exporter

      # Only the controller-plane taint needs an explicit toleration here;
      # the pressure and unschedulable tolerations are injected for us.
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule

      # Keep this agent on Linux nodes only.
      nodeSelector:
        kubernetes.io/os: linux

      securityContext:
        runAsUser: 65534
        runAsGroup: 65534
        runAsNonRoot: true

      containers:
      - name: node-exporter
        image: quay.io/prometheus/node-exporter:v1.8.2
        args:
        - --path.procfs=/host/proc
        - --path.sysfs=/host/sys
        - --web.listen-address=:9100
        ports:
        - name: metrics
          containerPort: 9100
          hostPort: 9100
          protocol: TCP
        # Requests matter: the scheduler enforces them, so keep them small
        # and realistic or your agent will not fit on busy nodes.
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 180Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        livenessProbe:
          httpGet:
            path: /
            port: 9100
          initialDelaySeconds: 10
          periodSeconds: 20
        readinessProbe:
          httpGet:
            path: /
            port: 9100
          initialDelaySeconds: 5
          periodSeconds: 10
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true

      volumes:
      - name: proc
        hostPath:
          path: /proc
          type: Directory
      - name: sys
        hostPath:
          path: /sys
          type: Directory
```

### Field Rules Worth Memorising

| Field | Rule |
|-------|------|
| `spec.selector` | Required, immutable, must match the template labels |
| `spec.template.spec.restartPolicy` | Must be `Always` (or omitted, which defaults to `Always`) |
| `spec.template.spec.nodeName` | Must not be set; the controller pins via node affinity instead |
| `spec.replicas` | Does not exist on a DaemonSet |
| `spec.updateStrategy.type` | `RollingUpdate` (default) or `OnDelete` |
| `spec.minReadySeconds` | Optional, defaults to 0 |

---

## Node Selectors

A DaemonSet does not have to target every node. There are two mechanisms, and they are additive with the controller's injected affinity.

### 1. `nodeSelector`: Simple Equality

The simplest targeting: a map of label keys to values, all of which must match.

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/os: linux
        node-role.kubernetes.io/worker: ""
        hardware/gpu: "true"
```

Label the nodes first:

```bash
# Label a subset of nodes
kubectl label node node-03 hardware/gpu=true
kubectl label node node-04 hardware/gpu=true

# Verify
kubectl get nodes -L hardware/gpu

# Remove a label (note the trailing minus)
kubectl label node node-04 hardware/gpu-
```

The DaemonSet reacts immediately. Removing the label from `node-04` causes the controller to delete that node's Pod on the next sync, dropping `DESIRED` by one; adding it to a new node creates one.

### 2. `nodeAffinity`: Expressive Targeting

`nodeAffinity` supports set based operators and OR semantics, which `nodeSelector` cannot express.

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            # Terms are OR'd together.
            - matchExpressions:
              - key: node-role.kubernetes.io/worker
                operator: Exists
              - key: topology.kubernetes.io/zone
                operator: In
                values: ["eu-west-1a", "eu-west-1b"]
            - matchExpressions:
              - key: hardware/storage-class
                operator: In
                values: ["nvme"]
```

Supported operators for `matchExpressions`: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`.

| Mechanism | OR support | Negation | Numeric compare | Verbosity |
|-----------|-----------|----------|-----------------|-----------|
| `nodeSelector` | ❌ (AND only) | ❌ | ❌ | Low |
| `nodeAffinity` required | ✅ across terms | ✅ `NotIn`, `DoesNotExist` | ✅ `Gt`, `Lt` | High |
| `nodeAffinity` preferred | ✅ weighted | ✅ | ✅ | High |

### How Your Affinity Combines With the Injected One

The controller **adds** its `metadata.name` term rather than replacing yours. Within a single `nodeSelectorTerm`, `matchExpressions` and `matchFields` are AND'd. The controller inserts its `matchFields` requirement into each of your terms, so the final predicate is:

```
(your term 1  AND  metadata.name == target)
      OR
(your term 2  AND  metadata.name == target)
```

The net effect: your rules decide **which nodes get a Pod at all**, and the injected field selector decides **which single node each individual Pod is bound to**.

Note that `preferredDuringSchedulingIgnoredDuringExecution` is nearly useless here: it affects **scoring**, not filtering, and the injected `metadata.name` requirement already leaves exactly one feasible node. Use `required...` terms for DaemonSet targeting.

### Taints as an Exclusion Mechanism

`nodeSelector` and `nodeAffinity` are opt in from the workload side. Taints are opt out from the node side. To keep a broadly targeted DaemonSet off specific nodes, apply a taint that is not in the injected default set:

```bash
kubectl taint node node-05 workload=isolated:NoSchedule
kubectl taint node node-05 workload=isolated:NoSchedule-   # remove
```

---

## Updating DaemonSets

DaemonSets support two update strategies. The choice is a real operational decision, not a formality.

```yaml
spec:
  updateStrategy:
    type: RollingUpdate      # or OnDelete
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0
```

### RollingUpdate (default)

The controller deletes old Pods and lets its normal reconciliation create replacements with the new template, node by node, respecting the availability budget.

| Field | Default | Meaning |
|-------|---------|---------|
| `maxUnavailable` | `1` | How many nodes may be without an available Pod at once |
| `maxSurge` | `0` | How many nodes may temporarily run **two** Pods (old plus new) |

Both accept an absolute integer or a percentage string such as `"10%"`. Percentages are resolved against the number of nodes that should be running the Pod.

```
┌───────────────────────────────────────────────────────────────────┐
│      RollingUpdate with maxUnavailable=1, maxSurge=0              │
├───────────────────────────────────────────────────────────────────┤
│  t0   node-01[v1]  node-02[v1]  node-03[v1]  node-04[v1]          │
│  t1   node-01[ X ] node-02[v1]  node-03[v1]  node-04[v1]  delete  │
│  t2   node-01[v2*] node-02[v1]  node-03[v1]  node-04[v1]  starting│
│  t3   node-01[v2]  node-02[v1]  node-03[v1]  node-04[v1]  Ready   │
│  t4   node-01[v2]  node-02[ X ] node-03[v1]  node-04[v1]          │
│  ...                                                              │
│  t9   node-01[v2]  node-02[v2]  node-03[v2]  node-04[v2]  done    │
│                                                                   │
│  Between t1 and t3 node-01 has NO agent running. For a CNI or     │
│  CSI agent, that gap is a real outage window on that node.        │
│                                                                   │
│  With maxUnavailable=0, maxSurge=1 the order inverts: the new     │
│  Pod starts alongside the old one and the old one is removed      │
│  only once the new one is Ready. No gap, but TWO copies coexist.  │
└───────────────────────────────────────────────────────────────────┘
```

### Choosing maxSurge Versus maxUnavailable

Surge only works if two copies of the agent can coexist on one node. That is frequently **not** true:

- `hostPort: 9100` on both Pods means the second Pod cannot bind and stays `Pending`.
- `hostNetwork: true` agents that bind a fixed listening port collide the same way.
- Agents holding an exclusive lock on a host path or a device conflict.

Rules to remember:

- `maxUnavailable` and `maxSurge` cannot **both** be zero; the rollout would be unable to make progress.
- Increasing `maxUnavailable` speeds up the rollout at the cost of a wider coverage gap.
- `maxSurge` is the right tool only for stateless, port-flexible agents.

### Triggering and Controlling a Rollout

```bash
# Change the image, which mutates spec.template and starts a rollout
kubectl set image daemonset/node-exporter \
  node-exporter=quay.io/prometheus/node-exporter:v1.9.0

kubectl rollout status daemonset/node-exporter --timeout=10m

# Force every Pod to be recreated with the same template
kubectl rollout restart daemonset/node-exporter
```

`kubectl rollout pause` is **not** supported for DaemonSets; use `OnDelete` or a conservative availability budget to control blast radius instead. `kubectl rollout restart` works by stamping `kubectl.kubernetes.io/restartedAt` into the Pod template annotations, which changes the template hash and therefore triggers a normal rolling update.

### OnDelete

With `type: OnDelete`, updating `spec.template` does **not** touch running Pods. New Pods are only created when you delete the old ones yourself, or when a new node joins.

```yaml
spec:
  updateStrategy:
    type: OnDelete
```

```bash
# Update the template (nothing happens to running pods yet)
kubectl set image daemonset/calico-node calico-node=calico/node:v3.28.2

# UP-TO-DATE will read 0 while READY stays at full count
kubectl get ds calico-node

# Roll one node at a time, manually, verifying between each
kubectl delete pod -n calico-system calico-node-abc12
```

Use `OnDelete` when the agent is critical enough that you want a human decision per node: CNI plugins, CSI node plugins, and storage daemons are the classic cases. It pairs naturally with a node by node maintenance runbook.

| Strategy | Who deletes old Pods | Best for | Risk |
|----------|---------------------|----------|------|
| `RollingUpdate` | Controller, automatically | Log agents, exporters, non-critical sidecars | Automatic coverage gaps |
| `OnDelete` | You, manually | CNI, CSI, storage, security agents | Drift if you forget to finish the roll |

---

## Rollbacks and ControllerRevisions

DaemonSets, like StatefulSets, record history as **ControllerRevision** objects rather than ReplicaSets.

```bash
kubectl rollout history daemonset/node-exporter
kubectl rollout history daemonset/node-exporter --revision=3
kubectl rollout undo daemonset/node-exporter
kubectl rollout undo daemonset/node-exporter --to-revision=2

# The raw objects behind the history
kubectl get controllerrevisions -l app.kubernetes.io/name=node-exporter
```

`spec.revisionHistoryLimit` (default 10) caps how many ControllerRevisions are retained. A rollback with `OnDelete` updates the template but, consistently with the strategy, still waits for you to delete Pods.

---

## Host Networking and Host Paths

Node agents routinely need to escape normal Pod isolation. Understand each escape hatch and its cost.

### hostNetwork

```yaml
spec:
  template:
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
```

With `hostNetwork: true` the Pod shares the node's network namespace:

- The Pod's IP **is** the node IP.
- `containerPort` values bind directly on the host; port conflicts are node wide.
- The agent can run before the CNI has configured pod networking, which is exactly why CNI agents and `kube-proxy` use it.
- It receives the `network-unavailable` toleration from the controller.

**Always pair it with `dnsPolicy: ClusterFirstWithHostNet`.** The default `ClusterFirst` policy is silently downgraded to the node's resolv.conf when `hostNetwork` is true, so cluster DNS names stop resolving. `ClusterFirstWithHostNet` keeps CoreDNS in the path.

> 📖 **See Also**: [coredns.md](coredns.md) for how cluster DNS resolution actually works.

### hostPort Without hostNetwork

```yaml
        ports:
        - containerPort: 9100
          hostPort: 9100
```

This keeps the Pod in its own network namespace but asks the CNI's portmap plugin to DNAT the host port to the Pod. The scheduler treats `hostPort` as a real resource: only one Pod per node can hold a given `protocol/hostIP/port` tuple. This is the number one reason `maxSurge` breaks DaemonSet rollouts.

### hostPath Volumes

```yaml
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
          type: Directory
      - name: containerd-sock
        hostPath:
          path: /run/containerd/containerd.sock
          type: Socket
```

Supported `type` values include `DirectoryOrCreate`, `Directory`, `FileOrCreate`, `File`, `Socket`, `CharDevice` and `BlockDevice`. Setting `type` explicitly turns a silent misconfiguration into a clear startup failure, so always set it.

`hostPath` is a genuine security boundary crossing: mounting `/` or the container runtime socket effectively grants node level control. Restrict it with Pod Security Admission (`hostPath` volumes are disallowed by the `baseline` and `restricted` levels), a dedicated namespace at the `privileged` level used only by trusted node agents, and `readOnly: true` on every mount that does not need to write.

### mountPropagation

```yaml
        volumeMounts:
        - name: plugin-dir
          mountPath: /var/lib/kubelet/plugins
          mountPropagation: Bidirectional
```

| Value | Meaning |
|-------|---------|
| `None` | Default; no propagation in either direction after the mount |
| `HostToContainer` | Mounts created on the host later become visible in the container |
| `Bidirectional` | Mounts created in the container propagate back to the host |

`Bidirectional` requires a **privileged** container and is what CSI node plugins use, because the mounts they create must be visible to the kubelet on the host. Do not enable it casually.

---

## Priority, Preemption and system-node-critical

Because DaemonSet Pods go through the scheduler, they compete for resources with everything else. Priority is how you win that competition.

Kubernetes ships two built in PriorityClasses:

| PriorityClass | Value | Intended for |
|---------------|-------|--------------|
| `system-node-critical` | 2000001000 | Pods that must run for the **node** to function: CNI, kube-proxy, CSI node plugins |
| `system-cluster-critical` | 2000000000 | Pods that must run for the **cluster** to function: CoreDNS, metrics pipeline |

```yaml
spec:
  template:
    spec:
      priorityClassName: system-node-critical
```

```bash
kubectl get priorityclasses
# NAME                      VALUE        GLOBAL-DEFAULT   AGE
# system-cluster-critical   2000000000   false            30d
# system-node-critical      2000001000   false            30d
```

Effects of a high priority class: higher priority Pods are dequeued from the scheduling queue first; if no node fits, the scheduler may **preempt** lower priority Pods to make room (for a DaemonSet that happens on the single pinned node); and under node resource pressure the kubelet ranks eviction candidates by QoS class and then by priority, so a critical agent is evicted last.

Setting `system-node-critical` on a badly behaved agent is dangerous: it will happily preempt your application Pods. Reserve it for software that genuinely breaks the node when absent.

> 📖 **See Also**: [cgroups.md](cgroups.md) for QoS classes and eviction ordering.

---

## Static Pods as an Alternative

Some components cannot be DaemonSets because they must run **before** the control plane exists. That is a chicken and egg problem: a DaemonSet Pod needs the API server to be stored and the scheduler to be bound, but the API server itself is one of the things you are trying to start.

**Static Pods** solve this. The kubelet watches a directory on disk and runs whatever Pod manifests it finds there, with no API server involvement at all.

```
┌───────────────────────────────────────────────────────────────────┐
│               Static Pod vs DaemonSet Pod                         │
├───────────────────────────────────────────────────────────────────┤
│  DAEMONSET POD                        STATIC POD                  │
│  You write a DaemonSet object         You drop a YAML file in     │
│           ▼                           /etc/kubernetes/manifests/  │
│  Controller creates the Pod                    ▼                  │
│           ▼                           kubelet reads the file      │
│  kube-scheduler binds it                       ▼                  │
│           ▼                           kubelet starts containers   │
│  kubelet starts containers                     ▼                  │
│                                       kubelet creates a MIRROR    │
│  Requires: apiserver + scheduler      Pod in the API for          │
│            + controller-manager       visibility only             │
│                                       Requires: kubelet only      │
└───────────────────────────────────────────────────────────────────┘
```

### Where They Live and Mirror Pods

```bash
# The path is set by staticPodPath in the kubelet config file
grep -i staticPodPath /var/lib/kubelet/config.yaml
# staticPodPath: /etc/kubernetes/manifests

ls -1 /etc/kubernetes/manifests/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

For each static Pod the kubelet creates a read only **mirror Pod** in the API server so that `kubectl get pods` shows it. The mirror Pod's name is the static Pod name with the node name appended:

```bash
kubectl get pods -n kube-system -o wide | grep apiserver
# kube-apiserver-cp-01   1/1   Running   0   30d   10.0.0.11   cp-01
#              ^^^^^^ node name suffix identifies a mirror pod
```

Deleting a mirror Pod with `kubectl delete pod` does not remove the static Pod; the kubelet simply recreates the mirror, because the source of truth is the file on disk. To actually stop a static Pod you move or delete its manifest file:

```bash
sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/   # stop
sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/   # start
```

### Comparison

| Aspect | DaemonSet | Static Pod |
|--------|-----------|------------|
| Managed by | DaemonSet controller | kubelet on one node |
| Requires API server | Yes | No |
| Requires scheduler | Yes | No |
| Scope | Every matching node, cluster wide | One node, per file |
| Update mechanism | `kubectl apply`, rolling update | Edit the file on each node |
| Visible in `kubectl get pods` | Yes, real Pod | Yes, as a mirror Pod |
| Deletable via kubectl | Yes | No, must remove the file |
| Typical use | kube-proxy, CNI, log agents | etcd, kube-apiserver, kube-scheduler, kube-controller-manager |

Note that `kube-proxy` is a DaemonSet even in kubeadm clusters, because by the time it is needed the API server is already up. Only the four control plane components are static.

> 📖 **See Also**: [control-plane-node.md](control-plane-node.md) and [kubelet.md](kubelet.md).

---

## DaemonSet Status Fields

`kubectl get ds` columns map directly to `.status` fields. Knowing which is which turns a confusing output into a diagnosis.

```bash
kubectl get ds -n kube-system kube-proxy -o jsonpath='{.status}' | jq
```

| Column / field | Meaning |
|----------------|---------|
| `desiredNumberScheduled` (DESIRED) | Nodes that **should** run a Pod, per your selectors |
| `currentNumberScheduled` (CURRENT) | Nodes actually running at least one Pod of this DaemonSet |
| `numberReady` (READY) | Pods passing their readiness probe |
| `updatedNumberScheduled` (UP-TO-DATE) | Pods running the **current** template revision |
| `numberAvailable` (AVAILABLE) | Ready Pods that have been ready for `minReadySeconds` |
| `numberUnavailable` | `desiredNumberScheduled` minus `numberAvailable` |
| `numberMisscheduled` | Pods running on nodes that should **not** have one |
| `observedGeneration` | The `metadata.generation` this status reflects |

Reading the numbers:

```
DESIRED 5, CURRENT 4  ──► one node never got a Pod (scheduling failure)
CURRENT 5, READY 3    ──► two Pods started but fail readiness
READY 5, UP-TO-DATE 2 ──► rollout in progress, or OnDelete strategy stalled
numberMisscheduled >0 ──► selector changed, leftover Pods pending cleanup
observedGeneration <
  metadata.generation ──► controller has not processed your change yet
```

---

## Deleting DaemonSets

```bash
# Default: cascading delete removes the Pods too
kubectl delete daemonset node-exporter

# Keep the Pods running, orphan them from the controller
kubectl delete daemonset node-exporter --cascade=orphan
```

Orphaned Pods keep running until something deletes them, and they retain their labels, so a newly created DaemonSet with a matching selector will **adopt** them rather than create duplicates. That adoption behaviour is how you rename or move a DaemonSet without downtime, and also how two DaemonSets sharing a selector end up fighting over the same Pods.

---

## Troubleshooting

### Symptom 1: DESIRED is 0

```bash
kubectl get ds my-agent
# NAME      DESIRED  CURRENT  READY  UP-TO-DATE  AVAILABLE  NODE SELECTOR
# my-agent  0        0        0      0           0          disk=ssd
```

**Cause:** no node matches the `nodeSelector` or `nodeAffinity`.

```bash
# What labels do the nodes actually have?
kubectl get nodes --show-labels

# Does any node carry the label you selected on?
kubectl get nodes -l disk=ssd

# What did you actually ask for?
kubectl get ds my-agent -o jsonpath='{.spec.template.spec.nodeSelector}'
kubectl get ds my-agent -o jsonpath='{.spec.template.spec.affinity}' | jq
```

**Fix:** correct the selector, or label the nodes. Watch for typos and for value type mistakes: `"true"` must be quoted in YAML because label values are strings.

### Symptom 2: DESIRED is N but CURRENT is less than N

A Pod exists in the API but was never bound to a node.

```bash
# Find pods that are Pending
kubectl get pods -l app=my-agent -o wide | grep -v Running

# The Events section is where the real answer is
kubectl describe pod my-agent-x7f2k
```

Common `FailedScheduling` messages and their meanings:

| Message fragment | Root cause | Fix |
|------------------|-----------|-----|
| `didn't match Pod's node affinity/selector` | Injected `metadata.name` affinity plus your selector left no feasible node | Verify node labels; the target node may have lost a label |
| `node(s) had untolerated taint {key: value}` | A custom taint not in the default injected set | Add a matching `tolerations` entry |
| `Insufficient cpu` / `Insufficient memory` | Node has no allocatable room for your requests | Lower `resources.requests` or free capacity, or raise priority |
| `node(s) didn't have free ports for the requested pod ports` | `hostPort` already bound by another Pod | Change the port, or set `maxSurge: 0` if this happened during a rollout |
| `node(s) exceed max volume count` | CSI attach limit reached on that node | Reduce attached volumes on the node |

```bash
# Inspect taints on all nodes in one line each
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key'

# Check allocatable versus requested on the problem node
kubectl describe node node-03 | sed -n '/Allocated resources/,/Events/p'
```

### Symptom 3: Pod Is Running but Never Ready

```bash
kubectl get pods -l app=my-agent
# my-agent-9dk2p   0/1   Running   0   4m

kubectl describe pod my-agent-9dk2p | sed -n '/Events/,$p'
kubectl logs my-agent-9dk2p
```

Look for `Readiness probe failed`. Typical causes:

- The probe port does not match the port the process binds.
- With `hostNetwork: true`, the probe targets the node IP; a process bound to `127.0.0.1` only will fail.
- `initialDelaySeconds` is shorter than the agent's real startup time. Prefer a `startupProbe` for slow starters instead of inflating the liveness delay.

### Symptom 4: CrashLoopBackOff on Every Node

```bash
# Logs from the previous, crashed container instance
kubectl logs my-agent-9dk2p --previous

# Exit code and reason
kubectl get pod my-agent-9dk2p \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq
```

For node agents specifically, check permission problems first: a missing `hostPath`, a `readOnlyRootFilesystem: true` on an agent that writes to `/tmp`, a `runAsNonRoot: true` on an image whose entrypoint needs root, or a missing capability such as `NET_ADMIN`.

### Symptom 5: Crash on Some Nodes Only

```bash
kubectl get pods -l app=my-agent -o wide --sort-by=.spec.nodeName
kubectl get nodes -L kubernetes.io/arch,kubernetes.io/os
```

Node heterogeneity is the usual culprit: different kernel version, different OS or architecture, a missing device file, cgroup v1 versus cgroup v2, or a host directory that exists on some machines only. Adding `nodeSelector: kubernetes.io/arch: amd64` fixes the classic "works on x86 nodes, crashes on arm64 nodes" case caused by a single-arch image.

### Symptom 6: Rollout Never Completes

```bash
kubectl rollout status daemonset/my-agent
# Waiting for daemon set "my-agent" rollout to finish: 3 out of 5 updated...

kubectl get ds my-agent -o jsonpath='{.spec.updateStrategy}' | jq
```

- If the strategy is `OnDelete`, the rollout is waiting for **you** to delete Pods. This is expected behaviour, not a bug.
- If it is `RollingUpdate`, one node's new Pod is not becoming available. Find it: the Pod whose template hash differs from the rest, or simply the not-ready one, then apply the Symptom 3 or 4 playbook.
- With `maxSurge > 0` and a `hostPort`, the new Pod is `Pending` on a port conflict and the rollout deadlocks. Set `maxSurge: 0`.

```bash
# Which pods are on the old revision?
kubectl get pods -l app=my-agent \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,HASH:.metadata.labels.controller-revision-hash'
```

### Symptom 7: numberMisscheduled Is Non Zero

Pods are running on nodes that no longer match. Usually transient while the controller catches up; if it persists, suspect a stuck controller, an admission webhook rejecting Pod deletions, or a finalizer on the Pods.

```bash
kubectl get ds my-agent -o jsonpath='{.status}' | jq
kubectl logs -n kube-system -l component=kube-controller-manager --tail=100 | grep -i daemon
```

### Symptom 8: Pods Vanish During Node Maintenance

Expected if you added a custom taint the DaemonSet does not tolerate, or if `kubectl drain` deleted them before failing on the missing `--ignore-daemonsets`. Verify:

```bash
kubectl get events --field-selector involvedObject.kind=Pod,reason=Evicted -A
kubectl get node node-02 -o jsonpath='{.spec.taints}' | jq
```

---

## Exam and Interview Traps

1. **`kubectl create daemonset` does not exist.** Generate a Deployment with `--dry-run=client -o yaml`, then change `kind`, drop `replicas` and drop `strategy`.
2. **DaemonSets have no `spec.replicas`.** `kubectl scale` is meaningless here; the count comes from the node inventory.
3. **The field is `updateStrategy`, not `strategy`.** Deployments use `spec.strategy`; DaemonSets and StatefulSets use `spec.updateStrategy`. Copy pasting a Deployment manifest and forgetting this is a guaranteed validation error.
4. **The valid types are `RollingUpdate` and `OnDelete`.** There is no `Recreate` for DaemonSets, and `Recreate` is not a valid DaemonSet strategy even though it is valid for Deployments.
5. **`maxSurge` defaults to 0 and `maxUnavailable` defaults to 1.** They cannot both be 0.
6. **DaemonSet Pods are scheduled by kube-scheduler**, pinned via `nodeAffinity` on `matchFields: metadata.name`, not by setting `spec.nodeName`. Saying "the DaemonSet controller schedules them itself" describes obsolete behaviour.
7. **DaemonSet Pods land on cordoned nodes** because of the injected `node.kubernetes.io/unschedulable:NoSchedule` toleration.
8. **`kubectl drain` needs `--ignore-daemonsets`**, and that flag leaves the Pods running rather than deleting them.
9. **The control plane taint is not tolerated by default.** Only the seven node condition and unschedulable taints listed earlier are injected. To run on control plane nodes you write the toleration yourself.
10. **`network-unavailable` is only tolerated for `hostNetwork: true` Pods.**
11. **`restartPolicy` must be `Always`.** `Never` and `OnFailure` are rejected for DaemonSet Pod templates. Contrast with Jobs, where `Always` is the rejected value.
12. **`spec.selector` is immutable in `apps/v1`.** To change it you delete and recreate the DaemonSet, optionally with `--cascade=orphan` to keep Pods alive for adoption.
13. **DaemonSet history is stored in ControllerRevisions**, not ReplicaSets. `kubectl rollout history` still works.
14. **`kubectl rollout pause` is not supported for DaemonSets.** Only Deployments can be paused.
15. **Rolling a DaemonSet interrupts node level service.** For CNI or CSI, prefer `OnDelete` plus a node by node runbook over an automatic rolling update.
16. **`hostNetwork: true` demands `dnsPolicy: ClusterFirstWithHostNet`**, otherwise cluster DNS silently stops working for that Pod.
17. **Static Pods, not DaemonSets, run the control plane.** Their mirror Pods are named `<name>-<nodename>` and cannot be deleted with kubectl.

---

## Related Topics

- [Pods](pods.md)
- [Controllers](controllers.md)
- [StatefulSets](statefulsets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [kube-scheduler](kube-scheduler.md)
- [kubelet](kubelet.md)
- [kube-proxy](kube-proxy.md)
- [kube-controller-manager](kube-controller-manager.md)
- [Control Plane Node](control-plane-node.md)
- [Worker Node](worker-node.md)
- [CNI](cni.md)
- [CoreDNS](coredns.md)
- [Cgroups](cgroups.md)
- [Network Policy](network-policy.md)
- [Installing the NFS CSI Driver](install-csi-nfs.md)

---

## Key Takeaways

1. A DaemonSet guarantees **one Pod per matching node**; the desired count is derived from the node inventory, so there is no `spec.replicas` and no meaningful `kubectl scale`.
2. DaemonSet Pods are scheduled by the **default scheduler**. The controller pins each Pod to its node by injecting a required `nodeAffinity` term using `matchFields` on `metadata.name`, leaving `spec.nodeName` empty at creation time.
3. Because real scheduling applies, **resource requests, hostPort conflicts, taints and priority all take effect** for DaemonSet Pods exactly as for any other Pod.
4. The controller injects tolerations for `not-ready`, `unreachable`, `disk-pressure`, `memory-pressure`, `pid-pressure` and `unschedulable`, plus `network-unavailable` for `hostNetwork` Pods. Every other taint, including the control plane taint, needs an explicit toleration.
5. The `unschedulable` toleration is why **DaemonSet Pods keep landing on cordoned nodes**, and why `kubectl drain` requires `--ignore-daemonsets` and then leaves them running.
6. Target subsets of nodes with `nodeSelector` for simple equality or `nodeAffinity` for OR, negation and numeric comparison; your terms are combined with the injected field selector, not replaced by it.
7. `RollingUpdate` with `maxUnavailable` (default 1) and `maxSurge` (default 0) automates rollouts but creates per node coverage gaps; `maxSurge` is unusable for agents with `hostPort` or a fixed host listening port.
8. `OnDelete` hands rollout control to you and is the safer choice for CNI, CSI and other agents whose restart disrupts the node.
9. Rollout history lives in **ControllerRevisions**, and `kubectl rollout history`, `undo` and `restart` all work, but `pause` does not.
10. Node agents use `hostNetwork`, `hostPort`, `hostPath` and sometimes `Bidirectional` mount propagation; each one weakens isolation, so pair them with tight `securityContext` settings and Pod Security Admission policy.
11. `priorityClassName: system-node-critical` protects genuinely node critical agents from preemption and eviction, and lets them preempt others; do not apply it indiscriminately.
12. **Static Pods** run the control plane because they need only the kubelet, not the API server or the scheduler. Their mirror Pods are visible in the API but can only be removed by deleting the manifest file.
13. Read the status fields carefully: `DESIRED` versus `CURRENT` isolates scheduling failures, `CURRENT` versus `READY` isolates probe failures, and `READY` versus `UP-TO-DATE` isolates rollout stalls.

---

## References

- [DaemonSet concept](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/)
- [Perform a Rolling Update on a DaemonSet](https://kubernetes.io/docs/tasks/manage-daemon/update-daemon-set/)
- [Perform a Rollback on a DaemonSet](https://kubernetes.io/docs/tasks/manage-daemon/rollback-daemon-set/)
- [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
- [Static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
- [Mirror Pods](https://kubernetes.io/docs/reference/glossary/?all=true#term-mirror-pod)
- [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [Volumes: hostPath](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [DaemonSet API reference (apps/v1)](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/daemon-set-v1/)
