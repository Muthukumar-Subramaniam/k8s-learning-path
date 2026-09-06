# 🛠️ Kubernetes Pod Operations

The practical operator handbook for Pods: creating them, reading their output columns correctly, extracting exactly the field you need, reading logs and events, executing into them, debugging images with no shell, and a systematic decision tree for every common failure.

## 📋 Table of Contents

- [Creating Pods](#creating-pods)
- [kubectl run as a Manifest Generator](#kubectl-run-as-a-manifest-generator)
- [Reading kubectl get pods](#reading-kubectl-get-pods)
- [Output Formats](#output-formats)
- [Selectors, Sorting and Filtering](#selectors-sorting-and-filtering)
- [kubectl describe pod, Read Top to Bottom](#kubectl-describe-pod-read-top-to-bottom)
- [kubectl logs](#kubectl-logs)
- [kubectl exec](#kubectl-exec)
- [kubectl debug](#kubectl-debug)
- [kubectl cp](#kubectl-cp)
- [kubectl port-forward](#kubectl-port-forward)
- [kubectl attach](#kubectl-attach)
- [kubectl top pod](#kubectl-top-pod)
- [Editing and Patching](#editing-and-patching)
- [Deleting Pods](#deleting-pods)
- [Bulk Operations](#bulk-operations)
- [Waiting and Watching](#waiting-and-watching)
- [The Pod Troubleshooting Decision Tree](#the-pod-troubleshooting-decision-tree)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Creating Pods

### Declarative: The Only Approach for Production

```yaml
# pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: default
  labels:
    app: web
    tier: frontend
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - name: http
          containerPort: 80
      resources:
        requests: {cpu: "100m", memory: "128Mi"}
        limits:   {cpu: "500m", memory: "256Mi"}
```

```bash
# Apply: creates or updates, records intent in the
# kubectl.kubernetes.io/last-applied-configuration annotation
kubectl apply -f pod.yaml

# Server side apply: field ownership is tracked in metadata.managedFields
kubectl apply -f pod.yaml --server-side --field-manager=my-tool

# Create: fails if the object already exists, records no intent annotation
kubectl create -f pod.yaml

# Replace: delete + recreate. Required for immutable Pod fields.
kubectl replace --force -f pod.yaml

# Dry runs
kubectl apply -f pod.yaml --dry-run=client    # local validation only
kubectl apply -f pod.yaml --dry-run=server    # full admission, nothing persisted

# Diff against the live object before applying
kubectl diff -f pod.yaml

# Apply a whole directory, recursively
kubectl apply -f ./manifests/ -R

# From stdin, useful in scripts and in exams
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: quick}
spec:
  containers: [{name: c, image: busybox:1.36, command: ["sleep","3600"]}]
EOF
```

| Command | Object exists | Object missing | Records intent |
|---------|---------------|----------------|----------------|
| `apply` | Patches the difference | Creates | Yes |
| `create` | Error `AlreadyExists` | Creates | No |
| `replace` | Full overwrite | Error `NotFound` | No |
| `replace --force` | Delete then create | Creates | No |

### Imperative

```bash
# Run a Pod (NOT a Deployment in current kubectl versions)
kubectl run web --image=nginx:1.27-alpine

# Common flags
kubectl run web \
  --image=nginx:1.27-alpine \
  --port=80 \
  --labels="app=web,tier=frontend" \
  --env="LOG_LEVEL=debug" \
  --env="TZ=UTC" \
  --restart=Never \
  --requests='cpu=100m,memory=128Mi' \
  --limits='cpu=500m,memory=256Mi' \
  --annotations="owner=platform-team" \
  --namespace=default

# Override the entrypoint (everything after -- becomes args/command)
kubectl run busy --image=busybox:1.36 --restart=Never -- sleep 3600

# Interactive, self deleting throwaway Pod: the single most useful
# one liner for debugging cluster networking and DNS
kubectl run tmp --rm -it --image=nicolaka/netshoot:latest --restart=Never -- bash

# Run once and print the output, then delete
kubectl run dnscheck --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

| `--restart` value | What is created |
|-------------------|-----------------|
| `Always` (default) | A Pod with `restartPolicy: Always` |
| `OnFailure` | A Pod with `restartPolicy: OnFailure` |
| `Never` | A Pod with `restartPolicy: Never` |

⚠ `kubectl run` no longer creates Deployments. Use `kubectl create deployment` for that.

---

## kubectl run as a Manifest Generator

This is the highest value time saver in a CKA or CKAD exam and it is genuinely useful day to day.

```bash
kubectl run web --image=nginx:1.27-alpine \
  --dry-run=client -o yaml > pod.yaml
```

```yaml
# Generated output (creationTimestamp: null and empty status are noise)
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    run: web
  name: web
spec:
  containers:
  - image: nginx:1.27-alpine
    name: web
    resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
status: {}
```

### Generator Recipes

```bash
# Pod skeleton with everything the flags support
kubectl run app --image=myapp:v1 --port=8080 \
  --labels="app=myapp,env=prod" \
  --env="MODE=production" \
  --requests='cpu=200m,memory=256Mi' \
  --limits='cpu=1,memory=1Gi' \
  --restart=Never \
  --dry-run=client -o yaml

# Deployment skeleton
kubectl create deployment web --image=nginx:1.27 --replicas=3 \
  --dry-run=client -o yaml

# Job skeleton
kubectl create job backup --image=busybox:1.36 \
  --dry-run=client -o yaml -- /bin/sh -c "echo backing up"

# CronJob skeleton
kubectl create cronjob nightly --image=busybox:1.36 --schedule="0 2 * * *" \
  --dry-run=client -o yaml -- /bin/sh -c "echo run"

# Service for an existing Pod
kubectl expose pod web --port=80 --target-port=8080 --name=web-svc \
  --dry-run=client -o yaml

# ConfigMap and Secret
kubectl create configmap app-config --from-literal=LOG_LEVEL=info \
  --dry-run=client -o yaml
kubectl create secret generic db-creds --from-literal=password=s3cr3t \
  --dry-run=client -o yaml
```

### Discovering Fields Without the Docs

```bash
# One level of the schema
kubectl explain pod.spec.containers

# A specific field
kubectl explain pod.spec.containers.livenessProbe.httpGet

# Everything below a node (long, but complete)
kubectl explain pod.spec.securityContext --recursive

# Confirm apiVersion and whether a resource is namespaced
kubectl api-resources | grep -i pod
# NAME   SHORTNAMES   APIVERSION   NAMESPACED   KIND
# pods   po           v1           true         Pod
```

### Useful Shell Setup

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"     # k run x --image=y $do
export now="--force --grace-period=0"    # k delete pod x $now
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
```

---

## Reading kubectl get pods

```bash
kubectl get pods
```

```
NAME                      READY   STATUS             RESTARTS         AGE
web-5d4f8c9b7d-abcde      1/1     Running            0                4d2h
web-5d4f8c9b7d-fghij      1/1     Running            2 (3h12m ago)    4d2h
api-6c8d7f5b4c-klmno      2/3     Running            0                12m
worker-7f9c8d6b5a-pqrst   0/1     CrashLoopBackOff   9 (2m41s ago)    23m
batch-job-xyz12           0/1     Completed          0                1h
init-demo-abc34           0/1     Init:1/3           0                45s
cache-8b7d6f5c4b-uvwxy    0/1     ImagePullBackOff   0                6m
old-pod-99999             0/1     Terminating        0                8m
evicted-pod-11111         0/1     Evicted            0                2h
```

### Column by Column

| Column | Source | Meaning |
|--------|--------|---------|
| `NAME` | `metadata.name` | For a Deployment: `<deploy>-<replicaset-hash>-<random>`. For a StatefulSet: `<sts>-<ordinal>`. For a DaemonSet: `<ds>-<random>`. |
| `READY` | count of `containerStatuses[].ready == true` / total regular containers | `2/3` means one container is failing readiness. Init containers are **not** counted here. |
| `STATUS` | computed by kubectl from `phase`, container waiting reasons, `deletionTimestamp`, `status.reason` | See the table below. |
| `RESTARTS` | sum of `containerStatuses[].restartCount` | With the `(x ago)` suffix showing when the **most recent** restart happened. |
| `AGE` | `metadata.creationTimestamp` | Time since the Pod object was created, not since the container started. |

### The STATUS Column Is Not the Phase

`kubectl` synthesises `STATUS` from several fields, in roughly this order of precedence:

```
if deletionTimestamp is set        → "Terminating"
else if status.reason is set       → that reason  (Evicted, NodeAffinity, Shutdown)
else if an init container is
     still running or failing      → "Init:1/3", "Init:Error", "Init:CrashLoopBackOff"
else if a container is waiting     → the waiting reason
                                     (ContainerCreating, CrashLoopBackOff,
                                      ImagePullBackOff, ErrImagePull,
                                      CreateContainerConfigError, ...)
else if a container is terminated  → the terminated reason (Completed, Error, OOMKilled)
else                               → status.phase (Pending, Running, Succeeded, Failed)
```

| STATUS | Underlying phase | What it means |
|--------|-----------------|---------------|
| `Running` | `Running` | All containers created, at least one running |
| `Completed` | `Succeeded` | All containers exited 0 |
| `Error` | `Failed` or `Running` | A container exited non zero |
| `CrashLoopBackOff` | `Running` | Container is in the restart backoff window |
| `ImagePullBackOff` | `Pending` | Image pull failed, retrying |
| `ContainerCreating` | `Pending` | Sandbox, volumes or container being created |
| `Init:2/3` | `Pending` | Two of three init containers have completed |
| `PodInitializing` | `Pending` | Init containers done, regular containers starting |
| `Terminating` | `Running` (usually) | `deletionTimestamp` is set |
| `Evicted` | `Failed` | Node pressure eviction |
| `OOMKilled` | `Running` or `Failed` | Kernel killed a container for exceeding its memory limit |
| `Unknown` | `Unknown` | The node cannot be reached |

### The RESTARTS Suffix

```
RESTARTS
0                 never restarted
2 (3h12m ago)     two restarts, most recent 3 hours 12 minutes ago  → stable now
9 (2m41s ago)     nine restarts, most recent 2m41s ago              → active crash loop
                  (2m41s is consistent with the 5 minute backoff cap having engaged)
```

The suffix is the single fastest way to tell a **historical** problem from an **ongoing** one. A Pod with 47 restarts where the last one was 6 days ago is fine. A Pod with 3 restarts from 20 seconds ago is on fire.

### Wide Output

```bash
kubectl get pods -o wide
```

```
NAME       READY  STATUS    RESTARTS  AGE  IP           NODE       NOMINATED NODE  READINESS GATES
web-abcde  1/1    Running   0         4d   10.244.1.17  worker-01  <none>          <none>
api-klmno  2/3    Running   0         12m  10.244.2.31  worker-02  <none>          1/2
```

| Extra column | Source | Use |
|--------------|--------|-----|
| `IP` | `status.podIP` | Direct Pod addressing, endpoint verification |
| `NODE` | `spec.nodeName` | Correlate failures with a specific node |
| `NOMINATED NODE` | `status.nominatedNodeName` | Non empty means the scheduler is preempting on this Pod's behalf |
| `READINESS GATES` | `spec.readinessGates` vs `status.conditions` | `1/2` means one custom readiness gate is still False |

---

## Output Formats

### -o yaml and -o json

```bash
kubectl get pod web -o yaml          # the full object, spec + status + managedFields
kubectl get pod web -o json | jq '.status'
```

### -o custom-columns

Column definitions are `HEADER:jsonpath`, comma separated.

```bash
kubectl get pods -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP,QOS:.status.qosClass,PHASE:.status.phase'
```

```
NAME                  NODE        IP            QOS         PHASE
web-5d4f8c9b7d-abcde  worker-01   10.244.1.17   Burstable   Running
api-6c8d7f5b4c-klmno  worker-02   10.244.2.31   Guaranteed  Running
```

```bash
# Images actually in use, across the cluster
kubectl get pods -A -o custom-columns=\
'NS:.metadata.namespace,POD:.metadata.name,IMAGES:.spec.containers[*].image'

# Requests and limits at a glance
kubectl get pods -o custom-columns=\
'NAME:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory,CPU_LIM:.spec.containers[*].resources.limits.cpu,MEM_LIM:.spec.containers[*].resources.limits.memory'

# Restart counts per container
kubectl get pods -o custom-columns=\
'NAME:.metadata.name,CONTAINER:.status.containerStatuses[*].name,RESTARTS:.status.containerStatuses[*].restartCount'

# Column definitions from a file, for reuse
cat > cols.txt <<'EOF'
NAME          NODE            STATUS
.metadata.name .spec.nodeName .status.phase
EOF
kubectl get pods -o custom-columns-file=cols.txt
```

### -o jsonpath

```bash
# A single scalar
kubectl get pod web -o jsonpath='{.status.podIP}{"\n"}'

# All Pod IPs, space separated
kubectl get pods -o jsonpath='{.items[*].status.podIP}'

# One per line with a range
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.podIP}{"\n"}{end}'

# Filter expressions
kubectl get pods -o jsonpath=\
'{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}'

# Every unique image in the cluster
kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' \
  | tr ' ' '\n' | sort -u

# Container name plus its restart count and current state reason
kubectl get pod web -o jsonpath=\
'{range .status.containerStatuses[*]}{.name}{" restarts="}{.restartCount}{" ready="}{.ready}{"\n"}{end}'

# Escaped keys (dots inside a label name)
kubectl get pod web -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}{"\n"}'

# Node name of every non Running Pod
kubectl get pods -A -o jsonpath=\
'{range .items[?(@.status.phase!="Running")]}{.metadata.namespace}{"/"}{.metadata.name}{" on "}{.spec.nodeName}{"\n"}{end}'
```

JSONPath gotchas: `kubectl` implements a subset. There is no `$` root requirement, arithmetic and regular expressions are not supported, and `{"\n"}` is required for newlines because the shell will not add them.

### -o go-template

More powerful than jsonpath when you need conditionals or formatting.

```bash
kubectl get pods -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{.status.phase}}{{"\n"}}{{end}}'

# Conditional output: only Pods with restarts
kubectl get pods -o go-template='
{{- range .items -}}
  {{- range .status.containerStatuses -}}
    {{- if gt .restartCount 0.0 -}}
      {{ .name }} restarted {{ .restartCount }} times{{ "\n" }}
    {{- end -}}
  {{- end -}}
{{- end -}}'

# From a file
kubectl get pods -o go-template-file=report.tmpl

# Handle a possibly missing field
kubectl get pods -o go-template='
{{range .items}}{{.metadata.name}}: {{if .status.podIP}}{{.status.podIP}}{{else}}no-ip{{end}}{{"\n"}}{{end}}'
```

### Other Formats

```bash
kubectl get pods -o name          # pod/web-abcde  (perfect for piping)
kubectl get pods -o wide
kubectl get pod web -o yaml --show-managed-fields=false   # hide managedFields noise
```

---

## Selectors, Sorting and Filtering

### Label Selectors

```bash
kubectl get pods -l app=web
kubectl get pods -l 'app=web,tier=frontend'          # AND
kubectl get pods -l 'app!=web'
kubectl get pods -l 'env in (prod,staging)'
kubectl get pods -l 'env notin (dev)'
kubectl get pods -l 'app'                            # label exists
kubectl get pods -l '!app'                           # label does NOT exist
kubectl get pods --show-labels                       # append a LABELS column
kubectl get pods -L app,tier                         # one column per label key
```

### Field Selectors

Field selectors query the API server, so they scale far better than piping through `grep`. Only a fixed set of fields is indexed for Pods.

```bash
kubectl get pods --field-selector=status.phase=Running
kubectl get pods --field-selector=status.phase!=Running
kubectl get pods --field-selector=spec.nodeName=worker-02
kubectl get pods -A --field-selector=status.phase=Failed
kubectl get pods --field-selector=metadata.namespace!=kube-system -A
kubectl get pods --field-selector='status.phase=Running,spec.nodeName=worker-01'
```

Supported Pod field selectors:

```
metadata.name          metadata.namespace
spec.nodeName          spec.restartPolicy
spec.schedulerName     spec.serviceAccountName
status.phase           status.podIP
status.nominatedNodeName
```

Anything else returns `field label not supported`.

### Sorting

```bash
kubectl get pods --sort-by=.metadata.creationTimestamp
kubectl get pods --sort-by=.status.containerStatuses[0].restartCount
kubectl get pods -A --sort-by=.spec.nodeName
kubectl get pods --sort-by='.metadata.name'

# Newest last is usually what you want for events
kubectl get events --sort-by=.lastTimestamp
kubectl get events --sort-by=.metadata.creationTimestamp
```

### Scope and Watching

```bash
kubectl get pods -A                    # all namespaces
kubectl get pods -n kube-system
kubectl get pods -w                    # initial list, then stream changes
kubectl get pods -w --watch-only       # skip the initial list, stream only
kubectl get pods -l app=web -w -o wide

# Poll style alternative when you want a full refresh
watch -n 2 'kubectl get pods -o wide'
```

---

## kubectl describe pod, Read Top to Bottom

```bash
kubectl describe pod api-6c8d7f5b4c-klmno -n production
```

```
Name:             api-6c8d7f5b4c-klmno
Namespace:        production
Priority:         1000000
Priority Class:   high-priority
Service Account:  api-sa
Node:             worker-02/10.0.1.11
Start Time:       Fri, 05 Sep 2026 09:14:22 +0000
Labels:           app=api
                  pod-template-hash=6c8d7f5b4c
                  tier=backend
Annotations:      kubectl.kubernetes.io/default-container: api
                  prometheus.io/port: 9090
                  prometheus.io/scrape: true
Status:           Running
IP:               10.244.2.31
IPs:
  IP:             10.244.2.31
Controlled By:    ReplicaSet/api-6c8d7f5b4c

Init Containers:
  wait-for-db:
    Container ID:  containerd://a1b2c3...
    Image:         busybox:1.36
    Image ID:      docker.io/library/busybox@sha256:9ae97d3...
    Port:          <none>
    Command:
      sh
      -c
      until nc -z postgres 5432; do sleep 2; done
    State:          Terminated
      Reason:       Completed
      Exit Code:    0
      Started:      Fri, 05 Sep 2026 09:14:25 +0000
      Finished:     Fri, 05 Sep 2026 09:14:31 +0000
    Ready:          True
    Restart Count:  0

Containers:
  api:
    Container ID:   containerd://d4e5f6...
    Image:          registry.example.com/api:v2.3.1
    Image ID:       registry.example.com/api@sha256:77aa10...
    Port:           8080/TCP
    Host Port:      0/TCP
    State:          Running
      Started:      Fri, 05 Sep 2026 09:14:33 +0000
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Fri, 05 Sep 2026 09:12:02 +0000
      Finished:     Fri, 05 Sep 2026 09:14:31 +0000
    Ready:          True
    Restart Count:  3
    Limits:
      cpu:     1
      memory:  1Gi
    Requests:
      cpu:      500m
      memory:   512Mi
    Liveness:   http-get http://:8080/healthz delay=15s timeout=2s period=10s #success=1 #failure=3
    Readiness:  http-get http://:8080/readyz  delay=0s  timeout=2s period=5s  #success=1 #failure=2
    Startup:    http-get http://:8080/healthz delay=0s  timeout=1s period=10s #success=1 #failure=30
    Environment:
      LOG_LEVEL:     info
      POD_IP:         (v1:status.podIP)
      DB_PASSWORD:   <set to the key 'password' in secret 'db-credentials'>  Optional: false
    Mounts:
      /etc/api from config (ro)
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-r7x2k (ro)

  metrics-adapter:
    Image:          quay.io/example/adapter:v0.4
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
    Ready:          False
    Restart Count:  9

Conditions:
  Type                        Status
  PodReadyToStartContainers   True
  Initialized                 True
  Ready                       False
  ContainersReady             False
  PodScheduled                True

Volumes:
  config:
    Type:      ConfigMap (a volume populated by a ConfigMap)
    Name:      api-config
    Optional:  false
  kube-api-access-r7x2k:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    DownwardAPI:             true

QoS Class:                   Burstable
Node-Selectors:              kubernetes.io/os=linux
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s

Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  12m                default-scheduler  Successfully assigned production/api-6c8d7f5b4c-klmno to worker-02
  Normal   Pulled     12m                kubelet            Container image "busybox:1.36" already present on machine
  Normal   Created    12m                kubelet            Created container wait-for-db
  Normal   Started    12m                kubelet            Started container wait-for-db
  Normal   Pulling    12m                kubelet            Pulling image "registry.example.com/api:v2.3.1"
  Normal   Pulled     11m                kubelet            Successfully pulled image in 6.114s
  Warning  BackOff    2m (x28 over 10m)  kubelet            Back-off restarting failed container metrics-adapter
```

### What Each Block Tells You

| Block | Read it for |
|-------|-------------|
| `Node:` | **First thing to check.** Empty means the scheduler never placed it; skip to the Events for `FailedScheduling`. |
| `Controlled By:` | `<none>` means a bare Pod with no self healing. Otherwise names the owning ReplicaSet, Job, StatefulSet or DaemonSet. |
| `Labels:` | Whether the Pod matches the Service selector you expect. `pod-template-hash` identifies the ReplicaSet generation. |
| `Annotations:` | `kubectl.kubernetes.io/default-container` tells `logs` and `exec` which container to use by default. |
| `Status:` / `IP:` | Phase and Pod IP. No IP means the sandbox is not up. |
| `Init Containers:` | Each one's `State` and `Exit Code`. A stuck init container blocks everything. |
| `Containers: ... State:` | What the container is doing **right now**. |
| `Containers: ... Last State:` | **The gold.** `OOMKilled / Exit Code: 137` in the example above is the actual root cause, even though the container is currently Running. |
| `Restart Count:` | Per container, unlike the summed `RESTARTS` column in `get pods`. |
| `Limits:` / `Requests:` | Confirm what the container actually got, including anything injected by a LimitRange. |
| `Liveness/Readiness/Startup:` | The rendered probe config on one line. Verify the path, port and timings without reading YAML. |
| `Environment:` | Secret values are shown as a reference, never as plaintext. |
| `Mounts:` | The **effective** mount paths, with `(ro)` for read only. |
| `Conditions:` | The five gates. `Ready: False` with `Initialized: True` points squarely at readiness. |
| `Volumes:` | The resolved volume types and sources. |
| `QoS Class:` | Computed, and it determines eviction order. |
| `Node-Selectors:` / `Tolerations:` | Why this Pod can or cannot land on a given node. The two 300s tolerations are auto injected. |
| `Events:` | Chronological, oldest first. `(x28 over 10m)` is a deduplicated repeat count. |

⚠ **Events expire.** The default retention is one hour. A `describe` on an old broken Pod may show `Events: <none>`, which does not mean nothing happened.

```bash
# Describe several at once
kubectl describe pods -l app=api

# Just the events section
kubectl describe pod api-klmno | sed -n '/^Events:/,$p'

# Cluster wide events for one object, which survives kubectl's own formatting
kubectl get events -n production \
  --field-selector involvedObject.name=api-6c8d7f5b4c-klmno \
  --sort-by=.lastTimestamp
```

---

## kubectl logs

```bash
kubectl logs <pod>                     # single container Pod
kubectl logs <pod> -c <container>      # multi container Pod
```

### Every Flag That Matters

```bash
# Follow (stream)
kubectl logs -f web

# The PREVIOUS incarnation of a crashed container. Essential for CrashLoopBackOff.
kubectl logs web --previous
kubectl logs web -c api -p            # -p is the short form

# Specific container in a multi container Pod
kubectl logs api-klmno -c metrics-adapter

# All containers in the Pod, including init containers
kubectl logs api-klmno --all-containers=true --prefix=true

# Time bounded
kubectl logs web --since=10m
kubectl logs web --since=1h
kubectl logs web --since-time="2026-09-05T09:00:00Z"     # RFC3339

# Line bounded
kubectl logs web --tail=100
kubectl logs web --tail=-1            # everything the node still has

# Timestamps prepended by kubelet (independent of the app's own format)
kubectl logs web --timestamps

# Byte limit, useful against a runaway logger
kubectl logs web --limit-bytes=1048576

# Do not fail the whole command if one container has no logs
kubectl logs -l app=api --all-containers --ignore-errors
```

### Logs Across Multiple Pods

```bash
# By label selector: streams from all matching Pods
kubectl logs -l app=web --all-containers --prefix --tail=50

# Follow across a selector. Default concurrency limit is 5 Pods.
kubectl logs -l app=web -f --max-log-requests=20 --prefix

# By controller: kubectl picks ONE Pod from the controller's selector
kubectl logs deployment/web
kubectl logs deployment/web -f --tail=20
kubectl logs job/backup
kubectl logs statefulset/mysql -c mysql
kubectl logs daemonset/node-exporter -n monitoring
```

⚠ `kubectl logs deployment/web` does **not** aggregate all replicas. It picks one Pod. For all replicas use `-l app=web`.

### Where Logs Actually Come From

```
container stdout/stderr
        │
        ▼
container runtime writes to
  /var/log/pods/<ns>_<pod>_<uid>/<container>/0.log
        │  (symlinked from /var/log/containers/)
        ▼
kubelet serves them over the /logs endpoint
        │
        ▼
API server proxies them to kubectl
```

Consequences:

- **Logs are rotated by the kubelet**, controlled by `containerLogMaxSize` (commonly 10Mi) and `containerLogMaxFiles` (commonly 5). Older lines are gone.
- **Only the current and the immediately previous container instance are retained.** `--previous` cannot reach two crashes back.
- **Deleting a Pod destroys its logs.** If you need history, ship logs off node.
- **An application that logs to a file instead of stdout produces nothing** in `kubectl logs`. Either reconfigure it or add a sidecar that tails the file to stdout.
- `ephemeral-storage` limits include log volume.

```bash
# On the node, the raw files
sudo ls -l /var/log/containers/ | grep web
sudo tail -f /var/log/pods/production_web-abcde_<uid>/nginx/0.log
```

---

## kubectl exec

```bash
# Non interactive, single command
kubectl exec web -- ls -l /usr/share/nginx/html

# Interactive shell
kubectl exec -it web -- /bin/sh
kubectl exec -it web -- /bin/bash

# Specific container
kubectl exec -it api-klmno -c metrics-adapter -- /bin/sh

# Environment of the running process
kubectl exec web -- env | sort

# Check what is actually listening inside the Pod
kubectl exec web -- netstat -tlnp 2>/dev/null || kubectl exec web -- ss -tlnp

# Confirm PID 1 (signal handling)
kubectl exec web -- ps -o pid,ppid,comm

# Test the readiness endpoint from inside
kubectl exec web -- wget -qO- --timeout=2 http://127.0.0.1:8080/readyz

# DNS resolution from inside the Pod
kubectl exec web -- cat /etc/resolv.conf
kubectl exec web -- nslookup kubernetes.default
```

### The `--` Separator

```bash
# ❌ WRONG: -l is parsed by kubectl, not by ls
kubectl exec web ls -l /

# ✅ RIGHT: everything after -- goes to the container
kubectl exec web -- ls -l /
```

### Pipes and Redirection Run on YOUR Machine

```bash
# ❌ The grep runs locally, on kubectl's stdout. Works, but the whole
#    log is transferred first.
kubectl exec web -- cat /var/log/app.log | grep ERROR

# ✅ Run the pipeline INSIDE the container
kubectl exec web -- sh -c 'grep ERROR /var/log/app.log | tail -20'

# ❌ This creates the file on your laptop
kubectl exec web -- echo hi > /tmp/in-container.txt

# ✅ This creates it in the container
kubectl exec web -- sh -c 'echo hi > /tmp/in-container.txt'
```

### When exec Fails on Distroless Images

Distroless, scratch and `FROM: static` images contain no shell and often no coreutils.

```
$ kubectl exec -it api -- /bin/sh
OCI runtime exec failed: exec failed: unable to start container process:
exec: "/bin/sh": stat /bin/sh: no such file or directory: unknown
```

```
$ kubectl exec -it api -- ls
error: Internal error occurred: error executing command in container:
failed to exec in container: ... exec: "ls": executable file not found in $PATH
```

Try, in order:

```bash
kubectl exec -it api -- /bin/sh        # most images
kubectl exec -it api -- /bin/bash      # debian/ubuntu based
kubectl exec -it api -- /bin/ash       # alpine
kubectl exec -it api -- /busybox/sh    # distroless :debug variants
```

If none work, **stop trying** and use `kubectl debug` with an ephemeral container. That is the supported answer.

### Other exec Failure Modes

| Error | Cause |
|-------|-------|
| `unable to upgrade connection: pod does not exist` | The Pod was deleted or you are in the wrong namespace |
| `container not found` | Wrong `-c` name, or the container has not started yet |
| `error: unable to upgrade connection: container not found ("x")` | Pod is in `ContainerCreating` or `CrashLoopBackOff`; there is no running process to attach to |
| `Unable to use a TTY - input is not a terminal` | You passed `-t` from a non interactive context, for example a CI pipeline. Drop `-t` |
| `cannot exec into a container in a completed pod` | The Pod is `Succeeded` or `Failed` |
| RBAC `Forbidden` on `pods/exec` | `exec` is a separate subresource from `get pods` |

---

## kubectl debug

`kubectl debug` is the modern, supported way to inspect a workload you cannot `exec` into.

### Mode 1: Ephemeral Container on a Running Pod

```bash
kubectl debug -it api-klmno --image=busybox:1.36 --target=api -- sh
```

```
┌─────────────────────────────────────────────────────────────┐
│  Pod: api-klmno   (UNCHANGED, still serving traffic)         │
│                                                              │
│  ┌──────────────┐   ┌──────────────────────────────────┐    │
│  │ api          │   │ debugger-xyz12 (ephemeral)       │    │
│  │ distroless   │   │ busybox:1.36                     │    │
│  │ no shell     │   │ full shell + tools               │    │
│  └──────┬───────┘   └──────────┬───────────────────────┘    │
│         │                      │                            │
│         └─── same net ns ──────┤  same IP, same ports       │
│         └─── same ipc ns ──────┤                            │
│         └─── PID ns (--target)─┘  ps shows api's processes  │
│                                    /proc/1/root is api's fs │
│                                                              │
│  ⚠ Cannot be removed. Persists until the Pod is deleted.     │
└─────────────────────────────────────────────────────────────┘
```

- `--target=<container>` shares that container's **process namespace**, which also makes its filesystem reachable at `/proc/<pid>/root`. Without it you get the Pod's network and IPC only.
- The ephemeral container has **no** resources, probes, ports or lifecycle hooks and does not change the Pod's QoS class.
- It cannot be removed. It stays in `status.ephemeralContainerStatuses` for the life of the Pod.

```bash
# Explicit name so you can reattach later
kubectl debug -it api-klmno --image=nicolaka/netshoot --target=api \
  --container=netdebug -- bash

# Reattach to it after disconnecting
kubectl attach -it api-klmno -c netdebug

# See what has been injected
kubectl get pod api-klmno -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
```

### Mode 2: Debug Copy with --copy-to

Use this when the Pod is crash looping and there is nothing to attach to, or when you must change the command.

```bash
# Copy the Pod, add a debug container to the copy
kubectl debug api-klmno -it --image=busybox:1.36 --copy-to=api-debug -- sh

# Copy AND share the process namespace between all containers in the copy
kubectl debug api-klmno -it --image=busybox:1.36 \
  --copy-to=api-debug --share-processes -- sh

# Copy and REPLACE the broken container's command so it stays up
kubectl debug api-klmno -it --copy-to=api-debug \
  --container=api -- /bin/sh

# Copy and swap the image (for example to a :debug variant of the same app)
kubectl debug api-klmno --copy-to=api-debug \
  --set-image=api=registry.example.com/api:v2.3.1-debug

# Copy, replacing the original Pod name (dangerous, understand the blast radius)
kubectl debug api-klmno -it --copy-to=api-debug --replace --image=busybox:1.36
```

⚠ The copy is a **new independent Pod**. It has the original's labels, so it may immediately start receiving Service traffic. Strip or change the labels if that is not what you want, and always delete the copy afterwards.

```bash
kubectl delete pod api-debug
```

### Mode 3: Node Debugging

```bash
kubectl debug node/worker-02 -it --image=busybox:1.36
```

This creates a Pod on that node with `hostNetwork`, `hostPID` and `hostIPC` enabled, and the node's root filesystem mounted at `/host`.

```bash
# Inside the debug pod:
chroot /host                            # become effectively "on the node"
ls /host/var/log/containers/
cat /host/etc/kubernetes/kubelet.conf
crictl ps                               # if the binary is present under /host
df -h /host
journalctl -u kubelet --since "10 min ago"   # after chroot

# Clean up: node debug pods are NOT auto removed
kubectl get pods -A | grep node-debugger
kubectl delete pod node-debugger-worker-02-abc12
```

### Profiles

```bash
kubectl debug -it api-klmno --image=busybox --target=api --profile=general -- sh
```

| `--profile` | What it grants |
|-------------|----------------|
| `legacy` | The historical behaviour, minimal changes |
| `general` | A reasonable default set of debugging capabilities |
| `baseline` | Compliant with the `baseline` Pod Security Standard |
| `restricted` | Compliant with the `restricted` Pod Security Standard |
| `netadmin` | Adds `NET_ADMIN` and `NET_RAW`, for `tcpdump`, `iptables`, `ip` |
| `sysadmin` | Privileged; use only when nothing else works |

The default profile depends on your `kubectl` version, so specify it explicitly in anything you write down. In a namespace enforcing the `restricted` Pod Security Standard, `--profile=restricted` is what will actually be admitted.

```bash
# Packet capture inside a Pod's network namespace
kubectl debug -it web --image=nicolaka/netshoot --profile=netadmin -- \
  tcpdump -i any -nn port 8080
```

---

## kubectl cp

```bash
# Container → local
kubectl cp production/web-abcde:/etc/nginx/nginx.conf ./nginx.conf

# Local → container
kubectl cp ./patch.conf production/web-abcde:/etc/nginx/conf.d/patch.conf

# Specific container in a multi container Pod
kubectl cp production/api-klmno:/app/heap.hprof ./heap.hprof -c api

# A whole directory
kubectl cp production/web-abcde:/var/log/nginx ./nginx-logs

# Namespace can also be given with -n
kubectl cp web-abcde:/tmp/dump.tar ./dump.tar -n production
```

### The tar Dependency

`kubectl cp` is implemented as `kubectl exec <pod> -- tar cf - <path>` piped through the API server. **The container must have a `tar` binary on its `PATH`.**

```
error: Internal error occurred: error executing command in container:
failed to exec in container: ... exec: "tar": executable file not found in $PATH
```

Workarounds when `tar` is absent (distroless, scratch, minimal images):

```bash
# 1. Stream a single file out through exec (binary safe with base64)
kubectl exec web -- cat /app/data.bin | base64 > data.b64
base64 -d data.b64 > data.bin

# Simpler for text files
kubectl exec web -- cat /etc/app/config.yaml > config.yaml

# 2. Stream a file IN
cat local.conf | kubectl exec -i web -- sh -c 'cat > /etc/app/local.conf'
#    (requires a shell, so it fails on distroless too)

# 3. The reliable way: mount a shared volume and use an ephemeral
#    container that DOES have tar
kubectl debug -it web --image=busybox:1.36 --target=app -- sh
#    then, inside: tar cf - /proc/1/root/app | base64
```

Other `kubectl cp` caveats:

- It **overwrites** the destination without asking.
- Symlinks are followed, not preserved.
- File ownership and permissions may not survive.
- There is no progress indicator and no resume; large transfers over a flaky connection simply fail.
- It runs through the API server, so it consumes apiserver bandwidth. Do not use it to move gigabytes.

---

## kubectl port-forward

```bash
# local 8080 → pod 80
kubectl port-forward pod/web-abcde 8080:80

# Same port on both sides
kubectl port-forward pod/web-abcde 8080

# Let the OS pick the local port
kubectl port-forward pod/web-abcde :80

# Multiple ports at once
kubectl port-forward pod/web-abcde 8080:80 9090:9090

# Through a higher level object (kubectl resolves to one Pod)
kubectl port-forward deployment/web 8080:80
kubectl port-forward service/web-svc 8080:80
kubectl port-forward statefulset/mysql 3306:3306

# Named target port
kubectl port-forward pod/web-abcde 8080:http

# Bind to all interfaces (⚠ exposes it on your network)
kubectl port-forward --address 0.0.0.0 pod/web-abcde 8080:80

# Background it
kubectl port-forward pod/web-abcde 8080:80 >/dev/null 2>&1 &
PF_PID=$!
curl -s localhost:8080/healthz
kill $PF_PID
```

How it works and what that implies:

```
 curl localhost:8080
        │
        ▼
 kubectl (local listener)
        │  SPDY / WebSocket tunnel
        ▼
 kube-apiserver
        │
        ▼
 kubelet on the node
        │
        ▼
 Pod network namespace :80
```

- Traffic **bypasses Services, kube-proxy, Ingress and NetworkPolicy**. A successful `port-forward` proves the app is listening; it proves nothing about Service routing.
- It targets a single Pod. Forwarding through `service/` picks one backing Pod, it does not load balance.
- The connection dies when the Pod is deleted or restarted. It does not reconnect.
- The app must listen on `0.0.0.0` or on the Pod IP. An app bound only to `127.0.0.1` inside the container is still reachable, because the forward terminates in the same network namespace, but it will not be reachable through a Service.
- It requires the `pods/portforward` subresource in RBAC.

---

## kubectl attach

`attach` connects to the **existing** PID 1 process. `exec` starts a **new** process.

```bash
kubectl attach web                       # attach to stdout/stderr of PID 1
kubectl attach -it web -c app            # interactive, needs stdin+tty in the spec
kubectl attach -it api-klmno -c netdebug # reattach to an ephemeral container
```

```yaml
# For an interactive attach to work, the container must have been created with:
spec:
  containers:
    - name: app
      image: busybox:1.36
      stdin: true
      tty: true
```

That is exactly what `kubectl run -it` sets.

| | `kubectl attach` | `kubectl exec` |
|---|---|---|
| Process | The already running PID 1 | A brand new process |
| Needs `stdin`/`tty` in the spec | Yes, for interaction | No |
| Detach safely | `Ctrl-P Ctrl-Q` (with a TTY) | Just exit the shell |
| Risk | `Ctrl-C` may kill PID 1 and thus the container | None |
| Use case | Interacting with a REPL or an interactive process | Almost everything else |

⚠ Pressing `Ctrl-C` in an attached session sends SIGINT to PID 1 and can terminate the container.

---

## kubectl top pod

```bash
kubectl top pod
kubectl top pod --containers               # per container breakdown
kubectl top pod -A --sort-by=memory
kubectl top pod -A --sort-by=cpu
kubectl top pod -l app=web
kubectl top pod web-abcde --containers
kubectl top node
```

```
NAME                   CPU(cores)   MEMORY(bytes)
web-5d4f8c9b7d-abcde   3m           12Mi
api-6c8d7f5b4c-klmno   247m         892Mi
```

### The metrics-server Dependency

```
kubectl top pod
      │
      ▼
 kube-apiserver
      │  APIService: v1beta1.metrics.k8s.io
      ▼
 metrics-server  (a Deployment, usually in kube-system)
      │  scrapes /metrics/resource on each kubelet
      ▼
 kubelet ──▶ cAdvisor ──▶ cgroup counters
```

```
error: Metrics API not available
```

means metrics-server is not installed or not healthy.

```bash
# Is the APIService registered and available?
kubectl get apiservices | grep metrics
# v1beta1.metrics.k8s.io   kube-system/metrics-server   True   10d

# Is the deployment healthy?
kubectl -n kube-system get deploy metrics-server
kubectl -n kube-system logs deploy/metrics-server

# Raw metrics through the aggregated API
kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods | jq '.items[0]'
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/production/pods/web-abcde" | jq
```

Key facts:

- Metrics are a **point in time snapshot** collected on a scrape interval (commonly 15 seconds). They are **not** historical. `kubectl top` cannot answer "what was memory usage an hour ago"; that needs Prometheus.
- A newly started Pod shows no metrics until the first scrape completes.
- metrics-server is designed for the HPA and for `kubectl top`. It is explicitly **not** a monitoring solution.
- On clusters with self signed kubelet certificates, metrics-server commonly needs `--kubelet-insecure-tls` or a properly signed kubelet serving certificate.

---

## Editing and Patching

Remember that the Pod spec is nearly immutable. Most edits below are only meaningful on a controller's Pod template.

### kubectl edit

```bash
kubectl edit pod web
KUBE_EDITOR="vim" kubectl edit pod web
kubectl edit deployment web -o json
```

On save, `kubectl` submits the change. For a Pod, an attempt to modify anything outside the allowlist is rejected:

```
error: pods "web" is invalid: spec: Forbidden: pod updates may not change
fields other than `spec.containers[*].image`,
`spec.initContainers[*].image`, `spec.activeDeadlineSeconds`,
`spec.tolerations` (only additions to existing tolerations) ...
```

### kubectl patch

```bash
# 1. Strategic merge patch (DEFAULT for built in types).
#    Understands list merge keys, so it merges the container named "nginx"
#    instead of replacing the whole containers array.
kubectl patch pod web -p \
  '{"spec":{"containers":[{"name":"nginx","image":"nginx:1.27.2-alpine"}]}}'

# 2. JSON merge patch (RFC 7386). Lists are REPLACED wholesale.
kubectl patch pod web --type=merge -p \
  '{"metadata":{"labels":{"tier":"frontend"}}}'

# 3. JSON patch (RFC 6902). Explicit operations and array indexes.
kubectl patch pod web --type=json -p \
  '[{"op":"replace","path":"/spec/containers/0/image","value":"nginx:1.27.2-alpine"}]'

kubectl patch pod web --type=json -p \
  '[{"op":"add","path":"/metadata/labels/canary","value":"true"}]'

kubectl patch pod web --type=json -p \
  '[{"op":"remove","path":"/metadata/labels/canary"}]'

# From a file
kubectl patch pod web --patch-file=patch.yaml
```

| Patch type | Flag | List handling | Use when |
|-----------|------|---------------|----------|
| Strategic merge | (default) | Merges by the `patchMergeKey` (`name` for containers) | Built in Kubernetes types |
| JSON merge | `--type=merge` | **Replaces** the whole list | CRDs (which have no strategic merge metadata), and simple scalar/map updates |
| JSON patch | `--type=json` | Explicit `add`/`remove`/`replace`/`copy`/`move`/`test` on indexed paths | Precise surgery, removing a key, testing before writing |

⚠ Using a strategic merge patch on a CustomResource silently behaves as a JSON merge patch, which will replace lists you meant to append to.

### Labels and Annotations

```bash
kubectl label pod web tier=frontend
kubectl label pod web tier=backend --overwrite      # required to change an existing key
kubectl label pod web tier-                         # remove the key
kubectl label pods -l app=web canary=true           # all matching Pods
kubectl label pods --all env=dev
kubectl label pod web debug=true --dry-run=client -o yaml

kubectl annotate pod web owner="platform-team"
kubectl annotate pod web description="temp" --overwrite
kubectl annotate pod web description-
kubectl annotate pod web kubectl.kubernetes.io/default-container=api
```

Removing a label that a Service selects on **immediately removes the Pod from the Service endpoints** while leaving it running. That is a legitimate technique for taking a misbehaving replica out of rotation for live debugging, and it also causes the owning ReplicaSet to create a replacement.

### set Subcommands

```bash
# image: works on a live Pod (image is one of the mutable fields)
kubectl set image pod/web nginx=nginx:1.27.2-alpine
kubectl set image deployment/web nginx=nginx:1.27.2-alpine
kubectl set image deployment/web '*=registry.example.com/app:v2'   # all containers

# env: only on controllers, NOT on a live Pod
kubectl set env deployment/web LOG_LEVEL=debug
kubectl set env deployment/web LOG_LEVEL-                          # remove
kubectl set env deployment/web --from=configmap/app-config
kubectl set env deployment/web --from=secret/db-creds --prefix=DB_
kubectl set env deployment/web --list                              # show, do not change
kubectl set env deployment/web --all LOG_LEVEL=debug

# resources: only on controllers
kubectl set resources deployment/web \
  --requests=cpu=200m,memory=256Mi \
  --limits=cpu=1,memory=1Gi
kubectl set resources deployment/web -c=nginx --limits=memory=512Mi

# serviceaccount
kubectl set serviceaccount deployment/web web-sa

# Preview any of them
kubectl set image deployment/web nginx=nginx:1.28 --dry-run=client -o yaml
```

### Restarting Workloads

```bash
# There is no "kubectl restart pod". For a controller:
kubectl rollout restart deployment/web
kubectl rollout restart statefulset/mysql
kubectl rollout restart daemonset/node-exporter -n monitoring

kubectl rollout status deployment/web --timeout=300s
kubectl rollout history deployment/web
kubectl rollout undo deployment/web
kubectl rollout undo deployment/web --to-revision=3
```

`rollout restart` works by stamping `kubectl.kubernetes.io/restartedAt` into the Pod template annotations, which changes the template hash and triggers a normal rolling update.

To "restart" a bare Pod you delete and recreate it:

```bash
kubectl get pod web -o yaml > /tmp/web.yaml
kubectl replace --force -f /tmp/web.yaml
```

---

## Deleting Pods

```bash
# Graceful, using spec.terminationGracePeriodSeconds
kubectl delete pod web

# Custom grace period
kubectl delete pod web --grace-period=60

# --now is shorthand for --grace-period=1
kubectl delete pod web --now

# Force: removes the API object immediately without confirming the
# container stopped. Read the warning in Pod Lifecycle before using this.
kubectl delete pod web --grace-period=0 --force

# By label selector
kubectl delete pods -l app=web
kubectl delete pods -l 'env in (dev,test)'

# By field selector
kubectl delete pods --field-selector=status.phase=Failed
kubectl delete pods -A --field-selector=status.phase=Succeeded

# Everything in a namespace
kubectl delete pods --all -n scratch

# From the manifest that created it
kubectl delete -f pod.yaml

# Do not block waiting for finalization
kubectl delete pod web --wait=false

# Cascading behaviour when deleting a controller
kubectl delete deployment web                       # background cascade (default)
kubectl delete deployment web --cascade=foreground   # wait for Pods to go first
kubectl delete deployment web --cascade=orphan       # leave the Pods running
```

⚠ Deleting a Pod owned by a controller does **not** reduce the replica count. The ReplicaSet immediately creates a replacement. To actually remove capacity, scale the controller.

```bash
kubectl scale deployment web --replicas=0
kubectl scale deployment web --replicas=3
kubectl scale deployment web --current-replicas=3 --replicas=5   # optimistic guard
```

---

## Bulk Operations

```bash
# Every Pod not Running, cluster wide
kubectl get pods -A --field-selector=status.phase!=Running

# Every Pod with restarts, sorted
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount' \
  | tail -20

# Clean up Evicted and Completed Pods
kubectl get pods -A --field-selector=status.phase=Failed \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,REASON:.status.reason' \
  | grep Evicted
kubectl delete pods -A --field-selector=status.phase=Failed

# Pod count per node
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | sort | uniq -c | sort -rn

# Pod count per namespace
kubectl get pods -A --no-headers | awk '{print $1}' | sort | uniq -c | sort -rn

# Every image in use, deduplicated
kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' \
  | tr ' ' '\n' | sort -u

# Pods with NO resource requests (BestEffort, first to be evicted)
kubectl get pods -A -o json | jq -r '
  .items[] | select(.status.qosClass=="BestEffort")
  | "\(.metadata.namespace)/\(.metadata.name)"'

# Pods that are Running but not Ready
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(.status.phase=="Running")
  | select(any(.status.conditions[]?; .type=="Ready" and .status=="False"))
  | "\(.metadata.namespace)/\(.metadata.name)"'

# Pods on a specific node, for drain planning
kubectl get pods -A -o wide --field-selector=spec.nodeName=worker-02

# Delete Pods on a node without draining it (they will be rescheduled)
kubectl delete pods -A --field-selector=spec.nodeName=worker-02

# Exec the same command in every matching Pod
for p in $(kubectl get pods -l app=web -o name); do
  echo "=== $p ==="
  kubectl exec "$p" -- nginx -v 2>&1
done

# Piping -o name into another command
kubectl get pods -l app=web -o name | xargs -n1 kubectl delete
```

### Node Drain

```bash
kubectl cordon worker-02        # mark unschedulable, do not move anything
kubectl drain worker-02 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60 \
  --timeout=300s
kubectl uncordon worker-02
```

`drain` uses the eviction API, so it respects PodDisruptionBudgets and will hang if a PDB allows zero disruptions. `--ignore-daemonsets` is almost always required because DaemonSet Pods are not evictable and will be recreated instantly. `--delete-emptydir-data` acknowledges that `emptyDir` contents will be lost. `--force` additionally evicts bare Pods that no controller will recreate, so use it knowingly.

---

## Waiting and Watching

```bash
# Wait on a condition (the correct thing to wait on)
kubectl wait --for=condition=Ready pod/web --timeout=120s
kubectl wait --for=condition=Ready pod -l app=web --timeout=300s
kubectl wait --for=condition=Initialized pod/web --timeout=60s

# Wait for deletion
kubectl wait --for=delete pod/web --timeout=60s

# Wait on an arbitrary field
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/web --timeout=60s

# Rollout completion (the usual CI gate)
kubectl rollout status deployment/web --timeout=300s

# Watch a Pod's state transitions in real time
kubectl get pod web -w
kubectl get pods -l app=web -w -o wide

# Watch events as they happen
kubectl get events -w
kubectl get events -A -w --field-selector type=Warning
```

⚠ Do not wait on `status.phase == Running`. A Pod can be `Running` and completely unable to serve. `--for=condition=Ready` is the correct gate.

---

## The Pod Troubleshooting Decision Tree

```
                     ┌──────────────────────┐
                     │  kubectl get pods    │
                     └──────────┬───────────┘
                                │
      ┌───────────┬─────────────┼─────────────┬──────────────┐
      ▼           ▼             ▼             ▼              ▼
   Pending   ContainerCreating  Running   Terminating     Evicted /
                / ImagePull                                Completed
      │              │            │            │              │
      ▼              ▼            ▼            ▼              ▼
    [A]            [B]         [C][D]        [E]            [F]
```

### [A] Pending

```bash
kubectl describe pod <pod> | grep -A10 Events
```

```
Is spec.nodeName empty?
  YES → the scheduler could not place it. Read the FailedScheduling message.
        "Insufficient cpu"          → not enough allocatable CPU anywhere
        "Insufficient memory"       → same for memory
        "untolerated taint"         → add a toleration or fix the taint
        "didn't match Pod's node affinity/selector" → labels do not exist
        "didn't match pod anti-affinity rules"      → spread constraint blocks it
        "pod has unbound immediate PersistentVolumeClaims" → PVC is Pending
        "node(s) had volume node affinity conflict" → PV zone vs node zone
  NO  → it IS assigned. The problem is on the node, go to [B].
```

```bash
# Is there capacity anywhere?
kubectl describe node | sed -n '/Allocated resources/,/Events/p'
kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,PODS:.status.allocatable.pods'

# Taints on every node
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name): \(.spec.taints // "none")"'

# Is a PVC blocking it?
kubectl get pvc
kubectl describe pvc <name>
```

### [B] ContainerCreating / ImagePullBackOff

```bash
kubectl describe pod <pod> | grep -A20 Events
```

| Event | Meaning | Fix |
|-------|---------|-----|
| `Failed to pull image ... not found` | Wrong repository or tag | Verify with `docker pull` / `crane manifest` from a machine that can reach the registry |
| `pull access denied` / `unauthorized` | Private registry, missing credentials | Create a `kubernetes.io/dockerconfigjson` Secret and reference it in `imagePullSecrets` |
| `toomanyrequests` | Registry rate limit | Authenticate, or mirror the image internally |
| `dial tcp: i/o timeout` | The node cannot reach the registry | Node egress, proxy settings, DNS on the node |
| `FailedMount ... timed out waiting for the condition` | Volume never mounted | Check the PV, the CSI driver Pods, and node logs |
| `FailedAttachVolume ... Multi-Attach error` | An RWO volume is still attached to another node | Wait for the old Pod to fully terminate, or use the out-of-service taint |
| `FailedCreatePodSandBox ... failed to setup network` | CNI failure | CNI DaemonSet health, IP pool exhaustion, node routing |
| `CreateContainerConfigError` | Missing ConfigMap/Secret/key | The message names it. Create it or fix the reference |

```bash
# Verify credentials exist and are the right type
kubectl get secret regcred -o jsonpath='{.type}{"\n"}'
# kubernetes.io/dockerconfigjson

kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | jq '.auths | keys'

# On the node: is the image there and can the runtime pull?
sudo crictl images | grep myapp
sudo crictl pull registry.example.com/api:v2.3.1
```

### [C] CrashLoopBackOff

```bash
# ALWAYS start here
kubectl logs <pod> -c <container> --previous
```

```
No output from --previous?
  → the container may be dying before it writes anything
  → check lastState.terminated for the exit code

kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq

exitCode 0   with restartPolicy Always
             → the container has no long running process. Add a real command.
exitCode 1   → application error. Read the logs.
exitCode 126 → the binary is not executable
exitCode 127 → command not found. Wrong `command`, or wrong image contents.
exitCode 137 → SIGKILL. reason OOMKilled? raise the memory limit or fix the leak.
               Otherwise the grace period expired during termination.
exitCode 139 → SIGSEGV. Native crash, possibly a CPU architecture mismatch.
exitCode 143 → SIGTERM. Usually a normal shutdown the app reported as failure.
```

```bash
# Is a liveness probe doing the killing?
kubectl describe pod <pod> | grep -iE "unhealthy|killing|liveness"

# Run the image with a shell instead of its entrypoint to inspect it
kubectl debug <pod> -it --copy-to=<pod>-debug --container=<c> -- /bin/sh

# Or from scratch
kubectl run inspect --rm -it --image=<the-image> --restart=Never \
  --command -- /bin/sh
```

### [D] Running but 0/1 READY

```bash
kubectl describe pod <pod> | grep -iA3 readiness
# Warning  Unhealthy  30s (x12 over 2m)  kubelet
#   Readiness probe failed: Get "http://10.244.2.31:8080/readyz":
#   dial tcp 10.244.2.31:8080: connect: connection refused
```

```bash
# 1. Does the port even exist inside the Pod?
kubectl exec <pod> -- ss -tlnp 2>/dev/null || kubectl exec <pod> -- netstat -tlnp

# 2. Does the probe path respond from inside?
kubectl exec <pod> -- wget -qO- --timeout=2 http://127.0.0.1:8080/readyz

# 3. Does it respond on the POD IP (which is how the kubelet probes)?
#    An app bound only to 127.0.0.1 fails here.
IP=$(kubectl get pod <pod> -o jsonpath='{.status.podIP}')
kubectl run probe --rm -it --image=curlimages/curl:8.8.0 --restart=Never -- \
  curl -sv --max-time 3 "http://$IP:8080/readyz"

# 4. Is the timing too aggressive?
kubectl get pod <pod> -o jsonpath='{.spec.containers[0].readinessProbe}' | jq

# 5. Is a readiness GATE, not the probe, holding it False?
kubectl get pod <pod> -o jsonpath='{.status.conditions}' | jq
```

Most common causes, in order: the app binds `127.0.0.1` instead of `0.0.0.0`; the probe path or port is wrong; the timeout is too short; a dependency the readiness endpoint checks is genuinely down; a custom readiness gate was never satisfied.

### [E] Terminating Forever

```bash
kubectl get pod <pod> -o jsonpath='{.metadata.finalizers}{"\n"}'
kubectl get pod <pod> -o jsonpath='{.metadata.deletionGracePeriodSeconds}{"\n"}'
kubectl get node $(kubectl get pod <pod> -o jsonpath='{.spec.nodeName}')
```

```
Node NotReady?
  → the kubelet cannot confirm termination. Wait for the node controller,
    or apply the node.kubernetes.io/out-of-service taint on a
    confirmed dead node.

Finalizer present?
  → its controller must remove it. If that controller is gone:
    kubectl patch pod <pod> -p '{"metadata":{"finalizers":null}}' --type=merge

Neither?
  → the app is ignoring SIGTERM and the grace period is long.
    Verify PID 1:  kubectl exec <pod> -- ps -o pid,comm
    Fix the image to use exec form so the app IS PID 1.
```

### [F] Evicted / OOMKilled

```bash
# Evicted: read the message, it names the resource
kubectl describe pod <pod> | grep -A3 "^Status\|^Reason\|^Message"
# Message: The node was low on resource: ephemeral-storage.
#          Container app was using 4Gi, which exceeds its request of 0.

kubectl describe node <node> | sed -n '/Conditions/,/Addresses/p'

# OOMKilled: confirm and size correctly
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
kubectl get pod <pod> -o jsonpath='{.spec.containers[0].resources}' | jq
kubectl top pod <pod> --containers
```

Fixes: set realistic `requests` so the Pod is no longer the first eviction candidate; raise the `memory` limit if the working set genuinely needs it; set `ephemeral-storage` requests and limits and stop writing large files into the container filesystem; for JVM or Node.js workloads, align the heap setting with the container limit rather than the node's total memory.

---

## Exam and Interview Traps

1. **`kubectl run` creates a Pod, not a Deployment.** Use `kubectl create deployment` for a Deployment.

2. **`--dry-run=client -o yaml` is the manifest generator.** `--dry-run=server` runs full admission (webhooks, quotas, Pod Security) without persisting, which is what you want for validating a manifest against real policy.

3. **The `STATUS` column is not `status.phase`.** `CrashLoopBackOff`, `Terminating`, `ContainerCreating` and `Evicted` are synthesised by kubectl.

4. **`READY 2/3` counts only regular containers.** Init containers never appear there.

5. **`RESTARTS 9 (2m41s ago)`**: the suffix is the age of the **most recent** restart. It is what distinguishes an old scar from an active fire.

6. **`kubectl logs` is empty during `CrashLoopBackOff`** because nothing is running. Use `--previous`.

7. **Only the current and one previous container instance are retained.** `--previous` cannot reach two crashes back, and log rotation can delete lines even from the current instance.

8. **`kubectl logs deployment/web` picks one Pod.** Use `-l app=web --prefix` to see all replicas, and raise `--max-log-requests` beyond its default of 5.

9. **Everything after `--` goes to the container.** `kubectl exec pod ls -l` fails because `-l` is consumed by kubectl.

10. **Pipes and redirection in `kubectl exec` run on your machine.** Wrap the pipeline in `sh -c` to run it inside the container.

11. **`kubectl cp` needs `tar` inside the container.** Distroless images fail. Use `cat` piping or an ephemeral container instead.

12. **`kubectl debug --target` is required to see the target's processes.** Without it you share only network and IPC.

13. **Ephemeral containers cannot be removed.** They live for the rest of the Pod's life. `--copy-to` creates a separate Pod you must delete yourself.

14. **`kubectl debug node/<name>` leaves a Pod behind.** Delete the `node-debugger-*` Pod when you are done.

15. **`kubectl port-forward` bypasses Services, kube-proxy, Ingress and NetworkPolicy.** A working forward proves the app listens; it does not prove Service routing works.

16. **`kubectl attach` connects to PID 1. `Ctrl-C` can kill the container.** Detach with `Ctrl-P Ctrl-Q`.

17. **`kubectl top` needs metrics-server** and returns a live snapshot only, with no history.

18. **The default patch type is strategic merge for built in types.** On a CustomResource it degrades to a JSON merge patch, replacing lists rather than merging them.

19. **`kubectl set env` and `kubectl set resources` do not work on a live Pod**, because those fields are immutable. `kubectl set image` does, because `image` is on the mutable allowlist.

20. **`kubectl label pod x tier-` removes the label.** The trailing hyphen is the removal syntax for both `label` and `annotate`.

21. **Deleting a Pod owned by a controller changes nothing permanently.** A replacement appears immediately. Scale the controller instead.

22. **There is no `kubectl restart pod`.** Use `kubectl rollout restart` on a controller, or delete and recreate a bare Pod.

23. **Field selectors for Pods are a fixed, short list.** Anything outside it returns `field label not supported`. Use label selectors or `jq` for the rest.

24. **`kubectl drain` respects PodDisruptionBudgets and will hang on `ALLOWED DISRUPTIONS: 0`.** `--ignore-daemonsets` is nearly always required.

25. **Events default to about one hour of retention.** `Events: <none>` on an old Pod means the record expired, not that nothing happened.

26. **Wait on `condition=Ready`, never on `phase=Running`.**

---

## Related Topics

- [Pods](pods.md)
- [Pod Lifecycle](pod-lifecycle.md)
- [kubectl](kubectl.md)
- [Imperative Kubernetes](imperative-kubernetes.md)
- [Kubelet](kubelet.md)
- [Kubernetes API](k8s-api.md)
- [kube-apiserver](kube-apiserver.md)
- [Container Runtime](container-runtime.md)
- [Cgroups](cgroups.md)
- [Deployments](deployments.md)
- [ReplicaSets](replicasets.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [Jobs](jobs.md)
- [Controllers](controllers.md)
- [Kubernetes Networking Fundamentals](k8s-networking-fundamentals.md)
- [CoreDNS](coredns.md)

---

## Key Takeaways

1. **`--dry-run=client -o yaml` is the fastest path from an idea to a valid manifest.** Combine it with `kubectl explain` and you rarely need the web docs.
2. **The `STATUS` column is synthesised, not the phase.** Learn the mapping so you know which layer to inspect.
3. **`RESTARTS n (t ago)`** separates a historical incident from an active outage in one glance.
4. **`describe` is read top to bottom**, and the highest value line in it is usually `Last State`, not `State`.
5. **`kubectl logs --previous` is the first command for any `CrashLoopBackOff`**, because the current container is not running.
6. **Logs are ephemeral**: rotated by the kubelet, limited to the current plus one previous instance, and destroyed with the Pod.
7. **`kubectl exec` runs a new process; `kubectl attach` joins PID 1.** Pipes in `exec` execute locally unless wrapped in `sh -c`.
8. **`kubectl debug` is the supported answer for distroless images**, with three distinct modes: ephemeral container, `--copy-to` debug copy, and `node/<name>` node access.
9. **`kubectl cp` depends on `tar` in the container** and is unsuitable for large transfers.
10. **`kubectl port-forward` proves the app listens, nothing more.** It bypasses the entire Service data path.
11. **Choose the patch type deliberately.** Strategic merge for built ins, JSON merge for CRDs and scalars, JSON patch for precise array surgery.
12. **The Pod spec is nearly immutable**, so `set env` and `set resources` target controllers while `set image` also works on a live Pod.
13. **Field selectors filter server side and scale**; `grep` on the client does not.
14. **Work the decision tree**: `Pending` means scheduling or node setup, `ImagePullBackOff` means registry, `CrashLoopBackOff` means the application, `Running 0/1` means readiness, `Terminating` means finalizers or SIGTERM handling, `Evicted` means resource requests.

---

## References

- [kubectl Quick Reference](https://kubernetes.io/docs/reference/kubectl/quick-reference/)
- [kubectl Commands Reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl/)
- [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- [JSONPath Support](https://kubernetes.io/docs/reference/kubectl/jsonpath/)
- [Debug Running Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
- [Debug Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/)
- [Determine the Reason for Pod Failure](https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/)
- [Get a Shell to a Running Container](https://kubernetes.io/docs/tasks/debug/debug-application/get-shell-running-container/)
- [Ephemeral Containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/)
- [Logging Architecture](https://kubernetes.io/docs/concepts/cluster-administration/logging/)
- [Use Port Forwarding to Access Applications in a Cluster](https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/)
- [Resource Metrics Pipeline](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/)
- [Update API Objects in Place Using kubectl patch](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/)
- [Declarative Management of Kubernetes Objects Using Configuration Files](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/)
- [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [Pod API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
