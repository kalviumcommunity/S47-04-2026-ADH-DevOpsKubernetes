# Understanding Kubernetes Objects: Pods and ReplicaSets

This document explains the foundational workload objects in Kubernetes, demonstrating how the AeroStore project manages containerized applications locally. It serves as proof of our transition from basic Docker execution to declarative Kubernetes orchestration.

## 1. What is a Pod?
A **Pod** is the smallest deployable computing unit that you can create and manage in Kubernetes. 
Kubernetes does not run Docker containers directly. Instead, it wraps one or more tightly coupled containers inside a Pod. All containers inside the same Pod share the same local network IP address, port space, and storage volumes.

**Why is it important?**
If we just ran naked containers, managing shared resources between dependent containers (like an application container and a logging sidecar) would be incredibly difficult. A Pod provides a logical "host" wrapper around them.

*Reference:* See our basic pod definition at `k8s/basics/nginx-pod.yaml`.

## 2. The Problem with Standalone Pods
While Pods are the fundamental building blocks, **they are mortal**. If a Node dies, or if a Pod crashes due to an error, Kubernetes will *not* automatically bring a standalone Pod back to life. If we only used standalone Pods, our application would experience downtime until a human intervened.

## 3. What is a ReplicaSet?
A **ReplicaSet** solves the mortality problem of Pods. Its sole purpose is to maintain a stable set of replica Pods running at any given time.

**How it works:**
1. **Desired State:** We declare via YAML that we want a specific number of Pods (e.g., `replicas: 3`).
2. **Selectors:** The ReplicaSet uses a `selector` to constantly count how many Pods currently exist in the cluster with a specific label (e.g., `app: frontend`).
3. **Reconciliation Loop:** If the *Actual State* (current number of running Pods) does not match the *Desired State*, the ReplicaSet immediately creates or deletes Pods to fix the mismatch.

*Reference:* See our ReplicaSet definition at `k8s/basics/nginx-replicaset.yaml`.

## 4. Proving "Self-Healing"
During our testing on the local `kind` cluster, we proved the self-healing capability of the ReplicaSet:
1. We applied the ReplicaSet, which successfully spawned 3 Pods.
2. We simulated a critical failure by intentionally deleting one of the running Pods (`kubectl delete pod <pod-name>`).
3. Instantly, the ReplicaSet detected that the count dropped from 3 to 2.
4. Without human intervention, the ReplicaSet scheduled a brand new replacement Pod, restoring the system to the desired state of 3 running Pods.

## 5. Declarative vs Imperative
This exercise highlights Kubernetes' **Declarative** nature. We do not write imperative scripts saying *"if a pod crashes, run docker start"*. Instead, we simply provide a YAML file stating *"there must always be 3 frontend pods"* and the Kubernetes Control Plane handles the complexity of making that a reality.
