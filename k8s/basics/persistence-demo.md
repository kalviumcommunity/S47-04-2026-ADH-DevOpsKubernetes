# Persistent Storage Demo — Commands Reference

## Part 1: Create the PVC

```bash
kubectl apply -f k8s/basics/backend-pvc.yaml
kubectl get pvc backend-uploads-pvc
# NAME                  STATUS   VOLUME    CAPACITY   ACCESS MODES
# backend-uploads-pvc   Bound    pvc-xxx   2Gi        RWO
kubectl describe pvc backend-uploads-pvc
```

## Part 2: First Pod Run — Write Data

```bash
kubectl apply -f k8s/basics/stateful-demo-pod.yaml
kubectl get pod stateful-demo -w   # wait for Running
kubectl logs stateful-demo -c data-writer
# Shows: "--- New Pod start: 2024-01-15 10:30:45 UTC ---"

kubectl exec stateful-demo -- cat /data/uploads/demo.txt
# File is present — written to the PVC mount
kubectl exec stateful-demo -- ls -la /data/uploads/
```

## Part 3: Delete the Pod (Simulate Crash)

```bash
kubectl delete pod stateful-demo
kubectl get pod stateful-demo           # Error: not found — pod is gone
kubectl get pvc backend-uploads-pvc     # STATUS: Bound — PVC still exists!
# Data on PV is untouched by Pod deletion
```

## Part 4: Recreate Pod — Verify Persistence

```bash
kubectl apply -f k8s/basics/stateful-demo-pod.yaml
kubectl get pod stateful-demo -w        # wait for Running
kubectl logs stateful-demo -c data-writer
# Shows BOTH timestamps — original + new → data survived deletion!

kubectl exec stateful-demo -- cat /data/uploads/demo.txt
# Both lines present. Pod reattached to same PVC. Data persisted.
```

## Part 5: Contrast — Ephemeral Storage Data Loss

```bash
# Pod with NO PVC — writes to container filesystem
kubectl run ephemeral-demo --image=busybox:1.36 --restart=Never \
  -- sh -c "echo 'will be lost' > /tmp/test.txt && sleep 3600"
kubectl exec ephemeral-demo -- cat /tmp/test.txt
# Shows: will be lost

kubectl delete pod ephemeral-demo

kubectl run ephemeral-demo --image=busybox:1.36 --restart=Never \
  -- sh -c "sleep 3600"
kubectl exec ephemeral-demo -- cat /tmp/test.txt
# cat: /tmp/test.txt: No such file or directory  ← DATA LOST
kubectl delete pod ephemeral-demo
```

## Part 6: PV Details

```bash
kubectl get pv
kubectl describe pv $(kubectl get pvc backend-uploads-pvc -o jsonpath='{.spec.volumeName}')
# Shows: Source.Type, Reclaim Policy, Capacity, Claim
```

## Cleanup

```bash
kubectl delete pod stateful-demo
kubectl delete pvc backend-uploads-pvc
```
