#!/bin/bash
cd /server-hub/k8s/httpd
kubectl delete -f httpd-service.yaml 
kubectl delete -f httpd-deployment.yaml 
