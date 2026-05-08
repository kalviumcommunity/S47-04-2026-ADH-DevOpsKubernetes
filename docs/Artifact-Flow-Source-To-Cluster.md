# Artifact Flow — From Source Code to Running Cluster

> **Updated after AI review:** This version includes clarity and correctness improvements suggested by AI — specifically around image digest precision, `imagePullPolicy` behavior, security scanning in the CI stage, and expanded rollback verification steps.

> This document explains the complete journey of a code change — from a developer's Git commit to a live, running container inside a Kubernetes cluster. It covers every stage of the CI/CD pipeline, how Docker images are built and versioned, and why immutable artifacts are the foundation of reliable DevOps systems.

---

## Table of Contents

1. [Overview — The Full Artifact Journey](#1-overview--the-full-artifact-journey)
2. [Stage 1: Git Commit / PR Merge — Triggering the Pipeline](#2-stage-1-git-commit--pr-merge--triggering-the-pipeline)
3. [Stage 2: CI Pipeline — Building the Artifact](#3-stage-2-ci-pipeline--building-the-artifact)
4. [Stage 3: Docker Image — Tags and Digests](#4-stage-3-docker-image--tags-and-digests)
5. [Stage 4: Container Registry — Storing the Artifact](#5-stage-4-container-registry--storing-the-artifact)
6. [Stage 5: Kubernetes Deployment — Pulling and Running the Image](#6-stage-5-kubernetes-deployment--pulling-and-running-the-image)
7. [End-to-End Artifact Flow Diagram](#7-end-to-end-artifact-flow-diagram)
8. [Reflection — Why Immutable Artifacts Are Safer](#8-reflection--why-immutable-artifacts-are-safer)
9. [Case Study — Debugging a Production Bug](#9-case-study--debugging-a-production-bug)

---

## 1. Overview — The Full Artifact Journey

In modern DevOps, code never goes directly from a developer's laptop to production. Instead, it travels through a controlled, automated pipeline that transforms it into an **immutable artifact** — a Docker image — which is then stored, versioned, and deployed. This decoupling is what makes modern systems reliable, reproducible, and auditable.

Here is the high-level flow:

```
Source Code (Git)  →  CI Pipeline  →  Docker Image  →  Container Registry  →  Kubernetes Cluster  →  Running Pods
```

Each stage adds a layer of confidence: code is tested, packaged, versioned, stored centrally, and deployed declaratively. If any stage fails, the pipeline halts and production remains untouched.

---

## 2. Stage 1: Git Commit / PR Merge — Triggering the Pipeline

### How It Works

The CI/CD pipeline begins when a developer interacts with the Git repository. There are two primary triggers:

1. **Pull Request (PR) Creation / Update:** When a developer opens a PR or pushes new commits to an existing PR branch, the CI pipeline runs automatically. This provides early feedback — tests run, images build, and the team can verify that the change is safe *before* it reaches the main branch.

2. **Merge to Main:** When a PR is approved and merged into the `main` branch, the CD (Continuous Deployment) pipeline triggers. This is the signal that the change has been reviewed, approved, and is ready for production.

### Why This Matters

- **Automation from the start:** No human needs to remember to "run the build." The act of pushing code is the trigger.
- **Gate mechanism:** The CI pipeline acts as a quality gate. If tests fail on a PR, the merge is blocked. Broken code never reaches `main`.
- **Traceability:** Every pipeline run is tied to a specific Git commit SHA, creating an unbreakable chain from code change to deployed artifact.

### In Our AeroStore Project

We use **GitHub Actions** as our CI/CD engine. Our workflow files live in `.github/workflows/` and are configured to trigger on:

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
```

This means: *"Run CI on every PR targeting main, and run CD when code is actually merged into main."*

---

## 3. Stage 2: CI Pipeline — Building the Artifact

### What Happens Inside CI

Once triggered, the CI pipeline executes a series of automated steps:

| Step | What It Does | Why It Matters |
|---|---|---|
| **Checkout** | Pulls the exact commit from the repository | Ensures we're building the right code |
| **Install Dependencies** | Runs `npm install` for backend and frontend | Gets all required packages |
| **Build** | Compiles the React frontend, verifies the backend | Catches build errors early |
| **Test** | Runs unit/integration tests | Prevents broken logic from proceeding |
| **Docker Build** | Runs `docker build` using the project's Dockerfiles | Packages the app + runtime into a container image |
| **Security Scan** *(recommended)* | Scans the image for known CVEs (e.g., using Trivy or Snyk) | Prevents deploying images with critical vulnerabilities |
| **Tag** | Assigns a meaningful tag (e.g., Git commit SHA) | Links the image to the exact source code |
| **Push to Registry** | Uploads the tagged image to Docker Hub | Makes the artifact available for deployment |

### The Key Principle: Build Once, Deploy Everywhere

The CI pipeline produces a single Docker image from a specific Git commit. This *exact same image* is what gets deployed to staging, testing, and production. We never rebuild for different environments — we build once and promote the same artifact. This eliminates "works on my machine" problems entirely.

---

## 4. Stage 3: Docker Image — Tags and Digests

### What Is an Image Tag?

An **image tag** is a human-readable label assigned to a Docker image. It's like a Git branch name — a mutable pointer to a specific image version.

```
kalviaki0/devops-backend:v1.0
kalviaki0/devops-backend:commit-9f3a1c2
kalviaki0/devops-backend:latest
```

Tags are **mutable** — you can push a new image with the same tag, and the old image gets de-referenced. This is why `latest` is dangerous in production: it changes with every push.

### What Is an Image Digest?

An **image digest** is a SHA-256 hash of the image's **manifest** — the JSON document that describes the image's layers and configuration. Unlike tags, digests are **immutable** and **content-addressable**: they are computed from the image content itself, so if even one byte changes in any layer, the digest changes. This makes digests the most reliable way to reference a specific image build.

```
kalviaki0/devops-backend@sha256:a3ed95caeb02ffe68cdd9fd84406680ae93d633cb16422d00e8a7c22955b46d4
```

> **Note:** You can retrieve the digest of any image using `docker inspect --format='{{index .RepoDigests 0}}' <image>` or by checking the registry's web UI after pushing.

| Property | Tag | Digest |
|---|---|---|
| **Format** | Human-readable string | SHA-256 hash |
| **Mutable?** | Yes — can be reassigned | No — content-addressable |
| **Use case** | Development, convenience | Production, auditing |
| **Example** | `:v1.0`, `:latest` | `@sha256:a3ed95c...` |

### Our Tagging Strategy

In the AeroStore CI pipeline, every image is tagged with:

1. **Git Commit SHA** (`commit-9f3a1c2`) — Provides exact traceability to the source code
2. **Semantic Version** (`v1.0`, `v1.1`) — Provides human-readable release identification
3. **`latest`** — Convenience pointer for development environments only

For production deployments, we reference images by their **commit SHA tag** or **digest**, never by `latest`.

---

## 5. Stage 4: Container Registry — Storing the Artifact

### What Is a Container Registry?

A container registry is a centralized storage service for Docker images. It acts as the **single source of truth** for all versioned artifacts. Think of it as "npm for containers" — a place where built images are published and from which any authorized system can pull them.

### Why Registries Are Required

1. **Decoupling build from deploy:** The CI server builds the image; the Kubernetes cluster pulls it. These two systems never communicate directly — the registry is the handoff point.

2. **Distribution:** Multiple environments (dev, staging, production) can all pull the same verified image from one central location.

3. **Version history:** Every image push is recorded. You can see exactly which versions exist, when they were pushed, and their digests.

4. **Rollback capability:** Because previous image versions are preserved in the registry, rolling back is as simple as pointing the deployment to an older tag.

5. **Access control:** Registries support authentication and authorization, ensuring only CI pipelines and authorized personnel can push images.

### How It Fits in the Pipeline

```
CI Pipeline                    Registry                     Kubernetes
┌──────────────┐    push      ┌──────────────┐    pull      ┌──────────────┐
│ docker build │ ───────────► │  Docker Hub  │ ◄─────────── │  kubelet     │
│ docker tag   │              │              │              │  (on node)   │
│ docker push  │              │  Stores:     │              │              │
└──────────────┘              │  v1.0        │              │  Runs the    │
                              │  v1.1        │              │  container   │
                              │  commit-abc  │              └──────────────┘
                              └──────────────┘
```

### Our Registry Setup

| Detail | Value |
|---|---|
| **Registry** | Docker Hub |
| **Backend Image** | `kalviaki0/devops-backend` |
| **Frontend Image** | `kalviaki0/devops-frontend` |
| **Access** | Public (appropriate for learning; production uses private repos) |

---

## 6. Stage 5: Kubernetes Deployment — Pulling and Running the Image

### How Kubernetes Knows Which Image to Run

Kubernetes uses **declarative manifests** (YAML files) to define the desired state of the system. The Deployment manifest specifies which Docker image to run:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aerostore-backend
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: backend
          image: kalviaki0/devops-backend:commit-9f3a1c2   # ← Exact image reference
          ports:
            - containerPort: 3001
```

When you run `kubectl apply -f deployment.yaml`, Kubernetes compares the desired state (your YAML) with the current state (what's running). If the image tag has changed, Kubernetes triggers a **rolling update**.

> **Important — `imagePullPolicy` behavior:**
> - If you use a specific tag like `:commit-9f3a1c2`, Kubernetes defaults to `imagePullPolicy: IfNotPresent` — it only pulls if the image isn't already cached on the node.
> - If you use `:latest`, Kubernetes defaults to `imagePullPolicy: Always` — it pulls every time a pod starts.
> - For production, always use specific tags (commit SHA or version) and set `imagePullPolicy: IfNotPresent` to avoid unnecessary pulls and ensure deterministic deployments.

### The Pull and Run Process

1. **CD pipeline updates the manifest** — Changes the `image:` field to the new tag produced by CI.
2. **`kubectl apply`** — Sends the updated manifest to the Kubernetes API server.
3. **Scheduler assigns pods to nodes** — The control plane decides which worker nodes should run the new pods.
4. **Kubelet pulls the image** — The kubelet on each assigned node contacts the container registry and pulls the specified image.
5. **Container runtime starts the container** — The container runtime (e.g., containerd) creates and starts the container from the pulled image.
6. **Rolling update completes** — New pods come up, health checks pass, and old pods are gracefully terminated. Zero downtime.

### Why This Is Powerful

- **Declarative, not imperative:** You describe *what* you want, not *how* to get there. Kubernetes figures out the rest.
- **Self-healing:** If a pod crashes, Kubernetes automatically restarts it using the same image.
- **Rollback-ready:** `kubectl rollout undo` instantly reverts to the previous Deployment revision, which references the previous image.

---

## 7. End-to-End Artifact Flow Diagram

The diagram below visualizes the complete journey from source code to running production containers:

![End-to-End Artifact Flow Diagram](artifact-flow-diagram.png)

```
    ┌──────────────────────────────────┐
    │     Developer pushes code        │
    │     Git Commit / PR Merge        │
    └───────────────┬──────────────────┘
                    │
                    ▼
    ┌──────────────────────────────────┐
    │     CI Pipeline (GitHub Actions) │
    │  Install → Build → Test →       │
    │  Docker Build → Tag → Push      │
    └───────────────┬──────────────────┘
                    │
                    ▼
    ┌──────────────────────────────────┐
    │     Docker Image (Tagged)        │
    │  kalviaki0/devops-backend:       │
    │  commit-9f3a1c2                  │
    │  Digest: sha256:a3ed95c...       │
    └───────────────┬──────────────────┘
                    │
                    ▼
    ┌──────────────────────────────────┐
    │     Container Registry           │
    │     (Docker Hub)                 │
    │  Immutable, versioned storage    │
    └───────────────┬──────────────────┘
                    │
                    ▼
    ┌──────────────────────────────────┐
    │     Kubernetes Deployment        │
    │  kubectl apply → Rolling Update  │
    │  Image pulled by kubelet         │
    └───────────────┬──────────────────┘
                    │
                    ▼
    ┌──────────────────────────────────┐
    │     Running Pods in Cluster      │
    │  Healthy containers serving      │
    │  production traffic              │
    └──────────────────────────────────┘
```

---

## 8. Reflection — Why Immutable Artifacts Are Safer

**"Why is deploying immutable artifacts (Docker images) safer than deploying code directly?"**

Deploying immutable Docker images instead of raw source code is fundamentally safer because it eliminates an entire class of deployment failures rooted in environmental inconsistency. When you deploy code directly, the production server must install dependencies, compile assets, and configure the runtime — any of which can fail due to network issues, version drift, or missing system libraries. A Docker image, by contrast, is a **self-contained, pre-tested snapshot** that packages the application, its dependencies, and its runtime environment into a single artifact that has already been verified in CI.

**Reliability:** The image that passed all CI tests is the *exact same binary artifact* that runs in production. There is no "build step" on the production server that could introduce variance. What you tested is what you ship.

**Rollbacks:** If a deployment causes issues, rolling back with immutable images is instantaneous — you simply tell Kubernetes to use the previous image tag or digest. There's no need to rebuild, reinstall, or hope that the previous code state can be reproduced. The old image is sitting in the registry, untouched and ready.

**Traceability:** Every Docker image is tied to a specific Git commit SHA through its tag, and to its exact binary content through its digest. Given a running container, you can trace backwards to the exact line of code that produced it. This audit trail is critical for debugging, compliance, and incident response.

**Consistency across environments:** The same Docker image runs identically on a developer's laptop, in a CI runner, on a staging server, and in production. There are no environment-specific surprises because the environment *is* the image. This eliminates the classic "works on my machine" problem and ensures that what the QA team approved is exactly what customers see.

In summary, immutable artifacts turn deployments from a risky, variable process into a deterministic, auditable, and reversible operation.

---

## 9. Case Study — Debugging a Production Bug

**Scenario:** A new bug is discovered in production after a deployment.

### Step 1: Identify Which Docker Image Is Currently Running

```bash
# Get the exact image and tag running in the production deployment
kubectl get deployment aerostore-backend -o jsonpath='{.spec.template.spec.containers[0].image}'
# Output: kalviaki0/devops-backend:commit-9f3a1c2

# For even more precision, check the running pod's image digest
kubectl get pods -l app=aerostore-backend -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
# Output: docker.io/kalviaki0/devops-backend@sha256:a3ed95caeb02...
```

### Step 2: Identify Which Git Commit Produced That Image

Since our CI pipeline tags images with the Git commit SHA, the image tag itself reveals the source:

```
Image tag: commit-9f3a1c2
    ↓
Git commit: 9f3a1c2
```

```bash
# View the exact commit that produced the buggy image
git log --oneline -1 9f3a1c2
# Output: 9f3a1c2 feat: update checkout flow for new payment provider

# See what files changed in that commit
git diff 9f3a1c2^ 9f3a1c2 --stat
```

This gives you an instant, unambiguous link between the running production artifact and the exact source code change that created it.

### Step 3: Roll Back Safely

```bash
# Option A: Use Kubernetes rollout history
kubectl rollout undo deployment/aerostore-backend
# This reverts to the previous deployment revision, which references the previous image tag

# Option B: Explicitly set the image to a known-good version
kubectl set image deployment/aerostore-backend backend=kalviaki0/devops-backend:commit-7b2e4d1

# Option C: Update the manifest YAML and re-apply
# Change image: kalviaki0/devops-backend:commit-7b2e4d1
kubectl apply -f k8s/backend-deployment.yaml

# Verify the rollback
kubectl rollout status deployment/aerostore-backend
kubectl get pods -l app=aerostore-backend
```

### Why This Works

- **The registry is the source of truth:** The previous image (`commit-7b2e4d1`) still exists in Docker Hub, untouched and unchanged. We don't need to rebuild anything.
- **Kubernetes rolling update ensures zero downtime:** The rollback creates new pods with the old image before terminating the buggy pods.
- **The commit → image relationship provides full traceability:** From the running pod, we traced back to the exact code change, identified the issue, and rolled back to a verified artifact — all without touching source code or rebuilding anything.

---

## 10. Common Pitfalls to Avoid

| Pitfall | Why It's Dangerous | What to Do Instead |
|---|---|---|
| Using `:latest` tag in production | The tag is mutable — it could point to a different image tomorrow | Use commit SHA tags or digests for production manifests |
| Rebuilding images for each environment | Different builds may produce subtly different artifacts | Build once in CI, promote the same image across environments |
| Not scanning images for vulnerabilities | Known CVEs in base images can expose production | Add a security scan step (Trivy, Snyk) in your CI pipeline |
| Skipping health checks in K8s manifests | Pods with crashed apps report as "Running" | Define `livenessProbe` and `readinessProbe` in your Deployments |
| Not preserving old images in the registry | Rollback becomes impossible if old images are deleted | Set retention policies that keep at least the last N versions |

---

## Summary

The artifact-based delivery model — Source → Image → Registry → Cluster — is not just a best practice; it's the foundation of how modern, reliable software systems operate. Every stage in the pipeline adds a layer of verification, and the immutable nature of Docker images ensures that what you test is what you deploy, and what you deploy can always be traced, audited, and rolled back.
