# Kubernetes Scaling — Manual Scaling & Horizontal Pod Autoscaler (HPA)

> This document explains how Kubernetes scales applications in response to changing demand — through deliberate manual control and through automatic metric-driven scaling — and why the combination of both is essential for production reliability.

---

## Table of Contents

1. [Why Scaling Matters](#1-why-scaling-matters)
2. [Manual Scaling — Direct Replica Control](#2-manual-scaling--direct-replica-control)
3. [Horizontal Pod Autoscaler (HPA)](#3-horizontal-pod-autoscaler-hpa)
4. [How HPA Makes Scaling Decisions](#4-how-hpa-makes-scaling-decisions)
5. [AeroStore HPA Configuration](#5-aerostore-hpa-configuration)
6. [Scaling Behavior Diagram](#6-scaling-behavior-diagram)
7. [Verification — Observing Scaling in Action](#7-verification--observing-scaling-in-action)
8. [Scenario: Predictable Spikes + HPA vs Manual](#8-scenario-predictable-spikes--hpa-vs-manual)
9. [Manual Scaling vs Autoscaling — When to Use Each](#9-manual-scaling-vs-autoscaling--when-to-use-each)

---

## 1. Why Scaling Matters

A web application's traffic is rarely constant. It peaks at lunch, drops at night, surges on product launches, and collapses on weekends. Running enough replicas to handle peak traffic all the time wastes money during quiet periods. Running only enough for average traffic means requests fail during spikes.

Kubernetes solves this with two complementary mechanisms:
- **Manual scaling:** You decide the exact replica count, instantly.
- **Autoscaling (HPA):** Kubernetes watches metrics and decides the replica count automatically, continuously.

Both target the same thing: the Deployment's `spec.replicas` field.

---

## 2. Manual Scaling — Direct Replica Control

Manual scaling is the simplest form of scaling. You tell the Deployment how many replicas you want, and Kubernetes makes it happen immediately.

### How It Works

```bash
# Scale up to 5 replicas
kubectl scale deployment aerostore-backend --replicas=5

# Scale down to 2 replicas
kubectl scale deployment aerostore-backend --replicas=2
```

Kubernetes reconciles the current Pod count to match the desired count:
- **Scaling up:** ReplicaSet creates new Pods. Scheduler places them on available Nodes. Ready within ~10-30 seconds.
- **Scaling down:** ReplicaSet terminates excess Pods gracefully (SIGTERM → 30s grace period → SIGKILL).

### Alternatively, in the Deployment YAML

```yaml
spec:
  replicas: 5   # Change this value and apply
```

```bash
kubectl apply -f k8s/basics/backend-deployment.yaml
```

### When Manual Scaling Is Appropriate

- **Scheduled events:** "We have a product launch at 2pm — scale to 10 replicas at 1:50pm."
- **One-time capacity adjustments:** Migrating data, running a batch job, expected traffic doubling.
- **Development and testing:** Deliberately testing with a specific replica count.
- **Overriding HPA:** Temporarily pinning a replica count during an incident.

### Why Manual Scaling Is Insufficient for Dynamic Traffic

- Requires a human to be watching metrics
- Reaction time is minutes (human decision latency + command execution)
- Not self-correcting — traffic can spike and drop before a human responds
- Doesn't scale down automatically when traffic drops (wastes compute cost)

---

## 3. Horizontal Pod Autoscaler (HPA)

The Horizontal Pod Autoscaler is a Kubernetes controller that **continuously watches resource metrics and automatically adjusts the replica count** of a Deployment to keep metrics at a target value.

### What HPA Is NOT

- HPA does **not** add more nodes (that is Cluster Autoscaler's job)
- HPA does **not** scale based on custom business metrics by default (requires Custom Metrics Adapter)
- HPA is **not** instant — there is a built-in stabilization delay to prevent thrashing

### What HPA Targets

| Metric Type | Example | Requires |
|---|---|---|
| **CPU Utilization** | Keep avg CPU at 50% of request | Metrics Server |
| **Memory Utilization** | Keep avg memory at 70% of request | Metrics Server |
| **Custom Metrics** | Requests per second, queue depth | Custom Metrics Adapter |
| **External Metrics** | SQS queue length, Pub/Sub lag | External Metrics Adapter |

For most workloads, **CPU utilization is the correct and simplest metric**. CPU pressure directly reflects whether a Pod is handling more requests than it can efficiently process.

---

## 4. How HPA Makes Scaling Decisions

### The Control Loop

Every 15 seconds, the HPA controller:

1. **Queries the Metrics Server** for the current CPU utilization of each Pod
2. **Calculates the average** across all current replicas
3. **Applies the scaling formula:**

```
desiredReplicas = ceil(currentReplicas × (currentMetricValue / targetMetricValue))
```

**Example — Scaling Up:**
```
currentReplicas     = 2
currentCPU (avg)    = 80%
targetCPU           = 50%
desiredReplicas     = ceil(2 × (80 / 50))
                    = ceil(2 × 1.6)
                    = ceil(3.2)
                    = 4
```
HPA updates the Deployment to 4 replicas.

**Example — Scaling Down:**
```
currentReplicas     = 4
currentCPU (avg)    = 20%
targetCPU           = 50%
desiredReplicas     = ceil(4 × (20 / 50))
                    = ceil(4 × 0.4)
                    = ceil(1.6)
                    = 2
```
HPA wants to go to 2 replicas, but waits for the stabilization window (5 min) before acting.

### Stabilization Windows — Preventing Thrashing

Traffic is noisy. A 10-second spike to 80% CPU should not cause a scale-up that then triggers a scale-down cycle 2 minutes later. HPA uses stabilization windows:

- **Scale-up stabilization (30s):** Must stay above threshold for 30s before scaling up. Prevents reacting to instant spikes.
- **Scale-down stabilization (300s):** Must stay below threshold for 5 minutes before scaling down. Prevents yo-yo scaling.

### Replica Bounds — Protecting the Application and Cluster

```yaml
minReplicas: 2   # Never go below — ensures availability even at zero traffic
maxReplicas: 8   # Never go above — prevents runaway scaling bankrupting the cluster
```

- **minReplicas:** HPA never scales below this, even if CPU drops to 0%. Without a minimum, a quiet period could scale the app to 0 replicas, causing a cold-start delay when traffic returns.
- **maxReplicas:** HPA never scales above this, even if CPU reaches 100%. Without a maximum, a traffic spike could trigger hundreds of new Pods, exhausting Node resources and crashing other workloads.

---

## 5. AeroStore HPA Configuration

### `k8s/basics/backend-hpa.yaml`

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: aerostore-backend-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: aerostore-backend
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50   # Scale when avg CPU > 50% of cpu request
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - type: Pods
          value: 2           # Add at most 2 Pods per 30-second window
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300   # Wait 5 minutes before scaling down
      policies:
        - type: Pods
          value: 1           # Remove at most 1 Pod per 60-second window
          periodSeconds: 60
```

### Why These Values

| Parameter | Value | Reasoning |
|---|---|---|
| `targetCPU` | 50% | Leaves 50% headroom for traffic spikes while new Pods are being created |
| `minReplicas` | 2 | Always-available redundancy; 1 replica = no HA |
| `maxReplicas` | 8 | 4× the base count; capped to prevent ResourceQuota exhaustion |
| `scaleUp.stabilization` | 30s | Fast reaction to genuine load spikes |
| `scaleDown.stabilization` | 300s | Slow scale-down to avoid thrashing during variable traffic |
| `scaleUp policy` | +2 pods / 30s | Adds capacity in steps rather than all at once |
| `scaleDown policy` | -1 pod / 60s | Gentle reduction to keep spare capacity for traffic rebounds |

### Why 50% CPU Target (Not 80% or 90%)?

If you target 80% CPU and a spike arrives, by the time HPA triggers a scale-up (~30 seconds), schedules new Pods (~10 seconds), and the Pods become ready (~15 seconds), your existing Pods have been at 80%+ for almost a minute. User responses have been slow or failing the entire time.

At 50% target, there is a 30% CPU buffer available when traffic first spikes. New Pods come online before the existing ones are fully saturated.

---

## 6. Scaling Behavior Diagram

![Kubernetes Scaling and HPA Diagram](k8s-scaling-hpa-diagram.png)

```
MANUAL SCALING:

kubectl scale --replicas=5
        ↓
Deployment.spec.replicas = 5
        ↓
ReplicaSet creates 3 new Pods immediately
        ↓
Pods scheduled → pulled → running (~30s)

AUTOSCALING (HPA):

Metrics Server → collects CPU from each Pod every 15s
        ↓
HPA Controller reads metrics every 15s
        ↓
currentCPU (80%) > targetCPU (50%)
        ↓
desiredReplicas = ceil(2 × 80/50) = 4
        ↓
HPA updates Deployment.spec.replicas = 4
        ↓
ReplicaSet creates 2 new Pods
        ↓
Traffic drops → CPU falls → stabilization 5min → scales back to 2

REPLICA BOUNDS:
minReplicas=2 ←──── HPA never goes below ────→ maxReplicas=8
```

---

## 7. Verification — Observing Scaling in Action

### Check Current HPA State

```bash
kubectl get hpa aerostore-backend-hpa

# Output:
# NAME                    REFERENCE                    TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
# aerostore-backend-hpa   Deployment/aerostore-backend  22%/50%   2         8         2          5m
```

- `TARGETS`: `current%/target%` — when current > target, scale-up triggers
- `REPLICAS`: current active replicas

### Demonstrate Manual Scaling

```bash
# Scale up
kubectl scale deployment aerostore-backend --replicas=5
kubectl get pods -l app=backend -w    # Watch Pods being created

# Scale back
kubectl scale deployment aerostore-backend --replicas=2
kubectl get pods -l app=backend -w    # Watch Pods terminating
```

### Simulate Load (Trigger HPA Scale-Up)

```bash
# Start load generator
kubectl run load-generator \
  --image=busybox:1.28 --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://aerostore-backend-service:3001; done"

# Watch HPA respond (takes ~60-90s for metrics to propagate and scale-up to occur)
kubectl get hpa aerostore-backend-hpa -w

# View scale-up events
kubectl describe hpa aerostore-backend-hpa | grep -A5 "Events:"

# Clean up load generator
kubectl delete pod load-generator
```

### View Scaling Events

```bash
kubectl get events --sort-by='.lastTimestamp' | grep -i "scale\|hpa"

# Example event:
# Normal  SuccessfulRescale  HPA: New size: 4
# reason: cpu resource utilization (percentage of request) above target
```

---

## 8. Scenario: Predictable Spikes + HPA vs Manual

**Scenario:** The application experiences low traffic most of the day but sudden spikes during specific hours (lunch rush, end-of-business). Manual scaling is being used but is difficult to manage.

### Why Manual Scaling Fails Here

1. **Human latency:** By the time someone notices the spike, checks the metrics, decides to scale, and runs the command, 2-5 minutes have passed. Users experienced slow or failed requests the entire time.

2. **Scale-down is forgotten:** After the spike, someone has to remember to scale back down. If they don't, you pay for unused capacity until the next incident.

3. **No self-correction:** If traffic spikes at 3am when no one is watching, the app stays undersized until someone wakes up.

4. **Unpredictable spikes:** "Predictable" spikes can still be variable — launch 30 minutes early, traffic builds faster than expected. Manual scaling can't adapt in real time.

### How HPA Solves This

With HPA configured to `minReplicas: 2`, `maxReplicas: 8`, `targetCPU: 50%`:

- **During quiet periods:** CPU averages ~20%, HPA keeps 2 replicas. Cost is minimized.
- **As traffic builds:** CPU climbs to 55%. HPA formula: `ceil(2 × 55/50)` = 3 replicas. New Pod scheduled within 30 seconds, ready within ~60 seconds. Still within the spike window.
- **At peak:** CPU might reach 70% briefly. HPA scales to 4, then 6 replicas in successive windows. Application stays responsive.
- **As spike ends:** Traffic drops, CPU falls. HPA waits 5 minutes (stabilization window) then removes 1 Pod per minute until back to 2. No human action required.

### What the Metric (CPU) Tells HPA

CPU utilization is the proxy for "is this Pod busy serving requests?". When each Pod's CPU climbs above the target, it means each Pod is processing more requests than it was sized for. Adding more Pods distributes that load and brings per-Pod CPU back down to the target.

### How minReplicas and maxReplicas Protect the System

- **minReplicas: 2** — even at 3am with zero traffic, there are always 2 replicas ready. When traffic arrives (even suddenly), there is no cold-start delay. The first request is served immediately.
- **maxReplicas: 8** — if a traffic spike is extreme (DDoS, viral event), HPA cannot create more than 8 Pods. This prevents exhausting Node resources, triggering the ResourceQuota limit, or causing cascading failures in other namespaces. The app gracefully degrades rather than taking down the cluster.

---

## 9. Manual Scaling vs Autoscaling — When to Use Each

| Situation | Recommendation |
|---|---|
| Known, scheduled event (product launch) | **Manual:** Scale up pre-emptively before the event |
| Unpredictable, variable traffic | **HPA:** Let metrics drive the decision |
| Development / testing | **Manual:** Pin to a specific count for reproducibility |
| Production steady-state | **HPA:** Always-on, continuous adjustment |
| Incident response (override HPA) | **Manual:** Temporarily force a specific count, disable HPA |
| Post-launch scale-down | **HPA + minReplicas:** Set a higher minimum during launch, then reduce it |
| Traffic spike at off-hours | **HPA:** No human needed — reacts automatically |

**Best practice:** Use HPA in production with a `minReplicas` set to your baseline capacity (not zero), and `maxReplicas` capped at what your Node pool and ResourceQuota can support. Use manual scaling for pre-planned events and incident overrides.
