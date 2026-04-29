# Docker Architecture — Images, Layers, and Containers

> Docker is a platform, not a command. Understanding its architecture is what separates debugging from guessing.

---

## Docker Is a Platform, Not Just a CLI

When people say "Docker," they usually mean the `docker` command. But Docker is actually a platform made up of several components working together:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Docker Platform                         │
│                                                                │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐   │
│  │  Docker CLI  │──▶│ Docker Daemon│──▶│ Container Runtime│   │
│  │  (client)    │   │  (dockerd)   │   │  (containerd +   │   │
│  │              │   │              │   │   runc)           │   │
│  └──────────────┘   └──────┬───────┘   └──────────────────┘   │
│                            │                                   │
│                     ┌──────▼───────┐                           │
│                     │   Registry   │                           │
│                     │ (Docker Hub, │                           │
│                     │  GHCR, ECR)  │                           │
│                     └──────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
```

| Component | What It Does |
|---|---|
| **Docker CLI** | The command-line tool you interact with (`docker build`, `docker run`, etc.) |
| **Docker Daemon (dockerd)** | Background service that manages images, containers, networks, and volumes |
| **containerd** | Lower-level container runtime that actually manages container lifecycle |
| **runc** | The OCI-compliant runtime that creates and runs containers using Linux kernel features |
| **Registry** | Remote storage for images (Docker Hub, GitHub Container Registry, AWS ECR) |

When you run `docker build .`, you're talking to the **CLI**, which sends the request to the **daemon**, which reads your **Dockerfile**, builds **layers**, assembles an **image**, and optionally pushes it to a **registry**. When you run `docker run`, the daemon tells **containerd** to create a container via **runc**.

Understanding this separation matters because:
- Build issues → Dockerfile or daemon problem
- Runtime crashes → Container runtime or application problem
- Pull failures → Registry or network problem

---

## Docker Images — Immutable Build Artifacts

### What Is an Image?

A Docker image is a **read-only, immutable blueprint** that contains everything needed to run an application:

- Base operating system files (e.g., Alpine Linux, Debian)
- Runtime (e.g., Node.js 18, Python 3.11)
- Application code
- Dependencies (e.g., `node_modules/`)
- Configuration and metadata (exposed ports, startup command)

**Immutable** means: once an image is built, it never changes. You don't patch an image — you build a new one. This is fundamental to reliable delivery.

```
Think of an image like a compiled binary:

Source Code  ──compile──▶  Binary (immutable)  ──run──▶  Process
Dockerfile   ──build───▶  Image  (immutable)   ──run──▶  Container
```

### Why Immutability Matters

| Benefit | Explanation |
|---|---|
| **Reproducibility** | The image that passed tests is the exact image that deploys. No surprises. |
| **Versioning** | Images are tagged (`v1.0.0`, `latest`, `sha-abc123`). You can always roll back. |
| **Caching** | Unchanged layers are reused across builds — faster CI, less bandwidth. |
| **Trust** | A signed image guarantees nothing was modified between build and deploy. |

### Image Identification

Every image has multiple identifiers:

```bash
# By name and tag
aerostore-api:1.0.0
aerostore-api:latest

# By digest (content-addressable hash — truly unique)
aerostore-api@sha256:3e7a8f...

# Full registry path
ghcr.io/kalviumcommunity/aerostore-api:1.0.0
```

**Best practice**: Never rely on `:latest` in production. Always use specific version tags or digests. `:latest` is a moving target — it points to whatever was pushed last.

---

## Understanding Layers — The Architecture Behind Images

### What Are Layers?

An image is not a single blob. It's a **stack of read-only layers**, where each layer represents a filesystem change produced by one instruction in the Dockerfile.

```dockerfile
FROM node:18-alpine          # Layer 1: Base OS + Node.js (~50 MB)
WORKDIR /app                 # Layer 2: Creates /app directory (~0 KB)
COPY package*.json ./        # Layer 3: Adds package files (~2 KB)
RUN npm ci --production      # Layer 4: Installs dependencies (~80 MB)
COPY . .                     # Layer 5: Adds application code (~500 KB)
CMD ["node", "server.js"]    # Metadata only (no new layer)
```

Visually:

```
┌──────────────────────────────────────┐
│  Layer 5: Application code (COPY .) │  ← Changes most often
├──────────────────────────────────────┤
│  Layer 4: node_modules (RUN npm ci) │  ← Changes when deps change
├──────────────────────────────────────┤
│  Layer 3: package.json (COPY)       │  ← Changes when deps change
├──────────────────────────────────────┤
│  Layer 2: WORKDIR /app              │  ← Almost never changes
├──────────────────────────────────────┤
│  Layer 1: node:18-alpine base       │  ← Changes on base image update
└──────────────────────────────────────┘
```

### How Layer Caching Works

Docker caches each layer. On rebuild, it checks: **"Has this instruction or its inputs changed?"**

- If **no** → Reuse the cached layer (fast!)
- If **yes** → Rebuild this layer AND all layers after it (cache invalidation)

This is why **instruction order matters enormously**:

```dockerfile
# ❌ BAD: Any code change invalidates npm install cache
COPY . .                     # Layer: all files (changes every commit)
RUN npm ci --production      # Layer: rebuilds EVERY TIME (slow!)

# ✅ GOOD: npm install only reruns when package.json changes
COPY package*.json ./        # Layer: only package files
RUN npm ci --production      # Layer: cached unless deps change!
COPY . .                     # Layer: only app code changes
```

**Impact on real builds:**

| Approach | Build time (code change only) | Build time (dep change) |
|---|---|---|
| ❌ Bad ordering | ~2-3 minutes (reinstalls deps) | ~2-3 minutes |
| ✅ Good ordering | ~5-10 seconds (deps cached) | ~2-3 minutes |

### What Makes Layers Grow

Every `RUN` instruction creates a layer that captures filesystem changes. This means:

```dockerfile
# ❌ BAD: Downloads stay in the layer even after deletion
RUN apt-get update
RUN apt-get install -y build-essential
RUN make && make install
RUN apt-get remove -y build-essential    # Files still in previous layers!
RUN rm -rf /var/lib/apt/lists/*          # Same — previous layers are frozen

# ✅ GOOD: Single layer, cleanup happens in the same step
RUN apt-get update && \
    apt-get install -y build-essential && \
    make && make install && \
    apt-get remove -y build-essential && \
    rm -rf /var/lib/apt/lists/*
```

**Key insight**: Deleting a file in a later layer doesn't reduce image size. The file still exists in the earlier layer. Layers are additive.

---

## Containers — Runtime Instances of Images

### Image vs Container

This is the most important distinction in Docker:

```
┌──────────────────────────────────────────────────────┐
│                     IMAGE                            │
│            (read-only, immutable)                    │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │  Layer 5: App code                             │  │
│  ├────────────────────────────────────────────────┤  │
│  │  Layer 4: Dependencies                         │  │
│  ├────────────────────────────────────────────────┤  │
│  │  Layer 3: Package manifest                     │  │
│  ├────────────────────────────────────────────────┤  │
│  │  Layer 2: Workdir setup                        │  │
│  ├────────────────────────────────────────────────┤  │
│  │  Layer 1: Base OS + Runtime                    │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
                         │
                    docker run
                         │
              ┌──────────▼──────────┐
              │     CONTAINER       │
              │  (running instance) │
              │                     │
              │  ┌───────────────┐  │
              │  │ Writable      │  │  ← Runtime changes go here
              │  │ Layer         │  │    (logs, temp files, state)
              │  ├───────────────┤  │
              │  │ Image layers  │  │  ← Read-only, shared
              │  │ (read-only)   │  │
              │  └───────────────┘  │
              └─────────────────────┘
```

| Aspect | Image | Container |
|---|---|---|
| **State** | Static, immutable | Running, has writable layer |
| **Persistence** | Stored in registry, survives forever | Ephemeral — stops, writable layer discarded |
| **Analogy** | Class definition | Instance of the class |
| **Created by** | `docker build` | `docker run` or `docker create` |
| **Count** | One image | Many containers from same image |

### The Writable Layer Trap

The most common mistake in Docker:

```bash
# You SSH into a container and fix a config file
docker exec -it my-app /bin/sh
vi /app/config.json    # ← This change is in the WRITABLE LAYER

# Container restarts...
docker restart my-app
# Change is gone? No — restart preserves writable layer

# Container is removed and recreated...
docker rm my-app
docker run ... my-image
# Change IS gone — writable layer was discarded with the container
```

**Rule**: Never rely on runtime modifications to containers. If a change needs to persist:
- **Build-time change** → Update the Dockerfile and rebuild the image
- **Configuration** → Use environment variables or mounted config files
- **Data** → Use Docker volumes

---

## The Complete Image-Container Lifecycle

```
 Dockerfile          docker build         Registry           docker run
┌──────────┐       ┌──────────────┐     ┌──────────┐      ┌───────────────┐
│ FROM     │──────▶│   IMAGE      │────▶│  STORED  │─────▶│  CONTAINER    │
│ COPY     │ build │  (immutable) │push │  IMAGE   │ pull │  (running)    │
│ RUN      │       │              │     │          │      │               │
│ CMD      │       └──────────────┘     └──────────┘      └───────┬───────┘
└──────────┘              │                                       │
                          │                              ┌────────▼────────┐
                     Can create                          │   Container     │
                     multiple                            │   Lifecycle:    │
                     containers                          │                 │
                          │                              │  created        │
                          ├────▶ Container A             │  running  ←─┐   │
                          ├────▶ Container B             │  paused     │   │
                          └────▶ Container C             │  stopped ───┘   │
                                                         │  removed        │
                                                         └─────────────────┘
```

### Lifecycle States

| State | What's Happening | Common Trigger |
|---|---|---|
| **Created** | Container exists but process hasn't started | `docker create` |
| **Running** | Main process (PID 1) is active | `docker start` / `docker run` |
| **Paused** | Process frozen (SIGSTOP) | `docker pause` |
| **Stopped** | Process exited (gracefully or crashed) | `docker stop` / app crash |
| **Removed** | Container and writable layer deleted | `docker rm` |

### Where Changes Belong

| Change Type | Where It Belongs | Example |
|---|---|---|
| Install a dependency | **Image** (Dockerfile `RUN`) | `RUN npm ci` |
| Set a default port | **Image** (Dockerfile `EXPOSE`) | `EXPOSE 3001` |
| Define startup command | **Image** (Dockerfile `CMD`) | `CMD ["node", "server.js"]` |
| Database connection string | **Container** (env variable) | `docker run -e DB_URL=...` |
| API keys / secrets | **Container** (env / mounted file) | `docker run -v ./secrets:/run/secrets` |
| Application logs | **Container** (volume) | `docker run -v logs:/app/logs` |
| Uploaded user files | **Container** (volume) | `docker run -v uploads:/app/uploads` |

---

## How This Applies to AeroStore

Here's how Docker architecture maps to this project:

### Backend Service (Express API)

```
Dockerfile (instructions)
    │
    ▼
aerostore-api:1.0.0 (image = artifact)
    │
    ├──▶ Container on developer laptop    (docker run)
    ├──▶ Container in CI test runner      (GitHub Actions)
    ├──▶ Container in staging             (same image!)
    └──▶ Container in production          (same image!)
```

The **image** stays the same. The **container's** behavior changes via environment variables:

```bash
# Development
docker run -e NODE_ENV=development -e PORT=3001 aerostore-api:1.0.0

# Production
docker run -e NODE_ENV=production -e PORT=80 aerostore-api:1.0.0
```

Same image. Different runtime behavior. This is the power of separating build-time from runtime.

### Layer Strategy for AeroStore

```dockerfile
# Layers ordered from least-changing to most-changing:

FROM node:18-alpine              # ① Base: changes rarely
WORKDIR /app                     # ② Setup: never changes
COPY package*.json ./            # ③ Deps manifest: changes occasionally
RUN npm ci --production          # ④ Install: only rebuilds if ③ changes
COPY . .                         # ⑤ App code: changes every commit
EXPOSE 3001                      # Metadata
CMD ["node", "server.js"]        # Metadata
```

On a typical code-only change, layers ①–④ are cached. Only layer ⑤ rebuilds. **Build time: seconds instead of minutes.**

---

## Performance and Debugging — Thinking in Layers

### Why Your Image Is 1 GB

```bash
# Check image size
docker images aerostore-api
# REPOSITORY      TAG     SIZE
# aerostore-api   1.0.0   1.2GB   ← Why??

# Inspect layers
docker history aerostore-api:1.0.0
# IMAGE       CREATED BY                              SIZE
# abc123      COPY . .                                800MB  ← Copying too much!
# def456      RUN npm ci                              300MB
# ...

# Fix: Add .dockerignore
echo "node_modules" >> .dockerignore
echo ".git" >> .dockerignore
echo "*.md" >> .dockerignore
```

### Why Your Build Is Slow

```bash
# Every build takes 3 minutes even for a one-line code change

# Check cache usage during build
docker build . 2>&1 | grep -E "CACHED|RUN"
# Step 3/6: COPY . .           ← Not cached (code changed)
# Step 4/6: RUN npm ci          ← Not cached (layer after invalidated layer)

# Fix: Reorder instructions (copy package.json before full COPY)
```

### Why Your Container Keeps Crashing

```bash
# Container exits immediately after starting
docker logs my-container
# Error: Cannot find module '/app/server.js'

# Debug: Check what's actually in the image
docker run --rm -it aerostore-api:1.0.0 ls -la /app/
# → server.js is missing because .dockerignore excluded it
# or the COPY instruction used the wrong path
```

---

## Key Takeaways

1. **Docker is a platform** with CLI, daemon, runtime, and registry — know which layer is failing
2. **Images are immutable artifacts** — build once, run anywhere, version with tags
3. **Layers are the architecture** — instruction order affects cache, build time, and image size
4. **Containers are ephemeral instances** — don't modify them; rebuild images or use volumes
5. **Separate build-time from runtime** — code and deps in the image, config and data in the container
6. **Performance is predictable** — slow builds and large images trace directly to layer decisions

---

## What's Next

With this architectural understanding in place, the next phases will cover:

- **Dockerfile best practices** — Writing efficient, secure, production-ready Dockerfiles
- **Docker Compose** — Orchestrating multi-container setups (frontend + backend)
- **Container registries** — Pushing, pulling, and versioning images
- **Kubernetes** — Running containers at scale with orchestration

---

*Part of the AeroStore DevOps learning path — understanding Docker architecture before writing Dockerfiles.*
