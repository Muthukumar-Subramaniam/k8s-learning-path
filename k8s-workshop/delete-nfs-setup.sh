#!/bin/bash
cd /server-hub/k8s
kubectl delete -f nfs-pvc-web-share.yaml
kubectl delete -f nfs-pv-web-share.yaml
