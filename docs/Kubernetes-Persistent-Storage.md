# Kubernetes Persistent Storage — Volumes and PersistentVolumeClaims

> This document explains why data is lost when a Pod restarts without persistent storage, how PersistentVolumeClaims (PVCs) solve this, and why persistence is non-negotiable for stateful applications like databases and file upload services.

---

## Table of Contents

1. [Why Data is Ephemeral by Default](#1-why-data-is-ephemeral-by-default)
2. [Kubernetes Storage Primitives](#2-kubernetes-storage-primitives)
3. [PersistentVolumeClaim Configuration](#3-persistentvolumeclaim-configuration)
4. [Mounting a PVC into a Workload](#4-mounting-a-pvc-into-a-workload)
5. [How Data Survives Pod Deletion](#5-how-data-survives-pod-deletion)
6. [Access Modes](#6-access-modes)
7. [Storage Classes and Dynamic Provisioning](#7-storage-classes-and-dynamic-provisioning)
8. [Persistent Storage Diagram](#8-persistent-storage-diagram)
9. [Verification — Proving Persistence](#9-verification--proving-persistence)
10. [Scenario: Missing Uploaded Files After Pod Restart](#10-scenario-missing-uploaded-files-after-pod-restart)

---

## 1. Why Data is Ephemeral by Default

Every container in Kubernetes has its own **writable container layer** — a thin, ephemeral filesystem that is created fresh every time the container starts. When the container stops, this layer is destroyed. When the Pod is deleted, everything written inside the container (to paths like `/tmp`, `/var`, `/app/uploads`) is permanently lost.

This is intentional. Stateless, ephemeral containers are easier to schedule, replace, and scale. But for any application that needs to persist data — uploaded files, a database, logs — ephemerality is a problem.

```
WITHOUT PVC:
  Container starts → writes /app/uploads/photo.jpg
  Pod deleted or crashed
  New container starts → /app/uploads/ is EMPTY
  User: "Where did my file go?"
```

Kubernetes provides **Volumes** to solve this. A volume is storage that exists outside the container layer and is mounted into the container at a specific path.

---

## 2. Kubernetes Storage Primitives

| Object | What it is |
|---|---|
| **Volume** | A directory mounted into a container. Simple but tied to the Pod lifecycle (emptyDir, configMap, secret) |
| **PersistentVolume (PV)** | A cluster-level storage resource — an actual disk, NFS share, or cloud volume. Created by an admin or auto-provisioned. |
| **PersistentVolumeClaim (PVC)** | A user-level request for storage. Says "I need 2Gi of ReadWriteOnce storage." Kubernetes binds it to a suitable PV. |
| **StorageClass** | Defines a type of storage and its provisioner. Allows dynamic PV creation on demand. |

The relationship:
```
Pod → volumeMount → Volume → PVC → PV (actual disk)
```

**PVCs are the correct abstraction.** Applications reference PVCs by name. The actual storage backend (local disk, EBS, GCE PD, NFS) is hidden behind the PVC — swap the StorageClass and the application YAML stays the same.

---

## 3. PersistentVolumeClaim Configuration

```yaml
# k8s/basics/backend-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backend-uploads-pvc
spec:
  accessModes:
    - ReadWriteOnce    # Mounted read-write on one Node at a time
  resources:
    requests:
      storage: 2Gi     # Request 2 GiB of storage
  storageClassName: standard  # Use the default kind StorageClass
```

After `kubectl apply -f backend-pvc.yaml`, the PVC moves from **Pending** to **Bound** once Kubernetes finds or provisions a matching PV. The PVC is now ready to be referenced by Pods.

```bash
kubectl get pvc backend-uploads-pvc
# NAME                  STATUS   VOLUME         CAPACITY   ACCESS MODES
# backend-uploads-pvc   Bound    pvc-abc123...  2Gi        RWO
```

---

## 4. Mounting a PVC into a Workload

```yaml
# k8s/basics/stateful-demo-pod.yaml (simplified)
apiVersion: v1
kind: Pod
metadata:
  name: stateful-demo
spec:
  containers:
    - name: app
      image: busybox:1.36
      volumeMounts:
        - name: uploads-storage   # matches volumes[].name below
          mountPath: /data        # path inside the container

  volumes:
    - name: uploads-storage
      persistentVolumeClaim:
        claimName: backend-uploads-pvc   # references the PVC
```

**How the mount works:**
1. kubelet on the Node sees the Pod spec references `backend-uploads-pvc`
2. kubelet attaches the underlying PV to the Node (if not already attached)
3. kubelet mounts the PV's filesystem at `/data` inside the container
4. Everything the application writes to `/data/` goes to the persistent disk
5. Everything else (the container filesystem, `/tmp`, `/app`) remains ephemeral

---

## 5. How Data Survives Pod Deletion

```
First run:
  Pod starts → initContainer writes /data/uploads/demo.txt → "timestamp: 10:30"
  kubectl exec stateful-demo -- cat /data/uploads/demo.txt → shows "10:30"

Pod deleted:
  kubectl delete pod stateful-demo
  Pod is gone. Container layer is destroyed.
  But PVC "backend-uploads-pvc" still exists: STATUS=Bound
  The PV (disk) is untouched.

Second run:
  kubectl apply -f stateful-demo-pod.yaml (same PVC reference)
  Pod starts → initContainer APPENDS to /data/uploads/demo.txt → "timestamp: 10:35"
  kubectl exec stateful-demo -- cat /data/uploads/demo.txt
  → Shows BOTH "10:30" AND "10:35" — first run's data survived
```

**The key insight:** The PVC and PV exist outside the Pod lifecycle. Deleting a Pod does not delete the PVC. Deleting the PVC triggers the PV's **reclaim policy** (Delete or Retain) — but that's an explicit administrative action, not automatic.

---

## 6. Access Modes

Access modes define how many Nodes can mount the volume simultaneously:

| Mode | Short | Meaning | Use case |
|---|---|---|---|
| **ReadWriteOnce** | RWO | One Node, read-write | Databases, single-replica backends |
| **ReadOnlyMany** | ROX | Many Nodes, read-only | Shared config, pre-built ML models |
| **ReadWriteMany** | RWX | Many Nodes, read-write | Shared file uploads in multi-replica apps |
| **ReadWriteOncePod** | RWOP | One Pod, read-write | Strict single-writer guarantee |

**Why RWO for AeroStore's backend PVC:**
The backend runs with a single active writer at a time. RWO is supported by all major cloud storage providers (EBS, GCE PD, Azure Disk) and is most cost-effective. If we scale to multiple replicas all needing to read/write the same uploads directory, we'd switch to RWX with NFS or a cloud-native shared filesystem.

---

## 7. Storage Classes and Dynamic Provisioning

Without dynamic provisioning, a cluster admin must manually create PVs before PVCs can bind. StorageClasses enable **dynamic provisioning**: the PVC describes what it needs, and Kubernetes automatically creates a matching PV.

```yaml
storageClassName: standard   # kind's default (local-path-provisioner)
# In GKE: standard-rwo       → GCE Persistent Disk (SSD)
# In EKS: gp3                → AWS EBS gp3
# In AKS: managed-premium    → Azure Premium SSD
```

Dynamic provisioning means developers never need to know the details of the underlying storage infrastructure. The PVC is the only interface they need.

---

## 8. Persistent Storage Diagram

![Kubernetes Persistent Storage Diagram](k8s-persistent-storage-diagram.png)

```
WITHOUT PVC:
  [Pod] → writes /app/data/file.txt
  Pod deleted → container layer destroyed → file.txt GONE
  New Pod → /app/data/ is empty

WITH PVC:
  [Pod]
    ↓ volumeMount: /data
  [PVC: backend-uploads-pvc] (STATUS: Bound)
    ↓ bound to
  [PV: actual disk storage]
    → /data/uploads/demo.txt persists here

  Pod deleted → PVC still Bound → PV untouched
  New Pod → same PVC → same PV → demo.txt STILL THERE

PVC LIFECYCLE:
  Pending → Bound → (Pod deleted: still Bound) → Released (PVC deleted) → Deleted/Retained
```

---

## 9. Verification — Proving Persistence

### Step 1: Create and Verify PVC

```bash
kubectl apply -f k8s/basics/backend-pvc.yaml
kubectl get pvc backend-uploads-pvc
# STATUS: Bound → ready to use
```

### Step 2: Write Data

```bash
kubectl apply -f k8s/basics/stateful-demo-pod.yaml
kubectl logs stateful-demo -c data-writer
kubectl exec stateful-demo -- cat /data/uploads/demo.txt
```

### Step 3: Delete Pod

```bash
kubectl delete pod stateful-demo
kubectl get pvc backend-uploads-pvc   # Still Bound — data intact
```

### Step 4: Recreate and Verify

```bash
kubectl apply -f k8s/basics/stateful-demo-pod.yaml
kubectl exec stateful-demo -- cat /data/uploads/demo.txt
# Both timestamps visible — data survived
```

### Step 5: Contrast with Ephemeral Storage

```bash
kubectl run ephemeral-demo --image=busybox:1.36 --restart=Never \
  -- sh -c "echo 'lost data' > /tmp/test.txt && sleep 600"
kubectl exec ephemeral-demo -- cat /tmp/test.txt   # exists
kubectl delete pod ephemeral-demo
kubectl run ephemeral-demo --image=busybox:1.36 --restart=Never \
  -- sh -c "sleep 600"
kubectl exec ephemeral-demo -- cat /tmp/test.txt   # DOES NOT EXIST
```

---

## 10. Scenario: Missing Uploaded Files After Pod Restart

**Scenario:** Application stores uploaded files on disk. After a Pod restart, uploaded files are missing.

### Why This Happens by Default

The application writes to a path inside the container (e.g., `/app/uploads/`). This path is part of the container's writable layer — an ephemeral overlay on top of the Docker image. When the Pod is deleted (due to a crash, node drain, rolling update, or `kubectl delete pod`), the entire container filesystem is destroyed, including everything written to it.

Kubernetes Pods are designed to be cattle, not pets. They are expected to be created and destroyed freely. Without explicit persistent storage, nothing written inside the container survives the Pod's lifecycle.

### How PVC Solves This

Instead of writing to `/app/uploads/` (inside the container), the application writes to `/data/uploads/` which is a **volumeMount backed by a PVC**. The actual data goes to the PersistentVolume — a disk that exists outside the Pod.

When the Pod is deleted and recreated, the new Pod spec references the same PVC by name. Kubernetes attaches the same PV (same disk) to the new Pod. The `/data/uploads/` directory contains all the files from before the restart.

### What Happens if Pod is Deleted but PVC Remains

The PVC continues to exist with `STATUS: Bound`. The underlying PV and all its data are completely unaffected. The data is just sitting on the disk, waiting for the next Pod to attach to it. This is exactly the correct behavior — it means a Pod failure is not a data loss event.

### Why Persistence is Essential for Stateful Applications

**Databases (PostgreSQL, MySQL, MongoDB):** All data is written to disk. Without a PVC, a database restart means starting from an empty database — every table, every row lost.

**File upload services:** User-uploaded content (photos, documents, media) lives on disk. Without a PVC, any Pod restart returns to a blank filesystem. Users lose their uploaded content permanently.

**Message queues:** Durable queues (RabbitMQ, Kafka) persist messages to disk to guarantee delivery. Without persistent storage, in-flight messages are lost on Pod restart.

**Session stores:** If Redis or Memcached is configured for persistence, it writes a snapshot to disk. Without a PVC, the snapshot is lost on restart and the cache warms cold, causing performance degradation.

In all these cases, PVCs are the mechanism that separates "I have a Kubernetes cluster" from "I can run real production applications on Kubernetes."
