# CI/CD Pipeline — AeroStore E-Commerce Project

## What Is This?

This document outlines our CI/CD (Continuous Integration / Continuous Deployment) strategy for the AeroStore e-commerce application. AeroStore is a full-stack app with a **React frontend** and a **Node.js/Express backend** serving mock product data. The application itself is intentionally minimal — the real focus of this project is building a production-grade DevOps delivery pipeline around it.

Our goal is to automate the entire journey from a code commit to a running, healthy deployment inside a Kubernetes cluster, with zero manual steps in between.

---

## What We Are Going to Do

We will build a **GitHub Actions CI/CD pipeline** that automates the following stages:

### CI (Continuous Integration) — Triggered on every Push / Pull Request
1. **Checkout** — Pull the latest source code from the repository.
2. **Install Dependencies** — Run `npm install` for both `backend/` and `frontend/`.
3. **Build** — Build the React frontend production bundle and verify the backend starts cleanly.
4. **Docker Build** — Build Docker images for both the backend and frontend services.
5. **Tag** — Tag each image with the Git commit SHA for full traceability (e.g., `aerostore-backend:commit-9f3a1c2`).
6. **Push to Registry** — Push the tagged images to Docker Hub.

### CD (Continuous Deployment) — Triggered on merge to `main`
1. **Pull Pre-Built Image** — Reference the exact image artifact produced by CI.
2. **Update Kubernetes Manifests** — Point the Deployment manifests to the new image tag.
3. **Apply to Cluster** — Deploy the updated manifests to the Kubernetes cluster using `kubectl apply`.
4. **Verify Health** — Confirm pods are running and health checks pass.

---

## Why We Are Doing This

### The Problem (Without CI/CD)
- Deployments are manual, slow, and error-prone.
- "Works on my machine" issues cause production failures.
- No traceability — you can't tell which code is running in production.
- Rollbacks require rebuilding and redeploying from scratch.
- Broken code can silently reach production if no one remembers to test.

### What CI/CD Solves
| Problem | CI/CD Solution |
|---|---|
| Manual deployments | Fully automated pipeline on every push |
| Environment inconsistencies | Docker containers ensure identical environments everywhere |
| No traceability | Every image is tagged with its Git commit SHA |
| Risky rollbacks | Rolling back = pointing K8s to a previous, immutable image |
| Broken code reaching production | CI fails fast — broken code never gets deployed |

### DevOps Principles We Follow
- **Automation over manual work** — No CLI commands needed after `git push`.
- **Small, traceable changes** — Each PR produces a single, versioned artifact.
- **Incremental delivery** — We ship small changes frequently, not big risky releases.
- **Feedback loops** — CI tells you within minutes if your code is safe to merge.

---

## How We Will Implement It

### Pipeline Architecture

```
Developer pushes code
        ↓
GitHub Actions CI Workflow triggers
        ↓
Install → Build → Test → Docker Build → Tag → Push to Registry
        ↓
GitHub Actions CD Workflow triggers (on main merge)
        ↓
Update K8s Deployment → Apply to Cluster → Verify Health
        ↓
Application live with zero downtime (Rolling Update)
```

### Technology Choices

| Component | Tool | Why |
|---|---|---|
| Source Control | GitHub | Industry standard, integrates with Actions |
| CI/CD Engine | GitHub Actions | Native to our repo, free tier available, YAML-based |
| Containerization | Docker | Packages app + runtime into immutable images |
| Container Registry | Docker Hub | Free tier, widely supported |
| Orchestration | Kubernetes | Self-healing, rolling updates, replica management |
| Manifests | Raw YAML (Deployment + Service) | Simple, transparent, easy to learn |

### File Structure (Planned)

```
.github/
  workflows/
    ci.yml          ← Build, test, docker build & push
    cd.yml          ← Deploy to Kubernetes cluster
k8s/
  backend-deployment.yaml
  backend-service.yaml
  frontend-deployment.yaml
  frontend-service.yaml
backend/
  Dockerfile
frontend/
  Dockerfile
```

### Pipeline Stages Breakdown

| Stage | Runs When | Purpose | Failure = |
|---|---|---|---|
| Install | Every push/PR | Get dependencies | Broken package.json |
| Build | Every push/PR | Compile frontend, validate backend | Code error |
| Docker Build | Every push/PR | Package into container | Dockerfile issue |
| Push to Registry | On main merge | Store immutable artifact | Registry auth issue |
| Deploy to K8s | On main merge | Update live system | Manifest or cluster issue |
| Health Check | After deploy | Verify pods are healthy | App crash or probe failure |

---

## Summary

This is not just about writing a YAML file. It's about building a **repeatable, traceable, automated delivery system** where every code change flows through controlled stages before reaching production. By the end of this pipeline implementation, a `git push` will be the only manual action needed — everything else happens automatically.
