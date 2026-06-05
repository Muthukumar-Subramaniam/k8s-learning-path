#!/bin/bash
if [ -z "${1}" ]; then
    read -rp "Enter the domain name (e.g., user.internal): " domain
else
    domain="${1}"
fi

#To List pods on a specific node
kubectl get pods --all-namespaces --field-selector spec.nodeName=k8s-cp1.${domain}
kubectl get pods --all-namespaces --field-selector spec.nodeName=k8s-w1.${domain}
kubectl get pods --all-namespaces --field-selector spec.nodeName=k8s-w2.${domain}

