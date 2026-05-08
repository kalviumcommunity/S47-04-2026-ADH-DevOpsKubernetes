# Kubernetes Resource Management — CPU & Memory Requests and Limits

> This document explains how Kubernetes controls CPU and memory consumption at the container and namespace level, how requests affect scheduling decisions, how limits are enforced at runtime, and why proper resource configuration is essential for cluster stability in multi-tenant environments.

---

## Table of Contents

1. [Why Resource Configuration Matters](#1-why-resource-configuration-matters)
2. [Requests vs Limits — The Fundamental Distinction](#2-requests-vs-limits--the-fundamental-distinction)
3. [How CPU and Memory Behave Differently Under Pressure](#3-how-cpu-and-memory-behave-differently-under-pressure)
4. [AeroStore Resource Configuration](#4-aerostore-resource-configuration)
5. [Namespace-Level Policies: LimitRange and ResourceQuota](#5-namespace-level-policies-limitrange-and-resourcequota)
6. [Resource Management Diagram](#6-resource-management-diagram)
7. [Verification — Observing Resources at Runtime](#7-verification--observing-resources-at-runtime)
8. [Scenario: The Noisy Neighbor Problem](#8-scenario-the-noisy-neighbor-problem)
9. [Choosing the Right Values](#9-choosing-the-right-values)

---

## 1. Why Resource Configuration Matters

In a shared Kubernetes cluster, multiple applications run on the same physical nodes. Without resource configuration, any single container can consume all available CPU or memory on a Node, causing other containers on the same Node to slow down or be killed. This is called the **noisy neighbor problem**.

Additionally, without requests, the Kubernetes scheduler has no basis for making placement decisions. It may pack too many containers onto a single Node, leading to resource contention, or it may fail to spread load evenly across the cluster.

Resource configuration solves both problems:
- **Requests** give the scheduler the information it needs to make safe placement decisions
- **Limits** give the Linux kernel cgroups the boundaries it needs to enforce at runtime

---

## 2. Requests vs Limits — The Fundamental Distinction

### Resource Requests — Scheduling Guarantee

**Requests are promises to the scheduler.** When you set `cpu: "100m"` as a request, you are telling Kubernetes: *"This container needs at least 100 millicores of CPU to run correctly. Please only schedule me on a Node that has at least that much available."*

```yaml
resources:
  requests:
    cpu: "100m"      # 0.1 CPU core — the guaranteed minimum
    memory: "64Mi"   # 64 MB RAM — the guaranteed minimum
```

The scheduler sums up all resource requests on each Node and compares against the Node's allocatable capacity. A Pod is only scheduled on a Node where the sum of existing requests plus the new Pod's requests does not exceed the Node's capacity.

**Key behavior:** The container may actually use *less* than its request (that's fine) or *more* (that's where limits come in). The request is the floor for scheduling, not a runtime ceiling.

### Resource Limits — Runtime Enforcement

**Limits are enforced by the Linux kernel via cgroups.** When you set `cpu: "250m"` as a limit, the Linux kernel's CPU scheduler will not allow the container to use more than 250 millicores, regardless of how much CPU is physically available on the Node.

```yaml
resources:
  limits:
    cpu: "250m"      # Hard cap — throttled if exceeded
    memory: "128Mi"  # Hard cap — OOMKilled if exceeded
```

**Key behavior:** CPU and memory behave very differently when limits are exceeded (see Section 3).

### The Relationship Between Requests and Limits

| | Requests | Limits |
|---|---|---|
| **Who uses it** | kube-scheduler (at scheduling time) | Linux kernel cgroups (at runtime) |
| **When enforced** | Before Pod is placed on a Node | While the container is running |
| **What happens if exceeded** | N/A — requests are a floor, not a ceiling | CPU: throttled. Memory: OOMKilled |
| **Required** | Recommended (Pending if Node is full) | Recommended (unbounded without it) |
| **Rule** | Limit must be ≥ Request | Cannot set limit < request |

---

## 3. How CPU and Memory Behave Differently Under Pressure

This is the most important concept in resource management and is frequently misunderstood.

### CPU Limit Exceeded → Container is Throttled

CPU is a **compressible resource**. When a container tries to use more CPU than its limit:
- The Linux CFS (Completely Fair Scheduler) throttles the container's CPU time slices
- The container process **slows down** — responses take longer
- The container **does NOT crash** — the process keeps running
- `kubectl get pods` shows the Pod as `Running` — no visible crash event

```
Container requests 250m CPU for a computation
       ↓
CFS scheduler limits it to 250m CPU time slices
       ↓
Computation takes 4x longer than expected
       ↓
Pod is still Running — no crash, no restart
```

This can cause hard-to-diagnose latency issues. The application appears healthy but is inexplicably slow.

### Memory Limit Exceeded → Container is OOMKilled

Memory is a **non-compressible resource**. When a container exceeds its memory limit:
- The Linux OOM (Out Of Memory) killer terminates the process **immediately**
- The container exits with **exit code 137** (SIGKILL)
- Kubernetes detects the crash and **restarts the container** (kubelet behavior)
- If this repeats, the Pod enters `CrashLoopBackOff`
- `kubectl describe pod` shows `OOMKilled` in the Last State

```
Container allocates RAM beyond 128Mi limit
       ↓
Linux OOM killer sends SIGKILL
       ↓
Container exits with code 137 (OOMKilled)
       ↓
kubelet restarts the container
       ↓
If memory leak persists → CrashLoopBackOff
```

| Resource | Exceeds Limit | Effect | Pod Status |
|---|---|---|---|
| **CPU** | Throttled by CFS | Process slows down | Running (no change) |
| **Memory** | OOMKilled by kernel | Process terminated | Restarting → CrashLoopBackOff |

---

## 4. AeroStore Resource Configuration

### Backend Deployment (`backend-deployment.yaml`)

```yaml
resources:
  requests:
    cpu: "100m"      # Guaranteed scheduling minimum
    memory: "64Mi"   # Guaranteed scheduling minimum
  limits:
    cpu: "200m"      # Throttled if exceeded — 0.2 cores max
    memory: "128Mi"  # OOMKilled if exceeded — 128 MB max
```

**Reasoning:**
- nginx at idle uses ~10-20m CPU and ~20-30Mi RAM
- Requests at `100m`/`64Mi` give 5x headroom above idle — enough for moderate traffic spikes
- Limits at `200m`/`128Mi` are 2x the requests — allows bursting but prevents runaway consumption

### Resource Demo Pod (`resource-demo-pod.yaml`)

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "64Mi"
  limits:
    cpu: "250m"
    memory: "128Mi"
```

This Pod runs stably under these constraints and can be used to verify resource accounting on the node.

### Probe Demo Pod (`probe-demo-pod.yaml`)

```yaml
resources:
  requests:
    cpu: "50m"
    memory: "32Mi"
  limits:
    cpu: "100m"
    memory: "64Mi"
```

Smaller values since this is a diagnostic Pod, not a production workload.

---

## 5. Namespace-Level Policies: LimitRange and ResourceQuota

Individual Pod resource configs protect at the container level. But in a shared cluster, we also need namespace-level governance. Two Kubernetes objects provide this.

### LimitRange (`namespace-resource-policy.yaml`)

A **LimitRange** sets default and maximum resource values for all containers in a namespace:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: aerostore-limit-range
spec:
  limits:
    - type: Container
      default:          # Applied when a container has no limits
        cpu: "300m"
        memory: "256Mi"
      defaultRequest:   # Applied when a container has no requests
        cpu: "100m"
        memory: "64Mi"
      max:              # No container can exceed these
        cpu: "1000m"
        memory: "512Mi"
      min:              # No container can go below these
        cpu: "50m"
        memory: "32Mi"
```

**Why this matters:** If a developer deploys a Pod without resource configuration, the LimitRange automatically applies defaults. This eliminates the "I forgot to set resources" problem at the cluster level.

### ResourceQuota (`namespace-resource-policy.yaml`)

A **ResourceQuota** limits the total resources consumed by all Pods in a namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: aerostore-resource-quota
spec:
  hard:
    requests.cpu: "4"        # Max total CPU requests across all Pods
    requests.memory: "2Gi"   # Max total memory requests across all Pods
    limits.cpu: "8"          # Max total CPU limits across all Pods
    limits.memory: "4Gi"     # Max total memory limits across all Pods
    pods: "20"               # Max number of Pods in this namespace
```

**Why this matters:** Even with per-container limits, one namespace could spin up 100 Pods and consume all cluster resources. ResourceQuota prevents this by capping the namespace's total consumption.

---

## 6. Resource Management Diagram

![Kubernetes Resource Management Diagram](k8s-resource-management-diagram.png)

```
SCHEDULING (Requests):
                                  ┌─────────────────┐
                                  │  kube-scheduler  │
                                  └────────┬─────────┘
                     Pod requests:         │  Finds Node with
                     cpu: 500m             │  enough unallocated
                     memory: 256Mi         │  requests capacity
                                  ┌────────┴───┬──────────────┐
                                  ▼            ▼              ▼
                            ┌──────────┐ ┌──────────┐ ┌──────────┐
                            │  Node A  │ │  Node B  │ │  Node C  │
                            │ 4CPU/8GB │ │ 200m/    │ │ Full     │
                            │ avail ✓  │ │ 100Mi ✗  │ │ ✗        │
                            └──────────┘ └──────────┘ └──────────┘
                            SCHEDULED        SKIP          SKIP

RUNTIME ENFORCEMENT (Limits):

CPU limit exceeded:          Memory limit exceeded:
container throttled          container OOMKilled
process slows down           exit code 137
does NOT crash               kubelet restarts it
```

---

## 7. Verification — Observing Resources at Runtime

### Apply the Demo Pod

```bash
kubectl apply -f k8s/basics/resource-demo-pod.yaml
kubectl apply -f k8s/basics/namespace-resource-policy.yaml
```

### Check Resource Configuration on the Pod

```bash
# See requests and limits assigned to the pod
kubectl describe pod resource-demo | grep -A 10 "Limits:\|Requests:"
# Output:
# Limits:
#   cpu:     250m
#   memory:  128Mi
# Requests:
#   cpu:     100m
#   memory:  64Mi
```

### Check Actual Live Resource Usage

```bash
# Requires metrics-server to be installed in the cluster
kubectl top pod resource-demo
# NAME            CPU(cores)   MEMORY(bytes)
# resource-demo   2m           4Mi    ← well under limits — running stably
```

### Check Node Resource Accounting

```bash
# See how much of the node is allocated vs available
kubectl describe node | grep -A 20 "Allocated resources:"
# Allocated resources:
#   Resource           Requests   Limits
#   cpu                550m       950m
#   memory             256Mi      640Mi
```

### Check ResourceQuota Usage

```bash
kubectl describe resourcequota aerostore-resource-quota
# Name:             aerostore-resource-quota
# Resource          Used   Hard
# --------          ----   ----
# limits.cpu        950m   8
# limits.memory     640Mi  4Gi
# pods              5      20
# requests.cpu      550m   4
# requests.memory   256Mi  2Gi
```

---

## 8. Scenario: The Noisy Neighbor Problem

**Scenario:** An application runs fine in development, but when deployed to a shared cluster it causes other applications to slow down or crash.

### Root Cause: No Resource Configuration

In development, the app runs alone on a dedicated machine. It can use all available CPU and memory freely. In a shared cluster, without resource configuration:

1. **Scheduler packs pods arbitrarily.** Without requests, the scheduler has no information about how much CPU or memory the container needs. It may place many containers on a single Node that can't actually support them all.

2. **No limits = unbounded consumption.** A container without limits can consume all CPU and memory on a Node. When this happens, other containers on the same Node are starved — they get CPU throttled or are OOMKilled even though their own resource configuration is correct.

3. **Memory pressure cascades.** When one container on a Node consumes all available memory, the Linux kernel begins OOMKilling processes on that Node — choosing victims based on priority and memory usage. Other well-behaved containers can be killed to free memory for the unconstrained one.

### The Fix: Proper Requests and Limits

```yaml
# Before (causes noisy neighbor problem):
containers:
  - name: my-app
    image: my-app:latest
    # No resource configuration — unbounded, unpredictable

# After (cluster-safe):
containers:
  - name: my-app
    image: my-app:latest
    resources:
      requests:
        cpu: "200m"      # Scheduler knows this Pod needs 0.2 CPU
        memory: "128Mi"  # Scheduler knows this Pod needs 128 MB
      limits:
        cpu: "500m"      # Container cannot consume more than 0.5 CPU
        memory: "256Mi"  # Container cannot consume more than 256 MB
```

With proper configuration:
- The scheduler distributes Pods across Nodes based on actual capacity
- No single container can starve others by consuming unbounded resources
- If a container has a memory leak, it is OOMKilled and restarted — it does not take down the Node
- CPU-heavy computation is throttled, not allowed to crowd out other workloads

---

## 9. Choosing the Right Values

There is no universal formula, but these principles guide good choices:

| Principle | Guidance |
|---|---|
| **Profile before setting** | Run `kubectl top pods` to measure actual usage, then set requests ~2x actual idle usage |
| **Requests should reflect average usage** | Not peak, not minimum — the scheduler uses requests to determine fit |
| **Limits should allow for bursting** | Set limits at 2-3x requests to allow traffic spikes without OOMKilling |
| **Memory limits require extra care** | Set too low → constant OOMKilled. Set too high → noisy neighbor risk |
| **CPU throttling is preferable to OOMKill** | Better to be slow than dead — err slightly conservative on CPU limits |
| **Use LimitRange as a safety net** | Enforce default limits at the namespace level so unconfigured Pods are never unbounded |
| **Review and adjust over time** | Resource needs change as traffic grows — monitor and update regularly |
