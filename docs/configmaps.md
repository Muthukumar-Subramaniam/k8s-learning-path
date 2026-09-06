# ⚙️ ConfigMaps: Configuration Outside the Image

A complete guide to the ConfigMap API object: why configuration belongs outside the container image, every way to create one, every way to consume one, exactly which consumption methods update live, and the failure modes that bite in production.

## 📋 Table of Contents
- [Why ConfigMaps Exist](#why-configmaps-exist)
- [What a ConfigMap Is](#what-a-configmap-is)
- [Anatomy of the Object](#anatomy-of-the-object)
- [Name and Key Rules](#name-and-key-rules)
- [The Size Limit and What To Do About It](#the-size-limit-and-what-to-do-about-it)
- [Creating ConfigMaps: Every Method](#creating-configmaps-every-method)
- [Consuming ConfigMaps: The Four Ways](#consuming-configmaps-the-four-ways)
- [What Updates Live and What Does Not](#what-updates-live-and-what-does-not)
- [Inside the Mounted Directory](#inside-the-mounted-directory)
- [Optional References and Missing ConfigMaps](#optional-references-and-missing-configmaps)
- [Immutable ConfigMaps](#immutable-configmaps)
- [Rolling Pods When Config Changes](#rolling-pods-when-config-changes)
- [Projected Volumes](#projected-volumes)
- [Worked Example: Real Config Files](#worked-example-real-config-files)
- [Namespacing and Scope](#namespacing-and-scope)
- [Command Reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Exam and Interview Traps](#exam-and-interview-traps)
- [Related Topics](#related-topics)
- [Key Takeaways](#key-takeaways)
- [References](#references)

---

## Why ConfigMaps Exist

### The Problem: Configuration Baked Into Images

Without an external configuration mechanism, every environment needs its own image:

```
┌────────────────────────────────────────────────────────────────────┐
│              ANTI-PATTERN: Config Baked Into the Image             │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   myapp:1.4.2-dev        myapp:1.4.2-staging     myapp:1.4.2-prod  │
│   ┌──────────────┐       ┌──────────────┐        ┌──────────────┐  │
│   │ binary       │       │ binary       │        │ binary       │  │
│   │ app.conf     │       │ app.conf     │        │ app.conf     │  │
│   │  db=dev-db   │       │  db=stg-db   │        │  db=prod-db  │  │
│   │  debug=true  │       │  debug=true  │        │  debug=false │  │
│   └──────────────┘       └──────────────┘        └──────────────┘  │
│                                                                     │
│   Three builds. Three artifacts. Three chances to ship the wrong   │
│   one. The bits you tested in staging are NOT the bits in prod.    │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Consequences of that pattern:

1. **The artifact you tested is not the artifact you ship.** A staging image and a production image differ, so the staging test proves less than you think.
2. **A config typo requires a rebuild.** Changing a log level becomes a full CI cycle.
3. **Secrets leak into layers.** Anyone with `docker pull` access can read the image filesystem.
4. **Promotion becomes a rebuild, not a re-tag.** You cannot promote `myapp:1.4.2` from staging to production by moving a tag.

### The Twelve Factor Rationale

Factor III of the twelve factor methodology states that configuration should be stored in the environment, and defines config as **everything that varies between deploys**: database handles, credentials for backing services, hostnames, feature flags, tuning parameters. Code that is identical across deploys is not config.

The litmus test from the methodology: could you open source the repository right now without leaking any credential? If not, config and code are entangled.

```
┌────────────────────────────────────────────────────────────────────┐
│              PATTERN: One Image, Many Configurations               │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│                     ┌──────────────────┐                            │
│                     │   myapp:1.4.2    │   ONE immutable artifact   │
│                     │   (no config)    │                            │
│                     └────────┬─────────┘                            │
│                              │                                      │
│         ┌────────────────────┼────────────────────┐                 │
│         ▼                    ▼                    ▼                 │
│  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐          │
│  │ ns: dev     │      │ ns: staging │      │ ns: prod    │          │
│  │ ConfigMap   │      │ ConfigMap   │      │ ConfigMap   │          │
│  │  + Secret   │      │  + Secret   │      │  + Secret   │          │
│  └─────────────┘      └─────────────┘      └─────────────┘          │
│                                                                     │
│  Promotion = re-tag, not rebuild. Rollback = previous config.       │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Kubernetes splits this into two objects with the same shape but different handling:

| Concern | Object | Backing store on the node | Intended for |
|---------|--------|---------------------------|--------------|
| Non confidential config | **ConfigMap** | Regular filesystem (or env) | URLs, ports, tuning, feature flags, whole config files |
| Confidential config | **Secret** | tmpfs (RAM) for volumes | Passwords, tokens, keys, certificates |

> 📖 **See Also**: [Secrets](secrets.md) for the confidential half of this story, and [Downward API](downward-api.md) for config that comes from the Pod itself.

---

## What a ConfigMap Is

A **ConfigMap** is a namespaced API object that stores non confidential data as key value pairs. Pods consume it as environment variables, as command line arguments, or as files in a volume.

**Key characteristics:**

```
┌──────────────────────────────────────────────────────────────┐
│                    ConfigMap Properties                       │
├──────────────────────────────────────────────────────────────┤
│  • apiVersion: v1, kind: ConfigMap (core group)              │
│  • Namespace scoped                                          │
│  • Stores UTF-8 strings (data) and binary blobs (binaryData) │
│  • No spec and no status: just data, binaryData, immutable   │
│  • Not versioned: updating overwrites, there is no history   │
│  • No schema and no validation of the values                 │
│  • Total size limited to roughly 1 MiB                       │
│  • Referenced only by Pods in the SAME namespace             │
│  • Stored in etcd in plaintext                               │
└──────────────────────────────────────────────────────────────┘
```

Two properties surprise people:

- **There is no rollback.** A ConfigMap has no `revisionHistoryLimit` and no ControllerRevision. If you overwrite it and did not keep the old manifest in Git, the previous value is gone. Treat ConfigMaps as GitOps managed objects, not as things you edit by hand.
- **There is no validation.** If you put a malformed `nginx.conf` in a ConfigMap, the API server accepts it happily. The failure shows up when the container starts and crashes.

---

## Anatomy of the Object

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default
  labels:
    app.kubernetes.io/name: myapp
data:                          # UTF-8 string values
  LOG_LEVEL: "info"            # simple scalar
  MAX_CONNECTIONS: "100"       # NOTE: quoted, YAML would make this an int
  FEATURE_BETA: "true"         # NOTE: quoted, YAML would make this a bool
  application.properties: |    # a whole file as one value
    server.port=8080
    spring.datasource.url=jdbc:postgresql://db:5432/app
    logging.level.root=INFO
binaryData:                    # base64 encoded, for non UTF-8 content
  favicon.ico: AAABAAEAEBAAAAEAIABoBAAAFgAAACgAAAAQAAAAIAAAAAEAIAAA
immutable: false               # optional, see the Immutable section
```

### Field by Field

| Field | Type | Notes |
|-------|------|-------|
| `data` | `map[string]string` | Values **must** be valid UTF-8. This is what you use 95 percent of the time. |
| `binaryData` | `map[string][]byte` | Serialised as base64 in YAML and JSON. For images, certificates in DER form, compiled artefacts, anything not valid UTF-8. |
| `immutable` | `bool` | When `true`, `data` and `binaryData` can never be changed again. |

**Rules the API server enforces:**

1. Keys in `data` and `binaryData` **must not overlap**. A duplicate key is a validation error.
2. Values in `data` must be valid UTF-8. Embedding a NUL byte or invalid byte sequence is rejected; use `binaryData` instead.
3. Once `immutable: true` is set, you may not flip it back to `false`, and you may not change the data.

### The Quoting Trap

This is the single most common ConfigMap bug:

```yaml
# ❌ WRONG: YAML parses these as int, bool and float, not strings
data:
  PORT: 8080
  DEBUG: true
  RATIO: 1.5
  VERSION: 1.10          # also parsed as a float, becomes "1.1"
  COUNTRY: NO            # YAML 1.1 parses this as boolean false
```

```
error: error validating data: ValidationError(ConfigMap.data.PORT):
  invalid type for io.k8s.api.core.v1.ConfigMap.data: got "integer",
  expected "string"
```

```yaml
# ✅ CORRECT: everything quoted
data:
  PORT: "8080"
  DEBUG: "true"
  RATIO: "1.5"
  VERSION: "1.10"
  COUNTRY: "NO"
```

**Rule: every value in a ConfigMap is a string. Quote everything.**

### Multi Line Values: `|` versus `>`

```yaml
data:
  # Literal block: newlines preserved. Use this for config FILES.
  nginx.conf: |
    server {
      listen 80;
    }

  # Literal block, strip trailing newline
  no-trailing-newline: |-
    exactly this, no \n at the end

  # Literal block, keep ALL trailing newlines
  keep-newlines: |+
    line one


  # Folded block: newlines become spaces. Use for long prose only.
  description: >
    This becomes one long
    single line of text.
```

Use `|` for anything a program will parse. Use `>` only for human readable prose. Using `>` for a config file silently joins lines and produces a file that fails to parse at runtime.

---

## Name and Key Rules

### The ConfigMap Name

The `metadata.name` must be a valid **DNS subdomain name**:

```
┌──────────────────────────────────────────────────────────────┐
│              DNS Subdomain Name (RFC 1123)                    │
├──────────────────────────────────────────────────────────────┤
│  • at most 253 characters                                    │
│  • lowercase alphanumeric, '-' or '.'                        │
│  • must start and end with an alphanumeric character         │
│                                                               │
│  ✅ app-config      ✅ nginx.conf.v2     ✅ cfg-2024          │
│  ❌ App-Config      ❌ _config           ❌ config-           │
└──────────────────────────────────────────────────────────────┘
```

### The Keys

Keys inside `data` and `binaryData` follow a different, looser rule. A key may contain **alphanumeric characters, `-`, `_` and `.`**:

```
Valid key regex: [-._a-zA-Z0-9]+

✅ LOG_LEVEL          ✅ nginx.conf        ✅ my-key.v2
✅ application.properties                  ✅ ca.crt
❌ my key             ❌ path/to/file      ❌ key@host
❌ ..                 ❌ .                 ❌ ..data
```

Note that `.` and `..` alone are rejected, and a key may not begin with `..`. This is deliberate: the kubelet uses `..`-prefixed names for its own bookkeeping inside a mounted volume (see [Inside the Mounted Directory](#inside-the-mounted-directory)).

### Keys Versus Environment Variable Names

The key rules are looser than the rules for environment variable names. `nginx.conf` is a perfectly valid ConfigMap key, but it is not a valid environment variable name in most shells.

```
┌───────────────────────────────────────────────────────────────────┐
│                Key Validity: Two Different Contexts                │
├───────────────────────────────────────────────────────────────────┤
│  Key            │ Valid ConfigMap key │ Valid env var name        │
│  ───────────────┼─────────────────────┼───────────────────────    │
│  LOG_LEVEL      │        yes          │        yes                │
│  log-level      │        yes          │   technically settable,   │
│                 │                     │   not readable from sh    │
│  nginx.conf     │        yes          │        no                 │
│  2FAST          │        yes          │        no (leading digit) │
└───────────────────────────────────────────────────────────────────┘
```

Consequence: when you use `envFrom` to import every key as an environment variable, keys that are not valid environment variable names are **silently skipped**. The Pod still starts; the kubelet records an event with reason `InvalidEnvironmentVariableNames` listing what it dropped. This is a classic "my variable is missing and nothing errored" incident.

```bash
kubectl describe pod myapp-0 | grep -A3 InvalidEnvironmentVariableNames
```

---

## The Size Limit and What To Do About It

A ConfigMap is limited to roughly **1 MiB** of data. This is not an arbitrary number: it comes from etcd, which by default refuses individual values larger than 1.5 MiB, and the API server enforces a limit below that so that object metadata and encoding overhead still fit.

```
┌────────────────────────────────────────────────────────────────────┐
│                    Where the 1 MiB Limit Comes From                │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   kubectl apply ──► kube-apiserver ──► etcd                        │
│                          │                │                         │
│                          │                └─ default max request    │
│                          │                   size for a single      │
│                          │                   value is 1.5 MiB       │
│                          │                                          │
│                          └─ rejects ConfigMap/Secret data larger    │
│                             than ~1 MiB so encoding overhead and    │
│                             metadata still fit under etcd's cap     │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

The error looks like this:

```
The ConfigMap "big-config" is invalid: []: Too long: must have at most
1048576 bytes
```

Remember that `binaryData` is stored base64 encoded, so a binary blob consumes about **4/3** of its raw size against the budget. A 800 KiB binary is already over the limit once encoded.

### What To Do Instead

| Situation | Approach |
|-----------|----------|
| Large static assets (images, fonts, JS bundles) | Bake them into the image, or serve from object storage or a CDN |
| Large data files a Pod must read | PersistentVolume, or an init container that downloads at startup |
| Many related config files that together exceed the limit | Split into several ConfigMaps and mount each into a subdirectory, or project several sources into one directory |
| Genuinely large generated config | Generate it in an init container from a small ConfigMap of parameters, write it to an `emptyDir` shared with the main container |
| Machine learning models, datasets | Never a ConfigMap. PVC, object storage, or an image |

### Splitting Across Multiple ConfigMaps

```yaml
volumes:
- name: config
  projected:
    sources:
    - configMap:
        name: app-config-base
    - configMap:
        name: app-config-routes
    - configMap:
        name: app-config-tls
```

All three land in one directory. Keys must not collide across sources; a duplicate path is a validation error at Pod creation time.

### The Hidden Cost of Large ConfigMaps

Even under 1 MiB, large ConfigMaps hurt:

1. **Every kubelet running a consuming Pod holds a watch** on the object and caches its full contents in memory.
2. **Every update pushes the full object** to every watcher; there are no partial updates.
3. **etcd stores every revision** until compaction, so a 900 KiB ConfigMap updated hourly generates real write amplification.

This is exactly the pressure that [Immutable ConfigMaps](#immutable-configmaps) were designed to relieve.

---

## Creating ConfigMaps: Every Method

### 1. From Literals

```bash
kubectl create configmap app-config \
  --from-literal=LOG_LEVEL=info \
  --from-literal=MAX_CONNECTIONS=100 \
  --from-literal=FEATURE_BETA=true
```

Resulting object:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  FEATURE_BETA: "true"
  LOG_LEVEL: info
  MAX_CONNECTIONS: "100"
```

Note that `kubectl` produces correctly quoted strings automatically, which is one good reason to generate the YAML rather than hand write it.

Values with special characters need shell quoting:

```bash
kubectl create configmap app-config \
  --from-literal=GREETING='Hello, World!' \
  --from-literal=JDBC='jdbc:postgresql://db:5432/app?ssl=true'
```

### 2. From a Single File

```bash
cat > nginx.conf <<'EOF'
server {
  listen 80;
  location / { proxy_pass http://backend:8080; }
}
EOF

kubectl create configmap nginx-config --from-file=nginx.conf
```

**The key defaults to the base name of the file:**

```yaml
data:
  nginx.conf: |
    server {
      listen 80;
      location / { proxy_pass http://backend:8080; }
    }
```

If you pass a path, only the base name is used as the key:

```bash
kubectl create configmap nginx-config --from-file=./configs/prod/nginx.conf
# key is still: nginx.conf
```

### 3. From a File With a Custom Key

The `--from-file=KEY=PATH` form decouples the key from the filename:

```bash
kubectl create configmap nginx-config \
  --from-file=default.conf=./configs/prod/nginx-prod.conf
```

```yaml
data:
  default.conf: |
    ...contents of nginx-prod.conf...
```

This matters constantly. Your repository might store `nginx-prod.conf` and `nginx-staging.conf`, but the container expects the file to be named `default.conf`. The custom key form solves it without renaming files on disk.

### 4. From a Directory

```bash
ls configs/
# app.properties  logging.xml  routes.yaml  README.md

kubectl create configmap app-config --from-file=configs/
```

Every **regular file directly inside** the directory becomes one key, named after the file:

```yaml
data:
  README.md: ...
  app.properties: ...
  logging.xml: ...
  routes.yaml: ...
```

Rules for directory mode:

```
┌──────────────────────────────────────────────────────────────┐
│              --from-file=<directory> Behaviour                │
├──────────────────────────────────────────────────────────────┤
│  ✅ regular files directly in the directory  → become keys   │
│  ⛔ subdirectories                           → ignored       │
│  ⛔ files whose names are not valid keys     → skipped       │
│  ⛔ device files, sockets, pipes             → ignored       │
│  ⚠️  hidden files (.foo)                     → included      │
│  ⚠️  no recursion, ever                                      │
└──────────────────────────────────────────────────────────────┘
```

The "no recursion" rule catches people who expect a nested directory tree to be reproduced in the volume. It is not. Keys are flat, and `/` is not a legal key character, so a nested layout cannot be represented in a single ConfigMap at all. Use multiple ConfigMaps mounted at different paths.

You can also repeat `--from-file` to combine sources:

```bash
kubectl create configmap app-config \
  --from-file=configs/base/ \
  --from-file=override.conf=configs/prod/override.conf \
  --from-literal=BUILD_ID=4711
```

### 5. From an Env File

An env file is a plain `KEY=value` file:

```bash
cat > app.env <<'EOF'
# comments and blank lines are ignored

LOG_LEVEL=debug
MAX_CONNECTIONS=250
GREETING=Hello there
EOF

kubectl create configmap app-config --from-env-file=app.env
```

```yaml
data:
  GREETING: Hello there
  LOG_LEVEL: debug
  MAX_CONNECTIONS: "250"
```

**The difference between `--from-file` and `--from-env-file` is the single most confused point in this whole API:**

```
┌────────────────────────────────────────────────────────────────────┐
│         --from-file=app.env      vs      --from-env-file=app.env   │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  --from-file                     │  --from-env-file                │
│  ────────────────────────────────┼──────────────────────────────── │
│  ONE key: "app.env"              │  ONE key PER LINE               │
│  value = the whole file text     │  value = the part after '='     │
│                                  │                                 │
│  data:                           │  data:                          │
│    app.env: |                    │    LOG_LEVEL: debug             │
│      LOG_LEVEL=debug             │    MAX_CONNECTIONS: "250"       │
│      MAX_CONNECTIONS=250         │    GREETING: Hello there        │
│                                  │                                 │
│  Good for: mounting as a file    │  Good for: envFrom              │
└────────────────────────────────────────────────────────────────────┘
```

Env file specifics worth knowing:

- Lines beginning with `#` and blank lines are ignored.
- There is **no shell processing**. Quotes are literal: `NAME="bob"` gives the value `"bob"` with the quote characters included. Variable expansion such as `PATH=$PATH:/opt` is not performed.
- Keys must be valid environment variable names; an invalid key is an error, unlike the silent skip you get with `envFrom` at Pod start.

### 6. Declaratively (The Method You Should Actually Use)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: production
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/component: config
data:
  LOG_LEVEL: "info"
  MAX_CONNECTIONS: "100"
  application.properties: |
    server.port=8080
    server.tomcat.threads.max=200
    spring.datasource.hikari.maximum-pool-size=20
binaryData:
  truststore.jks: |
    /u3+7QAAAAIAAAABAAAAAgAJbG9jYWxob3N0AAABhH5...
```

```bash
kubectl apply -f app-config.yaml
```

Declarative manifests in Git are the only form that gives you review, history, and rollback.

### 7. The Generate and Review Pattern

Get the ergonomics of imperative creation with the auditability of declarative manifests:

```bash
kubectl create configmap app-config \
  --from-file=configs/ \
  --dry-run=client -o yaml > manifests/app-config.yaml

# review, commit, then:
kubectl apply -f manifests/app-config.yaml
```

To regenerate an existing ConfigMap in place without a diff war:

```bash
kubectl create configmap app-config --from-file=configs/ \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 8. Kustomize configMapGenerator

Kustomize solves the "roll Pods when config changes" problem by appending a content hash to the name:

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
configMapGenerator:
- name: app-config
  files:
  - nginx.conf
  literals:
  - LOG_LEVEL=info
```

```bash
kubectl kustomize .
```

The generated object is named `app-config-6ct58987ht`, and every reference to `app-config` in the Deployment is rewritten to that hashed name. Change one byte of `nginx.conf` and the name changes, the Pod template changes, and the Deployment rolls automatically. See [Rolling Pods When Config Changes](#rolling-pods-when-config-changes).

### Creation Methods At a Glance

| Method | Produces | Best for |
|--------|----------|----------|
| `--from-literal=k=v` | one key per flag | a handful of scalars |
| `--from-file=path` | key = base name, value = file | one config file |
| `--from-file=key=path` | key = your choice | file whose name must change |
| `--from-file=dir/` | one key per file in dir | a directory of config files |
| `--from-env-file=f` | one key per line | env style variables for `envFrom` |
| YAML `data` | anything | production, GitOps |
| YAML `binaryData` | base64 blobs | non UTF-8 content |
| `configMapGenerator` | hashed name | automatic rollouts on change |

---

## Consuming ConfigMaps: The Four Ways

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Four Consumption Patterns                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. SINGLE ENV VAR         env[].valueFrom.configMapKeyRef          │
│     pick one key, name the variable yourself                        │
│                                                                      │
│  2. ALL KEYS AS ENV VARS   envFrom[].configMapRef  (+ prefix)       │
│     bulk import, variable names come from the keys                  │
│                                                                      │
│  3. WHOLE VOLUME           volumes[].configMap.name                 │
│     every key becomes a file named after the key                    │
│                                                                      │
│  4. SELECTIVE PROJECTION   volumes[].configMap.items[]              │
│     choose keys, choose paths, choose permission bits               │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Method 1: A Single Environment Variable

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-single
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "echo level=$APP_LOG_LEVEL; sleep 3600"]
    env:
    - name: APP_LOG_LEVEL              # the name INSIDE the container
      valueFrom:
        configMapKeyRef:
          name: app-config             # the ConfigMap object name
          key: LOG_LEVEL               # the key inside it
          optional: false              # default: fail if missing
    - name: DB_POOL_SIZE
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: MAX_CONNECTIONS
```

The strength of this method is **renaming**. The ConfigMap key is `LOG_LEVEL`, but the container wants `APP_LOG_LEVEL`. You control both sides independently, which means you never have to name your ConfigMap keys after whatever legacy variable a third party image demands.

### Method 2: Every Key at Once With `envFrom`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-bulk
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "env | sort; sleep 3600"]
    envFrom:
    - configMapRef:
        name: app-config
    - configMapRef:
        name: feature-flags
        optional: true
      prefix: FLAG_              # applied to every key from THIS source
```

With `app-config` containing `LOG_LEVEL` and `MAX_CONNECTIONS`, and `feature-flags` containing `BETA` and `DARK_MODE`, the container sees:

```
FLAG_BETA=true
FLAG_DARK_MODE=false
LOG_LEVEL=info
MAX_CONNECTIONS=100
```

**Precedence rules, in the order the kubelet applies them:**

```
┌────────────────────────────────────────────────────────────────────┐
│              Environment Variable Precedence                        │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. Image ENV (from the Dockerfile)          lowest precedence      │
│  2. envFrom sources, in list order                                  │
│       later sources overwrite earlier ones on key collision         │
│  3. env[] entries                            highest precedence     │
│       always win over anything from envFrom                         │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

So `env` always beats `envFrom`, which is the natural way to express "import the whole set, then override two of them".

**The silent skip:** keys that are not valid environment variable names are dropped. `nginx.conf` in a ConfigMap consumed with `envFrom` simply will not appear. Check for the event:

```bash
kubectl get events --field-selector reason=InvalidEnvironmentVariableNames
```

**The prefix caveat:** `prefix` is a sibling of `configMapRef` inside a single `envFrom` list entry, and applies only to that entry. It is not a global setting.

### Method 3: Mount the Whole ConfigMap as a Volume

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vol-whole
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "ls -l /etc/config; sleep 3600"]
    volumeMounts:
    - name: config
      mountPath: /etc/config
      readOnly: true             # good hygiene, the mount is read only anyway
  volumes:
  - name: config
    configMap:
      name: app-config
      defaultMode: 0444          # octal, applies to every projected file
```

Every key becomes a file whose name is the key and whose content is the value:

```bash
$ kubectl exec vol-whole -- ls -l /etc/config
total 0
lrwxrwxrwx 1 root root 25 Sep  5 10:12 LOG_LEVEL -> ..data/LOG_LEVEL
lrwxrwxrwx 1 root root 31 Sep  5 10:12 MAX_CONNECTIONS -> ..data/MAX_CONNECTIONS
lrwxrwxrwx 1 root root 32 Sep  5 10:12 application.properties -> ..data/application.properties

$ kubectl exec vol-whole -- cat /etc/config/LOG_LEVEL
info
```

Note two things immediately:

1. **The entries are symlinks**, not regular files. See [Inside the Mounted Directory](#inside-the-mounted-directory).
2. **There is no trailing newline** added. `cat /etc/config/LOG_LEVEL` prints `info` with no newline unless the value itself ended with one. Shell scripts doing `read -r LEVEL < /etc/config/LOG_LEVEL` behave differently depending on that newline, so be explicit in your YAML.

**The mount path shadowing trap:**

```yaml
    volumeMounts:
    - name: config
      mountPath: /etc/nginx        # ⚠️ replaces the ENTIRE directory
```

Mounting at `/etc/nginx` hides everything the image shipped in `/etc/nginx`. The container now sees only your ConfigMap keys. For nginx that means `mime.types`, `conf.d/` and the rest are gone, and the process fails to start. Mount into an empty or dedicated subdirectory, or use `subPath` to place a single file (with the update caveat described below).

### Method 4: Selective Projection With `items`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vol-items
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "find /etc/app -type l -o -type f | sort; sleep 3600"]
    volumeMounts:
    - name: config
      mountPath: /etc/app
  volumes:
  - name: config
    configMap:
      name: app-config
      defaultMode: 0644
      items:
      - key: application.properties
        path: conf/application.properties     # subdirectories ARE allowed here
      - key: LOG_LEVEL
        path: logging/level.txt
        mode: 0400                            # per file override
```

Result:

```
/etc/app/
├── conf/
│   └── application.properties
└── logging/
    └── level.txt        (mode 0400)
```

Critical semantics of `items`:

```
┌────────────────────────────────────────────────────────────────────┐
│                       items[] Semantics                             │
├────────────────────────────────────────────────────────────────────┤
│  • If items is present, ONLY the listed keys are projected.         │
│    Everything else in the ConfigMap is invisible in this volume.    │
│                                                                     │
│  • path may contain '/' to build a subdirectory tree, even though   │
│    a KEY may not contain '/'. This is how you get nested layouts.   │
│                                                                     │
│  • path must be relative and must not contain '..'.                 │
│                                                                     │
│  • mode overrides defaultMode for that one file.                    │
│                                                                     │
│  • If a listed key does not exist and the volume is not optional,   │
│    the container fails to start.                                    │
└────────────────────────────────────────────────────────────────────┘
```

This is the answer to the flat key problem: keys stay flat in the object, and `path` reconstructs whatever directory tree the application expects.

### A Note on `defaultMode` and Permission Bits

```yaml
  volumes:
  - name: config
    configMap:
      name: app-config
      defaultMode: 0644          # ALWAYS write this in octal with a leading 0
```

- The field is an integer. `0644` in YAML is octal 644, which is what you want. Writing `644` (no leading zero) is decimal 644, which is octal 1204, and you get a surprising result.
- Some tools render the value back as decimal `420`, which is exactly `0644`. That is not a bug.
- Permission bits interact with `securityContext.fsGroup` and with `runAsUser`. A file mode of `0400` on a volume is only readable by the file owner, and the owner is determined by the kubelet, not by your container's UID. If a non root container cannot read a `0400` ConfigMap file, relax the mode or set an appropriate `fsGroup`.
- ConfigMap volumes are **always mounted read only**. Setting `readOnly: true` on the `volumeMount` documents intent but does not change behaviour. A container that tries to write to `/etc/config/LOG_LEVEL` gets `Read-only file system`.

### Using ConfigMap Values in `command` and `args`

Environment variables sourced from a ConfigMap are usable with the `$(VAR)` syntax:

```yaml
    env:
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: LOG_LEVEL
    command: ["/app/server"]
    args: ["--log-level=$(LOG_LEVEL)", "--port=8080"]
```

Rules:

- Expansion is performed by the **kubelet**, not by a shell. There is no globbing, no command substitution, no `${VAR:-default}`.
- Only variables defined **earlier in the same `env` list** can be referenced by later entries. Variables coming from `envFrom` are **not** available for `$(VAR)` expansion in `command` or `args`.
- To emit a literal `$(FOO)`, escape it as `$$(FOO)`.

---

## What Updates Live and What Does Not

This is the section to memorise.

```
┌─────────────────────────────────────────────────────────────────────┐
│                  Live Update Behaviour by Method                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  METHOD                              │ UPDATES LIVE?                │
│  ────────────────────────────────────┼───────────────────────────── │
│  env + configMapKeyRef               │ ❌ NEVER                     │
│  envFrom + configMapRef              │ ❌ NEVER                     │
│  volume mount (whole ConfigMap)      │ ✅ eventually                │
│  volume mount with items[]           │ ✅ eventually                │
│  projected volume, configMap source  │ ✅ eventually                │
│  volume mount using subPath          │ ❌ NEVER                     │
│  volume mount using subPathExpr      │ ❌ NEVER                     │
│  ConfigMap marked immutable: true    │ ❌ cannot change at all      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Why Environment Variables Are Frozen

An environment variable is copied into the process's memory at `execve()` time by the container runtime. There is no mechanism in Linux for an external party to change another process's environment block in a way the process would notice. The kubelet reads the ConfigMap once, when it constructs the container, and hands the values to the runtime. After that the ConfigMap and the running process have no relationship at all.

Consequence: **updating a ConfigMap consumed as environment variables has zero effect on running Pods, and there is no event, warning or status field to tell you.** The Pod keeps running with values that no longer match the object. New Pods created after the change get the new values, so you end up with a Deployment whose replicas disagree with each other. That divergence is one of the nastiest configuration bugs to diagnose.

### How Volume Refresh Actually Works

```
┌─────────────────────────────────────────────────────────────────────┐
│              ConfigMap Volume Refresh Pipeline                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. kubectl apply updates the ConfigMap in etcd                     │
│                       ▼                                              │
│  2. kubelet's ConfigMap manager learns about the new version.       │
│     The mechanism is set by configMapAndSecretChangeDetectionStrategy│
│     in the KubeletConfiguration:                                     │
│                                                                      │
│        Watch  (default) : a watch on the object, propagation is      │
│                           quick but not instantaneous                │
│        TTL              : cached value with a time to live           │
│        Get              : every read goes straight to the API server │
│                           (no cache delay, heaviest on apiserver)    │
│                       ▼                                              │
│  3. On its next periodic sync of the Pod, the kubelet notices the   │
│     mounted content is stale and rewrites the volume.               │
│     The sync interval is the kubelet's syncFrequency.                │
│                       ▼                                              │
│  4. New timestamped directory written, ..data symlink swapped        │
│     atomically, old directory removed.                               │
│                                                                      │
│  TOTAL DELAY = kubelet sync period + cache propagation delay         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Two consequences that matter operationally:

1. **The delay is not configurable per Pod.** It is a kubelet level setting. Do not build a system that assumes config lands within N seconds.
2. **The refresh is silent.** Nothing tells the application that the file changed. Either the application watches the file with inotify, or it re-reads on a timer, or it needs a signal, or you restart the Pod.

Applications that genuinely re-read config on change are rare. nginx needs `nginx -s reload`. Most Java and Go services read config once at boot. **If your application does not watch files, a live volume refresh buys you nothing, and you should roll the Pods instead.**

### The subPath Exception

```yaml
    volumeMounts:
    - name: config
      mountPath: /etc/nginx/conf.d/default.conf
      subPath: default.conf         # ⚠️ NEVER refreshed
```

`subPath` is extremely tempting because it places a single file into an existing directory without hiding the rest of it. The cost is that the kubelet bind mounts that one file at container creation time and never touches it again. The `..data` symlink swap happens in the underlying volume directory, but the bind mount inside the container still points at the old inode.

```
┌────────────────────────────────────────────────────────────────────┐
│               Why subPath Cannot Refresh                            │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Normal mount:                                                      │
│    container /etc/config  ──► volume dir  ──► ..data ──► ..2025_09  │
│                                                 ▲                   │
│                              swap this symlink ─┘  container sees   │
│                                                    the new content  │
│                                                                     │
│  subPath mount:                                                     │
│    container /etc/nginx/conf.d/default.conf                         │
│           │                                                         │
│           └─ bind mount to a specific inode inside the old          │
│              timestamped directory. When the kubelet writes a       │
│              NEW directory and swaps ..data, the bind mount is      │
│              still pinned to the OLD inode. Nothing propagates.     │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

**Alternatives to `subPath` when you need live refresh:**

| Option | How |
|--------|-----|
| Mount into a dedicated directory | `mountPath: /etc/nginx/conf.d` with the ConfigMap providing every file in it |
| Use `items` with `path` | Project only the keys you want, into the shape the app expects |
| Init container copy | Init container copies from a ConfigMap volume into an `emptyDir`; loses refresh too, but keeps the directory intact |
| Accept it and roll | Use `subPath` and pair it with a checksum annotation so the Pod restarts on change |

---

## Inside the Mounted Directory

When the kubelet projects a ConfigMap into a volume, it does not write plain files. It builds a structure designed to make updates **atomic from the application's point of view**.

```bash
$ kubectl exec vol-whole -- ls -la /etc/config
total 12
drwxrwxrwt 3 root root  140 Sep  5 10:12 .
drwxr-xr-x 1 root root 4096 Sep  5 10:12 ..
drwxr-xr-x 2 root root  120 Sep  5 10:12 ..2025_09_05_10_12_44.1874265301
lrwxrwxrwx 1 root root   32 Sep  5 10:12 ..data -> ..2025_09_05_10_12_44.1874265301
lrwxrwxrwx 1 root root   16 Sep  5 10:12 LOG_LEVEL -> ..data/LOG_LEVEL
lrwxrwxrwx 1 root root   22 Sep  5 10:12 MAX_CONNECTIONS -> ..data/MAX_CONNECTIONS
```

### The Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│                  Kubelet Projected Volume Layout                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  /etc/config/                                                        │
│  │                                                                   │
│  ├── ..2025_09_05_10_12_44.1874265301/   ← real directory, real     │
│  │   ├── LOG_LEVEL                          files, timestamped name  │
│  │   └── MAX_CONNECTIONS                                             │
│  │                                                                   │
│  ├── ..data ────────────────────────────► points at the current     │
│  │                                          timestamped directory    │
│  │                                                                   │
│  ├── LOG_LEVEL ─────────────────────────► ..data/LOG_LEVEL          │
│  └── MAX_CONNECTIONS ───────────────────► ..data/MAX_CONNECTIONS    │
│                                                                      │
│  Note: the mount point is tmpfs for Secrets. For ConfigMaps the     │
│  backing directory lives under the kubelet's pod directory on the   │
│  node's filesystem.                                                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Names beginning with `..` are hidden from ordinary directory listings (`ls` without `-a` skips dotfiles), which is why the application sees a clean directory with exactly its keys in it. This is also why `..` prefixed keys are forbidden by validation: they would collide with this machinery.

### The Atomic Swap

On update, the kubelet does this:

```
1. Write a brand new timestamped directory containing ALL keys at their
   new values:
       ..2025_09_05_11_47_02.9982135467/

2. Create a temporary symlink pointing at the new directory:
       ..data_tmp -> ..2025_09_05_11_47_02.9982135467

3. rename("..data_tmp", "..data")
       This is a single rename(2) syscall. On Linux, rename over an
       existing path is ATOMIC. There is no instant at which ..data
       does not exist, and no instant at which it points at a
       half written directory.

4. Remove the old timestamped directory.
```

### Why This Matters to Applications

**Guarantee you get:** at any instant, every file in the directory is from the *same* ConfigMap revision. You will never read a new `cert.pem` alongside an old `key.pem`. For multi file configuration this consistency guarantee is the entire point.

**Consequence for file watchers:** the individual files never change. `/etc/config/LOG_LEVEL` is a symlink whose target string is always `..data/LOG_LEVEL`. What changes is the `..data` symlink itself.

```
┌────────────────────────────────────────────────────────────────────┐
│              Why Naive inotify Watches Break                        │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ❌ inotify_add_watch("/etc/config/app.conf", IN_MODIFY)            │
│     inotify follows the symlink and watches the INODE of the file   │
│     inside the old timestamped directory. That inode is never       │
│     modified, it is deleted. You get IN_DELETE_SELF (once) and      │
│     then silence forever.                                           │
│                                                                     │
│  ✅ Watch the DIRECTORY /etc/config for IN_CREATE and IN_MOVED_TO   │
│     The rename of ..data fires IN_MOVED_TO on the directory. On     │
│     that event, re-read every file by path (not by held fd).        │
│                                                                     │
│  ✅ Or just poll: stat("/etc/config/..data") and compare the        │
│     symlink target, or re-read on a timer.                          │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Widely used file watching libraries handle this correctly precisely because Kubernetes made the pattern common. If you write the watch yourself, watch the directory, not the file.

**Consequence for held file descriptors:** a process that opens `/etc/config/app.conf` and keeps the descriptor open will read the old content forever, because the descriptor is bound to the old inode which still exists until it is unlinked and the last reference closes. Re-open by path on every read if freshness matters.

---

## Optional References and Missing ConfigMaps

### The Default: Hard Failure

Reference a ConfigMap that does not exist, and the Pod is scheduled, the sandbox is created, and then container creation fails:

```bash
$ kubectl get pod broken
NAME     READY   STATUS                       RESTARTS   AGE
broken   0/1     CreateContainerConfigError   0          42s
```

```bash
$ kubectl describe pod broken
...
Events:
  Type     Reason     Age                From     Message
  ----     ------     ----               ----     -------
  Normal   Scheduled  60s                default-scheduler  Successfully assigned default/broken to node-2
  Normal   Pulled     15s (x6 over 59s)  kubelet  Container image "busybox:1.36" already present on machine
  Warning  Failed     15s (x6 over 59s)  kubelet  Error: configmap "missing-config" not found
```

Key facts about `CreateContainerConfigError`:

```
┌────────────────────────────────────────────────────────────────────┐
│                 CreateContainerConfigError                          │
├────────────────────────────────────────────────────────────────────┤
│  • The Pod IS scheduled. This is not a scheduling failure, so       │
│    do not go looking at taints or resources.                        │
│  • The kubelet RETRIES with backoff, forever.                       │
│  • The moment you create the missing ConfigMap, the container       │
│    starts on the next retry. No Pod recreation needed.              │
│  • The same status is produced by a missing Secret, a missing KEY   │
│    inside an existing ConfigMap, and a bad subPath.                 │
│  • kubectl logs returns nothing useful: the container never ran.    │
│    Always go to kubectl describe pod for this status.               │
└────────────────────────────────────────────────────────────────────┘
```

A missing **key** inside an existing ConfigMap fails identically:

```
Warning  Failed  3s  kubelet  Error: couldn't find key LOG_LEVEL in ConfigMap default/app-config
```

### Making a Reference Optional

```yaml
spec:
  containers:
  - name: app
    image: busybox:1.36
    env:
    - name: OPTIONAL_TUNING
      valueFrom:
        configMapKeyRef:
          name: tuning-config
          key: GC_TUNING
          optional: true            # missing map OR missing key: skip
    envFrom:
    - configMapRef:
        name: feature-flags
        optional: true              # missing map: import nothing
    volumeMounts:
    - name: extra
      mountPath: /etc/extra
  volumes:
  - name: extra
    configMap:
      name: extra-config
      optional: true                # missing map: mount an EMPTY directory
```

Behaviour of `optional: true`, per consumption method:

| Method | ConfigMap missing | Key missing |
|--------|-------------------|-------------|
| `configMapKeyRef` | variable is not set at all | variable is not set at all |
| `configMapRef` in `envFrom` | nothing imported from that source | not applicable |
| `configMap` volume | volume is mounted **empty**, the directory exists | key simply absent from the directory |

Note carefully: an unset environment variable is not an empty string. In a shell, `$OPTIONAL_TUNING` expands to nothing either way, but in Go `os.LookupEnv` returns `ok=false`, and in Java `System.getenv` returns `null`. Applications that distinguish the two will behave differently, so design defaults on the application side.

**When to use `optional: true`:**

- Genuinely optional overlays: a debug tuning ConfigMap that exists only in dev.
- Bootstrapping order problems where an operator creates the ConfigMap shortly after the Pod.

**When not to use it:** anything the application actually requires. `optional: true` on a required value turns a loud, obvious `CreateContainerConfigError` into a running Pod that silently uses a default. Fail fast is the better default.

---

## Immutable ConfigMaps

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-v3
data:
  LOG_LEVEL: "info"
immutable: true
```

Once applied, the API server rejects any change to `data` or `binaryData`, and rejects flipping `immutable` back to `false`:

```
The ConfigMap "app-config-v3" is invalid: data: Forbidden: field is
immutable when `immutable` is set
```

You may still change `metadata` (labels and annotations), and you may still delete the object.

### The Performance Rationale

This is not primarily a safety feature. It is a scalability feature.

```
┌─────────────────────────────────────────────────────────────────────┐
│              Why Immutability Reduces Load                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  MUTABLE ConfigMap consumed by 5000 Pods across 500 nodes:          │
│                                                                      │
│    kube-apiserver                                                    │
│      ▲ ▲ ▲ ▲ ▲ ... 500 open watches, one per kubelet                │
│      │ │ │ │ │      each kubelet must keep the object cached        │
│      │ │ │ │ │      and re-sync every mounted copy periodically     │
│    kubelet x500                                                      │
│                                                                      │
│  IMMUTABLE ConfigMap:                                                │
│                                                                      │
│    kube-apiserver                                                    │
│                      the kubelet reads the object ONCE, then         │
│                      CLOSES the watch. It can never change, so       │
│                      there is nothing to watch for.                  │
│    kubelet x500                                                      │
│                                                                      │
│  Result: large clusters with many Pods sharing config shed a         │
│  significant amount of apiserver watch traffic and kubelet memory.   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

Secondary benefits:

- **Protection against accidental edits.** Nobody fat fingers production config on an immutable object.
- **Forced explicit rollouts.** Because you must create a new object, you must change the Pod template to point at it, which means the Deployment rolls, which means the change is visible in `kubectl rollout history`.

### The Versioned Name Workflow

Immutability only works if names carry a version:

```yaml
# manifests/config-v3.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-v3
data:
  LOG_LEVEL: "debug"
immutable: true
---
# manifests/deployment.yaml (excerpt)
      containers:
      - name: app
        envFrom:
        - configMapRef:
            name: app-config-v3        # bump this to roll
```

```bash
kubectl apply -f manifests/config-v3.yaml
kubectl apply -f manifests/deployment.yaml
kubectl rollout status deployment/myapp
# once the rollout is complete and verified:
kubectl delete configmap app-config-v2
```

Kustomize's `configMapGenerator` produces exactly this workflow automatically, with a content hash instead of a hand maintained version number. Combine `configMapGenerator` with `options: {immutable: true}` and you get versioned, immutable, automatically rolled config with no manual bookkeeping.

**Cleanup discipline:** immutable ConfigMaps accumulate. Nothing garbage collects them. Label them and prune old generations as part of your deploy pipeline, or set an owner reference so they are cleaned up with their parent.

---

## Rolling Pods When Config Changes

Kubernetes will **not** restart your Pods when a ConfigMap changes. A Deployment only rolls when its **Pod template** changes, and a reference to `app-config` is textually identical before and after the ConfigMap's contents change.

```
┌────────────────────────────────────────────────────────────────────┐
│         Why the Deployment Does Not Notice a ConfigMap Edit         │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Deployment spec.template hash is computed from the TEMPLATE.      │
│                                                                     │
│   Before:  envFrom: [{configMapRef: {name: app-config}}]            │
│   After :  envFrom: [{configMapRef: {name: app-config}}]            │
│            identical text  ──►  identical hash  ──►  no new         │
│                                 ReplicaSet, no rollout              │
│                                                                     │
│   The ConfigMap's contents are not part of the template hash.       │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

Four ways to force the roll, from most to least automatic:

### 1. Kustomize configMapGenerator (Best)

The hashed name changes, so the template changes, so the Deployment rolls. Zero manual steps, and rollback works because the old ConfigMap still exists.

### 2. The Checksum Annotation Pattern

Put a hash of the config into the Pod template's annotations. This is the pattern Helm charts use universally:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
      annotations:
        # Any change to the ConfigMap changes this string, which changes
        # the pod template hash, which triggers a rolling update.
        checksum/config: "8f7d3b1e2a94c05f6b7e8d9a0c1b2e3f4a5d6c7b8e9f0a1b2c3d4e5f6a7b8c9d"
    spec:
      containers:
      - name: app
        image: myapp:1.4.2
        volumeMounts:
        - name: config
          mountPath: /etc/app
      volumes:
      - name: config
        configMap:
          name: app-config
```

In Helm the annotation value is templated:

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Generating the checksum without Helm:

```bash
CHECKSUM=$(kubectl get configmap app-config -o jsonpath='{.data}' | sha256sum | cut -d' ' -f1)

kubectl patch deployment myapp --type=merge -p \
  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$CHECKSUM\"}}}}}"
```

Or, if you keep the ConfigMap manifest in Git, hash the file itself, which is more reproducible:

```bash
CHECKSUM=$(sha256sum manifests/app-config.yaml | cut -d' ' -f1)
```

The annotation must live on `spec.template.metadata.annotations`, **not** on `metadata.annotations` of the Deployment. Putting it on the Deployment itself changes nothing about the Pod template and therefore rolls nothing. This is a very common mistake.

### 3. `kubectl rollout restart`

```bash
kubectl rollout restart deployment/myapp
kubectl rollout status deployment/myapp
```

This adds or updates the annotation `kubectl.kubernetes.io/restartedAt` with the current timestamp on the Pod template, which changes the template hash and triggers a normal rolling update respecting `maxSurge` and `maxUnavailable`. It works on Deployments, StatefulSets and DaemonSets.

Use it for ad hoc operations and incident response. It is not a substitute for the checksum pattern in an automated pipeline, because it is a manual imperative step that leaves no record of *why* the restart happened.

### 4. Reload Sidecars and Controllers

Third party controllers exist that watch ConfigMaps and Secrets and annotate or restart the workloads that reference them. They reduce boilerplate at the cost of another component in the cluster and a less explicit relationship between config and rollout. Evaluate them against the Kustomize approach, which needs no runtime component at all.

### Decision Guide

```
┌─────────────────────────────────────────────────────────────────────┐
│                  Do I Need to Roll the Pods?                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Consumed as env vars?                                               │
│      └─► YES, always. Env vars never update.                         │
│                                                                      │
│  Mounted as a volume, app watches files and reloads?                 │
│      └─► No. Let the kubelet refresh it. (nginx, envoy, fluent-bit,  │
│          prometheus with a reload sidecar, and similar.)             │
│                                                                      │
│  Mounted as a volume, app reads config only at startup?              │
│      └─► YES. The file changes but the app never notices, leaving    │
│          you with a Pod whose behaviour disagrees with its files.    │
│                                                                      │
│  Mounted with subPath?                                               │
│      └─► YES, always. subPath never refreshes.                       │
│                                                                      │
│  ConfigMap is immutable?                                             │
│      └─► YES, by construction: you created a new object and had to   │
│          change the template to reference it.                        │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Projected Volumes

A `projected` volume merges several sources into a single directory. The supported sources are `configMap`, `secret`, `downwardAPI` and `serviceAccountToken`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: projected-demo
spec:
  serviceAccountName: myapp
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "find /etc/podconfig -type l | sort; sleep 3600"]
    volumeMounts:
    - name: everything
      mountPath: /etc/podconfig
      readOnly: true
  volumes:
  - name: everything
    projected:
      defaultMode: 0444
      sources:
      - configMap:
          name: app-config
          items:
          - key: application.properties
            path: app/application.properties
      - configMap:
          name: logging-config
          items:
          - key: logback.xml
            path: app/logback.xml
      - secret:
          name: app-tls
          items:
          - key: tls.crt
            path: tls/tls.crt
          - key: tls.key
            path: tls/tls.key
            mode: 0400
      - downwardAPI:
          items:
          - path: meta/pod_name
            fieldRef:
              fieldPath: metadata.name
          - path: meta/namespace
            fieldRef:
              fieldPath: metadata.namespace
      - serviceAccountToken:
          path: token/api-token
          audience: vault
          expirationSeconds: 3600
```

Resulting layout:

```
/etc/podconfig/
├── app/
│   ├── application.properties
│   └── logback.xml
├── tls/
│   ├── tls.crt
│   └── tls.key          (mode 0400)
├── meta/
│   ├── pod_name
│   └── namespace
└── token/
    └── api-token        (refreshed by the kubelet before expiry)
```

Rules and gotchas:

```
┌────────────────────────────────────────────────────────────────────┐
│                     Projected Volume Rules                          │
├────────────────────────────────────────────────────────────────────┤
│  • defaultMode is set once on the projected volume, not per source. │
│    Individual items[] may still override it with mode.              │
│                                                                     │
│  • Two sources must not produce the same path. A collision is a     │
│    validation error at Pod creation.                                │
│                                                                     │
│  • The whole directory gets ONE ..data symlink and ONE atomic       │
│    swap covering every source together.                             │
│                                                                     │
│  • serviceAccountToken is the modern, bound, auto rotating token.   │
│    See secrets.md.                                                  │
│                                                                     │
│  • The same subPath caveat applies: subPath on a projected volume   │
│    freezes that file.                                               │
└────────────────────────────────────────────────────────────────────┘
```

Use a projected volume when the application expects one config directory that happens to contain a mix of public config, credentials and pod metadata. That is a very common shape for agents and sidecars.

> 📖 **See Also**: [Downward API](downward-api.md) for the `downwardAPI` source, and [Secrets](secrets.md) for `secret` and `serviceAccountToken`.

---

## Worked Example: Real Config Files

### Scenario

An nginx reverse proxy in front of a Spring Boot application. nginx must be reconfigurable without a rebuild, and it must reload on config change. The Java application reads `application.properties` once at startup, so it must roll on change.

### Step 1: The nginx ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: production
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/component: proxy
data:
  default.conf: |
    upstream backend {
        server app-svc.production.svc.cluster.local:8080 max_fails=3 fail_timeout=10s;
        keepalive 32;
    }

    server {
        listen 8080;
        server_name _;

        access_log /dev/stdout main;
        error_log  /dev/stderr warn;

        location /healthz {
            access_log off;
            return 200 "ok\n";
            add_header Content-Type text/plain;
        }

        location / {
            proxy_pass         http://backend;
            proxy_http_version 1.1;
            proxy_set_header   Connection "";
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_connect_timeout 5s;
            proxy_read_timeout    30s;
        }
    }
```

Note that `$host` and `$remote_addr` are nginx variables and survive untouched: nothing in Kubernetes performs shell expansion on the **contents** of a ConfigMap value. Expansion with `$(VAR)` happens only in `command` and `args`.

### Step 2: The Application Properties ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: production
data:
  application.properties: |
    server.port=8080
    server.tomcat.threads.max=200
    server.tomcat.accept-count=100

    spring.datasource.url=jdbc:postgresql://postgres.production.svc:5432/appdb
    spring.datasource.hikari.maximum-pool-size=20
    spring.datasource.hikari.connection-timeout=3000

    management.endpoints.web.exposure.include=health,info,prometheus
    management.endpoint.health.probes.enabled=true

    logging.level.root=INFO
    logging.level.com.example=DEBUG
  # scalar tuning consumed as env vars
  JAVA_OPTS: "-XX:MaxRAMPercentage=75 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError"
  SPRING_PROFILES_ACTIVE: "production"
```

### Step 3: The nginx Deployment (Live Reload)

nginx can reload without dropping connections, so mount the whole directory and let the kubelet refresh it. A small sidecar watches the directory and issues the reload.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        # Mount the DIRECTORY, not a single file with subPath, so the
        # kubelet can refresh it. The image ships nothing else in conf.d.
        - name: nginx-config
          mountPath: /etc/nginx/conf.d
          readOnly: true
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
        readinessProbe:
          httpGet: {path: /healthz, port: http}
          periodSeconds: 5
        livenessProbe:
          httpGet: {path: /healthz, port: http}
          periodSeconds: 10
        resources:
          requests: {cpu: 100m, memory: 64Mi}
          limits:   {memory: 128Mi}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 101
          capabilities:
            drop: ["ALL"]
      volumes:
      - name: nginx-config
        configMap:
          name: nginx-config
          defaultMode: 0444
      - name: cache
        emptyDir: {}
      - name: run
        emptyDir: {}
```

Verifying the refresh end to end:

```bash
# 1. note the current content
kubectl exec deploy/web -c nginx -- cat /etc/nginx/conf.d/default.conf | head -3

# 2. change the ConfigMap
kubectl patch configmap nginx-config --type=merge -p \
  '{"data":{"default.conf":"server {\n  listen 8080;\n  return 204;\n}\n"}}'

# 3. watch the file change inside the running container.
#    This takes up to the kubelet sync period plus cache propagation delay.
kubectl exec deploy/web -c nginx -- sh -c \
  'while :; do echo "--- $(date +%T)"; readlink /etc/nginx/conf.d/..data; sleep 5; done'

# 4. once it changes, validate and reload
kubectl exec deploy/web -c nginx -- nginx -t
kubectl exec deploy/web -c nginx -- nginx -s reload
```

Always run `nginx -t` before `nginx -s reload`. A ConfigMap accepts a syntactically invalid nginx config without complaint, and a reload with a broken file fails, leaving the old config running if you are lucky and a crash loop if you are not.

### Step 4: The Java Deployment (Roll on Change)

The Spring Boot application reads properties at startup, so a live file refresh is useless. Pair the mount with a checksum annotation.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
      annotations:
        checksum/config: "REPLACED_BY_CI_WITH_SHA256_OF_THE_CONFIGMAP"
    spec:
      containers:
      - name: app
        image: myapp:1.4.2
        ports:
        - name: http
          containerPort: 8080
        env:
        # scalars as env vars: these are FROZEN for the container's life,
        # which is fine because the checksum annotation rolls the Pod.
        - name: JAVA_OPTS
          valueFrom:
            configMapKeyRef: {name: app-config, key: JAVA_OPTS}
        - name: SPRING_PROFILES_ACTIVE
          valueFrom:
            configMapKeyRef: {name: app-config, key: SPRING_PROFILES_ACTIVE}
        - name: SPRING_CONFIG_ADDITIONAL_LOCATION
          value: "file:/etc/app/"
        volumeMounts:
        - name: app-config
          mountPath: /etc/app
          readOnly: true
        readinessProbe:
          httpGet: {path: /actuator/health/readiness, port: http}
          initialDelaySeconds: 10
        livenessProbe:
          httpGet: {path: /actuator/health/liveness, port: http}
          initialDelaySeconds: 30
        resources:
          requests: {cpu: 500m, memory: 512Mi}
          limits:   {memory: 1Gi}
      volumes:
      - name: app-config
        configMap:
          name: app-config
          items:
          - key: application.properties
            path: application.properties
          defaultMode: 0444
```

Note the `items` list: the ConfigMap also contains `JAVA_OPTS` and `SPRING_PROFILES_ACTIVE`, and without `items` those would appear as stray files named `JAVA_OPTS` and `SPRING_PROFILES_ACTIVE` inside `/etc/app/`, which Spring's directory scan would try to interpret. Projecting only the key you want keeps the directory clean.

### Step 5: The CI Step That Ties It Together

```bash
#!/usr/bin/env bash
set -euo pipefail

NS=production

kubectl apply -n "$NS" -f manifests/nginx-config.yaml
kubectl apply -n "$NS" -f manifests/app-config.yaml

# hash the manifest in Git, not the live object: reproducible across runs
CHECKSUM=$(sha256sum manifests/app-config.yaml | cut -d' ' -f1)

sed "s/REPLACED_BY_CI_WITH_SHA256_OF_THE_CONFIGMAP/${CHECKSUM}/" \
  manifests/app-deployment.yaml | kubectl apply -n "$NS" -f -

kubectl apply -n "$NS" -f manifests/web-deployment.yaml

kubectl rollout status -n "$NS" deployment/app  --timeout=5m
kubectl rollout status -n "$NS" deployment/web --timeout=5m
```

---

## Namespacing and Scope

```
┌─────────────────────────────────────────────────────────────────────┐
│                    ConfigMaps Are Namespace Scoped                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   namespace: production          namespace: staging                  │
│   ┌──────────────────────┐       ┌──────────────────────┐            │
│   │  ConfigMap           │       │  ConfigMap           │            │
│   │  app-config          │       │  app-config          │            │
│   │  LOG_LEVEL=info      │       │  LOG_LEVEL=debug     │            │
│   └──────────┬───────────┘       └──────────┬───────────┘            │
│              │                              │                        │
│         ┌────▼─────┐                   ┌────▼─────┐                  │
│         │ Pod app  │                   │ Pod app  │                  │
│         └──────────┘                   └──────────┘                  │
│                                                                      │
│   ✗ A Pod in `production` CANNOT reference `staging/app-config`.     │
│     There is no cross namespace reference syntax. None. The Pod      │
│     spec has no `namespace` field on configMapKeyRef or configMap.   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

The same name in two namespaces is the intended mechanism for environment differentiation: identical manifests, different namespace, different content.

### Sharing Config Across Namespaces

There is no built in mechanism. Your options:

| Approach | Notes |
|----------|-------|
| Duplicate via GitOps | Apply the same manifest into each namespace. Simple, explicit, no runtime component. |
| Kustomize overlays | One base, per namespace overlays with patches. |
| A replication controller | Third party controllers copy annotated ConfigMaps into other namespaces. Adds a component and a new failure mode. |
| Copy on demand | `kubectl get cm app-config -n src -o yaml \| sed 's/namespace: src/namespace: dst/' \| kubectl apply -f -` |

The copy on demand command needs care: the exported object carries `resourceVersion`, `uid` and `creationTimestamp`, which `kubectl apply` tolerates but which pollute your Git history if you save the output. Strip them:

```bash
kubectl get configmap app-config -n source -o yaml \
  | kubectl neat 2>/dev/null || kubectl get configmap app-config -n source -o yaml \
  | sed '/resourceVersion:/d;/uid:/d;/creationTimestamp:/d;/selfLink:/d' \
  | sed 's/namespace: source/namespace: target/' \
  | kubectl apply -f -
```

### RBAC Considerations

ConfigMaps are not secret, but they are not harmless either. They frequently contain internal hostnames, database names, S3 bucket names, feature flags and tuning parameters that are useful to an attacker for reconnaissance.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: config-reader
  namespace: production
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: config-writer
  namespace: production
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
  # note: no "delete". Deleting a ConfigMap in use breaks new Pod starts.
```

Restricting to specific objects is possible with `resourceNames`, but be aware that `resourceNames` does not restrict `list` or `watch`, only the verbs that address a single object:

```yaml
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-config"]
  verbs: ["get", "update", "patch"]      # list/watch cannot be narrowed this way
```

Two special cases worth knowing:

- **Leader election.** Some controllers historically used a ConfigMap as a distributed lock, storing the holder identity in the `control-plane.alpha.kubernetes.io/leader` annotation. The `coordination.k8s.io` Lease object is the purpose built replacement. If you see a ConfigMap being updated many times per minute, this is probably why.
- **`kube-root-ca.crt`.** Every namespace automatically contains a ConfigMap named `kube-root-ca.crt` holding the cluster's root CA bundle, published so that workloads can verify the API server. Do not delete it; it is recreated by a controller, but Pods starting in the interim can fail.

```bash
kubectl get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | head -2
```

---

## Command Reference

```bash
# ── CREATE ────────────────────────────────────────────────────────────
kubectl create configmap NAME --from-literal=k1=v1 --from-literal=k2=v2
kubectl create configmap NAME --from-file=path/to/file
kubectl create configmap NAME --from-file=customkey=path/to/file
kubectl create configmap NAME --from-file=path/to/dir/
kubectl create configmap NAME --from-env-file=path/to/file.env
kubectl create configmap NAME --from-file=dir/ --dry-run=client -o yaml

# ── READ ──────────────────────────────────────────────────────────────
kubectl get configmaps
kubectl get configmaps -A
kubectl get configmap app-config -o yaml
kubectl describe configmap app-config

# a single key's value, raw
kubectl get configmap app-config -o jsonpath='{.data.LOG_LEVEL}'

# a key whose name contains dots must be escaped in jsonpath
kubectl get configmap nginx-config -o jsonpath='{.data.default\.conf}'

# just the key names
kubectl get configmap app-config -o jsonpath='{.data}' | jq -r 'keys[]'

# decode a binaryData entry
kubectl get configmap assets -o jsonpath='{.data.favicon\.ico}' | base64 -d > favicon.ico

# size in bytes of every ConfigMap in the namespace, largest first
kubectl get configmap -o json \
  | jq -r '.items[] | "\(.data // {} | tostring | length)\t\(.metadata.name)"' \
  | sort -rn | head

# ── UPDATE ────────────────────────────────────────────────────────────
kubectl apply -f app-config.yaml

# regenerate from files, in place
kubectl create configmap app-config --from-file=configs/ \
  --dry-run=client -o yaml | kubectl apply -f -

# patch a single key
kubectl patch configmap app-config --type=merge -p '{"data":{"LOG_LEVEL":"debug"}}'

# remove a single key (JSON patch; '/' in a key must be escaped as ~1)
kubectl patch configmap app-config --type=json \
  -p='[{"op":"remove","path":"/data/OBSOLETE_KEY"}]'

# interactive edit (use sparingly, it bypasses Git)
kubectl edit configmap app-config

# ── ROLL THE CONSUMERS ────────────────────────────────────────────────
kubectl rollout restart deployment/myapp
kubectl rollout status deployment/myapp

# ── DELETE ────────────────────────────────────────────────────────────
kubectl delete configmap app-config
kubectl delete configmap -l app.kubernetes.io/name=myapp

# ── FIND CONSUMERS ────────────────────────────────────────────────────
# every Pod in the cluster that references a given ConfigMap
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(
      (.spec.volumes // [])[]?.configMap.name == "app-config"
      or ((.spec.containers[].envFrom // [])[]?.configMapRef.name == "app-config")
      or ((.spec.containers[].env // [])[]?.valueFrom.configMapKeyRef.name == "app-config")
    )
  | "\(.metadata.namespace)/\(.metadata.name)"'

# ── VERIFY INSIDE A RUNNING POD ───────────────────────────────────────
kubectl exec POD -- env | sort
kubectl exec POD -- ls -la /etc/config
kubectl exec POD -- readlink /etc/config/..data
kubectl exec POD -- cat /etc/config/application.properties
```

---

## Troubleshooting

### Pod Stuck in `CreateContainerConfigError`

```bash
kubectl get pod POD
kubectl describe pod POD | tail -20
```

| Message | Cause | Fix |
|---------|-------|-----|
| `configmap "X" not found` | Wrong name, or wrong namespace | `kubectl get cm -n <ns>`; ConfigMaps are namespace scoped |
| `couldn't find key K in ConfigMap ns/X` | Key typo, or key removed by a later apply | `kubectl get cm X -o jsonpath='{.data}' \| jq keys` |
| `secret "Y" not found` | A Secret reference, not a ConfigMap one | See [Secrets](secrets.md) |
| `failed to prepare subPath` | `subPath` names a key that does not exist | Check the key name matches exactly |

The kubelet retries forever with backoff, so creating the missing object fixes a running Pod without recreating it.

### Environment Variable Is Missing Inside the Container

```bash
kubectl exec POD -- env | sort | grep MY_VAR
```

Work through this list:

1. **Key is not a valid env var name.** With `envFrom`, keys containing `.` or `-`, or starting with a digit, are silently dropped.
   ```bash
   kubectl get events --field-selector reason=InvalidEnvironmentVariableNames -A
   ```
2. **`optional: true` hid a missing key.** The Pod started, the variable simply is not there.
3. **A later `envFrom` source overwrote it.** Later sources win; check ordering.
4. **You updated the ConfigMap after the Pod started.** Env vars never refresh. Restart the Pod.
5. **You are looking at the wrong container.** `kubectl exec POD -c CONTAINER -- env`.
6. **Init containers have their own env.** Config for an init container must be declared on the init container.

### The Value Inside the Container Is Stale

```bash
# What does the object say?
kubectl get configmap app-config -o jsonpath='{.data.LOG_LEVEL}'; echo

# What does the container see?
kubectl exec POD -- cat /etc/config/LOG_LEVEL; echo
kubectl exec POD -- printenv LOG_LEVEL
```

Diagnosis tree:

```
Stale value
├─ Consumed as env var?           → expected. Restart the Pod.
├─ Mounted with subPath?          → expected. Restart the Pod.
├─ ConfigMap immutable?           → the object literally cannot have changed.
├─ Mounted normally, changed <2m? → wait: kubelet sync + cache propagation.
├─ Mounted normally, changed >5m? → check the ..data symlink target below.
└─ File is fresh but app is not?  → the app cached it at startup. Restart or
                                     send it a reload signal.
```

```bash
# has the kubelet swapped the directory?
kubectl exec POD -- readlink /etc/config/..data
# ..2025_09_05_11_47_02.9982135467   ← timestamp tells you when it last wrote
```

If the timestamp is old, the kubelet has not refreshed. Confirm the Pod is actually using the ConfigMap you think it is:

```bash
kubectl get pod POD -o jsonpath='{.spec.volumes}' | jq
```

### Values Are Wrong Types or Truncated

```bash
kubectl get configmap app-config -o jsonpath='{.data.VERSION}'
# 1.1     ← you wrote 1.10 unquoted, YAML made it a float
```

Round trip test before applying:

```bash
kubectl create configmap test --from-file=my-config.yaml --dry-run=client -o yaml \
  | kubectl get -f - -o jsonpath='{.data}' 2>/dev/null
```

Or simply quote everything, always.

### Application Fails to Parse a Mounted Config File

```bash
# Look for whitespace and line ending damage
kubectl exec POD -- cat -A /etc/config/app.conf | head -20
```

- `^M$` at end of lines: CRLF line endings survived the round trip. Fix at the source file or add `.gitattributes` normalisation.
- Everything on one line: you used `>` instead of `|` in the YAML block scalar.
- Leading spaces on every line: the block scalar indentation was inconsistent; YAML strips the *least* indented line's indentation, so an over indented first line shifts everything.

### The Mount Hid Files the Image Shipped

```bash
kubectl exec POD -- ls /etc/nginx
# only your ConfigMap keys are there; mime.types and friends are gone
```

You mounted over a populated directory. Mount into a dedicated subdirectory, or project only the files you need with `items`, or use `subPath` and accept losing live refresh.

### ConfigMap Too Large

```
The ConfigMap "big" is invalid: []: Too long: must have at most 1048576 bytes
```

```bash
# find your biggest offenders cluster wide
kubectl get configmap -A -o json | jq -r '
  .items[] | "\((.data // {} | tostring | length) + (.binaryData // {} | tostring | length))\t\(.metadata.namespace)/\(.metadata.name)"' \
  | sort -rn | head -10
```

See [The Size Limit and What To Do About It](#the-size-limit-and-what-to-do-about-it).

### Cannot Update: Field Is Immutable

```
The ConfigMap "app-config" is invalid: data: Forbidden: field is immutable
when `immutable` is set
```

Create a new object with a new name and update the Pod template to reference it. You cannot un set `immutable`.

### Non Root Container Cannot Read the Files

```bash
kubectl exec POD -- ls -l /etc/config/..data/
kubectl exec POD -- id
```

A restrictive `defaultMode` such as `0400` grants read access only to the file owner. If the container runs as a UID that does not own the file, reads fail with `Permission denied`. Relax to `0444`, or set `spec.securityContext.fsGroup` so the group ownership matches the container's supplementary group.

---

## Exam and Interview Traps

1. **Updating a ConfigMap does not restart anything.** No rolling update, no event, no warning. The Deployment's template hash is unchanged, so nothing happens.
2. **Environment variables never refresh.** Not eventually, not slowly, never. They are set at `execve()` time. This is the single most asked ConfigMap question.
3. **`subPath` mounts never refresh either.** The bind mount is pinned to an inode inside a directory the kubelet later deletes.
4. **A ConfigMap key may not contain `/`, but an `items[].path` may.** That is how you build nested directory layouts from flat keys.
5. **`--from-file=x.env` and `--from-env-file=x.env` are completely different.** One makes a single key named `x.env`; the other makes one key per line.
6. **`--from-file=<dir>` does not recurse** and skips subdirectories and files whose names are not valid keys.
7. **`envFrom` silently drops keys that are not valid environment variable names.** The Pod starts; only an event records the loss.
8. **`env` beats `envFrom`.** Within `envFrom`, later sources beat earlier ones.
9. **Variables from `envFrom` are not available for `$(VAR)` expansion** in `command` or `args`. Only earlier entries in the same `env` list are.
10. **A missing ConfigMap gives `CreateContainerConfigError`, not `ImagePullBackOff` and not `Pending`.** The Pod was scheduled successfully; the failure is in the kubelet's container creation step, and it retries forever.
11. **Cross namespace references do not exist.** There is no field for it. A Pod can only reference ConfigMaps in its own namespace.
12. **Unquoted YAML scalars are a validation error.** `PORT: 8080` fails; `PORT: "8080"` works. And `VERSION: 1.10` unquoted becomes `1.1`.
13. **The limit is roughly 1 MiB, and it comes from etcd**, not from an arbitrary Kubernetes policy. `binaryData` costs about 4/3 of raw size because of base64.
14. **Immutable is a performance feature first.** It lets the kubelet drop its watch, which is what makes it valuable at scale. Accident prevention is a bonus.
15. **`immutable: true` is one way only.** You cannot set it back to `false`; you must delete and recreate.
16. **ConfigMap volumes are always read only.** `readOnly: true` on the mount is documentation, not enforcement of anything new.
17. **The mounted entries are symlinks into `..data`**, so naive `inotify` watches on the file path stop firing after the first swap. Watch the directory.
18. **The swap is atomic across all keys.** You can never observe a half updated set of files.
19. **`defaultMode: 644` without the leading zero is decimal, not octal.** Always write `0644`.
20. **Mounting a ConfigMap over a populated directory hides everything already there.** This is the classic "nginx will not start after I mounted my config" incident.
21. **`data` and `binaryData` keys must not overlap**, and `data` values must be valid UTF-8.
22. **`optional: true` on a volume mounts an empty directory** when the ConfigMap is missing; it does not skip the mount.
23. **The checksum annotation must be on `spec.template.metadata.annotations`.** On the Deployment's own metadata it changes nothing.
24. **`kubectl rollout restart` works by setting `kubectl.kubernetes.io/restartedAt`** on the Pod template, which is just the template hash trick again.
25. **Every namespace has a `kube-root-ca.crt` ConfigMap** published automatically so workloads can verify the API server.
26. **ConfigMaps are stored in etcd in plaintext and are not encrypted by encryption at rest configuration unless you explicitly list `configmaps` as a resource.** They are not a place for credentials regardless. Use [Secrets](secrets.md).

---

## Related Topics

- [Secrets](secrets.md)
- [Downward API](downward-api.md)
- [Pods](pods.md)
- [Deployments](deployments.md)
- [Deployment Strategies](deployment-strategies.md)
- [StatefulSets](statefulsets.md)
- [DaemonSets](daemonsets.md)
- [ReplicaSets](replicasets.md)
- [Jobs](jobs.md)
- [CronJobs](cronjobs.md)
- [Controllers](controllers.md)
- [kubelet](kubelet.md)
- [kube-apiserver](kube-apiserver.md)
- [etcd](etcd.md)
- [Kubernetes API](k8s-api.md)
- [kubectl](kubectl.md)
- [Imperative Kubernetes](imperative-kubernetes.md)
- [CoreDNS](coredns.md)

---

## Key Takeaways

1. A ConfigMap decouples configuration from the image so that **one artifact runs in every environment**, which is the whole point of twelve factor config and the only way promotion can be a re-tag rather than a rebuild.
2. Every ConfigMap value is a **string**. Quote everything in YAML, and use `|` (not `>`) for config files.
3. There are six ways to create one: `--from-literal`, `--from-file` (file, custom key, directory), `--from-env-file`, and declarative `data` plus `binaryData`. The generate and review pattern (`--dry-run=client -o yaml`) gives you kubectl's ergonomics with Git's auditability.
4. **`--from-file` and `--from-env-file` on the same file produce completely different objects.** One key with the whole file, versus one key per line.
5. Keys allow `[-._a-zA-Z0-9]+`, which is looser than the rules for environment variable names, so `envFrom` **silently skips** keys such as `nginx.conf` and only records an event.
6. There are four consumption methods: single env var with `configMapKeyRef`, bulk env with `envFrom` plus optional `prefix`, whole volume mount, and selective projection with `items`, `path` and `mode`.
7. **Environment variables are frozen at container start and never refresh.** Volume mounts are eventually refreshed by the kubelet, on a delay of its sync period plus cache propagation delay. `subPath` mounts never refresh.
8. The kubelet builds a `..data` symlink pointing at a timestamped directory and swaps it with a single atomic `rename(2)`. All keys update together, and naive `inotify` watches on individual file paths stop firing after the first swap; watch the directory instead.
9. A missing ConfigMap or key produces **`CreateContainerConfigError`**, not a scheduling failure. The kubelet retries forever, so creating the object repairs the Pod in place.
10. `optional: true` converts hard failures into silent absence: unset variables, or an empty mounted directory. Use it only for genuinely optional overlays.
11. **`immutable: true` exists mainly for scale**: the kubelet can close its watch on an object that can never change. It also forces you into a versioned name workflow that makes rollouts explicit.
12. Kubernetes never restarts Pods on a config change. Force it with a **content hash in the name** (Kustomize `configMapGenerator`), a **`checksum/config` annotation on the Pod template**, or `kubectl rollout restart` for ad hoc work.
13. The roughly **1 MiB limit comes from etcd**. For anything larger, use a PersistentVolume, object storage, or bake it into the image. `binaryData` costs about 4/3 of raw size after base64.
14. Even under the limit, large and frequently updated ConfigMaps cost apiserver watch traffic, kubelet memory on every consuming node, and etcd write amplification.
15. **ConfigMaps are namespace scoped with no cross namespace reference syntax.** Same name, different namespace is the intended environment differentiation mechanism.
16. Mounting over a populated directory **hides everything the image shipped there**. Mount into a dedicated directory or project individual files with `items`.
17. ConfigMaps are stored in etcd in plaintext and are readable by anyone with `get` on the namespace. Anything confidential belongs in a [Secret](secrets.md), with encryption at rest enabled.

---

## References

- [ConfigMaps concept](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [Configure a Pod to Use a ConfigMap](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/)
- [Define Environment Variables for a Container](https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/)
- [Define Dependent Environment Variables](https://kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables/)
- [Define a Command and Arguments for a Container](https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/)
- [Projected Volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
- [Volumes: configMap](https://kubernetes.io/docs/concepts/storage/volumes/#configmap)
- [Volumes: Using subPath](https://kubernetes.io/docs/concepts/storage/volumes/#using-subpath)
- [Object Names and IDs](https://kubernetes.io/docs/concepts/overview/working-with-objects/names/)
- [ConfigMap API reference (v1)](https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/config-map-v1/)
- [kubectl create configmap](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-configmap-em-)
- [Declarative Management of Kubernetes Objects Using Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
- [Kubelet Configuration (v1beta1) reference](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/)
- [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [The Twelve-Factor App: Config](https://12factor.net/config)
