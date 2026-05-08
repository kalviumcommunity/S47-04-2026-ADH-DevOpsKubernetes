# Kubernetes RBAC — Role-Based Access Control

> This document explains how Kubernetes RBAC secures cluster access by restricting what each user or ServiceAccount can do, why the principle of least privilege matters, and how Roles, ClusterRoles, RoleBindings, and ClusterRoleBindings work together to enforce namespace-scoped access boundaries.

---

## Table of Contents

1. [Why RBAC Exists](#1-why-rbac-exists)
2. [RBAC Primitives](#2-rbac-primitives)
3. [AeroStore RBAC Design](#3-aerostore-rbac-design)
4. [dev-viewer Role — Read-Only Developer Access](#4-dev-viewer-role--read-only-developer-access)
5. [cicd-deployer Role — Pipeline Deploy Access](#5-cicd-deployer-role--pipeline-deploy-access)
6. [RoleBindings — Connecting Roles to Subjects](#6-rolebindings--connecting-roles-to-subjects)
7. [Verifying Access with kubectl auth can-i](#7-verifying-access-with-kubectl-auth-can-i)
8. [RBAC Diagram](#8-rbac-diagram)
9. [Scenario: Multi-Team Cluster Access Control](#9-scenario-multi-team-cluster-access-control)

---

## 1. Why RBAC Exists

By default, when Kubernetes was first released, any authenticated user could do almost anything in the cluster. As clusters grew to serve multiple teams, this became a serious security and operational problem:

- A developer deleting a production Deployment by accident
- A compromised CI/CD pipeline with access to all namespaces
- A new team member able to read database Secrets
- An application Pod that could modify its own Deployment

RBAC (Role-Based Access Control) solves this by enforcing: **every action must be explicitly permitted. Everything else is denied.**

The default in a properly configured cluster is **zero access**. Access is built up from nothing by explicitly granting the minimum required permissions.

---

## 2. RBAC Primitives

| Object | Scope | Purpose |
|---|---|---|
| **Role** | Namespace | Defines permissions within one namespace |
| **ClusterRole** | Cluster-wide | Defines permissions across all namespaces |
| **RoleBinding** | Namespace | Grants a Role (or ClusterRole) to a subject within one namespace |
| **ClusterRoleBinding** | Cluster-wide | Grants a ClusterRole to a subject across all namespaces |
| **Subject** | N/A | Who receives the permissions: User, Group, or ServiceAccount |

### How the API Server Evaluates a Request

```
Request: ServiceAccount aerostore-dev-sa wants to list Pods in namespace dev-team

API Server checks:
  1. Is the ServiceAccount authenticated? Yes → proceed
  2. Find all RoleBindings in namespace dev-team that reference this SA
     Found: dev-viewer-binding → references Role dev-viewer
  3. Does dev-viewer grant [list] on [pods] in [dev-team]?
     Yes → ALLOW (200 OK)
  4. If not found → DENY (403 Forbidden)
```

The check is: **does any binding in this namespace grant this verb on this resource to this subject?** If the answer is no — for any reason — the request is denied.

---

## 3. AeroStore RBAC Design

The AeroStore cluster is shared between the development team and the platform/CI-CD team. The design applies the principle of least privilege:

| Team | Identity | Role | Allowed | Denied |
|---|---|---|---|---|
| Developers | `aerostore-dev-sa` | `dev-viewer` | Read Pods, Services, Deployments, ConfigMaps, Events | Write, Delete, Secrets, Exec, Other namespaces |
| CI/CD Pipeline | `aerostore-cicd-sa` | `cicd-deployer` | Read + Update/Patch Deployments | Delete, Create, Secrets, Services, Other namespaces |
| Other teams | None | None | Nothing (403 on all requests) | Everything |

All Roles and RoleBindings live in the `dev-team` namespace. No subject has access to the `production` or `staging` namespaces from these bindings.

---

## 4. dev-viewer Role — Read-Only Developer Access

```yaml
# k8s/rbac/dev-viewer-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-viewer
  namespace: dev-team
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/status"]
    verbs: ["get", "list", "watch"]

  - apiGroups: [""]
    resources: ["services", "endpoints"]
    verbs: ["get", "list", "watch"]

  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]

  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]

  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
```

### What Each Section Does

**`apiGroups: [""]`** — The empty string refers to the core Kubernetes API group (v1 resources like Pod, Service, ConfigMap, Secret). Resources in the `apps` group (Deployment, ReplicaSet) need `"apps"` in apiGroups.

**`verbs: ["get", "list", "watch"]`** — Read-only verbs:
- `get` = read one resource by name (`kubectl get pod my-pod`)
- `list` = read all resources of a type (`kubectl get pods`)
- `watch` = stream updates (`kubectl get pods -w`)

`create`, `update`, `patch`, `delete` are not listed → they are denied.

**`pods/log`** — A subresource. Pod logs are served at a different API path (`/api/v1/namespaces/dev-team/pods/my-pod/log`). Must be listed separately from `pods`.

**Secrets are not listed** — Even though ConfigMaps are readable, Secrets require an explicit separate rule entry. Omitting Secrets means the API server denies all access to Secrets for this role.

---

## 5. cicd-deployer Role — Pipeline Deploy Access

```yaml
# k8s/rbac/cicd-deployer-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cicd-deployer
  namespace: dev-team
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]

  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["update", "patch"]

  - apiGroups: [""]
    resources: ["pods", "pods/status"]
    verbs: ["get", "list", "watch"]

  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list"]
```

### Why These Specific Verbs

**`update` and `patch` on Deployments** — A CI/CD pipeline performing `helm upgrade` or `kubectl set image deployment/backend image=nginx:1.18.0` uses a PATCH or PUT request to the Deployments API. The pipeline needs to mutate the Deployment, but only to update the image — not to delete or replace the entire resource.

**`create` is excluded** — The pipeline should not be able to create new Deployments. It should only update existing ones. If a new Deployment needs to be created, that's an infrastructure change requiring a code review, not a CI pipeline action.

**`delete` is excluded** — If a pipeline is compromised, the attacker cannot delete running Deployments. The worst they can do is update images — bad, but recoverable.

---

## 6. RoleBindings — Connecting Roles to Subjects

```yaml
# k8s/rbac/role-bindings.yaml

# Developer binding
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-viewer-binding
  namespace: dev-team
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: dev-viewer
subjects:
  - kind: ServiceAccount
    name: aerostore-dev-sa
    namespace: dev-team
```

### The Three Parts of a RoleBinding

1. **`metadata.namespace`** — The namespace where this binding applies. The binding lives in `dev-team`, so it only grants permissions in `dev-team`. If the same ServiceAccount tries to list Pods in `production`, the API server finds no binding there and returns 403.

2. **`roleRef`** — Immutable once created. Points to the Role being granted. You cannot change the roleRef after creation — you must delete and recreate the binding.

3. **`subjects`** — Who receives the permissions. Can be multiple entries. A RoleBinding can grant the same Role to multiple ServiceAccounts, users, or groups simultaneously.

---

## 7. Verifying Access with kubectl auth can-i

`kubectl auth can-i` simulates a permission check without actually executing the request:

```bash
# Test: can the developer SA list pods in dev-team?
kubectl auth can-i list pods \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# yes ✅

# Test: can the developer SA delete pods?
kubectl auth can-i delete pods \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# no ❌

# Test: can the developer SA access the production namespace?
kubectl auth can-i list pods \
  --namespace production \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
# no ❌ (no RoleBinding in production namespace)

# Test: can the CI/CD SA update deployments?
kubectl auth can-i update deployments \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-cicd-sa
# yes ✅

# Test: can the CI/CD SA delete deployments?
kubectl auth can-i delete deployments \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-cicd-sa
# no ❌

# See ALL permissions for the developer SA in dev-team
kubectl auth can-i --list \
  --namespace dev-team \
  --as system:serviceaccount:dev-team:aerostore-dev-sa
```

---

## 8. RBAC Diagram

![Kubernetes RBAC Diagram](k8s-rbac-diagram.png)

```
aerostore-dev-sa  →  RoleBinding: dev-viewer-binding  →  Role: dev-viewer
                                                            │
                                              resources: pods, services,
                                              deployments, configmaps, events
                                              verbs: get, list, watch

aerostore-cicd-sa →  RoleBinding: cicd-deployer-binding → Role: cicd-deployer
                                                            │
                                              resources: deployments
                                              verbs: get, list, update, patch

Other team SA     →  No RoleBinding in dev-team  →  403 Forbidden on all requests

Both Roles: namespace: dev-team → no access to production/staging/monitoring
```

---

## 9. Scenario: Multi-Team Cluster Access Control

**Scenario:** Kubernetes cluster is shared by multiple teams. Developers should be able to view Pods and Services in their namespace but must not delete resources or access other namespaces.

### RBAC Role Design

```yaml
# Role type: Role (not ClusterRole) — namespace-scoped
# Why: ClusterRole with ClusterRoleBinding grants access to ALL namespaces
# A Role only applies in the namespace it's created in

apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-viewer
  namespace: dev-team          ← scoped to this namespace only
rules:
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list", "watch"]   ← read only, no write verbs
```

### Resources and Verbs to Allow

| Resource | Allowed Verbs | Rationale |
|---|---|---|
| pods, pods/log | get, list, watch | See what's running, view logs |
| services | get, list, watch | Understand service discovery |
| deployments | get, list, watch | View rollout status |
| configmaps | get, list, watch | Read non-sensitive config |
| events | get, list, watch | Debug without modifying |
| **secrets** | **none** | Sensitive — not for developers |
| **pods/exec** | **none** | No shell into containers |
| **delete, create, update** | **none** | Read-only access |

### Why a Role, Not a ClusterRole

A `ClusterRole` with a `ClusterRoleBinding` would grant these permissions across every namespace in the cluster — production, staging, monitoring, other teams' namespaces. That's a massive over-grant.

A `Role` scoped to `dev-team` means:
- Developer SA has read access in `dev-team` ✓
- Developer SA gets 403 in `production` ✓ (no binding there)
- Developer SA gets 403 in `staging` ✓ (no binding there)
- Developer SA gets 403 in another team's namespace ✓ (no binding there)

The namespace boundary is enforced by the Kubernetes API server automatically — there's nothing the developer can do to cross it with these credentials.

### How RoleBinding Enforces Restrictions

The RoleBinding is the glue. Without it:
- The Role exists but has no subjects → no effect
- The ServiceAccount exists but has no roles → 403 on everything

With the RoleBinding in `dev-team`:
- API server finds: `aerostore-dev-sa` → `dev-viewer-binding` → `dev-viewer`
- `dev-viewer` allows `list` on `pods` in `dev-team`
- Request succeeds

Without a RoleBinding in `production`:
- API server finds: no binding for `aerostore-dev-sa` in `production`
- Request denied → 403 Forbidden
- The developer's credentials are not useful outside their namespace
