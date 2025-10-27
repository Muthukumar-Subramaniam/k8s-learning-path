#!/bin/bash
kubectl create namespace ingress-nginx
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml
kubectl patch svc ingress-nginx-controller -n ingress-nginx   -p '{"spec": {"type": "LoadBalancer"}}'
