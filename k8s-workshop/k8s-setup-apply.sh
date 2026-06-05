#!/bin/bash
set -euo pipefail
clear
cd "$(dirname "$0")"

if [ -z "${1:-}" ]; then
    read -rp "Enter the domain name (e.g., user.internal): " domain
else
    domain="${1}"
fi
nfs_server="tux2lab-engine.${domain}"

./apply-nfs-setup.sh "${domain}"
sed "s/__DOMAIN__/${domain}/g; s/__NFS_SERVER__/${nfs_server}/g" ./httpd/httpd-all-in-one.yaml | kubectl apply -f -
sed "s/__DOMAIN__/${domain}/g; s/__NFS_SERVER__/${nfs_server}/g" ./nginx/nginx-all-in-one.yaml | kubectl apply -f -
echo -e "\nExecuting : kubectl get all\n"
kubectl get all
echo ""
