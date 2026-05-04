# Kubernetes Deployments: Managing Rollouts and Desired State

This document outlines the standard production method for managing applications in Kubernetes: **Deployments**. It demonstrates how the AeroStore project handles version updates with zero downtime.

## 1. Why Deployments over ReplicaSets?
While ReplicaSets guarantee high availability (maintaining $N$ Pods), they do not know how to safely handle updates. If we want to change our application's container image from `v1` to `v2`, a ReplicaSet cannot orchestrate that transition gracefully.

A **Deployment** is a higher-level object that wraps around ReplicaSets. It provides declarative updates for Pods. Instead of managing Pods directly, you declare the desired state in a Deployment, and the Deployment Controller changes the actual state to the desired state at a controlled rate.

*Reference:* See our Deployment definition at `k8s/basics/nginx-deployment.yaml`.

## 2. Zero-Downtime Rollouts
The primary advantage of a Deployment is the **Rolling Update** strategy. 

When we updated our image from `nginx:1.14.2` to `nginx:1.16.1`:
1. The Deployment created a *new* ReplicaSet for version `1.16.1`.
2. It began scaling up the new ReplicaSet (adding new pods).
3. Simultaneously, it began scaling down the old `1.14.2` ReplicaSet.
4. It ensured that at least a minimum number of Pods were always available to serve user traffic, resulting in **zero downtime**.

## 3. Safe Updates (The "Typo" Protection)
During our testing, we intentionally introduced a typo in the image name (`nginx:1.16.2` which does not exist). 

This perfectly demonstrated Kubernetes' built-in safety mechanisms:
- The Deployment attempted to pull the invalid image and failed (`ImagePullBackOff`).
- Because the new Pod could not reach a `Ready` state, the Deployment **paused the rollout**.
- Crucially, the original `1.14.2` Pods were kept alive and `Running`. 
- If this were a production environment, users would not have experienced an outage, despite a bad update being pushed. Once the typo was fixed to `1.16.1`, the rollout resumed and completed successfully.

## 4. Declarative Lifecycle Management
Using Deployments means we are managing our application lifecycle entirely declaratively. We don't script the update process; we just change the `image` tag in the YAML, and Kubernetes handles the complex orchestration of ReplicaSets and Pod scheduling automatically.
