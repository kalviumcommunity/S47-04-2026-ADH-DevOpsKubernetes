# k8s/rbac/rbac-demo.md
# RBAC Demo — Commands Reference
#
# This is the exact command sequence for verifying RBAC access control.
# The goal is to demonstrate that the developer SA can read resources
# but cannot modify or delete them, and cannot access other namespaces.

---

## Setup

```bash
# Apply all RBAC resources
kubectl apply -f k8s/rbac/dev-team-namespace.yaml
kubectl apply -f k8s/rbac/serviceaccounts.yaml
kubectl apply -f k8s/rbac/dev-viewer-role.yaml
kubectl apply -f k8s/rbac/cicd-deployer-role.yaml
kubectl apply -f k8s/rbac/role-bindings.yaml

# Verify
kubectl get roles -n dev-team
kubectl get rolebindings -n dev-team
kubectl get serviceaccounts -n dev-team
```

---

## Part 1: Test Developer SA — Allowed Actions (Read-Only)

```bash
# ✅ List Pods — ALLOWED (dev-viewer has pods/list)
kubectl auth can-i list pods \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: yes

# ✅ Get Services — ALLOWED
kubectl auth can-i get services \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: yes

# ✅ List Deployments — ALLOWED
kubectl auth can-i list deployments \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: yes

# ✅ Watch Events — ALLOWED
kubectl auth can-i watch events \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: yes

# ✅ Get ConfigMaps — ALLOWED
kubectl auth can-i get configmaps \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: yes
```

---

## Part 2: Test Developer SA — Denied Actions

```bash
# ❌ Delete a Pod — DENIED (delete not in dev-viewer rules)
kubectl auth can-i delete pods \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: no

# ❌ Create a Deployment — DENIED
kubectl auth can-i create deployments \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: no

# ❌ Read Secrets — DENIED (Secrets not in dev-viewer rules)
kubectl auth can-i get secrets \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: no

# ❌ Exec into a Pod — DENIED (pods/exec not in rules)
kubectl auth can-i create pods/exec \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: no

# ❌ Access OTHER NAMESPACE (production) — DENIED (Role is namespace-scoped)
kubectl auth can-i list pods \
  --namespace production \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# Output: no
# The dev-viewer Role only exists in dev-team. No RoleBinding in production → 403.
```

---

## Part 3: Test CI/CD SA — Allowed Actions

```bash
# ✅ Update a Deployment — ALLOWED (cicd-deployer has deployments/update)
kubectl auth can-i update deployments \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-cicd-sa
# Output: yes

# ✅ Patch a Deployment — ALLOWED (for --set image.tag=x.y.z)
kubectl auth can-i patch deployments \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-cicd-sa
# Output: yes

# ✅ List Pods (verify rollout) — ALLOWED
kubectl auth can-i list pods \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-cicd-sa
# Output: yes
```

---

## Part 4: Test CI/CD SA — Denied Actions

```bash
# ❌ Delete a Deployment — DENIED (delete not granted)
kubectl auth can-i delete deployments \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-cicd-sa
# Output: no

# ❌ Read Secrets — DENIED
kubectl auth can-i get secrets \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-cicd-sa
# Output: no

# ❌ Create Services — DENIED (not an infrastructure Role)
kubectl auth can-i create services \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-cicd-sa
# Output: no
```

---

## Part 5: View Full Permissions Summary

```bash
# List everything the developer SA can do in dev-team
kubectl auth can-i --list \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa

# Describe the binding to confirm the connection
kubectl describe rolebinding dev-viewer-binding -n dev-team
kubectl describe role dev-viewer -n dev-team
```
