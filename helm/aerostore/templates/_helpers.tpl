{{/*
helm/aerostore/templates/_helpers.tpl

Helper templates (named templates) that are reused across all template files.
These prevent duplication and ensure consistent naming/labeling.
*/}}

{{/*
Expand the chart name.
*/}}
{{- define "aerostore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because Kubernetes name fields are limited.
*/}}
{{- define "aerostore.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart version label — used to track which chart version created a resource.
*/}}
{{- define "aerostore.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Standard labels — applied to ALL resources created by this chart.
Kubernetes recommends these for discoverability and tooling compatibility.
*/}}
{{- define "aerostore.labels" -}}
helm.sh/chart: {{ include "aerostore.chart" . }}
{{ include "aerostore.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — used in matchLabels and Service selectors.
Must be stable (not change between releases) because they are immutable
once set on a ReplicaSet.
*/}}
{{- define "aerostore.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aerostore.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
