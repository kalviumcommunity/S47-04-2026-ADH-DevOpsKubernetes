# AeroStore — E-Commerce DevOps Journey

A comprehensive DevOps project implementing modern infrastructure practices—including Docker, Kubernetes, and automated CI/CD pipelines—for a full-stack e-commerce application. This repository tracks the evolution from local development to a production-ready, cloud-native architecture.

## 🚀 Tech Stack & Infrastructure

| Layer | Technology |
|---|---|
| **Frontend** | React, Vite |
| **Backend** | Node.js, Express |
| **Containers** | Docker, Docker Hub |
| **Orchestration** | Kubernetes (`kind` for local testing) |
| **CI/CD** | GitHub Actions |
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

### Phase 4: Artifact Flow & CI/CD Pipeline Design ✅ *(NEW)*
We designed the end-to-end artifact delivery pipeline — the system that connects a code change to a running production container, with full traceability and immutability guarantees.

**What this phase covers:**
- How a Git commit or PR merge triggers the CI pipeline automatically via GitHub Actions.
- How the CI pipeline builds Docker images, runs tests, and tags images with Git commit SHAs for traceability.
- How image tags (human-readable labels) and image digests (immutable SHA-256 hashes) work together to version artifacts.
- How images are pushed to Docker Hub as the central distribution point.
- How Kubernetes pulls the specified image and performs a rolling update with zero downtime.

**Key principle:** *Build once, deploy everywhere.* The exact same Docker image that passes CI tests is what runs in production — no rebuilding, no environment drift, no surprises.

- *Docs:* [Artifact Flow: Source → Cluster](docs/Artifact-Flow-Source-To-Cluster.md), [CI/CD Pipeline Plan](docs/CICD-Pipeline-Plan.md).

#### 📊 End-to-End Artifact Flow Diagram

![Artifact Flow Diagram](docs/artifact-flow-diagram.png)

```
Git Commit / PR Merge
        ↓
CI Pipeline (Build + Test)
        ↓
Docker Image (Tagged with Git SHA)
        ↓
Container Registry (Docker Hub)
        ↓
Kubernetes Deployment (Rolling Update)
        ↓
Running Containers in Cluster
```

#### 💡 Reflection: Why Immutable Artifacts Matter

Deploying immutable Docker images instead of raw source code is fundamentally safer because it eliminates an entire class of deployment failures rooted in environmental inconsistency.

- **Reliability:** The image that passed CI is the exact same binary that runs in production — no build-step variance.
- **Rollbacks:** Rolling back is instantaneous — point Kubernetes to the previous image tag. No rebuilding needed.
- **Traceability:** Every image is tied to a Git commit SHA. From a running pod, you can trace back to the exact line of code that produced it.
- **Consistency:** The same image runs identically across dev, staging, and production — eliminating "works on my machine" problems.

> For the full reflection and a detailed production bug case study, see [Artifact Flow Documentation](docs/Artifact-Flow-Source-To-Cluster.md#8-reflection--why-immutable-artifacts-are-safer).

### Phase 5: Kubernetes Workload Lifecycle ✅ *(NEW)*
We documented the complete internal lifecycle of how Kubernetes manages application workloads — from a Deployment definition to running, self-healing Pods.

**What this phase covers:**
- How a **Deployment** defines desired state, creates a **ReplicaSet**, which in turn creates and manages **Pods**.
- How the **kube-scheduler** assigns Pods to Nodes based on resource availability.
- How Kubernetes **continuously reconciles** desired state vs. current state — automatically restarting crashed Pods and rescheduling on node failure.
- How **rolling updates** work: new Pods are created with the new image while old Pods are gradually terminated, maintaining availability throughout.
- How **health probes** (Liveness, Readiness, Startup) influence Pod lifecycle and protect traffic from reaching unhealthy containers.
- How **CPU/memory requests and limits** affect scheduling decisions and runtime behavior.
- Common **Pod failure states**: `Pending`, `CrashLoopBackOff`, `ImagePullBackOff`, `OOMKilled` — causes, meaning, and automatic Kubernetes responses.

**Key principle:** *Kubernetes manages desired state, not application correctness.* The platform guarantees that the right number of containers are always running — but it's the application's responsibility to be correct. This boundary is what makes self-healing automation possible at scale.

- *Docs:* [K8s Workload Lifecycle](docs/Kubernetes-Workload-Lifecycle.md).

#### 📊 Kubernetes Lifecycle Diagram

![Kubernetes Lifecycle Diagram](docs/k8s-lifecycle-diagram.png)

```
Deployment (desired state)
       ↓
  ReplicaSet
       ↓
  Pod Creation
       ↓
   Scheduling
       ↓
 Container Start
       ↓
 Health Checks
       ↓
Running / Restart / Reschedule
```

#### 💡 Reflection: Desired State vs. Application Correctness

Kubernetes focuses on maintaining desired state rather than guaranteeing application correctness because the platform's responsibility is infrastructure automation — not business logic. Self-healing behavior (restarting crashed pods, rescheduling on node failure) is only possible because it is declarative and stateless from the platform's perspective. If Kubernetes tried to validate whether your application was *correct*, it would need to understand your domain — an impossible and unscalable boundary. Instead, it trusts health probes (defined by the developer) as the signal for correctness, and automates all recovery actions from there. This clean separation between platform responsibility and application responsibility is what makes Kubernetes reliable at scale.

> For full details including rolling update mechanics, probe configurations, and the failure case study, see [Kubernetes Workload Lifecycle](docs/Kubernetes-Workload-Lifecycle.md).

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
│   ├── Kubernetes-Workload-Lifecycle.md     ← NEW: Full lifecycle explanation
│   ├── k8s-lifecycle-diagram.png            ← NEW: Lifecycle diagram
│   ├── Artifact-Flow-Source-To-Cluster.md
│   ├── artifact-flow-diagram.png
│   ├── CICD-Pipeline-Plan.md
│   ├── Container-Registry-Tagging-And-Distribution.md
│   ├── Docker-Architecture-Images-Layers-Containers.md
│   ├── Kubernetes-Cluster-Architecture.md
│   └── ...more concept docs
└── README.md
```
