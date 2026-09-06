# 🧿 Pod Security Standards: Baseline, Restricted, and the Admission Controller That Enforces Them

Pod Security Standards are three named policy profiles that define what a Pod may do. Pod Security Admission is the built-in controller that enforces them using nothing more than namespace labels. This document covers the history that led here, every control in every profile with the exact fields checked, the three modes and their version pinning, cluster-wide defaults and exemptions, a safe adoption path from observation to enforcement, and the controller-versus-pod behaviour that confuses everyone the first time.

## 📋 Table of Contents
- [Why PodSecurityPolicy Died](#why-podsecuritypolicy-died)
- [The Two Halves: Standards and Admission](#the-two-halves-standards-and-admission)
- [The Three Profiles](#the-three-profiles)
- [Privileged](#privileged)
- [Baseline Controls](#baseline-controls)
- [Restricted Controls](#restricted-controls)
- [The Three Modes](#the-three-modes)
- [Version Pinning](#version-pinning)
- [Namespace Labels](#namespace-labels)
- [The Controller vs Pod Problem](#the-controller-vs-pod-problem)
- [Cluster Wide Defaults](#cluster-wide-defaults)
- [Exemptions](#exemptions)
- [A Safe Adoption Path](#a-safe-adoption-path)
- [Migrating a Workload to Restricted](#migrating-a-workload-to-restricted)
- [What PSA Cannot Do](#what-psa-cannot-do)
- [Policy Engine Alternatives](#policy-engine-alternatives)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why PodSecurityPolicy Died

PodSecurityPolicy was deprecated in 1.21 and removed entirely in 1.25. Understanding why explains the design of its replacement.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  HOW PSP AUTHORIZATION WORKED                                        │
   │                                                                      │
   │  1. A pod is submitted by some identity.                             │
   │  2. The controller finds EVERY PodSecurityPolicy that identity is    │
   │     authorized to `use` via RBAC.                                    │
   │  3. It sorts them by a heuristic, preferring the one that mutates    │
   │     the pod least.                                                   │
   │  4. It applies that one, possibly MUTATING the pod.                  │
   │  5. If none permit the pod, it is rejected.                          │
   └──────────────────────────────────────────────────────────────────────┘
```

The fatal problems:

**The authorizing identity was usually not the user.** A Deployment's pods are created by the ReplicaSet controller, whose ServiceAccount is `system:serviceaccount:kube-system:replicaset-controller`. So PSP evaluated *that* identity's policies, not the developer's. Getting this right required binding PSPs to controller service accounts in ways that were deeply unintuitive.

**Policy selection was non-deterministic in practice.** With multiple usable PSPs, the ordering heuristic meant a pod could be admitted under a different policy depending on what changed elsewhere. Two identical pods could get different security contexts.

**It mutated.** PSP could rewrite the pod, so the stored object differed from the manifest, silently.

**Enabling it was all or nothing and broke clusters.** Turning PSP on with no policies defined rejected every pod in the cluster, including system components.

The replacement inverts every one of those decisions:

```
   ┌──────────────────┬─────────────────────┬────────────────────────────┐
   │                  │  PodSecurityPolicy  │  Pod Security Admission    │
   ├──────────────────┼─────────────────────┼────────────────────────────┤
   │ Selection        │ RBAC `use` verb     │ Namespace labels           │
   │ Granularity      │ Arbitrary policies  │ Three fixed profiles       │
   │ Mutation         │ Yes                 │ No, validation only        │
   │ Identity used    │ The creating SA     │ Irrelevant, label based    │
   │ Determinism      │ Heuristic ordering  │ Fully deterministic        │
   │ Enable safely    │ Hard                │ audit and warn modes       │
   │ Extensibility    │ Fully custom        │ None, use a policy engine  │
   └──────────────────┴─────────────────────┴────────────────────────────┘
```

The trade is deliberate: PSA is far less flexible, but it is comprehensible, deterministic, and safe to roll out. If you need custom policy, you use a policy engine or `ValidatingAdmissionPolicy` alongside it.

---

## The Two Halves: Standards and Admission

Keep these separate in your head.

```
   ┌────────────────────────────────────────────────────────────────────┐
   │  POD SECURITY STANDARDS                                            │
   │  A specification. Three named profiles with defined controls.      │
   │  Not an API object. Not code. Just an agreed definition.           │
   │  Anyone can implement them: Kyverno, Gatekeeper, a CI linter.      │
   └────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ implemented by
                                   ▼
   ┌────────────────────────────────────────────────────────────────────┐
   │  POD SECURITY ADMISSION (PSA)                                      │
   │  The built-in admission controller, named `PodSecurity`.           │
   │  Enabled by default since 1.25.                                    │
   │  Reads namespace labels, validates pods, rejects or warns.         │
   └────────────────────────────────────────────────────────────────────┘
```

Confirm the controller is active:

```bash
sudo grep -E 'enable-admission-plugins|disable-admission-plugins' \
  /etc/kubernetes/manifests/kube-apiserver.yaml

# PodSecurity is in the default enabled set, so its absence from
# --enable-admission-plugins is normal. What matters is that it is NOT
# in --disable-admission-plugins.
```

---

## The Three Profiles

```
   PRIVILEGED                BASELINE                  RESTRICTED
   ══════════                ════════                  ══════════
   Unrestricted.             Blocks known              Heavily restricted.
   Everything allowed.       privilege escalation.     Current hardening
                             Minimally restrictive.    best practice.

   For: cluster              For: most                 For: security
   infrastructure,           application                critical workloads,
   CNI, CSI, node            workloads, easy            and ideally the
   agents.                   to adopt.                  default everywhere.

   ┌───────────────────────────────────────────────────────────────────┐
   │  Restricted  ⊂  Baseline  ⊂  Privileged                          │
   │                                                                   │
   │  Every pod that satisfies Restricted also satisfies Baseline.     │
   │  The profiles are strictly nested.                                 │
   └───────────────────────────────────────────────────────────────────┘
```

The design intent: **Baseline is what you can adopt without breaking much. Restricted is where you should be heading.**

---

## Privileged

There is nothing to describe. The profile applies no restrictions whatsoever. It exists so that namespaces hosting genuine infrastructure can be labelled explicitly rather than simply having no label at all, which makes intent visible in an audit.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: calico-system
  labels:
    # Explicit, auditable statement that this namespace hosts
    # infrastructure that legitimately requires host access.
    pod-security.kubernetes.io/enforce: privileged
```

---

## Baseline Controls

Baseline blocks the mechanisms that lead to trivial container escape or host compromise, while remaining compatible with the vast majority of off-the-shelf applications.

### Host Namespaces

Sharing a host namespace defeats the isolation container security depends on.

| Field | Allowed values |
|---|---|
| `spec.hostNetwork` | `false` or unset |
| `spec.hostPID` | `false` or unset |
| `spec.hostIPC` | `false` or unset |

```yaml
# Rejected under Baseline
spec:
  hostNetwork: true      # sees all host interfaces, bypasses NetworkPolicy
  hostPID: true          # sees every host process in /proc
  hostIPC: true          # reads host shared memory
```

### Privileged Containers

| Field | Allowed values |
|---|---|
| `spec.containers[*].securityContext.privileged` | `false` or unset |
| `spec.initContainers[*].securityContext.privileged` | `false` or unset |
| `spec.ephemeralContainers[*].securityContext.privileged` | `false` or unset |

### Capabilities

Baseline permits the runtime default set, and allows dropping. It restricts what may be **added**.

| Field | Allowed values |
|---|---|
| `securityContext.capabilities.add` | Only from the list below |

```
   ADDABLE UNDER BASELINE
   ──────────────────────
   AUDIT_WRITE       CHOWN             DAC_OVERRIDE
   FOWNER            FSETID            KILL
   MKNOD             NET_BIND_SERVICE  SETFCAP
   SETGID            SETPCAP           SETUID
   SYS_CHROOT
```

Anything else, notably `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, `SYS_MODULE`, `DAC_READ_SEARCH` and `SYS_TIME`, is rejected.

### HostPath Volumes

| Field | Allowed values |
|---|---|
| `spec.volumes[*].hostPath` | Must be undefined |

A `hostPath` mount is a direct route out of the container. Mounting `/` , `/etc/kubernetes`, `/var/lib/kubelet` or the container runtime socket is game over.

```yaml
# Rejected under Baseline
volumes:
  - name: escape
    hostPath:
      path: /
```

### Host Ports

| Field | Allowed values |
|---|---|
| `spec.containers[*].ports[*].hostPort` | `0` or undefined |

Binding a host port lets a pod occupy a node-level port and potentially intercept traffic intended for a node service. Some implementations allow a configured range; the default is to forbid entirely.

### AppArmor

| Field | Allowed values |
|---|---|
| `securityContext.appArmorProfile.type` | `RuntimeDefault`, `Localhost`, or unset |

`Unconfined` is rejected. On systems without AppArmor this control is a no-op.

### SELinux

| Field | Allowed values |
|---|---|
| `seLinuxOptions.type` | unset, `container_t`, `container_init_t`, `container_kvm_t`, `container_engine_t` |
| `seLinuxOptions.user` | Must be unset |
| `seLinuxOptions.role` | Must be unset |

Setting `user` or `role` allows escaping the container SELinux domain. The `level` (MCS category) field is unrestricted, since it only narrows access.

### /proc Mount Type

| Field | Allowed values |
|---|---|
| `securityContext.procMount` | `Default` or unset |

`Unmasked` exposes `/proc/kcore`, `/proc/sysrq-trigger` and other host-affecting paths.

### Seccomp

| Field | Allowed values |
|---|---|
| `securityContext.seccompProfile.type` | Anything **except** `Unconfined` when explicitly set |

Baseline does not *require* a seccomp profile. It only forbids explicitly setting `Unconfined`. Leaving it unset is permitted, which is why `seccompDefault: true` on the kubelet is a worthwhile complement.

### Sysctls

| Field | Allowed values |
|---|---|
| `spec.securityContext.sysctls[*].name` | Only the safe, namespaced list |

```
   PERMITTED SYSCTLS UNDER BASELINE
   ────────────────────────────────
   kernel.shm_rmid_forced
   net.ipv4.ip_local_port_range
   net.ipv4.ip_unprivileged_port_start
   net.ipv4.tcp_syncookies
   net.ipv4.ping_group_range
   net.ipv4.ip_local_reserved_ports
   net.ipv4.tcp_keepalive_time
   net.ipv4.tcp_fin_timeout
   net.ipv4.tcp_keepalive_intvl
   net.ipv4.tcp_keepalive_probes
```

### Windows HostProcess

| Field | Allowed values |
|---|---|
| `securityContext.windowsOptions.hostProcess` | `false` or unset |

---

## Restricted Controls

Restricted includes **every Baseline control** and adds the following. This is where most migration work happens.

### Volume Types

Restricted permits only volume types that cannot reference host state.

```
   PERMITTED VOLUME TYPES UNDER RESTRICTED
   ───────────────────────────────────────
   configMap              downwardAPI            emptyDir
   projected              secret                 ephemeral
   persistentVolumeClaim  csi                    image
```

Everything else is rejected, which notably includes `hostPath`, `nfs` (mount it through a PVC and a CSI driver instead), `gitRepo`, `iscsi` and the legacy in-tree cloud volume types.

### Privilege Escalation

| Field | Required value |
|---|---|
| `securityContext.allowPrivilegeEscalation` | **must be explicitly `false`** |

This is the control that catches almost everyone. Omitting the field is a violation. It must be present and false, on every container, init container and ephemeral container.

```yaml
# Violation: field absent
securityContext:
  runAsNonRoot: true

# Compliant
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
```

### Running as Non-Root

| Field | Required value |
|---|---|
| `securityContext.runAsNonRoot` | **must be `true`** at pod or container level |
| `securityContext.runAsUser` | must not be `0` if set |

Setting it at pod level covers all containers. A container that overrides it to `false` is a violation.

### Capabilities

| Field | Required value |
|---|---|
| `securityContext.capabilities.drop` | **must include `ALL`** |
| `securityContext.capabilities.add` | at most `NET_BIND_SERVICE` |

```yaml
# The only compliant shapes
capabilities:
  drop: ["ALL"]

capabilities:
  drop: ["ALL"]
  add: ["NET_BIND_SERVICE"]
```

Note `drop: ["ALL"]` must be present even if you add nothing. `drop: ["NET_RAW", "SYS_ADMIN"]` is a violation because it does not include `ALL`.

### Seccomp

| Field | Required value |
|---|---|
| `securityContext.seccompProfile.type` | **must be `RuntimeDefault` or `Localhost`** |

Unlike Baseline, unset is a violation here. It must be explicitly set at pod level or on every container.

### Summary Table

| Control | Baseline | Restricted |
|---|---|---|
| Host namespaces | forbidden | forbidden |
| Privileged containers | forbidden | forbidden |
| hostPath volumes | forbidden | forbidden |
| Host ports | forbidden | forbidden |
| Dangerous capabilities | forbidden | forbidden |
| Unsafe sysctls | forbidden | forbidden |
| `procMount: Unconfined` | forbidden | forbidden |
| AppArmor `Unconfined` | forbidden | forbidden |
| SELinux user/role | forbidden | forbidden |
| **Volume types** | any | restricted allowlist |
| **`allowPrivilegeEscalation`** | any | must be `false` |
| **`runAsNonRoot`** | any | must be `true` |
| **`capabilities.drop`** | any | must include `ALL` |
| **`seccompProfile`** | not `Unconfined` if set | must be set to `RuntimeDefault`/`Localhost` |

---

## The Three Modes

Each namespace can carry all three modes simultaneously, each at a different profile level.

```
   ┌──────────┬──────────────────────────────────────────────────────────┐
   │  MODE    │  BEHAVIOUR ON VIOLATION                                  │
   ├──────────┼──────────────────────────────────────────────────────────┤
   │ enforce  │  Reject the Pod. Applies to PODS ONLY, not to            │
   │          │  Deployments, StatefulSets, Jobs or other controllers.   │
   ├──────────┼──────────────────────────────────────────────────────────┤
   │ audit    │  Allow the request. Add an annotation to the audit log   │
   │          │  event. Applies to pods and controller objects.          │
   ├──────────┼──────────────────────────────────────────────────────────┤
   │ warn     │  Allow the request. Return a warning to the client,      │
   │          │  visible in kubectl output. Applies to pods AND          │
   │          │  controller objects. This is the crucial one.            │
   └──────────┴──────────────────────────────────────────────────────────┘
```

The recommended production configuration sets `enforce` one level below `audit` and `warn`, so you get enforcement at the level you have achieved while continuously seeing how far you are from the next level.

```yaml
labels:
  pod-security.kubernetes.io/enforce: baseline      # what is enforced today
  pod-security.kubernetes.io/audit: restricted      # what you are aiming at
  pod-security.kubernetes.io/warn: restricted       # tell users about the gap
```

---

## Version Pinning

Each mode may be pinned to a Kubernetes minor version.

```yaml
labels:
  pod-security.kubernetes.io/enforce: restricted
  pod-security.kubernetes.io/enforce-version: v1.31
```

Why this exists: the definition of a profile can gain new controls in later releases. Without pinning, upgrading your cluster silently tightens policy and can reject workloads that were fine yesterday.

| Value | Meaning |
|---|---|
| `v1.31` (a specific version) | Evaluate against that release's definition. **Use this in production.** |
| `latest` | Always use the running version's definition. Convenient, but an upgrade can break workloads. |
| unset | Defaults to `latest`. |

The pattern that gives you both safety and visibility:

```yaml
labels:
  # Enforcement pinned. An upgrade cannot suddenly reject workloads.
  pod-security.kubernetes.io/enforce: restricted
  pod-security.kubernetes.io/enforce-version: v1.31
  # Warnings track the newest definition, so you see what a future
  # pin bump would require.
  pod-security.kubernetes.io/warn: restricted
  pod-security.kubernetes.io/warn-version: latest
```

---

## Namespace Labels

The complete label set. Nine labels, three per mode.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    # ── ENFORCE: reject violating Pods ────────────────────────────────
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.31

    # ── AUDIT: record violations in the audit log ─────────────────────
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.31

    # ── WARN: return a client warning, including for controllers ──────
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.31
```

Applying them imperatively:

```bash
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.31 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=v1.31 \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=v1.31 \
  --overwrite
```

Reading them back:

```bash
kubectl get ns -o custom-columns=\
'NAME:.metadata.name,'\
'ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce,'\
'WARN:.metadata.labels.pod-security\.kubernetes\.io/warn,'\
'AUDIT:.metadata.labels.pod-security\.kubernetes\.io/audit'
```

A useful property: **applying an enforce label is itself validated**. If you label an existing namespace with `enforce: restricted` and pods already running there would violate it, the API server returns warnings listing them. It does not evict them, but it tells you what will break on the next restart.

```bash
kubectl label ns dev pod-security.kubernetes.io/enforce=restricted
# Warning: existing pods in namespace "dev" violate the new PodSecurity
# enforce level "restricted:latest"
# Warning: web-7d9f8c-abcde: allowPrivilegeEscalation != false,
#   unrestricted capabilities, runAsNonRoot != true, seccompProfile
```

---

## The Controller vs Pod Problem

This single behaviour generates more confusion than anything else in PSA.

```
   ┌───────────────────────────────────────────────────────────────────────┐
   │  You apply a Deployment whose pod template violates the profile.      │
   │                                                                       │
   │  1. kubectl apply -f deploy.yaml                                      │
   │        │                                                              │
   │        ▼                                                              │
   │  2. API server: is this a POD?  No, it is a Deployment.               │
   │        enforce  ──► DOES NOT APPLY. Deployment is CREATED.            │
   │        warn     ──► applies, returns a Warning header                 │
   │        audit    ──► applies, annotates the audit event                │
   │        │                                                              │
   │        ▼                                                              │
   │  3. Deployment controller creates a ReplicaSet.  Succeeds.            │
   │        │                                                              │
   │        ▼                                                              │
   │  4. ReplicaSet controller creates a POD.                              │
   │        enforce  ──► APPLIES. Pod REJECTED.                            │
   │        │                                                              │
   │        ▼                                                              │
   │  5. Result: a Deployment showing 0/3 ready, forever, with no          │
   │     error anywhere on the Deployment object itself.                   │
   └───────────────────────────────────────────────────────────────────────┘
```

What you see:

```bash
kubectl get deploy web
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    0/3     3            0           2m

kubectl describe deploy web
# ...nothing useful. The Deployment is perfectly healthy from its own
# point of view: it created a ReplicaSet as instructed.
```

Where the truth actually is:

```bash
kubectl describe rs -l app=web | tail -20
# Events:
#   Warning  FailedCreate  ...  Error creating: pods "web-7d9f8c-" is
#   forbidden: violates PodSecurity "restricted:v1.31":
#   allowPrivilegeEscalation != false (container "app" must set
#   securityContext.allowPrivilegeEscalation=false), ...
```

Or in events:

```bash
kubectl get events --field-selector reason=FailedCreate -n production
```

### Why It Was Designed This Way

`enforce` deliberately does not evaluate controller objects because PSA cannot reliably know which field path in an arbitrary object is a pod template. Custom resources from operators embed pod templates in arbitrary places. Restricting enforcement to actual Pod objects makes the controller correct for every workload type, present and future, at the cost of this indirection.

### The Fix

`warn` **does** evaluate controller objects, using a best-effort pod template extraction. So the answer is simply: **always set `warn` whenever you set `enforce`.**

```yaml
labels:
  pod-security.kubernetes.io/enforce: restricted
  pod-security.kubernetes.io/warn: restricted     # never omit this
```

Then the failure surfaces at apply time, where the human is:

```bash
kubectl apply -f deploy.yaml
# Warning: would violate PodSecurity "restricted:v1.31":
# allowPrivilegeEscalation != false (container "app" must set
# securityContext.allowPrivilegeEscalation=false), unrestricted
# capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
# runAsNonRoot != true, seccompProfile (pod or container "app" must set
# securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
# deployment.apps/web created
```

That message is a complete remediation checklist. Read it carefully; it names every violated control and the exact field to set.

---

## Cluster Wide Defaults

Without configuration, a namespace with **no PSA labels gets no enforcement at all**. On a large cluster, that means every namespace anyone creates is unprotected by default. `AdmissionConfiguration` fixes that.

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration

      # Applied to any namespace that does not carry the corresponding label.
      # A namespace label always overrides these.
      defaults:
        enforce: "baseline"
        enforce-version: "v1.31"
        audit: "restricted"
        audit-version: "v1.31"
        warn: "restricted"
        warn-version: "v1.31"

      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces:
          - kube-system
```

Wire it into the API server. Both the flag and the volume mount are required; the flag alone silently does nothing because the file will not exist inside the pod.

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml
spec:
  containers:
    - name: kube-apiserver
      command:
        - kube-apiserver
        - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
        # ...
      volumeMounts:
        - name: admission-config
          mountPath: /etc/kubernetes/admission
          readOnly: true
  volumes:
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission
        type: DirectoryOrCreate
```

On an HA control plane the file must be identical on **every** control plane node, or policy depends on which API server your request happens to reach.

Verify it took effect:

```bash
# Create a namespace with no labels at all
kubectl create ns psa-default-test

# Try a privileged pod. Under defaults enforce: baseline, it should be rejected.
kubectl -n psa-default-test run bad --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"bad","image":"busybox",
  "securityContext":{"privileged":true}}]}}' -- sleep 60
# Error from server (Forbidden): ... violates PodSecurity "baseline:v1.31"

kubectl delete ns psa-default-test
```

---

## Exemptions

Exemptions bypass PSA entirely for matching requests, in **all three modes**. An exempt request is not enforced, not warned about, and not audited.

```yaml
exemptions:
  # Requests from these usernames bypass PSA completely.
  # Use sparingly. A compromised credential here has no pod-level policy.
  usernames:
    - "system:serviceaccount:kube-system:cluster-installer"

  # Pods using these RuntimeClasses bypass PSA, on the theory that
  # a sandboxed runtime provides isolation by other means.
  runtimeClasses:
    - "gvisor"
    - "kata-containers"

  # Namespaces that bypass PSA entirely.
  namespaces:
    - kube-system
```

### The kube-system Question

`kube-system` genuinely needs privileged pods: `kube-proxy` manipulating iptables, CNI DaemonSets configuring host networking, CSI node plugins mounting volumes.

Two approaches:

```yaml
# Option A: exempt it in AdmissionConfiguration.
exemptions:
  namespaces: ["kube-system"]
```

```bash
# Option B: label it privileged. Preferable, because the intent is
# visible on the namespace object itself, and audit/warn still function.
kubectl label ns kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite
```

Option B is better practice. An exemption is invisible unless you read the API server's admission config; a label shows up in `kubectl get ns --show-labels` and in any GitOps diff.

Whichever you choose, do the same for your CNI and CSI namespaces:

```bash
for ns in kube-system calico-system tigera-operator metallb-system; do
  kubectl label ns "$ns" \
    pod-security.kubernetes.io/enforce=privileged \
    --overwrite 2>/dev/null
done
```

---

## A Safe Adoption Path

Never start with `enforce`. The mode design exists precisely to make this a graduated, low-risk process.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  STAGE 1  OBSERVE                                                    │
   │    audit: restricted                                                 │
   │    warn:  restricted                                                 │
   │    enforce: (unset)                                                  │
   │    Nothing is rejected. Collect data. Duration: weeks.               │
   ├──────────────────────────────────────────────────────────────────────┤
   │  STAGE 2  ENFORCE BASELINE                                           │
   │    enforce: baseline                                                 │
   │    audit/warn: restricted                                            │
   │    Blocks the genuinely dangerous. Most apps unaffected.             │
   ├──────────────────────────────────────────────────────────────────────┤
   │  STAGE 3  REMEDIATE                                                  │
   │    Work the warning list. Fix manifests. Rebuild images that         │
   │    cannot run non-root.                                              │
   ├──────────────────────────────────────────────────────────────────────┤
   │  STAGE 4  ENFORCE RESTRICTED                                         │
   │    enforce: restricted, pinned to a version                          │
   │    Roll out namespace by namespace, lowest risk first.               │
   └──────────────────────────────────────────────────────────────────────┘
```

### Stage 1 in Practice

```bash
# Apply observation labels to every non-system namespace.
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in
    kube-system|kube-public|kube-node-lease|calico-system|tigera-operator|metallb-system)
      continue ;;
  esac
  kubectl label ns "$ns" \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/audit-version=v1.31 \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=v1.31 \
    --overwrite
done
```

Then measure. Because `audit` writes annotations onto audit events, the audit log is your dataset. See [audit-logging.md](audit-logging.md).

```bash
# Which namespaces and pods are violating, and which controls?
sudo jq -r 'select(.annotations["pod-security.kubernetes.io/audit-violations"])
  | [ .objectRef.namespace,
      .objectRef.name,
      .annotations["pod-security.kubernetes.io/audit-violations"] ]
  | @tsv' /var/log/kubernetes/audit.log | sort -u
```

If audit logging is not yet enabled, an offline scan works too:

```bash
# Approximate the same analysis directly from the live pod inventory.
kubectl get pods -A -o json | jq -r '
  .items[]
  | . as $p
  | ($p.spec.securityContext // {}) as $psc
  | .spec.containers[]
  | (.securityContext // {}) as $csc
  | select(
      ($csc.allowPrivilegeEscalation != false)
      or (($csc.capabilities.drop // []) | index("ALL") | not)
      or (($psc.runAsNonRoot // $csc.runAsNonRoot // false) != true)
      or (($psc.seccompProfile.type // $csc.seccompProfile.type // "") == "")
    )
  | "\($p.metadata.namespace)/\($p.metadata.name)  container=\(.name)"' \
  | sort | uniq -c | sort -rn | head -40
```

### Stage 4 Rollout Order

Enforce in this order, verifying between each:

1. New namespaces (nothing to break).
2. Development namespaces.
3. Staging.
4. Production, one application at a time.

```bash
# Before flipping enforce, ask PSA directly what will break.
kubectl label ns staging \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.31 \
  --dry-run=server --overwrite
# Warnings list every currently running pod that violates.
```

`--dry-run=server` on the label command is the single most useful safety check in this entire process. It tells you the blast radius without changing anything.

---

## Migrating a Workload to Restricted

A worked example. Start with a typical, entirely non-compliant Deployment.

```yaml
# BEFORE: violates almost every Restricted control
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
```

Applying it under `warn: restricted` produces the remediation list:

```
Warning: would violate PodSecurity "restricted:v1.31":
  allowPrivilegeEscalation != false (container "nginx" must set
    securityContext.allowPrivilegeEscalation=false),
  unrestricted capabilities (container "nginx" must set
    securityContext.capabilities.drop=["ALL"]),
  runAsNonRoot != true (pod or container "nginx" must set
    securityContext.runAsNonRoot=true),
  seccompProfile (pod or container "nginx" must set
    securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Four controls. Address them one at a time.

### Fix 1 and 2: seccomp and capabilities

Cheap and almost never break anything.

```yaml
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: nginx:1.27
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
```

### Fix 3: runAsNonRoot

This is where the official `nginx` image fights back. It starts as root to bind port 80 and to write its pidfile, then drops to the `nginx` user. Setting `runAsNonRoot: true` breaks it.

Two options.

**Option A: use the unprivileged variant.** The nginx project publishes `nginxinc/nginx-unprivileged`, which listens on 8080 and runs as UID 101 by default.

```yaml
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27
          ports:
            - containerPort: 8080
```

**Option B: keep the image and supply the configuration.** Point nginx at a high port and a writable pidfile.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-conf
  namespace: production
data:
  nginx.conf: |
    # Writable location, since / is read-only.
    pid /tmp/nginx.pid;
    error_log /dev/stderr warn;
    events { worker_connections 1024; }
    http {
      # Every temp path must be writable.
      client_body_temp_path /tmp/client_body;
      proxy_temp_path       /tmp/proxy;
      fastcgi_temp_path     /tmp/fastcgi;
      uwsgi_temp_path       /tmp/uwsgi;
      scgi_temp_path        /tmp/scgi;
      access_log /dev/stdout;
      server {
        # Above 1024, so no NET_BIND_SERVICE needed at all.
        listen 8080;
        location / { root /usr/share/nginx/html; index index.html; }
      }
    }
```

### The Compliant Result

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      # ── Pod level ────────────────────────────────────────────────
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault

      # Not required by Restricted, but good hygiene: this workload
      # does not call the Kubernetes API.
      automountServiceAccountToken: false

      containers:
        - name: nginx
          image: nginx:1.27
          # ── Container level ──────────────────────────────────────
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true     # not required, but do it
            capabilities:
              drop: ["ALL"]
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/nginx

      volumes:
        - name: conf
          configMap:
            name: nginx-conf
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
        - name: cache
          emptyDir:
            sizeLimit: 128Mi
```

Verify before applying for real:

```bash
kubectl apply -f web.yaml --dry-run=server
# No warnings means compliant.
```

---

## What PSA Cannot Do

PSA is deliberately narrow. It handles pod-level security context and nothing else. These are all outside its scope:

```
   ✗ Which container registries are permitted
   ✗ Whether resource requests and limits are present
   ✗ Required labels or annotations
   ✗ Which StorageClasses may be used
   ✗ Ingress hostname collisions
   ✗ Naming conventions
   ✗ Replica count minimums
   ✗ Image tag policy (no :latest)
   ✗ Any custom resource
   ✗ Anything requiring comparison of old and new object state
   ✗ Any policy not expressible as one of the three fixed profiles
```

For anything on that list, reach for `ValidatingAdmissionPolicy` (built in, CEL based, no extra components) or a policy engine. See [admission-controllers.md](admission-controllers.md).

---

## Policy Engine Alternatives

| | Pod Security Admission | ValidatingAdmissionPolicy | Kyverno | OPA Gatekeeper |
|---|---|---|---|---|
| Built in | ✅ | ✅ | ❌ | ❌ |
| Extra components to run | none | none | controller | controller |
| Policy language | none, fixed profiles | CEL | YAML | Rego |
| Can mutate | ❌ | not yet GA | ✅ | ✅ |
| Can generate objects | ❌ | ❌ | ✅ | ❌ |
| Custom resources | ❌ | ✅ | ✅ | ✅ |
| Compares old/new object | ❌ | ✅ | ✅ | ✅ |
| Image verification | ❌ | ❌ | ✅ | limited |
| Scans existing objects | ❌ | ❌ | ✅ | ✅ |
| Learning curve | trivial | moderate | low | high |
| Can be "down" | ❌ | ❌ | ✅ | ✅ |

A sensible layering for most clusters:

```
   1. Pod Security Admission          ── pod security context baseline
   2. ValidatingAdmissionPolicy       ── registry allowlists, required
                                          labels, resource limits, no :latest
   3. A policy engine, only if you    ── mutation, generation, image
      genuinely need mutation or         signature verification
      generation
```

Kyverno can also enforce the Pod Security Standards directly, with the advantage that it can report on **existing** objects rather than only gating new ones:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: psa-restricted
spec:
  validationFailureAction: Audit
  background: true          # evaluate objects already in the cluster
  rules:
    - name: restricted
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        podSecurity:
          level: restricted
          version: v1.31
          exclude:
            - controlName: "Capabilities"
              images: ["registry.internal.example.com/legacy/*"]
```

That `exclude` block is something PSA cannot express: a per-image, per-control exception. It is the usual reason teams add Kyverno alongside PSA rather than instead of it.

---

## Recipes

### Recipe: Cluster Wide Compliance Report

```bash
#!/usr/bin/env bash
# Report each namespace's PSA labels and its current violation count.
printf '%-28s %-12s %-12s %s\n' NAMESPACE ENFORCE WARN VIOLATING_PODS
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  enf=$(kubectl get ns "$ns" -o jsonpath\
='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
  wrn=$(kubectl get ns "$ns" -o jsonpath\
='{.metadata.labels.pod-security\.kubernetes\.io/warn}')
  bad=$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq '[
    .items[] | . as $p | ($p.spec.securityContext // {}) as $psc
    | .spec.containers[] | (.securityContext // {}) as $csc
    | select(
        ($csc.allowPrivilegeEscalation != false)
        or (($csc.capabilities.drop // []) | index("ALL") | not)
        or (($psc.runAsNonRoot // $csc.runAsNonRoot // false) != true)
        or (($psc.seccompProfile.type // $csc.seccompProfile.type // "") == "")
      )] | length')
  printf '%-28s %-12s %-12s %s\n' "$ns" "${enf:--}" "${wrn:--}" "$bad"
done
```

### Recipe: Test a Namespace Against a Profile Without Changing It

```bash
# Server-side dry run on the label change reports every currently
# running pod that would violate, without applying anything.
kubectl label ns production \
  pod-security.kubernetes.io/enforce=restricted \
  --dry-run=server --overwrite
```

### Recipe: Enforce PSA Labels on Every New Namespace

PSA cannot require its own labels. Use a CEL policy to close the gap.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-psa-labels
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["namespaces"]
  validations:
    - expression: >-
        has(object.metadata.labels) &&
        'pod-security.kubernetes.io/enforce' in object.metadata.labels
      message: >-
        every namespace must declare pod-security.kubernetes.io/enforce
      reason: Invalid
    - expression: >-
        !has(object.metadata.labels) ||
        !('pod-security.kubernetes.io/enforce' in object.metadata.labels) ||
        object.metadata.labels['pod-security.kubernetes.io/enforce'] in
          ['baseline', 'restricted']
      message: >-
        enforce must be baseline or restricted; privileged namespaces
        require a documented exception
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-psa-labels-binding
spec:
  policyName: require-psa-labels
  validationActions: ["Deny"]
```

### Recipe: Find Every Privileged Namespace

The list of exceptions you should be able to justify.

```bash
kubectl get ns -o json | jq -r '
  .items[]
  | select((.metadata.labels["pod-security.kubernetes.io/enforce"] // "none")
           != "restricted")
  | "\(.metadata.name)\t\(.metadata.labels["pod-security.kubernetes.io/enforce"] // "NO LABEL")"' \
  | column -t
```

---

## Command Reference

```bash
# ---------- Read labels ----------
kubectl get ns --show-labels
kubectl get ns NAME -o jsonpath='{.metadata.labels}' | jq
kubectl get ns -o custom-columns=\
'NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'

# ---------- Set labels ----------
kubectl label ns NAME pod-security.kubernetes.io/enforce=baseline --overwrite
kubectl label ns NAME pod-security.kubernetes.io/enforce-version=v1.31 --overwrite
kubectl label ns NAME pod-security.kubernetes.io/warn=restricted --overwrite
kubectl label ns NAME pod-security.kubernetes.io/audit=restricted --overwrite

# ---------- Remove a label ----------
kubectl label ns NAME pod-security.kubernetes.io/enforce-

# ---------- Test without applying ----------
kubectl label ns NAME pod-security.kubernetes.io/enforce=restricted \
  --dry-run=server --overwrite
kubectl apply -f workload.yaml --dry-run=server

# ---------- Find the real error behind a stuck Deployment ----------
kubectl describe rs -l app=NAME
kubectl get events --field-selector reason=FailedCreate -n NAMESPACE
kubectl get events -n NAMESPACE --sort-by=.lastTimestamp | tail -20

# ---------- Controller configuration ----------
sudo grep -E 'admission-control-config-file|admission-plugins' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
sudo cat /etc/kubernetes/admission/admission-config.yaml

# ---------- Audit violations ----------
sudo jq -r 'select(.annotations["pod-security.kubernetes.io/audit-violations"])
  | [.objectRef.namespace, .objectRef.name,
     .annotations["pod-security.kubernetes.io/audit-violations"]] | @tsv' \
  /var/log/kubernetes/audit.log
```

---

## Troubleshooting

### Deployment Shows 0 Ready and Describes Cleanly

The controller-versus-pod behaviour. Look at the ReplicaSet.

```bash
kubectl describe rs -l app=web | tail -20
kubectl get events --field-selector reason=FailedCreate -n NAMESPACE
```

Then set `warn` on the namespace so this surfaces at apply time in future.

### The Violation Message, Decoded

```
Error from server (Forbidden): pods "web" is forbidden:
violates PodSecurity "restricted:v1.31":
  allowPrivilegeEscalation != false (container "nginx" must set
    securityContext.allowPrivilegeEscalation=false)
      │                    │
      │                    └── the exact field to set
      └── the control that failed
```

Each clause is independent and names the container and the field. Fix every clause; the message lists all failures at once rather than one at a time.

### A Label Was Applied But Nothing Is Enforced

```bash
# 1. Is the label spelled correctly? The prefix is exact.
kubectl get ns NAME -o jsonpath='{.metadata.labels}' | jq
#    Correct:   pod-security.kubernetes.io/enforce
#    Wrong:     pod-security.k8s.io/enforce
#               podsecurity.kubernetes.io/enforce

# 2. Is the value valid? Only privileged, baseline, restricted.
#    An invalid value is rejected at label time, so if the label
#    applied, the value is valid.

# 3. Is the PodSecurity plugin disabled?
sudo grep disable-admission-plugins /etc/kubernetes/manifests/kube-apiserver.yaml

# 4. Is the namespace exempt in AdmissionConfiguration?
sudo cat /etc/kubernetes/admission/admission-config.yaml
```

### Existing Pods Still Running After Enforcing

Correct and expected. Admission gates writes; it never scans existing objects. Violating pods run until something recreates them.

```bash
# Force a re-evaluation by restarting the workload.
kubectl rollout restart deployment/web -n production

# Or find what would break on the next restart, without restarting.
kubectl label ns production \
  pod-security.kubernetes.io/enforce=restricted \
  --dry-run=server --overwrite
```

If you need to find and remediate existing violations, that is a job for Kyverno's background scanning or the reporting recipe above. PSA will not do it.

### A System Component Broke After Enabling Defaults

CNI, CSI and monitoring agents legitimately need host access.

```bash
# Label their namespaces privileged.
for ns in kube-system calico-system tigera-operator metallb-system \
          monitoring csi-driver-nfs; do
  kubectl label ns "$ns" \
    pod-security.kubernetes.io/enforce=privileged --overwrite 2>/dev/null
done
```

Prefer the label to an `exemptions.namespaces` entry, because the label is visible in the cluster state and in GitOps diffs.

### Upgrading the Cluster Broke Previously Compliant Pods

You did not pin the version, so `latest` picked up a control added in the new release.

```bash
# Pin every namespace to the version you validated against.
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  kubectl label ns "$ns" \
    pod-security.kubernetes.io/enforce-version=v1.31 --overwrite
done
```

Then bump the pin deliberately, with `warn-version: latest` giving you advance notice of what the next bump will require.

### `hostPath` Is Genuinely Required

Node-level agents sometimes really do need it. The honest answer is a dedicated namespace labelled `privileged`, with tight RBAC on who may deploy into it, rather than weakening policy cluster wide.

```bash
kubectl create ns node-agents
kubectl label ns node-agents pod-security.kubernetes.io/enforce=privileged
kubectl label ns node-agents pod-security.kubernetes.io/audit=restricted
kubectl label ns node-agents pod-security.kubernetes.io/warn=restricted
```

Keeping `audit` and `warn` at `restricted` means you still get a continuous record of exactly how far outside policy those workloads sit.

---

## Exam and Interview Traps

1. **What replaced PodSecurityPolicy?** Pod Security Admission, enforcing the Pod Security Standards via namespace labels. PSP was removed in 1.25.

2. **How is a profile selected?** By namespace label. Not by RBAC, not by the creating identity, not by any policy object.

3. **Name the three profiles.** Privileged, Baseline, Restricted. They are strictly nested.

4. **Name the three modes.** `enforce`, `audit`, `warn`.

5. **Which modes evaluate Deployments?** `audit` and `warn`. `enforce` only evaluates Pod objects, which is why a Deployment can be created and then produce zero pods.

6. **A Deployment applied cleanly but has no pods. Why?** `enforce` rejected the Pods. Look at the ReplicaSet events, not the Deployment.

7. **Does PSA mutate pods?** No. It is validation only. That is a deliberate difference from PSP.

8. **What are the four Restricted requirements beyond Baseline that people forget?** `allowPrivilegeEscalation: false` explicitly, `runAsNonRoot: true`, `capabilities.drop: ["ALL"]`, and `seccompProfile.type` set to `RuntimeDefault` or `Localhost`.

9. **Is `drop: ["NET_RAW"]` sufficient for Restricted?** No. The drop list must include `ALL`.

10. **Is omitting `allowPrivilegeEscalation` acceptable under Restricted?** No. It must be explicitly `false`.

11. **Does Restricted require `readOnlyRootFilesystem`?** No. Recommended, not required.

12. **What happens to a namespace with no PSA labels?** No enforcement, unless `AdmissionConfiguration` sets cluster-wide defaults.

13. **Why pin the version?** A profile definition can gain controls in a later release. `latest` means a cluster upgrade can silently reject workloads that were previously fine.

14. **Which capability may Restricted add back?** Only `NET_BIND_SERVICE`.

15. **Does enabling `enforce: restricted` evict running privileged pods?** No. Admission only gates writes. They run until recreated.

16. **How do you find out what will break before enforcing?** `kubectl label ns NAME pod-security.kubernetes.io/enforce=restricted --dry-run=server`. It lists every currently running violating pod.

17. **Can PSA block images from an untrusted registry?** No. That is outside its scope. Use `ValidatingAdmissionPolicy` or a policy engine.

18. **Which volume types does Restricted permit?** `configMap`, `downwardAPI`, `emptyDir`, `projected`, `secret`, `ephemeral`, `persistentVolumeClaim`, `csi`, `image`. Notably not `hostPath` or `nfs`.

---

## Related Topics

- [security-context.md](security-context.md) for every field these profiles check
- [admission-controllers.md](admission-controllers.md) for the PodSecurity controller in the wider pipeline
- [admission-webhooks.md](admission-webhooks.md) for policy beyond what PSA expresses
- [cluster-hardening.md](cluster-hardening.md) for where this sits in overall posture
- [rbac.md](rbac.md) for controlling who may change namespace labels
- [pods.md](pods.md) for the pod spec being validated
- [volumes.md](volumes.md) for the volume types Restricted permits
- [runtime-class.md](runtime-class.md) for RuntimeClass based exemptions
- [audit-logging.md](audit-logging.md) for consuming audit-mode violations
- [namespaces](k8s-api.md) for the object carrying the labels

---

## Key Takeaways

- Pod Security Standards are the specification (three profiles); Pod Security Admission is the built-in controller that enforces them.
- Selection is by namespace label, deterministic and visible, unlike PSP's RBAC-driven heuristic.
- Restricted is a strict superset of Baseline, which is a strict subset of Privileged. The profiles nest.
- `enforce` applies to Pods only. `warn` and `audit` also apply to Deployments and other controllers. **Always set `warn` alongside `enforce`.**
- The four Restricted-only requirements are `allowPrivilegeEscalation: false` explicitly, `runAsNonRoot: true`, `capabilities.drop: ["ALL"]`, and an explicit `seccompProfile`.
- PSA never mutates. It only validates.
- A namespace with no labels gets no enforcement, unless you configure cluster-wide defaults in `AdmissionConfiguration`.
- Pin `enforce-version` in production so a cluster upgrade cannot tighten policy silently.
- Admission gates writes only. Enabling a profile never touches pods already running.
- `kubectl label ... --dry-run=server` reports the exact blast radius before you enforce anything.
- PSA is deliberately narrow. Registry allowlists, resource limits, required labels and image tag policy all need `ValidatingAdmissionPolicy` or a policy engine.

---

## References

- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Enforce Pod Security Standards with Namespace Labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)
- [Enforce Pod Security Standards by Configuring the Built-in Admission Controller](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/)
- [Migrate from PodSecurityPolicy to the Built-In PodSecurity Admission Controller](https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/)
- [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
