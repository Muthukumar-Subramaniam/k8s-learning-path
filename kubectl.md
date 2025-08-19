# ⚡ `kubectl` — Kubernetes CLI Power Guide

`kubectl` is the primary command-line tool to interact with your Kubernetes cluster via the **API server**.

It lets you **create**, **inspect**, **modify**, and **delete** Kubernetes resources.

---

## 📂 kubeconfig — Cluster Access Credentials

### 🔐 What is it?

`kubectl` uses a config file called `**kubeconfig**` to:
- Authenticate to the API server
- Select the current context (cluster + user + namespace)
- Store certificates, tokens, and endpoint info

### 📍 Default location:
```bash
~/.kube/config
```

You can override it using:
```bash
kubectl --kubeconfig /path/to/other/config ...
```

Or set an environment variable:
```bash
export KUBECONFIG=/path/to/myconfig
```

### 🔧 To set up after kubeadm init:
```bash
mkdir -p ~/.kube
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
```

---

## 🧰 Most Frequently Used `kubectl` Commands

### 📊 Cluster Info

```bash
kubectl cluster-info
kubectl get nodes
kubectl get componentstatuses  # Deprecated but used in older clusters
```

---

### 📦 Pods, Deployments, Services

```bash
kubectl get pods
kubectl get pods -A                 # All namespaces
kubectl get pods -n <namespace>
kubectl describe pod <pod-name>

kubectl get deployments
kubectl describe deployment <name>

kubectl get svc
kubectl describe svc <name>
```

---

### 🚀 Creating Resources

```bash
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=NodePort

kubectl run busybox --image=busybox -it --rm -- /bin/sh
```

---

### 🔁 Updating and Managing

```bash
kubectl edit deployment nginx         # Opens editor to live-edit
kubectl scale deployment nginx --replicas=5
kubectl rollout restart deployment nginx
kubectl rollout status deployment nginx
kubectl set image deployment/nginx nginx=nginx:1.21
```

---

### 🗑 Deleting Resources

```bash
kubectl delete pod <name>
kubectl delete deployment <name>
kubectl delete svc <name>
kubectl delete -f <file>.yaml
```

---

## 🧩 Working with YAML (Declarative Style)

```bash
kubectl apply -f deployment.yaml
kubectl get -f deployment.yaml
kubectl delete -f deployment.yaml
```

---

## 📄 Output Formatting

```bash
kubectl get pods -o wide
kubectl get pod <name> -o yaml
kubectl get pod <name> -o json
kubectl get pod <name> -o jsonpath='{.status.podIP}'
kubectl get pods -w            # Watch for changes
```

---

## 🐚 Exec and Logs

```bash
kubectl exec -it <pod> -- /bin/sh
kubectl exec -it <pod> -c <container> -- /bin/bash

kubectl logs <pod>
kubectl logs <pod> -c <container>
kubectl logs -f <pod>          # Tail logs
```

---

## 📦 Namespaces

```bash
kubectl get namespaces
kubectl get pods -n <namespace>
kubectl create namespace dev
kubectl delete namespace dev

kubectl config set-context --current --namespace=dev
```

---

## 🌐 Port Forward and Proxy

```bash
kubectl port-forward svc/nginx 8080:80
kubectl port-forward pod/<pod-name> 9090:8080
kubectl proxy
```

---

## 📁 Context & Config Management

```bash
kubectl config get-contexts
kubectl config use-context <name>
kubectl config view
kubectl config current-context
kubectl config set-context --current --namespace=dev
```

---

## ⚙️ Dry Runs, Validation, Explain

```bash
kubectl apply -f deployment.yaml --dry-run=client
kubectl apply -f deployment.yaml --dry-run=server

kubectl explain pod
kubectl explain deployment.spec.template.spec.containers
```

---

## 🔐 Accessing Secure Clusters

```bash
kubectl --token=<jwt> --server=https://<api-server> ...
kubectl --kubeconfig=/path/to/kubeconfig get nodes
```

---

## 📋 Summary Table

| Task | Command |
|------|---------|
| Get cluster info | `kubectl cluster-info` |
| List pods | `kubectl get pods` |
| Create deployment | `kubectl create deployment` |
| Apply config | `kubectl apply -f file.yaml` |
| Exec into pod | `kubectl exec -it <pod> -- /bin/sh` |
| View logs | `kubectl logs <pod>` |
| Port forward | `kubectl port-forward <pod> 8080:80` |
| Change namespace | `kubectl config set-context --current --namespace=dev` |

---

## 🔀 How to Merge Multiple kubeconfig Files

Kubernetes allows you to **merge multiple kubeconfig files** into a single view by using the `KUBECONFIG` environment variable.

### 🗂️ Example Files:
- `$HOME/.kube/config` → default config
- `/tmp/dev-kubeconfig`
- `/tmp/prod-kubeconfig`

### ✅ Merge Them Temporarily

```bash
KUBECONFIG=$HOME/.kube/config:/tmp/dev-kubeconfig:/tmp/prod-kubeconfig kubectl config view --flatten > /tmp/merged-config
```

Then move or set it as your default config:
```bash
mv /tmp/merged-config ~/.kube/config
```

### 🔐 Explanation:

| Step | Description |
|------|-------------|
| `KUBECONFIG=a:b:c` | Specifies multiple config files |
| `kubectl config view` | Shows merged config |
| `--flatten` | Combines contexts/clusters/users cleanly |
| `> newfile` | Outputs to a merged file |

### 🔁 Set It Persistently (Optional)

Add to `.bashrc` or `.zshrc`:
```bash
export KUBECONFIG=$HOME/.kube/config:/tmp/dev-kubeconfig:/tmp/prod-kubeconfig
```

### 🧪 Verify the Merge

```bash
kubectl config get-contexts
kubectl config use-context <context-name>
```

### 🧠 Tip
Always run `--flatten` when merging — it **inlines all references**, so it becomes self-contained and **safe to share or move**.

> ✅ Pro Tip: Keep your main `~/.kube/config` clean by merging only when needed, or use tools like [`kubectx`](https://github.com/ahmetb/kubectx) to manage multiple contexts easily.
