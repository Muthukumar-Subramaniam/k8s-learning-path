#!/bin/bash

#To List pods on a specific node
kubectl get pods --all-namespaces --field-selector spec.nodeName=k8s-cp1.lab.local
kubectl get pods --all-namespaces --field-selector spec.nodeName=k8s-w1.lab.local
kubectl get pods --all-namespaces --field-selector spec.nodeName=k8s-w2.lab.local

