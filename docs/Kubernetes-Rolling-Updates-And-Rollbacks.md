# Kubernetes Rolling Updates & Rollbacks

> This document explains how Kubernetes performs rolling updates to deliver new versions of an application without downtime, how it tracks revision history to enable instant rollbacks, and why this mechanism is critical for safe production deployments.

---

## Table of Contents

1. [The Problem: Deployment Without Safety](#1-the-problem-deployment-without-safety)
2. [Rolling Update Strategy](#2-rolling-update-strategy)
3. [How maxSurge and maxUnavailable Control the Rollout](#3-how-maxsurge-and-maxunavailable-control-the-rollout)
4. [How readinessProbe Guards Traffic During a Rollout](#4-how-readinessprobe-guards-traffic-during-a-rollout)
5. [AeroStore Rolling Update Configuration](#5-aerostore-rolling-update-configuration)
6. [Revision History and Rollback](#6-revision-history-and-rollback)
7. [Rolling Update Diagram](#7-rolling-update-diagram)
8. [Verification — Observing Rollout and Rollback](#8-verification--observing-rollout-and-rollback)
9. [Scenario: Bad Release — Detection and Recovery](#9-scenario-bad-release--detection-and-recovery)
10. [Rolling Update vs Recreate Strategy](#10-rolling-update-vs-recreate-strategy)

---

## 1. The Problem: Deployment Without Safety

Without a rolling update strategy, the naive way to deploy a new version is:

1. Delete all running Pods (old version)
2. Create new Pods (new version)

This causes **complete downtime** between steps 1 and 2 — users receive connection errors for the entire time it takes for new Pods to start. In production, this can be 30 seconds to several minutes depending on startup time.

Even worse: if the new version has a bug, you have deployed it to 100% of your capacity with no ability to limit the blast radius.

Kubernetes' **RollingUpdate strategy** solves both problems.

---

## 2. Rolling Update Strategy

A rolling update replaces old Pods with new ones **gradually**, ensuring there are always enough healthy Pods serving traffic throughout the transition. When you change the Docker image (or any part of the Pod template) in a Deployment, Kubernetes:

1. Creates a **new ReplicaSet** for the new version, initially with 0 Pods
2. Gradually **scales up** the new ReplicaSet (creating new Pods)
3. Gradually **scales down** the old ReplicaSet (terminating old Pods)
4. Keeps the Service routing to healthy Pods at all times

The old ReplicaSet is kept around (scaled to 0 replicas, not deleted) so that rollback is instant — Kubernetes just scales the old ReplicaSet back up.

### What Triggers a Rolling Update?

Any change to the Pod **template** (`spec.template`) in a Deployment triggers a new rollout:
- ✅ Changing the container image version
- ✅ Changing environment variables or ConfigMap references
- ✅ Changing resource requests/limits
- ✅ Changing probe configuration

Changes to `spec.replicas` or `spec.strategy` do **not** trigger a new rollout (they take effect immediately without creating a new ReplicaSet).

---

## 3. How maxSurge and maxUnavailable Control the Rollout

These two parameters define the rollout's speed and safety tradeoff:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # How many EXTRA Pods above desired count are allowed
    maxUnavailable: 0  # How many Pods can be unavailable during the rollout
```

### maxSurge

With `replicas: 3` and `maxSurge: 1`, Kubernetes can have up to 4 Pods running simultaneously during the rollout (3 desired + 1 surge). This means it creates one new Pod before it terminates any old Pod.

- **Higher maxSurge** → faster rollout, uses more resources temporarily
- **Lower maxSurge** → slower rollout, conserves resources
- **`maxSurge: 0`** → only one Pod at a time is replaced, slowest possible rollout

### maxUnavailable

With `maxUnavailable: 0`, Kubernetes will **never terminate an old Pod until a new Pod is Ready**. This guarantees zero downtime at the cost of requiring extra capacity during the rollout.

- **`maxUnavailable: 0`** → zero-downtime rollout (requires `maxSurge > 0`)
- **`maxUnavailable: 1`** → one Pod may be unavailable, slightly faster rollout
- **`maxUnavailable: 100%`** → all old Pods deleted at once (equivalent to Recreate strategy)

### AeroStore Configuration: maxSurge=1, maxUnavailable=0

This is the **zero-downtime configuration**:
- Before any old Pod is removed, a new Pod must be created AND pass its readiness probe
- At any moment, at least 3 Pods are serving traffic (either old or new version)
- The rollout is slightly slower than more aggressive settings, but users never experience downtime

```
Desired: 3 replicas, maxSurge: 1, maxUnavailable: 0

Step 1: Create 1 new Pod (v2)          → 3 old + 1 new = 4 Pods (allowed: 3+1)
Step 2: New Pod passes readiness probe  → new Pod enters Service
Step 3: Terminate 1 old Pod (v1)        → 3 total = 2 old + 1 new
Step 4: Create 1 new Pod (v2)           → 2 old + 2 new = 4 Pods
Step 5: New Pod passes readiness        → new Pod enters Service
Step 6: Terminate 1 old Pod            → 3 total = 1 old + 2 new
Step 7: Create 1 new Pod (v2)           → 1 old + 3 new = 4 Pods
Step 8: New Pod passes readiness        → new Pod enters Service
Step 9: Terminate last old Pod          → 3 new Pods — rollout complete
```

At every step, at least 3 Pods are Ready and serving traffic.

---

## 4. How readinessProbe Guards Traffic During a Rollout

The readiness probe is **the safety gate** for rolling updates. Kubernetes will not add a new Pod to the Service's endpoint list (and will not terminate the old Pod it is replacing) until the new Pod's readiness probe returns success.

Without a readiness probe, Kubernetes adds the new Pod to the Service as soon as the container process starts — even if the application inside hasn't finished initializing. Users get routed to a half-started server.

With a readiness probe:
```yaml
readinessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 3
```

The rollout controller waits for the probe to pass before proceeding. If the probe never passes (e.g., new image is broken), the rollout stalls at that step — old Pods keep running and serving traffic.

---

## 5. AeroStore Rolling Update Configuration

```yaml
# backend-deployment.yaml
metadata:
  annotations:
    kubernetes.io/change-cause: "update to nginx:1.17.0 — add explicit rolling update strategy"

spec:
  replicas: 3
  revisionHistoryLimit: 5    # Keep 5 old ReplicaSets for rollback

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1            # Allow 1 extra Pod during rollout (up to 4 total)
      maxUnavailable: 0      # Never allow any Pod to be unavailable

  template:
    spec:
      containers:
        - name: backend
          image: nginx:1.17.0   # Updated from 1.16.1 — triggers rolling rollout
```

### The `change-cause` Annotation

The `kubernetes.io/change-cause` annotation is recorded in the rollout history for each revision. This allows you to see a human-readable description of what changed in each deployment — similar to a release note linked to a specific version.

```bash
kubectl rollout history deployment/aerostore-backend
# REVISION  CHANGE-CAUSE
# 1         <none>
# 2         update to nginx:1.17.0 — add explicit rolling update strategy
```

---

## 6. Revision History and Rollback

### How Revision History Works

Every time a rolling update completes, Kubernetes stores the old ReplicaSet (scaled to 0 replicas). These stored ReplicaSets are the rollback targets. The number stored is controlled by `revisionHistoryLimit`.

```bash
# See all Deployments' ReplicaSets (current + historical)
kubectl get replicasets -l app=backend

# NAME                              DESIRED   CURRENT   READY   AGE
# aerostore-backend-6d8f4b5c9       3         3         3       5m   ← current (v2)
# aerostore-backend-7c9b3d4f1       0         0         0       30m  ← old (v1), kept for rollback
```

### Performing a Rollback

```bash
# Roll back to the previous revision
kubectl rollout undo deployment/aerostore-backend

# Roll back to a specific revision number
kubectl rollout undo deployment/aerostore-backend --to-revision=1
```

A rollback is itself a rolling update — it uses the same `maxSurge` and `maxUnavailable` settings to replace new Pods with old ones. This means rollback is also zero-downtime.

**Key insight:** Rollback is instant because the old ReplicaSet still exists. Kubernetes simply scales it back up and scales down the current one — there is no image rebuild, no CI pipeline run, no waiting for a new image to be pushed. The old Pods start from an already-pulled image.

### When to Roll Back

Rollback is appropriate when:
- New Pods are stuck in `ErrImagePull` or `ImagePullBackOff` (bad image tag)
- New Pods fail their readiness probe (application broken)
- The rollout completes but monitoring shows error rates spiking
- Users report a regression introduced by the new version

### Rollback Does Not Roll Back ConfigMaps or Secrets

An important limitation: `kubectl rollout undo` only restores the Pod template (image, env vars, probes, resources). It does **not** restore ConfigMaps or Secrets that may have changed alongside the Deployment. If a ConfigMap was modified as part of the release, you must manually restore it.

---

## 7. Rolling Update Diagram

![Kubernetes Rolling Update and Rollback Diagram](k8s-rolling-update-diagram.png)

```
STABLE STATE (v1):
  [Pod v1.16.1] [Pod v1.16.1] [Pod v1.16.1]
       ↑               ↑               ↑
       └───────────── Service ─────────┘  (all Pods serving traffic)

ROLLING UPDATE IN PROGRESS:
  maxSurge=1 → up to 4 Pods at once
  maxUnavailable=0 → no Pod removed until new one is Ready

  [Pod v1.16.1] [Pod v1.16.1] [Terminating] [Pod v1.17.0 ✓] [Pod v1.17.0 (init)]
                                              ↑
                                   readiness passed → in Service

OUTCOMES:
  ✓ All new Pods healthy → rollout complete → old ReplicaSet scaled to 0
  ✗ New Pod readiness fails → rollout stalls → old Pods keep serving
     → kubectl rollout undo → old ReplicaSet scaled back up → restored instantly
```

---

## 8. Verification — Observing Rollout and Rollback

### Watch a Rollout Live

```bash
# Trigger rolling update
kubectl set image deployment/aerostore-backend backend=nginx:1.18.0

# Watch status (blocks until complete or timeout)
kubectl rollout status deployment/aerostore-backend

# Watch Pods transitioning
kubectl get pods -l app=backend -w
```

### Check Revision History

```bash
kubectl rollout history deployment/aerostore-backend

# Inspect a specific revision
kubectl rollout history deployment/aerostore-backend --revision=2
```

### Simulate a Failed Release and Rollback

```bash
# Deploy a bad image
kubectl set image deployment/aerostore-backend backend=nginx:nonexistent-tag

# Pods will enter ErrImagePull — rollout stalls, old Pods keep running
kubectl get pods -l app=backend

# Roll back immediately
kubectl rollout undo deployment/aerostore-backend

# Watch recovery
kubectl rollout status deployment/aerostore-backend
```

### Confirm Zero Downtime

```bash
# Curl from inside the cluster continuously during a rolling update
kubectl exec curl-client -- sh -c \
  "while true; do wget -q -O- http://aerostore-backend-service:3001 2>&1; sleep 0.5; done"
```

No gaps in responses — the Service continuously routes to Ready Pods only.

---

## 9. Scenario: Bad Release — Detection and Recovery

**Scenario:** A new version is deployed via rolling update. Shortly after, users report errors and degraded behavior.

### How Rolling Updates Limit the Blast Radius

With `maxUnavailable: 0` and `maxSurge: 1`, the rollout proceeds one Pod at a time. If the new version breaks, only 1 Pod (the surge Pod) is serving bad traffic at any moment — the other 3 original Pods are still healthy. The blast radius is limited to 1/4 of capacity, not 100%.

Additionally, if the new Pods fail their readiness probe, Kubernetes **automatically stalls the rollout** — it never proceeds to replace more old Pods. The old version continues serving all traffic. In this case, no user sees errors at all — the broken version is quarantined to 0% of live traffic.

### How Kubernetes Tracks Previous Versions

Each deployment revision is stored as a ReplicaSet with 0 replicas. The `revisionHistoryLimit: 5` setting keeps up to 5 old ReplicaSets. Each has the complete Pod template of that revision — image, env vars, probes, resources. This is the rollback mechanism.

### When to Trigger a Rollback

- **Immediately:** New Pods are stuck in `ErrImagePull` (wrong image tag, registry credentials expired)
- **Within minutes:** Error rate monitoring (Prometheus/Datadog) shows spike after rollout
- **On user reports:** Functional regression that monitoring didn't catch
- **Proactively:** If rollout stalls and doesn't complete within `progressDeadlineSeconds`

### How Rollback Restores Stability

```bash
kubectl rollout undo deployment/aerostore-backend
```

1. The old ReplicaSet (already stored, image already pulled on nodes) scales from 0 back to 3
2. The rolling update mechanism runs in reverse: new broken Pods are terminated one at a time
3. Old Pods become Ready and are added back to the Service
4. Within ~60 seconds, all traffic is back on the stable version
5. No rebuild, no new image, no CI run required — the old Pod spec is already there

---

## 10. Rolling Update vs Recreate Strategy

| | RollingUpdate | Recreate |
|---|---|---|
| **Downtime** | None (with maxUnavailable:0) | Yes — gap between delete and create |
| **Simultaneous versions** | Brief period with both versions running | No — clean cut-over |
| **Rollback** | Instant (old ReplicaSet kept) | Instant (old ReplicaSet kept) |
| **Use when** | Almost always in production | Stateful apps where two versions cannot coexist (DB schema changes) |
| **Speed** | Slower (gradual) | Faster (all Pods replaced at once) |

**Always use `RollingUpdate` in production unless you have a specific reason not to.** The brief window of running two versions simultaneously is almost always acceptable, and zero downtime is non-negotiable for most services.
