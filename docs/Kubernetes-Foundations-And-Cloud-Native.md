# Kubernetes Foundations — Why K8s and Cloud-Native Architecture

> This document explains why Kubernetes is essential in modern DevOps, what problems it solves, and how it fits into cloud-native architecture for scalable, resilient systems.

---

## Table of Contents

1. [Why Kubernetes Exists](#1-why-kubernetes-exists)
2. [What Kubernetes Takes Over](#2-what-kubernetes-takes-over)
3. [Core Concepts](#3-core-concepts)
4. [How Kubernetes Fits Into Cloud-Native Architecture](#4-how-kubernetes-fits-into-cloud-native-architecture)
5. [How Our Project Maps to Kubernetes](#5-how-our-project-maps-to-kubernetes)
6. [Declarative vs Imperative](#6-declarative-vs-imperative)
7. [Cloud-Native Principles Applied](#7-cloud-native-principles-applied)
8. [What Happens Next](#8-what-happens-next)

---

## 1. Why Kubernetes Exists

### The Problem Without Kubernetes

With Docker alone, you can containerize your app. But in production, you face questions Docker doesn't answer:

| Question | Docker's Answer | Kubernetes' Answer |
|---|---|---|
| What if a container crashes? | It stays down. You restart manually. | **Auto-restarts it** within seconds. |
| How do I run 5 copies for traffic? | Run `docker run` 5 times manually. | **Declare `replicas: 5`**, K8s handles it. |
| How do I update without downtime? | Stop old, start new (downtime). | **Rolling updates** — zero downtime. |
| How do I rollback a bad deploy? | Hope you remember the old image tag. | **`kubectl rollout undo`** — instant. |
| How do containers find each other? | Hardcode IPs or use Docker networks. | **Service discovery** via DNS names. |
| What if traffic spikes? | Manually add more containers. | **Autoscaling** based on CPU/memory. |

**Kubernetes is the orchestrator** — it manages containers at scale so you don't have to babysit each one.

### The Journey So Far

```
Manual Deploy → Docker Containers → Container Registry → Kubernetes (you are here)
     ↓                 ↓                    ↓                    ↓
  "It works       "It works            "Anyone can          "It runs itself,
   on my            anywhere"            pull it"             heals itself,
   machine"                                                   scales itself"
```

---

## 2. What Kubernetes Takes Over

Kubernetes automates responsibilities that would otherwise fall on developers or ops teams:

### From Developers

| Responsibility | Before K8s | With K8s |
|---|---|---|
| Restarting crashed apps | Write watchdog scripts or monitor manually | **Automatic** — liveness probes restart unhealthy pods |
| Load balancing across instances | Configure nginx/HAProxy manually | **Built-in** — Services distribute traffic automatically |
| Environment configuration | Hardcode or manage .env files | **ConfigMaps and Secrets** — managed declaratively |
| Service-to-service communication | Hardcode URLs and ports | **DNS-based discovery** — `backend-service:3001` |

### From Ops Teams

| Responsibility | Before K8s | With K8s |
|---|---|---|
| Scaling up/down | SSH into servers, start more containers | **`kubectl scale`** or autoscaling policies |
| Zero-downtime deployments | Complex blue-green or canary scripts | **Rolling updates** — built into Deployments |
| Resource allocation | Manually track server capacity | **Resource requests/limits** — K8s schedules optimally |
| Rollbacks | Maintain old images, manual revert | **`kubectl rollout undo`** — one command |

---

## 3. Core Concepts

### Pods
The smallest deployable unit in Kubernetes. A Pod wraps one or more containers. In our case, each Pod would run one container (backend or frontend).

```
┌──── Pod ────────────────┐
│  ┌────────────────────┐ │
│  │   Container        │ │
│  │   (your app)       │ │
│  └────────────────────┘ │
└─────────────────────────┘
```

**Why Pods?** Containers are ephemeral — they crash, restart, get rescheduled to different machines. Pods give Kubernetes a unit to manage, track, and replace.

### Deployments
A Deployment tells Kubernetes: *"I want N replicas of this Pod running at all times."* If a Pod dies, the Deployment controller creates a new one. If you update the image tag, it performs a rolling update.

**Why Deployments?** They are the **declarative** way to manage applications. You declare the desired state, Kubernetes makes it happen.

### Services
Pods get random IP addresses that change when they restart. A Service provides a **stable endpoint** (DNS name + IP) that routes traffic to the right Pods.

```
                         ┌── Pod 1 (10.0.0.5)
Client ──► Service ──────┤
           (stable IP)   └── Pod 2 (10.0.0.9)
```

**Why Services?** Without them, every restart would break connections. Services abstract away the instability of individual Pods.

### Service Types

| Type | Accessibility | Use Case |
|---|---|---|
| `ClusterIP` | Internal only (within cluster) | Backend APIs, databases |
| `LoadBalancer` | External (internet-facing) | Frontend apps, public APIs |
| `NodePort` | External (via node IP:port) | Dev/testing environments |

### Health Probes

Kubernetes monitors containers using probes:

| Probe | Purpose | If It Fails |
|---|---|---|
| **Liveness Probe** | "Is the container alive?" | K8s kills and restarts it |
| **Readiness Probe** | "Can it handle traffic?" | K8s stops sending traffic to it |

This is why our backend has a `/api/health` endpoint — it's designed to be used as a Kubernetes health check.

### Resource Limits

Every container can declare:
- **Requests** — minimum guaranteed CPU/memory
- **Limits** — maximum allowed CPU/memory

Without these, one runaway pod could starve all other pods on the same node.

---

## 4. How Kubernetes Fits Into Cloud-Native Architecture

```
┌────────────────────────────────────────────────────────┐
│                  Cloud-Native Stack                     │
│                                                        │
│   Code ──► Docker ──► Registry ──► Kubernetes ──► Users│
│                                                        │
│   Write     Package    Store &       Orchestrate,      │
│   app       as image   version       scale, heal       │
└────────────────────────────────────────────────────────┘
```

Kubernetes is the **runtime layer** of cloud-native architecture:

1. **Docker** answers: *"How do I package my app?"*
2. **Registry** answers: *"Where do I store and distribute images?"*
3. **Kubernetes** answers: *"How do I run, scale, and manage containers in production?"*

Without Kubernetes, you'd need to manually handle deployment, scaling, networking, health monitoring, and failover — for every service, on every server.

---

## 5. How Our Project Maps to Kubernetes

Our AeroStore project (frontend + backend) maps naturally to Kubernetes concepts:

```
                    ┌─── Kubernetes Cluster ──────────────────────────┐
                    │                                                  │
  Users ──────────► │  frontend-service (LoadBalancer :80)             │
                    │       │                                          │
                    │       ├──► frontend-pod-1 (nginx)                │
                    │       └──► frontend-pod-2 (nginx)                │
                    │                                                  │
                    │  backend-service (ClusterIP :3001)               │
                    │       │                                          │
                    │       ├──► backend-pod-1 (node:express)          │
                    │       └──► backend-pod-2 (node:express)          │
                    │                                                  │
                    └──────────────────────────────────────────────────┘

Images pulled from: Docker Hub (kalviaki0/devops-frontend:v1.0, kalviaki0/devops-backend:v1.0)
```

| Our Component | K8s Resource | Why |
|---|---|---|
| Frontend (nginx) | Deployment + LoadBalancer Service | Users access it externally, needs multiple replicas |
| Backend (Express) | Deployment + ClusterIP Service | Only frontend talks to it, no public exposure needed |
| Docker images | Pulled by K8s from Docker Hub | Pinned tags ensure exact version runs |
| `/api/health` endpoint | Liveness/Readiness probe target | K8s uses it to monitor backend health |

### Why ClusterIP for Backend?

The backend API doesn't need to be accessible from the internet. Only the frontend communicates with it inside the cluster. Using `ClusterIP` instead of `LoadBalancer` follows the **principle of least privilege** — don't expose more than necessary.

### Why LoadBalancer for Frontend?

Users need to access the frontend from outside the cluster. A `LoadBalancer` Service provisions an external IP (in cloud environments) or can be accessed via `minikube service` locally.

---

## 6. Declarative vs Imperative

This is the fundamental shift Kubernetes introduces:

**Docker approach (imperative):** *"Run this container, on this port, with this name"*
```bash
docker run -d -p 3001:3001 --name backend devops-backend
```
You tell Docker **what to do**. If it crashes, you run the command again.

**Kubernetes approach (declarative):** *"I want 2 backend pods, always running, with health checks"*
```yaml
replicas: 2
image: kalviaki0/devops-backend:v1.0
livenessProbe:
  httpGet:
    path: /api/health
    port: 3001
```
You tell Kubernetes **what you want**. It figures out how to get there and continuously ensures reality matches your desired state. If a pod crashes, K8s creates a new one — no human intervention.

---

## 7. Cloud-Native Principles Applied

Our project already follows core cloud-native principles:

| Principle | How We Apply It |
|---|---|
| **Containerization** | Frontend and backend are Dockerized with optimized, multi-stage Dockerfiles |
| **Image registry** | Images stored on Docker Hub (`kalviaki0/*`) with version tags (`v1.0`) |
| **Separation of concerns** | Frontend (nginx) and backend (Node.js) are independently deployable |
| **Health endpoints** | Backend exposes `/api/health` — ready for K8s liveness probes |
| **Immutable infrastructure** | Pinned image tags (`v1.0`, not `latest`) ensure predictable deployments |
| **Stateless design** | Backend serves from `products.json`, no database state to manage (yet) |
| **Minimal images** | Alpine-based images reduce attack surface and pull times |

These choices weren't accidental — they were made with Kubernetes deployment in mind from the start.

---

## 8. What Happens Next

| Step | What It Adds |
|---|---|
| **Write K8s manifests** | Deployment + Service YAML files for frontend and backend |
| **Deploy to a cluster** | Apply manifests to Minikube or a cloud K8s cluster |
| **ConfigMaps & Secrets** | Externalize environment variables and sensitive config |
| **Ingress Controller** | Single entry point with path-based routing (`/api` → backend, `/` → frontend) |
| **Horizontal Pod Autoscaler** | Automatically scale pods based on CPU/memory usage |
| **CI/CD integration** | Automate: push code → build image → push to registry → deploy to K8s |

---

## Key Commands Reference

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes

# Deploy resources
kubectl apply -f <manifest.yaml>

# Check status
kubectl get deployments
kubectl get pods
kubectl get services

# View logs
kubectl logs <pod-name>

# Interactive debugging
kubectl exec -it <pod-name> -- sh

# Scale replicas
kubectl scale deployment <name> --replicas=3

# Rolling update
kubectl set image deployment/<name> <container>=<new-image>:<tag>

# Rollback
kubectl rollout undo deployment/<name>

# Delete resources
kubectl delete -f <manifest.yaml>
```
