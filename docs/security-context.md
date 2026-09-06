# 🔐 Kubernetes securityContext: Shaping the Container's Privileges

`securityContext` is where Kubernetes abstractions meet Linux kernel primitives. Every field here becomes a UID, a capability bitmask, a seccomp filter, an LSM label or a mount option in the OCI runtime spec that containerd hands to runc. This document covers every field at both pod and container scope, what each one actually does at the kernel level, the precedence rules between them, and the exact combinations required to satisfy the Restricted Pod Security Standard.

## 📋 Table of Contents
- [Where securityContext Lives](#where-securitycontext-lives)
- [From YAML to Kernel](#from-yaml-to-kernel)
- [Field Scope Matrix](#field-scope-matrix)
- [Precedence Rules](#precedence-rules)
- [User and Group Identity](#user-and-group-identity)
- [runAsNonRoot](#runasnonroot)
- [fsGroup and Volume Ownership](#fsgroup-and-volume-ownership)
- [supplementalGroups](#supplementalgroups)
- [Linux Capabilities](#linux-capabilities)
- [allowPrivilegeEscalation and no_new_privs](#allowprivilegeescalation-and-no_new_privs)
- [privileged](#privileged)
- [readOnlyRootFilesystem](#readonlyrootfilesystem)
- [procMount](#procmount)
- [seccomp](#seccomp)
- [AppArmor](#apparmor)
- [SELinux](#selinux)
- [sysctls](#sysctls)
- [Host Namespace Fields](#host-namespace-fields)
- [windowsOptions](#windowsoptions)
- [The Restricted Baseline](#the-restricted-baseline)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Where securityContext Lives

There are two `securityContext` blocks in a Pod spec, and they are **different types** with different field sets. Confusing them is the single most common mistake.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo
spec:
  # ┌─────────────────────────────────────────────────────────┐
  # │ POD LEVEL: type is PodSecurityContext                   │
  # │ Applies to all containers as a default, plus a few      │
  # │ fields that only make sense pod-wide (fsGroup, sysctls) │
  # └─────────────────────────────────────────────────────────┘
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: app
      image: nginx:1.27
      # ┌───────────────────────────────────────────────────────┐
      # │ CONTAINER LEVEL: type is SecurityContext              │
      # │ Overrides the pod level for this container, plus      │
      # │ fields that only exist per container (capabilities,   │
      # │ privileged, readOnlyRootFilesystem)                   │
      # └───────────────────────────────────────────────────────┘
      securityContext:
        runAsUser: 2000              # wins over the pod's 1000
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

`fsGroup` at container level is a schema error. `capabilities` at pod level is a schema error. The API server will reject both, but the message is not always obvious, so keep the matrix below to hand.

---

## From YAML to Kernel

Understanding the translation removes almost all of the mystery.

```
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  │   Pod spec                                                               │
  │   securityContext: { runAsUser: 1000, capabilities: {drop: [ALL]} }      │
  │        │                                                                 │
  │        ▼                                                                 │
  │   kube-apiserver  (admission may default or reject: PodSecurity)         │
  │        │                                                                 │
  │        ▼                                                                 │
  │   kubelet                                                                │
  │        │  builds a CRI CreateContainerRequest with a LinuxContainer      │
  │        │  SecurityContext message                                        │
  │        ▼                                                                 │
  │   containerd  (CRI plugin)                                               │
  │        │  translates CRI fields into an OCI runtime spec (config.json)   │
  │        ▼                                                                 │
  │   ┌───────────────────────────────────────────────────────────────┐      │
  │   │  config.json  (OCI runtime spec)                              │      │
  │   │    "process": {                                               │      │
  │   │       "user": { "uid": 1000, "gid": 3000,                     │      │
  │   │                 "additionalGids": [2000] },                   │      │
  │   │       "noNewPrivileges": true,                                │      │
  │   │       "capabilities": { "bounding": [], "effective": [],      │      │
  │   │                         "permitted": [] }                     │      │
  │   │    },                                                         │      │
  │   │    "linux": {                                                 │      │
  │   │       "seccomp": { ... },                                     │      │
  │   │       "namespaces": [ ... ],                                  │      │
  │   │       "readonlyPaths": [ ... ]                                │      │
  │   │    }                                                          │      │
  │   └───────────────────────────────────────────────────────────────┘      │
  │        │                                                                 │
  │        ▼                                                                 │
  │   runc                                                                   │
  │        │  setuid/setgid, capset(), prctl(PR_SET_NO_NEW_PRIVS),           │
  │        │  seccomp(SECCOMP_SET_MODE_FILTER), LSM label, then execve()     │
  │        ▼                                                                 │
  │   your process                                                           │
  │                                                                          │
  └──────────────────────────────────────────────────────────────────────────┘
```

You can see the end result on a node. This is the most instructive five minutes you can spend on this topic:

```bash
# Find the container
CID=$(sudo crictl ps --name app -q | head -1)

# Its OCI spec, as runc received it
sudo crictl inspect "$CID" | jq '.info.runtimeSpec.process'
sudo crictl inspect "$CID" | jq '.info.runtimeSpec.process.capabilities'
sudo crictl inspect "$CID" | jq '.info.runtimeSpec.linux.seccomp.defaultAction'
```

---

## Field Scope Matrix

| Field | Pod | Container | Notes |
|---|:---:|:---:|---|
| `runAsUser` | ✅ | ✅ | Container wins |
| `runAsGroup` | ✅ | ✅ | Container wins |
| `runAsNonRoot` | ✅ | ✅ | Container wins |
| `supplementalGroups` | ✅ | ❌ | Pod only |
| `supplementalGroupsPolicy` | ✅ | ❌ | Pod only, newer field |
| `fsGroup` | ✅ | ❌ | Pod only |
| `fsGroupChangePolicy` | ✅ | ❌ | Pod only |
| `seccompProfile` | ✅ | ✅ | Container wins |
| `appArmorProfile` | ✅ | ✅ | Container wins |
| `seLinuxOptions` | ✅ | ✅ | Container wins |
| `seLinuxChangePolicy` | ✅ | ❌ | Pod only |
| `sysctls` | ✅ | ❌ | Pod only, applies to the pod's namespaces |
| `windowsOptions` | ✅ | ✅ | Container wins |
| `capabilities` | ❌ | ✅ | Container only |
| `privileged` | ❌ | ✅ | Container only |
| `allowPrivilegeEscalation` | ❌ | ✅ | Container only |
| `readOnlyRootFilesystem` | ❌ | ✅ | Container only |
| `procMount` | ❌ | ✅ | Container only |
| `hostNetwork` | ✅* | ❌ | *Directly on `spec`, not inside `securityContext` |
| `hostPID` | ✅* | ❌ | *Directly on `spec` |
| `hostIPC` | ✅* | ❌ | *Directly on `spec` |
| `hostUsers` | ✅* | ❌ | *Directly on `spec`, user namespace support |

Note the last four: `hostNetwork`, `hostPID`, `hostIPC` and `hostUsers` are fields on `spec` itself, siblings of `securityContext`, not inside it. They are security relevant and the Pod Security Standards check them, so they are covered here.

---

## Precedence Rules

```
   ┌──────────────────────────────────────────────────────────────────┐
   │  For any field valid at both scopes:                             │
   │                                                                  │
   │    container.securityContext.X  is set   ──►  use it             │
   │    container.securityContext.X  is unset ──►  use pod value      │
   │    both unset                            ──►  image default or   │
   │                                               runtime default    │
   └──────────────────────────────────────────────────────────────────┘
```

There is no merging. It is a whole-field override. This matters for `capabilities`: setting `capabilities` on a container does not merge with anything, it replaces the runtime default set entirely as described below.

Two subtleties:

- **`runAsUser` unset falls back to the image's `USER` directive.** If the Dockerfile has `USER 1001`, that is what runs. If the Dockerfile has no `USER`, the container runs as root (UID 0) inside its namespace.
- **`runAsNonRoot: true` with no `runAsUser` anywhere** means the kubelet must determine the image's user at runtime. If the image's `USER` is numeric and non-zero, it starts. If the image's `USER` is a *name* like `nginx`, the kubelet cannot resolve it to a UID and the pod fails with `CreateContainerConfigError`. Always pair `runAsNonRoot: true` with an explicit numeric `runAsUser`.

---

## User and Group Identity

```yaml
spec:
  securityContext:
    # Primary UID for the process.
    runAsUser: 1000
    # Primary GID for the process.
    runAsGroup: 3000
```

What actually happens: runc calls `setgid(3000)` then `setuid(1000)` before `execve()`. Inside the container:

```bash
$ id
uid=1000 gid=3000 groups=3000
```

### The UID Does Not Need To Exist

There is no requirement that UID 1000 appears in the container's `/etc/passwd`. The kernel deals in numbers. A missing entry only means tools that do a reverse lookup show the raw number:

```bash
$ whoami
whoami: cannot find name for user ID 1000
$ id
uid=1000 gid=3000 groups=3000
```

Some applications (notably some JVM tooling, `sshd`, and anything calling `getpwuid()`) genuinely require a passwd entry. Two standard fixes:

```dockerfile
# Fix at build time: create the user in the image.
RUN echo 'app:x:1000:3000::/home/app:/sbin/nologin' >> /etc/passwd
```

```yaml
# Or use nss_wrapper, or mount a passwd file, if the image is not yours.
```

### Without User Namespaces, UIDs Are Host UIDs

This is the fact that changes how you think about container security.

```
   WITHOUT hostUsers: false  (the default)
   ─────────────────────────────────────────
   container UID 1000  ===  host UID 1000
   container UID 0     ===  host UID 0 (real root, restricted by capabilities)

   WITH hostUsers: false  (user namespaces enabled)
   ─────────────────────────────────────────
   container UID 0     ───mapped──►  host UID 165536 (unprivileged)
   container UID 1000  ───mapped──►  host UID 166536 (unprivileged)
```

By default, a container running as root is running as *actual host root*, merely constrained by dropped capabilities, seccomp, and namespaces. If any of those constraints has a gap, root in the container is root on the node. This is why `runAsNonRoot` matters so much and why user namespaces (`hostUsers: false`) are a significant hardening step where supported.

```yaml
spec:
  # Run the pod in its own user namespace. Container root maps to an
  # unprivileged host UID. Requires kernel and runtime support.
  hostUsers: false
```

See [linux-namespaces.md](linux-namespaces.md) for the namespace mechanics.

---

## runAsNonRoot

```yaml
securityContext:
  runAsNonRoot: true
```

This is a **validation gate, not an assignment**. It does not choose a UID. It instructs the kubelet to refuse to start the container if the effective UID would be 0.

The check happens at container creation, after the image is pulled, because the kubelet needs to read the image config to find the `USER` directive.

```
   runAsNonRoot: true
        │
        ├─ runAsUser explicitly set?
        │     ├─ to 0      ──► REJECT at API validation time
        │     └─ to non-0  ──► OK
        │
        └─ runAsUser unset, fall back to image USER
              ├─ numeric, non-zero    ──► OK
              ├─ numeric, zero        ──► CreateContainerConfigError
              ├─ a name like "nginx"  ──► CreateContainerConfigError
              │                            (kubelet cannot resolve names)
              └─ absent entirely      ──► CreateContainerConfigError
```

The error you will see:

```
Error: container has runAsNonRoot and image will run as root
```

or

```
Error: container has runAsNonRoot and image has non-numeric user (nginx),
cannot verify user is non-root
```

The robust pattern is always to set both:

```yaml
securityContext:
  runAsNonRoot: true      # the guard
  runAsUser: 1000         # the actual identity
```

---

## fsGroup and Volume Ownership

`fsGroup` solves a real problem: a volume is provisioned with root ownership, but the container runs as UID 1000 and cannot write to it.

```yaml
spec:
  securityContext:
    fsGroup: 2000
```

Three things happen:

1. `2000` is added to the process's supplementary group list.
2. The kubelet **recursively chowns** the volume to group `2000`.
3. The kubelet **recursively chmods** to add group write, effectively `g+rwX`.

```
   Before:                            After fsGroup: 2000
   /data       root:root  0755        /data       root:2000  0775
   /data/db    root:root  0644        /data/db    root:2000  0664
   /data/logs  root:root  0755        /data/logs  root:2000  0775
```

The process, running as UID 1000 with supplementary group 2000, can now write.

### The Recursive chown Performance Trap

On a volume with millions of files, that recursive walk happens **on every pod start** and can take many minutes. Pods sit in `ContainerCreating` with no obvious explanation. This has bitten large Elasticsearch, Postgres and Kafka deployments repeatedly.

`fsGroupChangePolicy` fixes it:

```yaml
spec:
  securityContext:
    fsGroup: 2000
    # Always    : chown/chmod every time (default).
    # OnRootMismatch: check the TOP LEVEL directory's ownership first.
    #                 If it already matches, skip the entire recursive walk.
    fsGroupChangePolicy: OnRootMismatch
```

`OnRootMismatch` should be your default for any volume with meaningful file counts. The first mount does the work; every subsequent mount is a single `stat`.

### Which Volume Types Honour fsGroup

`fsGroup` applies to volumes whose ownership Kubernetes controls:

| Volume type | fsGroup applied? |
|---|:---:|
| `emptyDir` | ✅ |
| `configMap`, `secret`, `downwardAPI`, `projected` | ✅ |
| Block-backed PVs (most CSI drivers) | ✅ |
| `hostPath` | ❌ never, it is host state |
| NFS and other shared filesystems | ⚠️ depends on the driver |
| CSI drivers declaring `fsGroupPolicy: None` | ❌ |

For NFS specifically, ownership is controlled by the NFS server's export configuration and the `no_root_squash` setting, not by the kubelet. `fsGroup` still adds the supplementary group to the process, which combined with correct server-side ownership is usually the working solution. See [csi.md](csi.md) and [install-csi-nfs.md](install-csi-nfs.md).

Check what a CSI driver declares:

```bash
kubectl get csidriver -o custom-columns=\
'NAME:.metadata.name,FSGROUPPOLICY:.spec.fsGroupPolicy'
```

---

## supplementalGroups

Adds GIDs to the process's supplementary group list without changing the primary GID.

```yaml
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    supplementalGroups: [4000, 5000]
```

```bash
$ id
uid=1000 gid=3000 groups=3000,4000,5000
```

By default, the container runtime **also** merges in whatever groups the image's `/etc/group` associates with the user. `supplementalGroupsPolicy` controls that:

```yaml
spec:
  securityContext:
    supplementalGroups: [4000]
    # Merge  : union of the image's groups and the listed ones (default).
    # Strict : use ONLY the listed groups, ignore the image entirely.
    supplementalGroupsPolicy: Strict
```

`Strict` is the safer choice: it means the group membership is fully determined by the manifest and cannot be widened by rebuilding the image with extra `/etc/group` entries. Verify what actually landed:

```bash
kubectl get pod demo -o jsonpath='{.status.containerStatuses[0].user.linux}'
```

---

## Linux Capabilities

Capabilities split the historical all-or-nothing root privilege into roughly forty distinct units. The kernel checks a specific capability rather than "is UID 0".

### The Container Runtime Default Set

A container does **not** get all capabilities, even running as root. containerd grants a curated default set:

```
   DEFAULT SET GRANTED BY containerd/runc
   ──────────────────────────────────────
   CHOWN               DAC_OVERRIDE        FSETID
   FOWNER              MKNOD               NET_RAW
   SETGID              SETUID              SETFCAP
   SETPCAP             NET_BIND_SERVICE    SYS_CHROOT
   KILL                AUDIT_WRITE
```

Notably **absent** from the default set: `SYS_ADMIN`, `SYS_PTRACE`, `SYS_MODULE`, `NET_ADMIN`, `SYS_TIME`, `DAC_READ_SEARCH`. These are the dangerous ones, and you must ask for them explicitly.

### add and drop

```yaml
containers:
  - name: app
    securityContext:
      capabilities:
        # Remove everything, including the default set.
        drop: ["ALL"]
        # Then add back precisely what is needed.
        # Note: no CAP_ prefix in Kubernetes YAML.
        add: ["NET_BIND_SERVICE"]
```

Ordering is `drop` then `add`, so `drop: ["ALL"]` followed by `add: [...]` is the canonical minimal pattern. This is what the Restricted standard requires.

### The Capabilities Worth Knowing

| Capability | Grants | Risk |
|---|---|---|
| `NET_BIND_SERVICE` | Bind ports below 1024 | Low. The one you usually add back. |
| `CHOWN` | Change file ownership | Low to moderate |
| `DAC_OVERRIDE` | Bypass file permission checks | High. Read any file in the container. |
| `DAC_READ_SEARCH` | Bypass read and directory checks | High. Enables `open_by_handle_at` escapes. |
| `NET_RAW` | Raw sockets | Moderate. Enables ARP spoofing and packet crafting inside the pod network. |
| `NET_ADMIN` | Configure networking | High. CNI plugins need it; applications do not. |
| `SYS_PTRACE` | Trace other processes | High. Combined with `shareProcessNamespace` or `hostPID`, read other processes' memory. |
| `SYS_ADMIN` | Mount, pivot_root, and much more | **Critical. Effectively root.** The catch-all capability. |
| `SYS_MODULE` | Load kernel modules | **Critical. Direct kernel code execution.** |
| `SYS_TIME` | Set the system clock | High. The clock is shared with the host. |
| `SYS_BOOT` | Reboot the host | Critical |
| `MKNOD` | Create device nodes | High. Combined with `SYS_ADMIN`, mount the host disk. |
| `SETUID` / `SETGID` | Change process UID/GID | Moderate. Needed by anything that drops privileges. |

`NET_RAW` deserves a note: it is in the default set, and it allows a compromised pod to craft arbitrary packets and perform ARP spoofing against other pods on the same node. Dropping it is a cheap, high value hardening step, and it is why `drop: ["ALL"]` is preferable to dropping a handpicked list.

### Verifying What a Container Got

```bash
# From inside the container, if capsh is available
capsh --print

# The raw bitmask, always available
cat /proc/1/status | grep -E 'CapPrm|CapEff|CapBnd'
# CapBnd: 0000000000000000   ← all dropped, this is what you want

# Decode a bitmask
capsh --decode=00000000a80425fb

# From the node, authoritative
sudo crictl inspect $(sudo crictl ps --name app -q) \
  | jq '.info.runtimeSpec.process.capabilities'
```

A `CapBnd` of all zeros with `drop: ["ALL"]` is the goal. The bounding set is the ceiling: a process can never gain a capability outside it, even through a setuid binary.

---

## allowPrivilegeEscalation and no_new_privs

```yaml
containers:
  - name: app
    securityContext:
      allowPrivilegeEscalation: false
```

This sets the kernel's `no_new_privs` bit via `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`.

Once set, the bit:

- Is **inherited by every child process**, forever.
- **Cannot be unset**. It is a one-way latch.
- Causes the kernel to ignore setuid and setgid bits on executables.
- Prevents file capabilities from granting new privileges on `execve()`.

```
   WITHOUT no_new_privs                 WITH no_new_privs
   ────────────────────                 ─────────────────
   $ ls -l /usr/bin/sudo                $ ls -l /usr/bin/sudo
   -rwsr-xr-x root root                 -rwsr-xr-x root root
        ▲                                    ▲
        └ setuid bit honoured                └ setuid bit IGNORED

   $ sudo id                            $ sudo id
   uid=0(root)                          sudo: effective uid is not 0...
```

This closes an entire escalation class: an attacker who lands in a container as UID 1000 cannot use any setuid binary present in the image to become root, regardless of what the image contains.

### The Implicit True Cases

`allowPrivilegeEscalation` is forced to `true` and cannot be set false when:

- `privileged: true` is set.
- `CAP_SYS_ADMIN` is in the capability set.

The API server will reject the contradictory combination.

### What It Does Not Do

It does not stop a process that *already* has a capability from using it. It stops the *acquisition of new* privileges. A container running as root with `SYS_ADMIN` and `allowPrivilegeEscalation: false` is still extremely dangerous.

---

## privileged

```yaml
containers:
  - name: dangerous
    securityContext:
      privileged: true
```

This is not "a few more permissions". It is a near-complete removal of container isolation.

```
   privileged: true grants ALL of the following at once
   ────────────────────────────────────────────────────
   ✗ All Linux capabilities, including SYS_ADMIN and SYS_MODULE
   ✗ All host devices visible at /dev
   ✗ Seccomp filter set to Unconfined
   ✗ AppArmor profile set to unconfined
   ✗ SELinux label relaxed (spc_t on labelled systems)
   ✗ /sys and /proc mounted read-write
   ✗ Full write access to /sys/fs/cgroup
   ✗ allowPrivilegeEscalation forced to true
   ✗ Ability to mount filesystems, including the host root disk
```

### A Concrete Escape

The reason this is treated as equivalent to root on the node:

```bash
# Inside a privileged container
$ ls /dev/sda1                    # the host's root disk is visible
$ mkdir /host && mount /dev/sda1 /host
$ chroot /host

# You are now root on the node, with full filesystem access,
# including /etc/kubernetes/pki and every kubelet credential.
$ cat /etc/kubernetes/pki/ca.key
```

From there, forging a `system:masters` certificate is trivial, which is cluster takeover. See [certificates.md](certificates.md).

### Legitimate Uses

There genuinely are some, all infrastructure rather than application:

- CNI plugin DaemonSets (Calico, Cilium) configuring host networking.
- CSI node plugins performing mounts in the host mount namespace.
- Node monitoring and eBPF agents.
- `kube-proxy` manipulating iptables or IPVS.

Even these should use targeted capabilities rather than blanket `privileged` where the software supports it:

```yaml
# Better than privileged: true for a networking agent
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_ADMIN", "NET_RAW", "SYS_MODULE"]
```

Audit your cluster for privileged pods regularly:

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | . as $p
  | .spec.containers[]
  | select(.securityContext.privileged == true)
  | "\($p.metadata.namespace)/\($p.metadata.name)  container=\(.name)"'
```

---

## readOnlyRootFilesystem

```yaml
containers:
  - name: app
    securityContext:
      readOnlyRootFilesystem: true
```

Mounts the container's root filesystem read-only. The value is real: an attacker who achieves code execution cannot drop a persistent binary, modify a config file, or overwrite the application itself.

Most applications need *some* writable path, so pair it with `emptyDir` mounts:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-nginx
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101              # the nginx user in the official image
    fsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: nginx
      image: nginx:1.27
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
          # nginx.conf in the official image listens on 80.
          # Either add this, or change the config to a high port.
          add: ["NET_BIND_SERVICE"]
      volumeMounts:
        # Every path nginx needs to write must be mounted.
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
        - name: tmp
          mountPath: /tmp
      ports:
        - containerPort: 80
  volumes:
    - name: cache
      emptyDir:
        # Bound it. An unbounded emptyDir can fill the node's disk
        # and trigger eviction of every pod on it.
        sizeLimit: 100Mi
    - name: run
      emptyDir:
        sizeLimit: 10Mi
    - name: tmp
      emptyDir:
        sizeLimit: 50Mi
```

### Finding the Writable Paths an Image Needs

Rather than guessing, observe:

```bash
# Run with a read-only root and watch it fail, reading the error each time.
kubectl logs pod/hardened-nginx

# Or run the image locally and trace writes.
docker run --rm --read-only nginx:1.27
# nginx: [emerg] open() "/var/run/nginx.pid" failed (30: Read-only file system)
```

Common writable paths by workload type:

| Workload | Paths |
|---|---|
| nginx | `/var/cache/nginx`, `/var/run`, `/tmp` |
| Apache httpd | `/usr/local/apache2/logs`, `/tmp` |
| JVM | `/tmp` (for `hsperfdata` and temp files) |
| Python | `/tmp`, sometimes `~/.cache` |
| Most | `/tmp` at minimum |

Consider also setting `TMPDIR` via an env var to point at your mounted `emptyDir`, which handles libraries that hardcode temp file creation.

---

## procMount

```yaml
containers:
  - name: app
    securityContext:
      # Default    : mask sensitive /proc paths (the safe default).
      # Unmasked   : expose them. Requires the ProcMountType feature and
      #              is only meaningful in a user namespace.
      procMount: Default
```

With `Default`, the runtime masks a set of `/proc` paths that leak host information or allow host manipulation:

```
   MASKED (bind mounted to /dev/null or an empty dir)
   ─────────────────────────────────────────────────
   /proc/kcore              kernel memory image
   /proc/keys               kernel keyring
   /proc/timer_list         kernel timers
   /proc/sched_debug        scheduler internals
   /proc/scsi               SCSI devices
   /sys/firmware            firmware tables

   READ-ONLY
   ─────────
   /proc/bus  /proc/fs  /proc/irq  /proc/sys  /proc/sysrq-trigger
```

`Unmasked` removes that protection. Its legitimate use is running a nested container runtime inside a pod, and it should be paired with a user namespace. Treat it as a red flag in any application workload.

---

## seccomp

Seccomp filters which syscalls a process may make. A default Linux system exposes over 400 syscalls; a typical application uses perhaps 60. The rest are attack surface.

```yaml
spec:
  securityContext:
    seccompProfile:
      # RuntimeDefault : the container runtime's curated profile.
      # Unconfined     : no filtering at all.
      # Localhost      : a profile file on the node.
      type: RuntimeDefault
```

### The Three Types

**`RuntimeDefault`** applies containerd's default profile, which blocks roughly 60 dangerous syscalls while permitting everything a normal application needs. Blocked calls include `mount`, `umount2`, `reboot`, `kexec_load`, `init_module`, `delete_module`, `swapon`, `ptrace` (in older profiles), `bpf`, `perf_event_open`, `clock_settime` and `pivot_root`.

This should be your baseline everywhere. It rarely breaks anything and closes a large amount of kernel attack surface. The Restricted standard requires it.

**`Unconfined`** is the historical default when nothing is specified, which means most clusters run with no seccomp filtering at all. You can change that cluster-wide:

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Make RuntimeDefault the default for pods that specify nothing.
seccompDefault: true
```

```bash
sudo systemctl restart kubelet
```

**`Localhost`** points at a custom JSON profile on the node.

```yaml
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      # Relative to <kubelet-root-dir>/seccomp, which is normally
      # /var/lib/kubelet/seccomp
      localhostProfile: profiles/audit.json
```

### A Custom Profile

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_X32"
  ],
  "syscalls": [
    {
      "names": [
        "accept4", "access", "arch_prctl", "bind", "brk", "close",
        "connect", "epoll_create1", "epoll_ctl", "epoll_pwait",
        "execve", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getrandom", "listen", "lseek",
        "mmap", "mprotect", "munmap", "nanosleep", "openat",
        "read", "readlinkat", "rt_sigaction", "rt_sigprocmask",
        "sendto", "set_robust_list", "set_tid_address", "setsockopt",
        "socket", "stat", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

Actions available: `SCMP_ACT_ALLOW`, `SCMP_ACT_ERRNO` (return an error), `SCMP_ACT_KILL` (kill the process), `SCMP_ACT_LOG` (permit and log, invaluable for profiling), `SCMP_ACT_TRACE`, `SCMP_ACT_NOTIFY`.

Deploying the profile to every node is your problem. Options: a DaemonSet with a `hostPath` mount that copies files in, a node image build step, or the Security Profiles Operator which manages this properly and can also **record** a profile from a running workload.

### Building a Profile by Recording

Guessing a syscall list is hopeless. Record it instead. A log-everything profile:

```json
{
  "defaultAction": "SCMP_ACT_LOG"
}
```

Run the workload with it, exercise every code path, then read the kernel audit log:

```bash
sudo grep 'SECCOMP' /var/log/audit/audit.log | \
  grep -oP 'syscall=\K[0-9]+' | sort -un | \
  while read n; do ausyscall "$n"; done
```

The Security Profiles Operator automates exactly this with a `ProfileRecording` CRD.

### Verifying

```bash
# Inside the container. Mode 2 = filter active, 0 = disabled.
$ grep Seccomp /proc/1/status
Seccomp:	2
Seccomp_filters:	1

# From the node
sudo crictl inspect $(sudo crictl ps --name app -q) \
  | jq '.info.runtimeSpec.linux.seccomp.defaultAction'
```

---

## AppArmor

On Debian, Ubuntu and SUSE, AppArmor is the LSM in use. It restricts file paths, capabilities and network operations per profile.

The modern field (the annotation form is deprecated):

```yaml
spec:
  containers:
    - name: app
      securityContext:
        appArmorProfile:
          # RuntimeDefault : the container runtime's default profile.
          # Localhost      : a named profile loaded on the node.
          # Unconfined     : no AppArmor confinement.
          type: Localhost
          localhostProfile: k8s-nginx-restricted
```

Profiles must be loaded into the kernel on every node **before** a pod references them. Kubernetes does not distribute them.

```bash
# Check AppArmor is active
sudo aa-status
cat /sys/kernel/security/apparmor/profiles

# Load a profile
sudo apparmor_parser -r -W /etc/apparmor.d/k8s-nginx-restricted
```

An example profile:

```
#include <tunables/global>

profile k8s-nginx-restricted flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Deny all file writes by default.
  deny /** w,

  # Permit the specific paths nginx needs.
  /var/cache/nginx/** rw,
  /var/run/nginx.pid rw,
  /tmp/** rw,

  # Read the config and content.
  /etc/nginx/** r,
  /usr/share/nginx/** r,

  # Explicitly deny access to host credential material even if
  # some other control fails.
  deny /etc/kubernetes/** rwx,
  deny /var/lib/kubelet/** rwx,
  deny /proc/sys/** w,

  # Networking.
  network inet tcp,
  network inet udp,

  # No raw sockets.
  deny network raw,

  capability net_bind_service,
}
```

If a referenced profile is not loaded on the node the pod schedules to, the pod fails to start with a clear message. This makes AppArmor profiles a scheduling constraint in practice; label nodes that carry them.

---

## SELinux

On Red Hat family distributions, SELinux is the LSM. It applies a type label to processes and files, and the policy governs which types may interact.

```yaml
spec:
  securityContext:
    seLinuxOptions:
      level: "s0:c123,c456"
      # These are rarely set by hand; the defaults are almost always right.
      # user: "system_u"
      # role: "system_r"
      # type: "container_t"
```

The container runtime normally assigns a unique **MCS label** (the `level` field) per container automatically. Two containers with different categories cannot access each other's files even if UIDs and permissions would otherwise allow it. This is genuine, kernel-enforced isolation that does not depend on getting UIDs right.

The most common practical issue is a `hostPath` volume whose files carry a label the container type cannot read:

```bash
# On the node, check the label
ls -Z /srv/data

# Relabel for container access
sudo chcon -Rt container_file_type /srv/data

# Or persist it in the SELinux file context database
sudo semanage fcontext -a -t container_file_type '/srv/data(/.*)?'
sudo restorecon -Rv /srv/data
```

`seLinuxChangePolicy` (pod level) controls relabelling behaviour for volumes, and mirrors the `fsGroupChangePolicy` concern: recursive relabelling of a huge volume is slow. The `MountOption` policy passes the label as a mount option instead of walking the tree, which is dramatically faster where the filesystem supports it.

```yaml
spec:
  securityContext:
    seLinuxChangePolicy: MountOption
```

Check whether SELinux is enforcing:

```bash
getenforce
sudo ausearch -m avc -ts recent      # recent denials
```

---

## sysctls

Kernel parameters, applied to the pod's namespaces.

```yaml
spec:
  securityContext:
    sysctls:
      # Safe: namespaced, cannot affect the host or other pods.
      - name: net.ipv4.ip_local_port_range
        value: "1024 65535"
      - name: net.ipv4.tcp_syncookies
        value: "1"
```

### Safe vs Unsafe

A sysctl is **safe** if it is properly namespaced, meaning setting it in one pod cannot affect the host or any other pod. The safe list is small and fixed:

```
   net.ipv4.ip_local_port_range
   net.ipv4.ip_unprivileged_port_start
   net.ipv4.tcp_syncookies
   net.ipv4.ping_group_range
   net.ipv4.tcp_keepalive_time
   net.ipv4.tcp_fin_timeout
   net.ipv4.tcp_keepalive_intvl
   net.ipv4.tcp_keepalive_probes
   net.ipv4.tcp_rmem
   net.ipv4.tcp_wmem
```

Everything else is **unsafe** and rejected by the kubelet unless explicitly allowed. The most frequently wanted unsafe sysctl is `net.core.somaxconn` for high connection rate services.

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
allowedUnsafeSysctls:
  - "net.core.somaxconn"
  - "net.ipv4.tcp_max_syn_backlog"
```

```bash
sudo systemctl restart kubelet
```

Enable this only on specific nodes and taint them, so that arbitrary workloads do not land there. An unsafe sysctl can destabilise the node and every pod on it.

Note that `net.*` sysctls require the pod to have its own network namespace. With `hostNetwork: true` the pod shares the host's, and setting them is refused.

---

## Host Namespace Fields

These live directly on `spec`, not inside `securityContext`, but they are the most security-relevant fields in the whole pod spec.

```yaml
spec:
  # Pod uses the HOST network namespace. It sees every host interface,
  # binds host ports directly, and NetworkPolicy does not apply to it.
  hostNetwork: false

  # Pod sees every process on the host. Combined with SYS_PTRACE this
  # reads other processes' memory, including credentials.
  hostPID: false

  # Pod shares host IPC. Access to host shared memory segments.
  hostIPC: false

  # Pod uses the host user namespace. false enables a private user
  # namespace, mapping container root to an unprivileged host UID.
  hostUsers: true
```

```
   RISK OF EACH
   ────────────
   hostNetwork  ► bypasses NetworkPolicy entirely
                ► can bind to 0.0.0.0 on the node
                ► reaches services bound to node loopback,
                  including the kubelet's own read-only port
                ► can reach the cloud metadata endpoint

   hostPID      ► sees all host processes in /proc
                ► with SYS_PTRACE, reads their memory
                ► can signal host processes

   hostIPC      ► reads host shared memory segments,
                  which sometimes contain credentials

   hostUsers    ► true (default) means container UID 0 IS host UID 0
```

All three of `hostNetwork`, `hostPID` and `hostIPC` are forbidden by both the Baseline and Restricted Pod Security Standards. Audit for them:

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(.spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true)
  | "\(.metadata.namespace)/\(.metadata.name)  net=\(.spec.hostNetwork // false) pid=\(.spec.hostPID // false) ipc=\(.spec.hostIPC // false)"'
```

Related, and equally dangerous, is `hostPath` volumes. A `hostPath` mount of `/` or `/etc/kubernetes` is a direct path to node and cluster compromise. See [volumes.md](volumes.md).

---

## windowsOptions

For Windows nodes, a separate field set applies. Linux fields such as `runAsUser` and `capabilities` are meaningless there.

```yaml
securityContext:
  windowsOptions:
    # Run as a Windows user rather than a UID.
    runAsUserName: "ContainerUser"
    # Group Managed Service Account for domain authentication.
    gmsaCredentialSpecName: "webapp-gmsa"
    # Host process container. The Windows analogue of privileged.
    hostProcess: false
```

`hostProcess: true` runs directly on the host with host privileges and is the Windows equivalent of `privileged: true`. Treat it the same way.

---

## The Restricted Baseline

The exact `securityContext` required to pass Pod Security Standard `restricted`. Commit this to memory; it appears constantly.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: restricted-compliant
  namespace: production
spec:
  # ── POD LEVEL ────────────────────────────────────────────────────
  securityContext:
    # Must not run as UID 0.
    runAsNonRoot: true
    # Explicit UID so the kubelet does not have to resolve the image's USER.
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
    fsGroupChangePolicy: OnRootMismatch
    # Restricted requires RuntimeDefault or Localhost. Not Unconfined.
    seccompProfile:
      type: RuntimeDefault

  # Host namespaces forbidden.
  hostNetwork: false
  hostPID: false
  hostIPC: false

  containers:
    - name: app
      image: registry.internal.example.com/app:1.4.2
      # ── CONTAINER LEVEL ──────────────────────────────────────────
      securityContext:
        # The no_new_privs latch. Must be explicitly false.
        allowPrivilegeEscalation: false
        privileged: false
        readOnlyRootFilesystem: true
        capabilities:
          # ALL must be dropped. Only NET_BIND_SERVICE may be added back.
          drop: ["ALL"]
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 500m
          memory: 512Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp

  volumes:
    # Restricted permits only a safe subset of volume types.
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
```

The mandatory items, restated as a checklist:

```
   ☑ runAsNonRoot: true
   ☑ allowPrivilegeEscalation: false      (explicitly, not omitted)
   ☑ capabilities.drop: ["ALL"]
   ☑ seccompProfile.type: RuntimeDefault  (or Localhost)
   ☑ privileged: false or absent
   ☑ hostNetwork / hostPID / hostIPC absent or false
   ☑ no hostPath volumes
   ☑ no unsafe sysctls
   ☑ no /proc unmasked
```

Note that `readOnlyRootFilesystem` is **not** required by Restricted, though it is strongly recommended.

Full detail on the standards is in [pod-security-standards.md](pod-security-standards.md).

---

## Recipes

### Recipe: Audit Every Container's Security Posture

```bash
kubectl get pods -A -o json | jq -r '
  ["NAMESPACE","POD","CONTAINER","PRIV","ROOT","APE","CAPS","ROFS"],
  (.items[]
   | . as $p
   | .spec.containers[]
   | [
       $p.metadata.namespace,
       $p.metadata.name,
       .name,
       (.securityContext.privileged // false | tostring),
       (($p.spec.securityContext.runAsNonRoot // .securityContext.runAsNonRoot // false)
         | if . then "no" else "MAYBE" end),
       (.securityContext.allowPrivilegeEscalation // "unset" | tostring),
       ((.securityContext.capabilities.drop // []) | if index("ALL") then "dropALL" else "partial" end),
       (.securityContext.readOnlyRootFilesystem // false | tostring)
     ])
  | @tsv' | column -t
```

### Recipe: Hardening an Existing Deployment Incrementally

Do not attempt the full Restricted profile in one change. Layer it, testing after each step.

```bash
D=web
N=production

# Step 1: seccomp. Almost never breaks anything.
kubectl -n $N patch deploy $D --type=strategic -p '
spec:
  template:
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault'

# Step 2: drop capabilities and set no_new_privs.
kubectl -n $N patch deploy $D --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/securityContext",
   "value":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}
]'

# Step 3: non-root. Most likely to break. Check logs carefully.
kubectl -n $N patch deploy $D --type=strategic -p '
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000'

# Step 4: read-only root. Add emptyDir mounts as failures appear.
kubectl -n $N patch deploy $D --type=strategic -p '
spec:
  template:
    spec:
      containers:
        - name: app
          securityContext:
            readOnlyRootFilesystem: true'

kubectl -n $N rollout status deploy/$D
```

### Recipe: A Debug Pod That Can Actually Debug

Sometimes you need the opposite of hardening. Confine it to a dedicated namespace exempt from Pod Security.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: node-debug
  namespace: kube-system
spec:
  # Full host visibility.
  hostNetwork: true
  hostPID: true
  hostIPC: true
  nodeName: worker-01           # pin to the node under investigation
  tolerations:
    - operator: Exists          # schedule despite any taint
  containers:
    - name: shell
      image: nicolaka/netshoot:latest
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /
```

```bash
kubectl -n kube-system exec -it node-debug -- chroot /host bash
# Delete it the moment you are finished.
kubectl -n kube-system delete pod node-debug --force --grace-period=0
```

### Recipe: Find Images That Refuse to Run Non-Root

```bash
# Inspect the USER directive without running anything.
for img in nginx:1.27 redis:7 postgres:16 python:3.12-slim; do
  u=$(docker inspect "$img" --format '{{.Config.User}}' 2>/dev/null)
  printf '%-24s USER=%s\n' "$img" "${u:-<root>}"
done
```

Images with an empty `USER` run as root by default and need an explicit `runAsUser` in the pod spec. Images with a *named* user need an explicit numeric `runAsUser` too, because `runAsNonRoot` cannot validate a name.

---

## Command Reference

```bash
# ---------- Inspect what a running container actually got ----------
kubectl exec POD -- id
kubectl exec POD -- cat /proc/1/status | grep -E 'Cap|Seccomp|NoNewPrivs'
kubectl exec POD -- capsh --print
kubectl exec POD -- touch /test          # tests readOnlyRootFilesystem
kubectl exec POD -- ls -ld /data         # tests fsGroup

# ---------- From the node, authoritative ----------
sudo crictl ps
sudo crictl inspect CID | jq '.info.runtimeSpec.process'
sudo crictl inspect CID | jq '.info.runtimeSpec.process.capabilities'
sudo crictl inspect CID | jq '.info.runtimeSpec.linux.seccomp'
sudo crictl inspect CID | jq '.info.runtimeSpec.linux.namespaces'

# ---------- Effective spec ----------
kubectl get pod POD -o jsonpath='{.spec.securityContext}' | jq
kubectl get pod POD -o jsonpath='{.spec.containers[*].securityContext}' | jq
kubectl get pod POD -o jsonpath='{.status.containerStatuses[0].user}' | jq

# ---------- Capability decoding ----------
capsh --decode=00000000a80425fb
capsh --print

# ---------- LSM status ----------
sudo aa-status
cat /sys/kernel/security/apparmor/profiles
getenforce
sudo ausearch -m avc -ts recent

# ---------- seccomp ----------
grep Seccomp /proc/1/status
ls /var/lib/kubelet/seccomp/

# ---------- kubelet configuration ----------
sudo cat /var/lib/kubelet/config.yaml | grep -E 'seccompDefault|allowedUnsafeSysctls'

# ---------- Test before applying ----------
kubectl apply -f pod.yaml --dry-run=server
```

---

## Troubleshooting

### `CreateContainerConfigError: container has runAsNonRoot and image will run as root`

The image runs as root and you asked for non-root without providing a UID.

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000        # add this
```

If the application genuinely needs to own files created at build time, rebuild the image with the right ownership rather than reverting to root:

```dockerfile
FROM nginx:1.27
RUN chown -R 1000:1000 /var/cache/nginx /var/log/nginx
USER 1000
```

### `Permission denied` Writing to a Mounted Volume

Diagnose in order:

```bash
# 1. What identity is the process?
kubectl exec POD -- id

# 2. What does the mount look like?
kubectl exec POD -- ls -ld /data

# 3. Is fsGroup set?
kubectl get pod POD -o jsonpath='{.spec.securityContext.fsGroup}'
```

If `fsGroup` is absent, add it. If it is present but ownership did not change, the volume type does not support it (`hostPath`, or a CSI driver with `fsGroupPolicy: None`). For NFS, fix ownership on the server side.

### Pod Stuck in `ContainerCreating` for Minutes with a Large Volume

The recursive `fsGroup` chown.

```bash
kubectl describe pod POD | tail -20
# On the node:
sudo journalctl -u kubelet -f | grep -i 'chown\|SetVolumeOwnership'
```

Fix:

```yaml
spec:
  securityContext:
    fsGroup: 2000
    fsGroupChangePolicy: OnRootMismatch
```

### `Operation not permitted` on a Syscall

Either a dropped capability or seccomp.

```bash
# Capabilities: is the bounding set empty?
kubectl exec POD -- grep CapBnd /proc/1/status

# Seccomp: is a filter loaded?
kubectl exec POD -- grep Seccomp /proc/1/status

# Which syscall? strace needs SYS_PTRACE, so this is a diagnostic-only pod.
kubectl exec POD -- strace -f -e trace=all -p 1
```

Binding to port 80 as non-root is the classic case:

```yaml
capabilities:
  drop: ["ALL"]
  add: ["NET_BIND_SERVICE"]
```

Better still, configure the application to listen above 1024 and let the Service map port 80 to it. Then no capability is needed at all.

### `Read-only file system`

```bash
kubectl logs POD | grep -i 'read-only'
# nginx: [emerg] open() "/var/run/nginx.pid" failed (30: Read-only file system)
```

Mount an `emptyDir` at the offending path. Iterate until the application starts.

### `cannot set sysctl ... not allowlisted`

```
forbidden sysctl: "net.core.somaxconn" not allowlisted
```

Add it to `allowedUnsafeSysctls` in the kubelet config on the nodes concerned, restart the kubelet, and taint those nodes so unrelated workloads do not land there.

### AppArmor Profile Not Found

```
Pod Cannot enforce AppArmor: profile "k8s-nginx" is not loaded
```

The profile is not loaded on the node the pod scheduled to. Load it everywhere, or label the nodes that have it and add a `nodeSelector`.

```bash
sudo apparmor_parser -r -W /etc/apparmor.d/k8s-nginx
kubectl label node worker-01 apparmor-profile/k8s-nginx=loaded
```

### Everything Looks Right But the Field Is Ignored

Check you put it at the correct scope. `capabilities` at pod level and `fsGroup` at container level are both schema errors, but a field silently absent from the stored object usually means it went to a place the schema pruned.

```bash
# Compare submitted with stored
kubectl get pod POD -o yaml | grep -A 15 securityContext
```

---

## Exam and Interview Traps

1. **`runAsNonRoot: true` with no `runAsUser`, image has `USER nginx`.** Fails with `CreateContainerConfigError`. The kubelet cannot resolve a *name* to a UID, only numbers.

2. **Does `runAsNonRoot` pick a UID?** No. It is purely a gate. It refuses to start a container whose effective UID would be 0.

3. **Where does `fsGroup` go?** Pod level only. It is a schema error at container level.

4. **Where does `capabilities` go?** Container level only.

5. **Does a container running as root have all capabilities?** No. The runtime grants a curated default set of about 14. `SYS_ADMIN` and `SYS_MODULE` are not among them.

6. **What does `allowPrivilegeEscalation: false` actually set?** The kernel's `no_new_privs` bit via `prctl`. It makes setuid binaries ineffective and is inherited by all children, irreversibly.

7. **Why is `privileged: true` equivalent to root on the node?** It grants all capabilities plus all host devices plus unconfined seccomp and LSM. `mount /dev/sda1 && chroot` gives full host filesystem access, including the cluster CA key.

8. **Container UID 1000, what is the host UID?** Also 1000, unless `hostUsers: false` enables a user namespace. There is no translation by default.

9. **Pod stuck in ContainerCreating with a large PVC.** Recursive `fsGroup` chown. Set `fsGroupChangePolicy: OnRootMismatch`.

10. **Which four things does Restricted require in securityContext?** `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile.type: RuntimeDefault`.

11. **Is `readOnlyRootFilesystem` required by Restricted?** No. Recommended, not required.

12. **What is the default seccomp profile for a pod that specifies nothing?** `Unconfined`, unless the kubelet sets `seccompDefault: true`.

13. **Container-level and pod-level both set `runAsUser`. Which wins?** Container. There is no merging, it is a whole-field override.

14. **Which sysctls can any pod set?** Only the safe, namespaced list (mostly `net.ipv4.*` connection tuning). Everything else needs `allowedUnsafeSysctls` on the kubelet.

15. **Why is dropping `NET_RAW` worthwhile?** It is in the default set and permits raw sockets, enabling ARP spoofing and packet crafting against other pods on the node.

16. **Are `hostNetwork` and `hostPID` inside `securityContext`?** No. They are fields directly on `spec`.

17. **Does `hostNetwork: true` affect NetworkPolicy?** Yes. The pod uses the host network namespace, so pod-level NetworkPolicy does not apply to it.

---

## Related Topics

- [pod-security-standards.md](pod-security-standards.md) for the profiles that enforce these fields
- [admission-controllers.md](admission-controllers.md) for the PodSecurity admission controller
- [linux-namespaces.md](linux-namespaces.md) for the isolation primitives underneath
- [cgroups.md](cgroups.md) for the resource side of container confinement
- [containers.md](containers.md) for how images and runtimes fit together
- [container-runtime.md](container-runtime.md) for CRI and containerd
- [runtime-class.md](runtime-class.md) for stronger isolation with gVisor and Kata
- [pods.md](pods.md) for the full pod spec
- [volumes.md](volumes.md) for hostPath risks and volume ownership
- [cluster-hardening.md](cluster-hardening.md) for the wider posture
- [image-security.md](image-security.md) for building images that run non-root cleanly

---

## Key Takeaways

- There are two `securityContext` blocks with different schemas. Pod level sets defaults and owns `fsGroup`, `supplementalGroups` and `sysctls`. Container level owns `capabilities`, `privileged`, `allowPrivilegeEscalation` and `readOnlyRootFilesystem`.
- Container level overrides pod level wholesale. There is no field merging.
- Without user namespaces, container UID equals host UID. Container root is host root, restrained only by capabilities, seccomp and namespaces.
- `runAsNonRoot` validates, it does not assign. Always pair it with a numeric `runAsUser`.
- Containers get a curated default capability set, not all capabilities. `drop: ["ALL"]` then adding back is the correct pattern.
- `allowPrivilegeEscalation: false` sets `no_new_privs`, neutralising every setuid binary in the image, permanently and for all children.
- `privileged: true` is equivalent to root on the node. Mounting the host disk and chrooting is a two-command escape.
- `fsGroup` recursively chowns the volume on every mount. Use `fsGroupChangePolicy: OnRootMismatch` on anything large.
- `seccompProfile: RuntimeDefault` is cheap, rarely breaks anything, and removes a large amount of kernel attack surface. Make it the cluster default with `seccompDefault: true`.
- `hostNetwork`, `hostPID`, `hostIPC` and `hostPath` live on `spec`, not in `securityContext`, and are the highest risk fields in the pod spec.
- Restricted compliance is four fields: `runAsNonRoot`, `allowPrivilegeEscalation: false`, `drop: ["ALL"]`, `seccompProfile: RuntimeDefault`.

---

## References

- [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Seccomp with Kubernetes](https://kubernetes.io/docs/tutorials/security/seccomp/)
- [Restrict a Container's Access to Resources with AppArmor](https://kubernetes.io/docs/tutorials/security/apparmor/)
- [Assign SELinux Labels to a Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#assign-selinux-labels-to-a-container)
- [Using sysctls in a Kubernetes Cluster](https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/)
- [User Namespaces](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/)
- [Configure Volume Permission and Ownership Change Policy](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#configure-volume-permission-and-ownership-change-policy-for-pods)
- [OCI Runtime Specification](https://github.com/opencontainers/runtime-spec/blob/main/config.md)
- [capabilities(7) Linux Manual Page](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [seccomp(2) Linux Manual Page](https://man7.org/linux/man-pages/man2/seccomp.2.html)
