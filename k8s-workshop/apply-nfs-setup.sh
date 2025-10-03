#!/bin/bash
cd /server-hub/k8s
kubectl apply -f nfs-pv-web-share.yaml
kubectl apply -f nfs-pvc-web-share.yaml
