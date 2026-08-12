{{/* Name helpers */}}
{{- define "headroom.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "headroom.fullname" -}}
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

{{- define "headroom.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "headroom.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "headroom.selectorLabels" -}}
app.kubernetes.io/name: {{ include "headroom.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "headroom.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "headroom.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "headroom.qdrantFullname" -}}
{{- printf "%s-qdrant" (include "headroom.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "headroom.neo4jFullname" -}}
{{- printf "%s-neo4j" (include "headroom.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Secret name holding the chart-managed proxy token / neo4j password.
*/}}
{{- define "headroom.secretName" -}}
{{- printf "%s-secrets" (include "headroom.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Resolve the proxy token, preserving an already-generated one across upgrades.

Rendered ONLY by secret.yaml. Every consumer references the Secret by
secretKeyRef, so randAlphaNum is never evaluated twice for one release
(which would otherwise emit a different token into each manifest).
*/}}
{{- define "headroom.proxyToken" -}}
{{- if .Values.auth.token -}}
{{- .Values.auth.token -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "headroom.secretName" .) -}}
{{- $prev := "" -}}
{{- if $existing -}}
{{- $prev = get ($existing.data | default dict) "proxy-token" -}}
{{- end -}}
{{- if $prev -}}
{{- b64dec $prev -}}
{{- else -}}
{{- randAlphaNum 48 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Same preserve-across-upgrade contract for the Neo4j password. */}}
{{- define "headroom.neo4jPassword" -}}
{{- if .Values.memory.neo4j.auth.password -}}
{{- .Values.memory.neo4j.auth.password -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "headroom.secretName" .) -}}
{{- $prev := "" -}}
{{- if $existing -}}
{{- $prev = get ($existing.data | default dict) "neo4j-password" -}}
{{- end -}}
{{- if $prev -}}
{{- b64dec $prev -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Where the proxy token is read from (chart Secret or a user-supplied one). */}}
{{- define "headroom.authSecretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "headroom.secretName" . -}}
{{- end -}}
{{- end -}}

{{- define "headroom.authSecretKey" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecretKey -}}
{{- else -}}
proxy-token
{{- end -}}
{{- end -}}

{{- define "headroom.neo4jSecretName" -}}
{{- if .Values.memory.neo4j.auth.existingSecret -}}
{{- .Values.memory.neo4j.auth.existingSecret -}}
{{- else -}}
{{- include "headroom.secretName" . -}}
{{- end -}}
{{- end -}}

{{- define "headroom.neo4jSecretKey" -}}
{{- if .Values.memory.neo4j.auth.existingSecret -}}
{{- .Values.memory.neo4j.auth.existingSecretKey -}}
{{- else -}}
neo4j-password
{{- end -}}
{{- end -}}

{{- define "headroom.embeddingsSecretName" -}}
{{- if .Values.memory.embeddings.existingSecret -}}
{{- .Values.memory.embeddings.existingSecret -}}
{{- else -}}
{{- include "headroom.secretName" . -}}
{{- end -}}
{{- end -}}

{{- define "headroom.embeddingsSecretKey" -}}
{{- if .Values.memory.embeddings.existingSecret -}}
{{- .Values.memory.embeddings.existingSecretKey -}}
{{- else -}}
openai-api-key
{{- end -}}
{{- end -}}

{{/* True when the chart manages its own Secret (token, neo4j password and/or embeddings key). */}}
{{- define "headroom.createsSecret" -}}
{{- $needToken := and .Values.auth.enabled (not .Values.auth.existingSecret) -}}
{{- $needNeo := and (include "headroom.memoryActive" . | eq "true") .Values.memory.neo4j.enabled (not .Values.memory.neo4j.external.enabled) (not .Values.memory.neo4j.auth.existingSecret) -}}
{{- $needEmbed := and .Values.memory.enabled .Values.memory.embeddings.apiKey (not .Values.memory.embeddings.existingSecret) -}}
{{- if or $needToken $needNeo $needEmbed -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "headroom.memoryActive" -}}
{{- if .Values.memory.enabled -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "headroom.qdrantUrl" -}}
{{- if .Values.memory.qdrant.external.enabled -}}
{{- .Values.memory.qdrant.external.url -}}
{{- else -}}
{{- printf "http://%s:6333" (include "headroom.qdrantFullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "headroom.neo4jUri" -}}
{{- if .Values.memory.neo4j.external.enabled -}}
{{- .Values.memory.neo4j.external.uri -}}
{{- else -}}
{{- printf "neo4j://%s:7687" (include "headroom.neo4jFullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Umbrella hoisting.

The workgroup chart sets `global.expose.*` once so both subcharts share a
domain, ingress class, Gateway and TLS certificate. Chart-local values always
win; the global is only a fallback.
*/}}
{{- define "headroom.globalExpose" -}}
{{- toYaml (dig "expose" dict (.Values.global | default dict)) -}}
{{- end -}}

{{- define "headroom.exposeHost" -}}
{{- $g := fromYaml (include "headroom.globalExpose" .) -}}
{{- if .Values.expose.host -}}
{{- .Values.expose.host -}}
{{- else if $g.domain -}}
{{- printf "%s.%s" (.Values.expose.subdomain | default "headroom") $g.domain -}}
{{- end -}}
{{- end -}}

{{- define "headroom.ingressClassName" -}}
{{- $g := fromYaml (include "headroom.globalExpose" .) -}}
{{- .Values.expose.ingress.className | default $g.ingressClassName | default "nginx" -}}
{{- end -}}

{{- define "headroom.tlsSecretName" -}}
{{- $g := fromYaml (include "headroom.globalExpose" .) -}}
{{- .Values.expose.ingress.tls.secretName | default $g.tlsSecretName | default (printf "%s-tls" (include "headroom.fullname" .)) -}}
{{- end -}}

{{- define "headroom.gatewayParentRefs" -}}
{{- $g := fromYaml (include "headroom.globalExpose" .) -}}
{{- toYaml (.Values.expose.gateway.parentRefs | default $g.gatewayParentRefs | default list) -}}
{{- end -}}

{{/*
Preflight guards. Rendered from a template so a misconfiguration fails at
`helm template`/`install` time with an actionable message rather than
producing a running-but-wrong deployment.
*/}}
{{- define "headroom.validate" -}}
{{- if not (has .Values.expose.mode (list "none" "ingress" "gateway")) -}}
{{- fail (printf "headroom: expose.mode must be one of none|ingress|gateway (got %q)" .Values.expose.mode) -}}
{{- end -}}

{{- if ne .Values.expose.mode "none" -}}
  {{- if and (not .Values.auth.enabled) (not .Values.auth.acknowledgeUnauthenticated) -}}
    {{- fail "headroom: refusing to expose the proxy with auth.enabled=false. Every /v1/* route would be reachable unauthenticated. Set auth.enabled=true (recommended), or auth.acknowledgeUnauthenticated=true to override." -}}
  {{- end -}}
  {{- if and (eq .Values.expose.mode "ingress") (not (include "headroom.exposeHost" .)) -}}
    {{- fail "headroom: expose.mode=ingress requires expose.host (or global.expose.domain from the workgroup umbrella)" -}}
  {{- end -}}
  {{- if eq .Values.expose.mode "gateway" -}}
    {{- if not (include "headroom.gatewayParentRefs" . | fromYamlArray) -}}
      {{- fail "headroom: expose.mode=gateway requires expose.gateway.parentRefs (or global.expose.gatewayParentRefs)" -}}
    {{- end -}}
    {{- if not ($.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1") -}}
      {{- fail "headroom: expose.mode=gateway requires the Gateway API (gateway.networking.k8s.io/v1), which is not installed on this cluster." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- if .Values.memory.enabled -}}
  {{- $upstreamImage := "ghcr.io/chopratejas/headroom" -}}
  {{- if and (eq .Values.image.repository $upstreamImage) (not .Values.memory.acknowledgeUnpatchedImage) -}}
    {{- fail (printf "headroom: memory.enabled=true needs an image built with patches/0001-headroom-neo4j-config-surface.patch, but image.repository is set to the published upstream image %q. That image has no configuration surface for the Neo4j half of the qdrant-neo4j backend, so memory would silently stay on local SQLite. Remove your image.repository override to use this repo's patched build (the chart default), or set memory.acknowledgeUnpatchedImage=true if upstream has merged the patch." $upstreamImage) -}}
  {{- end -}}
  {{- if not (or .Values.memory.embeddings.apiKey .Values.memory.embeddings.existingSecret) -}}
    {{- fail "headroom: memory.enabled=true requires memory.embeddings.apiKey or memory.embeddings.existingSecret. Qdrant stores vectors but does not produce them — the qdrant-neo4j backend embeds through an OpenAI-compatible /v1/embeddings endpoint, and with no key it fails to initialize on every attempt. The proxy would start, serve traffic, and never report ready: /readyz stays 503 with memory.initialized=false until the startup probe kills it. Set memory.embeddings.existingSecret to a Secret you manage (recommended), or memory.embeddings.apiKey. Point memory.embeddings.baseUrl at a self-hosted embeddings endpoint if you do not want to call OpenAI." -}}
  {{- end -}}
  {{- if and .Values.memory.qdrant.external.enabled (not .Values.memory.qdrant.external.url) -}}
    {{- fail "headroom: memory.qdrant.external.enabled=true requires memory.qdrant.external.url" -}}
  {{- end -}}
  {{- if and .Values.memory.neo4j.external.enabled (not .Values.memory.neo4j.external.uri) -}}
    {{- fail "headroom: memory.neo4j.external.enabled=true requires memory.neo4j.external.uri" -}}
  {{- end -}}
  {{- if .Values.stateless -}}
    {{- fail "headroom: memory.enabled=true is incompatible with stateless=true (upstream disables memory when HEADROOM_STATELESS is set)." -}}
  {{- end -}}
{{- end -}}
{{- end -}}
