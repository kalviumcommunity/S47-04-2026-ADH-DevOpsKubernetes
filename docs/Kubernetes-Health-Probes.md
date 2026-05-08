# Kubernetes Health Probes — Liveness, Readiness & Startup

> This document explains how Kubernetes health probes make applications self-healing and reliable — specifically how liveness probes trigger container restarts, readiness probes control traffic routing, and how the two work together to protect users during failure conditions.

---

## Table of Contents

1. [Why Health Probes Exist](#1-why-health-probes-exist)
2. [The Three Probes and What They Do](#2-the-three-probes-and-what-they-do)
3. [Probe Configuration in AeroStore](#3-probe-configuration-in-aerostore)
4. [The Critical Difference: Restart vs Traffic Removal](#4-the-critical-difference-restart-vs-traffic-removal)
5. [Health Probes Diagram](#5-health-probes-diagram)
6. [Demonstrating Probe Failures](#6-demonstrating-probe-failures)
7. [Scenario: Bad State + Slow Restart — Using Both Probes](#7-scenario-bad-state--slow-restart--using-both-probes)
8. [Common Misconfigurations to Avoid](#8-common-misconfigurations-to-avoid)

---

## 1. Why Health Probes Exist

Kubernetes knows when a container process **crashes** — when the process exits, the kubelet detects it immediately and restarts the container. But a container process can be running and still be completely broken:

- The HTTP server is alive but stuck in a deadlock and returning no responses
- The application connected to a database that went offline and is now returning errors on every request
- The server is handling requests but so slowly that users are timing out
- The app just restarted and is still warming up — not ready to serve traffic yet

In all these cases, the container process is running (`kubectl get pods` shows `Running`), but the application is not actually healthy. **Health probes are how Kubernetes detects this gap** between "the process is running" and "the application is working correctly."

---

## 2. The Three Probes and What They Do

### Startup Probe — "Has the app finished initializing?"

The startup probe runs **first**, and both liveness and readiness probes are **disabled** until it passes. This is critical for applications that have a slow startup (database migrations, JVM warmup, large cache loading).

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 80
  failureThreshold: 30   # Allow 30 retries
  periodSeconds: 10      # Every 10 seconds = up to 300 seconds total
```

**If it fails `failureThreshold` times:** The container is killed and restarted. If it passes: control is handed to liveness and readiness probes.

---

### Liveness Probe — "Is the container still alive?"

The liveness probe answers: *Is this container in a state where it can ever recover on its own?*

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 80
  initialDelaySeconds: 15
  periodSeconds: 20
  timeoutSeconds: 5
  failureThreshold: 3
```

**If it fails `failureThreshold` times (3 × 20s = 60 seconds):**
→ **kubelet kills and restarts the container**

The key insight is that a liveness failure means the container is in a state it cannot fix itself. Restarting it is the only option. This is appropriate for:
- Deadlocks inside the application
- Corrupted in-memory state
- Infinite loops blocking all request processing
- The process getting stuck on a blocking I/O call

**Failure action: RESTART** — this causes a brief interruption to that Pod, but the other replicas continue serving traffic.

---

### Readiness Probe — "Is the container ready to receive traffic?"

The readiness probe answers: *Should this container receive user traffic right now?*

```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: 80
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
```

**If it fails `failureThreshold` times (3 × 10s = 30 seconds):**
→ **Pod is removed from the Service's endpoint list — traffic stops being routed to it**
→ **The container is NOT restarted**

When the probe passes again, the Pod is automatically re-added to the Service and traffic resumes. This is appropriate for:
- App still warming up after a restart (caches loading, connections establishing)
- A downstream dependency (database, cache) temporarily unavailable
- The container is too overloaded to handle more requests right now
- Performing a configuration reload

**Failure action: STOP TRAFFIC** — the container keeps running, waiting to recover, and rejoins the load balancer when healthy.

---

## 3. Probe Configuration in AeroStore

Both probes are configured in `k8s/basics/backend-deployment.yaml` and demonstrated in `k8s/basics/probe-demo-pod.yaml`.

### Backend Deployment (`backend-deployment.yaml`)

```yaml
startupProbe:
  httpGet:
    path: /
    port: 80
  failureThreshold: 30     # Gives container up to 300s to start
  periodSeconds: 10

livenessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 15  # Wait for startup to complete
  periodSeconds: 20        # Check every 20 seconds
  timeoutSeconds: 5        # 5-second response deadline
  failureThreshold: 3      # Restart after 3 consecutive failures (60s)
  successThreshold: 1

readinessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 10  # Start checking 10s after container start
  periodSeconds: 10        # Check every 10 seconds
  timeoutSeconds: 3        # 3-second response deadline
  failureThreshold: 3      # Remove from Service after 3 failures (30s)
  successThreshold: 1
```

### Why `initialDelaySeconds` and `startupProbe` Together?

Using `initialDelaySeconds` alone is a rough estimate — you hardcode a wait time that may be too short (causing premature probe failures) or too long (delaying traffic routing unnecessarily). `startupProbe` is the production-grade solution: it dynamically waits for the actual startup to complete before handing off to liveness and readiness probes.

---

## 4. The Critical Difference: Restart vs Traffic Removal

| | Liveness Probe Failure | Readiness Probe Failure |
|---|---|---|
| **Action** | Container **RESTARTED** | Pod **REMOVED FROM SERVICE** |
| **Pod status** | Brief interruption, then comes back | Still Running, just not receiving traffic |
| **Traffic impact** | Other replicas absorb traffic during restart | This replica's traffic moves to other replicas immediately |
| **Recovery** | Automatic restart (ReplicaSet ensures it comes back) | Probe passes again → automatically re-added to Service |
| **Use for** | Irrecoverable bad state (deadlocks) | Temporary unreadiness (warming up, dependencies) |
| **Risk if misconfigured** | Too aggressive → unnecessary restarts cascade | Too aggressive → healthy pods removed from traffic |

---

## 5. Health Probes Diagram

![Kubernetes Health Probes Diagram](k8s-health-probes-diagram.png)

```
Container starts
       │
       ▼
┌──────────────────────────────┐
│       startupProbe           │  "Is initialization done?"
│   httpGet / every 10s        │
│   failureThreshold: 30       │  ← blocks other probes until PASS
└──────────────┬───────────────┘
               │ PASSES
      ┌────────┴────────┐
      ▼                 ▼
┌─────────────┐   ┌──────────────────┐
│ livenessProbe│   │ readinessProbe   │
│ "Alive?"    │   │ "Ready for       │
│             │   │  traffic?"       │
│ FAIL ↓      │   │ FAIL ↓           │
│ RESTART     │   │ REMOVE FROM SVC  │
│ container   │   │ (no restart)     │
└─────────────┘   └──────────────────┘
       ↑                   ↑
 Fixes bad state     Protects users
 (deadlock, etc.)    (warming up, etc.)
```

---

## 6. Demonstrating Probe Failures

### Setup

```bash
# Apply the demo pod
kubectl apply -f k8s/basics/probe-demo-pod.yaml

# Watch its status in real-time
kubectl get pods probe-demo -w
```

### Demonstrating Readiness Probe Failure (Traffic Removal)

```bash
# Break the readiness endpoint by removing the index file nginx serves
kubectl exec probe-demo -- mv /usr/share/nginx/html/index.html /tmp/
# nginx now returns 403 for GET / → readinessProbe fails

# Watch the Pod get removed from endpoints (no longer receives traffic)
# The STATUS stays "Running" but READY column changes to 0/1
kubectl get pods probe-demo
# NAME         READY   STATUS    RESTARTS
# probe-demo   0/1     Running   0     ← NOT restarted, just not ready

# Restore — the probe passes again and the Pod is re-added automatically
kubectl exec probe-demo -- mv /tmp/index.html /usr/share/nginx/html/
```

### Observing Liveness Probe Events

```bash
# View probe-related events and restart counts
kubectl describe pod probe-demo

# Look for events like:
# Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 403
# Normal   Killing    Container probe-demo failed liveness probe, will be restarted

# Check the restart count (increases each time liveness fails)
kubectl get pods probe-demo
# NAME         READY   STATUS    RESTARTS
# probe-demo   1/1     Running   2     ← restarted twice due to liveness failures
```

### Checking Endpoints (Readiness Effect on Service)

```bash
# After readinessProbe fails, the Pod IP disappears from Service endpoints
kubectl get endpoints

# After probe recovers, Pod IP reappears automatically
```

---

## 7. Scenario: Bad State + Slow Restart — Using Both Probes

**Scenario:** The application starts successfully but after a few minutes enters a bad state (e.g., deadlock). When it restarts, it takes 45+ seconds to initialize.

### Which probe detects the "bad state"?

The **liveness probe**. After the application enters its deadlocked state, it stops responding to HTTP requests. The liveness probe detects this after `failureThreshold` consecutive failures and tells kubelet to restart the container. The readiness probe alone would only remove the pod from traffic — the deadlocked container would never recover without a restart.

### Which probe controls when traffic resumes?

The **readiness probe**. After the container restarts, it takes 45 seconds to initialize. During this time, the readiness probe is failing (the app isn't ready yet), so no traffic is sent to this Pod — users are protected from hitting a half-started server. Only when the app fully initializes and the readiness probe passes does traffic start flowing to it again.

### What if only a liveness probe were used?

The liveness probe would restart the container when it enters the bad state — that part is correct. But without a readiness probe, Kubernetes has no way to know when the restarted container has finished its 45-second initialization. Traffic would be routed to the Pod immediately after the container process starts, even while it's still warming up. Users would get connection errors or incomplete responses for 45 seconds after every restart.

### How both probes together solve the problem

```
App enters bad state (deadlock)
           ↓
livenessProbe fails 3 times
           ↓
kubelet restarts the container
           ↓
Container starts — but initialization takes 45s
           ↓
readinessProbe fails during those 45 seconds
           ↓
Traffic routes to other healthy replicas — users see no errors
           ↓
After 45s: app is ready, readinessProbe passes
           ↓
Pod re-added to Service — traffic resumes
           ↓
User experience: seamless
```

This is why **both probes together are essential for production workloads**. Liveness fixes the broken state. Readiness protects users during the recovery window.

---

## 8. Common Misconfigurations to Avoid

| Misconfiguration | Consequence | Fix |
|---|---|---|
| `initialDelaySeconds` too short | Probe fails before app is ready → immediate restart → `CrashLoopBackOff` | Use `startupProbe` for slow-starting apps |
| Same endpoint for liveness and readiness | A temporary dependency failure triggers a restart instead of just traffic removal | Use separate endpoints: `/healthz` (liveness) and `/ready` (readiness) |
| `failureThreshold: 1` on liveness | One slow response restarts the container — too aggressive for production | Use `failureThreshold: 3` minimum to allow for transient slowness |
| No readiness probe on slow-starting apps | Traffic hits Pod before it's initialized → user errors on every deploy | Always define readiness probe on any Pod that takes time to warm up |
| Liveness probe hitting an endpoint that calls external dependencies | DB goes down → liveness fails → entire fleet restarts at once | Liveness should only check internal app health, not dependencies |
