# Rolling Update & Rollback — Demo Commands Reference
#
# This file contains the exact command sequence for the video demo.
# Run these after the cluster is up and backend-deployment.yaml is applied.

---

## Setup — Confirm Starting State

```bash
# Apply the updated deployment (nginx:1.17.0 with rolling update strategy)
kubectl apply -f k8s/basics/backend-deployment.yaml

# Confirm 3 Pods are running (we bumped replicas to 3 for better demo visibility)
kubectl get pods -l app=backend

# Check the rollout history (revision 1 = initial deploy, revision 2 = this update)
kubectl rollout history deployment/aerostore-backend

# See the change-cause recorded for each revision
kubectl rollout history deployment/aerostore-backend --revision=2
```

---

## Part 1: Watch a Rolling Update in Progress

```bash
# Trigger a new update — bump image to nginx:1.18.0 (simulating v3)
kubectl set image deployment/aerostore-backend backend=nginx:1.18.0

# Annotate this revision with a change-cause message
kubectl annotate deployment/aerostore-backend \
  kubernetes.io/change-cause="update to nginx:1.18.0 — demo rolling update v3" \
  --overwrite

# ── In a separate terminal: watch the rollout happen live ──
kubectl rollout status deployment/aerostore-backend
# Output as it progresses:
# Waiting for deployment "aerostore-backend" rollout to finish:
#   1 out of 3 new replicas have been updated...
#   2 out of 3 new replicas have been updated...
#   3 out of 3 new replicas have been updated...
# deployment "aerostore-backend" successfully rolled out

# Watch Pods transitioning (old ones Terminating, new ones ContainerCreating → Running)
kubectl get pods -l app=backend -w
```

**Key points to show:**
- maxSurge=1: at most 4 Pods exist at one time (3 desired + 1 surge)
- maxUnavailable=0: service is never interrupted — new Pod must be Ready before old is killed
- readinessProbe is the gate: only Ready Pods receive Service traffic

---

## Part 2: Check Revision History

```bash
# See all stored revisions
kubectl rollout history deployment/aerostore-backend

# Example output:
# REVISION  CHANGE-CAUSE
# 1         <none>
# 2         update to nginx:1.17.0 — add explicit rolling update strategy
# 3         update to nginx:1.18.0 — demo rolling update v3

# Inspect a specific revision's Pod template
kubectl rollout history deployment/aerostore-backend --revision=2
```

---

## Part 3: Simulate a Bad Release

```bash
# Deploy a deliberately broken image (nonexistent tag — simulates a bad release)
kubectl set image deployment/aerostore-backend backend=nginx:this-tag-does-not-exist

kubectl annotate deployment/aerostore-backend \
  kubernetes.io/change-cause="BAD RELEASE: nginx:this-tag-does-not-exist" \
  --overwrite

# Watch the update stall — new Pods stay in ErrImagePull / ImagePullBackOff
kubectl get pods -l app=backend -w

# Old Pods keep running because maxUnavailable=0 — traffic is unaffected
kubectl rollout status deployment/aerostore-backend
# Shows: "Waiting for deployment — 1 out of 3 new replicas have been updated..."
# Old Pods are STILL RUNNING and SERVING TRAFFIC while this hangs
```

---

## Part 4: Rollback

```bash
# Rollback to the immediately previous revision (revision 3)
kubectl rollout undo deployment/aerostore-backend

# OR rollback to a specific revision by number
kubectl rollout undo deployment/aerostore-backend --to-revision=2

# Watch the rollback proceed (same rolling mechanism — just reversed direction)
kubectl rollout status deployment/aerostore-backend
kubectl get pods -l app=backend -w

# Confirm the image is back to the working version
kubectl describe deployment aerostore-backend | grep Image
# Image: nginx:1.18.0  ← (or whichever revision you rolled back to)

# Check history — rollback itself creates a new revision
kubectl rollout history deployment/aerostore-backend
# REVISION  CHANGE-CAUSE
# 3         update to nginx:1.18.0
# 4         BAD RELEASE: nginx:this-tag-does-not-exist
# 5         update to nginx:1.18.0   ← rollback re-promotes revision 3
```

---

## Part 5: Verify Zero-Downtime During Update

```bash
# In one terminal: continuously curl the service during a rolling update
kubectl exec curl-client -- sh -c \
  "while true; do wget -q -O- http://aerostore-backend-service:3001 2>&1 | head -1; sleep 0.5; done"

# In another terminal: trigger the update
kubectl set image deployment/aerostore-backend backend=nginx:1.19.0

# Observe: no gaps in the curl output — service remains available throughout
```
