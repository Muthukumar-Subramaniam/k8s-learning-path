for i in k8s-cp{1..3}.${dnsbinder_domain}; do echo "Host : $i";ssh "$i" "kubectl exec -n kube-system etcd-$i -- etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
endpoint status --write-out=table";echo;done
