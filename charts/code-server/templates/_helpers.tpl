{{- define "code-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "code-server.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s" (include "code-server.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "code-server.labels" -}}
app.kubernetes.io/name: {{ include "code-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: code-server
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "code-server.selectorLabels" -}}
app: {{ include "code-server.fullname" . }}
{{- end -}}

{{/*
`annotations:` block carrying the keep policy, or nothing.

Used on every object that must survive `helm uninstall`: the PVCs holding pi's
login/sessions/skills and the workspace, and any Secret this chart creates
itself. Uninstalling a release must never be how this data is lost — see
README's uninstall section.
*/}}
{{- define "code-server.keepAnnotations" -}}
{{- if .Values.keepOnUninstall -}}
annotations:
  helm.sh/resource-policy: keep
{{- end -}}
{{- end -}}

{{/*
The image reference.

A digest wins over a tag whenever one is set (immutable, and what the live
instance pins). The tag fallback sanitises .Chart.AppVersion: appVersion is
"<code-server>+pi<pi>" and an OCI tag may not contain "+", so the raw value
renders an image Kubernetes rejects with InvalidImageName. Same `replace` the
helm.sh/chart label above already uses.
*/}}
{{- define "code-server.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default (.Chart.AppVersion | replace "+" "_") }}
{{- end -}}
{{- end -}}
