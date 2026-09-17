# 🖼️ Image Security: Trusting What You Actually Run

A Kubernetes cluster runs whatever your image references resolve to. That reference is the single widest supply chain gap in most deployments: a mutable tag, pulled from a registry anyone can push to, containing a base layer with 300 known CVEs, signed by nobody. This document covers digests versus tags, `imagePullPolicy` semantics, private registry authentication in all its forms, vulnerability scanning, SBOMs, Sigstore signing and admission-time verification, minimal base images, and how to build a Dockerfile that is not a liability.

## 📋 Table of Contents
- [The Supply Chain Attack Surface](#the-supply-chain-attack-surface)
- [Tags Are Mutable, Digests Are Not](#tags-are-mutable-digests-are-not)
- [imagePullPolicy](#imagepullpolicy)
- [Private Registry Authentication](#private-registry-authentication)
- [Kubelet Credential Providers](#kubelet-credential-providers)
- [Vulnerability Scanning](#vulnerability-scanning)
- [SBOMs](#sboms)
- [Signing With Cosign](#signing-with-cosign)
- [Verifying Signatures at Admission](#verifying-signatures-at-admission)
- [Registry Allowlisting](#registry-allowlisting)
- [Minimal Base Images](#minimal-base-images)
- [A Hardened Dockerfile](#a-hardened-dockerfile)
- [Pull Rate Limits and Caching](#pull-rate-limits-and-caching)
- [Recipes](#recipes)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## The Supply Chain Attack Surface

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                  FROM SOURCE TO RUNNING CONTAINER                    │
   │                                                                      │
   │   developer laptop ──► git ──► CI ──► registry ──► kubelet ──► pod   │
   │         │              │       │        │            │               │
   │         │              │       │        │            └─ pulls by     │
   │         │              │       │        │               tag: which   │
   │         │              │       │        │               image is     │
   │         │              │       │        │               that, today? │
   │         │              │       │        │                            │
   │         │              │       │        └─ can anyone push here?     │
   │         │              │       │           is the tag protected?     │
   │         │              │       │                                     │
   │         │              │       └─ is the build reproducible?         │
   │         │              │          are build secrets exposed?         │
   │         │              │          is a malicious dependency pulled?  │
   │         │              │                                             │
   │         │              └─ is the commit signed?                      │
   │         │                 is the base image pinned?                  │
   │         │                                                            │
   │         └─ is the developer's environment compromised?               │
   └──────────────────────────────────────────────────────────────────────┘
```

Kubernetes sits at the far right of that chain and trusts everything to its left by default. The controls in this document tighten each link:

| Question | Control |
|---|---|
| Is this exactly the image I tested? | Digest pinning |
| Does it contain known vulnerabilities? | Scanning (Trivy, Grype) |
| What is actually inside it? | SBOM (Syft) |
| Did my build system produce it? | Signing (cosign) and provenance |
| Is it from an approved source? | Registry allowlist at admission |
| How much is even in it? | Minimal base images |

---

## Tags Are Mutable, Digests Are Not

The most important fact in this document.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  A TAG IS A POINTER. It can be moved at any time by anyone with      │
   │  push access.                                                        │
   │                                                                      │
   │     myapp:1.4.2  ──►  sha256:abc123...   (Monday)                    │
   │     myapp:1.4.2  ──►  sha256:def456...   (Tuesday, silently)         │
   │                                                                      │
   │  A DIGEST IS CONTENT-ADDRESSED. It is the SHA-256 of the image       │
   │  manifest. It cannot be moved, only deleted.                         │
   │                                                                      │
   │     myapp@sha256:abc123...  ──►  always the same bytes               │
   └──────────────────────────────────────────────────────────────────────┘
```

Three references, three risk levels:

```yaml
# WORST. Unpinned, unpredictable, and triggers alwaysPull semantics.
image: myapp:latest

# BETTER. Human readable, but the tag can still be moved underneath you.
image: myapp:1.4.2

# BEST. Immutable. This is exactly the artifact you tested.
image: myapp@sha256:9f2a7c1e4b8d3a6f5e0c2b1d7a9e8f4c3b2a1d0e9f8c7b6a5d4e3f2a1b0c9d8e

# PRACTICAL COMPROMISE. Readable and immutable. The tag is documentation;
# the digest is what is actually pulled.
image: myapp:1.4.2@sha256:9f2a7c1e4b8d3a6f5e0c2b1d7a9e8f4c3b2a1d0e9f8c7b6a5d4e3f2a1b0c9d8e
```

That last form is what mature pipelines emit: the tag tells a human what it is, the digest guarantees what it is.

### Why `:latest` Is Specifically Dangerous

```
   1. Nobody knows which build is running.
   2. Two replicas created minutes apart can run DIFFERENT code, because
      the tag moved between pulls.
   3. A rollback is impossible. There is nothing to roll back to.
   4. It forces imagePullPolicy: Always, so every pod start depends on
      the registry being reachable.
   5. An attacker who gains push access silently replaces production
      on the next pod restart, with no manifest change to review.
```

Point 2 is the one that surprises people. Kubernetes does not resolve a tag once per Deployment; each kubelet resolves it at pull time.

### Finding the Digest

```bash
# From a registry, without pulling the whole image
docker buildx imagetools inspect nginx:1.27 | head -5

# With crane (part of go-containerregistry), the cleanest tool for this
crane digest nginx:1.27
# sha256:9f2a7c1e4b8d3a6f5e0c2b1d7a9e8f4c3b2a1d0e9f8c7b6a5d4e3f2a1b0c9d8e

# From an image you already pulled
docker inspect nginx:1.27 --format '{{index .RepoDigests 0}}'

# What is ACTUALLY running in the cluster right now
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.containerStatuses[*].imageID}{"\n"}{end}'
```

That final command is worth running on any cluster you have inherited. `status.containerStatuses[].imageID` is the resolved digest, whereas `spec.containers[].image` is only what was requested. Comparing them tells you whether a tag has drifted.

### Manifest Lists

A single tag usually points at a **manifest list** (a multi-architecture index), not directly at an image.

```bash
crane manifest nginx:1.27 | jq '.mediaType, (.manifests[]? | .platform)'
# "application/vnd.oci.image.index.v1+json"
# { "architecture": "amd64", "os": "linux" }
# { "architecture": "arm64", "os": "linux" }
```

Pinning the index digest is correct and portable: each node resolves the right architecture underneath. Pinning a platform-specific digest breaks on mixed-architecture clusters.

---

## imagePullPolicy

```yaml
containers:
  - name: app
    image: myapp:1.4.2
    imagePullPolicy: IfNotPresent
```

| Policy | Behaviour |
|---|---|
| `Always` | Contact the registry on every pod start. Pulls layers only if the digest differs, but the manifest fetch always happens. |
| `IfNotPresent` | Use the local image if any image with that tag exists on the node. Only pull if absent. |
| `Never` | Never pull. Fail if not present locally. |

### The Defaulting Rule

This catches people constantly:

```
   image: myapp:latest       ──►  imagePullPolicy defaults to Always
   image: myapp              ──►  defaults to Always (implicitly :latest)
   image: myapp:1.4.2        ──►  defaults to IfNotPresent
   image: myapp@sha256:...   ──►  defaults to IfNotPresent
```

So `:latest` silently changes your pull behaviour as well as your reproducibility.

### The IfNotPresent Trap

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Node A has myapp:1.4.2 cached from last week.                       │
   │  You push a NEW image to the same tag.                                │
   │  A pod scheduled to node A with IfNotPresent runs the OLD image.     │
   │  A pod scheduled to node B (no cache) pulls the NEW one.             │
   │                                                                      │
   │  Two replicas of the same Deployment running different code,         │
   │  indefinitely, with nothing in the manifest to explain it.           │
   └──────────────────────────────────────────────────────────────────────┘
```

Digest pinning eliminates this entirely, because the digest *is* the cache key. This is the strongest practical argument for digests over tags.

### AlwaysPullImages

An admission controller that forces `Always` on every container, regardless of what the manifest says.

```yaml
- --enable-admission-plugins=AlwaysPullImages,NodeRestriction
```

Its real purpose is **not** freshness. It closes an authorization hole: without it, any pod on a node can reference a private image already cached there, even if its service account has no pull credentials. Forcing a pull means the registry re-authorizes every time.

The cost is a registry round trip on every pod start, and a hard dependency on registry availability. On a multi-tenant cluster it is worth it. See [admission-controllers.md](admission-controllers.md).

---

## Private Registry Authentication

Four mechanisms, in increasing order of sophistication.

### 1. imagePullSecrets on the Pod

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=deploy-bot \
  --docker-password="$TOKEN" \
  --docker-email=noreply@example.com \
  --namespace=production
```

This creates a Secret of type `kubernetes.io/dockerconfigjson`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: regcred
  namespace: production
type: kubernetes.io/dockerconfigjson
data:
  # base64 of a docker config.json containing base64 of user:password.
  # This is ENCODING, not encryption. Anyone with get on the Secret
  # has the registry credential in plaintext.
  .dockerconfigjson: eyJhdXRocyI6eyJyZWdpc3RyeS5leGFtcGxlLmNvbSI6...
```

```yaml
apiVersion: v1
kind: Pod
spec:
  imagePullSecrets:
    - name: regcred
  containers:
    - name: app
      image: registry.example.com/myapp:1.4.2
```

Decode one to see what it really holds:

```bash
kubectl -n production get secret regcred \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq
```

The Secret is namespaced, so it must be created in every namespace that needs it. That replication is a genuine operational burden and a reason to prefer mechanism 3 or 4.

### 2. imagePullSecrets on the ServiceAccount

Better, because pods no longer need to know about it. The `ServiceAccount` admission controller copies it onto every pod using that account.

```bash
kubectl -n production patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: production
imagePullSecrets:
  - name: regcred
```

Every pod in that namespace using the `default` service account now pulls successfully without a single manifest change. Verify:

```bash
kubectl -n production run test --image=registry.example.com/myapp:1.4.2 --restart=Never
kubectl -n production get pod test -o jsonpath='{.spec.imagePullSecrets}'
# [{"name":"regcred"}]
```

### 3. Node-Level Credentials

The kubelet reads a docker config from disk, so every pod on the node can pull without any Secret.

```bash
sudo mkdir -p /var/lib/kubelet
sudo cp ~/.docker/config.json /var/lib/kubelet/config.json
sudo chmod 600 /var/lib/kubelet/config.json
sudo systemctl restart kubelet
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  Simple, but it removes the authorization boundary entirely.         │
   │  ANY pod on that node can pull ANY image the node's credential       │
   │  can reach, regardless of namespace or service account.              │
   │                                                                      │
   │  On a multi-tenant cluster this is a real problem. Combine with      │
   │  AlwaysPullImages if you use it, and understand what you gave up.    │
   └──────────────────────────────────────────────────────────────────────┘
```

### 4. Cloud IAM

On managed clusters the node's cloud identity usually grants registry access with no Kubernetes configuration at all: an EKS node role with ECR read, a GKE node service account with Artifact Registry read, an AKS cluster identity attached to ACR.

```bash
# EKS: attach the managed policy to the node role
aws iam attach-role-policy \
  --role-name my-eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# AKS: attach a registry to the cluster
az aks update --name my-cluster --resource-group my-rg --attach-acr myregistry
```

This has the same node-scoped authorization property as mechanism 3, with better credential rotation.

---

## Kubelet Credential Providers

The modern, general mechanism: the kubelet executes a plugin binary to obtain credentials on demand, so nothing long-lived sits on disk.

```yaml
# /etc/kubernetes/credential-providers.yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    # Which image references trigger this provider.
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr-fips.*.amazonaws.com"
    # How long the kubelet may cache the returned credential.
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
    args:
      - get-credentials
    env:
      - name: AWS_REGION
        value: eu-west-1
```

Wire it into the kubelet:

```bash
# /var/lib/kubelet/kubeadm-flags.env, or the systemd unit
--image-credential-provider-config=/etc/kubernetes/credential-providers.yaml
--image-credential-provider-bin-dir=/usr/local/bin
```

The plugin binary must exist in the bin directory and be executable by root. The kubelet invokes it, receives a short-lived credential on stdout, caches it for `defaultCacheDuration`, and uses it for matching images.

```bash
sudo ls -l /usr/local/bin/ecr-credential-provider
sudo journalctl -u kubelet | grep -i 'credential.provider'
```

This is how EKS and GKE handle registry auth today, and it is the right pattern for any registry with short-lived tokens.

---

## Vulnerability Scanning

### Trivy

The most widely used scanner, and the easiest to adopt.

```bash
# Scan an image
trivy image nginx:1.27

# Only what matters, and only if it is fixable
trivy image --severity HIGH,CRITICAL --ignore-unfixed nginx:1.27

# Fail a CI build on findings
trivy image --severity CRITICAL --exit-code 1 myapp:1.4.2

# Machine readable
trivy image --format json --output report.json myapp:1.4.2
trivy image --format sarif --output trivy.sarif myapp:1.4.2

# Also scan for misconfiguration and secrets baked into the image
trivy image --scanners vuln,secret,misconfig myapp:1.4.2

# Scan a Kubernetes manifest or Helm chart, not just images
trivy config ./deploy/
```

`--ignore-unfixed` matters more than it sounds. A base image can carry hundreds of CVEs with no available patch; drowning developers in unactionable findings is how scanning gets ignored entirely.

### Scanning What Is Actually Running

The gap between "we scan in CI" and "we know what is running" is usually large.

```bash
# Every unique image in the cluster
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sort -u > cluster-images.txt

wc -l cluster-images.txt

# Scan them all
while read -r img; do
  echo "=== $img"
  trivy image --severity HIGH,CRITICAL --ignore-unfixed \
    --format table "$img" 2>/dev/null | tail -20
done < cluster-images.txt
```

For continuous coverage, `trivy-operator` runs this in-cluster and publishes results as CRDs:

```bash
kubectl get vulnerabilityreports -A
kubectl get configauditreports -A
```

### Grype

An alternative worth knowing, often better at certain language ecosystems.

```bash
grype nginx:1.27
grype myapp:1.4.2 --fail-on critical
grype sbom:./sbom.json          # scan an SBOM rather than an image
```

That last form is useful: generate the SBOM once at build time, then rescan it daily as new CVEs are published, without pulling the image again.

---

## SBOMs

A Software Bill of Materials is a machine-readable inventory of everything in an image. It answers "are we affected?" in minutes rather than days when the next Log4Shell lands.

```bash
# Generate with Syft
syft myapp:1.4.2 -o spdx-json > sbom.spdx.json
syft myapp:1.4.2 -o cyclonedx-json > sbom.cdx.json
syft myapp:1.4.2 -o table          # human readable

# How many components are we actually shipping?
jq '.packages | length' sbom.spdx.json
```

Two standard formats:

| Format | Origin | Notes |
|---|---|---|
| SPDX | Linux Foundation, ISO standard | Strong for licence compliance |
| CycloneDX | OWASP | Strong for vulnerability workflows |

Most tools read both. Pick one and be consistent.

### Attaching the SBOM to the Image

An SBOM in a build artifact store gets lost. Attached to the image in the registry, it travels with it.

```bash
# Attach as an attestation, signed
cosign attest --predicate sbom.spdx.json --type spdxjson myapp:1.4.2

# Retrieve later
cosign download attestation myapp:1.4.2 | jq -r '.payload' | base64 -d | jq
```

### Answering the Emergency Question

```bash
# "Are we running anything with a vulnerable log4j?"
for img in $(kubectl get pods -A \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u); do
  if syft "$img" -o json 2>/dev/null | jq -e '.artifacts[] | select(.name | test("log4j"))' >/dev/null; then
    echo "AFFECTED: $img"
  fi
done
```

Without SBOMs this question takes days. With them it takes minutes.

---

## Signing With Cosign

Signing proves an image came from your build system and has not been altered. Scanning tells you what is inside; signing tells you where it came from.

### Keyless Signing

The modern default. No key to manage, no key to leak.

```bash
# Signs using an OIDC identity (GitHub Actions, Google, GitLab).
# The short-lived certificate and the signature are recorded in
# Rekor, the public transparency log.
COSIGN_EXPERIMENTAL=1 cosign sign myapp@sha256:9f2a7c...
```

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                      KEYLESS SIGNING FLOW                            │
   │                                                                      │
   │   1. cosign obtains an OIDC token proving WHO is signing             │
   │      (for CI: the workflow identity, not a human)                    │
   │                          │                                           │
   │   2. Fulcio issues a SHORT-LIVED certificate (~10 minutes)           │
   │      binding that identity to an ephemeral key                       │
   │                          │                                           │
   │   3. cosign signs the image digest with that key                     │
   │                          │                                           │
   │   4. The signature, certificate and timestamp go into REKOR,         │
   │      an append-only transparency log                                 │
   │                          │                                           │
   │   5. The private key is DISCARDED. There is nothing to steal.        │
   │      Verification checks the Rekor entry against the identity.       │
   └──────────────────────────────────────────────────────────────────────┘
```

Verification pins the **identity**, which is the actual security control:

```bash
cosign verify myapp@sha256:9f2a7c... \
  --certificate-identity-regexp='^https://github\.com/myorg/myrepo/\.github/workflows/.+@refs/heads/main$' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com
```

Read that regexp carefully. It asserts the image was signed by a workflow **in your repository**, on the **main branch**. A signature from a fork or a feature branch fails verification. Verifying without pinning the identity is close to meaningless, since anyone can sign anything.

### Key-Based Signing

Simpler to reason about, but you now own a key.

```bash
cosign generate-key-pair                     # cosign.key, cosign.pub
cosign sign --key cosign.key myapp@sha256:9f2a7c...
cosign verify --key cosign.pub myapp@sha256:9f2a7c...

# Store the key in KMS rather than a file
cosign generate-key-pair --kms awskms:///alias/cosign
cosign sign --key awskms:///alias/cosign myapp@sha256:9f2a7c...
```

### Always Sign the Digest

```bash
# Correct. Immutable target.
cosign sign myapp@sha256:9f2a7c...

# Wrong. cosign resolves the tag now; the tag can move later, and the
# signature then refers to an image nobody is running.
cosign sign myapp:1.4.2
```

---

## Verifying Signatures at Admission

A signature nobody checks is decoration. Enforcement belongs at admission.

### Kyverno

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  background: false          # signature checks need network, not background scans
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-internal-images
      match:
        any:
          - resources:
              kinds: ["Pod"]
      # System namespaces run third-party images we do not sign.
      exclude:
        any:
          - resources:
              namespaces: ["kube-system", "calico-system", "tigera-operator"]
      verifyImages:
        - imageReferences:
            - "registry.internal.example.com/*"
          # Rewrite the tag to the verified digest in the admitted pod.
          # This is a significant feature: it closes the tag-drift gap.
          mutateDigest: true
          # Reject anything not matching imageReferences above.
          required: true
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "https://github.com/myorg/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

`mutateDigest: true` is the quietly important setting. Kyverno resolves the tag, verifies the signature on that digest, and rewrites the pod spec to reference the digest. The pod then cannot be affected by a subsequent tag move.

### Sigstore Policy Controller

A focused alternative that does only this job.

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: internal-images-must-be-signed
spec:
  images:
    - glob: "registry.internal.example.com/**"
  authorities:
    - keyless:
        url: https://fulcio.sigstore.dev
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subjectRegExp: "^https://github\\.com/myorg/.+$"
      ctlog:
        url: https://rekor.sigstore.dev
```

Enforcement is opt-in per namespace by label, which gives a safe rollout:

```bash
kubectl label namespace production policy.sigstore.dev/include=true
```

### Operational Warnings

```
   ⚠ Verification requires NETWORK access from the admission controller
     to the registry and to Rekor. An outage there blocks pod creation.

   ⚠ Set a realistic webhookTimeoutSeconds. Signature verification is
     much slower than a typical admission check.

   ⚠ ALWAYS exclude kube-system and your CNI/CSI namespaces, or a
     verification failure can deadlock the cluster.

   ⚠ Roll out in Audit mode first. See admission-controllers.md.
```

---

## Registry Allowlisting

Before worrying about signatures, most clusters benefit more from simply refusing images from places nobody approved. This needs no extra components.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: allowed-registries
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    # Init and ephemeral containers matter too. Forgetting them is
    # a common and complete bypass.
    - name: allContainers
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
    - name: allowed
      expression: >-
        ['registry.internal.example.com/',
         'registry.k8s.io/',
         'quay.io/jetstack/',
         'docker.io/library/']
    - name: bad
      expression: >-
        variables.allContainers.filter(c,
          !variables.allowed.exists(p, c.image.startsWith(p)))
  validations:
    - expression: "size(variables.bad) == 0"
      messageExpression: >-
        "images must come from an approved registry; rejected: " +
        variables.bad.map(c, c.image).join(", ")
      reason: Invalid
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: allowed-registries-binding
spec:
  policyName: allowed-registries
  # Start with Warn and Audit. Move to Deny once the audit log is clean.
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease", "kube-public",
                   "calico-system", "tigera-operator"]
```

A companion policy forbidding mutable tags:

```yaml
  validations:
    - expression: >-
        variables.allContainers.all(c, c.image.contains("@sha256:"))
      message: "images must be pinned by digest"
      reason: Invalid
```

Start that one in `Warn` mode. Requiring digests everywhere is a significant workflow change and needs pipeline support first.

---

## Minimal Base Images

Every package in the image is attack surface and CVE noise. The cheapest security win available is shipping less.

```
   IMAGE                      SIZE      PACKAGES   TYPICAL CVEs
   ─────                      ────      ────────   ────────────
   ubuntu:24.04               ~78 MB    ~100       dozens
   debian:12-slim             ~75 MB    ~95        dozens
   alpine:3.20                ~8 MB     ~15        few
   gcr.io/distroless/static   ~2 MB     0          ~none
   scratch                    0 B       0          none
```

| Base | Contains | Use when |
|---|---|---|
| `scratch` | Literally nothing | A static binary with no libc, no TLS certs needed, no timezone data |
| `distroless/static` | CA certs, timezone data, `/etc/passwd`, nonroot user | Static Go or Rust binaries. The usual right answer |
| `distroless/base` | The above plus glibc | Dynamically linked binaries |
| `distroless/cc` | The above plus libstdc++ | C++ applications |
| `alpine` | musl, busybox, apk | You need a shell or package manager, and musl is acceptable |
| `debian:slim` | glibc, coreutils, apt | Compatibility matters more than size |

The distroless trade-off worth stating plainly: **there is no shell**, so `kubectl exec -it pod -- sh` does not work. That is a security feature and a debugging inconvenience. The answer is ephemeral containers, not a fatter image:

```bash
kubectl debug -it mypod --image=busybox:1.36 --target=app
```

See [pod-operations.md](pod-operations.md).

---

## A Hardened Dockerfile

Every line here exists for a reason.

```dockerfile
# ── BUILD STAGE ────────────────────────────────────────────────────────
# Pin the builder by digest too. A compromised builder image compromises
# the output just as surely as a compromised base.
FROM golang:1.23-alpine@sha256:4b7e1ba5d4b0e2c6d9e8f7a6c5b4a3d2e1f0c9b8a7d6e5f4c3b2a1d0e9f8c7b6 AS build

WORKDIR /src

# Copy dependency manifests first so this layer caches independently
# of source changes.
COPY go.mod go.sum ./
# Verify module checksums against go.sum. Fails on tampering.
RUN go mod download && go mod verify

COPY . .

# CGO_ENABLED=0 produces a fully static binary, which is what allows
# a scratch or distroless/static base.
# -trimpath removes local filesystem paths from the binary.
# -ldflags "-s -w" strips the symbol table and DWARF data.
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w" \
      -o /out/app ./cmd/app

# ── RUNTIME STAGE ──────────────────────────────────────────────────────
# distroless/static: CA certificates, timezone data, and a nonroot user.
# No shell, no package manager, no coreutils. Nothing for an attacker
# to pivot with.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b

# The nonroot user in distroless is UID 65532.
# Declaring it NUMERICALLY matters: runAsNonRoot cannot validate a name.
USER 65532:65532

# Only the binary crosses from the build stage. The Go toolchain,
# source code and module cache are all left behind.
COPY --from=build --chown=65532:65532 /out/app /app

# Above 1024, so no NET_BIND_SERVICE capability is required at runtime.
EXPOSE 8080

# Exec form, not shell form. There is no shell in this image, and exec
# form makes the process PID 1 so it receives SIGTERM directly.
ENTRYPOINT ["/app"]
```

The matching pod spec, which assumes everything the Dockerfile set up:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  automountServiceAccountToken: false
  containers:
    - name: app
      image: registry.internal.example.com/myapp@sha256:9f2a7c1e4b8d...
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      ports:
        - containerPort: 8080
      resources:
        requests: { cpu: 100m, memory: 64Mi }
        limits:   { cpu: 500m, memory: 256Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 32Mi
```

See [security-context.md](security-context.md) for every field there.

### Never Put Secrets in a Build

```dockerfile
# WRONG. The ARG value is recorded in the image history forever,
# even if a later layer deletes the file.
ARG NPM_TOKEN
RUN echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > .npmrc \
 && npm ci \
 && rm .npmrc

# RIGHT. BuildKit secret mounts are never written to any layer.
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```

```bash
DOCKER_BUILDKIT=1 docker build --secret id=npmrc,src=$HOME/.npmrc -t myapp:1.4.2 .
```

Check any existing image for leaked build secrets:

```bash
docker history --no-trunc myapp:1.4.2
trivy image --scanners secret myapp:1.4.2
```

---

## Pull Rate Limits and Caching

Docker Hub rate limits anonymous pulls by IP. On a cluster where every node shares an egress address, this bites quickly and presents as random `ImagePullBackOff` under load.

```
Error response from daemon: toomanyrequests: You have reached your pull rate limit
```

Three fixes, best first:

**1. Mirror everything into your own registry.** Removes the dependency entirely and gives you an audit point.

```bash
crane copy docker.io/library/nginx:1.27 registry.internal.example.com/mirror/nginx:1.27
```

**2. Configure a pull-through cache in containerd.**

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."https://registry.internal.example.com/v2/dockerhub-proxy"]
  capabilities = ["pull", "resolve"]
```

**3. Authenticate, which raises the limit** even for a free account.

Pre-pulling critical images onto nodes removes registry availability from your pod startup path:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: image-prepuller
  namespace: kube-system
spec:
  selector:
    matchLabels: { app: image-prepuller }
  template:
    metadata:
      labels: { app: image-prepuller }
    spec:
      initContainers:
        # Each init container pulls one image, then exits immediately.
        # The image is now in the node's content store.
        - name: pull-app
          image: registry.internal.example.com/myapp@sha256:9f2a7c...
          command: ["/bin/true"]
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests: { cpu: 1m, memory: 8Mi }
```

---

## Recipes

### Recipe: Full Image Inventory and Risk Report

```bash
#!/usr/bin/env bash
# What are we running, and how bad is it?
printf '%-70s %-8s %-8s %s\n' IMAGE CRIT HIGH PINNED

kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
| sort -u | while read -r img; do
  pinned="no"
  [[ "$img" == *"@sha256:"* ]] && pinned="yes"

  out=$(trivy image --quiet --severity CRITICAL,HIGH --ignore-unfixed \
          --format json "$img" 2>/dev/null) || { echo "$img  SCAN FAILED"; continue; }
  crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' <<<"$out")
  high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")]     | length' <<<"$out")

  printf '%-70s %-8s %-8s %s\n' "${img:0:70}" "$crit" "$high" "$pinned"
done
```

### Recipe: Find Tag Drift in a Running Cluster

Where the requested tag no longer matches what is actually running.

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | . as $p
  | .status.containerStatuses[]?
  | select(.imageID != "")
  | "\($p.metadata.namespace)/\($p.metadata.name)\t\(.image)\t\(.imageID)"' \
| awk -F'\t' '{split($3,a,"@"); print $1"\t"$2"\t"a[2]}' \
| column -t
```

Two pods of the same Deployment showing different digests for the same tag is tag drift, and it is more common than people expect.

### Recipe: A CI Pipeline That Does All of It

```yaml
# .github/workflows/build.yml
name: build
on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write          # required for cosign keyless signing

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: registry.internal.example.com
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: registry.internal.example.com/myapp:${{ github.sha }}
          provenance: true          # SLSA provenance attestation
          sbom: true                # attach an SBOM

      # Scan BEFORE promoting. Fail the build on criticals.
      - name: Scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: registry.internal.example.com/myapp@${{ steps.build.outputs.digest }}
          severity: CRITICAL,HIGH
          ignore-unfixed: true
          exit-code: '1'

      - uses: sigstore/cosign-installer@v3

      # Sign the DIGEST, never the tag.
      - name: Sign
        run: |
          cosign sign --yes \
            registry.internal.example.com/myapp@${{ steps.build.outputs.digest }}

      # Emit the digest for the deployment step to consume.
      - name: Output digest
        run: echo "digest=${{ steps.build.outputs.digest }}" >> "$GITHUB_OUTPUT"
```

The deployment stage then references `myapp@${digest}`, never a tag.

### Recipe: Roll Out Registry Allowlisting Safely

```bash
# 1. Find out what would break, before enforcing anything.
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sed -E 's#^([^/]+/)?([^/]*/)?.*#\1\2#' | sort | uniq -c | sort -rn

# 2. Deploy the policy with validationActions: ["Audit"] only.
# 3. Wait a week, then read the audit log.
sudo jq -r 'select(.annotations["validation.policy.admission.k8s.io/validation_failure"])
  | [.objectRef.namespace, .objectRef.name] | @tsv' \
  /var/log/kubernetes/audit/audit.log | sort -u

# 4. Mirror or exempt the legitimate stragglers.
# 5. Switch to ["Deny", "Audit"].
```

---

## Command Reference

```bash
# ---------- Digests ----------
crane digest nginx:1.27
crane manifest nginx:1.27 | jq
docker buildx imagetools inspect nginx:1.27
docker inspect IMAGE --format '{{index .RepoDigests 0}}'

# ---------- What is running ----------
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
kubectl get pod NAME -o jsonpath='{.status.containerStatuses[*].imageID}'

# ---------- Pull secrets ----------
kubectl create secret docker-registry NAME \
  --docker-server=S --docker-username=U --docker-password=P
kubectl get secret NAME -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regcred"}]}'

# ---------- Scanning ----------
trivy image IMAGE
trivy image --severity HIGH,CRITICAL --ignore-unfixed IMAGE
trivy image --exit-code 1 --severity CRITICAL IMAGE
trivy image --scanners vuln,secret,misconfig IMAGE
trivy config ./manifests/
grype IMAGE
grype sbom:./sbom.json

# ---------- SBOM ----------
syft IMAGE -o spdx-json > sbom.json
syft IMAGE -o table
cosign attest --predicate sbom.json --type spdxjson IMAGE
cosign download attestation IMAGE

# ---------- Signing ----------
cosign generate-key-pair
cosign sign --key cosign.key IMAGE@sha256:...
cosign sign --yes IMAGE@sha256:...                    # keyless
cosign verify --key cosign.pub IMAGE@sha256:...
cosign verify IMAGE@sha256:... \
  --certificate-identity-regexp='...' \
  --certificate-oidc-issuer='...'
cosign tree IMAGE

# ---------- Image forensics ----------
docker history --no-trunc IMAGE
crane config IMAGE | jq '.config.User, .history'
dive IMAGE
```

---

## Troubleshooting

### `ImagePullBackOff`

```bash
kubectl describe pod NAME | tail -20
```

Read the underlying message:

| Message | Cause |
|---|---|
| `manifest unknown` / `not found` | Typo in the image name, or the tag does not exist |
| `unauthorized` / `authentication required` | Missing or wrong pull secret |
| `denied: requested access to the resource is denied` | Credentials valid but lack pull permission |
| `toomanyrequests` | Registry rate limit |
| `x509: certificate signed by unknown authority` | Private registry with a CA the node does not trust |
| `no such host` | DNS failure on the node, not an image problem |

```bash
# Is a pull secret attached at all?
kubectl get pod NAME -o jsonpath='{.spec.imagePullSecrets}'

# Does it contain the right server? A mismatch here is the usual cause.
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d | jq '.auths | keys'

# Test the pull directly on the node, bypassing Kubernetes entirely.
sudo crictl pull registry.example.com/myapp:1.4.2
```

The server key must match the registry host in the image reference exactly. `docker.io` versus `index.docker.io` versus `https://index.docker.io/v1/` trips people up regularly.

### Private Registry With a Self-Signed Certificate

```bash
# Trust the CA on every node
sudo cp registry-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
sudo systemctl restart containerd
```

Or configure it for containerd specifically:

```toml
# /etc/containerd/certs.d/registry.example.com/hosts.toml
server = "https://registry.example.com"

[host."https://registry.example.com"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/registry.example.com/ca.crt"
```

Never use `insecure_skip_verify`. It turns a registry compromise into a cluster compromise.

### Two Replicas Running Different Code

Tag drift plus `IfNotPresent`. Confirm:

```bash
kubectl get pods -l app=myapp -o json | jq -r '
  .items[] | "\(.metadata.name)\t\(.status.containerStatuses[0].imageID)"'
```

Differing digests confirm it. The fix is to pin by digest. A `rollout restart` only papers over it until the next drift.

### Signature Verification Blocking Everything

```bash
kubectl -n kyverno logs -l app.kubernetes.io/name=kyverno --tail=100 | grep -i verif
```

Common causes: the admission controller cannot reach Rekor or the registry, the identity regexp does not match the real signer, or the image was signed by tag while the pod references a digest.

Test verification manually, outside the cluster:

```bash
cosign verify IMAGE@sha256:... \
  --certificate-identity-regexp='...' \
  --certificate-oidc-issuer='...'
```

If it fails there, the policy is not the problem.

Break-glass, if verification has deadlocked the cluster:

```bash
kubectl delete clusterpolicy verify-image-signatures
```

### Scanner Reports Hundreds of Unfixable CVEs

Expected for a full OS base image. Two responses, in order:

1. `--ignore-unfixed` so the report contains only actionable findings.
2. Change the base image. Moving from `ubuntu` to `distroless/static` typically takes a report from hundreds of findings to zero, and is usually less work than triaging them.

### Image Pulls Are Slow

```bash
# Time a pull directly
time sudo crictl pull myapp:1.4.2

# How much is the node storing?
sudo crictl images
sudo du -sh /var/lib/containerd
```

Usual causes: a very large image (fix the base), no local registry (mirror it), or an exhausted node disk triggering image garbage collection and re-pulls.

---

## Exam and Interview Traps

1. **Why is `:latest` a security problem?** It is mutable, so you cannot know or reproduce what is running, cannot roll back, and an attacker with push access replaces production on the next pod restart with no manifest change.

2. **What does `imagePullPolicy` default to?** `Always` for `:latest` or a missing tag; `IfNotPresent` for any other tag or a digest.

3. **How can two replicas of one Deployment run different code?** `IfNotPresent` plus a moved tag. One node has the old image cached; another pulls the new one.

4. **What does `AlwaysPullImages` actually protect against?** Not staleness. It stops a pod using a cached private image that its service account has no credentials to pull.

5. **Where is the best place to attach `imagePullSecrets`?** On the ServiceAccount, so pods inherit it without manifest changes.

6. **What is wrong with node-level registry credentials?** Any pod on the node can pull any image the node can reach, regardless of namespace or service account. It removes the authorization boundary.

7. **Is a `dockerconfigjson` Secret encrypted?** No. Base64 encoded. Anyone with `get` on it has the registry credential.

8. **Should you sign a tag or a digest?** Always the digest. Signing a tag produces a signature that may later refer to an image nobody runs.

9. **Why is verifying a signature without pinning the identity nearly useless?** Anyone can sign anything. The control is asserting *who* signed it, via `--certificate-identity-regexp` and the issuer.

10. **What does `mutateDigest: true` in Kyverno do?** Rewrites the pod's image reference from tag to the verified digest, closing the gap between verification time and pull time.

11. **Which field shows what is genuinely running?** `status.containerStatuses[].imageID`, which is the resolved digest. `spec.containers[].image` is only the request.

12. **Why does `kubectl exec` fail on a distroless image?** There is no shell. Use `kubectl debug` with an ephemeral container instead.

13. **Why does `ARG` for a build secret leak?** The value is recorded in the image history permanently, even if a later layer deletes the file. Use BuildKit `--mount=type=secret`.

14. **What does an SBOM buy you?** The ability to answer "are we affected by this new CVE" in minutes rather than days, and to rescan without pulling images.

15. **A CEL registry policy checks `spec.containers` only. What is the bypass?** Init containers and ephemeral containers. All three lists must be checked.

---

## Related Topics

- [containers.md](containers.md) for image and layer fundamentals
- [docker.md](docker.md) for building images in depth
- [pods.md](pods.md) for `imagePullSecrets` and the container spec
- [secrets.md](secrets.md) for how registry credentials are stored
- [service-accounts.md](service-accounts.md) for attaching pull secrets to an identity
- [admission-controllers.md](admission-controllers.md) for `AlwaysPullImages` and CEL policies
- [security-context.md](security-context.md) for running the image safely once pulled
- [pod-security-standards.md](pod-security-standards.md) for the pod-level controls alongside these
- [runtime-class.md](runtime-class.md) for sandboxing images you cannot fully trust
- [cluster-hardening.md](cluster-hardening.md) for the overall posture
- [pod-operations.md](pod-operations.md) for debugging distroless containers

---

## Key Takeaways

- Tags are mutable pointers; digests are content-addressed and immutable. Pin production workloads by digest.
- `imagePullPolicy` defaults to `Always` for `:latest` and `IfNotPresent` otherwise, which is how one Deployment ends up running two different builds.
- `status.containerStatuses[].imageID` tells you what is really running. `spec.containers[].image` only tells you what was asked for.
- Put `imagePullSecrets` on the ServiceAccount, not on every pod. Node-level credentials are simpler but remove the authorization boundary.
- `AlwaysPullImages` exists to stop credential-free access to cached private images, not to keep images fresh.
- Scan with `--ignore-unfixed` or the findings become noise developers learn to ignore.
- SBOMs turn "are we affected?" from a multi-day investigation into a query.
- Sign the digest, never the tag, and always verify against a pinned signer identity.
- Enforce at admission or none of it matters. Registry allowlisting via `ValidatingAdmissionPolicy` needs no extra components and is the highest value first step.
- Any CEL or policy check must cover `containers`, `initContainers` and `ephemeralContainers`, or it is trivially bypassed.
- Changing base image to distroless usually eliminates more CVEs than any amount of patching, and removes the shell an attacker would pivot with.
- Never pass build secrets via `ARG`. They persist in image history forever.

---

## References

- [Images](https://kubernetes.io/docs/concepts/containers/images/)
- [Pull an Image from a Private Registry](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)
- [Kubelet Credential Provider](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/)
- [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Sigstore Cosign Documentation](https://docs.sigstore.dev/cosign/signing/overview/)
- [Sigstore Policy Controller](https://docs.sigstore.dev/policy-controller/overview/)
- [Trivy Documentation](https://trivy.dev/latest/docs/)
- [Syft](https://github.com/anchore/syft)
- [Distroless Container Images](https://github.com/GoogleContainerTools/distroless)
- [SLSA Supply Chain Levels](https://slsa.dev/spec/v1.0/levels)
