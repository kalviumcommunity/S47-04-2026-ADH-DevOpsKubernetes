# Local Kubernetes Cluster Setup

This document outlines the setup and verification of a local Kubernetes cluster using **kind** (Kubernetes IN Docker). This setup is used for local experimentation, testing deployments, and validating Kubernetes manifests before they reach production.

## Why We Chose `kind`
For the AeroStore project, we chose **kind** over Minikube or k3s because:
- **Zero New Dependencies:** We are already utilizing Docker for our containerization needs. `kind` runs Kubernetes nodes simply as Docker containers.
- **Realistic Topology:** `kind` allows us to define a multi-node cluster (control plane + worker nodes) using a declarative YAML configuration, accurately reflecting a production K8s architecture.
- **Speed & Resource Efficiency:** It spins up very quickly without the heavy overhead of a traditional Virtual Machine (which Minikube requires on Windows).

## Cluster Configuration
The cluster topology is defined in `k8s/kind-cluster-config.yaml`. We are using a 2-node setup:
1. **Control Plane Node:** Runs the API server, scheduler, controller manager, and etcd.
2. **Worker Node:** Dedicated to running our application workloads (pods).

## Setup Instructions

### 1. Create the Cluster
To spin up the cluster, run the following command from the root of the repository:
```bash
kind create cluster --name aerostore-dev --config k8s/kind-cluster-config.yaml
```

### 2. Verify the Setup
Once the cluster is created, we verify its health and accessibility:

- **Check Node Status:**
  ```bash
  kubectl get nodes
  ```
  *(Expected Output: Both `aerostore-dev-control-plane` and `aerostore-dev-worker` should be in the `Ready` state).*

- **Verify API Server Accessibility:**
  ```bash
  kubectl cluster-info
  ```

- **Check Underlying Infrastructure (Docker):**
  ```bash
  docker ps
  ```
  *(Expected Output: Two containers running the `kindest/node` image, representing our control plane and worker).*

## Verification Screenshot
Below is the verification of our running cluster, showing the nodes in a `Ready` state, the active cluster-info, and the corresponding Docker containers:

![Cluster Verification Screenshot](./cluster-verification.png)

*(Note: Ensure you place your screenshot in the `docs` folder and name it `cluster-verification.png` before your PR).*

## Meaningful Project Integration
To make this setup easily reproducible for any developer joining the AeroStore project, we have also added a helper script at `scripts/manage-k8s-cluster.sh`. 

This script allows developers to quickly spin up, verify, and tear down the local testing cluster without having to remember the specific `kind` commands or config paths. This integrates the local K8s environment directly into our standard development workflow.
