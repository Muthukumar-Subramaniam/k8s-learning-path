# Manual, the hard way of installing kubeadm-based [Kubernetes](https://kubernetes.io/) cluster on Linux from scratch ( with Cilium CNI & kube-proxy disabled )

----  
This documentation is designed for manually installing kubeadm-based [Kubernetes](https://kubernetes.io/) cluster on Linux from scratch for development and testing environment, with a single control plane or HA control plane, using [the most recent stable Kubernetes release](https://github.com/kubernetes/kubernetes/releases/latest).  

This variant uses **Cilium** as the CNI plugin with **kube-proxy replacement** enabled, leveraging eBPF for high-performance dataplane operations.

**Suitable Environment:** Development & Testing

**System Requirements:** Minimum 2 GB RAM & 2 vCPU ( kernel >= 5.10 recommended for full eBPF features )

**Supported Platforms:** Baremetal, Virtual Machines, Cloud Instances

### Supported Linux distributions: 
* RedHat-based ( Fedora, RHEL, Rocky Linux, Almalinux, Oracle Linux ) 
* Debian-based  ( Debian, Ubuntu )
* SUSE-based  ( OpenSUSE, SLES )

### Prerequisites:
* Prepare the cluster nodes by installing any of the above mentioned supported Linux distributions, even with a minimal installation.
* Please make sure the cluster nodes are on the same subnet and there are no network comunication issues between the nodes.
* Please ensure that you have DNS set up that resolves all the involved hosts, or update the host files on all hosts with the necessary entries for each involved host.
* Ensure you have a common user in all the nodes which has passwordless sudo privileges.
* For HA cluster setups, ensure that the control plane endpoint is configured via a load balancer such as NGINX, HAProxy, or any load balancer of your choice.
* Kernel version >= 5.10 is recommended for full Cilium eBPF feature support. Verify with `uname -r`.
 
### The main components of the installation.   
* Container orchestrator: [kubernetes](https://github.com/kubernetes/kubernetes)
* Container runtime: [containerd](https://github.com/containerd/containerd)  
* Low-level container runtime: [runc](https://github.com/opencontainers/runc) ( dependency for containerd )  
* CNI plugin: [cilium](https://github.com/cilium/cilium) ( with kube-proxy replacement )

### Optional components that can be installed once the cluster is ready.  
* [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs)
* [csi-driver-smb](https://github.com/kubernetes-csi/csi-driver-smb)
* [MetalLB](https://github.com/metallb/metallb) LoadBalancer

## Installation Steps 
----
### Step 1 ) Turn of swap in all the nodes
----
```
sudo swapoff -a && sudo sed -i '/swap/s/^/#/' /etc/fstab
```

### Step 2 ) Upgrade system packages and install some required packages  
----
#### If your linux distro is RedHat-based 
```
sudo dnf clean all && sudo dnf update --refresh -y && sudo dnf install -y curl wget rsync jq
```
#### If your linux distro is Debian-based 
```
sudo apt clean all && sudo apt update && sudo apt upgrade -y && sudo apt install -y curl wget rsync jq
```
#### If your linux distro is SUSE-based 
```
sudo zypper clean -a && sudo zypper rr && sudo zypper update -y && sudo zypper install -y curl wget rsync jq
```
#### Reboot the system if the above system packages upgrade requires it 
```
sudo reboot
```
### Step 3) Load required kernel modules
----
```
(echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/k8s.conf >/dev/null) && (xargs -r -a /etc/modules-load.d/k8s.conf -n1 sudo modprobe) && (lsmod | grep -E "overlay|br_netfilter")
```
### Step 4) Load required kernel parameters
----
```
(echo -e "net.ipv4.ip_forward = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1" | sudo tee /etc/sysctl.d/k8s.conf >/dev/null) && sudo sysctl --system
```
### Step 5) Download and setup the latest version of runc binary
----
```
runc_vers=$(curl -s -L https://api.github.com/repos/opencontainers/runc/releases/latest | jq -r '.tag_name' 2>>/dev/null | tr -d '[:space:]') && echo "latest runc version : ${runc_vers}"
```
```
sudo wget -O /usr/bin/runc https://github.com/opencontainers/runc/releases/download/"${runc_vers}"/runc.amd64 && sudo chmod +x /usr/bin/runc
```
```
runc --version
```
### Step 6) Download containerd binary and setup containerd service
----
```
containerd_vers=$(curl -s -L https://api.github.com/repos/containerd/containerd/releases/latest | jq -r '.tag_name' 2>>/dev/null | tr -d '[:space:]') && echo "latest containerd version : ${containerd_vers}"
```
```
mkdir -p containerd && wget -P containerd/ https://github.com/containerd/containerd/releases/download/"${containerd_vers}"/containerd-"${containerd_vers:1}"-linux-amd64.tar.gz
```
```
tar Cxzvf containerd/ containerd/containerd-"${containerd_vers:1}"-linux-amd64.tar.gz
```
```
chmod -R +x containerd/bin && sudo chown -R root:root containerd/bin
```
```
sudo rsync -avPh containerd/bin/ /usr/bin/ && sudo rm -rf containerd
```
```
containerd --version
```
```
sudo mkdir -p /etc/containerd && ( containerd config default | sudo tee /etc/containerd/config.toml )
```
```
(if grep -q SystemdCgroup /etc/containerd/config.toml; then sudo sed -i '/SystemdCgroup/s/false/true/' /etc/containerd/config.toml; else sudo sed -i '/containerd\.runtimes\.runc\.options/ a\            SystemdCgroup = true' /etc/containerd/config.toml; fi) && (containerd config dump | grep -B 10 SystemdCgroup)
```
```
sudo wget -P /etc/systemd/system/ https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
```
```
sudo sed -i "s|usr/local/bin|usr/bin|g" /etc/systemd/system/containerd.service
```
```
sudo systemctl daemon-reload && sudo systemctl enable --now containerd.service && sudo systemctl status containerd.service --no-pager
```

### Step 7) Configure kubernetes repo and install kubeadm, kubectl and kubelet packages
----
#### [Click here if RedHat-based systems](install-k8s-pkgs-redhat.md)  

#### [Click here if Debian-based systems](install-k8s-pkgs-debian.md)  

#### [Click here if SUSE-based systems](install-k8s-pkgs-suse.md)  

### Step 8) Allow networks in firewalld if running in case of RedHat-based or SUSE-based systems
----
```
k8s_pod_network_cidr="10.8.0.0/22" # Pod Network of your choice
```
```
sudo firewall-cmd --permanent --zone=trusted --add-source="${k8s_pod_network_cidr}"
```
```
sudo firewall-cmd --permanent --zone=trusted --add-source=< cluster mgmt network cidr >
```
```
sudo firewall-cmd --permanent --add-port=4240/tcp   # Cilium health checks
```
```
sudo firewall-cmd --permanent --add-port=4244/tcp   # Hubble Relay
```
```
sudo firewall-cmd --permanent --add-port=4245/tcp   # Hubble UI
```
```
sudo firewall-cmd --permanent --add-port=8472/udp   # VXLAN overlay (if using VXLAN mode)
```
```
sudo firewall-cmd --reload
```

### Step 9) Install Cilium CLI on the control plane node
----
```
cilium_cli_vers=$(curl -s -L https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt | tr -d '[:space:]') && echo "latest cilium-cli version : ${cilium_cli_vers}"
```
```
wget https://github.com/cilium/cilium-cli/releases/download/"${cilium_cli_vers}"/cilium-linux-amd64.tar.gz
```
```
sudo tar xzvf cilium-linux-amd64.tar.gz -C /usr/local/bin && rm -f cilium-linux-amd64.tar.gz
```
```
cilium version --client
```

### ⚠️ Step 10) Configure the Control Plane ( with kube-proxy disabled )
> **🚨 CAUTION:**  
>\> This step must be executed ONLY on the control plane node.  
>\> If you are setting up HA control plane, run only on one of the control plane node.  
----
```
sudo systemctl enable --now kubelet.service && sudo systemctl status kubelet.service --no-pager
```
```
sudo kubeadm config images pull
```
```
k8s_pod_network_cidr="10.8.0.0/22" # Pod Network of your choice
```
> **Important:** We use `--skip-phases=addon/kube-proxy` to skip kube-proxy installation since Cilium will replace it entirely using eBPF.

> In case of Single Control Plane Setup
```
sudo kubeadm init --pod-network-cidr="${k8s_pod_network_cidr}" --skip-phases=addon/kube-proxy
```  
> ( Or )
>  In case of HA Control Plane Setup
```
sudo kubeadm init --pod-network-cidr="${k8s_pod_network_cidr}" --control-plane-endpoint <fqdn of control-plane-endpoint>:6443 --skip-phases=addon/kube-proxy
```
create kube config file in the home directory
```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```
control plane node still won't be ready and all system pods would be running expect for core-dns in pending state, it is because we are yet to install a CNI for our cluster
```
kubectl get nodes -o wide
```
```
kubectl get pods -A
```

### Step 11) Install Cilium CNI with kube-proxy replacement
----
Identify the Kubernetes API server address ( needed for kube-proxy replacement )

> In case of Single Control Plane Setup
```
k8s_api_server_ip=$(kubectl get endpointslice -n default -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].endpoints[0].addresses[0]}')
k8s_api_server_port=$(kubectl get endpointslice -n default -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].ports[0].port}')
echo "API Server: ${k8s_api_server_ip}:${k8s_api_server_port}"
```
> ( Or )
> In case of HA Control Plane Setup, use the control-plane-endpoint FQDN
```
k8s_api_server_ip="<fqdn of control-plane-endpoint>"
k8s_api_server_port="6443"
```

Now install Cilium with kube-proxy replacement enabled
```
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${k8s_api_server_ip}" \
  --set k8sServicePort="${k8s_api_server_port}" \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="${k8s_pod_network_cidr}"
```
Now wait for Cilium to be ready
```
cilium status --wait
```
Verify kube-proxy replacement is active
```
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
```
Expected output should show: `KubeProxyReplacement: True`

Now wait for all the pods to be running including core-dns
```
kubectl get pods -A --watch
```
Once all pods are running, now the control plane becomes ready
```
kubectl get nodes -o wide
```
Update your bashrc file for kubectl command arguement tab completion
```
echo 'source <(kubectl completion bash)' >> "${HOME}"/.bashrc
source "${HOME}"/.bashrc
```
To create join command to join worker nodes with the cluster, run the below
```
sudo kubeadm token create --print-join-command
```
In case of HA Control Plane Setup, to create join command to join remaining control plane nodes with the cluster, run the below
```
sudo kubeadm token create --print-join-command --certificate-key $(sudo kubeadm init phase upload-certs --upload-certs | tail -n 1 | tr -d '[:space:]')
```

### ⚠️ Step 12) Now run the above printed kubeadm join command in worker nodes and remaining control plane nodes ( in case of HA cluster ) to join them to the K8s cluster
> **🚨 CAUTION:**  
> \> Do NOT run the `kubeadm join` command on the control plane node where you performed `kubeadm init`, can result in serious cluster issues, including duplicate control plane components and API server disruptions.  

If the join command succeeds, the kubelet service should be running now in the worker nodes and remaining control plane nodes ( in case of HA cluster ).
```
sudo systemctl status kubelet.service --no-pager
```
### Step 13) Now go to control plane node to check nodes and pod details, you could find pods running in worker nodes as well, it might take a little time for all the pods to be in running state.
```
kubectl get pods -A -o wide --watch
```
```
kubectl get nodes -o wide
```

### Step 14) Validate Cilium connectivity across the cluster
```
cilium connectivity test
```
This runs a comprehensive set of connectivity tests to ensure pod-to-pod, pod-to-service, and external connectivity is working correctly through the Cilium eBPF dataplane.

### Optional Step 15) Put a worker role label for worker nodes for identification
```
kubectl label node $(kubectl get nodes --no-headers | grep -i -v 'control-plane' | awk '{print $1}' | tr '\n' ' ') node-role.kubernetes.io/worker=true
```
```
kubectl get nodes -o wide
```

### Optional Step 16) Enable Hubble Observability ( Cilium's built-in network observability layer )
Install the Hubble CLI
```
hubble_vers=$(curl -s -L https://raw.githubusercontent.com/cilium/hubble/main/stable.txt | tr -d '[:space:]') && echo "latest hubble-cli version : ${hubble_vers}"
```
```
wget https://github.com/cilium/hubble/releases/download/"${hubble_vers}"/hubble-linux-amd64.tar.gz
```
```
sudo tar xzvf hubble-linux-amd64.tar.gz -C /usr/local/bin && rm -f hubble-linux-amd64.tar.gz
```
```
hubble version
```
Enable Hubble in the cluster
```
cilium hubble enable --ui
```
```
cilium hubble port-forward &
```
```
hubble status
```

## Now the cluster is ready for deployments if all nodes are in ready state.

### Addons for the Cluster for Networking and Storage needs

#### [ Click Here to Configure metallb for Your Cluster ](install-metallb.md)  

#### [ Click Here to Configure CSI NFS driver for Your Cluster ](install-csi-nfs.md)  

#### [ Click Here to Configure CSI SMB driver for Your Cluster ](install-csi-smb.md)  
