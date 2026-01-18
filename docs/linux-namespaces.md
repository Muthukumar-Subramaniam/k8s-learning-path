# 🔒 Linux Namespaces: Deep Dive with Practical Examples

A comprehensive guide to understanding Linux namespaces from the kernel level to containers and Kubernetes.

## 📋 Table of Contents
- [What Are Linux Namespaces?](#what-are-linux-namespaces)
- [The 8 Namespace Types](#the-8-namespace-types)
- [Viewing Namespaces](#viewing-namespaces)
- [Creating and Managing Namespaces](#creating-and-managing-namespaces)
- [PID Namespace (Process Isolation)](#pid-namespace-process-isolation)
- [Network Namespace (Network Isolation)](#network-namespace-network-isolation)
- [Mount Namespace (Filesystem Isolation)](#mount-namespace-filesystem-isolation)
- [UTS Namespace (Hostname Isolation)](#uts-namespace-hostname-isolation)
- [IPC Namespace (Inter-Process Communication)](#ipc-namespace-inter-process-communication)
- [User Namespace (UID/GID Mapping)](#user-namespace-uidgid-mapping)
- [Cgroup Namespace](#cgroup-namespace)
- [Time Namespace](#time-namespace)
- [Namespaces in Containers](#namespaces-in-containers)
- [Namespaces in Kubernetes](#namespaces-in-kubernetes)
- [Advanced Topics](#advanced-topics)
- [Troubleshooting](#troubleshooting)

---

## What Are Linux Namespaces?

**Linux namespaces** are a kernel feature that provides isolation by creating separate instances of global system resources. They make processes think they have their own isolated instance of the resource.

### The Core Concept: Virtualization of Global Resources

In traditional Unix/Linux, certain resources are **global** and shared by all processes:
- All processes see the same process tree (PIDs)
- All processes share the same network stack
- All processes see the same mounted filesystems
- All processes share the same hostname

**Namespaces break this assumption.** They virtualize these global resources so different groups of processes can have different views.

### How Namespaces Work at Kernel Level

```
┌─────────────────────────────────────────────────────────────┐
│                    Linux Kernel                             │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │         Global Resource (before namespaces)          │   │
│  │  All processes → Same view of system                 │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│                         ↓ With Namespaces ↓                 │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │   Namespace-aware Resource Management                │   │
│  │                                                      │   │
│  │   ┌────────────┐  ┌────────────┐  ┌────────────┐    │   │
│  │   │ NS Instance│  │ NS Instance│  │ NS Instance│    │   │
│  │   │     A      │  │     B      │  │     C      │    │   │
│  │   └────────────┘  └────────────┘  └────────────┘    │   │
│  │         ↑               ↑               ↑           │   │
│  │         │               │               │           │   │
│  │   Process Group   Process Group   Process Group     │   │
│  │   sees only A     sees only B     sees only C       │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Visual Example: PID Namespace Isolation

```
┌─────────────────────────────────────────────────────────────┐
│                    Host System                              │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ Namespace A  │  │ Namespace B  │  │ Namespace C  │      │
│  │              │  │              │  │              │      │
│  │ Process 1    │  │ Process 10   │  │ Process 20   │      │
│  │ Process 2    │  │ Process 11   │  │ Process 21   │      │
│  │              │  │              │  │              │      │
│  │ PIDs: 1, 2   │  │ PIDs: 1, 2   │  │ PIDs: 1, 2   │      │
│  │              │  │              │  │              │      │
│  │ (sees own    │  │ (sees own    │  │ (sees own    │      │
│  │  processes)  │  │  processes)  │  │  processes)  │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                             │
│  Host kernel sees ALL processes with real PIDs              │
│  Process 1 → PID 12345, Process 2 → PID 12346, etc.        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### How Processes Join Namespaces

Every process belongs to exactly **one namespace of each type**. When a process is created:

1. **By default**: Inherits all parent's namespaces
2. **With `clone()` + flags**: Creates new namespace(s)
3. **With `unshare()`**: Moves to new namespace(s)
4. **With `setns()`**: Joins existing namespace(s)

```
┌─────────────────────────────────────────────────────────────┐
│                Process Namespace Assignment                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Parent Process                                             │
│  ├─ PID NS:  4026531836                                     │
│  ├─ NET NS:  4026531840                                     │
│  ├─ MNT NS:  4026531841                                     │
│  └─ ...                                                     │
│                                                             │
│         │                                                   │
│         │ fork() → Child inherits all namespaces            │
│         ▼                                                   │
│                                                             │
│  Child Process (Same namespaces)                            │
│  ├─ PID NS:  4026531836  ← Same                             │
│  ├─ NET NS:  4026531840  ← Same                             │
│  ├─ MNT NS:  4026531841  ← Same                             │
│  └─ ...                                                     │
│                                                             │
│         │                                                   │
│         │ unshare(CLONE_NEWNET) → New network namespace     │
│         ▼                                                   │
│                                                             │
│  Same Process (Modified namespaces)                         │
│  ├─ PID NS:  4026531836  ← Same                             │
│  ├─ NET NS:  4026532450  ← NEW!                             │
│  ├─ MNT NS:  4026531841  ← Same                             │
│  └─ ...                                                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Namespace Lifecycle and Reference Counting

Namespaces use **reference counting** for lifecycle management:

```
┌─────────────────────────────────────────────────────────────┐
│              Namespace Lifecycle                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Creation:                                                  │
│  ┌──────────────────────────────────────────┐               │
│  │ Process calls clone(CLONE_NEWPID)        │               │
│  │ Kernel creates new PID namespace         │               │
│  │ Reference count = 1                      │               │
│  └──────────────────────────────────────────┘               │
│                                                             │
│  Reference Increment:                                       │
│  ┌──────────────────────────────────────────┐               │
│  │ • New process joins namespace → +1       │               │
│  │ • Namespace fd opened → +1               │               │
│  │ • Namespace bind-mounted → +1            │               │
│  └──────────────────────────────────────────┘               │
│                                                             │
│  Reference Decrement:                                       │
│  ┌──────────────────────────────────────────┐               │
│  │ • Process exits → -1                     │               │
│  │ • Namespace fd closed → -1               │               │
│  │ • Bind-mount removed → -1                │               │
│  └──────────────────────────────────────────┘               │
│                                                             │
│  Destruction:                                               │
│  ┌──────────────────────────────────────────┐               │
│  │ When reference count reaches 0:          │               │
│  │ Kernel automatically destroys namespace  │               │
│  └──────────────────────────────────────────┘               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Why Namespaces Matter

- **Containers** = Linux processes + namespaces + cgroups
- **Security isolation** - processes can't see or affect others
- **Resource isolation** - each namespace has its own view
- **Multi-tenancy** - run multiple isolated environments on one host

### Namespace Implementation in Task Struct

In the Linux kernel, each process (represented by `task_struct`) has a pointer to its namespace structure:

```c
// Simplified kernel structure
struct task_struct {
    ...
    struct nsproxy *nsproxy;  // Points to namespace proxy
    ...
};

struct nsproxy {
    struct uts_namespace *uts_ns;
    struct ipc_namespace *ipc_ns;
    struct mnt_namespace *mnt_ns;
    struct pid_namespace *pid_ns_for_children;
    struct net           *net_ns;
    struct cgroup_namespace *cgroup_ns;
    struct time_namespace *time_ns;
    struct time_namespace *time_ns_for_children;
};
```

When kernel functions need to access a resource (e.g., list processes), they:
1. Look at the calling process's `nsproxy`
2. Find the appropriate namespace
3. Only show resources belonging to that namespace

---

## The 8 Namespace Types

| Namespace | Kernel Flag | Isolates | Added in Kernel |
|-----------|-------------|----------|-----------------|
| **PID** | `CLONE_NEWPID` | Process IDs, process tree | Linux 2.6.24 (2008) |
| **NET** | `CLONE_NEWNET` | Network stack (interfaces, routing, firewall) | Linux 2.6.29 (2009) |
| **MNT** | `CLONE_NEWNS` | Mount points, filesystems | Linux 2.4.19 (2002) |
| **UTS** | `CLONE_NEWUTS` | Hostname and domain name | Linux 2.6.19 (2006) |
| **IPC** | `CLONE_NEWIPC` | System V IPC, POSIX message queues | Linux 2.6.19 (2006) |
| **USER** | `CLONE_NEWUSER` | User and group IDs | Linux 3.8 (2013) |
| **CGROUP** | `CLONE_NEWCGROUP` | Cgroup root directory | Linux 4.6 (2016) |
| **TIME** | `CLONE_NEWTIME` | System clocks | Linux 5.6 (2020) |

---

## Viewing Namespaces

### List All Namespaces

```bash
# List all namespaces on the system
lsns

# Output format:
#         NS TYPE   NPROCS     PID USER     COMMAND
# 4026531834 time        2 3440874 musubram -bash
# 4026531835 cgroup      2 3440874 musubram -bash
# 4026531836 pid         2 3440874 musubram -bash
```

### List Specific Namespace Type

```bash
# List PID namespaces
lsns -t pid

# List network namespaces
lsns -t net

# List mount namespaces
lsns -t mnt

# List all types
lsns -t uts
lsns -t ipc
lsns -t user
lsns -t cgroup
lsns -t time
```

### View Current Process Namespaces

```bash
# Show namespace IDs for current shell
ls -la /proc/$$/ns/

# Output:
# lrwxrwxrwx. 1 user user 0 Jan 18 12:00 cgroup -> 'cgroup:[4026531835]'
# lrwxrwxrwx. 1 user user 0 Jan 18 12:00 ipc -> 'ipc:[4026531839]'
# lrwxrwxrwx. 1 user user 0 Jan 18 12:00 mnt -> 'mnt:[4026531841]'
# lrwxrwxrwx. 1 user user 0 Jan 18 12:00 net -> 'net:[4026531840]'
# lrwxrwxrwx. 1 user user 0 Jan 18 12:00 pid -> 'pid:[4026531836]'
# lrwxrwxrwx. 1 user user 0 Jan 18 12:00 time -> 'time:[4026531834]'
# lrwxrwxrwx. 1 user user 0 Jan 18 12:00 user -> 'user:[4026531837]'
# lrwxrwxrwx. 1 user user 0 Jan 18 12:00 uts -> 'uts:[4026531838]'

# View namespaces for specific process
ls -la /proc/<PID>/ns/

# View namespaces for PID 1 (init)
ls -la /proc/1/ns/
```

### Compare Namespaces

```bash
# Your shell's namespaces
readlink /proc/$$/ns/*

# Another process's namespaces
readlink /proc/1/ns/*

# Check if two processes share a namespace
# If the namespace ID is the same, they share it
readlink /proc/$$/ns/net
readlink /proc/1/ns/net
```

### View Processes in a Namespace

```bash
# Show all processes with namespace info
ps -eo pid,pidns,netns,userns,comm

# Find processes in a specific namespace
lsns -o NS,TYPE,NPROCS,PID,USER,COMMAND -t pid

# More detailed view
sudo lsns -p <PID>
```

---

## Creating and Managing Namespaces

### The `unshare` Command

Creates new namespaces and executes a program in them.

```bash
# General syntax
unshare [options] <program> [arguments]

# Create all new namespaces
sudo unshare --fork --pid --net --mount --uts --ipc bash

# Create only specific namespaces
unshare --pid --fork bash
unshare --net bash
unshare --mount bash
```

### The `nsenter` Command

Enters existing namespaces and runs a program.

```bash
# General syntax
nsenter [options] <program> [arguments]

# Enter all namespaces of a process
sudo nsenter --target <PID> --all bash

# Enter specific namespaces
sudo nsenter --target <PID> --net bash
sudo nsenter --target <PID> --pid --fork bash

# Enter container namespaces
sudo nsenter --target $(docker inspect -f '{{.State.Pid}}' container-name) --all bash
```

### IP Netns (Network Namespace Tool)

```bash
# List network namespaces
ip netns list

# Add a network namespace
sudo ip netns add myns

# Execute command in network namespace
sudo ip netns exec myns <command>
sudo ip netns exec myns bash
sudo ip netns exec myns ip addr

# Delete network namespace
sudo ip netns delete myns
```

---

## PID Namespace (Process Isolation)

### Understanding PID Namespace

The **PID namespace** virtualizes the process ID number space. This is one of the most important namespaces because it creates true process isolation.

### How It Works

1. **Each PID namespace has its own numbering** starting from PID 1
2. **Parent namespace can see child namespaces** but not vice versa
3. **PID mapping happens transparently** by the kernel
4. **Init process (PID 1) is special** - if it dies, all processes in namespace are killed

```
┌─────────────────────────────────────────────────────────────┐
│                    PID Namespace Hierarchy                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Host PID Namespace (Root)                                  │
│  ┌────────────────────────────────────────────────────┐     │
│  │  PID 1: systemd (init)                             │     │
│  │  PID 100: sshd                                     │     │
│  │  PID 1234: bash (parent)                           │     │
│  │  PID 1235: ├─ unshare (creates child namespace)   │     │
│  │  PID 1236: │  └─ bash (child, appears as PID 1)   │     │
│  │  PID 1237: │     └─ sleep (appears as PID 2)      │     │
│  │  PID 5000: httpd                                   │     │
│  └────────────────────────────────────────────────────┘     │
│                    ▲                                        │
│                    │ Can see all                            │
│                    │                                        │
│  Child PID Namespace                                        │
│  ┌────────────────────────────────────────────────────┐     │
│  │  PID 1: bash (actually host PID 1236)              │     │
│  │  PID 2: sleep (actually host PID 1237)             │     │
│  │                                                    │     │
│  │  Cannot see host PIDs 1, 100, 1234, 5000          │     │
│  │  Isolated view - only sees processes in namespace  │     │
│  └────────────────────────────────────────────────────┘     │
│                    ▼                                        │
│              Cannot see parent                              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Kernel Implementation Details

When a process in a PID namespace calls `getpid()`:

1. **Kernel looks up calling process's PID namespace**
2. **Translates host PID to namespace PID**
3. **Returns namespace-local PID**

```
Example:
- Host sees process as PID 1236
- Namespace sees same process as PID 1
- Kernel maintains mapping: Host PID → Namespace PID
- Translation happens in kernel space, transparent to process
```

### PID Namespace Hierarchy

PID namespaces form a **tree hierarchy** (unlike other namespaces which are flat):

```
┌─────────────────────────────────────────────────────────────┐
│              PID Namespace Tree                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│                    Root PID NS                              │
│                    (Host PIDs)                              │
│                         │                                   │
│         ┌───────────────┼───────────────┐                   │
│         │               │               │                   │
│      Child A         Child B         Child C                │
│    (Container 1)   (Container 2)   (Container 3)            │
│         │                               │                   │
│         │                               │                   │
│    Grand-child A1                  Grand-child C1           │
│   (Nested container)               (Nested container)       │
│                                                             │
│  Rules:                                                     │
│  • Parent can see all descendant processes                  │
│  • Child can only see own and descendant processes          │
│  • Siblings cannot see each other                           │
│  • PIDs are unique within each level                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Why PID 1 is Special

In each PID namespace, **PID 1 has special responsibilities**:

1. **Reaps zombie processes** - becomes parent of orphaned processes
2. **Signal handling** - some signals are blocked (can't be killed easily)
3. **Namespace termination** - if PID 1 exits, kernel kills all processes in namespace

```
┌─────────────────────────────────────────────────────────────┐
│            PID 1 Responsibilities                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Scenario: Process creates child then exits                 │
│                                                             │
│  Without PID namespace (host):                              │
│  Process 1000 → creates → Process 1001                      │
│  Process 1000 exits → Process 1001 reparented to PID 1      │
│  PID 1 (systemd) reaps zombie when Process 1001 exits       │
│                                                             │
│  With PID namespace:                                        │
│  Container PID 5 → creates → Container PID 6                │
│  Container PID 5 exits → Container PID 6 reparented to PID 1 │
│  Container PID 1 must reap zombie when PID 6 exits          │
│                                                             │
│  If container PID 1 doesn't reap zombies:                   │
│  • Zombies accumulate                                       │
│  • Resource exhaustion                                      │
│  • Container health issues                                  │
│                                                             │
│  This is why containers often use:                          │
│  • tini                                                     │
│  • dumb-init                                                │
│  • Proper init systems                                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Practical Examples

```bash
# Create a new PID namespace
sudo unshare --fork --pid --mount-proc bash

# Inside the new namespace:
ps aux
# You'll see only bash as PID 1!

# Check PID from host perspective (different terminal)
ps aux | grep bash
# Shows the real PID (e.g., 12345)
```

### PID Namespace Isolation Test

```bash
# Terminal 1: Create isolated PID namespace
sudo unshare --fork --pid --mount-proc bash

# Inside namespace:
echo $$        # Shows PID 1
ps aux         # Shows only processes in this namespace
sleep 1000 &   # Background process

# Terminal 2: On host
ps aux | grep sleep
# You'll see the sleep process with a different PID (e.g., 12346)

# Can't see host processes from namespace
# Can see namespace processes from host
```

### PID Namespace Hierarchy

```bash
# Parent namespace can see child namespaces
# Child namespace CANNOT see parent or sibling namespaces

# Check namespace hierarchy
cat /proc/$$/status | grep NSpid
# Shows PIDs at each level of the hierarchy
```

---

## Network Namespace (Network Isolation)

### Understanding Network Namespace

The **network namespace** virtualizes the entire network stack. Each network namespace gets its own:
- Network interfaces (including loopback)
- IP addresses
- Routing tables
- Firewall rules (iptables/nftables)
- Network statistics
- Port number space

###

 How It Works

When a network namespace is created:

1. **Starts with only loopback** (`lo`) interface (down by default)
2. **Completely isolated network stack** - can't communicate with host or other namespaces
3. **Needs connectivity setup** - requires veth pairs, bridges, or other mechanisms

```
┌─────────────────────────────────────────────────────────────┐
│              Network Namespace Architecture                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Host Network Namespace                              │    │
│  │                                                     │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │    │
│  │  │   eth0   │  │   br0    │  │   lo     │          │    │
│  │  │192.168.1 │  │172.17.0.1│  │127.0.0.1 │          │    │
│  │  └────┬─────┘  └────┬─────┘  └──────────┘          │    │
│  │       │             │                               │    │
│  │       │    ┌────────┴──────┐                        │    │
│  │       │    │               │                        │    │
│  │    Physical  veth0-host veth1-host                  │    │
│  │    Network      │            │                      │    │
│  └─────────────────┼────────────┼──────────────────────┘    │
│                    │            │                           │
│                    │            │                           │
│  ┌─────────────────┼────────────┼──────────────────────┐    │
│  │ Container Net NS│            │                      │    │
│  │                 │            │                      │    │
│  │          veth0-container  veth1-container           │    │
│  │          172.17.0.2/16    172.18.0.2/16            │    │
│  │                 │            │                      │    │
│  │            Container A   Container B                │    │
│  │           (Can see eth0) (Can see eth0)            │    │
│  │                                                     │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  Each namespace has completely independent:                 │
│  • IP routing tables                                        │
│  • Firewall rules                                           │
│  • Network device configurations                            │
│  • Socket connections                                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Virtual Ethernet (veth) Pairs

The primary mechanism for connecting network namespaces:

```
┌─────────────────────────────────────────────────────────────┐
│                  veth Pair Concept                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  veth = Virtual Ethernet pair                               │
│  Like a virtual network cable with two ends                 │
│                                                             │
│  ┌───────────────────────┐    ┌───────────────────────┐     │
│  │  Network Namespace A  │    │  Network Namespace B  │     │
│  │                       │    │                       │     │
│  │      ┌────────┐       │    │       ┌────────┐      │     │
│  │      │ veth0  │◄──────┼────┼──────►│ veth1  │      │     │
│  │      │(one end)       │    │       │(other end)    │     │
│  │      └────────┘       │    │       └────────┘      │     │
│  │   192.168.1.1/24      │    │    192.168.1.2/24     │     │
│  │                       │    │                       │     │
│  └───────────────────────┘    └───────────────────────┘     │
│                                                             │
│  Packets sent to veth0 appear on veth1                      │
│  Packets sent to veth1 appear on veth0                      │
│  Bidirectional pipe between namespaces                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Network Isolation Mechanics

When a process makes a network operation (e.g., `bind()` a socket):

1. **Kernel checks process's network namespace**
2. **Looks up available interfaces in that namespace**
3. **Allocates port from that namespace's port space**
4. **Creates socket bound to that namespace**

```
Example: Two containers binding to port 80

Container A (netns A):
- bind(0.0.0.0:80) → Success
- Listens on port 80 in its namespace

Container B (netns B):
- bind(0.0.0.0:80) → Success
- Also listens on port 80 in its namespace

No conflict! Different namespaces = different port spaces
```

### Container Networking Pattern (Docker-style)

```
┌─────────────────────────────────────────────────────────────┐
│          Typical Container Networking Setup                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Host                                                       │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Physical: eth0 (192.168.1.100)                      │   │
│  │            │                                         │   │
│  │            │  NAT/Masquerade (iptables)              │   │
│  │            │                                         │   │
│  │         docker0 bridge (172.17.0.1/16)               │   │
│  │            │                                         │   │
│  │    ┌───────┼────────┬────────────┐                   │   │
│  │    │       │        │            │                   │   │
│  │  veth0   veth1    veth2       veth3                  │   │
│  └────┼───────┼────────┼────────────┼───────────────────┘   │
│       │       │        │            │                       │
│  ┌────┼───────┼────────┼────────────┼───────────────────┐   │
│  │    │       │        │            │                   │   │
│  │  Container Namespaces                                │   │
│  │    │       │        │            │                   │   │
│  │   NS1     NS2      NS3          NS4                  │   │
│  │   eth0    eth0     eth0         eth0                 │   │
│  │ .17.0.2  .17.0.3  .17.0.4      .17.0.5              │   │
│  │    │       │        │            │                   │   │
│  │   App1    App2     App3         App4                 │   │
│  │  :80      :80      :8080        :443                 │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                             │
│  External access via port mapping:                          │
│  Host:8080 → NAT → Container NS1:80                         │
│  Host:8081 → NAT → Container NS2:80                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Port Mapping (NAT) Explained

How packets flow when accessing container from outside:

```
┌─────────────────────────────────────────────────────────────┐
│              Port Mapping Flow                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  External Client                                            │
│  (192.168.1.50)                                             │
│       │                                                     │
│       │ 1. Send packet to: 192.168.1.100:8080              │
│       ▼                                                     │
│  ┌──────────────────────────────────────────┐               │
│  │  Host (192.168.1.100)                    │               │
│  │                                          │               │
│  │  2. iptables DNAT rule triggers:         │               │
│  │     DNAT 192.168.1.100:8080              │               │
│  │     → 172.17.0.2:80                      │               │
│  │                                          │               │
│  │  3. Packet forwarded to bridge           │               │
│  │                                          │               │
│  │     docker0 bridge                       │               │
│  │         │                                │               │
│  │         │ 4. Route to veth pair          │               │
│  │         ▼                                │               │
│  └────────veth0─────────────────────────────┘               │
│             │                                               │
│             │ 5. Packet enters container namespace          │
│             ▼                                               │
│  ┌────────eth0────────────────────────────┐                 │
│  │  Container Network Namespace           │                 │
│  │  (172.17.0.2)                          │                 │
│  │                                        │                 │
│  │  6. Application receives packet        │                 │
│  │     Destination: 172.17.0.2:80         │                 │
│  │                                        │                 │
│  │  App listening on port 80              │                 │
│  └────────────────────────────────────────┘                 │
│                                                             │
│  Return path (reverse SNAT):                                │
│  Container → Host translates source → Client                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Create Network Namespace

```bash
# Create network namespace
sudo ip netns add netns1
sudo ip netns add netns2

# List namespaces
ip netns list

# Show network interfaces in namespace (initially only loopback)
sudo ip netns exec netns1 ip link
sudo ip netns exec netns1 ip addr

# Compare with host
ip addr
```

### Configure Network Namespace

```bash
# Create network namespace
sudo ip netns add mynet

# Bring up loopback in namespace
sudo ip netns exec mynet ip link set lo up

# Test loopback
sudo ip netns exec mynet ping -c 2 127.0.0.1

# Create veth pair (virtual ethernet pair)
sudo ip link add veth0 type veth peer name veth1

# Move one end to namespace
sudo ip link set veth1 netns mynet

# Configure host end
sudo ip addr add 192.168.1.1/24 dev veth0
sudo ip link set veth0 up

# Configure namespace end
sudo ip netns exec mynet ip addr add 192.168.1.2/24 dev veth1
sudo ip netns exec mynet ip link set veth1 up

# Test connectivity
ping -c 2 192.168.1.2
sudo ip netns exec mynet ping -c 2 192.168.1.1
```

### Network Namespace with Bridge

```bash
# Create bridge on host
sudo ip link add br0 type bridge
sudo ip link set br0 up
sudo ip addr add 192.168.100.1/24 dev br0

# Create namespace
sudo ip netns add container1

# Create veth pair
sudo ip link add veth0 type veth peer name veth1

# Connect veth0 to bridge
sudo ip link set veth0 master br0
sudo ip link set veth0 up

# Move veth1 to namespace
sudo ip link set veth1 netns container1

# Configure namespace
sudo ip netns exec container1 ip addr add 192.168.100.2/24 dev veth1
sudo ip netns exec container1 ip link set veth1 up
sudo ip netns exec container1 ip link set lo up
sudo ip netns exec container1 ip route add default via 192.168.100.1

# Test
sudo ip netns exec container1 ping -c 2 192.168.100.1
```

### View Network Namespace Details

```bash
# Show all interfaces
sudo ip netns exec mynet ip addr

# Show routing table
sudo ip netns exec mynet ip route

# Show iptables rules
sudo ip netns exec mynet iptables -L

# Run tcpdump in namespace
sudo ip netns exec mynet tcpdump -i veth1

# Start a server in namespace
sudo ip netns exec mynet python3 -m http.server 8080
```

### Delete Network Namespace

```bash
# Delete namespace (automatically removes interfaces)
sudo ip netns delete mynet
```

---

## Mount Namespace (Filesystem Isolation)

### Understanding Mount Namespace

The mount namespace isolates the filesystem mount points seen by a group of processes. Each mount namespace has its own independent filesystem view, which means processes in different mount namespaces can have completely different views of what filesystems are mounted where.

**How It Works at the Kernel Level:**

When a process creates a new mount namespace, the kernel:

1. **Copies the Mount Tree**: Creates a copy of the current namespace's mount tree (from `current->nsproxy->mnt_ns`)
2. **Duplicates Mount Points**: Each mount point (`struct mount`) is cloned with reference counting
3. **Isolates Changes**: Future mount/unmount operations only affect the new namespace
4. **Manages Propagation**: Tracks propagation types to determine if/how mount events propagate

```
Process creates new mount namespace:
┌─────────────────────────────────────────────────────────────┐
│  Original Namespace                  New Namespace           │
│                                                               │
│  /                                   / (copy)                │
│  ├─ /proc                           ├─ /proc (copy)         │
│  ├─ /sys                            ├─ /sys (copy)          │
│  ├─ /dev                            ├─ /dev (copy)          │
│  └─ /mnt/data ───────────────────> └─ /mnt/data (shared?)  │
│                                                               │
│  Mount tmpfs at /tmp:               Mount tmpfs at /tmp:    │
│  Visible in original                Isolated - only visible │
│                                     in new namespace         │
└─────────────────────────────────────────────────────────────┘
```

**Key Kernel Structures:**

- `struct mnt_namespace`: Represents a mount namespace, contains list of mounts
- `struct mount`: Represents a single mount point with parent/child relationships
- `struct vfsmount`: The VFS layer representation of a mounted filesystem
- Mount propagation flags determine isolation vs sharing behavior

**Container Use Case:**

Containers heavily rely on mount namespaces to provide isolated filesystem views:
- Each container sees only its own rootfs (via chroot or pivot_root)
- Container can't see host mounts (unless explicitly shared)
- Volumes are bind-mounted into container's namespace
- OverlayFS provides efficient writable layers on top of read-only images

Each mount namespace has:
- Independent filesystem view
- Own mount points
- Changes don't affect other namespaces (unless propagation configured)

### Create Mount Namespace

```bash
# Create new mount namespace
sudo unshare --mount bash

# Inside namespace, create a mount
mkdir /tmp/mymount
sudo mount -t tmpfs tmpfs /tmp/mymount

# Check mounts inside namespace
mount | grep mymount

# Exit namespace and check on host
mount | grep mymount
# Won't see it - isolated!
```

### Mount Namespace with chroot

```bash
# Prepare a root filesystem
mkdir -p /tmp/newroot/{bin,lib,lib64,proc}

# Copy essential binaries
cp /bin/bash /tmp/newroot/bin/
cp /bin/ls /tmp/newroot/bin/

# Copy required libraries
ldd /bin/bash | grep -o '/lib.*\.[0-9]' | xargs -I {} cp {} /tmp/newroot/lib/
ldd /bin/ls | grep -o '/lib.*\.[0-9]' | xargs -I {} cp {} /tmp/newroot/lib/

# Create new mount namespace and chroot
sudo unshare --mount bash -c "
  mount --bind /tmp/newroot /tmp/newroot
  chroot /tmp/newroot /bin/bash
"
```

### Mount Propagation

```bash
# Check mount propagation
findmnt -o TARGET,PROPAGATION

# Types of propagation:
# - shared: changes propagate to/from other namespaces
# - slave: receives changes but doesn't propagate
# - private: no propagation (isolated)
# - unbindable: cannot be bind-mounted

# Make mount private
sudo mount --make-private /mnt

# Make mount shared
sudo mount --make-shared /mnt

# Create namespace with private mounts
sudo unshare --mount --propagation private bash
```

**Understanding Mount Propagation:**

Mount propagation controls how mount and unmount events propagate between mount namespaces. This is crucial for container orchestration.

```
┌──────────────────────────────────────────────────────────────────┐
│  Mount Propagation Types                                         │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  SHARED (MS_SHARED):                                             │
│    Parent Namespace     ←──→    Child Namespace                 │
│    mount /foo                   sees /foo                        │
│    sees /bar            ←──     mount /bar                       │
│    (bidirectional propagation)                                   │
│                                                                   │
│  SLAVE (MS_SLAVE):                                               │
│    Parent Namespace     ───→    Child Namespace                 │
│    mount /foo                   sees /foo                        │
│    doesn't see /bar     ←──     mount /bar                       │
│    (unidirectional: parent → child only)                         │
│                                                                   │
│  PRIVATE (MS_PRIVATE):                                           │
│    Parent Namespace             Child Namespace                  │
│    mount /foo                   doesn't see /foo                │
│    doesn't see /bar             mount /bar                       │
│    (no propagation - full isolation)                             │
│                                                                   │
│  UNBINDABLE (MS_UNBINDABLE):                                    │
│    Like private, but mount cannot be bind-mounted                │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

**Container Runtime Use:**

Docker/Kubernetes typically use:
- `private` or `slave` propagation for container mounts
- Prevents containers from affecting host mounts
- Allows controlled sharing when needed (volume mounts)

### Practical Example: Isolated Filesystem

```bash
# Create isolated filesystem for testing
sudo unshare --mount bash

# Mount tmpfs
mount -t tmpfs tmpfs /mnt
cd /mnt

# Create files
echo "Isolated data" > test.txt
ls -la

# Exit namespace
exit

# Check on host
ls /mnt
# Different view - isolation works!
```

---

## UTS Namespace (Hostname Isolation)

### Understanding UTS Namespace

UTS = Unix Timesharing System

The UTS namespace isolates two system identifiers:
- **Hostname**: The system's hostname (returned by `gethostname()`)
- **Domain name**: The NIS/YP domain name (not DNS domain)

**How It Works:**

While simpler than other namespaces, UTS namespace isolation is important for:
1. **Container Identity**: Each container can have its own hostname
2. **Application Configuration**: Many apps use hostname for configuration
3. **Network Identity**: Hostname often used in distributed systems

```
┌────────────────────────────────────────────────────────────┐
│  Process calls sethostname("my-container")                 │
│                           │                                 │
│                           ▼                                 │
│  ┌──────────────────────────────────────────────┐         │
│  │ Kernel checks current->nsproxy->uts_ns       │         │
│  │ Updates hostname in that UTS namespace only  │         │
│  └──────────────────────────────────────────────┘         │
│                                                             │
│  Host UTS namespace:   hostname = "k8s-w1"                │
│  Container UTS ns:     hostname = "my-container"          │
│                                                             │
│  Each process reads its own UTS namespace's hostname       │
└────────────────────────────────────────────────────────────┘
```

**Kernel Implementation:**

- `struct uts_namespace`: Stores hostname and domainname strings
- `struct new_utsname`: Contains the actual name fields (MAXHOSTNAMELEN = 64)
- System calls `sethostname()` and `setdomainname()` modify the current UTS namespace
- `gethostname()` reads from current UTS namespace

**Container Use Case:**

Every container gets its own UTS namespace:
- Container hostname = typically container ID or pod name in Kubernetes
- Allows containers to identify themselves uniquely
- Applications can use hostname without conflicts

Isolates:
- Hostname
- Domain name (NIS domain)

### Create UTS Namespace

```bash
# Check current hostname
hostname

# Create new UTS namespace
sudo unshare --uts bash

# Inside namespace, change hostname
hostname my-container
hostname
# Shows: my-container

# Exit and check on host
exit
hostname
# Still shows original hostname
```

### Practical Example

```bash
# Create namespace with custom hostname
sudo unshare --uts bash -c "
  hostname my-isolated-system
  echo 'Hostname inside namespace:'
  hostname
"

# Check hostname on host
echo 'Hostname on host:'
hostname
```

### View UTS Namespace Info

```bash
# Show UTS namespace ID
readlink /proc/$$/ns/uts

# Compare with another process
readlink /proc/1/ns/uts
```

---

## IPC Namespace (Inter-Process Communication)

### Understanding IPC Namespace

The IPC namespace isolates System V IPC objects and POSIX message queues, preventing processes in different namespaces from communicating through these traditional IPC mechanisms.

**What Gets Isolated:**

1. **System V IPC Objects:**
   - **Message Queues**: `msgget()`, `msgsnd()`, `msgrcv()`
   - **Semaphore Sets**: `semget()`, `semop()`, `semctl()`
   - **Shared Memory Segments**: `shmget()`, `shmat()`, `shmdt()`

2. **POSIX Message Queues:**
   - `/dev/mqueue` filesystem mount
   - `mq_open()`, `mq_send()`, `mq_receive()`

**How It Works:**

```
┌────────────────────────────────────────────────────────────────┐
│  Process A (Host IPC namespace)                                │
│  ┌──────────────────────────────────┐                         │
│  │ Create shared memory: shmget()   │                         │
│  │ Returns IPC key: 0x12345678      │                         │
│  │                                   │                         │
│  │ Stored in: host_ipc_ns->shm_ids  │                         │
│  └──────────────────────────────────┘                         │
│                                                                 │
│  Process B (Container IPC namespace)                           │
│  ┌──────────────────────────────────┐                         │
│  │ Try to access: shmget(0x12345678)│                         │
│  │ Searches: container_ipc_ns->shm_ids                        │
│  │ Result: NOT FOUND - isolated!    │                         │
│  │                                   │                         │
│  │ Can only see its own IPC objects │                         │
│  └──────────────────────────────────┘                         │
└────────────────────────────────────────────────────────────────┘
```

**Kernel Structures:**

- `struct ipc_namespace`: Contains separate IPC ID tables
  - `ids[3]`: Array holding message queue, semaphore, and shared memory IDs
  - Each IPC type has its own ID allocator
- `struct kern_ipc_perm`: Common IPC object permissions and metadata
- IPC keys are namespace-local, not global

**Why IPC Isolation Matters:**

1. **Security**: Prevents information leakage between containers
2. **Resource Accounting**: Each namespace tracks its own IPC limits
3. **Cleanup**: When namespace destroyed, all IPC objects automatically cleaned up
4. **Legacy Support**: Allows old applications using System V IPC to work in containers

**Container Implications:**

- Containers cannot interfere with host IPC objects
- Each container has its own IPC resource limits (`/proc/sys/kernel/msg*`, `shm*`, `sem*`)
- Kubernetes pods share IPC namespace by default (containers in same pod can IPC)

Isolates:
- System V IPC objects (message queues, semaphores, shared memory)
- POSIX message queues

### Create IPC Namespace

```bash
# Create IPC namespace
sudo unshare --ipc bash

# Inside namespace:
# Create a message queue
ipcmk -Q

# List IPC objects
ipcs -q

# Exit and check on host
exit
ipcs -q
# Won't see the queue created in namespace
```

### System V IPC Examples

```bash
# Host: Create shared memory
ipcmk -M 1024
ipcs -m

# Create namespace
sudo unshare --ipc bash

# Inside namespace: Can't see host's shared memory
ipcs -m

# Create new shared memory in namespace
ipcmk -M 2048
ipcs -m
# Only sees namespace's shared memory

# Exit namespace
exit

# Host: Still only sees original shared memory
ipcs -m
```

### POSIX Message Queues

```bash
# View POSIX message queues
ls /dev/mqueue/

# Create namespace
sudo unshare --ipc --mount bash

# Must mount mqueue filesystem in namespace
mount -t mqueue none /dev/mqueue

# Now can create isolated message queues
```

---

## User Namespace (UID/GID Mapping)

### Understanding User Namespace

The user namespace is the most powerful and complex namespace type. It allows **unprivileged users to have root privileges within the namespace** while remaining unprivileged on the host system. This is achieved through UID/GID mapping.

**Core Capabilities:**

1. **UID/GID Mapping**: Maps user/group IDs between namespace and host
2. **Capability Isolation**: Grants full capabilities inside namespace, limited outside
3. **Nested Namespaces**: User namespaces can be nested for additional isolation
4. **Security**: Enables rootless containers - root inside ≠ root outside

**How UID/GID Mapping Works:**

```
┌──────────────────────────────────────────────────────────────────┐
│  User Namespace UID Mapping                                      │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  Host System              User Namespace          Inside View    │
│  ───────────              ──────────────          ────────────   │
│                                                                   │
│  UID 1000 (alice)  ─────→  UID 0 (root)    →   "I am root!"    │
│  UID 1001 (bob)    ─────→  UID 1 (bin)     →   "I am bin"      │
│  UID 1002 (carol)  ─────→  UID 2 (daemon)  →   "I am daemon"   │
│                                                                   │
│  Mapping configured in:                                          │
│  /proc/<pid>/uid_map:  "0 1000 1"  (inside 0 = host 1000)      │
│  /proc/<pid>/gid_map:  "0 1000 1"  (inside 0 = host 1000)      │
│                                                                   │
│  File Operations:                                                │
│  - Process UID 0 creates file → Host sees owner as UID 1000    │
│  - Host file owned by 1000 → Namespace sees owner as UID 0     │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

**Kernel Implementation:**

- `struct user_namespace`: Contains UID/GID mapping tables
- `struct uid_gid_map`: Mapping structure with extents (ranges)
- **Credential Translation**: Every system call that checks UID/GID translates through mapping
- `/proc/<pid>/uid_map`, `/proc/<pid>/gid_map`: One-time writable mapping files
- **setgroups**: Must be disabled (`/proc/<pid>/setgroups` → "deny") for non-root to write gid_map

**Capabilities Inside User Namespace:**

When you create a user namespace, you gain **full capabilities** within that namespace:

```
Outside namespace:     Inside namespace:
UID 1000 (unprivileged)  →  UID 0 with CAP_SYS_ADMIN, CAP_NET_ADMIN, etc.
                             BUT only for operations within the namespace!
                             
Can't:                   Can:
- Bind port < 1024       - Create other namespaces  
  on host                - Mount filesystems in mount NS
- Load kernel modules    - Configure network in net NS
- Change system time     - chroot within namespace
```

**Security Model:**

1. **Creator becomes root**: Process creating user NS becomes UID 0 inside
2. **Limited scope**: Root powers only apply to resources within namespace
3. **Parent visibility**: Parent namespace can still see/control child namespace processes
4. **Filesystem permissions**: Still enforced at host level (file owned by host UID)

**Rootless Containers:**

User namespaces enable unprivileged users to run containers:
- User 1000 on host runs container runtime
- Container processes think they're root (UID 0)
- Host kernel sees them as UID 1000
- Security maintained - can't escape to real root

Most powerful namespace - allows:
- Root inside namespace without root on host
- UID/GID mapping between namespace and host
- Security isolation

### Create User Namespace

```bash
# Create user namespace (no sudo needed!)
unshare --user bash

# Inside namespace:
id
# Shows uid=65534(nobody) gid=65534(nogroup)

# Set up UID/GID mappings
echo $$ > /tmp/mypid

# From another terminal (on host):
# Map current user to root in namespace
echo "0 $(id -u) 1" | sudo tee /proc/$(cat /tmp/mypid)/uid_map
echo "0 $(id -g) 1" | sudo tee /proc/$(cat /tmp/mypid)/gid_map

# Back in namespace:
id
# Now shows uid=0(root) gid=0(root)
```

### User Namespace with Mapping

```bash
# Create user namespace with automatic mapping
unshare --user --map-root-user bash

# Inside namespace:
id
# Shows root!

whoami
# Shows root

# But on host, it's still your regular user
# Check from another terminal:
ps -ef | grep bash
```

### Practical Example: Rootless Container

```bash
# As regular user (no sudo):
unshare --user --map-root-user --mount --pid --fork bash

# Inside namespace:
id  # Shows root
mount -t tmpfs tmpfs /mnt  # Can mount!
mkdir /mnt/test
echo "Rootless but powerful!" > /mnt/test/file.txt

# Security: Host is protected
# This "root" can only affect the namespace
```

### UID/GID Mapping Rules

```bash
# Mapping format: <start_in_namespace> <start_on_host> <count>
# Example: Map UIDs 0-999 in namespace to 100000-100999 on host
echo "0 100000 1000" > /proc/$$/uid_map

# View current mappings
cat /proc/$$/uid_map
cat /proc/$$/gid_map

# Can only map UIDs that are in your subordinate UID range
cat /etc/subuid
cat /etc/subgid
```

---

## Cgroup Namespace

### Understanding Cgroup Namespace

The cgroup namespace virtualizes the view of `/proc/self/cgroup`, making processes inside the namespace believe they are at the root of the cgroup hierarchy. This prevents container processes from seeing or modifying the host's cgroup hierarchy.

**What It Does:**

- **Virtualizes cgroup paths**: Process sees relative path, not absolute host path
- **Hides host hierarchy**: Container can't see parent cgroups
- **Limits visibility**: Prevents container from modifying resource limits outside its scope
- **Security boundary**: Prevents information leakage about other containers

**How It Works:**

```
┌───────────────────────────────────────────────────────────────────┐
│  Without Cgroup Namespace (Host View):                           │
│                                                                    │
│  $ cat /proc/self/cgroup                                          │
│  12:memory:/system.slice/docker-abc123.scope                     │
│  11:cpu:/system.slice/docker-abc123.scope                        │
│                                                                    │
│  Process sees FULL path in host cgroup hierarchy                 │
│  Can infer: system structure, other containers, etc.             │
│                                                                    │
├───────────────────────────────────────────────────────────────────┤
│  With Cgroup Namespace (Container View):                         │
│                                                                    │
│  $ cat /proc/self/cgroup                                          │
│  12:memory:/                                                      │
│  11:cpu:/                                                         │
│                                                                    │
│  Process sees "/" - believes it's at cgroup root                 │
│  No visibility into host cgroup structure                         │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

**Kernel Behavior:**

When a process reads `/proc/self/cgroup` in a cgroup namespace:
1. Kernel retrieves the actual cgroup path from `task_struct->cgroups`
2. Determines the cgroup namespace's root cgroup
3. Returns **relative path** from namespace root to process's cgroup
4. Container at `/system.slice/docker-abc123.scope` sees itself at `/`

**Practical Implications:**

```
Host creates container with cgroup limits:
  CPU: 50% (0.5 cores)
  Memory: 512 MB
  
Container sees in /proc/self/cgroup:
  cpu:/
  memory:/
  
Container CANNOT:
  - See it's in /system.slice/docker-abc123.scope
  - See other containers' cgroups
  - Modify parent cgroup limits
  - Determine system resource topology
  
Container CAN:
  - Create sub-cgroups within its view
  - See its own resource usage
  - Subdivide its allocated resources
```

**Security & Resource Isolation:**

- Prevents container from escaping resource limits
- Hides system information (number of containers, naming scheme)
- Allows safe delegation of cgroup management to unprivileged processes
- Works with both cgroup v1 and v2

**Container Use Case:**

Modern container runtimes (Docker, containerd, CRI-O) create cgroup namespaces by default:
- Container believes it's the only process on the system (from cgroup perspective)
- Makes resource monitoring inside container more intuitive
- Enables nested containers (systemd in containers)

### Create and Use Cgroup Namespace

Virtualizes the view of `/proc/self/cgroup` and `/sys/fs/cgroup`.

```bash
# View current cgroup
cat /proc/self/cgroup

# Create cgroup namespace
sudo unshare --cgroup bash

# Inside namespace:
cat /proc/self/cgroup
# Shows virtualized view
```

### Practical Use

```bash
# Create cgroup namespace (usually combined with others)
sudo unshare --cgroup --mount --pid --fork bash

# Inside namespace:
mount -t cgroup2 none /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
```

---

## Time Namespace

### Understanding Time Namespace

Allows different system times in different namespaces (added in Linux 5.6).
## Time Namespace

### Understanding Time Namespace

Introduced in Linux 5.6 (2020), the time namespace allows different processes to see different system times. This is one of the newest namespace types.

**What It Isolates:**

- `CLOCK_MONOTONIC`: Time since boot
- `CLOCK_BOOTTIME`: Like MONOTONIC but includes suspend time  
- **Does NOT isolate** `CLOCK_REALTIME` (wall-clock time)

**How It Works:**

```
┌─────────────────────────────────────────────────────────────────┐
│  Time Namespace with Offsets                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Host System:                                                   │
│    CLOCK_MONOTONIC = 1000000 seconds (system uptime)           │
│                                                                  │
│  Container with time namespace:                                 │
│    Offset: -999000 seconds                                      │
│    Processes see: 1000000 - 999000 = 1000 seconds             │
│                                                                  │
│  Result: Container thinks system booted 16 minutes ago         │
│           Host knows system booted 11.5 days ago               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Configuration:**

Offsets are set via `/proc/<pid>/timens_offsets`:
```
# Format: <clock_id> <seconds> <nanoseconds>
monotonic 1000 0
boottime 2000 500000000
```

**Why This Matters:**

1. **Container Migration**: Preserve application uptime perception after migration
2. **Testing**: Simulate different system uptimes without actually waiting
3. **Application Compatibility**: Some apps make assumptions about system uptime
4. **Checkpoint/Restore**: CRIU can restore with original monotonic time

**Limitations:**

- Cannot change wall-clock time (CLOCK_REALTIME) - security risk
- Relatively new feature, not universally supported
- Limited practical use cases compared to other namespaces

```bash
# Check if time namespace is supported
ls /proc/$$/ns/time

# Create time namespace
sudo unshare --time bash

# Set time offset (requires special setup)
# This is advanced and rarely used directly
```

### Use Cases

- Testing time-dependent applications
- Migration scenarios (CRIU checkpoint/restore)
- Container time manipulation
- Simulating different system uptimes for testing

---

## Namespaces in Containers

### How Docker Uses Namespaces

When Docker creates a container, it creates new namespaces for isolation. Understanding this is key to understanding container security and architecture.

**Docker Container Namespace Creation:**

```
docker run -d --name myapp nginx
          │
          ▼
┌─────────────────────────────────────────────────────────────────┐
│ Docker Engine creates namespaces:                               │
│                                                                  │
│  1. PID namespace    → Container sees only its processes       │
│  2. Network namespace → Container gets virtual NIC + IP         │
│  3. Mount namespace  → Container sees its own rootfs           │
│  4. UTS namespace    → Container has unique hostname           │
│  5. IPC namespace    → Isolated IPC objects                    │
│  6. Cgroup namespace → Virtualized cgroup view                 │
│  7. User namespace   → (optional) UID/GID mapping              │
│                                                                  │
│ Result: Isolated environment that looks like a separate system │
└─────────────────────────────────────────────────────────────────┘
```

**Process Flow:**

```
User runs: docker run -d nginx
                  │
                  ▼
Docker daemon (dockerd) receives request
                  │
                  ▼
containerd creates container spec
                  │
                  ▼
runc (low-level runtime) called
                  │
                  ▼
runc performs:
  1. clone() syscall with CLONE_NEW* flags
  2. Sets up namespaces (unshare)
  3. Configures cgroups for resource limits
  4. Sets up network (veth pair, bridge)
  5. Mounts rootfs using OverlayFS
  6. Changes root (pivot_root)
  7. Drops capabilities
  8. Executes container process (nginx)
                  │
                  ▼
Container running in isolated namespaces!
```

### Docker Container Namespaces

```bash
# Run a container
docker run -d --name test nginx

# Get container PID
CPID=$(docker inspect -f '{{.State.Pid}}' test)

# View container's namespaces
sudo ls -la /proc/$CPID/ns/

# Compare with host
ls -la /proc/$$/ns/

# Enter container namespaces
sudo nsenter --target $CPID --all bash

# Inside container namespace:
hostname  # Shows container hostname
ip addr   # Shows container network
ps aux    # Shows container processes
```

### Viewing Container Namespace IDs

```bash
# Show namespace IDs for container
docker inspect test | grep -A 10 Namespace

# Or directly:
sudo lsns | grep $CPID

# Compare namespace sharing
# Containers on same network share net namespace with pause container
```

### Container Namespace Isolation

```bash
# Create two containers
docker run -d --name c1 nginx
docker run -d --name c2 nginx

# Get their PIDs
PID1=$(docker inspect -f '{{.State.Pid}}' c1)
PID2=$(docker inspect -f '{{.State.Pid}}' c2)

# Check if they share namespaces
readlink /proc/$PID1/ns/net
readlink /proc/$PID2/ns/net
# Different - isolated

readlink /proc/$PID1/ns/pid
readlink /proc/$PID2/ns/pid
# Different - each has own PID namespace
```

### Sharing Namespaces Between Containers

```bash
# Create container
docker run -d --name c1 nginx

# Create second container sharing network namespace
docker run -d --name c2 --network container:c1 alpine sleep 3600

# Check namespace sharing
PID1=$(docker inspect -f '{{.State.Pid}}' c1)
PID2=$(docker inspect -f '{{.State.Pid}}' c2)

readlink /proc/$PID1/ns/net
readlink /proc/$PID2/ns/net
# Same network namespace!

# Both see same network interfaces
docker exec c1 ip addr
docker exec c2 ip addr
```

### Host Namespace Mode

```bash
# Run container with host network namespace
docker run -it --network host nginx

# Container shares host's network
# No isolation for network
# Can bind to host ports directly

# Check namespaces
PID=$(docker inspect -f '{{.State.Pid}}' <container>)
readlink /proc/$PID/ns/net
readlink /proc/1/ns/net
# Same!
```

---

## Namespaces in Kubernetes

### Pod Namespace Sharing

```
┌─────────────────────────────────────────────────────────────┐
│                         Kubernetes Pod                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Pause Container (Infrastructure)        │   │
│  │  • Holds the namespaces                              │   │
│  │  • Creates: NET, IPC, UTS namespaces                 │   │
│  │  • PID: depends on shareProcessNamespace             │   │
│  └─────────────────┬────────────────────────────────────┘   │
│                    │                                        │
│         ┌──────────┴──────────┬──────────────┐              │
│         ▼                     ▼              ▼              │
│  ┌────────────┐        ┌────────────┐  ┌────────────┐      │
│  │Container 1 │        │Container 2 │  │Container 3 │      │
│  │            │        │            │  │            │      │
│  │ Own MNT NS │        │ Own MNT NS │  │ Own MNT NS │      │
│  │ Own PID NS*│        │ Own PID NS*│  │ Own PID NS*│      │
│  │            │        │            │  │            │      │
│  │ Shared NET │◄──────►│ Shared NET │◄►│ Shared NET │      │
│  │ Shared IPC │◄──────►│ Shared IPC │◄►│ Shared IPC │      │
│  │ Shared UTS │◄──────►│ Shared UTS │◄►│ Shared UTS │      │
│  └────────────┘        └────────────┘  └────────────┘      │
│                                                             │
│  * Unless shareProcessNamespace: true                       │
│                                                             │
│  Why This Design?                                           │
│  ═══════════════                                            │
│  • localhost communication: Containers can talk via         │
│    127.0.0.1 (same network namespace)                      │
│  • Shared ports: Only one container can bind to a port     │
│  • IPC: Containers can use shared memory, signals          │
│  • Resource efficiency: One network stack per pod          │
│  • Filesystem isolation: Each container has own view       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Namespace Sharing Implications:**

1. **Network (Shared)**:
   - All containers in pod share `localhost`
   - Port conflicts possible - coordinate port usage
   - Network policies apply to entire pod

2. **IPC (Shared)**:
   - Containers can use shared memory for high-performance communication
   - System V IPC and POSIX queues visible to all containers in pod

3. **UTS (Shared)**:
   - All containers see same hostname (pod name)
   - Cannot set individual hostnames per container

4. **PID (Typically Separate, Optionally Shared)**:
   - Default: Each container PID namespace independent
   - `shareProcessNamespace: true`: All containers see all processes in pod
   - When shared: Useful for sidecars that need to monitor/debug app

5. **Mount (Separate)**:
   - Each container has its own filesystem view
   - Volumes mounted into each container independently
   - Enables different images per container

### View Pod Namespaces

```bash
# Find a pod
kubectl get pods

# Get pod details including node
kubectl get pod <pod-name> -o wide

# SSH to the node where pod is running
ssh user@node

# Find pause container for the pod
sudo crictl pods
sudo crictl ps | grep <pod-name>

# Get pause container PID
PAUSE_PID=$(sudo crictl inspect <pause-container-id> | jq -r .info.pid)

# View pause container namespaces
sudo ls -la /proc/$PAUSE_PID/ns/

# Get app container PID
APP_PID=$(sudo crictl inspect <app-container-id> | jq -r .info.pid)

# Compare namespaces
echo "Pause container NET namespace:"
sudo readlink /proc/$PAUSE_PID/ns/net

echo "App container NET namespace:"
sudo readlink /proc/$APP_PID/ns/net
# They match! Shared namespace
```

### Shared Network Namespace in Pods

```bash
# Deploy a multi-container pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-container
spec:
  containers:
  - name: nginx
    image: nginx
  - name: alpine
    image: alpine
    command: ["sleep", "3600"]
EOF

# Wait for pod
kubectl wait --for=condition=ready pod/multi-container

# Check from nginx container
kubectl exec multi-container -c nginx -- ip addr

# Check from alpine container
kubectl exec multi-container -c alpine -- ip addr
# Same network interfaces!

# Both can reach localhost
kubectl exec multi-container -c nginx -- curl localhost:80
kubectl exec multi-container -c alpine -- wget -O- localhost:80
```

### Process Namespace Sharing

```yaml
# Enable shared PID namespace
apiVersion: v1
kind: Pod
metadata:
  name: shared-pid
spec:
  shareProcessNamespace: true
  containers:
  - name: nginx
    image: nginx
  - name: shell
    image: alpine
    command: ["sleep", "3600"]
```

```bash
# Apply the pod
kubectl apply -f shared-pid.yaml

# Check processes from nginx container
kubectl exec shared-pid -c nginx -- ps aux
# Shows all pod processes!

# Check from shell container
kubectl exec shared-pid -c shell -- ps aux
# Same processes - shared PID namespace

# Can see pause container as PID 1
# Can see processes from other containers
```

### Namespace Isolation Test

```bash
# Create test pod
kubectl run test --image=nginx

# Get node and container info
NODE=$(kubectl get pod test -o jsonpath='{.spec.nodeName}')
ssh $NODE

# Find container PID
CPID=$(sudo crictl ps --name nginx -q | head -1)
CPID_FULL=$(sudo crictl inspect $CPID | jq -r .info.pid)

# Check namespaces
sudo ls -la /proc/$CPID_FULL/ns/

# Compare with host
ls -la /proc/$$/ns/

# All different except user namespace
```

---

## Advanced Topics

### Namespace Persistence

```bash
# Namespaces exist as long as:
# 1. At least one process is in the namespace, OR
# 2. The namespace is bind-mounted

# Create namespace and persist it
sudo unshare --net --mount-proc=/tmp/netns/myns bash

# In another terminal, bind-mount the namespace
sudo touch /var/run/netns/myns
sudo mount --bind /proc/<PID>/ns/net /var/run/netns/myns

# Now namespace persists even after process exits
ip netns list
# Shows: myns
```

### Nested Namespaces

```bash
# Create parent namespace
sudo unshare --pid --fork bash

# Inside parent, create child namespace
unshare --pid --fork bash

# Check PID hierarchy
cat /proc/$$/status | grep NSpid
# Shows PIDs at each level
```

### Namespace and Capabilities

```bash
# User namespace gives capabilities inside namespace
unshare --user --map-root-user bash

# Check capabilities
capsh --print
# Shows full capabilities inside namespace

# But limited on host
# Exit namespace and check
capsh --print
```

### Joining Multiple Namespaces

```bash
# Enter multiple namespaces of a process at once
sudo nsenter \
  --target <PID> \
  --pid \
  --net \
  --mount \
  --uts \
  --ipc \
  bash

# Or use --all for all namespaces
sudo nsenter --target <PID> --all bash
```

---

## Troubleshooting

### Check Namespace Support

```bash
# Check kernel version (namespaces need specific versions)
uname -r

# Check namespace support
ls /proc/$$/ns/
# Should show: cgroup, ipc, mnt, net, pid, time, user, uts

# Check unshare support
unshare --help
```

### Permission Issues

```bash
# User namespace doesn't need root
unshare --user bash  # Works as regular user

# Other namespaces need CAP_SYS_ADMIN
# Usually requires root or specific capabilities

# Check capabilities
getcap /usr/bin/unshare
```

### Debugging Namespace Issues

```bash
# Can't create namespace?
# Check if unprivileged user namespaces are enabled
sysctl kernel.unprivileged_userns_clone

# Enable if disabled
sudo sysctl -w kernel.unprivileged_userns_clone=1

# Check for AppArmor/SELinux restrictions
getenforce  # SELinux
aa-status   # AppArmor
```

### Finding Processes in Namespaces

```bash
# List all processes with their namespace IDs
ps -eo pid,pidns,netns,mntns,user,cmd

# Find processes in specific namespace
lsns -t net -p <namespace-id>

# Show namespace tree
lsns -T
```

### Network Namespace Troubleshooting

```bash
# Can't ping in network namespace?
# Check if loopback is up
sudo ip netns exec myns ip link show lo
sudo ip netns exec myns ip link set lo up

# Check routing
sudo ip netns exec myns ip route

# Check connectivity
sudo ip netns exec myns ping -c 2 127.0.0.1
```

### Mount Namespace Issues

```bash
# Can't see mounts?
# Check mount propagation
findmnt -o TARGET,PROPAGATION

# Make mount visible
sudo mount --make-shared /mnt
```

### Cleanup

```bash
# Remove network namespaces
ip netns delete myns

# Kill processes in namespace
# (namespace is automatically removed when last process exits)

# Force unmount if needed
sudo umount -f /path/to/mount

# Clean up bind-mounted namespaces
sudo umount /var/run/netns/myns
sudo rm /var/run/netns/myns
```

---

## Practical Exercises

### Exercise 1: Create Isolated Environment

```bash
# Create a fully isolated environment
sudo unshare \
  --fork \
  --pid \
  --mount-proc \
  --net \
  --mount \
  --uts \
  --ipc \
  bash

# Inside:
hostname isolated-test
hostname
ps aux
ip addr
mount | grep proc
```

### Exercise 2: Container-like Isolation

```bash
# Simulate a container
sudo unshare \
  --user --map-root-user \
  --fork \
  --pid --mount-proc \
  --net \
  --mount \
  --uts \
  bash

# You're now "root" in an isolated environment
id
ps aux
hostname my-container
```

### Exercise 3: Network Isolation Test

```bash
# Terminal 1: Create network namespace with HTTP server
sudo ip netns add webserver
sudo ip netns exec webserver ip link set lo up
sudo ip netns exec webserver python3 -m http.server 8080

# Terminal 2: Try to access from host
curl localhost:8080
# Fails - isolated!

# Create connectivity
sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth1 netns webserver
sudo ip addr add 192.168.1.1/24 dev veth0
sudo ip link set veth0 up
sudo ip netns exec webserver ip addr add 192.168.1.2/24 dev veth1
sudo ip netns exec webserver ip link set veth1 up

# Now test
curl 192.168.1.2:8080
# Works!
```

---

## Summary Table

| Namespace | Isolates | Command Example | Use Case |
|-----------|----------|-----------------|----------|
| **PID** | Process IDs | `unshare --pid --fork` | Process isolation, containers |
| **NET** | Network stack | `unshare --net` | Network isolation, containers |
| **MNT** | Mount points | `unshare --mount` | Filesystem isolation |
| **UTS** | Hostname | `unshare --uts` | Hostname per container |
| **IPC** | IPC objects | `unshare --ipc` | IPC isolation |
| **USER** | UID/GID | `unshare --user` | Rootless containers, security |
| **CGROUP** | Cgroup view | `unshare --cgroup` | Resource limits view |
| **TIME** | System time | `unshare --time` | Time manipulation |

---

## 🔍 Practical Visualization Guide: See Namespaces in Action

### Step-by-Step: Exploring Namespaces on a Kubernetes Cluster

This practical guide shows you how to visualize and understand namespaces on your actual Kubernetes cluster.

#### Step 1: Identify a Running Pod

```bash
# List all pods
kubectl get pods -A -o wide

# Pick a pod and note its name, namespace, and node
kubectl get pod <pod-name> -n <namespace> -o wide
# Example: mypod running on node k8s-w1
```

#### Step 2: Access the Worker Node

```bash
# SSH to the worker node where pod is running
ssh user@k8s-w1

# Verify you're on the correct node
hostname
```

#### Step 3: Find Pod Containers with crictl

```bash
# List all pods on this node
sudo crictl pods

# Find your specific pod
sudo crictl pods | grep <pod-name>

# List containers in the pod
sudo crictl ps | grep <pod-name>

# You'll see:
#   - pause container (infrastructure/sandbox)
#   - application container(s)
```

#### Step 4: Get Container PIDs

```bash
# Get pause container ID and PID
PAUSE_ID=$(sudo crictl ps | grep <pod-name> | grep pause | head -1 | awk '{print $1}')
PAUSE_PID=$(sudo crictl inspect $PAUSE_ID | jq -r .info.pid)

# Get application container ID and PID
APP_ID=$(sudo crictl ps | grep <pod-name> | grep -v pause | head -1 | awk '{print $1}')
APP_PID=$(sudo crictl inspect $APP_ID | jq -r .info.pid)

# Display the PIDs
echo "Pause container PID: $PAUSE_PID"
echo "App container PID: $APP_PID"
```

#### Step 5: Visualize Namespace Sharing

```bash
# Compare all namespaces
echo "=========================================="
echo "NAMESPACE COMPARISON"
echo "=========================================="

echo -e "\nPause Container Namespaces:"
sudo ls -la /proc/$PAUSE_PID/ns/

echo -e "\nApp Container Namespaces:"
sudo ls -la /proc/$APP_PID/ns/

# Check network namespace (SHARED)
echo -e "\n--- Network Namespace (shared) ---"
echo -n "Pause: " && sudo readlink /proc/$PAUSE_PID/ns/net
echo -n "App:   " && sudo readlink /proc/$APP_PID/ns/net

# Check mount namespace (SEPARATE)
echo -e "\n--- Mount Namespace (separate) ---"
echo -n "Pause: " && sudo readlink /proc/$PAUSE_PID/ns/mnt
echo -n "App:   " && sudo readlink /proc/$APP_PID/ns/mnt

# Check PID namespace (SEPARATE)
echo -e "\n--- PID Namespace (separate) ---"
echo -n "Pause: " && sudo readlink /proc/$PAUSE_PID/ns/pid
echo -n "App:   " && sudo readlink /proc/$APP_PID/ns/pid
```

**Expected Results:**
- ✅ **Network (net)**: Same inode number → SHARED
- ✅ **IPC**: Same inode number → SHARED
- ✅ **UTS**: Same inode number → SHARED
- ❌ **Mount (mnt)**: Different inode numbers → SEPARATE
- ❌ **PID**: Different inode numbers → SEPARATE

#### Step 6: Visualize Process Isolation (PID Namespace)

```bash
# View processes from host perspective
echo "--- Host View (all processes) ---"
ps aux | head -20

# View processes from container perspective
echo "--- Container View (isolated) ---"
sudo nsenter --target $APP_PID --pid --mount ps aux

# Even shorter - just count
echo "Host process count: $(ps aux | wc -l)"
echo "Container process count: $(sudo nsenter --target $APP_PID --pid --mount ps aux | wc -l)"
```

#### Step 7: Visualize Network Isolation (NET Namespace)

```bash
# Host network interfaces
echo "--- Host Network Interfaces ---"
ip addr show | grep '^[0-9]'

# Container network interfaces (via nsenter)
echo "--- Container Network Interfaces ---"
sudo nsenter --target $APP_PID --net ip addr show

# From inside container (alternative method)
kubectl exec <pod-name> -- ip addr show

# Check routing table
echo "--- Container Routes ---"
sudo nsenter --target $APP_PID --net ip route
```

#### Step 8: Test Multi-Container Pod Network Sharing

```bash
# Create a pod with two containers
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: netshare-demo
spec:
  containers:
  - name: nginx
    image: nginx
    ports:
    - containerPort: 80
  - name: curl
    image: curlimages/curl:latest
    command: ["sleep", "3600"]
EOF

# Wait for pod
kubectl wait --for=condition=ready pod/netshare-demo --timeout=60s

# Test localhost communication (works because shared network namespace!)
kubectl exec netshare-demo -c curl -- curl -s localhost:80 | head -5

# Verify both containers see identical network
echo "--- Nginx container network ---"
kubectl exec netshare-demo -c nginx -- ip addr | grep "inet "

echo "--- Curl container network ---"
kubectl exec netshare-demo -c curl -- ip addr | grep "inet "
# Same IP address!

# Cleanup
kubectl delete pod netshare-demo
```

#### Step 9: Visualize Mount Namespace Isolation

```bash
# Create a file on the host
sudo touch /tmp/host-only-file-$(date +%s)

# List host /tmp
echo "--- Host /tmp ---"
ls -la /tmp/ | head -10

# Try to see it from container (won't be there!)
echo "--- Container /tmp ---"
kubectl exec <pod-name> -- ls -la /tmp/

# Create file in container
kubectl exec <pod-name> -- touch /tmp/container-file

# File exists in container
kubectl exec <pod-name> -- ls -la /tmp/container-file

# But not in host /tmp (it's in the container's overlay filesystem)
ls /tmp/container-file 2>&1
# File not found!
```

#### Step 10: Use lsns to See the Big Picture

```bash
# View all namespaces on the node
sudo lsns

# View only network namespaces
sudo lsns -t net

# View namespaces for specific container
sudo lsns -p $APP_PID

# See all processes sharing a network namespace
NET_NS=$(sudo readlink /proc/$APP_PID/ns/net | sed 's/.*\[\(.*\)\]/\1/')
sudo lsns -t net | grep $NET_NS
```

### Understanding What You See

**Key Observations:**

1. **Pause Container's Role:**
   ```bash
   # Pause container is always there
   sudo crictl ps | grep pause | grep <pod-name>
   
   # It does nothing but sleep
   sudo nsenter --target $PAUSE_PID --pid --mount ps aux
   # Shows: /pause process
   
   # But it holds the pod's network namespace
   # If app containers restart, network stays intact!
   ```

2. **Namespace Sharing = Localhost Communication:**
   ```
   Shared NET namespace means:
   - Same IP address
   - Same network interfaces
   - Can use localhost to communicate
   - Port conflicts if both bind same port
   ```

3. **Container Runtime Flow:**
   ```bash
   # See the order containers were created
   sudo crictl ps | grep <pod-name>
   # Pause container has oldest creation time
   # App containers created after
   ```

### How Container Runtime Creates Namespaces

Watch it in action:

```bash
# Monitor namespace creation
watch -n 1 'sudo lsns -t net'

# In another terminal, create a pod
kubectl run test-ns --image=nginx

# You'll see:
# 1. New NET namespace appears (pause container)
# 2. Another process joins that namespace (nginx container)
# 3. All containers in pod share that namespace

# Cleanup
kubectl delete pod test-ns
# Network namespace disappears
```

### Debugging Commands

```bash
# Enter container's complete environment from host
sudo nsenter --target $APP_PID --all bash
# Now you're "inside" the container!

# Check what's mounted in container
sudo nsenter --target $APP_PID --mount findmnt | head -20

# View network config as container sees it
sudo nsenter --target $APP_PID --net netstat -tuln

# See iptables rules in container's network namespace
sudo nsenter --target $APP_PID --net iptables -L -n

# Compare host and container views
echo "Host PIDs:" && ps aux | wc -l
echo "Container PIDs:" && sudo nsenter --target $APP_PID --pid ps aux | wc -l
```

### Common Gotchas

1. **PID changes on container restart:**
   ```bash
   # Old PID becomes invalid when container restarts
   # Always re-fetch: sudo crictl inspect <container-id> | jq -r .info.pid
   ```

2. **Namespace persists with pause container:**
   ```bash
   # Even if app crashes, network namespace stays (pause container still there)
   # Only deleted when entire pod terminates
   ```

3. **Host always sees real PIDs:**
   ```bash
   # From host: PID 12345
   # From container: PID 1
   # Same process, different views!
   ```

---

## Quick Reference

```bash
# View namespaces
lsns                           # List all namespaces
lsns -t net                    # List network namespaces
ls -la /proc/$$/ns/            # Current process namespaces
ip netns list                  # Network namespaces

# Create namespaces
unshare --pid --fork bash      # PID namespace
unshare --net bash             # Network namespace
unshare --mount bash           # Mount namespace
unshare --uts bash             # UTS namespace
ip netns add myns              # Network namespace

# Enter namespaces
nsenter --target <PID> --all bash    # Enter all namespaces
nsenter --target <PID> --net bash    # Enter network namespace
ip netns exec myns bash              # Execute in network namespace

# Container namespaces
docker inspect -f '{{.State.Pid}}' container  # Get container PID
sudo ls -la /proc/<PID>/ns/                   # View container namespaces
sudo nsenter --target <PID> --all bash        # Enter container namespaces

# Kubernetes
kubectl get pod <pod> -o wide                 # Get pod node
sudo crictl pods                              # List pods on node
sudo crictl inspect <container-id>            # Inspect container
```

---

## References

- [Linux Namespaces Man Page](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- [unshare Man Page](https://man7.org/linux/man-pages/man1/unshare.1.html)
- [nsenter Man Page](https://man7.org/linux/man-pages/man1/nsenter.1.html)
- [ip-netns Man Page](https://man7.org/linux/man-pages/man8/ip-netns.8.html)
- [Linux Cgroups (Resource Management)](cgroups.md)
- [Understanding Containers](containers.md)
- [Docker Guide](docker.md)
- [Kubernetes Pods](pods.md)
- [Pause Containers](pause-containers.md)

---

**Next Steps:**
1. Practice creating and managing namespaces
2. Understand how Docker uses namespaces
3. Explore Kubernetes pod namespace sharing
4. Learn about cgroups for resource limits
5. Study container security with namespaces

**🔒 Security Note:** User namespaces are powerful but require careful configuration. Always understand the security implications before enabling unprivileged user namespaces in production.
