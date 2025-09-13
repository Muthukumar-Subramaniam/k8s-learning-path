# A deep dive into the world of [Kubernetes](https://kubernetes.io/)
## Kubernetes Installation and Configuration Fundamentals
### Exploring the Kubernetes Architecture
* [Containers: What They Are and Why They're Changing the World](containers.md)
* What Is [Docker](https://www.docker.com/) and Why Container Orchestration Is Required
* [What Is Kubernetes?](https://kubernetes.io/)
* [Where Is Kubernetes?](https://github.com/kubernetes/kubernetes)
* [Why is it called K8s?](https://kubernetes.io/docs/concepts/overview/)
* [K8s Benefits and Operating Principles](https://kubernetes.io/docs/concepts/overview/)
* What Are Microservices?
* [K8s Cluster Architecture Overview](https://kubernetes.io/docs/concepts/architecture/)
  * [Control Plane Nodes](control-plane-node.md)
    * [kube-apiserver](kube-apiserver.md)
    * [etcd](etcd.md)
    * [kube-scheduler](kube-scheduler.md)
    * [kube-controller-manager](kube-controller-manager.md)
  * [Worker Nodes](worker-node.md)
    * [kubelet](kubelet.md)
    * [kube-proxy](kube-proxy.md)
    * [container runtime](container-runtime.md)
* [k8s Networking Fundamentals](k8s-networking-fundamentals.md)
* Introducing the Kubernetes API - Objects and API Server
* [Understanding API Objects - Pods](pods.md)
* Understanding API Objects - Controllers
* Understanding API Objects - Services
* Understanding API Objects - Storage
* Cluster Add-on Pods
* Pod Operations
* Service Operations

### Installing and Configuring K8s
* [Installation Considerations](k8s-installation-considerations.md)
* [Installation Methods](k8s-installation-methods.md)
* [Installation Requirements](k8s-installation-requirements.md)
* [Understanding Cluster Networking Ports](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
* Installing K8s on VMs
  * Preparing the linux node
  * Installing and Configuring containerd
  * Installing and Configuring K8s Packages
  * Creating a Cluster Control Plane Node
  * Bootstrapping a Cluster with kubeadm
  * Understanding the Certificate Authority's Role in Your Cluster
  * kubeadm Created kubeconfig Files and Static Pod Manifests
  * Adding a Worker Node to Your Cluster
* Setting up Your Own K8s Cluster for Testing
  * [Click Here to Go to Github Repo for Creating a Automation Lab Environment](https://github.com/Muthukumar-Subramaniam/server-hub)
    * How to Perform a Manual Cluster Installation
      * [Click Here to Go to Github Document for Manual Installation of Cluster](manual-install-k8s-cluster.md)
    * How to Perform a Automated Cluster Installation Using Ansible
      * Ansible Project for Testing Environments - [install-k8s-on-linux](https://github.com/Muthukumar-Subramaniam/install-k8s-on-linux)
      * Production Level and Advanced Customizations - [Kubespray](https://kubespray.io/#/)
 

### Fundamentals to work with k8s clsuter
* [Introducing and Using kubectl](kubectl.md)
* [Imperative way of managing the configurations and deployment of resources.](imperative-kubernetes.md)
* Understanding [YAML](https://yaml.org/) and YAML manifests.
* Declerative way of managing the configurations and deployment of resources.


## Managing Kubernetes Controllers and Deployments
### Using Controllers to Deploy Applications and Deployment Basics  
* Kubernetes Principals, the Controller Manager, and Introduction to Controllers  
* Examining System Pods and Their Controllers	 
* Introducing the Deployment Controller and Deployment Basics	 
* Creating a Basic Deployment Imperatively and Declaratively	 
* Understanding ReplicaSet Controller Operations	 
* Creating a Deployment and ReplicaSet Controller  
* ReplicaSet Controller Operations - Working with Labels and Selectors  
* ReplicaSet Controller Operations - Node Failures	 
