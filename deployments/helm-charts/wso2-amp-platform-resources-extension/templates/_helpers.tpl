{{/*
Expand the name of the chart.
*/}}
{{- define "amp-build-extension.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "amp-build-extension.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
These labels should be applied to all resources and include:
- helm.sh/chart: Chart name and version
- app.kubernetes.io/name: Name of the application
- app.kubernetes.io/instance: Unique name identifying the instance of an application
- app.kubernetes.io/version: Current version of the application
- app.kubernetes.io/managed-by: Tool being used to manage the application
- app.kubernetes.io/part-of: Name of a higher level application this one is part of
*/}}
{{- define "amp-build-extension.labels" -}}
helm.sh/chart: {{ include "amp-build-extension.chart" . }}
{{ include "amp-build-extension.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openchoreo
{{- with .Values.global.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
These labels are used for pod selectors and should be stable across upgrades.
They should NOT include version or chart labels as these change with upgrades.
*/}}
{{- define "amp-build-extension.selectorLabels" -}}
app.kubernetes.io/name: {{ include "amp-build-extension.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Get the registry endpoint for workflow templates
Returns external endpoint if global.baseDomain is set, otherwise uses configured endpoint
*/}}
{{- define "openchoreo-workflow-plane.registryEndpoint" -}}
{{- if .Values.global.baseDomain -}}
  {{- printf "registry.%s" .Values.global.baseDomain -}}
{{- else -}}
  {{- .Values.global.registry.endpoint -}}
{{- end -}}
{{- end -}}

{{/*
Get buildpack image by ID
Returns the appropriate image reference based on buildpackCache.enabled setting.
When caching is enabled, returns the cached image path prefixed with registry endpoint.
When caching is disabled, returns the remote image reference directly.

Usage:
  {{ include "openchoreo-workflow-plane.buildpackImage" (dict "id" "google-builder" "context" .) }}

Parameters:
  - id: The unique identifier of the buildpack image (e.g., "google-builder", "ballerina-run")
  - context: The Helm context (usually .)
*/}}
{{- define "openchoreo-workflow-plane.buildpackImage" -}}
{{- $id := .id -}}
{{- $ctx := .context -}}
{{- $cacheEnabled := $ctx.Values.global.defaultResources.buildpackCache.enabled -}}
{{- $registryEndpoint := include "openchoreo-workflow-plane.registryEndpoint" $ctx -}}
{{- $found := false -}}
{{- range $ctx.Values.global.defaultResources.buildpackCache.images -}}
  {{- if eq .id $id -}}
    {{- $found = true -}}
    {{- if $cacheEnabled -}}
      {{- printf "%s/%s" $registryEndpoint .cachedImage -}}
    {{- else -}}
      {{- .remoteImage -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not $found -}}
  {{- fail (printf "Buildpack image with id '%s' not found in buildpackCache.images" $id) -}}
{{- end -}}
{{- end -}}

{{/*
Registry CA env var — renders a container env entry carrying
global.registry.caCert (PEM), when set. Read by
"openchoreo-workflow-plane.registryTrustSetup" (below) inside the container's shell
script. Kept in an env var rather than baked straight into the shell heredoc so the
YAML block-scalar indentation of the surrounding script can never corrupt the
multi-line PEM content.
Usage: {{ include "openchoreo-workflow-plane.registryCaEnvVar" . }}  (inside an `env:` list)
*/}}
{{- define "openchoreo-workflow-plane.registryCaEnvVar" -}}
{{- if .Values.global.registry.caCert }}
- name: AMP_REGISTRY_CA_CERT
  value: {{ .Values.global.registry.caCert | quote }}
{{- end -}}
{{- end -}}

{{/*
Registry trust setup — shell snippet that configures Podman's trust for
REGISTRY_ENDPOINT before any pull/build/push:
  1. Always appends a [[registry]] block to /etc/containers/registries.conf setting
     `insecure` from global.defaultResources.registry.tlsVerify, so tlsVerify=false
     behaves consistently across every build/publish template (previously only
     publish-image.yaml's explicit --tls-verify flag honored it).
  2. When global.registry.caCert is set, writes it to the registry's certs.d
     directory (/etc/containers/certs.d/<endpoint>/ca.crt) — the containers/image
     mechanism for trusting one registry's custom CA (self-signed or
     internal/corporate) without disabling verification or touching the container's
     system-wide trust store. No-op (verification stays on, using the image's stock
     CA bundle) when caCert is unset.
Must run after AMP_REGISTRY_CA_CERT is available (see registryCaEnvVar) and before
any podman/pack command that touches REGISTRY_ENDPOINT. Assumes the caller has
already created /etc/containers/ (mkdir -p).
Usage: {{ include "openchoreo-workflow-plane.registryTrustSetup" . | nindent 12 }}
*/}}
{{- define "openchoreo-workflow-plane.registryTrustSetup" -}}
{{- $endpoint := include "openchoreo-workflow-plane.registryEndpoint" . }}
cat >> /etc/containers/registries.conf <<AMPREGISTRYCONF
[[registry]]
location = "{{ $endpoint }}"
insecure = {{ not .Values.global.defaultResources.registry.tlsVerify }}
AMPREGISTRYCONF
{{- if .Values.global.registry.caCert }}
mkdir -p "/etc/containers/certs.d/{{ $endpoint }}"
printf '%s\n' "$AMP_REGISTRY_CA_CERT" > "/etc/containers/certs.d/{{ $endpoint }}/ca.crt"
{{- end -}}
{{- end -}}
