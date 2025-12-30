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
cat << EOF | sudo tee /etc/yum.repos.d/k8s.repo
[k8s-${k8s_vers_major_minor}]
name=k8s-${k8s_vers_major_minor}
baseurl=https://pkgs.k8s.io/core:/stable:/${k8s_vers_major_minor}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${k8s_vers_major_minor}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl
EOF
```
#### Install kubeadm, kubelet and kubectl packages
```
sudo dnf makecache && sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=k8s-"${k8s_vers_major_minor}"
```
#### Enable kubelet service
```
sudo systemctl enable kubelet
```
[Click here to go back to next step in main document](manual-install-k8s-cluster.md#step-8-allow-networks-in-firewalld-if-running-in-case-of-redhat-based-or-suse-based-systems)
