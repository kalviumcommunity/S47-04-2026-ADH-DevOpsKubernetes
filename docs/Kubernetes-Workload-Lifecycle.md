# Kubernetes Workload Lifecycle — From Deployment to Self-Healing Pods

> **Updated after AI review:** This version includes improvements for clarity and correctness — specifically around the reconciliation loop explanation, rolling update availability math, and expanded CrashLoopBackOff diagnosis steps.

> This document explains the complete internal lifecycle of a Kubernetes workload — from creating a Deployment to scheduling Pods, running health checks, handling failures, and automatically recovering. It covers how Kubernetes maintains reliability through desired state management, rolling updates, probes, and self-healing behavior.

---

## Table of Contents

1. [Kubernetes Lifecycle: Deployment → ReplicaSet → Pods](#1-kubernetes-lifecycle-deployment--replicaset--pods)
2. [Deployment & Rollout Mechanics](#2-deployment--rollout-mechanics)
3. [Health Probes & Resource Configuration](#3-health-probes--resource-configuration)
4. [Pod States & Failure Conditions](#4-pod-states--failure-conditions)
5. [Kubernetes Lifecycle Diagram](#5-kubernetes-lifecycle-diagram)
6. [Reflection — Desired State vs. Application Correctness](#6-reflection--desired-state-vs-application-correctness)
7. [Common Pitfalls to Avoid](#7-common-pitfalls-to-avoid)

---

## 1. Kubernetes Lifecycle: Deployment → ReplicaSet → Pods

### How a Deployment Defines Desired State

A **Deployment** is a Kubernetes object that describes *what you want* — not *how to get there*. It is a declaration of intent. You specify:

- How many replicas (copies of your app) should run
- Which container image to use
- What update strategy to apply when the image changes
- What resource limits and health checks the containers need

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aerostore-backend
spec:
  replicas: 3                         # Desired state: 3 pods should always be running
  selector:
    matchLabels:
      app: aerostore-backend
  template:
    spec:
      containers:
        - name: backend
          image: kalviaki0/devops-backend:commit-9f3a1c2
```

Kubernetes stores this desired state in **etcd** (the cluster's key-value database). The **Deployment Controller** then continuously monitors the cluster to ensure reality matches this declaration.

### How a ReplicaSet Is Created and Manages Pods

When you apply a Deployment, Kubernetes automatically creates a **ReplicaSet** under it. The ReplicaSet's single job is to ensure that the correct number of Pods is always running. It does this through the **reconciliation loop**:

```
Desired Pods (3) ≠ Current Pods (2)
        ↓
ReplicaSet Controller detects the gap
        ↓
Creates 1 new Pod to close the gap
```

The ReplicaSet owns the Pods it creates through **label selectors**. Any Pod matching the selector (e.g., `app: aerostore-backend`) is counted as part of the replica set. If a Pod dies, the count drops below desired, and the ReplicaSet immediately creates a replacement.

### How Pods Are Scheduled onto Nodes

Once a Pod is created by the ReplicaSet, it enters the `Pending` state. It exists in etcd but hasn't been assigned to a physical Node yet. The **kube-scheduler** watches for unscheduled Pods and selects the best Node based on:

1. **Resource availability:** Does the Node have enough CPU and memory to satisfy the Pod's `requests`?
2. **Taints and tolerations:** Is the Pod allowed to run on this Node?
3. **Affinity rules:** Are there preferences about which Nodes to use?
4. **Current load:** Scheduler spreads Pods across Nodes to avoid hot spots.

Once the scheduler assigns a Node, the **kubelet** (the agent running on that Node) takes over. It contacts the container registry, pulls the image, and uses the container runtime (e.g., containerd) to start the container.

### Desired State vs. Current State — Continuous Reconciliation

This is the most important concept in Kubernetes. Every controller in the cluster runs a continuous loop:

```
Watch current state
      ↓
Compare to desired state
      ↓
If different → take action to close the gap
      ↓
Repeat forever
```

This means Kubernetes never "finishes." It is always watching, always comparing, always correcting. If you manually delete a Pod, the ReplicaSet controller detects the gap within seconds and creates a new one. If a Node goes offline, the Pods on it are rescheduled to healthy Nodes. This behavior is what makes Kubernetes self-healing — it's not magic, it's a tight feedback loop running continuously.

---

## 2. Deployment & Rollout Mechanics

### How Rolling Updates Work

When you update a Deployment (e.g., change the container image tag), Kubernetes performs a **rolling update** by default. It does NOT kill all old Pods and start new ones simultaneously — that would cause downtime.

Instead, it uses two parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `maxSurge` | 25% | How many extra Pods can exist above desired during rollout |
| `maxUnavailable` | 25% | How many Pods can be unavailable (not serving traffic) during rollout |

**Example with 4 replicas (maxSurge=1, maxUnavailable=1):**

```
Start:     [v1] [v1] [v1] [v1]     ← 4 old pods running
Step 1:    [v1] [v1] [v1] [v2]     ← 1 new pod created (surge), 1 old terminated
Step 2:    [v1] [v1] [v2] [v2]     ← 1 more new, 1 more old terminated
Step 3:    [v1] [v2] [v2] [v2]     ← continuing...
Step 4:    [v2] [v2] [v2] [v2]     ← rollout complete
```

At no point are all Pods unavailable. Availability is maintained throughout.

### The Role of ReplicaSets in Tracking Versions

Each Deployment update creates a **new ReplicaSet**. The old ReplicaSet is kept (scaled to 0 replicas) so that Kubernetes can use it for rollbacks. At any time:

```
aerostore-backend-7d4c9f (v2 ReplicaSet) → 4 pods running   ← active
aerostore-backend-5b2a1e (v1 ReplicaSet) → 0 pods running   ← kept for rollback
```

This is why `kubectl rollout undo` is instant — it doesn't rebuild anything, it simply scales the old ReplicaSet back up and scales the new one down.

### What a Successful Rollout Looks Like

```bash
kubectl rollout status deployment/aerostore-backend
# Output: deployment "aerostore-backend" successfully rolled out
```

All new Pods are:
- `Running` with status `1/1 Ready`
- Passing their `readinessProbe` (if configured)
- Traffic has been shifted to the new Pods
- Old Pods have been gracefully terminated

### What Happens During a Failed Rollout

If new Pods fail their health checks (or crash immediately), Kubernetes **pauses the rollout** at the `maxUnavailable` threshold. It will not terminate more old Pods than allowed, meaning old Pods keep serving traffic while the broken new version is stuck. This prevents a full outage.

```bash
kubectl rollout status deployment/aerostore-backend
# Output: Waiting for deployment "aerostore-backend" rollout to finish: 1 out of 4 new replicas have been updated...
# (stays here — rollout stalled)
```

You can then roll back:
```bash
kubectl rollout undo deployment/aerostore-backend
```

---

## 3. Health Probes & Resource Configuration

### Liveness Probe

The **Liveness Probe** answers: *"Is this container alive?"*

If it fails, Kubernetes restarts the container. Use it to detect deadlocks or corrupted application state — situations where the process is running but stuck and can never recover on its own.

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 3001
  initialDelaySeconds: 10   # Wait before first check
  periodSeconds: 15          # Check every 15 seconds
  failureThreshold: 3        # Restart after 3 consecutive failures
```

> **Misconfiguration risk:** If `initialDelaySeconds` is too short for a slow-starting app, the probe fails before the app is ready, causing an endless restart loop (`CrashLoopBackOff`).

### Readiness Probe

The **Readiness Probe** answers: *"Is this container ready to receive traffic?"*

If it fails, Kubernetes removes the Pod from the Service's endpoint list — traffic stops being sent to it. The Pod keeps running; it just isn't considered ready. Use it to protect against serving requests during startup, warm-up, or temporary dependency unavailability.

```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: 3001
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3
```

> **Key difference:** Liveness failure = **restart the container**. Readiness failure = **stop sending traffic** (do not restart).

### Startup Probe

The **Startup Probe** answers: *"Has this container finished its slow initialization?"*

It disables both Liveness and Readiness probes until it succeeds. This is critical for applications with long startup times (e.g., a JVM app that takes 60 seconds to initialize) that would otherwise be killed by the Liveness probe before they're ready.

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 3001
  failureThreshold: 30
  periodSeconds: 10   # Allows up to 300 seconds for startup
```

### CPU & Memory Requests — Effect on Scheduling

**Requests** are what the scheduler uses to find a suitable Node:

```yaml
resources:
  requests:
    cpu: "250m"       # 0.25 CPU cores reserved
    memory: "128Mi"   # 128 MB reserved
```

The scheduler only places a Pod on a Node that has at least this much *unallocated* capacity. If no Node has enough, the Pod stays `Pending` indefinitely.

> **Misconfiguration:** Setting requests too low causes the scheduler to pack too many Pods onto one Node, leading to resource contention and poor performance. Setting them too high causes Pods to remain `Pending` even when the cluster has plenty of actual (but un-reservable) capacity.

### CPU & Memory Limits — Effect on Runtime

**Limits** are enforced at runtime by the Linux kernel (via cgroups):

```yaml
resources:
  limits:
    cpu: "500m"       # Container throttled if it tries to use more
    memory: "256Mi"   # Container KILLED if it exceeds this
```

- **CPU limit exceeded:** The container is CPU-throttled (slowed down). It does not crash.
- **Memory limit exceeded:** The container is **killed immediately** by the OOM killer. The Pod status becomes `OOMKilled`. If the container restarts and exceeds memory again, it enters `CrashLoopBackOff`.

---

## 4. Pod States & Failure Conditions

### Pending

| | |
|---|---|
| **What it means** | The Pod has been created in etcd but no Node has been assigned yet |
| **Common causes** | Insufficient cluster resources (CPU/memory), unsatisfiable node affinity, missing PersistentVolume |
| **Kubernetes response** | Scheduler keeps retrying. The Pod stays Pending until a Node with enough capacity exists |

```bash
kubectl describe pod <pod-name>
# Look for: "0/2 nodes are available: insufficient memory"
```

### CrashLoopBackOff

| | |
|---|---|
| **What it means** | The container is starting, crashing, and being restarted in a repeated loop. Kubernetes adds increasing delays between restarts (backoff) to avoid overwhelming the system |
| **Common causes** | Application bug on startup, misconfigured Liveness probe, missing environment variable, database connection failure at boot |
| **Kubernetes response** | Kubernetes keeps restarting the container with exponential backoff: 10s → 20s → 40s → 80s → 160s → 300s (cap) |

```bash
kubectl logs <pod-name> --previous   # View logs from the crashed container
kubectl describe pod <pod-name>      # Check "Last State" and "Restart Count"
```

### ImagePullBackOff

| | |
|---|---|
| **What it means** | Kubernetes cannot pull the container image from the registry |
| **Common causes** | Image name or tag typo, image does not exist in the registry, private registry without credentials |
| **Kubernetes response** | Kubelet retries pulling with exponential backoff. The Pod stays in this state until the image becomes available or the Deployment is corrected |

```bash
kubectl describe pod <pod-name>
# Look for: "Failed to pull image ... 404 Not Found"
```

### OOMKilled

| | |
|---|---|
| **What it means** | The container exceeded its memory limit and was killed by the Linux OOM (Out Of Memory) killer |
| **Common causes** | Memory limit set too low, application memory leak, unexpected traffic spike causing high memory usage |
| **Kubernetes response** | The container is killed and restarted. If it keeps hitting the memory limit, it enters `CrashLoopBackOff`. The exit code is `137` |

```bash
kubectl describe pod <pod-name>
# Look for: "OOMKilled" in the Last State section and exit code 137
```

---

## 5. Kubernetes Lifecycle Diagram

The diagram below shows the complete lifecycle of a workload from Deployment definition to running, self-healing Pods:

![Kubernetes Lifecycle Diagram](k8s-lifecycle-diagram.png)

```
┌──────────────────────────────────────────┐
│           DEPLOYMENT                     │
│  Defines desired state: 3 replicas,      │
│  image, update strategy, probes          │
└───────────────────┬──────────────────────┘
                    │ creates
                    ▼
┌──────────────────────────────────────────┐
│            REPLICASET                    │
│  Watches pod count. If count < desired,  │
│  creates new Pods to close the gap.      │
└───────────────────┬──────────────────────┘
                    │ spawns
                    ▼
┌──────────────────────────────────────────┐
│           POD CREATION                   │
│  Pod object written to etcd.             │
│  Status: Pending                         │
└───────────────────┬──────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────┐
│            SCHEDULING                    │
│  kube-scheduler assigns Pod to a Node    │
│  based on resource requests & capacity   │
└───────────────────┬──────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────┐
│          CONTAINER START                 │
│  kubelet pulls image, container runtime  │
│  creates and starts the container        │
└───────────────────┬──────────────────────┘
                    │
                    ▼
┌──────────────────────────────────────────┐
│           HEALTH CHECKS                  │
│  startupProbe → livenessProbe            │
│               → readinessProbe           │
└───────────────────┬──────────────────────┘
                    │
          ┌─────────┴─────────┐
          ▼                   ▼
  ┌───────────────┐   ┌───────────────────┐
  │    RUNNING    │   │  RESTART /        │
  │  Serving      │   │  RESCHEDULE       │
  │  traffic      │   │  (self-healing)   │
  └───────────────┘   └───────────────────┘
```

**Reconciliation sidebar:** `Desired State ≠ Current State → Controller reconciles → Repeat`

---

## 6. Reflection — Desired State vs. Application Correctness

**"Why does Kubernetes focus on maintaining desired state instead of guaranteeing application correctness?"**

Kubernetes focuses on maintaining desired state rather than guaranteeing application correctness because infrastructure automation and application logic are fundamentally different responsibilities. Self-healing behavior — automatically restarting crashed containers, rescheduling Pods on failed nodes, replacing unhealthy replicas — is only possible because Kubernetes operates at the infrastructure level. It doesn't need to understand *why* your app crashed or *what* it was doing; it simply observes that a Pod is not in the desired state and acts to fix it.

If Kubernetes tried to guarantee application correctness, it would need to understand your business logic, your data consistency requirements, and your domain model — a scope that is impossible to generalize and completely unscalable. Instead, it provides **health probes** as the bridge: developers define what "healthy" means for their app (via livenessProbe and readinessProbe), and Kubernetes uses those developer-defined signals as the trigger for automation. This clean boundary — platform guarantees infrastructure state, developers define application health — is exactly what makes Kubernetes reliable at scale and applicable to every kind of workload without needing to know anything specific about them.

---

## 7. Common Pitfalls to Avoid

| Pitfall | Why It's Dangerous | What to Do Instead |
|---|---|---|
| No readinessProbe defined | Traffic is sent to pods that aren't ready yet, causing errors | Always define a readinessProbe for all HTTP services |
| `initialDelaySeconds` too short | Liveness probe kills the app before it finishes starting | Use a startupProbe for slow-starting apps |
| Memory limit much lower than actual usage | Constant OOMKilled → CrashLoopBackOff | Profile your app's actual memory usage before setting limits |
| Using `:latest` tag in Deployments | Rolling update won't trigger (same tag, no change detected) | Always use versioned tags (commit SHA or semver) |
| No resource requests set | Scheduler packs too many pods on one node, causing instability | Always set requests based on measured baseline usage |
| Liveness probe on a `/ready` endpoint | Temporary unreadiness causes container restarts unnecessarily | Use separate, independent endpoints for liveness and readiness |
