# NGINX Ingress Controller — Configuration and Behavior

> This document explains how the NGINX Ingress Controller works inside a Kubernetes cluster, how it handles incoming HTTP requests, and how the Ingress resource maps a URL to a Service and Pods. It covers both the local kind setup and the production pattern.

---

## Table of Contents

1. [The Problem: ClusterIP is Internal-Only](#1-the-problem-clusterip-is-internal-only)
2. [What the NGINX Ingress Controller Does](#2-what-the-nginx-ingress-controller-does)
3. [How the Controller Handles a Request — Step by Step](#3-how-the-controller-handles-a-request--step-by-step)
4. [Ingress Resource — Mapping URL to Service](#4-ingress-resource--mapping-url-to-service)
5. [Local Setup in kind](#5-local-setup-in-kind)
6. [Access URLs and Verification](#6-access-urls-and-verification)
7. [How the Controller Auto-Generates nginx.conf](#7-how-the-controller-auto-generates-nginxconf)
8. [Scenario: ClusterIP Is Not Enough for External Access](#8-scenario-clusterip-is-not-enough-for-external-access)

---

## 1. The Problem: ClusterIP is Internal-Only

When a Kubernetes Service is created with `type: ClusterIP` (the default), it gets a virtual IP address that only exists inside the cluster's network. Pods inside the cluster can reach it by name (`aerostore-backend-service.default.svc.cluster.local`). But a user sitting outside the cluster — on the internet or even on the local machine — cannot reach a ClusterIP address at all.

```
External user → http://localhost/api/products

ClusterIP Service only:
  User request reaches the host machine
  No process is listening on port 80
  Connection refused. The user gets nothing.

ClusterIP Service + Ingress Controller:
  User request reaches the host machine on port 80
  nginx Ingress Controller Pod is listening (via kind extraPortMappings)
  Controller matches /api/* rule → proxies to ClusterIP Service
  Service → Pod → response travels back
  User receives the response. ✓
```

---

## 2. What the NGINX Ingress Controller Does

The nginx Ingress Controller is a Deployment running in the `ingress-nginx` namespace. It is composed of two responsibilities:

**1. Controller (Kubernetes-facing):**
- Watches the Kubernetes API for `Ingress` resources (across all namespaces)
- When an Ingress is created, updated, or deleted, it automatically regenerates its nginx configuration
- No manual nginx.conf editing required

**2. Proxy (traffic-facing):**
- Listens on host ports 80 and 443 (via kind extraPortMappings or NodePort)
- Receives all incoming external HTTP/S traffic
- Applies the routing rules from all Ingress resources
- Proxies matched requests to the correct ClusterIP Service
- Handles TLS termination, URL rewriting, rate limiting, CORS, and auth

```
[Kubernetes API]
    ↓ (watches for Ingress changes)
[nginx Ingress Controller Pod]
    ↕ (auto-updates nginx.conf)
[nginx proxy process]
    ↑ (receives external traffic on :80/:443)
```

---

## 3. How the Controller Handles a Request — Step by Step

```
User: GET http://localhost/api/products HTTP/1.1

Step 1: OS routing
  Port 80 on localhost → kind extraPortMapping → Node container port 80
  The nginx Ingress Controller Pod is bound to Node port 80

Step 2: nginx receives the request
  Host:    localhost
  Path:    /api/products
  Method:  GET

Step 3: Controller matches against loaded Ingress rules
  Checks all Ingress resources in the cluster
  Finds: aerostore-local-ingress
  Rule: path /api(/|$)(.*) → rewrite /$2 → service aerostore-backend-service:3001

Step 4: URL rewrite applied
  /api/products → regex captures "products" in group $2
  Rewrites to: /products

Step 5: nginx proxies to the Service DNS name
  GET /products HTTP/1.1
  Host: aerostore-backend-service.default.svc.cluster.local:3001

Step 6: kube-proxy resolves the Service to a Pod
  iptables rule: aerostore-backend-service:3001 → Pod IP:3001 (round-robin)
  Selected: 10.244.0.15:3001

Step 7: Backend Pod processes the request
  Returns: 200 OK with JSON body

Step 8: Response travels back through nginx → to user
  nginx adds response headers (X-Request-ID, etc.)
  User receives: 200 OK {"products": [...]}
```

---

## 4. Ingress Resource — Mapping URL to Service

```yaml
# k8s/basics/nginx-ingress-local.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: aerostore-local-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
    - http:                              # No host = matches any hostname (localhost)
        paths:
          - path: /api(/|$)(.*)          # Matches /api, /api/, /api/products
            pathType: Prefix
            backend:
              service:
                name: aerostore-backend-service
                port:
                  number: 3001

          - path: /                      # Catch-all — matches everything else
            pathType: Prefix
            backend:
              service:
                name: aerostore-frontend-service
                port:
                  number: 80
```

### URL → Service Mapping Table

| Request URL | Matched Rule | Rewritten URL | Target Service | Port |
|---|---|---|---|---|
| `http://localhost/` | `/*` | `/` | `aerostore-frontend-service` | 80 |
| `http://localhost/about` | `/*` | `/about` | `aerostore-frontend-service` | 80 |
| `http://localhost/api/` | `/api(/\|$)(.*)` | `/` | `aerostore-backend-service` | 3001 |
| `http://localhost/api/products` | `/api(/\|$)(.*)` | `/products` | `aerostore-backend-service` | 3001 |
| `http://localhost/api/cart/1` | `/api(/\|$)(.*)` | `/cart/1` | `aerostore-backend-service` | 3001 |

---

## 5. Local Setup in kind

### Prerequisites

The `k8s/kind-cluster-config.yaml` must include `extraPortMappings` so port 80 on the host reaches the cluster:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
```

### Automated Setup

```bash
# Run the setup script (installs controller, applies Ingress, shows access URLs)
chmod +x scripts/setup-ingress-controller.sh
./scripts/setup-ingress-controller.sh
```

### Manual Setup

```bash
# 1. Install nginx Ingress Controller (kind-specific)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# 2. Wait for the controller Pod to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

# 3. Verify the controller is running
kubectl get pods -n ingress-nginx
# NAME                                       READY   STATUS
# ingress-nginx-controller-xxxxxxxxx-xxxxx   1/1     Running

# 4. Apply the Ingress resource
kubectl apply -f k8s/basics/nginx-ingress-local.yaml

# 5. Verify the Ingress
kubectl get ingress aerostore-local-ingress
kubectl describe ingress aerostore-local-ingress
```

---

## 6. Access URLs and Verification

After the controller and Ingress are running:

```bash
# Access frontend
curl http://localhost/
# Returns: HTML of the React SPA

# Access backend API
curl http://localhost/api/
# Returns: JSON from the backend

# Test a specific endpoint
curl http://localhost/api/products
# URL rewrite strips /api → backend receives GET /products

# Watch controller logs as you make requests
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --follow

# Check Ingress status
kubectl get ingress aerostore-local-ingress
# NAME                     CLASS    HOSTS   ADDRESS     PORTS
# aerostore-local-ingress  <none>   *       localhost   80

# Full Ingress detail including active rules
kubectl describe ingress aerostore-local-ingress
```

---

## 7. How the Controller Auto-Generates nginx.conf

Every time an Ingress resource is created or updated, the controller generates an nginx configuration block. You can inspect it:

```bash
# View the full nginx.conf generated by the controller
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- cat /etc/nginx/nginx.conf | grep -A 20 "aerostore"

# The controller generates entries like:
#   upstream aerostore-default-aerostore-backend-service-3001 {
#     server 10.244.0.15:3001;
#     server 10.244.0.16:3001;   # multiple Pods if scaled
#   }
#   location ~* "^/api(/|$)(.*)" {
#     rewrite "^/api(/|$)(.*)" /$2 break;
#     proxy_pass http://aerostore-default-aerostore-backend-service-3001;
#   }
```

This is what "Ingress Controller" means in practice: it translates high-level Kubernetes routing rules into concrete nginx proxy configuration, automatically, every time the cluster state changes.

---

## 8. Scenario: ClusterIP Is Not Enough for External Access

**Scenario:** Application runs correctly inside the cluster and is accessible via a ClusterIP Service. Users outside the cluster cannot access it.

### Why ClusterIP Alone Fails

A ClusterIP Service creates a virtual IP (e.g., `10.96.45.123`) that exists only in the cluster's internal network space. This IP is reachable only by other Pods running on the same cluster. It does not bind to any port on the host machine. There is no process on the host listening on port 80 that can forward traffic into the cluster.

### How the NGINX Ingress Controller Enables External Access

1. The Ingress Controller Pod is deployed with `hostPort: 80` and `hostPort: 443` (via kind extraPortMappings or NodePort in other setups)
2. This means the nginx process inside the controller Pod is actually listening on the host machine's port 80
3. When a user sends a request to `http://localhost`, it arrives at the host's port 80, which is forwarded into the Ingress Controller Pod
4. The controller reads the Ingress resource rules, matches the path, and proxies the request to the correct ClusterIP Service using the cluster's internal DNS
5. The ClusterIP Service is now reachable — not because it's exposed externally, but because the controller acts as a bridge between the external network and the internal cluster network

### How Ingress Maps URL to Service and Pods

```
URL: http://localhost/api/products

Ingress rule match:
  path: /api(/|$)(.*) → service: aerostore-backend-service, port: 3001

Controller proxies to:
  http://aerostore-backend-service.default.svc.cluster.local:3001/products

Service endpoint selection (kube-proxy):
  → Pod IP: 10.244.0.15, port: 3001

Pod processes:
  GET /products → returns JSON

Response:
  Pod → Service → nginx Controller → User
```

### Why Ingress Is Preferred Over NodePort

| | NodePort | Ingress |
|---|---|---|
| External port | 30000-32767 (non-standard) | 80 / 443 (standard) |
| URL | `http://host:31234` | `http://localhost/` |
| Multiple services | One port per service | One rule per service, same port |
| TLS | Per-service (complex) | Centralized at controller |
| Path routing | Not possible | Native feature |
| Production ready | Dev/testing only | ✅ Production standard |

NodePort is a workaround. Ingress is the designed solution for exposing HTTP applications in Kubernetes.
