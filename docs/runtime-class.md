# 📦 RuntimeClass: Choosing Stronger Isolation Than a Shared Kernel

Every container on a node shares one kernel. That is the whole efficiency argument for containers, and it is also the entire attack surface: a single kernel vulnerability exploited from inside a container reaches everything else on the machine. RuntimeClass is the Kubernetes API for saying "this pod runs under a different, stronger isolation mechanism". This document covers the shared-kernel threat model, the RuntimeClass object in full, wiring handlers into containerd, gVisor and Kata Containers in practice, the honest performance and compatibility trade-offs, and how to run mixed runtimes safely on one cluster.

## 📋 Table of Contents
- [The Shared Kernel Problem](#the-shared-kernel-problem)
- [The Isolation Spectrum](#the-isolation-spectrum)
- [The RuntimeClass Object](#the-runtimeclass-object)
- [How a Handler Reaches containerd](#how-a-handler-reaches-containerd)
- [gVisor](#gvisor)
- [Kata Containers](#kata-containers)
- [Comparing the Options](#comparing-the-options)
- [Pod Overhead](#pod-overhead)
- [Scheduling to the Right Nodes](#scheduling-to-the-right-nodes)
- [Mixed Runtime Clusters](#mixed-runtime-clusters)
- [What Breaks Under Sandboxing](#what-breaks-under-sandboxing)
- [Interaction With Pod Security](#interaction-with-pod-security)
- [Verifying What a Pod Actually Got](#verifying-what-a-pod-actually-got)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The Shared Kernel Problem

A container is not a security boundary in the way a virtual machine is. It is a set of kernel features (namespaces, cgroups, capabilities, seccomp, LSM) applied to an ordinary process.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                      STANDARD runc CONTAINERS                        │
   │                                                                      │
   │   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐              │
   │   │ pod A   │   │ pod B   │   │ pod C   │   │ pod D   │              │
   │   │ tenant1 │   │ tenant1 │   │ tenant2 │   │ tenant2 │              │
   │   └────┬────┘   └────┬────┘   └────┬────┘   └────┬────┘              │
   │        │             │             │             │                   │
   │        └─────────────┴──────┬──────┴─────────────┘                   │
   │                             │                                        │
   │                   ┌─────────▼──────────┐                             │
   │                   │  ONE LINUX KERNEL  │  ~400 syscalls of           │
   │                   │  (the host's)      │  attack surface             │
   │                   └────────────────────┘                             │
   │                                                                      │
   │   A kernel LPE exploited from pod C reaches A, B and D,              │
   │   and the node itself.                                                │
   └──────────────────────────────────────────────────────────────────────┘
```

Namespaces and seccomp narrow that surface but do not remove it. Historic container escapes have come through `waitid`, `overlayfs`, `io_uring`, cgroup release agents and `runc` itself. The pattern repeats roughly annually.

For most workloads this is an acceptable risk: your own code, your own images, one trust domain. It stops being acceptable when you run:

- **Untrusted or third-party code**, for example customer-submitted functions, CI jobs from public pull requests, or a plugin marketplace
- **Hard multi-tenancy**, where tenants must not be able to reach each other even given a kernel bug
- **Regulated workloads** sharing nodes with anything else

RuntimeClass is how you say "not this one, this one gets a stronger box".

---

## The Isolation Spectrum

```
   WEAKER ◄──────────────────────────────────────────────────────► STRONGER
   FASTER ◄──────────────────────────────────────────────────────► SLOWER

   ┌──────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
   │   runc   │   │  runc +      │   │   gVisor     │   │    Kata      │
   │          │   │  hardening   │   │   (runsc)    │   │  Containers  │
   ├──────────┤   ├──────────────┤   ├──────────────┤   ├──────────────┤
   │ host     │   │ host kernel  │   │ USERSPACE    │   │ SEPARATE     │
   │ kernel,  │   │ + seccomp    │   │ kernel       │   │ guest kernel │
   │ direct   │   │ + caps drop  │   │ intercepts   │   │ in a         │
   │ syscalls │   │ + non-root   │   │ syscalls     │   │ lightweight  │
   │          │   │ + userns     │   │              │   │ VM           │
   └──────────┘   └──────────────┘   └──────────────┘   └──────────────┘
    default        what most         untrusted code      hard multi-
                   clusters          with moderate       tenancy,
                   should do         compat needs        max isolation
```

An important framing point: **RuntimeClass is not a substitute for the hardening in [security-context.md](security-context.md)**. Dropping capabilities, running non-root and applying seccomp are cheap and should be universal. Sandboxed runtimes are an additional layer for the subset of workloads that warrant the cost.

---

## The RuntimeClass Object

Cluster-scoped, and deliberately small.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass

metadata:
  # The name pods reference via spec.runtimeClassName.
  # This is NOT automatically the handler name, though by convention
  # people keep them the same.
  name: gvisor

# The CRI handler name. This must match a runtime configured in
# containerd's config.toml on the nodes. If it does not exist on the
# node a pod lands on, the pod fails to start.
handler: runsc

# Optional. Constrains WHERE pods using this class may be scheduled.
scheduling:
  # Pods get these added to their nodeSelector automatically.
  nodeSelector:
    sandbox.example.com/runtime: gvisor
  # Pods get these tolerations added automatically, so the nodes can
  # be tainted against everything else.
  tolerations:
    - key: sandbox
      operator: Equal
      value: gvisor
      effect: NoSchedule

# Optional. Declares the per-pod resource cost of the runtime itself,
# so the scheduler and eviction accounting know about it.
overhead:
  podFixed:
    cpu: 50m
    memory: 60Mi
```

Three fields do all the work:

| Field | Effect |
|---|---|
| `handler` | Passed to the CRI as `runtime_handler`. containerd looks it up in its config and uses the matching binary. |
| `scheduling` | Merged into the pod's own `nodeSelector` and `tolerations` at admission time. |
| `overhead` | Added to the pod's effective resource requests for scheduling, quota and eviction. |

Using it is a single field on the pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-job
spec:
  runtimeClassName: gvisor      # must match a RuntimeClass metadata.name
  containers:
    - name: app
      image: registry.internal.example.com/customer-code:abc123
```

```bash
kubectl get runtimeclasses
# NAME      HANDLER   AGE
# gvisor    runsc     3d
# kata      kata      3d
```

---

## How a Handler Reaches containerd

The chain from YAML to a different binary running your container.

```
   Pod: runtimeClassName: gvisor
        │
        ▼
   RuntimeClass "gvisor" ──► handler: runsc
        │
        ▼
   kubelet builds a CRI RunPodSandboxRequest
        with runtime_handler = "runsc"
        │
        ▼
   containerd looks up:
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
        │
        ▼
   runs binary:  /usr/local/bin/containerd-shim-runsc-v1
        │
        ▼
   which starts:  runsc  (the gVisor sandbox)
```

The containerd configuration, which lives on **every node** that should support the runtime:

```toml
# /etc/containerd/config.toml
version = 2

[plugins."io.containerd.grpc.v1.cri".containerd]
  # What runs when no runtimeClassName is specified.
  default_runtime_name = "runc"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

  # ── The default, standard runtime ──────────────────────────────────
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true

  # ── gVisor. The table key "runsc" IS the handler name. ─────────────
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
    runtime_type = "io.containerd.runsc.v1"

  # ── Kata Containers ────────────────────────────────────────────────
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
    runtime_type = "io.containerd.kata.v2"
    privileged_without_host_devices = true
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  The table key in config.toml must EXACTLY equal the RuntimeClass    │
   │  `handler` field.                                                    │
   │                                                                      │
   │     runtimes.runsc   in config.toml                                  │
   │     handler: runsc   in the RuntimeClass                             │
   │                                                                      │
   │  A mismatch produces RunPodSandbox failures that name the handler,   │
   │  which at least makes the error obvious once you know to look.       │
   └──────────────────────────────────────────────────────────────────────┘
```

After editing:

```bash
sudo systemctl restart containerd
sudo crictl info | jq '.config.containerd.runtimes | keys'
# [ "kata", "runc", "runsc" ]
```

That last command is the fastest way to confirm a node actually supports a handler.

---

## gVisor

gVisor implements a **Linux kernel in userspace**, written in Go. Container syscalls are intercepted by the `runsc` sandbox and serviced by gVisor's own implementation, rather than reaching the host kernel directly.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                          gVisor ARCHITECTURE                         │
   │                                                                      │
   │   ┌──────────────────────────────────────────────┐                   │
   │   │  application process                         │                   │
   │   │     issues openat(), read(), socket() ...    │                   │
   │   └────────────────────┬─────────────────────────┘                   │
   │                        │ intercepted                                 │
   │   ┌────────────────────▼─────────────────────────┐                   │
   │   │  SENTRY  (runsc)                             │                   │
   │   │  a userspace kernel implementing most of     │                   │
   │   │  the Linux syscall surface in Go             │                   │
   │   └────────────────────┬─────────────────────────┘                   │
   │                        │ a SMALL, audited set of host syscalls       │
   │   ┌────────────────────▼─────────────────────────┐                   │
   │   │  GOFER (runsc-gofer)                         │                   │
   │   │  brokers filesystem access; the sandbox      │                   │
   │   │  itself has almost no direct file access     │                   │
   │   └────────────────────┬─────────────────────────┘                   │
   │                        │                                             │
   │   ┌────────────────────▼─────────────────────────┐                   │
   │   │  HOST LINUX KERNEL                           │                   │
   │   │  sees perhaps 60 syscalls instead of 400+    │                   │
   │   └──────────────────────────────────────────────┘                   │
   └──────────────────────────────────────────────────────────────────────┘
```

The security argument: an application exploiting a bug in gVisor's `openat` implementation compromises the Sentry, which is a sandboxed Go process with a tiny host syscall allowlist, not the host kernel.

### Installing

```bash
# On each node that should run gVisor workloads
(
  set -e
  ARCH=$(uname -m)
  URL=https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}
  wget -q "${URL}/runsc" "${URL}/runsc.sha512" \
       "${URL}/containerd-shim-runsc-v1" "${URL}/containerd-shim-runsc-v1.sha512"
  sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512
  sudo install -m 755 -o root -g root runsc containerd-shim-runsc-v1 /usr/local/bin/
  rm -f runsc* containerd-shim-runsc-v1*
)

# Verify
runsc --version
```

Then add the containerd runtime block shown above and restart containerd.

### Platforms

gVisor can intercept syscalls two ways, and the choice materially affects performance.

| Platform | Mechanism | Performance | Requires |
|---|---|---|---|
| `systrap` | Uses seccomp notify and signal-based trapping. The current default. | Good | Modern kernel |
| `ptrace` | Traps every syscall via `ptrace`. Works anywhere. | Poor, high syscall overhead | Nothing special |
| `kvm` | Runs the Sentry as a guest using hardware virtualization. | Best for syscall-heavy work | `/dev/kvm`, so bare metal or nested virt |

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
  TypeUrl = "io.containerd.runsc.v1.options"
  ConfigPath = "/etc/containerd/runsc.toml"
```

```toml
# /etc/containerd/runsc.toml
[runsc_config]
  platform = "systrap"
  # Useful while debugging compatibility problems:
  # debug = "true"
  # debug-log = "/var/log/runsc/%ID%/"
  # strace = "true"
```

The `strace` and `debug-log` options are how you find out which syscall an application needs that gVisor has not implemented.

---

## Kata Containers

Kata takes the other approach: run the pod inside a **real, lightweight virtual machine** with its own kernel.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                        KATA ARCHITECTURE                             │
   │                                                                      │
   │   ┌──────────────────────────────────────────────┐                   │
   │   │  LIGHTWEIGHT VM  (QEMU, Cloud Hypervisor,    │                   │
   │   │                   or Firecracker)            │                   │
   │   │                                              │                   │
   │   │   ┌────────────────────────────────────┐     │                   │
   │   │   │  container processes               │     │                   │
   │   │   └────────────────┬───────────────────┘     │                   │
   │   │                    │                         │                   │
   │   │   ┌────────────────▼───────────────────┐     │                   │
   │   │   │  GUEST KERNEL                      │     │                   │
   │   │   │  a real, separate Linux kernel     │     │                   │
   │   │   └────────────────────────────────────┘     │                   │
   │   └───────────────────┬──────────────────────────┘                   │
   │                       │  hardware virtualization boundary            │
   │   ┌───────────────────▼──────────────────────────┐                   │
   │   │  HOST KERNEL                                 │                   │
   │   │  sees a VM, not container syscalls           │                   │
   │   └──────────────────────────────────────────────┘                   │
   └──────────────────────────────────────────────────────────────────────┘
```

Escaping requires a hypervisor breakout, which is a substantially harder and rarer class of vulnerability than a kernel LPE. In exchange you pay VM startup time and memory for a second kernel.

### Installing

```bash
# Hardware virtualization is mandatory. Check it first.
grep -cE 'vmx|svm' /proc/cpuinfo      # must be > 0
ls -l /dev/kvm                         # must exist

# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y kata-runtime kata-proxy kata-shim

# Or the release tarball, which is more current
KATA_VER=3.2.0
wget -q "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VER}/kata-static-${KATA_VER}-amd64.tar.xz"
sudo tar -xJf "kata-static-${KATA_VER}-amd64.tar.xz" -C /

# Verify the whole stack, including that KVM is usable
sudo /opt/kata/bin/kata-runtime check
```

`kata-runtime check` is excellent. It reports on CPU virtualization support, KVM access, kernel modules and configuration, and tells you precisely what is missing.

### Hypervisor Choice

```toml
# /opt/kata/share/defaults/kata-containers/configuration.toml
[hypervisor.qemu]
  # Fewer virtual CPUs and less memory means faster boot.
  default_vcpus = 1
  default_memory = 256
  # Shared filesystem between host and guest.
  shared_fs = "virtio-fs"
```

| Hypervisor | Startup | Memory | Notes |
|---|---|---|---|
| QEMU | ~200 to 500 ms | Higher | Most featureful, best device support |
| Cloud Hypervisor | ~150 ms | Moderate | Rust, modern, good default |
| Firecracker | ~125 ms | Lowest | Minimal device model. No virtio-fs, so some volume types are unavailable |

Firecracker is what powers AWS Lambda and Fargate. Its minimal device model is exactly why it boots so fast and exactly why it supports fewer Kubernetes volume types.

---

## Comparing the Options

| | runc | gVisor | Kata | Firecracker (via Kata) |
|---|---|---|---|---|
| Kernel | shared host | userspace re-implementation | separate guest | separate guest |
| Isolation strength | namespaces only | strong | very strong | very strong |
| Escape requires | kernel LPE | Sentry bug + host syscall bug | hypervisor breakout | hypervisor breakout |
| Startup latency | ~50 ms | ~150 ms | ~250 to 500 ms | ~125 ms |
| Memory overhead | negligible | ~15 to 50 MB | ~130 MB+ (guest kernel) | ~50 MB+ |
| Syscall performance | native | 2x to 10x slower | near native | near native |
| I/O performance | native | slower (gofer brokered) | good (virtio) | good |
| Syscall compatibility | complete | ~80 to 90% of Linux | complete | complete |
| Needs hardware virt | no | no (except KVM platform) | **yes** | **yes** |
| Works in a nested VM | yes | yes | only with nested virt enabled | only with nested virt |
| `hostNetwork` support | yes | limited | no | no |
| Typical use | everything normal | untrusted code, functions | hard multi-tenancy | fast-start serverless |

### Choosing

```
   Do you run untrusted or third-party code on shared nodes?
        │
        ├─ No ──► runc, properly hardened. Stop here. Sandboxing is
        │          cost without benefit for a single trust domain.
        │
        └─ Yes ──► Is hardware virtualization available?
                        │
                        ├─ No ──► gVisor. It is the only option
                        │          without KVM.
                        │
                        └─ Yes ──► Is the workload syscall-heavy, or does
                                   it need full Linux compatibility?
                                        │
                                        ├─ Yes ──► Kata
                                        └─ No  ──► gVisor (lighter,
                                                   faster to start)
```

Note the top branch. Most clusters do not need this at all, and adopting it without a threat model is a way to inherit operational complexity for nothing.

---

## Pod Overhead

A sandboxed pod costs resources beyond what its containers request: the Sentry process, or the guest kernel and hypervisor. `overhead` makes that visible to Kubernetes.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
overhead:
  podFixed:
    cpu: 250m
    memory: 160Mi
```

What it affects:

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Pod requests:   cpu 500m, memory 512Mi                              │
   │  RuntimeClass overhead: cpu 250m, memory 160Mi                       │
   │                                                                      │
   │  SCHEDULER sees:          cpu 750m, memory 672Mi                     │
   │  ResourceQuota counts:    cpu 750m, memory 672Mi                     │
   │  Eviction threshold uses: cpu 750m, memory 672Mi                     │
   │  The cgroup limit is set to include the overhead.                    │
   └──────────────────────────────────────────────────────────────────────┘
```

Without it, the scheduler overcommits: it packs nodes based on container requests while the runtime quietly consumes more, and you get unexplained node memory pressure and evictions.

```bash
# The effective overhead on a running pod
kubectl get pod untrusted-job -o jsonpath='{.spec.overhead}' | jq
# { "cpu": "250m", "memory": "160Mi" }
```

Overhead is injected by the `RuntimeClass` admission controller at pod creation and becomes immutable. Changing the RuntimeClass later does not update existing pods. See [admission-controllers.md](admission-controllers.md) and [resource-management.md](resource-management.md).

Measure your own rather than copying numbers:

```bash
# Run an identical workload under each runtime and compare
kubectl top pod baseline-runc sandbox-gvisor sandbox-kata

# Or from the node, look at the actual cgroup usage
sudo systemd-cgtop -m
```

---

## Scheduling to the Right Nodes

A RuntimeClass pod will fail on any node whose containerd does not have the handler. The `scheduling` block prevents that automatically.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  # Merged into the pod's nodeSelector. The pod does not need to
  # know these labels exist.
  nodeSelector:
    sandbox.example.com/runtime: gvisor
  # Merged into the pod's tolerations, so the nodes can be tainted
  # against everything that does NOT use this class.
  tolerations:
    - key: sandbox
      operator: Equal
      value: gvisor
      effect: NoSchedule
overhead:
  podFixed:
    cpu: 50m
    memory: 60Mi
```

Prepare the nodes:

```bash
# Label nodes that have runsc installed
kubectl label node worker-04 worker-05 sandbox.example.com/runtime=gvisor

# Taint them so ordinary workloads do not consume the sandbox capacity
kubectl taint node worker-04 worker-05 sandbox=gvisor:NoSchedule
```

The result is a clean separation with no per-pod configuration:

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  pod WITHOUT runtimeClassName                                        │
   │     no toleration for sandbox=gvisor  ──►  cannot land on 04/05      │
   │                                                                      │
   │  pod WITH runtimeClassName: gvisor                                   │
   │     admission adds nodeSelector + toleration                         │
     │     ──►  lands ONLY on 04/05, which have runsc                     │
   └──────────────────────────────────────────────────────────────────────┘
```

Important detail: the `scheduling.nodeSelector` is **merged** with any `nodeSelector` the pod already has. A conflict on the same key causes the pod to be **rejected** at admission rather than silently resolved.

See [scheduling.md](scheduling.md) for taints and tolerations in depth.

---

## Mixed Runtime Clusters

A realistic production shape.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  CONTROL PLANE                                                       │
   │    cp-01, cp-02, cp-03     runc only                                 │
   ├──────────────────────────────────────────────────────────────────────┤
   │  GENERAL WORKLOAD NODES                                              │
   │    worker-01..03           runc, hardened                            │
   │                            first-party applications                  │
   ├──────────────────────────────────────────────────────────────────────┤
   │  SANDBOX NODES                                                       │
   │    worker-04..05           runc + runsc                              │
   │                            label  sandbox.example.com/runtime=gvisor │
   │                            taint  sandbox=gvisor:NoSchedule          │
   │                            customer code, CI from forks              │
   ├──────────────────────────────────────────────────────────────────────┤
   │  HIGH ISOLATION NODES                                                │
   │    worker-06               runc + kata (bare metal, KVM)             │
   │                            label  sandbox.example.com/runtime=kata   │
   │                            taint  sandbox=kata:NoSchedule            │
   │                            regulated or hostile multi-tenant work    │
   └──────────────────────────────────────────────────────────────────────┘
```

Declaring both classes:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    sandbox.example.com/runtime: gvisor
  tolerations:
    - key: sandbox
      operator: Equal
      value: gvisor
      effect: NoSchedule
overhead:
  podFixed: { cpu: 50m, memory: 60Mi }
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
scheduling:
  nodeSelector:
    sandbox.example.com/runtime: kata
  tolerations:
    - key: sandbox
      operator: Equal
      value: kata
      effect: NoSchedule
overhead:
  podFixed: { cpu: 250m, memory: 160Mi }
```

### Enforcing Sandboxing for a Namespace

RuntimeClass is opt-in per pod, which is the wrong default for a namespace that exists specifically to run untrusted code. Close the gap with a CEL policy:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-sandbox-runtime
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  validations:
    - expression: >-
        has(object.spec.runtimeClassName) &&
        object.spec.runtimeClassName in ['gvisor', 'kata']
      message: >-
        pods in this namespace must set runtimeClassName to gvisor or kata
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-sandbox-runtime-binding
spec:
  policyName: require-sandbox-runtime
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels:
        security.example.com/untrusted: "true"
```

```bash
kubectl create namespace customer-functions
kubectl label ns customer-functions security.example.com/untrusted=true
```

---

## What Breaks Under Sandboxing

Be realistic about this before committing. gVisor in particular trades compatibility for isolation.

### Under gVisor

```
   ✗ Unimplemented syscalls          gVisor covers most of Linux, not all.
                                      Exotic or very new syscalls may fail
                                      with ENOSYS.
   ✗ Direct hardware access          GPUs need specific gVisor support and
                                      configuration; many device plugins do
                                      not work at all.
   ✗ Some /proc and /sys entries     gVisor presents its own, partial
                                      procfs. Tools reading obscure entries
                                      get surprises.
   ✗ Kernel modules                  Never. There is no host kernel to
                                      load into.
   ✗ Raw sockets and some netfilter  Limited. Network-heavy tooling
                                      frequently breaks.
   ✗ hostNetwork                     Not meaningfully supported.
   ✗ Nested containers               Docker-in-Docker style workloads
                                      generally do not work.
   ⚠ io_uring                        Historically unsupported or disabled;
                                      affects some modern runtimes.
   ⚠ Performance                     Syscall-heavy and I/O-heavy workloads
                                      can be several times slower.
```

### Under Kata

Compatibility is much better, since it is a real kernel. The constraints are structural instead:

```
   ✗ hostNetwork / hostPID / hostIPC  The pod is in a VM. There is no
                                       meaningful host namespace to share.
   ✗ hostPath volumes                 Limited, and dependent on virtio-fs.
                                       Firecracker supports fewer still.
   ✗ Nodes without KVM                Hard requirement. Rules out most
                                       nested-virtualization environments
                                       and many cloud instance types.
   ⚠ Startup latency                  Hundreds of milliseconds. Matters for
                                       short-lived Jobs and scale-to-zero.
   ⚠ Memory                           Every pod pays for a guest kernel.
   ⚠ Device plugins                   Must be virtualization-aware.
```

### Test Before Committing

```bash
# Run the real workload under the candidate runtime and watch it fail.
kubectl run compat-test \
  --image=registry.internal.example.com/your-app:1.4.2 \
  --overrides='{"spec":{"runtimeClassName":"gvisor"}}' \
  --restart=Never -- /bin/sh -c 'your-smoke-test.sh'

kubectl logs compat-test
```

For gVisor specifically, turn on strace to see exactly which syscall was refused:

```toml
# /etc/containerd/runsc.toml
[runsc_config]
  debug = "true"
  debug-log = "/var/log/runsc/%ID%/"
  strace = "true"
```

```bash
sudo tail -f /var/log/runsc/*/runsc.log.*.boot | grep -i 'unsupported\|ENOSYS'
```

---

## Interaction With Pod Security

Pod Security Admission can **exempt** workloads by RuntimeClass, on the reasoning that a sandboxed pod does not need the same pod-level restrictions.

```yaml
# /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "restricted"
        enforce-version: "v1.31"
      exemptions:
        # Pods using these RuntimeClasses bypass PodSecurity entirely.
        runtimeClasses:
          - kata
        namespaces:
          - kube-system
```

Use this with real care.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  An exemption is TOTAL. An exempt pod is not enforced, not warned    │
   │  about, and not audited.                                             │
   │                                                                      │
   │  A Kata pod running as root with all capabilities is contained by    │
   │  the VM boundary, which is a defensible position.                    │
   │                                                                      │
   │  A gVisor pod in the same state is NOT equivalently contained: the   │
   │  Sentry is a userspace process, not a hypervisor boundary.           │
   │                                                                      │
   │  Exempting gvisor is much harder to justify than exempting kata.     │
   └──────────────────────────────────────────────────────────────────────┘
```

The safer posture is to apply Restricted to sandboxed pods as well, and treat the runtime as defence in depth rather than a replacement. See [pod-security-standards.md](pod-security-standards.md).

---

## Verifying What a Pod Actually Got

Never assume. Confirm.

```bash
# 1. What does the pod spec say?
kubectl get pod untrusted-job -o jsonpath='{.spec.runtimeClassName}'; echo
kubectl get pod untrusted-job -o jsonpath='{.spec.overhead}' | jq

# 2. From the node, what handler did containerd actually use?
CID=$(sudo crictl ps --name app -q | head -1)
POD=$(sudo crictl inspect "$CID" | jq -r '.info.sandboxID')
sudo crictl inspectp "$POD" | jq -r '.info.runtimeHandler'
# runsc

# 3. From inside the container, which kernel is it?
kubectl exec untrusted-job -- uname -a
```

The `uname` output is the giveaway and makes the concept concrete:

```
   runc      Linux node 6.8.0-45-generic ...      ← the host's real kernel
   gVisor    Linux 4.4.0 ...                      ← gVisor reports a
                                                    synthetic version
   Kata      Linux 6.1.62 ...                     ← the GUEST kernel,
                                                    different from the host
```

```bash
# Compare host and pod directly
uname -r                                    # on the node
kubectl exec untrusted-job -- uname -r      # in the pod
# Different values confirm real kernel separation.
```

gVisor also identifies itself:

```bash
kubectl exec untrusted-job -- dmesg | head -3
# [    0.000000] Starting gVisor...
```

---

## Recipes

### Recipe: End-to-End gVisor Setup

```bash
#!/usr/bin/env bash
set -euo pipefail
# Run the node portion on each intended sandbox node.

echo "== 1. install runsc"
ARCH=$(uname -m)
URL="https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}"
wget -q "${URL}/runsc" "${URL}/runsc.sha512" \
     "${URL}/containerd-shim-runsc-v1" "${URL}/containerd-shim-runsc-v1.sha512"
sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512
sudo install -m 755 -o root -g root runsc containerd-shim-runsc-v1 /usr/local/bin/
rm -f runsc* containerd-shim-runsc-v1*
runsc --version

echo "== 2. configure containerd"
sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
if ! grep -q 'runtimes.runsc' /etc/containerd/config.toml; then
  sudo tee -a /etc/containerd/config.toml >/dev/null <<'EOF'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF
fi
sudo systemctl restart containerd
sudo crictl info | jq '.config.containerd.runtimes | keys'
```

Then, once per cluster:

```bash
kubectl label node worker-04 worker-05 sandbox.example.com/runtime=gvisor
kubectl taint node worker-04 worker-05 sandbox=gvisor:NoSchedule

kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    sandbox.example.com/runtime: gvisor
  tolerations:
    - key: sandbox
      operator: Equal
      value: gvisor
      effect: NoSchedule
overhead:
  podFixed:
    cpu: 50m
    memory: 60Mi
EOF

# Smoke test
kubectl run gvisor-test --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"gvisor"}}' -- uname -a
sleep 5
kubectl logs gvisor-test
kubectl delete pod gvisor-test
```

### Recipe: Benchmark the Overhead on Your Own Hardware

```bash
#!/usr/bin/env bash
# Startup latency comparison. Published numbers are not your numbers.
for rc in "" gvisor kata; do
  name="bench-${rc:-runc}"
  override='{"spec":{}}'
  [ -n "$rc" ] && override="{\"spec\":{\"runtimeClassName\":\"${rc}\"}}"

  start=$(date +%s%N)
  kubectl run "$name" --image=busybox:1.36 --restart=Never \
    --overrides="$override" -- /bin/true >/dev/null 2>&1

  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
    "pod/$name" --timeout=120s >/dev/null 2>&1
  end=$(date +%s%N)

  printf '%-10s %s ms\n' "${rc:-runc}" "$(( (end-start)/1000000 ))"
  kubectl delete pod "$name" --wait=false >/dev/null 2>&1
done
```

### Recipe: Audit Which Pods Are Sandboxed

```bash
# Every pod using a non-default runtime
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(.spec.runtimeClassName != null)
  | "\(.metadata.namespace)/\(.metadata.name)\t\(.spec.runtimeClassName)\t\(.spec.nodeName)"' \
  | column -t

# The inverse, and more interesting: pods in untrusted namespaces
# that are NOT sandboxed.
for ns in $(kubectl get ns -l security.example.com/untrusted=true \
            -o jsonpath='{.items[*].metadata.name}'); do
  kubectl get pods -n "$ns" -o json | jq -r --arg ns "$ns" '
    .items[]
    | select(.spec.runtimeClassName == null)
    | "UNSANDBOXED: \($ns)/\(.metadata.name)"'
done
```

### Recipe: Which Nodes Support Which Handlers

```bash
#!/usr/bin/env bash
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  printf '%-14s ' "$node"
  # Requires SSH access; on a managed cluster use a privileged DaemonSet instead.
  ssh "$node" 'sudo crictl info 2>/dev/null \
    | jq -r ".config.containerd.runtimes | keys | join(\", \")"' 2>/dev/null \
    || echo "(unreachable)"
done
```

---

## Command Reference

```bash
# ---------- RuntimeClass objects ----------
kubectl get runtimeclasses
kubectl describe runtimeclass gvisor
kubectl get runtimeclass gvisor -o yaml

# ---------- Node support ----------
sudo crictl info | jq '.config.containerd.runtimes | keys'
sudo crictl version
runsc --version
sudo /opt/kata/bin/kata-runtime check
grep -cE 'vmx|svm' /proc/cpuinfo
ls -l /dev/kvm

# ---------- containerd config ----------
sudo cat /etc/containerd/config.toml
sudo containerd config dump | grep -A3 runtimes
sudo systemctl restart containerd
sudo systemctl status containerd

# ---------- Verify a running pod ----------
kubectl get pod NAME -o jsonpath='{.spec.runtimeClassName}'
kubectl get pod NAME -o jsonpath='{.spec.overhead}' | jq
kubectl exec NAME -- uname -a
sudo crictl inspectp SANDBOX_ID | jq -r '.info.runtimeHandler'

# ---------- Node preparation ----------
kubectl label node NODE sandbox.example.com/runtime=gvisor
kubectl taint node NODE sandbox=gvisor:NoSchedule
kubectl taint node NODE sandbox-              # remove

# ---------- gVisor debugging ----------
sudo tail -f /var/log/runsc/*/runsc.log.*.boot
sudo journalctl -u containerd -f | grep -i runsc
```

---

## Troubleshooting

### `RunPodSandbox failed: no runtime for "runsc" is configured`

The node containerd does not know the handler.

```bash
sudo crictl info | jq '.config.containerd.runtimes | keys'
sudo grep -A3 'runtimes.runsc' /etc/containerd/config.toml
```

Either the config block is missing, containerd was not restarted, or the pod landed on a node without the runtime. The last case is exactly what `scheduling.nodeSelector` on the RuntimeClass prevents, so add it.

### Pod Stuck in `Pending` With No Matching Node

```bash
kubectl describe pod untrusted-job | tail -15
# 0/6 nodes are available: 6 node(s) didn't match Pod's node affinity/selector
```

The RuntimeClass `nodeSelector` names a label no node carries.

```bash
kubectl get runtimeclass gvisor -o jsonpath='{.scheduling.nodeSelector}' | jq
kubectl get nodes -l sandbox.example.com/runtime=gvisor
```

Label the nodes, or fix the selector.

### `RuntimeClass "gvisor" not found`

The object does not exist, and the pod is rejected at admission.

```bash
kubectl get runtimeclass
```

Note this is a cluster-scoped object, so there is no namespace to get wrong.

### Container Exits Immediately Under gVisor

Usually an unimplemented syscall.

```bash
kubectl logs untrusted-job --previous
kubectl describe pod untrusted-job | tail -20
```

Turn on gVisor's own logging to see which one:

```toml
# /etc/containerd/runsc.toml
[runsc_config]
  debug = "true"
  debug-log = "/var/log/runsc/%ID%/"
  strace = "true"
```

```bash
sudo systemctl restart containerd
# re-run the pod, then
sudo grep -i 'unsupported\|ENOSYS\|not implemented' /var/log/runsc/*/runsc.log.*
```

If the syscall is genuinely required, Kata is the answer rather than gVisor.

### Kata Pods Fail With a KVM Error

```
failed to create VM: open /dev/kvm: no such file or directory
```

No hardware virtualization on that node.

```bash
grep -cE 'vmx|svm' /proc/cpuinfo    # 0 means the CPU flag is absent or
                                     # virtualization is disabled in BIOS
ls -l /dev/kvm
lsmod | grep kvm
sudo modprobe kvm_intel   # or kvm_amd
```

On a cloud VM this usually means the instance type does not offer nested virtualization. Use gVisor there instead, or move to metal instances.

### Nodes Under Memory Pressure After Adopting Kata

`overhead` is not set, so the scheduler has been packing nodes without accounting for guest kernels.

```bash
kubectl get runtimeclass kata -o jsonpath='{.overhead}'
# empty = the problem
```

Measure the real cost and set it:

```bash
kubectl top pods --containers -A | grep kata
```

Note that adding `overhead` only affects **new** pods. Existing ones keep the value injected at their creation.

### Performance Is Far Worse Than Expected Under gVisor

Check the platform. `ptrace` is dramatically slower than `systrap`.

```bash
sudo grep platform /etc/containerd/runsc.toml
sudo grep -i platform /var/log/runsc/*/runsc.log.* | head
```

Also confirm `strace` and `debug` are **off** in production. Leaving them enabled after debugging is a classic and costly mistake.

### `hostNetwork` Pod Fails Under a Sandbox

Expected. A sandboxed pod cannot meaningfully share the host network namespace. Any workload requiring `hostNetwork`, `hostPID` or `hostIPC` must run under `runc`, which is a strong hint that it is infrastructure and should not be sandboxed anyway.

---

## Exam and Interview Traps

1. **Is a container a security boundary?** Not in the way a VM is. It is a process with kernel features applied. All containers on a node share one kernel.

2. **What does `handler` refer to?** A runtime configured in the CRI implementation, for example a table key under `containerd.runtimes` in `config.toml`. It must match exactly.

3. **Is RuntimeClass namespaced?** No, it is cluster-scoped.

4. **What happens if a pod lands on a node without the handler?** `RunPodSandbox` fails. Use `scheduling.nodeSelector` on the RuntimeClass to prevent it.

5. **What does `overhead.podFixed` affect?** Scheduling decisions, ResourceQuota accounting, eviction thresholds and the pod cgroup. Without it the scheduler overcommits.

6. **Does changing a RuntimeClass update existing pods?** No. `overhead` is injected at admission and is immutable thereafter.

7. **Fundamental difference between gVisor and Kata?** gVisor implements a kernel in userspace and intercepts syscalls. Kata runs a real guest kernel inside a lightweight VM.

8. **Which requires hardware virtualization?** Kata. gVisor does not, except when using its KVM platform.

9. **Which has better syscall compatibility?** Kata, because it is a real Linux kernel. gVisor implements most but not all of Linux.

10. **Why can gVisor be slower?** Every syscall is intercepted and serviced in userspace rather than going straight to the host kernel.

11. **How do you prove which runtime a pod got?** `crictl inspectp` and read `runtimeHandler`, or compare `uname -r` inside the pod against the node.

12. **What does a PodSecurity `runtimeClasses` exemption do?** Bypasses PodSecurity entirely for pods using that class, in all three modes. Defensible for Kata, much harder to justify for gVisor.

13. **Can a sandboxed pod use `hostNetwork`?** Not meaningfully. Kata cannot at all; gVisor's support is limited.

14. **When should you not use RuntimeClass?** When you run only first-party code in a single trust domain. The complexity buys nothing there. Harden `runc` properly instead.

---

## Related Topics

- [container-runtime.md](container-runtime.md) for CRI, containerd and runc
- [containers.md](containers.md) for what a container actually is
- [linux-namespaces.md](linux-namespaces.md) for the isolation primitives being strengthened
- [cgroups.md](cgroups.md) for the resource side of containment
- [security-context.md](security-context.md) for the hardening that should come first
- [pod-security-standards.md](pod-security-standards.md) for RuntimeClass-based exemptions
- [admission-controllers.md](admission-controllers.md) for the controller that injects overhead
- [scheduling.md](scheduling.md) for the taints and tolerations that steer pods to sandbox nodes
- [resource-management.md](resource-management.md) for how overhead affects quota and eviction
- [cluster-hardening.md](cluster-hardening.md) for where this sits in overall posture
- [image-security.md](image-security.md) for trusting what runs inside the sandbox

---

## Key Takeaways

- Containers share the host kernel. Namespaces and seccomp narrow that surface but do not make it a hard boundary.
- RuntimeClass is opt-in per pod via `spec.runtimeClassName` and is cluster-scoped.
- `handler` must exactly match a runtime configured in containerd on every node the pod might reach.
- `scheduling.nodeSelector` and `scheduling.tolerations` are the mechanism that keeps sandboxed pods on capable nodes, automatically, with no per-pod configuration.
- `overhead.podFixed` is not optional in practice. Without it the scheduler overcommits nodes and you get unexplained evictions.
- gVisor intercepts syscalls in a userspace kernel: no hardware virtualization needed, moderate overhead, incomplete Linux compatibility.
- Kata runs a real guest kernel in a lightweight VM: strongest isolation and full compatibility, but requires KVM and costs startup time and memory.
- Sandboxing is not a replacement for dropping capabilities, running non-root and applying seccomp. Do those first, everywhere.
- Exempting a RuntimeClass from Pod Security is total, and far easier to justify for Kata than for gVisor.
- Test real workloads under the candidate runtime before committing. Compatibility problems surface as immediate container exits, and gVisor's strace logging is how you identify them.
- If you run only first-party code in one trust domain, you probably do not need this at all.

---

## References

- [Runtime Class](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- [Pod Overhead](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/)
- [Container Runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [gVisor Documentation](https://gvisor.dev/docs/)
- [gVisor Platforms](https://gvisor.dev/docs/architecture_guide/platforms/)
- [Kata Containers Documentation](https://katacontainers.io/docs/)
- [containerd CRI Plugin Configuration](https://github.com/containerd/containerd/blob/main/docs/cri/config.md)
- [Pod Security Admission Configuration](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/)
