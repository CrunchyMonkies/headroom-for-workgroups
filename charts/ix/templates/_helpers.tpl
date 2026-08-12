{{- define "ix.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ix.fullname" -}}
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

{{- define "ix.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "ix.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "ix.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ix.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ix.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ix.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "ix.arangoFullname" -}}
{{- printf "%s-arangodb" (include "ix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ix.secretName" -}}
{{- printf "%s-secrets" (include "ix.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ix.arangoHost" -}}
{{- if .Values.arangodb.external.enabled -}}
{{- .Values.arangodb.external.host -}}
{{- else -}}
{{- include "ix.arangoFullname" . -}}
{{- end -}}
{{- end -}}

{{- define "ix.arangoPort" -}}
{{- if .Values.arangodb.external.enabled -}}
{{- .Values.arangodb.external.port -}}
{{- else -}}
8529
{{- end -}}
{{- end -}}

{{- define "ix.arangoSecretName" -}}
{{- if .Values.arangodb.existingSecret -}}
{{- .Values.arangodb.existingSecret -}}
{{- else -}}
{{- include "ix.secretName" . -}}
{{- end -}}
{{- end -}}

{{- define "ix.arangoSecretKey" -}}
{{- if .Values.arangodb.existingSecret -}}
{{- .Values.arangodb.existingSecretKey -}}
{{- else -}}
arango-password
{{- end -}}
{{- end -}}

{{/*
Resolve the ArangoDB password, preserving a generated one across upgrades.
Rendered only by secret.yaml; consumers use secretKeyRef.
*/}}
{{- define "ix.arangoPassword" -}}
{{- if .Values.arangodb.password -}}
{{- .Values.arangodb.password -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "ix.secretName" .) -}}
{{- $prev := "" -}}
{{- if $existing -}}
{{- $prev = get ($existing.data | default dict) "arango-password" -}}
{{- end -}}
{{- if $prev -}}
{{- b64dec $prev -}}
{{- else -}}
{{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ix.oauth2ProxyEnabled" -}}
{{- if eq .Values.auth.mode "oauth2Proxy" -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/* The port the Service targets: the sidecar when present, else the API. */}}
{{- define "ix.serviceTargetPort" -}}
{{- if eq (include "ix.oauth2ProxyEnabled" .) "true" -}}auth{{- else -}}http{{- end -}}
{{- end -}}

{{/*
Umbrella hoisting — see the matching helpers in charts/headroom. The workgroup
chart sets global.expose.* once; chart-local values always win.
*/}}
{{- define "ix.globalExpose" -}}
{{- toYaml (dig "expose" dict (.Values.global | default dict)) -}}
{{- end -}}

{{- define "ix.exposeHost" -}}
{{- $g := fromYaml (include "ix.globalExpose" .) -}}
{{- if .Values.expose.host -}}
{{- .Values.expose.host -}}
{{- else if $g.domain -}}
{{- printf "%s.%s" (.Values.expose.subdomain | default "ix") $g.domain -}}
{{- end -}}
{{- end -}}

{{- define "ix.ingressClassName" -}}
{{- $g := fromYaml (include "ix.globalExpose" .) -}}
{{- .Values.expose.ingress.className | default $g.ingressClassName | default "nginx" -}}
{{- end -}}

{{- define "ix.tlsSecretName" -}}
{{- $g := fromYaml (include "ix.globalExpose" .) -}}
{{- .Values.expose.ingress.tls.secretName | default $g.tlsSecretName | default (printf "%s-tls" (include "ix.fullname" .)) -}}
{{- end -}}

{{- define "ix.gatewayParentRefs" -}}
{{- $g := fromYaml (include "ix.globalExpose" .) -}}
{{- toYaml (.Values.expose.gateway.parentRefs | default $g.gatewayParentRefs | default list) -}}
{{- end -}}

{{- define "ix.validate" -}}
{{- if not (has .Values.expose.mode (list "none" "ingress" "gateway")) -}}
{{- fail (printf "ix: expose.mode must be one of none|ingress|gateway (got %q)" .Values.expose.mode) -}}
{{- end -}}
{{- if not (has .Values.auth.mode (list "none" "basic" "oauth2Proxy")) -}}
{{- fail (printf "ix: auth.mode must be one of none|basic|oauth2Proxy (got %q)" .Values.auth.mode) -}}
{{- end -}}

{{- if ne .Values.expose.mode "none" -}}
  {{- if and (eq .Values.auth.mode "none") (not .Values.auth.acknowledgeUnauthenticated) -}}
    {{- fail "ix: refusing to expose the memory-layer with auth.mode=none. The Ix API has no built-in authentication and is write-capable, so anyone reaching the host could read or destroy the graph. Set auth.mode=basic or auth.mode=oauth2Proxy, or auth.acknowledgeUnauthenticated=true to override." -}}
  {{- end -}}
  {{- if and (eq .Values.expose.mode "gateway") (eq .Values.auth.mode "basic") -}}
    {{- fail "ix: auth.mode=basic works through ingress-controller annotations and has no Gateway API equivalent. Use auth.mode=oauth2Proxy with expose.mode=gateway." -}}
  {{- end -}}
  {{- if and (eq .Values.expose.mode "ingress") (not (include "ix.exposeHost" .)) -}}
    {{- fail "ix: expose.mode=ingress requires expose.host (or global.expose.domain from the workgroup umbrella)" -}}
  {{- end -}}
  {{- if eq .Values.expose.mode "gateway" -}}
    {{- if not (include "ix.gatewayParentRefs" . | fromYamlArray) -}}
      {{- fail "ix: expose.mode=gateway requires expose.gateway.parentRefs (or global.expose.gatewayParentRefs)" -}}
    {{- end -}}
    {{- if not ($.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1") -}}
      {{- fail "ix: expose.mode=gateway requires the Gateway API (gateway.networking.k8s.io/v1), which is not installed on this cluster." -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- if and (eq .Values.auth.mode "basic") (not .Values.auth.basic.existingSecret) -}}
{{- fail "ix: auth.mode=basic requires auth.basic.existingSecret (an htpasswd Secret with an 'auth' key)" -}}
{{- end -}}
{{- if eq .Values.auth.mode "oauth2Proxy" -}}
  {{- if not .Values.auth.oauth2Proxy.existingSecret -}}
    {{- fail "ix: auth.mode=oauth2Proxy requires auth.oauth2Proxy.existingSecret with keys client-id, client-secret and cookie-secret" -}}
  {{- end -}}
  {{- if and (eq .Values.auth.oauth2Proxy.provider "oidc") (not .Values.auth.oauth2Proxy.oidcIssuerUrl) -}}
    {{- fail "ix: auth.oauth2Proxy.provider=oidc requires auth.oauth2Proxy.oidcIssuerUrl" -}}
  {{- end -}}
{{- end -}}

{{- if and .Values.arangodb.external.enabled (not .Values.arangodb.external.host) -}}
{{- fail "ix: arangodb.external.enabled=true requires arangodb.external.host" -}}
{{- end -}}
{{- if and (not .Values.arangodb.enabled) (not .Values.arangodb.external.enabled) -}}
{{- fail "ix: the memory-layer needs a database — enable arangodb or set arangodb.external.enabled=true" -}}
{{- end -}}
{{- end -}}
