{{/* code-server helpers. Deployed per-tenant by paas-operator as svc-{ref[:8]} into paas-ws-*. */}}
{{- define "code-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "code-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- define "code-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "code-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "code-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
{{- define "code-server.labels" -}}
helm.sh/chart: {{ include "code-server.chart" . }}
{{ include "code-server.selectorLabels" . }}
app.kubernetes.io/component: code-server
app.kubernetes.io/part-of: code-server
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}
{{- define "code-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "code-server.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
{{/* Secret carrying admin_password — auth.existingSecret wins. */}}
{{- define "code-server.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-secret" (include "code-server.fullname" .) -}}
{{- end -}}
{{- end -}}
{{/* explicit value wins; else the live Secret's value (stable across upgrades); else generate. */}}
{{- define "code-server.resolveSecretValue" -}}
{{- $ctx := .ctx -}}
{{- $val := .explicit -}}
{{- if not $val -}}
  {{- $live := lookup "v1" "Secret" $ctx.Release.Namespace (include "code-server.secretName" $ctx) -}}
  {{- if $live -}}
    {{- with $live.data -}}
      {{- with (index . $.key) -}}
        {{- $val = . | b64dec -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not $val -}}
  {{- $val = randAlphaNum 24 -}}
{{- end -}}
{{- $val -}}
{{- end -}}

{{/*
{{/* PVC names — existingClaim wins. */}}
{{- define "code-server.workspacePvcName" -}}
{{- default (printf "%s-workspace" (include "code-server.fullname" .)) .Values.persistence.workspace.existingClaim -}}
{{- end -}}
{{- define "code-server.piDataPvcName" -}}
{{- default (printf "%s-pi-data" (include "code-server.fullname" .)) .Values.persistence.piData.existingClaim -}}
{{- end -}}

{{/*
Host of codeServer.publicUrl for --trusted-origins. code-server compares the
browser Origin's host (no scheme) against this list, so passing the full URL
would never match. Fails the render on a URL without a host.
*/}}
{{- define "code-server.trustedOriginHost" -}}
{{- $u := .Values.codeServer.publicUrl | toString -}}
{{- if $u -}}
{{- $h := (urlParse $u).host -}}
{{- if not $h -}}
{{- fail (printf "codeServer.publicUrl %q has no host (expected https://<host>)" $u) -}}
{{- end -}}
{{- $h -}}
{{- end -}}
{{- end -}}
