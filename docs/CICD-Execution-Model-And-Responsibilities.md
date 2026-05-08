# CI/CD Execution Model — Responsibilities, Boundaries & Pipeline Flow

> **Updated after AI review:** This version incorporates improvements in clarity and structure — specifically around the blast radius explanation, the pipeline change impact section, and sharper separation of CI-only vs CD-only responsibilities.

> This document explains how CI/CD pipelines are executed, where each action occurs, and why clearly defined responsibility boundaries are critical for safe pull requests and reliable production systems.

---

## Table of Contents

1. [CI vs CD Responsibility Explanation](#1-ci-vs-cd-responsibility-explanation)
2. [Pipeline Execution Flow — Where Things Happen](#2-pipeline-execution-flow--where-things-happen)
3. [Responsibility Boundaries — Why Separation Matters](#3-responsibility-boundaries--why-separation-matters)
4. [Pipeline Change Impact Explanation](#4-pipeline-change-impact-explanation)
5. [CI/CD Execution Model Diagram](#5-cicd-execution-model-diagram)
6. [Reflection — Orchestration vs Replacement](#6-reflection--orchestration-vs-replacement)
7. [Common Pitfalls to Avoid](#7-common-pitfalls-to-avoid)

---

## 1. CI vs CD Responsibility Explanation

### Continuous Integration (CI) — Validate and Package

**CI is responsible for one thing: proving that a code change is safe to be merged.**

Every time a developer pushes code or opens a Pull Request, the CI pipeline runs automatically. It is the automated quality gate that prevents broken, untested, or unpackageable code from ever reaching the main branch.

**CI SHOULD:**
- Install dependencies and compile/build the application
- Run all unit tests, integration tests, and linters
- Build a Docker image from the verified source code
- Tag the image with the Git commit SHA for traceability
- Push the tagged image to the container registry
- Report a pass/fail status back to the Pull Request

**CI SHOULD NOT:**
- Deploy anything to any environment (staging, production, or otherwise)
- Modify live Kubernetes manifests or cluster state
- Run database migrations on production data
- Send external notifications about deployment success/failure
- Make decisions about *where* or *when* an artifact is used — that is CD's job

> **Key principle:** CI's job ends when the artifact is safely stored in the registry. It has no knowledge of, and no authority over, what happens next.

---

### Continuous Deployment (CD) — Deploy and Deliver

**CD is responsible for one thing: taking a verified artifact and delivering it to the target environment.**

CD only triggers after CI has successfully produced and pushed a Docker image. It never builds from source — it only works with pre-built, pre-verified artifacts.

**CD SHOULD:**
- Pick up the image artifact produced by CI (by tag or digest)
- Update the Kubernetes Deployment manifest with the new image reference
- Apply the manifest to the target cluster (`kubectl apply`)
- Monitor the rollout status and report success or failure
- Trigger rollback if the deployment fails health checks

**CD SHOULD NOT:**
- Run tests — tests are CI's job and have already been completed
- Build Docker images — the artifact is already built and verified
- Contain application business logic or make decisions about code correctness
- Bypass infrastructure review by directly modifying cluster state without manifests

> **Key principle:** CD treats the Docker image as a sealed, trusted package. It orchestrates *where* and *when* it runs — it does not modify, rebuild, or re-verify the code inside it.

---

## 2. Pipeline Execution Flow — Where Things Happen

This table maps every key action in the software delivery process to the layer responsible for it:

| Action | Where It Happens | Who Owns It |
|---|---|---|
| Writing application logic | **Developer's machine** | Application developer |
| Writing unit tests | **Developer's machine** | Application developer |
| Running unit/integration tests | **CI pipeline** (GitHub Actions runner) | CI system |
| Building a Docker image | **CI pipeline** (GitHub Actions runner) | CI system |
| Tagging and pushing images to registry | **CI pipeline** (GitHub Actions runner) | CI system |
| Deploying to Kubernetes | **CD pipeline** (GitHub Actions runner or ArgoCD) | CD system |
| Rolling update execution | **Kubernetes control plane** | Infrastructure |
| Restarting failed containers | **Kubernetes kubelet** (node-level agent) | Infrastructure (self-healing) |
| Rescheduling Pods on node failure | **Kubernetes scheduler + controller** | Infrastructure (self-healing) |

### Breaking It Down Further

**Application Code layer** (developer's laptop):
The developer writes business logic and the tests that verify it. This layer is entirely human and local. Nothing here is automated — it's where creative and technical decision-making happens.

**CI Pipeline layer** (GitHub Actions runner — a temporary cloud VM):
When code is pushed, GitHub spins up a clean, ephemeral virtual machine. This runner has no persistent state. It checks out the code, installs dependencies, runs tests, builds the Docker image, and pushes it to Docker Hub. Once the job completes, the VM is destroyed. This isolation is intentional — it means no build can be contaminated by a previous one.

**CD Pipeline layer** (GitHub Actions runner or GitOps controller):
After the image is in the registry, the CD pipeline picks it up. It does not re-run tests. It updates the Kubernetes manifest (changing the `image:` field to the new tag) and applies it to the cluster. In a GitOps model (e.g., ArgoCD), the CD pipeline is replaced by a controller that watches a Git repository for manifest changes and syncs them automatically.

**Infrastructure layer** (Kubernetes cluster):
Kubernetes takes over completely once the manifest is applied. The scheduler assigns Pods to Nodes, the kubelet pulls the image and starts containers, health probes verify readiness, and the self-healing controllers watch for failures and respond automatically. No human and no pipeline is involved at this stage — it is fully automated infrastructure behavior.

---

## 3. Responsibility Boundaries — Why Separation Matters

**"Why is it dangerous to mix application logic, pipeline logic, and deployment logic in a single step?"**

Mixing these three layers together creates a system that is fragile, unreviewed, and impossible to safely roll back. Here is why, through four lenses:

### Blast Radius of Failures

When responsibilities are separated, a failure in one layer has a contained blast radius. If tests fail in CI, the image is never built and nothing reaches production. If the CD pipeline fails, the previous deployment remains running. If a Pod crashes in Kubernetes, the ReplicaSet creates a replacement without touching the pipeline.

When responsibilities are mixed — for example, a CI step that also runs `kubectl apply` directly — a test failure could still trigger a half-executed deployment. Or a deployment error could corrupt the test environment. The failure in one layer cascades into another because there are no clean boundaries to contain it.

### Review Safety in Pull Requests

When CI configuration, CD configuration, and application code are all in the same file or step, a code reviewer cannot safely evaluate a Pull Request. They cannot tell whether a change is:
- Modifying business logic (requires testing)
- Modifying the pipeline (requires pipeline review)
- Modifying deployment behavior (requires infrastructure review)

Separated files — `src/` for application logic, `.github/workflows/ci.yml` for CI, `.github/workflows/cd.yml` for CD — mean each type of change can be reviewed by the right person with the right expertise.

### Predictability of Deployments

A CD pipeline that only deploys pre-built, registry-stored images is deterministic. The same image tag always produces the same running container. There are no surprises because the artifact was already sealed and verified by CI.

A mixed pipeline that rebuilds from source during deployment introduces variability: network conditions, dependency versions, or environment differences on the deployment runner can cause the "same" deployment to produce different results at different times.

### Rollback Reliability

Because CD only works with immutable image tags, rolling back is instant and reliable: point Kubernetes to the previous tag. The old image is sitting unchanged in the registry.

In a mixed system where deployment logic is entangled with build logic, rolling back requires re-running the entire mixed step in reverse — which may not even be possible if the source code has changed, dependencies have been updated, or intermediate state was not preserved.

---

## 4. Pipeline Change Impact Explanation

Modifying different parts of the pipeline has very different downstream effects. Understanding these effects before merging is a critical skill.

### Modifying Test Steps in CI

**Impact:** Any change to test configuration, test commands, or test coverage thresholds directly affects the quality gate.

- **Adding tests:** Increases confidence. PRs that previously would have passed may now fail if they don't meet the new standard. This is a positive change but requires team awareness.
- **Removing tests:** Weakens the quality gate. Broken code that relied on those tests to be caught can now pass CI and reach the registry.
- **Changing test thresholds (e.g., coverage minimum):** Can block all future PRs until codebase meets the new threshold, or silently allow lower-quality code if lowered.

> **Risk:** Removing or weakening tests without review is one of the most common causes of production regressions.

### Modifying Build or Image Creation Steps

**Impact:** Any change to the Dockerfile, build arguments, base image, or the `docker build` command in CI affects every image produced from that point forward.

- **Changing the base image** (e.g., `node:18-alpine` → `node:20-alpine`): Can introduce runtime behavior changes, new CVEs, or compatibility issues with existing code.
- **Adding build arguments or environment variables:** Can expose secrets if done carelessly, or change application configuration baked into the image.
- **Changing the image tagging format:** Can break CD pipeline steps that rely on a predictable tag format to know which image to deploy.

> **Risk:** A seemingly small Dockerfile change can produce an image that behaves differently in production than in testing, especially if the CI test step doesn't fully exercise the built image.

### Modifying Deployment Steps in CD

**Impact:** CD step changes directly affect how and when production is updated.

- **Changing the target namespace or cluster:** Could accidentally deploy to the wrong environment (e.g., production instead of staging).
- **Removing rollout status checks:** CD may report success immediately after `kubectl apply`, before verifying that Pods are actually healthy — masking deployment failures.
- **Adding direct `kubectl exec` or migration commands:** Introduces side effects that are not tracked in Git and cannot be rolled back declaratively.
- **Changing the deployment trigger condition** (e.g., deploying on PR instead of merge): Can deploy unreviewed, untested code to production.

> **Risk:** CD step changes have the highest potential blast radius because they directly touch the production environment. Any change to CD should be reviewed with the same scrutiny as a production change — because it is one.

---

## 5. CI/CD Execution Model Diagram

The diagram below shows the complete execution model from code change to running infrastructure:

![CI/CD Execution Model Diagram](cicd-execution-diagram.png)

```
┌─────────────────────────────────────────────┐
│           💻 CODE CHANGE                    │
│  Developer writes app logic + tests          │
│  Opens Pull Request on GitHub                │
└────────────────────┬────────────────────────┘
                     │ triggers on push / PR
                     ▼
┌─────────────────────────────────────────────┐   ┌──────────────────────┐
│         ⚙️  CI PIPELINE                     │   │  RESPONSIBILITY MAP  │
│  [GitHub Actions runner — ephemeral VM]      │   │                      │
│  ① Install dependencies                      │   │ APP CODE:            │
│  ② Run unit + integration tests              │   │ Business logic, tests │
│  ③ docker build (from Dockerfile)            │   │                      │
│  ④ docker tag :commit-sha                    │   │ CI PIPELINE:         │
│  ⑤ docker push → Docker Hub                 │   │ Validate + Package   │
└────────────────────┬────────────────────────┘   │                      │
                     │ produces                    │ CD + K8s:            │
                     ▼                             │ Deploy + Heal        │
┌─────────────────────────────────────────────┐   └──────────────────────┘
│       📦 DOCKER IMAGE (ARTIFACT)             │
│  Immutable, registry-stored                  │
│  kalviaki0/devops-backend:commit-9f3a1c2     │
│  Verified: passed all CI tests               │
└────────────────────┬────────────────────────┘
                     │ picked up by
                     ▼
┌─────────────────────────────────────────────┐
│           🚀 CD PIPELINE                    │
│  [GitHub Actions runner — ephemeral VM]      │
│  ① Updates K8s manifest image tag           │
│  ② kubectl apply -f deployment.yaml         │
│  ③ Monitors rollout status                  │
│  ④ Reports success or triggers rollback     │
└────────────────────┬────────────────────────┘
                     │ applies to
                     ▼
┌─────────────────────────────────────────────┐
│     ☸️  KUBERNETES / CLOUD INFRASTRUCTURE   │
│  Scheduler assigns Pods to Nodes             │
│  kubelet pulls image from Docker Hub         │
│  Container runtime starts containers         │
│  Health probes verify readiness              │
│  Self-healing: restart / reschedule          │
└─────────────────────────────────────────────┘
```

---

## 6. Reflection — Orchestration vs Replacement

**"Why should CI/CD pipelines orchestrate work instead of replacing application or infrastructure logic?"**

CI/CD pipelines are automation glue — they coordinate the handoffs between layers of a system, but they should never absorb the logic that belongs to those layers. A pipeline that starts containing business rules, database queries, or infrastructure provisioning scripts has violated its own purpose, and in doing so, has created a system that is harder to understand, harder to review, and impossible to trust.

**Clear ownership:** When CI only validates and CD only deploys, every engineer knows exactly where to look when something breaks. A test failure belongs to the application layer. A deployment failure belongs to the CD layer. A container restart belongs to Kubernetes. Mixing these responsibilities collapses that clarity — a failure could be caused by any part of a tangled system, and debugging becomes archaeology.

**Automation vs responsibility:** The pipeline's job is to automate the *triggering* and *sequencing* of well-defined operations — not to own those operations. Tests are owned by the application team. Deployments are owned by the infrastructure team. The pipeline coordinates them. When a pipeline starts doing things that belong to those teams, those teams lose visibility and control over their own domains.

**Safety and maintainability:** Pipelines that orchestrate rather than replace are easy to modify safely. Changing a CI trigger condition doesn't break the test suite. Changing a CD deployment step doesn't affect how the image is built. The layers remain independently testable, reviewable, and replaceable. A pipeline that has replaced the infrastructure layer — for example, by running direct `kubectl exec` commands with embedded logic — cannot be safely refactored without risking production impact. The system becomes brittle because the boundaries have collapsed.

---

## 7. Common Pitfalls to Avoid

| Pitfall | Why It's Dangerous | What to Do Instead |
|---|---|---|
| Running `kubectl apply` inside the CI stage | Deploys unreviewed code directly to production on every push | Keep deploy steps strictly in CD, triggered only on main branch merge |
| Rebuilding the Docker image in the CD stage | Produces a different artifact than what CI tested | CD must only pull and deploy the image already pushed by CI |
| Storing secrets directly in pipeline YAML | Secrets are visible in Git history and to all collaborators | Use GitHub Actions Secrets or a vault (e.g., HashiCorp Vault) |
| Skipping rollout status check in CD | Pipeline reports success before Pods are actually healthy | Always run `kubectl rollout status` after apply and fail the pipeline if it times out |
| Using a single combined CI/CD YAML file with no stage separation | Any change to the file can affect both validation and deployment behavior unpredictably | Use separate workflow files: `ci.yml` triggered on PR, `cd.yml` triggered on merge to main |
| Deploying on every push to a PR branch | Every draft commit triggers a production-affecting deployment | CD should only trigger on merge to `main`, never on PR pushes |
