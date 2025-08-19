#### Set a variable for latest version of k8s by fetching the version info from github api
```
k8s_vers=$(curl -s -L https://api.github.com/repos/kubernetes/kubernetes/releases/latest | jq -r '.tag_name' 2>>/dev/null | tr -d '[:space:]') && echo "latest kubernetes version : ${k8s_vers}"
```
#### Set a variable for the major version number of k8s to configure repo
```
k8s_vers_major=$(echo "${k8s_vers}" | cut -d "." -f 1)
k8s_vers_minor=$(echo "${k8s_vers}" | cut -d "." -f 2)
k8s_vers_major_minor="${k8s_vers_major}.${k8s_vers_minor}"
```
#### Configure kubernetes repo
```
echo "deb [signed-by=/etc/apt/keyrings/k8s-apt-keyring-${k8s_vers_major_minor}.gpg] https://pkgs.k8s.io/core:/stable:/${k8s_vers_major_minor}/deb/ /" | sudo tee /etc/apt/sources.list.d/k8s.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/"${k8s_vers_major_minor}"/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/k8s-apt-keyring-"${k8s_vers_major_minor}".gpg		
```
#### Install kubeadm, kubelet and kubectl packages
```
sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl && sudo apt-mark hold kubelet kubeadm kubectl
```
#### Enable kubelet service
```
sudo systemctl enable kubelet
```
[Click here to go back to next step in main document](manual-install-k8s-cluster.md#step-8-allow-networks-in-firewalld-if-running-in-case-of-redhat-based-or-suse-based-systems)
