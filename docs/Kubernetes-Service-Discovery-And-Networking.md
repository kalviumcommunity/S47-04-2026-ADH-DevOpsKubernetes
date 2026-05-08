# Kubernetes Service Discovery & Internal Networking

> This document explains how Kubernetes manages internal networking and service discovery — specifically how applications inside a cluster communicate with each other using Service names and DNS instead of IP addresses.

---

## Table of Contents

1. [The Problem: Pod IPs Are Ephemeral](#1-the-problem-pod-ips-are-ephemeral)
2. [The Solution: Kubernetes Services & DNS](#2-the-solution-kubernetes-services--dns)
3. [How DNS Resolution Works Inside the Cluster](#3-how-dns-resolution-works-inside-the-cluster)
4. [How Service Discovery Is Applied in AeroStore](#4-how-service-discovery-is-applied-in-aerostore)
5. [Service Discovery Diagram](#5-service-discovery-diagram)
6. [Verification — Demonstrating DNS from Inside a Pod](#6-verification--demonstrating-dns-from-inside-a-pod)
7. [Why This Model Supports Scalability and Reliability](#7-why-this-model-supports-scalability-and-reliability)

---

## 1. The Problem: Pod IPs Are Ephemeral

Every Pod in Kubernetes is assigned a unique IP address when it starts. This IP lives only as long as the Pod does. When a Pod is:
- Restarted after a crash
- Rescheduled to a different Node after a node failure
- Replaced during a rolling update

...it gets a **completely new IP address**. The old IP is gone forever.

This makes IP-based communication fundamentally unreliable in Kubernetes. Imagine if your frontend hardcoded the backend's IP as `10.244.1.5`. The moment the backend Pod restarts, that address is invalid, the frontend's requests fail, and the application breaks — even though the backend is perfectly healthy and running.

This is exactly why **you must never hardcode Pod IP addresses** for inter-component communication in Kubernetes.

---

## 2. The Solution: Kubernetes Services & DNS

A **Service** is a stable networking abstraction that sits in front of a group of Pods. It provides:

1. **A stable ClusterIP** — a virtual IP that never changes for the lifetime of the Service. Even if every Pod behind it is replaced, the ClusterIP stays the same.
2. **A stable DNS name** — Kubernetes automatically registers a DNS entry for every Service via **CoreDNS**, the cluster's built-in DNS resolver.
3. **Load balancing** — traffic sent to the Service is automatically distributed across all healthy Pods that match the Service's label selector.

### Service Types

| Type | Accessibility | Use Case |
|---|---|---|
| **ClusterIP** | Internal only (Pod-to-Pod) | Service discovery inside the cluster |
| **NodePort** | External via Node IP + static port | Local development, browser access |
| **LoadBalancer** | External via cloud load balancer | Production traffic from the internet |

For internal service discovery, **ClusterIP is always the correct choice**. It is the default type and is designed specifically for this pattern.

---

## 3. How DNS Resolution Works Inside the Cluster

Kubernetes runs **CoreDNS** as a system Pod in the `kube-system` namespace. Every Pod's `/etc/resolv.conf` is automatically configured to use CoreDNS as its DNS server.

### The Resolution Flow

```
curl-client Pod
      │
      │ curl http://aerostore-backend-service:3001
      │
      ▼
CoreDNS (kube-dns service at 10.96.0.10)
      │
      │ Lookup: aerostore-backend-service.default.svc.cluster.local
      │
      ▼
Returns ClusterIP: 10.96.45.12  (stable — never changes)
      │
      ▼
kube-proxy routes traffic to one of:
      ├── backend Pod 10.244.1.5
      ├── backend Pod 10.244.1.8
      └── backend Pod 10.244.2.3  (all selected by label: app: backend)
```

### DNS Name Format

Every Service automatically gets a DNS name in this format:

```
<service-name>.<namespace>.svc.cluster.local
```

For AeroStore's backend service:
```
aerostore-backend-service.default.svc.cluster.local
```

Within the **same namespace**, you can use just the short name:
```
aerostore-backend-service
```

Kubernetes appends the namespace and domain suffix automatically via the search domains in `/etc/resolv.conf`.

### What `/etc/resolv.conf` Looks Like Inside a Pod

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

This is why `curl http://aerostore-backend-service` works — the DNS client tries appending each search domain suffix until it gets a hit from CoreDNS.

---

## 4. How Service Discovery Is Applied in AeroStore

### Our Services

| Service | Type | DNS Name | Purpose |
|---|---|---|---|
| `aerostore-frontend-service` | NodePort | `aerostore-frontend-service` | Exposes frontend to external browser traffic |
| `aerostore-backend-service` | ClusterIP | `aerostore-backend-service` | Internal API access for Pod-to-Service communication |

### New Files Added (This PR)

**`k8s/basics/backend-service.yaml`** — A ClusterIP Service for the backend:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: aerostore-backend-service
spec:
  type: ClusterIP
  selector:
    app: backend       # Routes to any Pod with this label
  ports:
    - port: 3001
      targetPort: 3001
```

Any Pod inside the cluster can now reach the backend with:
```
http://aerostore-backend-service:3001
```

No IP address. No hardcoded endpoint. No breakage when Pods restart.

**`k8s/basics/curl-client-pod.yaml`** — A debug Pod for verifying discovery:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: curl-client
spec:
  containers:
    - name: curl-client
      image: curlimages/curl:latest
      command: ["sleep", "3600"]
  restartPolicy: Never
```

---

## 5. Service Discovery Diagram

![Kubernetes Service Discovery Diagram](k8s-service-discovery-diagram.png)

```
┌──────────────────────┐       DNS query        ┌──────────────────┐
│    curl-client Pod   │ ─────────────────────► │    CoreDNS       │
│                      │                         │  (kube-system)   │
│  curl http://        │ ◄──────────────────────  │                  │
│  aerostore-backend-  │  resolves to ClusterIP  │  Returns:        │
│  service:3001        │                         │  10.96.45.12     │
└──────────────────────┘                         └──────────────────┘
                                                          │
                                                          ▼
                                          ┌───────────────────────────┐
                                          │  aerostore-backend-service │
                                          │  ClusterIP: 10.96.45.12   │
                                          │  selector: app: backend    │
                                          └──────────┬────────────────┘
                                                     │ load balances
                                      ┌──────────────┼──────────────┐
                                      ▼              ▼              ▼
                               ┌──────────┐  ┌──────────┐  ┌──────────┐
                               │ backend  │  │ backend  │  │ backend  │
                               │  Pod     │  │  Pod     │  │  Pod     │
                               │10.244.1.5│  │10.244.1.8│  │10.244.2.3│
                               │(ephemeral│  │(ephemeral│  │(ephemeral│
                               │   IP)    │  │   IP)    │  │   IP)    │
                               └──────────┘  └──────────┘  └──────────┘
                                      ↑ IPs change on restart — Service name stays stable
```

---

## 6. Verification — Demonstrating DNS from Inside a Pod

### Step 1: Deploy the curl-client Pod

```bash
kubectl apply -f k8s/basics/curl-client-pod.yaml
kubectl apply -f k8s/basics/backend-service.yaml

# Verify the pod is running
kubectl get pods curl-client
```

### Step 2: Exec Into the Pod

```bash
kubectl exec -it curl-client -- sh
```

### Step 3: Verify DNS Resolution (Inside the Pod)

```bash
# Resolve the service name to its ClusterIP
nslookup aerostore-backend-service

# Expected output:
# Server:    10.96.0.10
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
#
# Name:      aerostore-backend-service
# Address 1: 10.96.45.12 aerostore-backend-service.default.svc.cluster.local
```

### Step 4: Communicate Using the Service Name

```bash
# Reach the backend via Service name — NOT an IP address
curl http://aerostore-backend-service:3001

# Also works with the full DNS name:
curl http://aerostore-backend-service.default.svc.cluster.local:3001

# Reach the frontend service via its cluster-internal name:
curl http://aerostore-frontend-service:80
```

### Step 5: Verify the Service Routes to Pods

```bash
# Exit the pod first
exit

# See all endpoints (Pod IPs) behind the Service
kubectl get endpoints aerostore-backend-service

# Expected output — the Pod IPs Kubernetes is load-balancing to:
# NAME                        ENDPOINTS                                         AGE
# aerostore-backend-service   10.244.1.5:3001,10.244.1.8:3001,10.244.2.3:3001  5m
```

This shows that the Service name is stable while the underlying Pod IPs can change at any time.

---

## 7. Why This Model Supports Scalability and Reliability

### Decoupling Consumers from Producers

When the frontend calls `http://aerostore-backend-service:3001`, it has zero knowledge of:
- How many backend Pods are running
- Which Node they're on
- What their IP addresses are

This decoupling is what makes the system scalable. You can scale backend Pods from 1 to 10 with `kubectl scale`, and the frontend's calls automatically start being distributed across all 10, with no configuration change required.

### Automatic Load Balancing

kube-proxy (running on every Node) watches for Services and their Pods and programs iptables (or IPVS) rules to distribute traffic across all healthy Pods behind a Service. This is automatic, always up-to-date, and requires no external load balancer for internal traffic.

### Self-Healing Without Reconfiguration

When a Pod crashes and Kubernetes restarts it, the new Pod gets a new IP. The Service's Endpoints controller detects this and updates the endpoints list within seconds. The Service name and ClusterIP stay constant — callers don't need to be updated, reconfigured, or restarted. Recovery is invisible to the consumers.

### Why Hardcoding Pod IPs Fails

| Scenario | Hardcoded IP Result | Service Name Result |
|---|---|---|
| Pod restarts | Old IP invalid → connection refused | Service updates endpoints → transparent |
| Pod rescheduled to new Node | New IP different → connection fails | Service updates endpoints → transparent |
| Scaling from 1 to 3 Pods | Only 1 Pod receives all traffic | Automatic load balancing across all 3 |
| Rolling update | Old Pod IPs gradually disappear | Always routes to running Pods only |
