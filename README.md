# AeroStore — E-Commerce DevOps Journey

A comprehensive DevOps project implementing modern infrastructure practices—including Docker, Kubernetes, and automated CI/CD pipelines—for a full-stack e-commerce application. This repository tracks the evolution from local development to a production-ready, cloud-native architecture.

## 🚀 Tech Stack & Infrastructure

| Layer | Technology |
|---|---|
| **Frontend** | React, Vite |
| **Backend** | Node.js, Express |
| **Containers** | Docker, Docker Hub |
| **Orchestration** | Kubernetes (`kind` for local testing) |
| **Networking** | Kubernetes ClusterIP & NodePort Services |

---

## 🏗️ The DevOps Flow (What We've Built So Far)

This project has been built iteratively. If you are a new developer joining the team, here is the journey of how our infrastructure is structured:

### Phase 1: Application Setup ✅
We started with a standard local development environment. 
- A React Frontend and a Node.js/Express Backend communicating via REST.
- *Status: Fully functional locally.*

### Phase 2: Containerization & Registries ✅
We moved away from "it works on my machine" by introducing Docker.
- Created highly optimized `Dockerfiles` for both Frontend and Backend.
- Implemented robust tagging and versioning strategies.
- Pushed our artifacts to Docker Hub for remote distribution.
- *Docs:* [Docker Architecture & Images](docs/Docker-Architecture-Images-Layers-Containers.md), [Container Registry Distribution](docs/Container-Registry-Tagging-And-Distribution.md).

### Phase 3: Kubernetes Orchestration ✅
We transitioned from managing individual Docker containers to orchestrating them declaratively using Kubernetes.
1. **Local Cluster Setup:** We use `kind` (Kubernetes IN Docker) to simulate a production multi-node cluster (1 Control Plane + 1 Worker Node) directly on our local machines.
2. **Workloads:** We manage our applications using **Deployments** (which manage ReplicaSets, which manage Pods). This ensures high availability and enables **Zero-Downtime Rollouts** when updating app versions.
3. **Networking:** We expose our applications using Kubernetes **Services**. A `NodePort` service allows external browser traffic to safely hit our ephemeral Pods without relying on unreliable Pod IP addresses.
- *Docs:* [K8s Architecture](docs/Kubernetes-Cluster-Architecture.md), [Local Cluster Setup](docs/Local-Kubernetes-Cluster-Setup.md), [Pods & ReplicaSets](docs/Kubernetes-Pods-And-ReplicaSets.md), [Deployments & Rollouts](docs/Kubernetes-Deployments-And-Rollouts.md).

---

## 💻 Developer Guide: Running the K8s Environment

If you want to spin up the entire AeroStore Kubernetes environment locally, follow these steps:

### 1. Spin up the Cluster
We have a helper script to easily create the `kind` cluster:
```bash
./scripts/manage-k8s-cluster.sh start
```

### 2. Apply the Workloads & Networking
Deploy the Nginx application and the Service exposing it:
```bash
kubectl apply -f k8s/basics/nginx-deployment.yaml
kubectl apply -f k8s/basics/nginx-service.yaml
```

### 3. Expose to Localhost
Because we are running a virtualized node inside Docker for Windows, we use port-forwarding to bridge the final gap to your browser:
```bash
kubectl port-forward service/aerostore-frontend-service 8080:80
```
*Open your browser to `http://localhost:8080` to see the application!*

---

## 📂 Repository Structure

```text
├── backend/          # Express API source code
├── frontend/         # React SPA source code
├── k8s/              # Kubernetes declarative YAML manifests
│   ├── kind-cluster-config.yaml
│   └── basics/       # Pods, Deployments, and Services
├── scripts/          # Automation scripts (e.g., manage-k8s-cluster.sh)
├── docs/             # Extensive documentation on DevOps concepts
└── README.md
```
