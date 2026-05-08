# Helm Environment Configuration Guide
# helm/aerostore/environments.md
#
# This document is the authoritative reference for deploying the AeroStore
# Helm chart to each environment. It explains what differs, why, and the
# exact commands to use.

---

## Environment Configuration Overview

The same Helm chart (`helm/aerostore/`) is used for **all three environments**.
No templates are changed between environments — only the values files differ.

| Configuration Key | Development | Staging | Production |
|---|---|---|---|
| **Values file** | `values-dev.yaml` | `values-staging.yaml` | `values-prod.yaml` |
| **`image.tag`** | `1.16.1` (stable/known) | `1.17.0` (prod-candidate) | `1.17.0` (pinned) |
| **`replicaCount`** | `1` | `2` | `5` |
| **`autoscaling.enabled`** | `false` | `true` | `true` |
| **`autoscaling.minReplicas`** | N/A | `2` | `3` |
| **`autoscaling.maxReplicas`** | N/A | `5` | `12` |
| **`autoscaling.targetCPU`** | N/A | `60%` | `50%` |
| **`config.appEnv`** | `development` | `staging` | `production` |
| **`config.logLevel`** | `debug` | `info` | `warn` |
| **`resources.requests.cpu`** | `50m` | `100m` | `200m` |
| **`resources.requests.memory`** | `32Mi` | `64Mi` | `128Mi` |
| **`resources.limits.cpu`** | `100m` | `300m` | `500m` |
| **`resources.limits.memory`** | `64Mi` | `192Mi` | `256Mi` |

---

## Why These Differences Exist

### Development
- **1 replica, no HPA:** Dev clusters are small and shared. Running 3+ replicas
  wastes capacity and costs money for work that is never user-facing.
- **debug logging:** Developers need full trace output to diagnose issues quickly.
  Verbose logs in production would flood log storage and hide real signals.
- **Smaller resources:** Dev containers rarely handle real traffic. Requesting
  200m CPU in dev would unnecessarily constrain the dev cluster for everyone.
- **Older image tag:** Dev may use a known-stable image to isolate variables
  when debugging new code — the application code, not the infrastructure.

### Staging
- **2 replicas, HPA on:** Staging must validate that HPA configuration is correct
  before it reaches production. If HPA is only enabled in prod, misconfiguration
  is discovered at the worst possible time.
- **info logging:** Enough detail to validate functional behavior without the
  noise of debug-level output or the silence of warn-only production logs.
- **Prod-candidate image:** Staging always runs the same image that is about to
  go to production — the entire point of staging is to validate that exact artifact.
- **Medium resources:** Staging validates that production resource settings don't
  cause OOMKills or CPU throttling under realistic load.

### Production
- **5 replicas minimum, HPA up to 12:** Production serves real users. A baseline
  of 5 Pods ensures capacity is available immediately when traffic spikes.
- **warn logging only:** In production, logging every request line is expensive
  and hides actionable signals. Only warnings and errors should generate log entries.
- **Larger resource requests/limits:** Production Pods handle real load. Under-
  resourcing causes OOMKills and CPU throttling for users.
- **50% CPU target (vs 60% in staging):** Lower target means more headroom before
  HPA triggers. In production, you want to scale before users feel the slowness.

---

## Deploy Commands

### Development

```bash
# Install
helm install aerostore-dev ./helm/aerostore \
  --values helm/aerostore/values-dev.yaml \
  --namespace dev \
  --create-namespace

# Verify
helm list -n dev
kubectl get pods -n dev -l app.kubernetes.io/instance=aerostore-dev

# Upgrade (e.g., after chart changes)
helm upgrade aerostore-dev ./helm/aerostore \
  --values helm/aerostore/values-dev.yaml \
  --namespace dev
```

### Staging

```bash
helm install aerostore-staging ./helm/aerostore \
  --values helm/aerostore/values-staging.yaml \
  --namespace staging \
  --create-namespace

# Verify HPA is created (staging has autoscaling.enabled=true)
kubectl get hpa -n staging

# Upgrade with new image
helm upgrade aerostore-staging ./helm/aerostore \
  --values helm/aerostore/values-staging.yaml \
  --set image.tag=1.18.0 \
  --namespace staging
```

### Production

```bash
helm install aerostore-prod ./helm/aerostore \
  --values helm/aerostore/values-prod.yaml \
  --namespace production \
  --create-namespace

# Verify all 5 replicas are running before cutting over traffic
kubectl rollout status deployment/aerostore-prod-aerostore -n production

# Upgrade
helm upgrade aerostore-prod ./helm/aerostore \
  --values helm/aerostore/values-prod.yaml \
  --set image.tag=1.18.0 \
  --namespace production

# Rollback if needed
helm rollback aerostore-prod -n production
```

---

## Preview Rendered YAML Per Environment (No Cluster Required)

```bash
# Compare what Helm generates for dev vs prod
helm template aerostore-dev ./helm/aerostore \
  --values helm/aerostore/values-dev.yaml

helm template aerostore-prod ./helm/aerostore \
  --values helm/aerostore/values-prod.yaml

# Validate values against schema before deploying
helm lint ./helm/aerostore --values helm/aerostore/values-prod.yaml
```

---

## The Merge Model — How Helm Combines Values Files

Helm merges values using a deep merge strategy:

```
values.yaml (base)
    +
values-dev.yaml (overrides)
    =
Final values used for rendering
```

Keys in the override file **replace** the same key in the base file.
Keys NOT in the override file **inherit** from the base file.

**Example:**

```yaml
# values.yaml
replicaCount: 3
config:
  appEnv: "production"
  logLevel: "info"
  dbPoolSize: "10"

# values-dev.yaml
replicaCount: 1
config:
  appEnv: "development"
  logLevel: "debug"
  # dbPoolSize is NOT overridden — inherits "10" from values.yaml

# Final result for dev install:
replicaCount: 1
config:
  appEnv: "development"
  logLevel: "debug"
  dbPoolSize: "10"   ← inherited from values.yaml
```

This means override files stay **minimal** — you only write what differs,
not a complete copy of the configuration.

---

## Why Not Duplicate Charts or Manifests?

Consider what would happen if each environment had its own copy of the chart or
its own set of raw YAML files:

```
WITHOUT Helm values separation (the bad approach):
  k8s-dev/
    deployment.yaml     ← hardcoded: replicas: 1, logLevel: debug
    service.yaml
    hpa.yaml
  k8s-staging/
    deployment.yaml     ← hardcoded: replicas: 2, logLevel: info
    service.yaml
    hpa.yaml
  k8s-prod/
    deployment.yaml     ← hardcoded: replicas: 5, logLevel: warn
    service.yaml
    hpa.yaml

Total: 9 files. Add a new resource → edit 3 files. Fix a probe setting → edit 3 files.
Miss one → environments are out of sync. Bugs in prod that don't exist in dev.
```

```
WITH Helm values separation (the correct approach):
  helm/aerostore/
    templates/          ← 5 template files (shared, never duplicated)
    values.yaml         ← defaults
    values-dev.yaml     ← 8 lines (only what's different)
    values-staging.yaml ← 12 lines (only what's different)
    values-prod.yaml    ← 14 lines (only what's different)

Total: 5 templates + 3 small override files.
Add a new resource → add 1 template file. All environments get it automatically.
Fix a probe setting → fix 1 template. All environments fixed simultaneously.
```
