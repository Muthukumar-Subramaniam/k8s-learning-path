#!/bin/bash
cd /server-hub/k8s/httpd
kubectl apply -f httpd-deployment.yaml 
kubectl apply -f httpd-service.yaml 
