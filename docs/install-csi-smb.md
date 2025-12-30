### Get latest version information of csi-driver-smb from GitHub API
```
csi_driver_smb_vers=$(curl -s -L https://api.github.com/repos/kubernetes-csi/csi-driver-smb/releases/latest | jq -r '.tag_name' 2>>/dev/null | tr -d '[:space:]') && echo "latest csi-driver-smb version : ${csi_driver_smb_vers}"
```
### Install csi_smb_driver ( remote install with kubectl using GitHub repo script )
```
curl -skSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/${csi_driver_smb_vers}/deploy/install-driver.sh" | bash -s "${csi_driver_smb_vers}" --
```
### Wait for all csi-smb-driver pods to be in running state
```
kubectl get pods -n kube-system --no-headers -l "app in (csi-smb-node, csi-smb-controller) --watch
```

[Click Here to Go Back to Main Documenation](manual-install-k8s-cluster.md#addons-for-the-cluster-for-networking-and-storage-needs)
