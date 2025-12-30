# A deep dive into the world of [Kubernetes](https://kubernetes.io/)
## Kubernetes Installation and Configuration Fundamentals
### Exploring the Kubernetes Architecture
* [Containers: What They Are and Why They're Changing the World](docs/containers.md)
* [What Is Docker and Why Container Orchestration Is Required](docs/docker-and-orchestration.md)
* [What Is Kubernetes?](docs/what-is-kubernetes.md)
  * [Where Is Kubernetes?](https://github.com/kubernetes/kubernetes) - Official GitHub Repository
  * Why is it called K8s? - Covered in [What Is Kubernetes](docs/what-is-kubernetes.md)
  * K8s Benefits and Operating Principles - Covered in [What Is Kubernetes](docs/what-is-kubernetes.md)
* [What Are Microservices?](docs/microservices.md)
* [K8s Cluster Architecture Overview](https://kubernetes.io/docs/concepts/architecture/)
  * [Control Plane Nodes](docs/control-plane-node.md)
    * [kube-apiserver](docs/kube-apiserver.md)
    * [etcd](docs/etcd.md)
    * [kube-scheduler](docs/kube-scheduler.md)
    * [kube-controller-manager](docs/kube-controller-manager.md)
  * [Worker Nodes](docs/worker-node.md)
    * [kubelet](docs/kubelet.md)
    * [kube-proxy](docs/kube-proxy.md)
    * [container runtime](docs/container-runtime.md)
* [k8s Networking Fundamentals](docs/k8s-networking-fundamentals.md)
* [Introducing the Kubernetes API - Objects and API Server](docs/k8s-api.md)
* [Understanding API Objects - Pods](docs/pods.md)
* [Understanding API Objects - Controllers](docs/controllers.md)
* [Understanding API Objects - Services](docs/services.md)
* [Understanding API Objects - Storage](docs/storage.md)
* [Cluster Add-on Pods](docs/cluster-addons.md)
* [Pod Operations](docs/pod-operations.md)
* [Service Operations](docs/service-operations.md)

### Installing and Configuring K8s
* [Installation Considerations](docs/k8s-installation-considerations.md)
* [Installation Methods](docs/k8s-installation-methods.md)
* [Installation Requirements](docs/k8s-installation-requirements.md)
* [Understanding Cluster Networking Ports](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
* Installing K8s on VMs
  * [Preparing the Linux Node](docs/preparing-linux-node.md)
  * [Installing and Configuring containerd](docs/installing-containerd.md)
  * [Installing and Configuring K8s Packages](docs/installing-k8s-packages.md)
  * [Creating a Cluster Control Plane Node](docs/creating-control-plane.md)
  * [Bootstrapping a Cluster with kubeadm](docs/bootstrapping-kubeadm.md)
  * [Understanding the Certificate Authority's Role in Your Cluster](docs/certificates.md)
  * [kubeadm Created kubeconfig Files and Static Pod Manifests](docs/kubeconfig-and-manifests.md)
  * [Adding a Worker Node to Your Cluster](docs/adding-worker-node.md)
* Setting up Your Own K8s Cluster for Testing
  * [Click Here to Go to Github Repo for Creating a Automation Lab Environment](https://github.com/Muthukumar-Subramaniam/server-hub)
    * How to Perform a Manual Cluster Installation
      * [Click Here to Go to Github Document for Manual Installation of Cluster](docs/manual-install-k8s-cluster.md)
    * How to Perform a Automated Cluster Installation Using Ansible
      * Ansible Project for Testing Environments - [install-k8s-on-linux](https://github.com/Muthukumar-Subramaniam/install-k8s-on-linux)
      * Production Level and Advanced Customizations - [Kubespray](https://kubespray.io/#/)
 

### Fundamentals to work with k8s cluster
* [Introducing and Using kubectl](docs/kubectl.md)
* [Imperative way of managing the configurations and deployment of resources](docs/imperative-kubernetes.md)
* [Understanding YAML and YAML manifests](docs/understanding-yaml.md)
* [Declarative way of managing the configurations and deployment of resources](docs/declarative-kubernetes.md)


## Managing Kubernetes Controllers and Deployments
### Using Controllers to Deploy Applications and Deployment Basics  
* [Kubernetes Principals, the Controller Manager, and Introduction to Controllers](docs/controllers.md)  
* [Examining System Pods and Their Controllers](docs/controllers.md#system-controllers)	 
* [Introducing the Deployment Controller and Deployment Basics](docs/deployments.md)	 
* [Creating a Basic Deployment Imperatively and Declaratively](docs/deployments.md#creating-deployments)	 
* [Understanding ReplicaSet Controller Operations](docs/replicasets.md)	 
* [Creating a Deployment and ReplicaSet Controller](docs/replicasets.md#creating-replicasets)  
* [ReplicaSet Controller Operations - Working with Labels and Selectors](docs/replicasets.md#labels-and-selectors)  
* [ReplicaSet Controller Operations - Node Failures](docs/replicasets.md#handling-failures)	 

### Maintaining Applications with Deployments  
* [Updating a Deployment and Checking Deployment Rollout Status](docs/deployment-strategies.md#rolling-updates)	 
* [Using Deployments to Change State and Controlling Updates with UpdateStrategy](docs/deployment-strategies.md#update-strategies)	 
* [Pausing and Rolling Back Deployments](docs/deployment-strategies.md#rollbacks)	 
* [Rolling Back a Deployment and Controlling the Rate of a Rollout](docs/deployment-strategies.md#controlling-rollout-rate)	 
* [Using UpdateStrategy and Readiness Probes to Control a Rollout](docs/deployment-strategies.md#readiness-probes)	 
* [Restarting a Deployment](docs/deployment-strategies.md#restarting-deployments)  	 
* [Scaling Deployments](docs/deployment-strategies.md#scaling)  

### Deploying and Maintaining Applications with DaemonSets and Jobs
* [Controllers in Kubernetes and Understanding DaemonSets](docs/daemonsets.md)	 
* [Updating DaemonSets](docs/daemonsets.md#updating-daemonsets)	 
* [Creating and DaemonSets Controller Operations](docs/daemonsets.md#creating-daemonsets)	 
* [Creating DaemonSets with NodeSelectors and Updating DaemonSets](docs/daemonsets.md#node-selectors)	 
* [Introducing and Working with Jobs](docs/jobs.md)	 
* [Introducing and Working with CronJobs](docs/cronjobs.md)	 
* [Executing Tasks with Jobs](docs/jobs.md#executing-jobs)	 
* [Dealing with Job Failures and restartPolicy](docs/jobs.md#handling-failures)	 	
* [Working with Parallel Jobs and Scheduling Tasks with CronJobs](docs/jobs.md#parallel-jobs)  
* [Introducing StatefulSets](docs/statefulsets.md)	 
