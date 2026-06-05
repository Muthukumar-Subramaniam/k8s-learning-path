#!/bin/bash
set -euo pipefail

if [ -z "${1:-}" ]; then
    read -rp "Enter the domain name (e.g., user.internal): " domain
else
    domain="${1}"
fi
nfs_server="tux2lab-engine.${domain}"

kubectl delete -f nfs-pvc-web-share.yaml
sed "s/__DOMAIN__/${domain}/g; s/__NFS_SERVER__/${nfs_server}/g" nfs-pv-web-share.yaml | kubectl delete -f -
