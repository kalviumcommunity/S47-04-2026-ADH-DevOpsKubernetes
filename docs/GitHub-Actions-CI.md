# GitHub Actions — Continuous Integration for AeroStore

> This document explains what Continuous Integration (CI) is, how the AeroStore GitHub Actions workflow is structured, which repository events trigger it, what each step validates, and why automated CI is essential for reliable collaborative development.

---

## Table of Contents

1. [What is Continuous Integration?](#1-what-is-continuous-integration)
2. [Workflow File Structure](#2-workflow-file-structure)
3. [Trigger Conditions](#3-trigger-conditions)
4. [CI Job Design](#4-ci-job-design)
5. [What Each Step Validates](#5-what-each-step-validates)
6. [npm ci vs npm install](#6-npm-ci-vs-npm-install)
7. [Concurrency and Cancellation](#7-concurrency-and-cancellation)
8. [Scenario: Code That Works Locally But Breaks When Merged](#8-scenario-code-that-works-locally-but-breaks-when-merged)

---

## 1. What is Continuous Integration?

Continuous Integration is the practice of automatically validating every code change against the full codebase as soon as it is pushed. The core principle is: **fail fast, fail locally, fail visibly.**

Without CI:
- Developer A pushes a change. Works locally.
- Developer B pushes a change. Works locally.
- Both changes are merged to main.
- The combination breaks. Nobody knows until manual testing — or until users report it.

With CI:
- Developer A pushes a branch. CI runs automatically in minutes.
- If the build or tests fail, the developer is notified before they open a PR.
- The PR cannot be merged if CI fails (when branch protection rules are enforced).
- Integration failures are caught at the contributor level, not the team level.

---

## 2. Workflow File Structure

```
.github/
  workflows/
    ci.yml          ← This file. GitHub detects it automatically.
```

GitHub automatically discovers all YAML files in `.github/workflows/`. No registration or setup required — the presence of the file is sufficient to activate the workflow.

```yaml
name: AeroStore CI          # Display name in the GitHub Actions tab

on:                          # Trigger conditions
  push:
    branches: ["**"]
  pull_request:
    branches: [main]

concurrency: ...             # Cancel stale runs

jobs:
  backend-ci:   ...          # Job 1: Express backend
  frontend-ci:  ...          # Job 2: Vite/React frontend
  docker-build: ...          # Job 3: Docker image build (runs after 1 and 2)
```

---

## 3. Trigger Conditions

```yaml
on:
  push:
    branches:
      - "**"        # Every branch — catches issues before a PR is even opened
  pull_request:
    branches:
      - main        # Validates every PR before it can be merged
```

### Why Both Triggers

**`push` to all branches:** Developers get CI feedback on their own branch as they work, before opening a PR. This is the fastest possible feedback loop — you don't wait until PR time to discover that your change broke the frontend build.

**`pull_request` targeting main:** This is the gate. Before anyone can click "Merge", the CI must have passed on the PR's current HEAD commit. If a developer pushes a new commit to the PR branch, the CI reruns. The green check on the merge button reflects the current state of the code, not a state from hours ago.

### What Events `pull_request` Covers

| Event | Description |
|---|---|
| `opened` | PR is created |
| `synchronize` | New commits are pushed to the PR branch |
| `reopened` | A closed PR is reopened |

---

## 4. CI Job Design

```
push / pull_request
        │
        ├── backend-ci  ──────────────────────┐
        │   (runs in parallel)                 │
        └── frontend-ci ─────────────────────►├── docker-build
                                               │   (runs only if both pass)
                                               └──
```

**Parallel jobs:** Backend and frontend CI run simultaneously. The total CI time is `max(backend_time, frontend_time)` — not their sum. This keeps CI fast.

**Job dependency:** `docker-build` uses `needs: [backend-ci, frontend-ci]`. It only starts when both upstream jobs succeed. A backend build failure prevents unnecessary Docker build compute.

---

## 5. What Each Step Validates

### Backend CI Steps

| Step | What it catches |
|---|---|
| `checkout` | Repository state at this commit |
| `setup-node` | Correct Node version for runtime compatibility |
| `npm ci` | Missing dependencies, lockfile out of sync with package.json |
| `node --check index.js` | Syntax errors, invalid `require()` calls, module not found |
| Smoke test | Server actually starts, port binds, HTTP 200 returned from `/products` |

The smoke test is the most important step. A server that passes syntax checking but crashes on startup (due to a missing env var, a bad import, or a runtime error in initialization code) is caught here within 3 seconds — not in production.

### Frontend CI Steps

| Step | What it catches |
|---|---|
| `checkout` | Repository state at this commit |
| `setup-node` | Correct Node version for Vite compatibility |
| `npm ci` | Missing packages, version drift |
| `npm run build` | JSX syntax errors, missing component imports, bad module paths |
| Artifact verification | `dist/index.html` exists — build didn't silently produce nothing |

The `npm run build` step is the most important for the frontend. Vite compiles the entire React application. Any import of a component that doesn't exist, any JSX syntax error, any missing dependency — the build fails and CI reports it. Without CI, this failure would only be discovered when deploying to staging or production.

### Docker Build Steps

| Step | What it catches |
|---|---|
| `setup-buildx` | Builder initialization |
| `build backend image` | Dockerfile syntax, base image availability, `COPY` paths, `RUN` errors |
| `build frontend image` | Same for frontend Dockerfile |

Images are built with `push: false` — they are validated but not pushed to a registry. Registry push happens in the CD pipeline, not CI.

---

## 6. npm ci vs npm install

```yaml
- name: Install dependencies
  run: npm ci   # NOT npm install
```

| | `npm install` | `npm ci` |
|---|---|---|
| Reads | `package.json` (allows version ranges) | `package-lock.json` (exact versions) |
| Behavior if lockfile differs | Updates lockfile silently | **Fails with an error** |
| Removes node_modules first | No | Yes (clean install) |
| Use case | Local development | CI pipelines |

In CI, `npm ci` is mandatory. If a developer accidentally modified `package-lock.json` without updating `package.json` (or vice versa), `npm ci` catches the inconsistency immediately. `npm install` would silently install a different version and potentially mask dependency issues.

---

## 7. Concurrency and Cancellation

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

When a developer pushes two commits quickly (e.g., fix a typo right after the first push), two CI runs start simultaneously for the same branch. The first run is now stale — the repository has moved forward. With `cancel-in-progress: true`, GitHub Actions automatically cancels the older run and keeps only the newest one running. This saves compute minutes and reduces the queue.

---

## 8. Scenario: Code That Works Locally But Breaks When Merged

**Scenario:** Team often merges code that compiles locally but breaks when combined with other changes in the main branch.

### Why This Happens Without CI

Local development environments diverge from each other over time:
- Developer A has `react@18.2.0` installed globally; the project specifies `^18.0.0`
- Developer B installs a new dependency but doesn't commit `package-lock.json`
- Developer A deletes a shared utility function that Developer B's new code depends on — but A's local tests pass because B's new component doesn't exist locally yet
- Two developers both modify the same ConfigMap key with different values — both pass local tests that don't import each other's changes

When both changes land on main, the combination fails. If there's no CI, the breakage is discovered by whoever pulls main next.

### How GitHub Actions CI Catches These Issues Early

1. **`npm ci` fails** if the lockfile is inconsistent — the dependency version mismatch is caught at install time, before any code runs.

2. **The build step fails** if Developer A deleted a function that Developer B's code imports. On Developer B's PR branch (which is based on main + B's changes), the build step tries to compile all components including A's deletion. The import fails → build fails → CI fails → B cannot merge.

3. **The smoke test fails** if a bad initialization change prevents the server from starting — catches what syntax checks miss.

### Which Events Should Trigger CI

| Event | Why |
|---|---|
| `push` to any branch | Immediate feedback before PR is opened |
| `pull_request` to main | Gate: prevents merge of failing code |

`push` to main directly should be blocked by branch protection rules — all changes should go through PRs with CI passing.

### What Risks Remain Without Automated CI

| Risk | Consequence |
|---|---|
| Integration failures only discovered post-merge | Everyone who pulls main is blocked |
| Manual testing is inconsistent | What one developer tests, another skips |
| No record of what was validated | Can't audit what checks passed before a deploy |
| Slow feedback loop | Failures discovered in staging, not at the PR stage |
| Dependency drift | Different machines, different versions, different behaviors |

CI does not eliminate all risk — it cannot catch logic errors, performance regressions, or integration with external services without more sophisticated tests. But it eliminates the entire class of "it compiled on my machine" failures that are the most common source of merge-day breakage in collaborative projects.
