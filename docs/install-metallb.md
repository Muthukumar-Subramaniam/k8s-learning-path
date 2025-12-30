### Get latest version information of MetalLB from GitHub API
```
metallb_vers=$(curl -s -L https://api.github.com/repos/metallb/metallb/releases/latest | jq -r '.tag_name' 2>>/dev/null | tr -d '[:space:]') && echo "latest metallb version : ${metallb_vers}"
```
### Install MetalLB using manifest from GitHub with kubectl
```
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${metallb_vers}/config/manifests/metallb-native.yaml
```
### Wait for all MetalLB pods to be in running state
```
kubectl get pods -n metallb --watch
```
### Create MetalLB IPAddressPool and L2Advertisement manifest
```
cat << EOF >metallb-IPAddressPool-L2Advertisement.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: k8s-metallb-ip-pool
  namespace: metallb-system
spec:
  addresses:
# Reserve IP Range for MetalLB LoadBalancer from your Cluster MGMT Network
# ( Note : This is not your pod_network_cidr )
# You need to change the below as per your MGMT Network
  - 10.10.20.201-10.10.20.255

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - k8s-metallb-ip-pool
EOF
```
### Apply MetalLB IPAddressPool and L2Advertisement manifest
```
kubectl apply -f metallb-IPAddressPool-L2Advertisement.yaml
```
### Validate
```
kubectl get ipaddresspools.metallb.io -n metallb-system
```
[Click Here to Go Back to Main Documenation](manual-install-k8s-cluster.md#addons-for-the-cluster-for-networking-and-storage-needs)

