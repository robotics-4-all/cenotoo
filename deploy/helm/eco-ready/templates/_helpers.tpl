{{/*
Chart name truncated to 63 chars.
*/}}
{{- define "eco-ready.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name truncated to 63 chars.
*/}}
{{- define "eco-ready.fullname" -}}
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
Common labels.
*/}}
{{- define "eco-ready.labels" -}}
helm.sh/chart: {{ include "eco-ready.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: eco-ready
{{- end }}

{{/*
Selector labels for a component.
*/}}
{{- define "eco-ready.selectorLabels" -}}
app.kubernetes.io/name: {{ include "eco-ready.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
