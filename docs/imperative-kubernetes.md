# Imperative Way of Managing Configurations and Deploying Resources in Kubernetes

## What is "Imperative"?
- **Imperative** = telling Kubernetes **exactly what to do, step by step**, using `kubectl` commands.
- Each command makes **direct API calls** to the Kubernetes API server.
- Good for **quick, one-off tasks, experiments, or debugging**.

🔹 Contrast:  
- **Imperative** → "Do this now."  
- **Declarative** → "Here’s what I want, keep it that way."  

---

## Common Imperative Commands

### 1. Create Resources
```bash
# Create a Deployment
kubectl create deployment nginx --image=nginx:1.21 --replicas=3

# Expose Deployment as a Service
kubectl expose deployment nginx --port=80 --target-port=80 --type=NodePort
```

### 2. Scale Resources
```bash
# Scale replicas
kubectl scale deployment/nginx --replicas=5
```

### 3. Update Resources
```bash
# Update container image (triggers rollout)
kubectl set image deployment/nginx nginx=nginx:1.22

# Check rollout status
kubectl rollout status deployment/nginx

# Rollback if needed
kubectl rollout undo deployment/nginx
```

### 4. Patch Resources
```bash
# Strategic merge patch
kubectl patch deployment nginx -p '{"spec":{"replicas":2}}'

# JSON patch
kubectl patch deployment nginx --type='json'   -p='[{"op":"replace","path":"/spec/replicas","value":4}]'
```

### 5. Edit Resources
```bash
# Opens resource in default editor (vim/nano)
kubectl edit deployment nginx
```

### 6. Delete Resources
```bash
kubectl delete deployment nginx
```

---

## Dry Run Mode

Dry run lets you **test your commands without persisting changes** to the cluster.  
There are two main modes:

### Client-Side Dry Run
```bash
kubectl create deployment nginx --image=nginx   --dry-run=client -o yaml
```
- **Validation happens on the client** (kubectl).  
- Only checks basic syntax/structure.  
- Does **not contact the API server**.  
- Commonly used to **generate YAML manifests** without creating resources.  

### Server-Side Dry Run
```bash
kubectl apply -f nginx-deploy.yaml --dry-run=server
```
- **Validation happens on the API server**.  
- Contacts the cluster API, runs admission controllers, and validates against CRDs, RBAC, quotas, etc.  
- Simulates the request **as if it would be persisted**, but discards changes after validation.  
- Safer for checking if an object is truly valid in the cluster context.  

---

## Pros of Imperative
- ✅ Fast and simple for quick tasks  
- ✅ Great for demos and debugging  
- ✅ Useful for scripting small automation  

## Cons of Imperative
- ❌ Hard to reproduce later (poor auditability)  
- ❌ Manual changes can drift from manifests  
- ❌ Not idempotent (`kubectl create` fails if resource exists)  
- ❌ Risk of accidental destructive changes  

---

## Best Practices
- Use `--dry-run=client -o yaml` to **generate YAML** for reproducibility.  
- Use `--dry-run=server` to **validate with the API server** before applying.  
- For production: **store YAML manifests in Git** and apply declaratively.  
- Use `kubectl diff` to preview changes.  
- Record changes with annotations or commit messages.  
- Use imperative mostly for **development, troubleshooting, and one-offs**.  

---

## Quick Cheat-Sheet
| Command | Purpose |
|---------|---------|
| `kubectl create` | Create resource (not idempotent) |
| `kubectl expose` | Create Service for resource |
| `kubectl scale` | Adjust replicas |
| `kubectl set image` | Update container images |
| `kubectl patch` | Partial updates to objects |
| `kubectl edit` | Live editing via editor |
| `kubectl delete` | Remove resources |
| `kubectl get -o yaml` | Export resource definition |
| `--dry-run=client` | Validate/generate manifest locally |
| `--dry-run=server` | Validate on API server (admission controllers, RBAC, quotas, CRDs) |

---
