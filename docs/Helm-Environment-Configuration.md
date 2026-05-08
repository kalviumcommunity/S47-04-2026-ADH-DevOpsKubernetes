# Helm Environment-Specific Configuration Management

> This document explains how the AeroStore Helm chart manages three distinct environments — development, staging, and production — using separate values files without duplicating a single template, and why this approach is fundamentally safer and more scalable than maintaining parallel YAML files.

---

## Table of Contents

1. [The Core Problem: Environment Configuration Drift](#1-the-core-problem-environment-configuration-drift)
2. [How Helm Values Files Solve This](#2-how-helm-values-files-solve-this)
3. [The Three AeroStore Environments](#3-the-three-aerostore-environments)
4. [The Helm Merge Model in Detail](#4-the-helm-merge-model-in-detail)
5. [What Gets Externalized and Why](#5-what-gets-externalized-and-why)
6. [Applying the Correct Configuration Per Environment](#6-applying-the-correct-configuration-per-environment)
7. [Scenario: Dev vs Production Resource Configuration](#7-scenario-dev-vs-production-resource-configuration)
8. [Why Chart Duplication Is Dangerous](#8-why-chart-duplication-is-dangerous)

---

## 1. The Core Problem: Environment Configuration Drift

Every application needs to run in multiple environments. The configurations differ in predictable ways:

| What changes | Dev | Staging | Production |
|---|---|---|---|
| Scale | Low | Medium | High |
| Resources | Small | Medium | Large |
| Logging | Verbose | Moderate | Minimal |
| Features | All enabled | Near-production | Carefully controlled |
| Image tag | Flexible | RC candidate | Pinned release |

Without a structured approach, teams handle this by:
- **Duplicating YAML files** per environment (3x maintenance cost, drift accumulates)
- **Editing files before each deployment** (manual, error-prone, no audit trail)
- **Using sed/awk scripts** to patch values into templates (fragile, unreadable)
- **Hardcoding environment names** in manifests with complex conditional logic

All of these approaches degrade over time. A fix applied to `k8s-dev/deployment.yaml` must be manually replicated to `k8s-staging/deployment.yaml` and `k8s-prod/deployment.yaml`. Developers forget. Environments drift. A bug in production doesn't exist in dev — because dev has a different version of the template.

---

## 2. How Helm Values Files Solve This

Helm's solution is structural: **separate the configuration from the templates**.

- **Templates** (`templates/*.yaml`) define the shape of resources — they never change between environments
- **Values** (`values*.yaml`) define the configuration — they're the only thing that varies

```
ONE chart + ONE values file per env = zero duplication, zero drift
```

Helm merges the environment values on top of the base `values.yaml` at install time, rendering final Kubernetes YAML that is specific to that environment. No manual file editing, no find-and-replace, no environment-specific template copies.

---

## 3. The Three AeroStore Environments

### Development — `values-dev.yaml`

```yaml
image:
  tag: "1.16.1"       # Known-stable image for isolated dev work
replicaCount: 1       # Single replica — no HA needed, saves dev cluster cost
autoscaling:
  enabled: false      # Fixed replicas in dev — no metrics server needed
config:
  appEnv: "development"
  logLevel: "debug"   # Full trace output for developers
resources:
  requests:
    cpu: "50m"        # Minimal — dev containers barely serve traffic
    memory: "32Mi"
  limits:
    cpu: "100m"
    memory: "64Mi"
```

**Rationale:** Development environments are shared and small. Every resource request blocks capacity for other developers. A single replica is sufficient for local testing. Debug logging helps developers but would flood production log pipelines.

### Staging — `values-staging.yaml`

```yaml
image:
  tag: "1.17.0"       # Same image as production-candidate
replicaCount: 2       # Tests HA behavior without full prod cost
autoscaling:
  enabled: true       # Validates HPA config before it reaches prod
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 60
config:
  appEnv: "staging"
  logLevel: "info"    # Enough detail to validate behavior
resources:
  requests:
    cpu: "100m"
    memory: "64Mi"
  limits:
    cpu: "300m"
    memory: "192Mi"
```

**Rationale:** Staging is a production mirror in miniature. It runs the same image, the same HPA configuration, and similar resource settings so that any misconfiguration is discovered here, not in production. If HPA is only enabled in prod, you'll only find out the CPU targets are wrong when real users are affected.

### Production — `values-prod.yaml`

```yaml
image:
  tag: "1.17.0"       # Pinned to exact verified version
replicaCount: 5       # High baseline for immediate capacity
autoscaling:
  enabled: true
  minReplicas: 3      # Never below 3 — always HA in production
  maxReplicas: 12     # Wide range for traffic spikes
  targetCPUUtilizationPercentage: 50   # More headroom than staging
config:
  appEnv: "production"
  logLevel: "warn"    # Only warnings and errors
resources:
  requests:
    cpu: "200m"       # Reflects actual production load
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "256Mi"
```

**Rationale:** Production must always have capacity ready before traffic arrives. A minimum of 3 replicas ensures redundancy. A 50% CPU target (vs 60% in staging) means scale-up begins earlier, protecting users from slowness during spikes. Warn-only logging reduces cost and noise.

---

## 4. The Helm Merge Model in Detail

When you run `helm install --values values-dev.yaml`, Helm performs a **deep merge**:

```
values.yaml (base layer)
    +
values-dev.yaml (environment layer)
    =
merged values → template rendering → Kubernetes YAML
```

**Rules:**
- Keys in the environment file **override** the same key in `values.yaml`
- Keys **absent** from the environment file **inherit** from `values.yaml`
- Nested keys are merged at each level individually (deep merge, not shallow)

**Example — nested merge:**

```yaml
# values.yaml
config:
  appEnv: "production"
  logLevel: "info"
  dbPoolSize: "10"       ← NOT in dev override
  appPort: "80"          ← NOT in dev override

# values-dev.yaml
config:
  appEnv: "development"  ← overrides values.yaml
  logLevel: "debug"      ← overrides values.yaml
  # dbPoolSize and appPort not listed → inherited from values.yaml

# Result for dev:
config:
  appEnv: "development"  ← from values-dev.yaml
  logLevel: "debug"      ← from values-dev.yaml
  dbPoolSize: "10"        ← inherited from values.yaml
  appPort: "80"           ← inherited from values.yaml
```

This means environment override files stay **minimal** — only the differences are listed. `values-dev.yaml` is 8 lines. `values-prod.yaml` is 14 lines. The full default configuration (55 lines) is defined once in `values.yaml`.

---

## 5. What Gets Externalized and Why

Not every field should be in values. The rule is: **externalize anything that legitimately differs between environments or deployments.**

| Field | Externalized? | Why |
|---|---|---|
| `image.tag` | ✅ Yes | Different per environment and per release |
| `replicaCount` | ✅ Yes | Dev=1, staging=2, prod=5 |
| `autoscaling.enabled` | ✅ Yes | Disabled in dev, enabled in staging/prod |
| `resources.requests/limits` | ✅ Yes | Sized to actual environment capacity |
| `config.logLevel` | ✅ Yes | debug/info/warn per environment |
| `config.appEnv` | ✅ Yes | Application reads this to change behavior |
| `service.type` | ✅ Yes | ClusterIP in most cases, could differ |
| `containerPort` | ❌ No | Hardcoded in the template — never changes |
| Labels/selectors | ❌ No | Must be stable — hardcoded in helpers |
| Probe paths | ❌ No | Same endpoint in all environments |

---

## 6. Applying the Correct Configuration Per Environment

### Install

```bash
# Development
helm install aerostore-dev ./helm/aerostore \
  --values helm/aerostore/values-dev.yaml \
  --namespace dev --create-namespace

# Staging
helm install aerostore-staging ./helm/aerostore \
  --values helm/aerostore/values-staging.yaml \
  --namespace staging --create-namespace

# Production
helm install aerostore-prod ./helm/aerostore \
  --values helm/aerostore/values-prod.yaml \
  --namespace production --create-namespace
```

### Preview Before Installing (Dry Run)

```bash
# See what Helm would apply to prod — no cluster interaction
helm template aerostore-prod ./helm/aerostore \
  --values helm/aerostore/values-prod.yaml

# Validate that prod values pass schema validation
helm lint ./helm/aerostore --values helm/aerostore/values-prod.yaml
```

### Verify Configuration Was Applied Correctly

```bash
# Confirm replica count
kubectl get deployment -n production | grep aerostore
# aerostore-prod-aerostore   5/5   5   5

# Confirm environment-specific ConfigMap values
kubectl get configmap -n production aerostore-prod-aerostore-config -o yaml
# data:
#   APP_ENV: production
#   LOG_LEVEL: warn

# Confirm HPA exists in staging and prod, not in dev
kubectl get hpa -A
# NAMESPACE    NAME
# staging      aerostore-staging-aerostore-hpa
# production   aerostore-prod-aerostore-hpa
# (dev has no HPA)
```

---

## 7. Scenario: Dev vs Production Resource Configuration

**Scenario:** Dev requires low replicas and relaxed resource limits. Production requires higher replicas and stricter resource settings.

### Without Helm Values Files

A developer would maintain three separate copies of `deployment.yaml`:

```
k8s/dev/deployment.yaml    → replicas: 1, cpu: 50m/100m
k8s/staging/deployment.yaml → replicas: 2, cpu: 100m/300m
k8s/prod/deployment.yaml   → replicas: 5, cpu: 200m/500m
```

Adding a new label to the Pod requires editing all three files. Adding a new probe configuration requires editing all three. When the team grows and developers work on different files, subtle differences accumulate. The dev deployment silently diverges from production. A bug that only manifests in production is impossible to reproduce in dev because the configurations are different in ways no one remembers.

### With Helm Values Files

```
helm/aerostore/templates/deployment.yaml   ← ONE template, never duplicated
helm/aerostore/values-dev.yaml             ← replicas: 1, cpu: 50m/100m (8 lines)
helm/aerostore/values-staging.yaml         ← replicas: 2, cpu: 100m/300m (12 lines)
helm/aerostore/values-prod.yaml            ← replicas: 5, cpu: 200m/500m (14 lines)
```

Adding a new label: edit `_helpers.tpl` once. All environments get the change. Adding a new probe configuration: edit `deployment.yaml` once. All environments get the change. The only thing that differs between environments is what's explicitly stated in the values files.

### How Helm Ensures Correct Configuration Per Environment

1. **Explicit values file selection:** `--values values-prod.yaml` is a required argument — you can't accidentally apply dev config to prod without explicitly passing the wrong file.
2. **Schema validation:** `values.schema.json` rejects invalid values before any templates are rendered — `replicaCount: 0` or `logLevel: "verbose"` both fail validation.
3. **Release namespacing:** Dev runs in the `dev` namespace, prod in `production` — Kubernetes RBAC can restrict who can deploy to each namespace.
4. **Helm history:** `helm history aerostore-prod` shows every revision — what was installed, when, and by which chart version.

---

## 8. Why Chart Duplication Is Dangerous

Duplicating charts or manifests per environment creates **N × M complexity** where N is the number of resources and M is the number of environments.

With 8 resource files and 3 environments:
- **24 files** to maintain
- Any change requires **3 coordinated edits**
- Reviews must diff all 3 versions to confirm no unintended differences
- A missed update means one environment is on a different version of a resource

The Helm values approach keeps complexity at **N + M**:
- **5 templates** (shared) + **3 values files** (environment-specific) = **8 files total**
- Any change requires **1 template edit**
- All environments receive the change simultaneously on next `helm upgrade`
- Differences between environments are fully explicit in the values files — nothing is hidden
