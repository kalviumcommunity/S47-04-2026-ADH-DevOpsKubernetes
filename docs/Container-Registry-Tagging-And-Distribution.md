# Container Registry — Tagging, Pushing & Pulling Images

> This document explains how we use Docker Hub as a container registry to store, version, and distribute our application images. It covers the why behind registries, tagging strategy, and the full push/pull workflow.

---

## Table of Contents

1. [Why Use a Container Registry](#1-why-use-a-container-registry)
2. [Public vs Private Registries](#2-public-vs-private-registries)
3. [Our Registry Setup](#3-our-registry-setup)
4. [Image Tagging Strategy](#4-image-tagging-strategy)
5. [Push Workflow](#5-push-workflow)
6. [Pull & Verify Workflow](#6-pull--verify-workflow)
7. [How This Fits Into CI/CD](#7-how-this-fits-into-cicd)
8. [Commands Reference](#8-commands-reference)
9. [Key Takeaways](#9-key-takeaways)

---

## 1. Why Use a Container Registry

When you run `docker build`, the image exists **only on your local machine**. That's fine for development, but in a real DevOps workflow:

- **CI/CD pipelines** need to pull images to deploy them
- **Staging/production servers** don't have your source code — they pull pre-built images
- **Team members** need access to the same tested image
- **Rollbacks** require access to previous image versions

A container registry solves all of this by acting as a **centralized distribution point** for images.

```
Developer Machine                    Registry                     Production
┌─────────────┐    docker push     ┌──────────┐    docker pull    ┌──────────┐
│ docker build │ ────────────────► │ Docker   │ ◄──────────────── │ K8s /    │
│ docker tag   │                   │ Hub      │                   │ Server   │
└─────────────┘                    └──────────┘                   └──────────┘
                                        ▲
                                        │ docker pull
                                   ┌──────────┐
                                   │ CI/CD    │
                                   │ Pipeline │
                                   └──────────┘
```

**Key concept:** Registries decouple **image creation** from **image execution**. You build once, push once, and any system can pull that exact image.

---

## 2. Public vs Private Registries

| Feature | Public Registry | Private Registry |
|---|---|---|
| **Access** | Anyone can pull | Restricted to authorized users |
| **Use case** | Open-source projects, learning | Internal apps, production workloads |
| **Examples** | Docker Hub (public repos), GitHub Container Registry | Docker Hub (private repos), AWS ECR, Google GCR, Azure ACR |
| **Cost** | Free | Usually paid or self-hosted |
| **CI/CD impact** | No auth needed to pull | CI runners need credentials/tokens |

**Our choice:** Docker Hub with public repositories — appropriate for a learning project. In production, you'd use private repositories with access tokens for CI/CD authentication.

---

## 3. Our Registry Setup

| Detail | Value |
|---|---|
| **Registry** | Docker Hub (`hub.docker.com`) |
| **Username** | `kalviaki0` |
| **Backend image** | `kalviaki0/devops-backend` |
| **Frontend image** | `kalviaki0/devops-frontend` |
| **Visibility** | Public |

### Authentication

```bash
docker login
# Enter username: kalviaki0
# Enter password or access token
```

**Why authenticate?** Anyone can `docker pull` from a public repo, but only authenticated owners can `docker push`. This prevents unauthorized image overwrites.

---

## 4. Image Tagging Strategy

### Tag Format

```
<registry-username>/<image-name>:<tag>
```

Example: `kalviaki0/devops-backend:v1.0`

### Tags Used

| Image | Tags | Purpose |
|---|---|---|
| `kalviaki0/devops-backend` | `v1.0`, `latest` | Versioned + convenience pointer |
| `kalviaki0/devops-frontend` | `v1.0`, `latest` | Versioned + convenience pointer |

### Why Two Tags?

**`v1.0` (version tag):**
- Immutable identifier — always points to this exact build
- Used for production deployments and rollbacks
- If `v1.1` breaks, rollback to `v1.0` instantly

**`latest` (convenience tag):**
- Floating pointer — moves to the newest build
- Useful for dev/staging environments that always want the newest version
- **Never use `latest` in production** — it's ambiguous and changes unpredictably

### Tagging Strategy in Practice

```
v1.0  ──────────────────────────────────► Always this exact build
v1.1  ──────────────────────────────────► Always this exact build
latest ─► v1.0 ─► v1.1 ─► v1.2 ──────► Moves with each new push
```

In a real CI/CD pipeline, tags often include:
- **Semantic versions:** `v1.0.0`, `v1.1.0`, `v2.0.0`
- **Git SHAs:** `abc123f` — ties image to exact commit
- **Branch names:** `main`, `staging` — ties image to environment

---

## 5. Push Workflow

### Step 1: Build Images (if not already built)
```bash
cd backend
docker build -t devops-backend .

cd ../frontend
docker build -t devops-frontend .
```

### Step 2: Tag for Registry
```bash
# Backend
docker tag devops-backend kalviaki0/devops-backend:v1.0
docker tag devops-backend kalviaki0/devops-backend:latest

# Frontend
docker tag devops-frontend kalviaki0/devops-frontend:v1.0
docker tag devops-frontend kalviaki0/devops-frontend:latest
```

**What `docker tag` does:** It doesn't copy the image — it creates an **alias** pointing to the same image layers. The image data exists once; the tag is just a label.

### Step 3: Push to Docker Hub
```bash
# Backend
docker push kalviaki0/devops-backend:v1.0
docker push kalviaki0/devops-backend:latest

# Frontend
docker push kalviaki0/devops-frontend:v1.0
docker push kalviaki0/devops-frontend:latest
```

**What happens during push:**
1. Docker checks which layers the registry already has
2. Only **new/changed layers** are uploaded (layer deduplication)
3. The tag is registered in the registry metadata

---

## 6. Pull & Verify Workflow

To prove the registry images work independently from local builds:

### Step 1: Remove Local Images
```bash
docker rmi kalviaki0/devops-backend:v1.0
docker rmi kalviaki0/devops-frontend:v1.0
```

### Step 2: Pull from Registry
```bash
docker pull kalviaki0/devops-backend:v1.0
docker pull kalviaki0/devops-frontend:v1.0
```

### Step 3: Run and Verify
```bash
# Backend
docker run -d -p 3001:3001 --name backend-test kalviaki0/devops-backend:v1.0
curl http://localhost:3001/api/health
# Expected: {"status":"ok"}

# Frontend
docker run -d -p 8080:80 --name frontend-test kalviaki0/devops-frontend:v1.0
# Open http://localhost:8080 — should show AeroStore app
```

This validates that the image in the registry is **self-contained and complete** — it doesn't depend on anything from your local machine.

---

## 7. How This Fits Into CI/CD

In a production CI/CD pipeline, the workflow looks like:

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────┐
│  Developer  │────►│  CI Server   │────►│  Registry    │────►│  Deploy  │
│  git push   │     │  docker build│     │  docker push │     │  docker  │
│             │     │  run tests   │     │  tag: v1.2   │     │  pull    │
└─────────────┘     └──────────────┘     └──────────────┘     └──────────┘
```

1. Developer pushes code to Git
2. CI server builds the image and runs tests
3. If tests pass, the image is tagged and pushed to the registry
4. Deployment system pulls the exact tagged image and runs it

**The registry is the handoff point** between "code that works" and "code that's deployed."

---

## 8. Commands Reference

| Command | What It Does |
|---|---|
| `docker login` | Authenticate with Docker Hub |
| `docker tag <source> <target>` | Create a new tag (alias) for an image |
| `docker push <image>:<tag>` | Upload image to registry |
| `docker pull <image>:<tag>` | Download image from registry |
| `docker images` | List all local images and their tags |
| `docker rmi <image>:<tag>` | Remove a local image tag |
| `docker search <term>` | Search Docker Hub for public images |
| `docker inspect <image>` | View image metadata (layers, config, etc.) |

---

## 9. Key Takeaways

1. **Registries decouple build from deploy.** You build on your machine or CI; you deploy from the registry. The two systems never need direct access to each other.

2. **Tags are your version control for images.** Without meaningful tags, you can't rollback, audit, or reproduce deployments. Always use version tags in production.

3. **`latest` is not a version.** It's a convenience pointer that moves. Use it for dev/staging, never for production deployments.

4. **Push only tested images.** In CI/CD, images are pushed to the registry only after tests pass. The registry should contain only validated artifacts.

5. **Layer deduplication saves bandwidth.** Docker only pushes/pulls layers that changed. This is why proper layer ordering in your Dockerfile (from the previous lesson) matters — it reduces both build time AND push/pull time.

6. **Authentication matters.** In production, CI/CD runners use access tokens (not passwords) to authenticate with registries. Tokens can be scoped and rotated without changing your password.
