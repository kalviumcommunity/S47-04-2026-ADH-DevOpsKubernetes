# CI Pipeline — Build, Test, and Docker Image Creation

> This document explains how the AeroStore CI pipeline enforces a strict build → test → Docker image gate sequence, why tests must pass before Docker images can be created, and what happens when any stage fails.

---

## Pipeline Flow

```
push / pull_request
       │
       ├── [STAGE 1a] backend-build ──────────────────────────────┐
       │   npm ci → node --check → validate products.json         │
       │         ↓ (only if build passes)                         │
       ├── [STAGE 1b] backend-test ────────────────────────────► [STAGE 2]
       │   npm test → smoke test (HTTP /api/health)               │
       │                                                           │ docker-build
       └── [STAGE 1c] frontend-build ──────────────────────────► [STAGE 2]
           npm ci → vite build → verify dist/index.html           │
                                                                   │
                          [STAGE 2] docker-build ─────────────────┘
                          (runs ONLY if stages 1b AND 1c both pass)
                          builds backend + frontend Docker images
```

---

## What Each Stage Validates

### Stage 1a — backend-build

| Step | Command | Catches |
|---|---|---|
| Install | `npm ci` | Missing deps, lockfile drift, version conflicts |
| Syntax check | `node --check index.js` | Syntax errors, invalid require() calls |
| Data validation | `node -e "require('./products.json')"` | Malformed JSON that crashes server on startup |

### Stage 1b — backend-test

| Step | Command | Catches |
|---|---|---|
| Install | `npm ci` | Same as 1a (clean runner) |
| Test suite | `npm test` | Data integrity failures, module loading errors, business logic bugs |
| Smoke test | HTTP curl to `/api/health` | Runtime errors, port binding failures, middleware crashes |

### Stage 1c — frontend-build

| Step | Command | Catches |
|---|---|---|
| Install | `npm ci` | Missing packages, version drift |
| Build | `npm run build` | JSX errors, missing imports, invalid component references |
| Artifact check | `ls dist/index.html` | Silent build failures (exits 0 but produces nothing) |

### Stage 2 — docker-build (gated)

```yaml
needs: [backend-test, frontend-build]   # BOTH must pass
```

| Step | What it does |
|---|---|
| Build backend image | Runs `docker build ./backend` — validates Dockerfile |
| Build frontend image | Runs `docker build ./frontend` — validates Dockerfile |
| push: false | Validation only — registry push is a CD responsibility |

---

## Failure Behavior

| What fails | What is skipped | Result |
|---|---|---|
| `npm ci` in backend-build | backend-test, docker-build | No image created |
| `node --check` in backend-build | backend-test, docker-build | No image created |
| `npm test` in backend-test | docker-build | No image created |
| Smoke test in backend-test | docker-build | No image created |
| `vite build` in frontend-build | docker-build | No image created |
| Either Docker build | Pipeline fails | Dockerfile error flagged |

**A broken test produces no Docker image.** This is enforced structurally by the `needs:` dependency — GitHub Actions will not start `docker-build` if any upstream job returned a non-zero exit code.

---

## Why Tests Must Gate Docker Image Creation

Docker images are deployable artifacts. Once a Docker image exists and is tagged, downstream systems (staging environments, production deployment pipelines, other developers' local clusters) can pull and run it. If a broken image reaches a downstream system:

1. **Staging breaks** — the next automated deployment fails, blocking the team
2. **Other developers pull a bad image** — their local testing is now unreliable
3. **In production** — users are affected; rollback becomes necessary

By enforcing `needs: [backend-test]` on `docker-build`, the pipeline guarantees: **every Docker image that gets built was produced from code that passed all tests.** There is no exception path. You cannot manually skip the test job and let docker-build proceed — the dependency is structural, not advisory.

---

## The Test Suite

```
backend/tests/api.test.js
```

Uses Node.js built-in `node:test` — no additional test framework dependency.

### Test Suites

**Suite 1: products.json data integrity**
- Is a non-empty array
- Every product has all required fields (id, name, price, category, stock)
- All IDs are unique positive integers
- All prices are positive numbers
- All stock values are non-negative integers

**Suite 2: Module load validation**
- `express` and `cors` are installed and importable
- `products.json` is valid JSON
- PORT env variable defaults to 3001
- PORT env variable is respected when set

**Suite 3: Business logic**
- At least one Electronics category item exists
- Total product count is in the expected range (10–100)
- No product has an unreasonably high price (> 10,000)

---

## npm ci vs npm install in CI

```yaml
- run: npm ci   # Always, never npm install
```

`npm ci` (clean install) is required in CI because:
- Reads `package-lock.json` exactly — no version drift between runs
- Fails if `package-lock.json` is inconsistent with `package.json`
- Deletes `node_modules` before installing — guaranteed clean state
- Is faster in CI because it doesn't resolve ranges

`npm install` would silently update the lockfile and install different versions of packages on different runs — undermining reproducibility.
