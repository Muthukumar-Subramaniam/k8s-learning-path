### Get latest version information of csi-driver-nfs from GitHub API
```
csi_driver_nfs_vers=$(curl -s -L https://api.github.com/repos/kubernetes-csi/csi-driver-nfs/releases/latest | jq -r '.tag_name' 2>>/dev/null | tr -d '[:space:]') && echo "latest csi-driver-nfs version : ${csi_driver_nfs_vers}"
```
### Install csi_nfs_driver ( remote install with kubectl using GitHub repo script )
```
curl -skSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/${csi_driver_nfs_vers}/deploy/install-driver.sh" | bash -s "${csi_driver_nfs_vers}" --
```
### Wait for all csi-nfs-driver pods to be in running state
```
kubectl get pods -n kube-system --no-headers -l "app in (csi-nfs-node, csi-nfs-controller) --watch
```

[Click Here to Go Back to Main Documenation](manual-install-k8s-cluster.md#addons-for-the-cluster-for-networking-and-storage-needs)
