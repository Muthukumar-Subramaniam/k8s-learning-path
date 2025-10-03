#!/bin/bash
clear
cd /server-hub/k8s
kubectl delete -f ./nginx/nginx-all-in-one.yaml
kubectl delete -f ./httpd/httpd-all-in-one.yaml
./delete-nfs-setup.sh

echo -e "\nExecuting : kubectl get all\n"
kubectl get all
echo ""
