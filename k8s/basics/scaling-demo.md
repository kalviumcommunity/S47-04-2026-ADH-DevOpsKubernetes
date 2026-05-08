# Scaling Demo — Commands Reference

This file provides the exact command sequence for demonstrating both manual
scaling and HPA autoscaling during the video demo. Run these after applying
all manifests.

---

## Prerequisites

```bash
# Ensure the backend deployment is running
kubectl apply -f k8s/basics/app-configmap.yaml
kubectl apply -f k8s/basics/app-secret.yaml
kubectl apply -f k8s/basics/backend-deployment.yaml
kubectl apply -f k8s/basics/backend-hpa.yaml

# Verify starting state: 2 replicas running
kubectl get pods -l app=backend
kubectl get hpa aerostore-backend-hpa
```

---

## Part 1: Manual Scaling

```bash
# Current state: 2 replicas
kubectl get deployment aerostore-backend

# Scale up manually to 5 replicas
kubectl scale deployment aerostore-backend --replicas=5

# Watch the new Pods come up in real-time
kubectl get pods -l app=backend -w

# Scale back down to 2 replicas
kubectl scale deployment aerostore-backend --replicas=2

# Watch Pods terminate
kubectl get pods -l app=backend -w
```

**What to explain:** Manual scaling is immediate and deterministic — you
decide the count. But it requires a human watching metrics and acting. In
a production spike at 3am, there is no one watching.

---

## Part 2: HPA Autoscaling

```bash
# Apply the HPA (if not already applied)
kubectl apply -f k8s/basics/backend-hpa.yaml

# View HPA state — shows current replicas, targets, and metric values
kubectl get hpa aerostore-backend-hpa

# Watch HPA scaling decisions in real-time
kubectl get hpa aerostore-backend-hpa -w

# Describe HPA for full detail: conditions, events, scaling history
kubectl describe hpa aerostore-backend-hpa
```

**What the output shows:**
```
NAME                    REFERENCE                 TARGETS   MINPODS   MAXPODS   REPLICAS
aerostore-backend-hpa   Deployment/aerostore-backend  22%/50%   2         8         2
```
- TARGETS: current CPU % / target CPU %
- MINPODS / MAXPODS: the replica bounds
- REPLICAS: current replica count

---

## Part 3: Simulating Load (HPA Trigger)

```bash
# In a separate terminal: generate load against the backend service
# This runs a busybox pod that continuously hits the service
kubectl run load-generator \
  --image=busybox:1.28 \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://aerostore-backend-service:3001; done"

# Watch HPA react — CPU should climb above 50% and trigger scale-up
kubectl get hpa aerostore-backend-hpa -w

# After ~60-90 seconds, replica count will increase automatically
kubectl get pods -l app=backend

# Stop the load generator
kubectl delete pod load-generator

# Watch HPA scale back down (stabilization window = 5 minutes)
kubectl get hpa aerostore-backend-hpa -w
```

---

## Key Events to Point Out

```bash
# View all scaling events in the cluster
kubectl get events --sort-by='.lastTimestamp' | grep -i "scal\|hpa"

# Example events you'll see:
# Normal  SuccessfulRescale  HorizontalPodAutoscaler
#         New size: 4; reason: cpu resource utilization (percentage of request)
#         above target
```
