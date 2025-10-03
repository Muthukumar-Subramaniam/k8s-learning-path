#!/bin/bash
cd /server-hub/k8s/nginx
kubectl apply -f nginx-deployment.yaml 
kubectl apply -f nginx-service.yaml 
