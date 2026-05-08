# Helm Demo — Commands Reference

This is the exact command sequence for the video demonstration.
Run these after verifying Helm is installed.

---

## Part 1: Verify Helm Installation

```bash
# Check Helm version
helm version
# Output: version.BuildInfo{Version:"v3.x.x", ...}

# Helm 3 does not require a server-side component (Tiller was removed in v3)
# It communicates directly with the Kubernetes API server via your kubeconfig.

# List currently installed releases
helm list
```

---

## Part 2: Inspect the Chart Before Installing

```bash
# Lint the chart — checks for syntax errors and best practices
helm lint ./helm/aerostore

# Show what Kubernetes YAML Helm would generate (dry run — nothing applied)
helm template aerostore ./helm/aerostore

# Show rendered YAML with dev overrides applied
helm template aerostore ./helm/aerostore --values helm/aerostore/values-dev.yaml

# Show rendered YAML with prod overrides applied
helm template aerostore ./helm/aerostore --values helm/aerostore/values-prod.yaml

# Spot the difference:
# dev:  replicaCount=1, no HPA, logLevel=debug
# prod: replicaCount=5, HPA enabled, logLevel=warn
```

---

## Part 3: Install the Chart (Development)

```bash
# Install as "aerostore-dev" release with dev values
helm install aerostore-dev ./helm/aerostore \
  --values helm/aerostore/values-dev.yaml

# Verify the release was created
helm list
# NAME           NAMESPACE  REVISION  STATUS    CHART             APP VERSION
# aerostore-dev  default    1         deployed  aerostore-0.1.0   1.17.0

# Check what Kubernetes resources were created
kubectl get all -l app.kubernetes.io/instance=aerostore-dev

# Verify ConfigMap was rendered with dev values
kubectl describe configmap aerostore-dev-aerostore-config
# LOG_LEVEL: debug (from values-dev.yaml)
```

---

## Part 4: Upgrade the Release

```bash
# Upgrade: bump the image tag to nginx:1.18.0
helm upgrade aerostore-dev ./helm/aerostore \
  --values helm/aerostore/values-dev.yaml \
  --set image.tag=1.18.0

# Helm triggers a rolling update automatically (same mechanism as kubectl apply)
kubectl rollout status deployment/aerostore-dev-aerostore

# Check upgrade history
helm history aerostore-dev
# REVISION  STATUS    CHART             APP VERSION  DESCRIPTION
# 1         superseded aerostore-0.1.0  1.17.0       Install complete
# 2         deployed   aerostore-0.1.0  1.17.0       Upgrade complete
```

---

## Part 5: Helm Rollback

```bash
# Roll back to revision 1 (previous image)
helm rollback aerostore-dev 1

# Verify the rollback
helm history aerostore-dev
# REVISION  STATUS
# 1         superseded
# 2         superseded
# 3         deployed   ← rollback creates a new revision

# Check the image was restored
kubectl describe deployment aerostore-dev-aerostore | grep Image
```

---

## Part 6: Install with Production Values (Side-by-Side)

```bash
# Install a SECOND release of the same chart for production simulation
helm install aerostore-prod ./helm/aerostore \
  --values helm/aerostore/values-prod.yaml

# See both releases coexist
helm list
# aerostore-dev   ... replicaCount=1, no HPA
# aerostore-prod  ... replicaCount=5, HPA enabled

# Compare: prod has HPA, dev does not
kubectl get hpa
```

---

## Part 7: Teardown

```bash
# Remove a release (deletes all its Kubernetes resources)
helm uninstall aerostore-dev
helm uninstall aerostore-prod

# Verify cleanup
kubectl get all -l app.kubernetes.io/instance=aerostore-dev
# No resources found.
```
