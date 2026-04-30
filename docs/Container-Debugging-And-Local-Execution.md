# Container Debugging & Local Execution

> This document captures the process of building, running, and debugging our Docker containers locally — including the issues encountered and how they were resolved.

---

## Table of Contents

1. [Building & Running the Backend](#1-building--running-the-backend)
2. [Building & Running the Frontend](#2-building--running-the-frontend)
3. [Bug: Frontend Rendering Boilerplate Instead of App](#3-bug-frontend-rendering-boilerplate-instead-of-app)
4. [Fix: Rewire the Entry Point](#4-fix-rewire-the-entry-point)
5. [Security Fix: Base Image Upgrade](#5-security-fix-base-image-upgrade)
6. [Debugging Commands Reference](#6-debugging-commands-reference)
7. [Key Takeaways](#7-key-takeaways)

---

## 1. Building & Running the Backend

### Build
```bash
cd backend
docker build -t devops-backend .
```
Build succeeded — no issues. The `node:24-alpine` base image has Node.js pre-installed, dependencies installed cleanly via `npm ci`.

### Run
```bash
docker run -d -p 3001:3001 --name backend-app devops-backend
```

### Verify
```bash
docker ps                                  # Confirmed container running
docker logs backend-app                    # Saw "Backend server listening at http://localhost:3001"
curl http://localhost:3001/api/health       # Response: {"status":"ok"}
curl http://localhost:3001/api/products     # Response: product JSON array
```

**Result:** Backend ran without issues ✅

---

## 2. Building & Running the Frontend

### Build
```bash
cd frontend
docker build -t devops-frontend .
```
Build succeeded — Vite produced output in `/app/dist`, which was copied to nginx in the second stage.

### Run
```bash
docker run -d -p 8080:80 --name frontend-app devops-frontend
```

### Verify
Opened `http://localhost:8080` in the browser.

**Expected:** AeroStore e-commerce app with product grid, cart, and hero section.

**Actual:** Vite boilerplate page — counter button, TypeScript/Vite logos, "Get started" text, and links to Vite documentation.

**Result:** Container ran, but displayed wrong content ❌

---

## 3. Bug: Frontend Rendering Boilerplate Instead of App

### Diagnosis

Inspected the frontend source files to trace the rendering chain:

**`index.html`** (the entry point served by nginx):
```html
<div id="app"></div>
<script type="module" src="/src/main.jsx"></script>
```

**Problem:** `index.html` references `src/main.jsx`, but the only entry file was `main.ts` — a **Vite boilerplate file** that rendered a counter and logo page directly into the DOM:

```typescript
// main.ts — BOILERPLATE, not our app
document.querySelector('#app')!.innerHTML = `
  <section id="center">
    <div class="hero">
      <img src="${heroImg}" ...>         <!-- Vite logos -->
    </div>
    <h1>Get started</h1>                 <!-- Not our app! -->
    <button id="counter">...</button>    <!-- Counter demo -->
  </section>
`
```

Meanwhile, the **actual app** (`App.jsx`) — a full React e-commerce store with products, cart, and API integration — was **never imported or rendered by anything**.

### Root Cause

The project had two conflicting entry points:

| File | What it rendered | Status |
|---|---|---|
| `main.ts` + `counter.ts` + `style.css` | Vite boilerplate (counter, logos) | ❌ Active but wrong |
| `App.jsx` + `App.css` | AeroStore React app | ❌ Existed but never used |

The Vite scaffold was never cleaned up when the React app was added. Locally during development with `npm run dev`, Vite may have resolved `main.jsx` differently, masking the issue. But in the Docker container, the production build exposed the bug: the built `dist/` contained the boilerplate, not the React app.

**This is exactly the kind of bug that container debugging catches** — it worked in dev but broke in production.

---

## 4. Fix: Rewire the Entry Point

### Step 1: Created proper React entry point

**New `src/main.jsx`:**
```jsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'

ReactDOM.createRoot(document.getElementById('app')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
```

This is the standard React 18+ entry point that mounts the `<App />` component into the `#app` div.

### Step 2: Removed boilerplate files

| Deleted File | Reason |
|---|---|
| `src/main.ts` | Boilerplate entry — rendered Vite demo, not our app |
| `src/counter.ts` | Boilerplate counter logic — not part of AeroStore |
| `src/style.css` | Boilerplate styles — our app uses `App.css` |
| `src/assets/typescript.svg` | Boilerplate asset — Vite demo logo |
| `src/assets/vite.svg` | Boilerplate asset — Vite demo logo |
| `src/assets/hero.png` | Boilerplate asset — Vite demo hero image |
| `public/icons.svg` | Boilerplate asset — SVG icon sprites for Vite demo |
| `tsconfig.json` | No TypeScript files remain in the project |

### Step 3: Updated build configuration

**`package.json` changes:**
```diff
- "build": "tsc && vite build",
+ "build": "vite build",
```
Removed `tsc` (TypeScript compiler) from the build script since all files are now `.jsx`.

Also removed the `typescript` devDependency — no longer needed.

### Step 4: Rebuild and verify

```bash
docker build -t devops-frontend .
docker rm -f frontend-app
docker run -d -p 8080:80 --name frontend-app devops-frontend
```

Opened `http://localhost:8080` → **AeroStore app renders correctly** ✅

---

## 5. Security Fix: Base Image Upgrade

During `docker build`, security vulnerability warnings appeared for `node:20-alpine`.

### Action Taken

Updated both Dockerfiles:
```diff
- FROM node:20-alpine
+ FROM node:24-alpine
```

This addresses known CVEs in the Node.js 20 Alpine image while staying on a maintained LTS-compatible version.

---

## 6. Debugging Commands Reference

Commands used during this debugging session:

| Command | Purpose |
|---|---|
| `docker build -t <name> .` | Build image from Dockerfile |
| `docker run -d -p <host>:<container> --name <n> <img>` | Run container in detached mode with port mapping |
| `docker ps` | List running containers |
| `docker ps -a` | List all containers including stopped |
| `docker logs <name>` | View container stdout/stderr output |
| `docker exec -it <name> sh` | Open interactive shell inside running container |
| `docker inspect <name>` | View container metadata (ports, env, mounts) |
| `docker stop <name>` | Stop a running container |
| `docker rm -f <name>` | Force remove a container |
| `docker images` | List all local images |

### When to Use Interactive Debugging

`docker exec -it <container> sh` is useful when:
- Logs don't provide enough information
- You need to check if files exist at the expected paths
- You want to verify environment variables at runtime
- You need to test network connectivity from inside the container

It complements log-based debugging — use logs first, drop into the shell when logs aren't enough.

---

## 7. Key Takeaways

1. **A successful `docker build` ≠ a working app.** The build completed fine, but the container served the wrong content. Always verify by running the container.

2. **Container builds expose hidden bugs.** The boilerplate issue may have been masked in local dev (`npm run dev`) but surfaced in the production Docker build. This is why building and testing containers locally matters.

3. **Trace the rendering chain.** When the wrong content appears: check `index.html` → entry script → what it imports → what it renders. Follow the chain.

4. **Clean up scaffolding.** Boilerplate files from `create-vite` or similar tools should be removed once your actual app code is written. Leftover files create confusion and bugs.

5. **Keep base images updated.** Security vulnerabilities in base images (`node:20-alpine`) should be addressed by upgrading to patched versions (`node:24-alpine`).

6. **Debug locally before pushing to CI.** Every issue found locally is one less broken pipeline. The feedback loop is seconds (rebuild + rerun) instead of minutes (push → CI → fail → read logs → fix → push again).
