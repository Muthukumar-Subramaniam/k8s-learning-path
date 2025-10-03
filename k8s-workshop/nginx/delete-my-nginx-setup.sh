#!/bin/bash
cd /server-hub/k8s/nginx
kubectl delete -f nginx-service.yaml 
kubectl delete -f nginx-deployment.yaml 
