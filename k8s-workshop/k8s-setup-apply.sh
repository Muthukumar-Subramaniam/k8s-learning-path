#!/bin/bash
clear
cd /server-hub/k8s
./apply-nfs-setup.sh
kubectl apply -f ./httpd/httpd-all-in-one.yaml
kubectl apply -f ./nginx/nginx-all-in-one.yaml
echo -e "\nExecuting : kubectl get all\n"
kubectl get all
echo ""
