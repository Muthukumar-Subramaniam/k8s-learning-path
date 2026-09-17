# ☸️ Kubernetes Learning Path

A complete, in-depth Kubernetes course in written form. Not a cheat sheet and not a reference card: each document explains **what a thing is, how it actually works underneath, how to operate it, how it fails, and how to debug it**, with runnable commands and annotated manifests throughout.

Currently **84 documents, around 85,000 lines**.

---

## 📖 How to Use This

**New to Kubernetes?** Read the parts in order. Part 0 exists because Kubernetes is Linux primitives wearing a trench coat. Namespaces, cgroups and network routing are not optional background, they are the subject.

**Already running clusters?** Jump to whatever you need. Every document is self contained and cross links to its neighbours.

**Preparing for CKA, CKAD or CKS?** Most documents end with an *Exam and Interview Traps* section covering the things that are reliably tested and reliably misunderstood.

### What you need to follow along

You do not need a large cluster. Almost every exercise works on a single node.

| Environment | Good for |
|---|---|
| `kind` or `minikube` on a laptop | Everything except node-level and multi-node networking work |
| A kubeadm cluster on VMs | Everything, including control plane internals |
| EKS, GKE or AKS | Workloads, storage, networking, security policy. **Not** control plane internals, which the provider hides |

### A note on environments

kubeadm is the primary teaching vehicle here because the control plane is visible: you can read the static pod manifests, inspect the certificates, and query etcd directly. That visibility is the whole point.

Where a procedure requires a self-managed control plane, the document says so and gives the managed-cluster equivalent. Where a choice of CNI, storage driver or load balancer exists, the alternatives are named rather than assuming one particular stack.

---

## Part 0: Foundations

Kubernetes makes very little sense until you understand what a container actually is. Start here even if you are impatient.

| Topic | What it covers |
|---|---|
| [Containers: What They Are and Why They Changed Everything](docs/containers.md) | Images, layers, OCI, the real difference between a container and a VM |
| [Linux Namespaces](docs/linux-namespaces.md) | The isolation primitive. PID, NET, MNT, UTS, IPC, USER, CGROUP |
| [Control Groups (cgroups)](docs/cgroups.md) | The resource primitive. How CPU and memory limits are actually enforced |
| [Docker](docs/docker.md) | The tool most people meet first, in depth |
| [Docker and Why Orchestration Is Required](docs/docker-and-orchestration.md) | The problems a single host cannot solve |
| [Linux Networking](docs/linux-networking.md) | Bridges, veth pairs, routing, iptables. The substrate under all pod networking |
| [Container Runtimes](docs/container-runtime.md) | CRI, containerd, runc, and who calls whom |
| [Pause Containers](docs/pause-containers.md) | The invisible container that holds a pod's namespaces open |

---

## Part 1: Kubernetes Fundamentals

| Topic | What it covers |
|---|---|
| [What Is Kubernetes?](docs/what-is-kubernetes.md) | The problem it solves, the declarative model, reconciliation |
| [Microservices](docs/microservices.md) | The architectural context Kubernetes was built for |
| [Cluster Architecture](docs/k8s-architecture.md) | How the pieces fit together |
| [The Kubernetes API](docs/k8s-api.md) | Objects, groups, versions, resources, and the discovery mechanism |
| [kubectl](docs/kubectl.md) | The client, properly understood |
| [Imperative Management](docs/imperative-kubernetes.md) | Fast commands for getting things done and for generating manifests |

### Control Plane Components

| Topic | What it covers |
|---|---|
| [Control Plane Nodes](docs/control-plane-node.md) | What runs where, and why |
| [kube-apiserver](docs/kube-apiserver.md) | The front door. Every request goes through it |
| [etcd](docs/etcd.md) | The only stateful component. Where the cluster actually lives |
| [kube-scheduler](docs/kube-scheduler.md) | How a pod gets assigned to a node |
| [kube-controller-manager](docs/kube-controller-manager.md) | The reconciliation loops that make the declarative model work |

### Worker Node Components

| Topic | What it covers |
|---|---|
| [Worker Nodes](docs/worker-node.md) | What a node is responsible for |
| [kubelet](docs/kubelet.md) | The node agent. Turns pod specs into running containers |
| [kube-proxy](docs/kube-proxy.md) | Service implementation via iptables, IPVS or nftables |

---

## Part 2: Workloads

The objects you will spend most of your time with.

| Topic | What it covers |
|---|---|
| [Pods](docs/pods.md) | The atomic unit. Shared namespaces, multi-container patterns, the full spec |
| [Pod Lifecycle](docs/pod-lifecycle.md) | Phases, conditions, probes, init and sidecar containers, graceful termination |
| [Pod Operations](docs/pod-operations.md) | Day to day: logs, exec, debug, ephemeral containers, port-forward |
| [Controllers and the Reconciliation Pattern](docs/controllers.md) | The idea underpinning every workload object |
| [ReplicaSets](docs/replicasets.md) | Labels, selectors, ownership, adoption |
| [Deployments](docs/deployments.md) | The workhorse for stateless applications |
| [Deployment Strategies](docs/deployment-strategies.md) | Rolling updates, rollbacks, surge and unavailability, restarts, scaling |
| [DaemonSets](docs/daemonsets.md) | One pod per node, and update strategies that differ from Deployments |
| [StatefulSets](docs/statefulsets.md) | Stable identity, ordered rollout, per-replica storage |
| [Jobs](docs/jobs.md) | Run to completion, parallelism, backoff, failure handling |
| [CronJobs](docs/cronjobs.md) | Scheduled work, concurrency policy, missed schedules |
| [Pod Disruption Budgets](docs/pod-disruption-budgets.md) | Protecting availability during voluntary disruption |

---

## Part 3: Configuration

| Topic | What it covers |
|---|---|
| [ConfigMaps](docs/configmaps.md) | Configuration injection, and the update propagation behaviour that surprises people |
| [Secrets](docs/secrets.md) | Types, consumption patterns, and an honest account of their limitations |
| [The Downward API](docs/downward-api.md) | Exposing pod and container metadata to the application |

---

## Part 4: Storage

| Topic | What it covers |
|---|---|
| [Storage Overview](docs/storage.md) | The model, and how the pieces relate |
| [Volumes](docs/volumes.md) | Every volume type, including the dangerous ones |
| [Persistent Volumes and Claims](docs/persistent-volumes.md) | Binding, lifecycle, reclaim policies, access modes |
| [Storage Classes](docs/storage-classes.md) | Dynamic provisioning, parameters, expansion, defaults |
| [CSI](docs/csi.md) | The driver architecture. Controller and node plugins, sidecars, the RPC calls |
| [Volume Snapshots](docs/volume-snapshots.md) | Snapshot classes, restore, cloning |

### Installing Storage Drivers

| Guide |
|---|
| [NFS CSI Driver](docs/install-csi-nfs.md) |
| [SMB CSI Driver](docs/install-csi-smb.md) |

---

## Part 5: Networking

The largest and most feared area. Taken in this order it is tractable.

### Core Concepts

| Topic | What it covers |
|---|---|
| [Kubernetes Networking Fundamentals](docs/k8s-networking-fundamentals.md) | The four networking problems, and the rules every implementation must satisfy |
| [CNI](docs/cni.md) | The plugin interface, and what happens the moment a pod is created |
| [IPAM](docs/ipam.md) | How pods get addresses |
| [Overlay Networks](docs/overlay-networks.md) | VXLAN, IP-in-IP, and when you do not need them |

### Services and Traffic

| Topic | What it covers |
|---|---|
| [Services](docs/services.md) | ClusterIP, NodePort, LoadBalancer, ExternalName, headless |
| [Service Operations](docs/service-operations.md) | Debugging service connectivity end to end |
| [EndpointSlices](docs/endpointslices.md) | What actually backs a Service, and why Endpoints was replaced |
| [CoreDNS](docs/coredns.md) | Cluster DNS, resolution rules, and the ndots problem |
| [Ingress](docs/ingress.md) | HTTP routing, controllers, TLS |
| [Gateway API](docs/gateway-api.md) | The successor to Ingress, with proper role separation |
| [Network Policy](docs/network-policy.md) | Segmentation, default-deny, and what policies cannot do |

### Load Balancing on Bare Metal

| Topic | What it covers |
|---|---|
| [MetalLB](docs/metallb.md) | LoadBalancer Services without a cloud provider |
| [Installing MetalLB](docs/install-metallb.md) | Setup guide |

### Deep Networking Internals

Optional, but this is the material that separates competent from expert.

| Topic | What it covers |
|---|---|
| [NAT](docs/nat.md) | Source and destination translation, conntrack |
| [BGP](docs/bgp.md) | How Calico and MetalLB advertise routes |
| [ECMP](docs/ecmp.md) | Equal cost multipath and traffic distribution |
| [eBPF](docs/ebpf.md) | The technology behind Cilium and kube-proxy replacement |
| [Calico Network Interfaces: A Worked Example](docs/calico-network-interfaces-example.md) | Tracing real interfaces on a real node |

---

## Part 6: Scheduling and Resources

| Topic | What it covers |
|---|---|
| [Scheduling](docs/scheduling.md) | nodeSelector, affinity, taints and tolerations, topology spread, priority and preemption |
| [Resource Management](docs/resource-management.md) | Requests, limits, QoS classes, LimitRange, ResourceQuota, eviction |

---

## Part 7: Security

Read in this order. Each layer assumes the previous one.

| Topic | What it covers |
|---|---|
| [Certificates and the Cluster PKI](docs/certificates.md) | The three CAs, every file explained, renewal, SANs, the CSR API, creating users |
| [kubeconfig and Static Pod Manifests](docs/kubeconfig-and-manifests.md) | The files that carry credentials and start the control plane |
| [Authentication](docs/authentication.md) | Certificates, tokens, OIDC, webhooks. How identity is established |
| [Authorization](docs/authorization.md) | The authorizer chain: Node, RBAC, ABAC, Webhook, and impersonation |
| [RBAC](docs/rbac.md) | Roles, bindings, rule anatomy, least privilege recipes |
| [Service Accounts](docs/service-accounts.md) | Workload identity, projected tokens, the token volume |
| [Admission Control](docs/admission-controllers.md) | The gate after authorization. Built-in controllers and CEL policies |
| [Pod Security Standards](docs/pod-security-standards.md) | Baseline and Restricted, and the controller that enforces them |
| [Security Context](docs/security-context.md) | Every field, and what each becomes at the kernel level |
| [Encryption at Rest](docs/encryption-at-rest.md) | Protecting etcd data, providers, key rotation |
| [Audit Logging](docs/audit-logging.md) | The forensic record. Policy design and investigation queries |

---

## Part 8: Installing Kubernetes

| Topic | What it covers |
|---|---|
| [Installation Considerations](docs/k8s-installation-considerations.md) | Decisions to make before you start |
| [Installation Methods](docs/k8s-installation-methods.md) | kubeadm, managed, distributions, and the trade-offs |
| [Installation Requirements](docs/k8s-installation-requirements.md) | Hardware, OS, networking, ports |
| [Preparing a Linux Node](docs/preparing-linux-node.md) | Kernel modules, sysctls, swap, runtime prerequisites |
| [Cluster Networking Ports](https://kubernetes.io/docs/reference/networking/ports-and-protocols/) | Upstream reference for firewall rules |

### Installing Packages by Distribution

| Guide |
|---|
| [Debian and Ubuntu](docs/install-k8s-pkgs-debian.md) |
| [RHEL, Rocky and Alma](docs/install-k8s-pkgs-redhat.md) |
| [SUSE and openSUSE](docs/install-k8s-pkgs-suse.md) |

### Full Cluster Builds

| Guide | Notes |
|---|---|
| [Manual Cluster Installation](docs/manual-install-k8s-cluster.md) | End to end with a standard CNI |
| [Manual Installation with Cilium](docs/manual-install-k8s-cluster-cilium.md) | With kube-proxy replacement |

### Automated Lab Environments

- [server-hub](https://github.com/Muthukumar-Subramaniam/server-hub) for building the lab VMs
- [install-k8s-on-linux](https://github.com/Muthukumar-Subramaniam/install-k8s-on-linux) for Ansible-based cluster installation
- [Kubespray](https://kubespray.io/) for production-grade automation

---

## Part 9: Cluster Operations

| Topic | What it covers |
|---|---|
| [Cluster Upgrades](docs/cluster-upgrades.md) | Version skew policy, control plane and node upgrade procedure |

---

## 🚧 Roadmap

Planned documents, not yet written. Listed so the intended scope is visible, and deliberately not linked so that nothing here is a broken link.

**Getting Started**
`local-clusters` (kind, minikube, k3s) · `managed-kubernetes` (EKS, GKE, AKS) · `understanding-yaml` · `declarative-kubernetes`

**Security**
`cluster-hardening` · `runtime-class` · `image-security`

**Installation**
`installing-containerd` · `installing-k8s-packages` · `creating-control-plane` · `bootstrapping-kubeadm` · `adding-worker-node`

**Cluster Lifecycle**
`etcd-backup-restore` · `node-maintenance` · `ha-control-plane` · `static-pods` · `disaster-recovery`

**Extending Kubernetes**
`crds` · `operators` · `admission-webhooks` · `api-aggregation`

**Observability and Autoscaling**
`metrics-server` · `horizontal-pod-autoscaler` · `vertical-pod-autoscaler` · `cluster-autoscaler` · `monitoring` · `logging` · `events` · `debugging`

**Application Delivery**
`helm` · `kustomize` · `gitops`

**Other**
`troubleshooting` · `service-mesh` · `cluster-addons` · `cni-comparison` · `certification-guide`

---

## 📄 License

See [LICENSE](LICENSE).
