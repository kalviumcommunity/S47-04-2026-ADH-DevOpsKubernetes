# Kubernetes Ingress — External Traffic Routing

> This document explains how external HTTP/S traffic enters a Kubernetes cluster, how it is routed to the correct Service and Pod using Ingress, why NodePort does not scale for production use, and how Ingress simplifies multi-service external access behind a single entry point.

---

## Table of Contents

1. [The Problem: Getting Traffic Into the Cluster](#1-the-problem-getting-traffic-into-the-cluster)
2. [Service Exposure Options](#2-service-exposure-options)
3. [What is Ingress?](#3-what-is-ingress)
4. [The Full External Traffic Path](#4-the-full-external-traffic-path)
5. [Ingress Controller vs Ingress Resource](#5-ingress-controller-vs-ingress-resource)
6. [Path-Based and Host-Based Routing](#6-path-based-and-host-based-routing)
7. [AeroStore Ingress Configuration](#7-aerostore-ingress-configuration)
8. [TLS Termination](#8-tls-termination)
9. [Ingress Diagram](#9-ingress-diagram)
10. [Scenario: NodePort Does Not Scale](#10-scenario-nodeport-does-not-scale)

---

## 1. The Problem: Getting Traffic Into the Cluster

Kubernetes Pods and Services are internal by default. A ClusterIP Service is only reachable from within the cluster. Users on the internet cannot reach it. For production applications, you need a way to expose services to external traffic while maintaining:

- **A single stable entry point** (one IP or DNS name, not one per service)
- **Host or path-based routing** (route `/api` to one service, `/` to another)
- **TLS termination** (HTTPS in, HTTP internally)
- **Load balancing** (distribute traffic across Pods)
- **Advanced features** (rate limiting, auth, rewrites, redirects)

---

## 2. Service Exposure Options

Kubernetes has three native ways to expose a Service externally:

| Type | How it works | Production use |
|---|---|---|
| **ClusterIP** | Internal only — no external access | Internal service-to-service |
| **NodePort** | Exposes a port (30000-32767) on every Node's IP | Dev/testing only |
| **LoadBalancer** | Provisions a cloud load balancer per Service | Expensive at scale |
| **Ingress** | One entry point, routes by host/path to Services | ✅ Production standard |

### Why NodePort Fails at Scale

NodePort exposes a random high port on every Node. To reach `backend`, users go to `<node-ip>:31234`. To reach `frontend`, they go to `<node-ip>:31456`.

Problems:
- Non-standard ports — users must type port numbers in URLs
- One NodePort per Service — with 20 services, 20 different ports to manage
- No TLS — no easy way to serve HTTPS
- No routing logic — can't send `/api` to backend and `/` to frontend
- No rate limiting, auth, or rewrites

### Why LoadBalancer Fails at Scale

Every `type: LoadBalancer` Service provisions a separate cloud load balancer. On GKE or EKS, each load balancer costs money and gets a separate external IP.

- 10 services = 10 load balancers = 10 external IPs = high cost and complexity
- No path routing — each load balancer only knows about one service
- DNS management becomes complex with 10 different IPs

---

## 3. What is Ingress?

Ingress is a Kubernetes resource that defines routing rules for external HTTP/S traffic. It sits in front of all your Services and routes requests based on:
- **Host:** `api.myapp.com` → Service A, `app.myapp.com` → Service B
- **Path:** `/api` → Service A, `/` → Service B

Ingress itself is just a configuration object — it does nothing without an **Ingress Controller** (a running proxy Pod) to enforce its rules.

```
Ingress = routing rules (YAML config)
Ingress Controller = the actual proxy that reads and enforces those rules
```

---

## 4. The Full External Traffic Path

```
Client (Browser)
    │ HTTPS :443
    ▼
Cloud Load Balancer / DNS
  (aerostore.example.com → External IP)
    │
    ▼
Ingress Controller Pod
  (nginx/traefik running inside the cluster)
  - Reads all Ingress resources
  - Terminates TLS (decrypts HTTPS → HTTP)
  - Applies routing rules
  - Applies rate limits, rewrites, redirects
    │
    ├── path: /api/*  ──────────────────────────────►  aerostore-backend-service (ClusterIP :3001)
    │                                                         │
    │                                                    kube-proxy (iptables/ipvs)
    │                                                         │
    │                                               ┌─────────────────────┐
    │                                               │  Pod (backend) #1   │
    │                                               │  Pod (backend) #2   │
    │                                               └─────────────────────┘
    │
    └── path: /*  ────────────────────────────────►  aerostore-frontend-service (ClusterIP :80)
                                                              │
                                                         kube-proxy
                                                              │
                                                     ┌────────────────────┐
                                                     │  Pod (frontend)    │
                                                     └────────────────────┘
```

### Where Routing Happens

| Layer | Routing type | What makes the decision |
|---|---|---|
| **DNS** | Name → IP | Your DNS provider (Route 53, Cloud DNS) |
| **Cloud LB** | IP → Node | Cloud provider's load balancer |
| **Ingress Controller** | Host + Path → Service | nginx/traefik reading Ingress rules |
| **Service (kube-proxy)** | Service → Pod | iptables rules managed by kube-proxy |

### Where Load Balancing Happens

- **Cloud LB → Nodes:** The cloud load balancer balances across cluster Nodes
- **Service → Pods:** kube-proxy's iptables rules randomly distribute connections across healthy Pods

Both layers load-balance independently. A request goes: Cloud LB picks a Node → Ingress Controller on that Node picks a Service → kube-proxy picks a Pod.

---

## 5. Ingress Controller vs Ingress Resource

This is the most commonly misunderstood distinction:

| | Ingress Resource | Ingress Controller |
|---|---|---|
| **What it is** | A Kubernetes API object (YAML) | A Pod running a proxy (nginx, traefik) |
| **Who creates it** | The developer/operator | The platform team (installed once) |
| **What it does** | Declares routing rules | Reads rules and enforces them |
| **Lives in** | etcd (like any K8s object) | As a Deployment in `ingress-nginx` namespace |

Without an Ingress Controller, an Ingress resource does nothing. The Ingress Controller watches all Ingress resources via the Kubernetes API and dynamically reconfigures its proxy (nginx config, etc.) to enforce their rules.

### Installing the Ingress Controller (kind)

```bash
# Install nginx Ingress Controller for kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for the controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

# Verify
kubectl get pods -n ingress-nginx
```

---

## 6. Path-Based and Host-Based Routing

### Path-Based Routing (same host, different paths)

```yaml
rules:
  - host: aerostore.example.com
    http:
      paths:
        - path: /api          # → backend service
        - path: /             # → frontend service (catch-all)
```

All requests to `aerostore.example.com` are handled by one Ingress. The path determines which Service receives the request. This is the most common pattern for single-domain apps.

### Host-Based Routing (different subdomains)

```yaml
rules:
  - host: api.aerostore.com   # → backend service
    http:
      paths:
        - path: /
  - host: aerostore.com       # → frontend service
    http:
      paths:
        - path: /
```

Each subdomain routes to a different Service. Used when frontend and backend have distinct domains. Both are served through the same Ingress Controller on port 443.

### pathType Options

| pathType | Behavior |
|---|---|
| **Prefix** | Matches any path starting with the prefix. `/api` matches `/api`, `/api/v1`, `/api/products` |
| **Exact** | Matches only the exact path. `/api` does NOT match `/api/v1` |
| **ImplementationSpecific** | Behavior defined by the Ingress Controller |

---

## 7. AeroStore Ingress Configuration

```yaml
# k8s/basics/aerostore-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: aerostore-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/limit-rps: "100"
spec:
  tls:
    - hosts:
        - aerostore.example.com
      secretName: aerostore-tls
  rules:
    - host: aerostore.example.com
      http:
        paths:
          - path: /api(/|$)(.*)    # → backend (port 3001)
            pathType: Prefix
            backend:
              service:
                name: aerostore-backend-service
                port:
                  number: 3001

          - path: /                # → frontend (port 80) — catch-all
            pathType: Prefix
            backend:
              service:
                name: aerostore-frontend-service
                port:
                  number: 80
```

### Key Annotations Explained

| Annotation | Effect |
|---|---|
| `ingress.class: nginx` | Assigns this Ingress to the nginx controller |
| `rewrite-target: /$2` | Strips `/api` prefix before forwarding — backend gets `/products` not `/api/products` |
| `ssl-redirect: true` | Forces HTTPS — HTTP requests get a 301 redirect |
| `limit-rps: 100` | Rate limits to 100 requests/second per IP — prevents abuse |

### Mapping to the AeroStore Architecture

```
User → https://aerostore.example.com/api/products
         ↓ Ingress matches /api/*
         ↓ Rewrite: /api/products → /products
         → aerostore-backend-service:3001 → backend Pods

User → https://aerostore.example.com/
         ↓ Ingress matches /* (catch-all)
         → aerostore-frontend-service:80 → frontend Pod
         ↓ React Router handles /about, /cart, etc. client-side
```

---

## 8. TLS Termination

TLS termination means the Ingress Controller decrypts HTTPS traffic and forwards plain HTTP internally. This has several advantages:

- **Centralized cert management:** One certificate at the Ingress Controller, not per-Service
- **Simpler internal networking:** Services communicate over HTTP without cert handling
- **cert-manager integration:** Automatically provision and rotate Let's Encrypt certificates

```bash
# In production: install cert-manager and use Let's Encrypt
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Then annotate the Ingress:
# cert-manager.io/cluster-issuer: "letsencrypt-prod"
# cert-manager auto-creates and rotates the TLS secret
```

In kind for local testing:
```bash
# Generate self-signed certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -subj "/CN=aerostore.example.com"

# Create the Secret
kubectl create secret tls aerostore-tls --key tls.key --cert tls.crt

# Then apply the Ingress
kubectl apply -f k8s/basics/aerostore-ingress.yaml
```

---

## 9. Ingress Diagram

![Kubernetes Ingress Traffic Routing Diagram](k8s-ingress-diagram.png)

```
Client → HTTPS :443 → Cloud LB → Ingress Controller Pod
                                        │
                         reads Ingress routing rules
                                        │
              ┌─────────────────────────┴────────────────────────┐
              │                                                   │
        /api/* → backend-service:3001              /* → frontend-service:80
              │                                                   │
         kube-proxy                                          kube-proxy
              │                                                   │
      [Pod #1] [Pod #2]                                     [Pod #1]

NodePort (old): each service → unique port (30001, 30002...)
Ingress  (new): all services → port 443, route by path
```

---

## 10. Scenario: NodePort Does Not Scale

**Scenario:** Application currently uses NodePort. As the number of services grows, managing ports and access becomes difficult.

### Why NodePort Breaks Down

With 5 services on NodePort:
- `frontend`: `:31001`
- `backend-api`: `:31002`
- `auth-service`: `:31003`
- `notifications`: `:31004`
- `admin`: `:31005`

Issues:
1. **Non-standard ports** — users must remember or bookmarks include port numbers
2. **No HTTPS** — NodePort doesn't handle TLS. Each service needs its own TLS setup
3. **Firewall rules per port** — every new service requires a new firewall rule opening that port
4. **No path routing** — can't have `myapp.com/api` go to backend and `myapp.com/` go to frontend on NodePort
5. **Node IP dependency** — users must use the Node's IP, which changes if the Node is replaced
6. **No centralized rate limiting or auth** — each service must handle this independently

### How Ingress Solves Each Problem

| NodePort problem | Ingress solution |
|---|---|
| Non-standard ports | Single port 443 for all services |
| No HTTPS | TLS terminated at Ingress Controller for all services |
| Firewall rules per port | One firewall rule: allow port 443 |
| No path routing | Path/host rules route to any Service |
| Node IP dependency | Stable DNS name → LoadBalancer IP (independent of Nodes) |
| No centralized features | Rate limiting, auth, rewrites at the controller for all services |

### How Ingress is Preferred in Production

In production, the pattern is:
1. All Services are `type: ClusterIP` (internal only)
2. One Ingress Controller is deployed (e.g., nginx Ingress via Helm)
3. Its Service is `type: LoadBalancer` (gets one external IP from the cloud)
4. All routing rules go into Ingress resources — add a new service by adding 3 lines to the Ingress YAML
5. cert-manager handles TLS certificate provisioning automatically

Adding a new microservice requires:
```yaml
# Just add a path rule to the existing Ingress
- path: /notifications
  pathType: Prefix
  backend:
    service:
      name: notifications-service
      port:
        number: 8080
```

No new load balancer. No new firewall rule. No new port. Just three lines of YAML.
