{{/*
Expand the name of the chart.
*/}}
{{- define "smtpd.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "smtpd.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "smtpd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "smtpd.labels" -}}
helm.sh/chart: {{ include "smtpd.chart" . }}
{{ include "smtpd.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "smtpd.selectorLabels" -}}
app.kubernetes.io/name: {{ include "smtpd.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Pod annotations, including the Istio sidecar traffic-capture exclusions.
Excluded ports bypass the sidecar entirely, so that traffic leaves the pod via the
node subnet (and therefore the NAT gateway) instead of the mesh/egress gateways.
*/}}
{{- define "smtpd.podAnnotations" -}}
{{- $annotations := deepCopy (.Values.podAnnotations | default dict) -}}
{{- $istio := .Values.istio | default dict -}}
{{- if $istio.enabled -}}
{{- with $istio.excludeOutboundPorts }}{{- $_ := set $annotations "traffic.sidecar.istio.io/excludeOutboundPorts" (toString .) }}{{- end -}}
{{- with $istio.excludeInboundPorts }}{{- $_ := set $annotations "traffic.sidecar.istio.io/excludeInboundPorts" (toString .) }}{{- end -}}
{{- with $istio.excludeOutboundIPRanges }}{{- $_ := set $annotations "traffic.sidecar.istio.io/excludeOutboundIPRanges" (toString .) }}{{- end -}}
{{- with $istio.podAnnotations }}{{- $annotations = merge $annotations (deepCopy .) }}{{- end -}}
{{- end -}}
{{- with $annotations }}{{ toYaml . }}{{ end }}
{{- end }}

{{/*
Pod labels, including the Istio sidecar injection opt-in.
*/}}
{{- define "smtpd.podLabels" -}}
{{- $labels := deepCopy (.Values.podLabels | default dict) -}}
{{- $istio := .Values.istio | default dict -}}
{{- if $istio.enabled -}}
{{- if $istio.revision }}{{- $_ := set $labels "istio.io/rev" (toString $istio.revision) }}{{- else }}{{- $_ := set $labels "sidecar.istio.io/inject" "true" }}{{- end -}}
{{- end -}}
{{- with $labels }}{{ toYaml . }}{{ end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "smtpd.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "smtpd.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
