# Kubernetes Package Management with Helm

> This document explains how Helm solves the multi-environment configuration management problem with raw Kubernetes YAML, how a Helm chart packages an entire application, and how Helm provides upgrade and rollback capabilities beyond what kubectl alone offers.

---

## Table of Contents

1. [The Problem: Raw YAML at Scale](#1-the-problem-raw-yaml-at-scale)
2. [What is Helm?](#2-what-is-helm)
3. [Helm Chart Structure](#3-helm-chart-structure)
4. [How values.yaml Drives Environment Configuration](#4-how-valuesyaml-drives-environment-configuration)
5. [AeroStore Helm Chart](#5-aerostore-helm-chart)
6. [Helm Lifecycle Commands](#6-helm-lifecycle-commands)
7. [Helm vs Raw kubectl — A Direct Comparison](#7-helm-vs-raw-kubectl--a-direct-comparison)
8. [Helm Diagram](#8-helm-diagram)
9. [Scenario: Multi-Environment Configuration Management](#9-scenario-multi-environment-configuration-management)

---

## 1. The Problem: Raw YAML at Scale

As the AeroStore project grew, we accumulated a collection of individual Kubernetes YAML files:

```
k8s/basics/
├── app-configmap.yaml
├── app-secret.yaml
├── backend-deployment.yaml
├── backend-service.yaml
├── backend-hpa.yaml
├── namespace-resource-policy.yaml
├── nginx-deployment.yaml
└── nginx-service.yaml
```

To deploy to a new environment, you must:

1. Copy all these files and manually edit values for that environment (image tags, replica counts, log levels, resource limits)
2. Run `kubectl apply -f` on each file, in the correct order
3. Track which version of each file was applied to which environment
4. When upgrading, diff old and new files manually to understand what changed
5. If something breaks, manually re-apply the previous version

This approach is **error-prone, not repeatable, and impossible to audit.** In a team setting, different developers apply different versions of files to different clusters, leading to configuration drift.

---

## 2. What is Helm?

Helm is the **package manager for Kubernetes** — analogous to `apt` for Ubuntu, `npm` for Node.js, or `pip` for Python.

A Helm **chart** packages all Kubernetes YAML manifests for an application into a single, versioned, configurable unit. Instead of managing individual YAML files, you manage a Helm **release** — a named, versioned installation of a chart on a specific cluster.

```
Without Helm:
  kubectl apply -f file1.yaml
  kubectl apply -f file2.yaml
  kubectl apply -f file3.yaml
  (repeat for each environment, manually editing each file)

With Helm:
  helm install aerostore-prod ./helm/aerostore --values values-prod.yaml
  (one command. one release. all resources created and tracked.)
```

### Key Helm Concepts

| Term | Description |
|---|---|
| **Chart** | A package containing templates + values + metadata |
| **Release** | A named installation of a chart on a cluster |
| **Revision** | A numbered version of a release (increments on every upgrade) |
| **Values** | Configuration that fills in the template variables |
| **Repository** | A collection of charts hosted remotely (e.g., Artifact Hub) |

---

## 3. Helm Chart Structure

```
helm/aerostore/              ← The chart directory
├── Chart.yaml               ← Chart metadata (name, version, appVersion)
├── values.yaml              ← Default values (production-sensible defaults)
├── values-dev.yaml          ← Development overrides (only changed values)
├── values-prod.yaml         ← Production overrides (only changed values)
└── templates/               ← Kubernetes YAML templates with {{ }} variables
    ├── _helpers.tpl         ← Named templates for reuse (labels, names)
    ├── deployment.yaml      ← Deployment template
    ├── service.yaml         ← Service template
    ├── hpa.yaml             ← HPA template (conditionally rendered)
    └── configmap.yaml       ← ConfigMap template
```

### `Chart.yaml` — Chart Metadata

```yaml
apiVersion: v2
name: aerostore
description: A Helm chart for the AeroStore application
version: 0.1.0         # Chart version — bump when the chart structure changes
appVersion: "1.17.0"   # Application version — the Docker image tag
```

### `templates/_helpers.tpl` — Reusable Named Templates

Helper templates define consistent naming and labeling across all resources:

```
{{ include "aerostore.fullname" . }}        → "aerostore-dev-aerostore" (release+chart)
{{ include "aerostore.labels" . }}          → all standard Kubernetes/Helm labels
{{ include "aerostore.selectorLabels" . }}  → stable labels for Service selectors
```

This ensures every resource created by Helm has consistent metadata that connects the release to its resources.

---

## 4. How values.yaml Drives Environment Configuration

The `values.yaml` file is the central configuration contract for the chart. Every `{{ .Values.X }}` reference in a template is filled in from this file at install/upgrade time.

### Template Example (Deployment)

```yaml
# templates/deployment.yaml
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
replicas: {{ .Values.replicaCount }}
```

### Default values.yaml (production defaults)

```yaml
image:
  tag: "1.17.0"
replicaCount: 3
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 8
config:
  logLevel: "info"
```

### values-dev.yaml (only differences from defaults)

```yaml
image:
  tag: "1.16.1"
replicaCount: 1
autoscaling:
  enabled: false
config:
  logLevel: "debug"
```

Helm **merges** these files — dev values override defaults, everything else inherits from `values.yaml`. You only specify what's different for each environment.

### How Rendering Works

```bash
# Install with dev values → dev gets: replicas=1, HPA=off, logLevel=debug
helm install aerostore-dev ./helm/aerostore --values values-dev.yaml

# Install with prod values → prod gets: replicas=5, HPA=on, logLevel=warn
helm install aerostore-prod ./helm/aerostore --values values-prod.yaml
```

**Same chart. Same templates. Different environments — no file duplication.**

### Conditional Resource Creation

The HPA template uses a Helm conditional:

```yaml
# templates/hpa.yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
...
{{- end }}
```

When `autoscaling.enabled: false` (dev), Helm does not render the HPA at all — no YAML is generated, no resource is created. This is impossible with static YAML files without duplicating entire file sets.

---

## 5. AeroStore Helm Chart

### Install (Development)

```bash
helm install aerostore-dev ./helm/aerostore \
  --values helm/aerostore/values-dev.yaml

# Creates: Deployment (1 replica), Service, ConfigMap (logLevel: debug)
# Does NOT create: HPA (disabled for dev)
```

### Install (Production)

```bash
helm install aerostore-prod ./helm/aerostore \
  --values helm/aerostore/values-prod.yaml

# Creates: Deployment (5 replicas), Service, ConfigMap (logLevel: warn), HPA
```

### Preview What Will Be Applied (Dry Run)

```bash
# See rendered YAML before applying anything
helm template aerostore ./helm/aerostore --values helm/aerostore/values-dev.yaml

# Lint for issues
helm lint ./helm/aerostore
```

---

## 6. Helm Lifecycle Commands

### Install

```bash
helm install <release-name> <chart-path> [--values <file>] [--set key=value]
```

Creates all chart resources in the cluster. Registers a release with revision 1.

### Upgrade

```bash
helm upgrade <release-name> <chart-path> [--values <file>] [--set key=value]
```

Applies changes to an existing release. Increments the revision number. Triggers a rolling update for Deployment changes. Helm records the full state of every revision.

```bash
helm upgrade aerostore-dev ./helm/aerostore --set image.tag=1.18.0
# Revision 1 → Revision 2. Rolling update begins automatically.
```

### View Release History

```bash
helm history aerostore-dev
# REVISION  UPDATED          STATUS     CHART           DESCRIPTION
# 1         2024-01-01 ...   superseded aerostore-0.1.0  Install complete
# 2         2024-01-02 ...   deployed   aerostore-0.1.0  Upgrade complete
```

### Rollback

```bash
helm rollback <release-name> <revision-number>
helm rollback aerostore-dev 1
# Restores revision 1. Creates revision 3 (rollbacks create new revisions).
```

### Uninstall

```bash
helm uninstall aerostore-dev
# Deletes ALL resources created by this release — Deployment, Service, HPA, ConfigMap
```

---

## 7. Helm vs Raw kubectl — A Direct Comparison

| Capability | Raw `kubectl apply` | Helm |
|---|---|---|
| **Install** | Apply each file manually, in order | `helm install` — one command, all resources |
| **Environment config** | Duplicate/edit YAML files per environment | `values-dev.yaml`, `values-prod.yaml` — override only differences |
| **Upgrade** | Apply updated files, track what changed manually | `helm upgrade` — revision tracked, rolling update triggered |
| **Rollback** | Re-apply old YAML files manually | `helm rollback N` — instant, to any previous revision |
| **Audit** | Check git history of each YAML file separately | `helm history` — shows all revisions of the release |
| **Conditional resources** | Duplicate entire file sets per environment | `{{- if .Values.X }}` — conditional in one template |
| **Cleanup** | Delete each resource manually | `helm uninstall` — deletes all release resources |
| **Reproducibility** | Developer must know which files to apply | `helm install` from the same chart always produces the same result |

---

## 8. Helm Diagram

![Kubernetes Helm Package Management Diagram](k8s-helm-diagram.png)

```
                    values.yaml (defaults)
                         +
                    values-dev.yaml OR values-prod.yaml
                         |
                         ▼
        templates/ → Helm Engine → Rendered Kubernetes YAML
                                          |
                                          ▼
                                   kubectl apply
                                   (done by Helm)
                                          |
                              ┌───────────┴───────────┐
                         dev cluster              prod cluster
                       (1 replica,              (5 replicas,
                        no HPA,                  HPA enabled,
                        debug logs)              warn logs)

helm upgrade → new revision → rolling update
helm rollback → previous revision → rolling update in reverse
helm history → full audit trail of every revision
```

---

## 9. Scenario: Multi-Environment Configuration Management

**Scenario:** The project uses multiple Kubernetes YAML files applied manually per environment. Managing updates and configuration differences is becoming error-prone.

### How Raw YAML Fails at Scale

With 8+ YAML files applied to 3 environments:
- **24 YAML files** to maintain (or complex file-copying scripts)
- No record of what was applied when — only git history, which is hard to correlate to running clusters
- Developer A applies dev files. Developer B applies a different version to staging. Configuration drift accumulates.
- A rollback means finding the right old files and re-applying them in the correct order

### How Helm Solves This

**One chart, one values file per environment.** The chart directory is committed to git once. Environment-specific values are committed as small override files. No duplication.

**Every deployment is a versioned release.** `helm history` shows every install and upgrade with timestamps and descriptions. You always know what version is running and when it was applied.

**Upgrade by changing a value, not a file.** To update the production image, you run `helm upgrade aerostore-prod --set image.tag=1.18.0`. Helm renders the updated template, diffs with the current state, and applies only the changed resources. Rolling update starts automatically.

**Rollback is one command.** `helm rollback aerostore-prod 2` restores the previous configuration in full — image, replica count, HPA settings, ConfigMap values — as a new revision. No need to find old YAML files.

**Conditional resources per environment.** HPA is only created in prod. The dev environment has a simpler, cheaper configuration — from the same chart, with a smaller values override file. No file duplication required.
