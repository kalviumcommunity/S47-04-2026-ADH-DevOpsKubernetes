# Kubernetes Cluster Architecture — How K8s Is Internally Structured

> This document goes beyond *why* Kubernetes exists (covered in [Kubernetes-Foundations-And-Cloud-Native.md](./Kubernetes-Foundations-And-Cloud-Native.md)) and explains **how a Kubernetes cluster is composed internally** — the control plane, worker nodes, and the communication loop that keeps applications running reliably.

---

## Table of Contents

1. [What Is a Kubernetes Cluster?](#1-what-is-a-kubernetes-cluster)
2. [The Two Halves: Control Plane vs Worker Nodes](#2-the-two-halves-control-plane-vs-worker-nodes)
3. [Control Plane Components — The Brain](#3-control-plane-components--the-brain)
4. [Worker Node Components — The Muscle](#4-worker-node-components--the-muscle)
5. [How They Talk: The Interaction Loop](#5-how-they-talk-the-interaction-loop)
6. [Walking Through a Real Deployment](#6-walking-through-a-real-deployment)
7. [Failure Scenarios and Self-Healing](#7-failure-scenarios-and-self-healing)
8. [Mapping Our AeroStore Project to the Architecture](#8-mapping-our-aerostore-project-to-the-architecture)
9. [Key Architectural Takeaways](#9-key-architectural-takeaways)

---

## 1. What Is a Kubernetes Cluster?

A Kubernetes cluster is **a set of machines (nodes) that collectively run containerized applications under Kubernetes' management**. At minimum, a cluster has:

- **At least one control plane node** — makes all scheduling and lifecycle decisions.
- **One or more worker nodes** — actually run the application containers.

Even a local setup like Minikube simulates both roles on a single machine.

```
┌────────────────────── Kubernetes Cluster ──────────────────────┐
│                                                                 │
│   ┌──────────────────┐     ┌──────────────┐ ┌──────────────┐   │
│   │  Control Plane   │     │  Worker       │ │  Worker       │  │
│   │  (the brain)     │────►│  Node 1       │ │  Node 2       │  │
│   │                  │────►│  (the muscle) │ │  (the muscle) │  │
│   └──────────────────┘     └──────────────┘ └──────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Why the split?** Separating management from execution means you can scale workers without touching the brain, and the brain can replace or reschedule work across any available worker. This is the same principle as a restaurant: the kitchen manager (control plane) decides what gets cooked and when, while the line cooks (workers) do the actual cooking.

---

## 2. The Two Halves: Control Plane vs Worker Nodes

| Aspect | Control Plane | Worker Node |
|---|---|---|
| **Role** | Decides *what* should run and *where* | Actually *runs* the workloads |
| **Contains** | API Server, Scheduler, Controller Manager, etcd | Kubelet, Kube-proxy, Container Runtime |
| **Handles failures by** | Detecting them and issuing corrective orders | Executing those orders (restart containers, etc.) |
| **Quantity** | Usually 1 (dev) or 3+ (production HA) | 1 to thousands depending on scale |
| **User interacts with** | Yes — via `kubectl` commands sent to API Server | No — indirectly through the control plane |

The control plane is never where your application Pods run (in production). It only manages. The workers are where actual CPU and memory are consumed by your apps.

---

## 3. Control Plane Components — The Brain

The control plane is not one monolithic process. It is **five distinct components**, each with a single responsibility.

### 3.1 kube-apiserver — The Front Door

```
kubectl ───► kube-apiserver ───► etcd
                 │
    Dashboard ───┘
    CI/CD ───────┘
```

- **What it does:** The single entry point for all cluster operations. Every `kubectl` command, every dashboard click, every CI/CD deployment — they all hit the API Server.
- **Why it matters:** It validates and authenticates every request before anything happens. No component talks to etcd directly except the API Server.
- **Architectural role:** It's the **gatekeeper**. If the API Server is down, nothing in the cluster can be created, updated, or queried — but existing workloads keep running because workers operate independently.

**Real analogy:** The API Server is like the reception desk at a hospital. You can't just walk into surgery — you go through reception, get authenticated, and get directed to the right department.

### 3.2 etcd — The Single Source of Truth

- **What it does:** A distributed key-value store that holds **all cluster state** — every Deployment, every Pod spec, every ConfigMap, every Secret.
- **Why it matters:** If etcd is lost without backup, the entire cluster's configuration is gone. The running containers might keep working, but Kubernetes loses all memory of what *should* be running.
- **Architectural role:** It's the **database** of the cluster. Not application data — cluster metadata.

```
etcd stores:
├── /registry/deployments/default/backend     → desired state
├── /registry/pods/default/backend-abc-xyz    → current state
├── /registry/services/default/backend-svc    → networking rules
└── /registry/secrets/default/db-credentials  → encrypted config
```

**What etcd does NOT store:** Your application data, container logs, or Docker images. It only stores Kubernetes object definitions.

### 3.3 kube-scheduler — The Matchmaker

- **What it does:** When a new Pod is created but has no node assigned, the scheduler picks the best node for it.
- **How it decides:** It evaluates every available worker node based on:
  - Does the node have enough CPU/memory? (resource requests)
  - Does the Pod require a specific node label? (node affinity)
  - Should this Pod avoid running on the same node as another Pod? (anti-affinity)
  - Are there taints on the node that the Pod doesn't tolerate?
- **Architectural role:** It's the **placement engine**. It doesn't run the Pod — it just assigns it to a node. The kubelet on that node then starts it.

```
New Pod created (no node assigned)
         │
         ▼
  kube-scheduler evaluates nodes:
  ┌──────────────────────────────────────────────┐
  │ Node 1: 4 CPU free, 8GB RAM ── Score: 85     │
  │ Node 2: 1 CPU free, 2GB RAM ── Score: 30     │
  │ Node 3: 6 CPU free, 12GB RAM ── Score: 92  ◄─── Winner │
  └──────────────────────────────────────────────┘
         │
         ▼
  Pod assigned to Node 3
```

### 3.4 kube-controller-manager — The Enforcer

- **What it does:** Runs a collection of **control loops** (controllers) that continuously watch cluster state and correct any drift between *desired state* and *actual state*.
- **Key controllers bundled inside:**

| Controller | What It Watches | What It Does |
|---|---|---|
| **ReplicaSet Controller** | Number of running Pods vs desired count | Creates or deletes Pods to match |
| **Deployment Controller** | Deployment spec changes | Orchestrates rolling updates and rollbacks |
| **Node Controller** | Node heartbeats | Marks nodes as unhealthy if heartbeats stop |
| **Job Controller** | Job completion status | Ensures batch jobs run to completion |
| **Endpoint Controller** | Pod IPs + Service selectors | Updates Service endpoints when Pods appear/disappear |

- **Architectural role:** It's the **reconciliation engine**. The entire philosophy of Kubernetes — "declare desired state, let the system converge" — is implemented by these controllers.

```
Desired state: replicas = 3
Actual state:  2 pods running (one crashed)
         │
         ▼
ReplicaSet Controller detects mismatch
         │
         ▼
Creates 1 new Pod → Scheduler assigns node → Kubelet starts it
         │
         ▼
Actual state: 3 pods running ✓ (matches desired)
```

### 3.5 cloud-controller-manager (Optional)

- **What it does:** Integrates with cloud provider APIs (AWS, GCP, Azure) to provision cloud-specific resources.
- **Examples:** Creating a cloud load balancer when you create a `LoadBalancer` Service, attaching cloud disks for `PersistentVolumes`.
- **When it's relevant:** Only in cloud-hosted clusters. Not present in Minikube or bare-metal clusters.

---

## 4. Worker Node Components — The Muscle

Every worker node runs three components that make it capable of hosting Pods.

### 4.1 kubelet — The Node Agent

```
Control Plane ──► kubelet ──► Container Runtime ──► Your Container
                    │
                    └──► Reports back: "Pod is healthy / Pod crashed"
```

- **What it does:** The primary agent on every worker node. It receives Pod specifications from the API Server and ensures the described containers are running and healthy.
- **Responsibilities:**
  - Pulls container images (via the container runtime)
  - Starts and stops containers
  - Executes liveness and readiness probes
  - Reports node status and Pod status back to the API Server
- **Architectural role:** It's the **executor**. The control plane decides, the kubelet acts.

**Critical detail:** The kubelet doesn't manage containers directly. It talks to the container runtime through the **Container Runtime Interface (CRI)**. This means Kubernetes isn't locked to Docker — it can use containerd, CRI-O, or any CRI-compliant runtime.

### 4.2 kube-proxy — The Network Plumber

- **What it does:** Maintains network rules on each node so that traffic to a Service reaches the correct Pod(s), no matter which node they're on.
- **How it works:** It watches the API Server for Service and Endpoint changes, then programs iptables rules (or IPVS rules) on the node to route traffic accordingly.

```
External traffic ──► Node's kube-proxy
                         │
                    iptables rules:
                    Service IP 10.96.0.1:80
                         │
              ┌──────────┼──────────┐
              ▼          ▼          ▼
          Pod 10.0.1.5  Pod 10.0.2.3  Pod 10.0.3.7
          (Node 1)      (Node 2)      (Node 3)
```

- **Architectural role:** It's the **in-cluster load balancer** and network proxy. Without it, Services wouldn't work — you'd need to track individual Pod IPs that change every time a Pod restarts.

### 4.3 Container Runtime — The Engine

- **What it does:** The low-level software that actually runs containers. It handles pulling images, creating container sandboxes, and managing the container lifecycle.
- **Common runtimes:**

| Runtime | Context |
|---|---|
| **containerd** | Default in modern Kubernetes. Industry standard. |
| **CRI-O** | Lightweight, built specifically for Kubernetes. |
| **Docker Engine** | Was the default pre-K8s v1.24. Now uses containerd under the hood. |

- **Architectural role:** The kubelet talks to it via CRI. The container runtime is intentionally swappable — Kubernetes doesn't care which one you use, as long as it speaks CRI.

---

## 5. How They Talk: The Interaction Loop

The power of Kubernetes comes from the **continuous reconciliation loop** between control plane and worker nodes. Here's the cycle:

```
┌─────────────────────────────────────────────────────────────────┐
│                   THE KUBERNETES CONTROL LOOP                    │
│                                                                  │
│  1. User declares desired state (kubectl apply)                  │
│         │                                                        │
│         ▼                                                        │
│  2. API Server validates & stores in etcd                        │
│         │                                                        │
│         ▼                                                        │
│  3. Controllers detect: desired ≠ actual                         │
│         │                                                        │
│         ▼                                                        │
│  4. Scheduler assigns unscheduled Pods to nodes                  │
│         │                                                        │
│         ▼                                                        │
│  5. Kubelet on target node pulls image & starts container        │
│         │                                                        │
│         ▼                                                        │
│  6. Kubelet reports status back to API Server → stored in etcd   │
│         │                                                        │
│         ▼                                                        │
│  7. Controllers re-check: desired == actual? ✓ Done              │
│                                              ✗ Go to step 3      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Key Communication Patterns

| From | To | Method | Purpose |
|---|---|---|---|
| `kubectl` | API Server | REST/HTTPS | User commands |
| API Server | etcd | gRPC | Read/write cluster state |
| Scheduler | API Server | Watch stream | Detect unscheduled Pods |
| Controllers | API Server | Watch stream | Detect state drift |
| Kubelet | API Server | HTTPS (pull model) | Get assigned Pod specs, report status |
| Kube-proxy | API Server | Watch stream | Get Service/Endpoint updates |

**Important architectural note:** Worker nodes never talk to etcd directly. All communication goes through the API Server. This is a security and consistency boundary — the API Server enforces RBAC, admission control, and validation before anything touches the data store.

---

## 6. Walking Through a Real Deployment

Let's trace what happens when we deploy our AeroStore backend to a cluster:

```bash
kubectl apply -f backend-deployment.yaml
```

### Step-by-Step Flow

```
                   YOU
                    │
                    │ kubectl apply -f backend-deployment.yaml
                    ▼
            ┌───────────────┐
            │  API Server   │─── 1. Validates YAML, authenticates user
            │               │─── 2. Stores Deployment object in etcd
            └───────┬───────┘
                    │
                    │ Watch event: "new Deployment created"
                    ▼
       ┌────────────────────────┐
       │ Deployment Controller  │─── 3. Sees Deployment, creates ReplicaSet
       └────────────┬───────────┘
                    │
                    │ Watch event: "new ReplicaSet, needs 2 Pods"
                    ▼
       ┌────────────────────────┐
       │ ReplicaSet Controller  │─── 4. Creates 2 Pod objects (no node yet)
       └────────────┬───────────┘
                    │
                    │ Watch event: "2 Pods with no node assigned"
                    ▼
         ┌──────────────────┐
         │   Scheduler      │─── 5. Evaluates nodes, assigns Pod → Node
         └────────┬─────────┘
                  │
        ┌─────────┴─────────┐
        ▼                   ▼
  ┌───────────┐      ┌───────────┐
  │  Node 1   │      │  Node 2   │
  │  kubelet  │      │  kubelet  │
  │           │      │           │
  │ 6. Pulls  │      │ 6. Pulls  │
  │    image  │      │    image  │
  │ 7. Starts │      │ 7. Starts │
  │    container     │    container
  │ 8. Runs   │      │ 8. Runs   │
  │    probes │      │    probes │
  │ 9. Reports│      │ 9. Reports│
  │    status │      │    status │
  └───────────┘      └───────────┘
```

**Total time from `kubectl apply` to running Pod:** Typically 10-30 seconds. That's the API Server, controllers, scheduler, kubelet, image pull, and container start — all coordinating automatically.

---

## 7. Failure Scenarios and Self-Healing

Understanding architecture means understanding what happens when things break. This is where the control loop proves its value.

### Scenario 1: A Pod Crashes

```
Pod crashes (OOM, unhandled exception, etc.)
     │
     ▼
Kubelet detects container exit
     │
     ▼
Kubelet restarts container (according to restartPolicy)
     │
     ▼
If restart fails repeatedly → CrashLoopBackOff
     │
     ▼
Pod status reported to API Server → visible in kubectl get pods
```

**Who handles it:** Kubelet (local restart). The control plane isn't even involved unless the Pod keeps failing and needs rescheduling.

### Scenario 2: A Worker Node Goes Down

```
Node stops sending heartbeats to API Server
     │
     ▼ (after ~40 seconds)
Node Controller marks node as NotReady
     │
     ▼ (after ~5 minutes)
Node Controller evicts all Pods from the dead node
     │
     ▼
ReplicaSet Controller detects fewer Pods than desired
     │
     ▼
Creates replacement Pods → Scheduler assigns to healthy nodes
     │
     ▼
Kubelets on healthy nodes start new containers
```

**Who handles it:** Node Controller (detects), ReplicaSet Controller (replaces), Scheduler (places), Kubelet (executes). Four components, zero human involvement.

### Scenario 3: Control Plane Goes Down

```
Control Plane becomes unreachable
     │
     ▼
Existing Pods continue running (kubelets keep containers alive)
BUT:
  ✗ No new deployments can be created
  ✗ No scaling events
  ✗ No self-healing for new failures
  ✗ kubectl commands fail
     │
     ▼
Control Plane recovers → reconciliation loop resumes → catches up
```

**Why this matters:** Worker nodes are designed to operate independently when the control plane is unavailable. Your app doesn't go down just because the control plane restarts. This is a deliberate architectural decision.

---

## 8. Mapping Our AeroStore Project to the Architecture

Here's exactly how each architectural component participates when our AeroStore app runs in a cluster:

```
┌──────────────── CONTROL PLANE ────────────────┐
│                                                 │
│  API Server                                     │
│    ├── Receives: kubectl apply -f *.yaml        │
│    ├── Authenticates: RBAC policies             │
│    └── Stores: Deployment, Service, Pod specs   │
│                                                 │
│  etcd                                           │
│    └── Holds: "frontend: 2 replicas, v1.0"      │
│              "backend: 2 replicas, v1.0"        │
│                                                 │
│  Scheduler                                      │
│    └── Assigns frontend pods to Node 1          │
│        Assigns backend pods to Node 2           │
│        (based on available resources)           │
│                                                 │
│  Controller Manager                             │
│    ├── Deployment Controller: manages rollouts  │
│    ├── ReplicaSet Controller: maintains count   │
│    └── Endpoint Controller: updates Service     │
│              endpoints as Pods come/go          │
│                                                 │
└─────────────────────────────────────────────────┘
                    │
                    │  API Server ◄──► Kubelet communication
                    │
┌───────────── WORKER NODES ──────────────────────┐
│                                                   │
│  Node 1                     Node 2                │
│  ┌──────────────────┐      ┌──────────────────┐  │
│  │ kubelet           │      │ kubelet           │ │
│  │  └► containerd    │      │  └► containerd    │ │
│  │      └► frontend  │      │      └► backend   │ │
│  │         pod (nginx)│      │         pod (node)│ │
│  │                    │      │                   │ │
│  │ kube-proxy         │      │ kube-proxy        │ │
│  │  └► iptables rules│      │  └► iptables rules│ │
│  │     route traffic  │      │     route traffic │ │
│  │     to backend svc │      │     to frontend   │ │
│  └──────────────────┘      └──────────────────┘  │
│                                                   │
└───────────────────────────────────────────────────┘
```

### How Traffic Flows Through Our Architecture

```
User → LoadBalancer (cloud/minikube) → kube-proxy → frontend Pod (nginx)
                                                        │
                                    frontend JS calls /api/products
                                                        │
                          kube-proxy routes to ClusterIP → backend Pod (Express)
                                                        │
                                              responds with products.json data
```

Every layer in the architecture has a role:
- **API Server** accepted our manifests
- **etcd** remembers what we asked for
- **Controllers** ensure it stays that way
- **Scheduler** decided where Pods go
- **Kubelet** started the containers
- **Kube-proxy** connected them with networking

---

## 9. Key Architectural Takeaways

### Why This Architecture Works

1. **Separation of concerns** — Each component does one thing. The scheduler only places, the kubelet only executes, controllers only reconcile. No single component is a monolith.

2. **Declarative convergence** — You don't write scripts for "if this breaks, do that." You declare the end state, and the control loop continuously drives reality toward it.

3. **Loose coupling via the API Server** — No component talks directly to another. Everything goes through the API Server, which acts as the single communication hub. This means components can be replaced, upgraded, or scaled independently.

4. **Distributed by design** — Worker nodes operate independently. A network partition between control plane and workers doesn't crash running apps — it only prevents new operations.

5. **Watch-based reactivity** — Components don't poll on a timer. They watch the API Server for changes and react instantly. This is why Kubernetes feels responsive despite managing thousands of objects.

### The Mental Model

```
         "I want 3 backend pods"
                  │
                  ▼
    ┌──── DESIRED STATE (etcd) ────┐
    │  backend: replicas=3, v1.0   │
    └──────────────────────────────┘
                  │
         Control Loop compares
                  │
    ┌──── ACTUAL STATE (nodes) ────┐
    │  2 backend pods running      │
    └──────────────────────────────┘
                  │
             Mismatch!
                  │
                  ▼
        Create 1 more pod
                  │
                  ▼
        Desired == Actual ✓
```

This is the core of Kubernetes architecture: **a continuous loop that compares desired state to actual state and takes corrective action.** Every component exists to serve this loop.

---

*Previous: [Kubernetes Foundations — Why K8s and Cloud-Native Architecture](./Kubernetes-Foundations-And-Cloud-Native.md)*
