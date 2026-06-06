#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

domain="${USER}.internal"

nfs_server="tux2lab-engine.${domain}"

for manifest in [0-9]-*.yaml; do
    sed "s/__DOMAIN__/${domain}/g; s/__NFS_SERVER__/${nfs_server}/g" "${manifest}" | kubectl apply -f -
done
