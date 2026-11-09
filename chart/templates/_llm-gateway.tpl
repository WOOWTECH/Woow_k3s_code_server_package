{{/* Same-workspace LiteLLM wiring helpers (llmGateway.baseUrl → LITELLM_BASE_URL,
     networkPolicy.litellmEgress). Separate file so it never collides with _helpers.tpl edits. */}}
{{/*
Same-workspace LiteLLM gateway (llmGateway.baseUrl, injected by the platform:
http://<release>-litellm.<ns>.svc.cluster.local:4000/v1). CR/LF stripped, trimmed,
one trailing "/" removed; anything that is not a plain http(s) URL prints "" (no
env, no egress hole; NOTES says so) — never a render failure. A missing
llmGateway map (--reuse-values from an older chart) counts as "".
*/}}
{{- define "code-server.llmGatewayRawBaseUrl" -}}
{{- (.Values.llmGateway | default dict).baseUrl | default "" | toString | replace "\r" "" | replace "\n" "" | trim -}}
{{- end -}}
{{- define "code-server.llmGatewayBaseUrl" -}}
{{- $u := include "code-server.llmGatewayRawBaseUrl" . | trimSuffix "/" -}}
{{- if regexMatch "^https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%\\[\\]-]+$" $u -}}{{ $u }}{{- end -}}
{{- end -}}
{{/* Runtime ConfigMap carrying LITELLM_BASE_URL (templates/llm-gateway-configmap.yaml). */}}
{{- define "code-server.llmGatewayConfigMapName" -}}
{{- printf "%s-llm-gateway" (include "code-server.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
