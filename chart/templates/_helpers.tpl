{{- define "keycloak-config-kog.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* configmap name holding the OAS for a given resource key */}}
{{- define "keycloak-config-kog.cmName" -}}
{{- printf "%s-%s" .root.Release.Name .key -}}
{{- end -}}
