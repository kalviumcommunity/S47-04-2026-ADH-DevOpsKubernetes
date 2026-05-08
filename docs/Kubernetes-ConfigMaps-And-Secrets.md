# Kubernetes ConfigMaps & Secrets — Secure Configuration Management

> This document explains how Kubernetes manages application configuration and sensitive credentials using ConfigMaps and Secrets — and why externalizing configuration is critical for production systems.

---

## Table of Contents

1. [The Problem: Hardcoded Configuration](#1-the-problem-hardcoded-configuration)
2. [ConfigMaps — Externalizing Non-Sensitive Config](#2-configmaps--externalizing-non-sensitive-config)
3. [Secrets — Handling Sensitive Data](#3-secrets--handling-sensitive-data)
4. [How Kubernetes Injects Configuration into Pods](#4-how-kubernetes-injects-configuration-into-pods)
5. [What Goes Where: ConfigMap vs Secret Decision Guide](#5-what-goes-where-configmap-vs-secret-decision-guide)
6. [Configuration Injection Diagram](#6-configuration-injection-diagram)
7. [Verification — Confirming Injection at Runtime](#7-verification--confirming-injection-at-runtime)
8. [Multi-Environment Strategy](#8-multi-environment-strategy)
9. [Why This Approach Improves Security and Maintainability](#9-why-this-approach-improves-security-and-maintainability)

---

## 1. The Problem: Hardcoded Configuration

Consider an application with this code:

```javascript
// ❌ WRONG — never do this
const db = new Database({
  host: "10.244.1.5",          // Pod IP — changes on restart
  user: "admin",               // Hardcoded credential
  password: "supersecret123",  // In plaintext, in source code
  database: "production_db"
});
```

This creates several serious problems:

1. **Security breach risk:** Credentials in source code are visible to everyone with repo access, and are permanently recorded in Git history even after deletion.
2. **Environment inflexibility:** The same code cannot be deployed to dev, staging, and production with different databases without code changes.
3. **Rebuild required for config changes:** Changing a port number or log level requires rebuilding and redeploying the Docker image.
4. **Audit failure:** You cannot prove which credentials were active at which time, because they're baked into the image.

The solution is **configuration externalization** — keeping all environment-specific and sensitive values outside the application code, managed by the platform.

---

## 2. ConfigMaps — Externalizing Non-Sensitive Config

A **ConfigMap** is a Kubernetes object that stores non-sensitive configuration data as key-value pairs. It lives in the cluster (in etcd), separate from the application code and Docker image.

### What We Created: `app-configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aerostore-app-config
data:
  APP_ENV:      "production"
  APP_PORT:     "3001"
  LOG_LEVEL:    "info"
  API_BASE_URL: "http://aerostore-backend-service:3001"
  DB_POOL_SIZE: "10"
  APP_NAME:     "AeroStore Backend"
```

### Key Properties of ConfigMaps

| Property | Detail |
|---|---|
| **Storage** | Stored in etcd as plaintext |
| **Visibility** | Any Pod in the namespace can use it (with correct RBAC) |
| **Updates** | Can be updated without rebuilding the Docker image |
| **Scope** | Namespace-scoped (each namespace has its own copy) |
| **Use for** | Ports, URLs, feature flags, log levels, env names |
| **Never use for** | Passwords, tokens, private keys, certificates |

---

## 3. Secrets — Handling Sensitive Data

A **Secret** is a Kubernetes object designed for sensitive data. While structurally similar to a ConfigMap, Secrets have additional protections:

- Values are **base64-encoded** in the manifest (for safe YAML transport)
- Kubernetes can encrypt Secrets **at rest in etcd** (when encryption is enabled at the cluster level)
- Secrets can be restricted by **RBAC** so only specific Pods/ServiceAccounts can access them
- They are **not exposed in `kubectl describe pod`** output (values are redacted)

### What We Created: `app-secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: aerostore-db-secret
type: Opaque
data:
  DB_HOST:     ZGItaG9zdC1wbGFjZWhvbGRlcg==   # base64("db-host-placeholder")
  DB_USER:     YWVyb3N0b3JlX3VzZXI=            # base64("aerostore_user")
  DB_PASSWORD: Y2hhbmdlbWU=                    # base64("changeme")
  DB_NAME:     YWVyb3N0b3JlX2Ri                # base64("aerostore_db")
  DB_PORT:     NTQzMg==                        # base64("5432")
```

> **Important:** Base64 is **encoding, not encryption**. Anyone who can read the Secret object can decode the values instantly. Real production security requires:
> - Kubernetes RBAC to restrict Secret access
> - Encryption at rest enabled at the etcd/cluster level
> - External secret managers (HashiCorp Vault, AWS Secrets Manager) for the highest security

> **⚠️ The values in `app-secret.yaml` are placeholders only.** Real credentials are never committed to Git. In production, secrets are injected via CI/CD pipeline environment variables or a secrets manager.

---

## 4. How Kubernetes Injects Configuration into Pods

Kubernetes provides two main injection mechanisms:

### Method 1: `envFrom` — Inject All Keys at Once

This injects every key from a ConfigMap or Secret as an environment variable:

```yaml
# From backend-deployment.yaml
envFrom:
  - configMapRef:
      name: aerostore-app-config    # Injects: APP_ENV, APP_PORT, LOG_LEVEL, etc.
  - secretRef:
      name: aerostore-db-secret     # Injects: DB_HOST, DB_USER, DB_PASSWORD, etc.
```

Inside the container, the application accesses these as standard env vars:
```javascript
const port = process.env.APP_PORT;       // "3001" — from ConfigMap
const dbPass = process.env.DB_PASSWORD;  // "changeme" — from Secret
```

### Method 2: `valueFrom` — Inject a Single Specific Key

This injects one specific key from a ConfigMap or Secret:

```yaml
env:
  - name: MY_DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: aerostore-db-secret
        key: DB_PASSWORD

  - name: MY_LOG_LEVEL
    valueFrom:
      configMapKeyRef:
        name: aerostore-app-config
        key: LOG_LEVEL
```

Use this when you only need specific values, or when you want to rename a key inside the container.

### Method 3: Volume Mounts — Inject as Files

Configuration can also be mounted as files inside the container:

```yaml
volumes:
  - name: config-volume
    configMap:
      name: aerostore-app-config

volumeMounts:
  - name: config-volume
    mountPath: /etc/config
```

This is useful for applications that read config from files (e.g., nginx.conf, application.properties).

### The Injection Lifecycle

```
ConfigMap/Secret created in cluster (kubectl apply)
           ↓
Pod is scheduled and started
           ↓
kubelet reads the envFrom / env references in the Pod spec
           ↓
kubelet fetches the ConfigMap and Secret values from the API server
           ↓
Values are injected as environment variables before the container process starts
           ↓
Container reads process.env.* — values are available immediately
```

---

## 5. What Goes Where: ConfigMap vs Secret Decision Guide

| Data Type | ConfigMap | Secret |
|---|---|---|
| Application environment (`dev`, `prod`) | ✅ | ❌ |
| Server port numbers | ✅ | ❌ |
| Log level (`info`, `debug`) | ✅ | ❌ |
| Feature flags | ✅ | ❌ |
| Internal service URLs | ✅ | ❌ |
| Database hostname | ✅ (if not sensitive) | ✅ (if sensitive) |
| Database username | ❌ | ✅ |
| Database password | ❌ | ✅ |
| API tokens / JWT secrets | ❌ | ✅ |
| TLS certificates and private keys | ❌ | ✅ (`type: kubernetes.io/tls`) |
| Docker registry credentials | ❌ | ✅ (`type: kubernetes.io/dockerconfigjson`) |

**Rule of thumb:** If knowing the value could harm your system in the hands of an unauthorized person, it belongs in a Secret.

---

## 6. Configuration Injection Diagram

![ConfigMap and Secret Injection Diagram](k8s-configmap-secret-diagram.png)

```
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│      ConfigMap                   │    │         Secret                   │
│      aerostore-app-config        │    │      aerostore-db-secret         │
│                                  │    │                                  │
│  APP_ENV=production              │    │  DB_HOST=     ••••••••          │
│  APP_PORT=3001                   │    │  DB_USER=     ••••••••          │
│  LOG_LEVEL=info                  │    │  DB_PASSWORD= ••••••••          │
│  API_BASE_URL=http://backend-svc │    │  DB_NAME=     ••••••••          │
│  DB_POOL_SIZE=10                 │    │  DB_PORT=     ••••••••          │
└────────────────┬─────────────────┘    └──────────────┬───────────────────┘
                 │  envFrom configMapRef               │  envFrom secretRef
                 └────────────────┐  ┌─────────────────┘
                                  ▼  ▼
                     ┌─────────────────────────────┐
                     │    aerostore-backend Pod     │
                     │                             │
                     │  process.env.APP_ENV        │
                     │  process.env.APP_PORT       │
                     │  process.env.LOG_LEVEL      │
                     │  process.env.DB_HOST        │
                     │  process.env.DB_USER        │
                     │  process.env.DB_PASSWORD    │
                     │                             │
                     │  ← No hardcoded values      │
                     │  ← Same image, any env      │
                     └─────────────────────────────┘
```

---

## 7. Verification — Confirming Injection at Runtime

### Step 1: Apply All Manifests

```bash
kubectl apply -f k8s/basics/app-configmap.yaml
kubectl apply -f k8s/basics/app-secret.yaml
kubectl apply -f k8s/basics/backend-deployment.yaml
```

### Step 2: Verify Objects Were Created

```bash
# List ConfigMaps
kubectl get configmaps
# NAME                   DATA   AGE
# aerostore-app-config   6      10s

# List Secrets (values are never shown)
kubectl get secrets
# NAME                   TYPE     DATA   AGE
# aerostore-db-secret    Opaque   5      10s

# View ConfigMap contents (plaintext — not sensitive)
kubectl describe configmap aerostore-app-config
```

### Step 3: Confirm Env Vars Inside a Running Pod

```bash
# Get the pod name
kubectl get pods -l app=backend

# Exec into the pod and list environment variables
kubectl exec -it <pod-name> -- env | grep -E "APP_|DB_|LOG_"

# Expected output:
# APP_ENV=production
# APP_PORT=3001
# LOG_LEVEL=info
# API_BASE_URL=http://aerostore-backend-service:3001
# DB_POOL_SIZE=10
# APP_NAME=AeroStore Backend
# DB_HOST=db-host-placeholder
# DB_USER=aerostore_user
# DB_PASSWORD=changeme
# DB_NAME=aerostore_db
# DB_PORT=5432
```

### Step 4: Verify Secrets Are Redacted in Pod Description

```bash
# kubectl describe pod does NOT show secret values
kubectl describe pod <pod-name>
# Environment section will show the source references, not the values:
#   DB_PASSWORD:  <set to the key 'DB_PASSWORD' in secret 'aerostore-db-secret'>
```

---

## 8. Multi-Environment Strategy

The power of ConfigMaps and Secrets is that the **same Docker image** runs across all environments. Only the configuration objects differ:

```
dev namespace:
  ConfigMap:  APP_ENV=development, LOG_LEVEL=debug
  Secret:     DB_PASSWORD=dev-password

staging namespace:
  ConfigMap:  APP_ENV=staging, LOG_LEVEL=info
  Secret:     DB_PASSWORD=staging-password

production namespace:
  ConfigMap:  APP_ENV=production, LOG_LEVEL=warn
  Secret:     DB_PASSWORD=<injected by CI/CD from secrets manager>
```

The Deployment manifest references the same ConfigMap and Secret names in all environments. Because they are namespace-scoped, each namespace has its own copy with environment-appropriate values.

**No code changes. No image rebuilds. No redeployments — just configuration.**

---

## 9. Why This Approach Improves Security and Maintainability

### Security

- **No credentials in Git history:** Even if a developer accidentally commits a file, Secret values are placeholder base64 blobs — not real credentials.
- **RBAC enforcement:** Kubernetes RBAC can restrict which Pods and service accounts can access which Secrets.
- **Audit trail:** Every access to a Secret in Kubernetes can be logged via audit logging.
- **Separation of duties:** Developers write application code without ever seeing production credentials. Ops/platform teams manage Secrets separately.

### Maintainability

- **Config changes don't require rebuilds:** Changing `LOG_LEVEL` from `info` to `debug` is a one-line `kubectl apply` — no Docker build, no new image, no rolling update required.
- **Environment parity:** Every environment runs the same image with the same configuration structure, so "works in staging" reliably means "works in production."
- **Discoverability:** All configuration for an application is documented in version-controlled YAML files, not scattered across developer laptops or buried in application code.
- **Rotation:** Rotating a database password means updating the Secret and rolling the Pods — the application code is unchanged.
