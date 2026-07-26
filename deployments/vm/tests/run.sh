#!/usr/bin/env bash
# Unit tests for lib-vm.sh + lib-advanced.sh. Run: bash deployments/vm/tests/run.sh
#
# Test groups set AMP_HOST_*/config vars and call the sourced lib functions, which
# read them via bash dynamic scope. shellcheck cannot follow that across the source
# boundary, and the per-group subshells are intentional isolation, so the following
# are expected false positives here:
# shellcheck disable=SC2034  # vars are consumed by sourced lib functions
# shellcheck disable=SC2030,SC2031  # subshell isolation of test-group vars is intentional
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib-vm.sh disable=SC1091
source "${SCRIPT_DIR}/../lib-vm.sh"
# shellcheck source=../lib-advanced.sh disable=SC1091
source "${SCRIPT_DIR}/../lib-advanced.sh"
# shellcheck source=../lib-tls.sh disable=SC1091
source "${SCRIPT_DIR}/../lib-tls.sh"
# shellcheck source=../lib-bootstrap.sh disable=SC1091
source "${SCRIPT_DIR}/../lib-bootstrap.sh"

# Failures are recorded in a marker file (not just a shell var) so that assertions
# inside subshells — used to scope AMP_HOST_* per test group — still fail the suite.
FAILLOG="$(mktemp)"
trap 'rm -f "$FAILLOG"' EXIT
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$label"
  else
    printf 'FAIL - %s\n      expected: %q\n      actual:   %q\n' "$label" "$expected" "$actual"
    echo 1 >>"$FAILLOG"
  fi
}
# has <haystack> <needle> -> "yes" if needle present, else "no"
# (-- so needles starting with '-' aren't parsed as grep options)
has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; }

# --- vm_host ---
assert_eq "vm_host console" "console.amp.203.0.113.10.sslip.io" "$(vm_host console 203.0.113.10)"
assert_eq "vm_host thunder" "thunder.amp.203.0.113.10.sslip.io" "$(vm_host thunder 203.0.113.10)"

# --- build_amp_helm_args (external gateways on by default) ---
amp="$(build_amp_helm_args 203.0.113.10 true)"
# Service settings are emitted under BOTH chart keys (agentManager + agentManagerService).
assert_eq "amp serverPublicURL (service key)" \
  "agentManagerService.config.serverPublicURL=https://api.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'agentManagerService.config.serverPublicURL' <<<"$amp")"
assert_eq "amp serverPublicURL (legacy key)" \
  "agentManager.config.serverPublicURL=https://api.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'agentManager.config.serverPublicURL' <<<"$amp")"
assert_eq "amp oauthAuthorizationServers (service key)" \
  "agentManagerService.config.oauthAuthorizationServers=https://thunder.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'agentManagerService.config.oauthAuthorizationServers' <<<"$amp")"
assert_eq "amp keyManager.issuer (service key)" \
  "agentManagerService.config.keyManager.issuer=https://thunder.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'agentManagerService.config.keyManager.issuer' <<<"$amp")"
# tlsEnabled=true makes amp-api advertise the https deployed-agent endpoint variant;
# emitted under both keys (old agentManager + new agentManagerService).
assert_eq "amp tlsEnabled (service key)" \
  "agentManagerService.config.tlsEnabled=true" \
  "$(grep -F 'agentManagerService.config.tlsEnabled' <<<"$amp")"
assert_eq "amp tlsEnabled (legacy key)" \
  "agentManager.config.tlsEnabled=true" \
  "$(grep -F 'agentManager.config.tlsEnabled' <<<"$amp")"
assert_eq "amp console apiBaseUrl" \
  "console.config.apiBaseUrl=https://api.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'config.apiBaseUrl' <<<"$amp")"
assert_eq "amp console obsApiBaseUrl" \
  "console.config.obsApiBaseUrl=https://observer.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'obsApiBaseUrl' <<<"$amp")"
assert_eq "amp console instrumentationUrl" \
  "console.config.instrumentationUrl=https://gateway.amp.203.0.113.10.sslip.io/otel" \
  "$(grep -F 'instrumentationUrl' <<<"$amp")"
assert_eq "amp console signInRedirectURL" \
  "console.config.auth.signInRedirectURL=https://console.amp.203.0.113.10.sslip.io/login" \
  "$(grep -F 'signInRedirectURL' <<<"$amp")"
# external gateways on by default => full-URL gatewayControlPlaneUrl
assert_eq "amp cp url by default" \
  "console.config.gatewayControlPlaneUrl=https://cp.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'gatewayControlPlaneUrl' <<<"$amp")"

# --- build_amp_helm_args (external gateways disabled) ---
amp_nocp="$(build_amp_helm_args 203.0.113.10 false)"
assert_eq "amp no cp when disabled" "" "$(grep -F 'gatewayControlPlaneUrl' <<<"$amp_nocp")"

# --- build_gateway_helm_args sets the published vhost + user-token keymanager issuer ---
gw="$(build_gateway_helm_args 203.0.113.10)"
assert_eq "gateway vhost" \
  "gateway.vhost=https://gateway.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'gateway.vhost' <<<"$gw")"
assert_eq "gateway hostname matches vhost host" \
  "gateway.hostname=gateway.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'gateway.hostname' <<<"$gw")"
# keymanagers supplied as a full list via --set-json (a list-index --set wipes the
# other entry); ThunderKeyManager gets the public issuer, agent-manager-service kept.
assert_eq "gateway keymanagers via --set-json" "yes" "$(has "$gw" '--set-json')"
km_json="$(grep -F 'keymanagers=' <<<"$gw")"
assert_eq "gateway keymanagers is a full list" "yes" "$(has "$km_json" 'keymanagers=[{')"
assert_eq "gateway keeps agent-manager-service km" "yes" "$(has "$km_json" '"name":"agent-manager-service"')"
assert_eq "gateway ThunderKeyManager public issuer" "yes" \
  "$(has "$km_json" '"name":"ThunderKeyManager","issuer":"https://thunder.amp.203.0.113.10.sslip.io"')"
assert_eq "gateway no sparse/null keymanager" "no" "$(has "$km_json" 'null')"

# --- build_observability_helm_args points the traces observer at the public issuer ---
obs="$(build_observability_helm_args 203.0.113.10)"
assert_eq "observability traces issuer -> public thunder" \
  "tracesObserver.auth.issuer=https://thunder.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'tracesObserver.auth.issuer' <<<"$obs")"

# --- render_dataplane_external_ingress: public host on :443, both http+https entries
#     bound to the internal http listener (amp-api advertises the https variant) ---
dpe="$(render_dataplane_external_ingress 203.0.113.10)"
assert_eq "dp external public host"    "yes" "$(has "$dpe" 'host: "agents.203.0.113.10.sslip.io"')"
assert_eq "dp external port 443"       "yes" "$(has "$dpe" 'port: 443')"
assert_eq "dp external listener http"  "yes" "$(has "$dpe" 'listenerName: http')"
assert_eq "dp external has http entry"  "yes" "$(printf '%s\n' "$dpe" | grep -qE '^        http:' && echo yes || echo no)"
assert_eq "dp external has https entry" "yes" "$(printf '%s\n' "$dpe" | grep -qE '^        https:' && echo yes || echo no)"
assert_eq "dp external not local default (19080)" "no" "$(has "$dpe" 'port: 1908')"

# --- build_cp_helm_args points OpenChoreo CP OIDC issuer at the public Thunder URL ---
cp_args="$(build_cp_helm_args 203.0.113.10)"
assert_eq "cp oidc issuer" \
  "security.oidc.issuer=https://thunder.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'security.oidc.issuer' <<<"$cp_args")"
assert_eq "cp oidc tokenUrl" \
  "security.oidc.tokenUrl=https://thunder.amp.203.0.113.10.sslip.io/oauth2/token" \
  "$(grep -F 'security.oidc.tokenUrl' <<<"$cp_args")"

# --- build_thunder_helm_args ---
th="$(build_thunder_helm_args 203.0.113.10)"
assert_eq "thunder ocIngress.hostname" \
  "thunder.ocIngress.hostname=thunder.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'ocIngress.hostname' <<<"$th")"
assert_eq "thunder server.publicUrl" \
  "thunder.configuration.server.publicUrl=https://thunder.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'server.publicUrl' <<<"$th")"
assert_eq "thunder jwt.issuer" \
  "thunder.configuration.jwt.issuer=https://thunder.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'jwt.issuer' <<<"$th")"
assert_eq "thunder gateClient.scheme" \
  "thunder.configuration.gateClient.scheme=https" \
  "$(grep -F 'gateClient.scheme' <<<"$th")"
assert_eq "thunder gateClient.port" \
  "thunder.configuration.gateClient.port=443" \
  "$(grep -F 'gateClient.port' <<<"$th")"
assert_eq "thunder cors origin" \
  "thunder.configuration.cors.allowedOrigins[0]=https://console.amp.203.0.113.10.sslip.io" \
  "$(grep -F 'cors.allowedOrigins' <<<"$th")"
# redirectUri emitted under both setup (legacy) and bootstrap (>=0.15.0) keys
assert_eq "thunder console redirectUri (bootstrap key)" \
  "thunder.bootstrap.ampConsoleClient.redirectUris[0]=https://console.amp.203.0.113.10.sslip.io/login" \
  "$(grep -F 'thunder.bootstrap.ampConsoleClient.redirectUris' <<<"$th")"
assert_eq "thunder console redirectUri (legacy setup key)" \
  "thunder.setup.ampConsoleClient.redirectUris[0]=https://console.amp.203.0.113.10.sslip.io/login" \
  "$(grep -F 'thunder.setup.ampConsoleClient.redirectUris' <<<"$th")"

# --- render_k3d_vm_config ---
k3d_in="$(printf '%s\n' \
  'ports:' \
  '  - port: 3000:3000' \
  '    nodeFilters:' \
  '      - loadbalancer' \
  '  - port: 11082:9200' \
  '    nodeFilters:' \
  '      - loadbalancer')"
k3d_out="$(render_k3d_vm_config <<<"$k3d_in")"
assert_eq "k3d rebinds 3000" \
  "  - port: 127.0.0.1:3000:3000" \
  "$(grep -F '3000' <<<"$k3d_out")"
assert_eq "k3d rebinds mismatched ports" \
  "  - port: 127.0.0.1:11082:9200" \
  "$(grep -F '11082' <<<"$k3d_out")"
assert_eq "k3d leaves nodeFilters intact" \
  "    nodeFilters:" \
  "$(grep -F 'nodeFilters' <<<"$k3d_out" | head -1)"
assert_eq "k3d leaves already-bound entry untouched" \
  "  - port: 127.0.0.1:3000:3000" \
  "$(render_k3d_vm_config <<<'  - port: 127.0.0.1:3000:3000')"
# registry mirror endpoint -> node host (so node containerd can pull); key untouched
reg_in="$(printf '%s\n' \
  '    mirrors:' \
  '      "host.k3d.internal:10082":' \
  '        endpoint:' \
  '          - http://host.k3d.internal:10082')"
reg_out="$(render_k3d_vm_config <<<"$reg_in")"
assert_eq "k3d registry endpoint -> node host" \
  "          - http://k3d-amp-local-server-0:10082" \
  "$(grep -F 'endpoint' -A1 <<<"$reg_out" | grep -F 'http://')"
assert_eq "k3d registry mirror key untouched" \
  '      "host.k3d.internal:10082":' \
  "$(grep -F '"host.k3d.internal:10082":' <<<"$reg_out")"

# --- render_caddyfile (with email, external gateways disabled => no cp) ---
cf="$(render_caddyfile 203.0.113.10 "ops@example.com" false)"
assert_eq "caddy email block" "	email ops@example.com" "$(grep -F 'email ops@example.com' <<<"$cf")"
assert_eq "caddy console site" "console.amp.203.0.113.10.sslip.io {" "$(grep -F 'console.amp' <<<"$cf" | head -1)"
assert_eq "caddy console upstream" "	reverse_proxy 127.0.0.1:3000" "$(grep -F '127.0.0.1:3000' <<<"$cf")"
assert_eq "caddy thunder upstream" "	reverse_proxy 127.0.0.1:8080" "$(grep -F '127.0.0.1:8080' <<<"$cf")"
# gateway host routes through the kgateway data plane (19080), not the ClusterIP
# runtime (22893) which is not node-published; scope the grep to the gateway block
# since 19080 is shared with the agents site.
assert_eq "caddy gateway upstream (via kgateway)" "	reverse_proxy 127.0.0.1:19080" \
  "$(grep -F -A8 'gateway.amp.203.0.113.10.sslip.io {' <<<"$cf" | grep -F 'reverse_proxy' | head -1)"
assert_eq "caddy no 22893 dead-end" "" "$(grep -F '127.0.0.1:22893' <<<"$cf")"
assert_eq "caddy no cp when disabled" "" "$(grep -F 'cp.amp' <<<"$cf")"
assert_eq "caddy api upstream" "	reverse_proxy 127.0.0.1:9000" "$(grep -F '127.0.0.1:9000' <<<"$cf")"
assert_eq "caddy observer upstream" "	reverse_proxy 127.0.0.1:9098" "$(grep -F '127.0.0.1:9098' <<<"$cf")"
assert_eq "caddy registry site" "registry.amp.203.0.113.10.sslip.io {" "$(grep -F 'registry.amp' <<<"$cf" | head -1)"
assert_eq "caddy registry upstream" "	reverse_proxy 127.0.0.1:10082" "$(grep -F -A6 'registry.amp.203.0.113.10.sslip.io {' <<<"$cf" | grep -F 'reverse_proxy' | head -1)"

# --- render_caddyfile: always 443-only TLS-ALPN-01 (disable_redirects + per-site
#     issuer acme/disable_http_challenge); no http mode, no port-80 redirect ---
cf_tls="$(render_caddyfile 203.0.113.10 "ops@example.com" true)"
assert_eq "global disable_redirects"   "yes" "$(has "$cf_tls" 'auto_https disable_redirects')"
assert_eq "issuer acme"                "yes" "$(has "$cf_tls" 'issuer acme')"
assert_eq "disable_http_challenge"     "yes" "$(has "$cf_tls" 'disable_http_challenge')"
assert_eq "keeps email"                "yes" "$(has "$cf_tls" 'email ops@example.com')"
# per-site tls block on each public host incl. cp (7) + the agent wildcard (1) = 8
assert_eq "tls block per site (8)"     "8"   "$(grep -cF 'issuer acme' <<<"$cf_tls")"
# never serves plain http / disables auto-https
assert_eq "no auto_https off"          "no"  "$(has "$cf_tls" 'auto_https off')"
assert_eq "no http:// public site"     "no"  "$(has "$cf_tls" 'http://console')"

# --- external gateways on by default => cp block present (3rd arg omitted) ---
cf_default="$(render_caddyfile 203.0.113.10 "")"
assert_eq "caddy cp on by default" "cp.amp.203.0.113.10.sslip.io {" "$(grep -F 'cp.amp' <<<"$cf_default" | head -1)"
cf_cp="$(render_caddyfile 203.0.113.10 "" true)"
assert_eq "caddy cp tls skip verify" "			tls_insecure_skip_verify" "$(grep -F 'tls_insecure_skip_verify' <<<"$cf_cp")"

# --- build_platform_resources_helm_args: point the workload publisher at the
#     Thunder service directly (the gateway path 404s once Thunder's vhost moves to
#     the public sslip.io host), AND advertise the public agents host on the default
#     Environment so deployed-agent routes resolve to <org>-<project>.<agents-base>
#     (else OpenChoreo uses am-gateway.localhost and the console invoke URL is empty,
#     with try-out 405ing against its own host). Reads AMP_AGENTS_BASE from scope. ---
(
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com
  pr="$(build_platform_resources_helm_args)"
  assert_eq "platform-resources oauth tokenUrl (direct svc)" \
    "global.oauth.tokenUrl=http://amp-thunder-extension-service.amp-thunder.svc.cluster.local:8090/oauth2/token" \
    "$(grep -F 'global.oauth.tokenUrl' <<<"$pr")"
  assert_eq "platform-resources public registry endpoint" \
    "global.registry.endpoint=registry.amp.example.com" \
    "$(grep -F 'global.registry.endpoint' <<<"$pr")"
  assert_eq "platform-resources registry tls verify" \
    "global.defaultResources.registry.tlsVerify=true" \
    "$(grep -F 'global.defaultResources.registry.tlsVerify' <<<"$pr")"
  assert_eq "platform-resources oauth not via host.k3d.internal" "no" "$(has "$pr" 'host.k3d.internal')"
  assert_eq "platform-resources env gateway host (public agents base)" \
    "environment.gateway.http.host=agents.amp.example.com" \
    "$(grep -F 'environment.gateway.http.host' <<<"$pr")"
  assert_eq "platform-resources env gateway port 443" \
    "environment.gateway.http.port=443" \
    "$(grep -F 'environment.gateway.http.port' <<<"$pr")"
  # The console reads the https endpoint variant when tlsEnabled=true, so the
  # Environment override MUST carry an https variant too. Without it the binding
  # status has only an http externalURL, the console invoke URL is empty, and
  # try-out falls back to a relative /chat (405). Mirror dataplane_external_ingress.
  assert_eq "platform-resources env gateway https host (public agents base)" \
    "environment.gateway.https.host=agents.amp.example.com" \
    "$(grep -F 'environment.gateway.https.host' <<<"$pr")"
  assert_eq "platform-resources env gateway https port 443" \
    "environment.gateway.https.port=443" \
    "$(grep -F 'environment.gateway.https.port' <<<"$pr")"
  # No AMP_REGISTRY_CA_FILE set (letsencrypt/letsencrypt-dns/upstream, or byoc with a
  # publicly-trusted cert) => no --set-file at all; the registry's stock CA bundle is
  # sufficient and nothing should reference a nonexistent CA path.
  assert_eq "platform-resources no registry CA set-file by default" "no" \
    "$(has "$pr" '--set-file')"
)

# --- build_platform_resources_helm_args: registry CA (selfsigned/byoc TLS modes with
#     a non-publicly-trusted cert). AMP_REGISTRY_CA_FILE is passed via --set-file so
#     the chart can inject it into the build/publish Podman containers' per-registry
#     trust dir (global.registry.caCert) — without this, podman build/push fails
#     with "certificate signed by unknown authority" against a self-signed/internal
#     registry cert. ---
(
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com
  AMP_REGISTRY_CA_FILE=/opt/amp/certs/ca.crt
  pr="$(build_platform_resources_helm_args)"
  assert_eq "platform-resources registry CA set-file flag present" "yes" \
    "$(has "$pr" '--set-file')"
  assert_eq "platform-resources registry CA set-file value" \
    "global.registry.caCert=/opt/amp/certs/ca.crt" \
    "$(grep -F 'global.registry.caCert' <<<"$pr")"
)

# --- render_coredns_vm_config rewrites the in-cluster names to the server node ---
cd_cfg="$(render_coredns_vm_config k3d-amp-local-server-0)"
assert_eq "coredns configmap name" "yes" "$(has "$cd_cfg" 'name: coredns-custom')"
assert_eq "coredns openchoreo -> node" "yes" \
  "$(has "$cd_cfg" 'name regex (.+\.)?openchoreo\.localhost k3d-amp-local-server-0')"
assert_eq "coredns amp -> node" "yes" \
  "$(has "$cd_cfg" 'name regex (.+\.)?amp\.localhost k3d-amp-local-server-0')"
assert_eq "coredns host aliases -> node" "yes" \
  "$(has "$cd_cfg" 'name regex (host\.k3d\.internal|host\.docker\.internal) k3d-amp-local-server-0')"
assert_eq "coredns no longer targets host.k3d.internal as dest" "no" \
  "$(has "$cd_cfg" 'localhost host.k3d.internal')"

# --- render_caddyfile: deployed-agent invocation (wildcard site, on-demand TLS,
#     CORS, ask endpoint) ---
cf_ai="$(render_caddyfile 203.0.113.10 "ops@example.com" true)"
# No CSP: amp-api advertises the https agent endpoint (config.tlsEnabled=true), so the
# console emits https directly and no upgrade-insecure-requests workaround is needed.
assert_eq "console has no CSP workaround" "no" \
  "$(has "$cf_ai" 'Content-Security-Policy')"
assert_eq "global on_demand_tls ask" "yes" "$(has "$cf_ai" 'ask http://127.0.0.1:9753')"
assert_eq "on-demand ask endpoint site" "yes" "$(has "$cf_ai" 'http://127.0.0.1:9753 {')"
assert_eq "wildcard agent site" "yes" "$(has "$cf_ai" '*.agents.203.0.113.10.sslip.io {')"
assert_eq "agent site on_demand tls" "yes" "$(has "$cf_ai" 'on_demand')"
assert_eq "agent site proxies data-plane gw" "yes" "$(has "$cf_ai" 'reverse_proxy 127.0.0.1:19080')"
assert_eq "agent CORS allow-origin = console" "yes" \
  "$(has "$cf_ai" 'Access-Control-Allow-Origin "https://console.amp.203.0.113.10.sslip.io"')"
assert_eq "agent CORS allows X-API-Key" "yes" "$(has "$cf_ai" 'Authorization, Content-Type, X-API-Key')"
assert_eq "agent CORS preflight short-circuit" "yes" "$(has "$cf_ai" 'respond @cors_preflight 204')"
# agent site forces TLS-ALPN-01 (disable_http_challenge) alongside on_demand
assert_eq "agent site on_demand + disable_http_challenge" "yes" \
  "$(printf '%s' "$cf_ai" | awk '/\*\.agents\./{f=1} f' | grep -qF 'disable_http_challenge' && echo yes || echo no)"

# --- hostname-driven cores: set AMP_HOST_* and call the core directly ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=cp.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com

  core_amp="$(amp_helm_args)"
  assert_eq "core amp serverPublicURL (service key)" \
    "agentManagerService.config.serverPublicURL=https://api.amp.example.com" \
    "$(grep -F 'agentManagerService.config.serverPublicURL' <<<"$core_amp")"
  assert_eq "core amp cp url present" \
    "console.config.gatewayControlPlaneUrl=https://cp.amp.example.com" \
    "$(grep -F 'gatewayControlPlaneUrl' <<<"$core_amp")"

  core_th="$(thunder_helm_args)"
  assert_eq "core thunder jwt.issuer" \
    "thunder.configuration.jwt.issuer=https://thunder.amp.example.com" \
    "$(grep -F 'jwt.issuer' <<<"$core_th")"

  core_gw="$(gateway_helm_args)"
  assert_eq "core gateway vhost" \
    "gateway.vhost=https://gateway.amp.example.com" \
    "$(grep -F 'gateway.vhost' <<<"$core_gw")"
  assert_eq "core gateway hostname matches vhost host" \
    "gateway.hostname=gateway.amp.example.com" \
    "$(grep -F 'gateway.hostname' <<<"$core_gw")"

  core_cp="$(cp_helm_args)"
  assert_eq "core cp oidc issuer" \
    "security.oidc.issuer=https://thunder.amp.example.com" \
    "$(grep -F 'security.oidc.issuer' <<<"$core_cp")"
)

# --- core respects AMP_HOST_CP="" as external-gateways-off ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=""
  AMP_AGENTS_BASE=agents.amp.example.com
  assert_eq "core amp no cp when AMP_HOST_CP empty" "" \
    "$(grep -F 'gatewayControlPlaneUrl' <<<"$(amp_helm_args)")"
)

# --- dataplane_external_ingress core reads AMP_AGENTS_BASE ---
(
  AMP_AGENTS_BASE=agents.amp.example.com
  dpe_core="$(dataplane_external_ingress)"
  assert_eq "core dp external host" "yes" "$(has "$dpe_core" 'host: "agents.amp.example.com"')"
  assert_eq "core dp external port 443" "yes" "$(has "$dpe_core" 'port: 443')"
)

# --- caddyfile core, letsencrypt mode ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=cp.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com
  cf_le="$(caddyfile letsencrypt "ops@example.com" "" "" "")"
  assert_eq "core caddy LE console site" "yes" "$(has "$cf_le" 'console.amp.example.com {')"
  assert_eq "core caddy LE console upstream" "yes" "$(has "$cf_le" 'reverse_proxy 127.0.0.1:3000')"
  assert_eq "core caddy LE issuer acme" "yes" "$(has "$cf_le" 'issuer acme')"
  assert_eq "core caddy LE disable_http_challenge" "yes" "$(has "$cf_le" 'disable_http_challenge')"
  assert_eq "core caddy LE email" "yes" "$(has "$cf_le" 'email ops@example.com')"
  assert_eq "core caddy LE cp site" "yes" "$(has "$cf_le" 'cp.amp.example.com {')"
  assert_eq "core caddy LE agent wildcard" "yes" "$(has "$cf_le" '*.agents.amp.example.com {')"
  assert_eq "core caddy LE on_demand ask" "yes" "$(has "$cf_le" 'ask http://127.0.0.1:9753')"
)

# --- caddyfile core, byoc mode ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=cp.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com
  cf_byoc="$(caddyfile byoc "" /opt/amp/certs/fullchain.pem /opt/amp/certs/privkey.pem "")"
  assert_eq "byoc serves provided cert/key" "yes" \
    "$(has "$cf_byoc" 'tls /opt/amp/certs/fullchain.pem /opt/amp/certs/privkey.pem')"
  assert_eq "byoc no acme issuer" "no" "$(has "$cf_byoc" 'issuer acme')"
  assert_eq "byoc no on_demand ask endpoint" "no" "$(has "$cf_byoc" 'ask http://127.0.0.1:9753')"
  assert_eq "byoc agent site uses provided cert (not on_demand)" "no" "$(has "$cf_byoc" 'on_demand')"
  assert_eq "byoc still has agent wildcard" "yes" "$(has "$cf_byoc" '*.agents.amp.example.com {')"
  assert_eq "byoc still serves https (no http:// site)" "no" "$(has "$cf_byoc" 'http://console')"
  assert_eq "byoc keeps CORS for agents" "yes" "$(has "$cf_byoc" 'X-API-Key')"
)

# --- caddyfile core, upstream mode (LB terminates TLS; Caddy routes plain HTTP) ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_CP=cp.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com
  cf_up="$(caddyfile upstream "" "" "" 8080)"
  assert_eq "upstream sets http_port" "yes" "$(has "$cf_up" 'http_port 8080')"
  assert_eq "upstream trusts proxy headers" "yes" "$(has "$cf_up" 'trusted_proxies static 0.0.0.0/0')"
  assert_eq "upstream console site is plain http" "yes" "$(has "$cf_up" 'http://console.amp.example.com:8080 {')"
  assert_eq "upstream console upstream port" "yes" "$(has "$cf_up" 'reverse_proxy 127.0.0.1:3000')"
  assert_eq "upstream no acme" "no" "$(has "$cf_up" 'issuer acme')"
  assert_eq "upstream no tls cert directive" "no" "$(has "$cf_up" 'tls /')"
  assert_eq "upstream agent wildcard plain http" "yes" "$(has "$cf_up" 'http://*.agents.amp.example.com:8080 {')"
  assert_eq "upstream keeps CORS" "yes" "$(has "$cf_up" 'X-API-Key')"
)

# --- upstream default listen port is 80 ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=""
  AMP_AGENTS_BASE=agents.amp.example.com
  cf_up80="$(caddyfile upstream "" "" "" "")"
  assert_eq "upstream default port 80" "yes" "$(has "$cf_up80" 'http_port 80')"
  assert_eq "upstream console site port 80" "yes" "$(has "$cf_up80" 'http://console.amp.example.com:80 {')"
  assert_eq "upstream no cp site when AMP_HOST_CP empty" "no" "$(has "$cf_up80" 'cp.amp.example.com')"
)

# --- derive_hosts: defaults from DOMAIN_BASE ---
(
  DOMAIN_BASE=amp.mycompany.com
  EXTERNAL_GATEWAYS=true
  derive_hosts
  assert_eq "derive console default" "console.amp.mycompany.com" "$AMP_HOST_CONSOLE"
  assert_eq "derive api default"     "api.amp.mycompany.com"     "$AMP_HOST_API"
  assert_eq "derive thunder default" "thunder.amp.mycompany.com" "$AMP_HOST_THUNDER"
  assert_eq "derive registry default" "registry.amp.mycompany.com" "$AMP_HOST_REGISTRY"
  assert_eq "derive cp default"      "cp.amp.mycompany.com"      "$AMP_HOST_CP"
  assert_eq "derive agents default"  "agents.amp.mycompany.com"  "$AMP_AGENTS_BASE"
)

# --- derive_hosts: per-service override + custom AGENTS_BASE ---
(
  DOMAIN_BASE=amp.mycompany.com
  EXTERNAL_GATEWAYS=true
  HOST_CONSOLE=ui.mycompany.com
  AGENTS_BASE=run.mycompany.com
  derive_hosts
  assert_eq "derive console override" "ui.mycompany.com" "$AMP_HOST_CONSOLE"
  assert_eq "derive api still default" "api.amp.mycompany.com" "$AMP_HOST_API"
  assert_eq "derive agents override" "run.mycompany.com" "$AMP_AGENTS_BASE"
)

# --- derive_hosts: external gateways off => empty cp host ---
(
  DOMAIN_BASE=amp.mycompany.com
  EXTERNAL_GATEWAYS=false
  derive_hosts
  assert_eq "derive cp empty when external gateways off" "" "$AMP_HOST_CP"
)

# --- validate_config: complete letsencrypt config passes ---
(
  AMP_VERSION=0.15.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=letsencrypt
  ACME_EMAIL=ops@mycompany.com
  validate_config; rc=$?
  assert_eq "validate complete LE config rc=0" "0" "$rc"
)

# --- validate_config: ACME_EMAIL is optional (recommended) -> letsencrypt without it passes ---
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=letsencrypt
  validate_config 2>/dev/null; rc=$?
  assert_eq "validate LE without ACME_EMAIL rc=0" "0" "$rc"
)

# --- validate_config: missing DOMAIN_BASE fails ---
(
  AMP_VERSION=0.15.0; TLS_MODE=letsencrypt; ACME_EMAIL=ops@mycompany.com
  validate_config; rc=$?
  assert_eq "validate missing DOMAIN_BASE rc=1" "1" "$rc"
  assert_eq "validate names DOMAIN_BASE" "yes" \
    "$(printf '%s\n' "${CONFIG_ERRORS[@]}" | grep -qF 'DOMAIN_BASE' && echo yes || echo no)"
)

# --- validate_config: bad TLS_MODE fails ---
(
  AMP_VERSION=0.15.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=banana
  validate_config; rc=$?
  assert_eq "validate bad TLS_MODE rc=1" "1" "$rc"
)

# --- validate_config: byoc requires cert+key ---
(
  AMP_VERSION=0.15.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=byoc
  validate_config; rc=$?
  assert_eq "validate byoc without cert rc=1" "1" "$rc"
  assert_eq "validate byoc names TLS_CERT_FILE" "yes" \
    "$(printf '%s\n' "${CONFIG_ERRORS[@]}" | grep -qF 'TLS_CERT_FILE' && echo yes || echo no)"
)

# --- install-advanced.sh --init emits a sourceable, complete template ---
ADV="${SCRIPT_DIR}/../install-advanced.sh"
init_out="$(bash "$ADV" --init)"
assert_eq "init has AMP_VERSION"  "yes" "$(has "$init_out" 'AMP_VERSION=')"
assert_eq "init has DOMAIN_BASE"  "yes" "$(has "$init_out" 'DOMAIN_BASE=')"
assert_eq "init has TLS_MODE"     "yes" "$(has "$init_out" 'TLS_MODE=')"
assert_eq "init mentions byoc keys" "yes" "$(has "$init_out" 'TLS_CERT_FILE=')"
assert_eq "init mentions upstream port" "yes" "$(has "$init_out" 'UPSTREAM_LISTEN_PORT=')"
assert_eq "init mentions HOST_REGISTRY" "yes" "$(has "$init_out" 'HOST_REGISTRY=')"
assert_eq "init mentions letsencrypt-dns" "yes" "$(has "$init_out" 'letsencrypt-dns')"
assert_eq "init mentions selfsigned"      "yes" "$(has "$init_out" 'selfsigned')"
assert_eq "init mentions DNS_PROVIDER"    "yes" "$(has "$init_out" 'DNS_PROVIDER=')"
assert_eq "init mentions ACME_SERVER"     "yes" "$(has "$init_out" 'ACME_SERVER=')"
# The emitted template must be valid shell (sourceable without error).
tmp_init="$(mktemp)"; printf '%s\n' "$init_out" > "$tmp_init"
if bash -n "$tmp_init"; then assert_eq "init template is valid shell" "0" "0"; else assert_eq "init template is valid shell" "0" "1"; fi
rm -f "$tmp_init"

# --- --dry-run renders Caddyfile + helm args for an upstream config, no cluster work ---
tmp_cfg="$(mktemp)"
cat > "$tmp_cfg" <<'CFG'
AMP_VERSION=0.15.0
DOMAIN_BASE=amp.mycompany.com
TLS_MODE=upstream
UPSTREAM_LISTEN_PORT=80
EXTERNAL_GATEWAYS=true
CFG
# upstream mode skips cert + DNS hard checks, so dry-run can run hermetically.
dry_out="$(bash "$ADV" --config "$tmp_cfg" --dry-run 2>&1)"
assert_eq "dry-run renders console site" "yes" "$(has "$dry_out" 'http://console.amp.mycompany.com:80 {')"
assert_eq "dry-run renders registry site" "yes" "$(has "$dry_out" 'http://registry.amp.mycompany.com:80 {')"
assert_eq "dry-run renders amp helm arg" "yes" "$(has "$dry_out" 'serverPublicURL=https://api.amp.mycompany.com')"
assert_eq "dry-run does NOT start install" "no" "$(has "$dry_out" 'Running base installer')"
rm -f "$tmp_cfg"

# --- validate_config: UPSTREAM_LISTEN_PORT must be a valid, non-colliding port ---
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=upstream; UPSTREAM_LISTEN_PORT=8088
  validate_config; rc=$?
  assert_eq "validate upstream good port rc=0" "0" "$rc"
)
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=upstream; UPSTREAM_LISTEN_PORT=http
  validate_config; rc=$?
  assert_eq "validate upstream non-numeric port rc=1" "1" "$rc"
)
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=upstream; UPSTREAM_LISTEN_PORT=70000
  validate_config; rc=$?
  assert_eq "validate upstream out-of-range port rc=1" "1" "$rc"
)
(
  # 8080 is a loopback-bound cluster port (Thunder/kgateway) -> must be rejected.
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=upstream; UPSTREAM_LISTEN_PORT=8080
  validate_config; rc=$?
  assert_eq "validate upstream colliding port rc=1" "1" "$rc"
  assert_eq "validate names the collision" "yes" \
    "$(printf '%s\n' "${CONFIG_ERRORS[@]}" | grep -qF 'collides with a loopback-bound cluster port' && echo yes || echo no)"
)

# --- caddyfile upstream: trusted_proxies is configurable (6th arg) ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=""
  AMP_AGENTS_BASE=agents.amp.example.com
  cf_tp="$(caddyfile upstream "" "" "" 80 "130.211.0.0/22 35.191.0.0/16")"
  assert_eq "upstream custom trusted_proxies" "yes" \
    "$(has "$cf_tp" 'trusted_proxies static 130.211.0.0/22 35.191.0.0/16')"
)

# --- tls_san_list: all hosts + agent wildcard, console first, cp gated ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=cp.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com
  sans="$(tls_san_list)"
  assert_eq "san list console is first" "console.amp.example.com" "$(head -1 <<<"$sans")"
  assert_eq "san list has api"      "yes" "$(has "$sans" 'api.amp.example.com')"
  assert_eq "san list has registry" "yes" "$(has "$sans" 'registry.amp.example.com')"
  assert_eq "san list has cp"       "yes" "$(has "$sans" 'cp.amp.example.com')"
  assert_eq "san list has agents wildcard" "yes" "$(has "$sans" '*.agents.amp.example.com')"
)
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=""
  AMP_AGENTS_BASE=agents.amp.example.com
  assert_eq "san list omits cp when empty" "no" "$(has "$(tls_san_list)" 'cp.amp.example.com')"
)

# --- build_lego_args: dns provider, email, domains per SAN, action last ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=cp.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com
  lego="$(build_lego_args ops@example.com route53 /opt/amp/certs "" run)"
  assert_eq "lego dns provider" "yes" "$(printf '%s\n' "$lego" | grep -A1 -- '--dns' | grep -qxF 'route53' && echo yes || echo no)"
  assert_eq "lego email"        "yes" "$(printf '%s\n' "$lego" | grep -A1 -- '--email' | grep -qxF 'ops@example.com' && echo yes || echo no)"
  assert_eq "lego domains console" "yes" "$(has "$lego" 'console.amp.example.com')"
  assert_eq "lego domains agent wildcard" "yes" "$(has "$lego" '*.agents.amp.example.com')"
  assert_eq "lego action run is last" "run" "$(tail -1 <<<"$lego")"
  assert_eq "lego no server when unset" "no" "$(has "$lego" '--server')"
  lego_stg="$(build_lego_args ops@example.com route53 /opt/amp/certs https://acme-staging-v02.api.letsencrypt.org/directory renew)"
  assert_eq "lego server when set" "yes" "$(printf '%s\n' "$lego_stg" | grep -A1 -- '--server' | grep -qxF 'https://acme-staging-v02.api.letsencrypt.org/directory' && echo yes || echo no)"
  assert_eq "lego action renew is last" "renew" "$(tail -1 <<<"$lego_stg")"
)

# --- --dry-run, selfsigned: renders byoc-form Caddyfile, generates NOTHING ---
tmp_ss="$(mktemp -d)"
cat > "$tmp_ss/cfg" <<'CFG'
AMP_VERSION=0.16.0
DOMAIN_BASE=amp.mycompany.com
TLS_MODE=selfsigned
EXTERNAL_GATEWAYS=true
CFG
ss_out="$(bash "$ADV" --config "$tmp_ss/cfg" --dry-run 2>&1)"
assert_eq "dry selfsigned serves cert file" "yes" "$(has "$ss_out" 'tls /opt/amp/certs/fullchain.pem /opt/amp/certs/privkey.pem')"
assert_eq "dry selfsigned no acme issuer"   "no"  "$(has "$ss_out" 'issuer acme')"
assert_eq "dry selfsigned does NOT install" "no"  "$(has "$ss_out" 'Running base installer')"
assert_eq "dry selfsigned shows SAN plan"   "yes" "$(has "$ss_out" '*.agents.amp.mycompany.com')"
rm -rf "$tmp_ss"

# --- --dry-run, letsencrypt-dns: prints lego plan, no docker, no install ---
tmp_dns="$(mktemp -d)"
cat > "$tmp_dns/cfg" <<'CFG'
AMP_VERSION=0.16.0
DOMAIN_BASE=amp.mycompany.com
TLS_MODE=letsencrypt-dns
DNS_PROVIDER=route53
ACME_EMAIL=ops@mycompany.com
EXTERNAL_GATEWAYS=true
CFG
dns_out="$(bash "$ADV" --config "$tmp_dns/cfg" --dry-run 2>&1)"
assert_eq "dry dns shows lego provider"  "yes" "$(has "$dns_out" '--dns')"
assert_eq "dry dns shows route53"        "yes" "$(has "$dns_out" 'route53')"
assert_eq "dry dns shows agent wildcard" "yes" "$(has "$dns_out" '*.agents.amp.mycompany.com')"
assert_eq "dry dns serves cert file"     "yes" "$(has "$dns_out" 'tls /opt/amp/certs/fullchain.pem /opt/amp/certs/privkey.pem')"
assert_eq "dry dns does NOT install"     "no"  "$(has "$dns_out" 'Running base installer')"
rm -rf "$tmp_dns"

# --- validate_config: letsencrypt-dns requires DNS_PROVIDER + ACME_EMAIL ---
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=letsencrypt-dns
  DNS_PROVIDER=route53; ACME_EMAIL=ops@mycompany.com
  validate_config; rc=$?
  assert_eq "validate complete dns config rc=0" "0" "$rc"
)
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=letsencrypt-dns
  ACME_EMAIL=ops@mycompany.com
  validate_config; rc=$?
  assert_eq "validate dns without provider rc=1" "1" "$rc"
  assert_eq "validate dns names DNS_PROVIDER" "yes" \
    "$(printf '%s\n' "${CONFIG_ERRORS[@]}" | grep -qF 'DNS_PROVIDER' && echo yes || echo no)"
)
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=letsencrypt-dns
  DNS_PROVIDER=route53
  validate_config; rc=$?
  assert_eq "validate dns without email rc=1" "1" "$rc"
  assert_eq "validate dns names ACME_EMAIL" "yes" \
    "$(printf '%s\n' "${CONFIG_ERRORS[@]}" | grep -qF 'ACME_EMAIL' && echo yes || echo no)"
)

# --- validate_config: selfsigned needs nothing beyond version + domain ---
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=selfsigned
  validate_config; rc=$?
  assert_eq "validate selfsigned minimal rc=0" "0" "$rc"
)

# --- validate_config: bad-mode error lists the new modes ---
(
  AMP_VERSION=0.16.0; DOMAIN_BASE=amp.mycompany.com; TLS_MODE=banana
  validate_config 2>/dev/null
  assert_eq "bad-mode error mentions letsencrypt-dns" "yes" \
    "$(printf '%s\n' "${CONFIG_ERRORS[@]}" | grep -qF 'letsencrypt-dns' && echo yes || echo no)"
)

# --- render_renewal_units: emits a renew service (lego renew + caddy reload) + timer ---
(
  AMP_HOST_CONSOLE=console.amp.example.com
  AMP_HOST_API=api.amp.example.com
  AMP_HOST_THUNDER=thunder.amp.example.com
  AMP_HOST_OBSERVER=observer.amp.example.com
  AMP_HOST_GATEWAY=gateway.amp.example.com
  AMP_HOST_REGISTRY=registry.amp.example.com
  AMP_HOST_CP=cp.amp.example.com
  AMP_AGENTS_BASE=agents.amp.example.com
  ACME_EMAIL=ops@example.com DNS_PROVIDER=route53
  units="$(render_renewal_units /opt/amp/certs /opt/amp/amp-config.env)"
  assert_eq "renewal runs lego renew"   "yes" "$(has "$units" 'goacme/lego')"
  # lego v5 dropped the global flags build_lego_args emits, so the image must stay
  # pinned to v4.x; :latest (now v5) breaks issuance with "flag not defined".
  assert_eq "renewal lego pinned not :latest" "no"  "$(has "$units" 'goacme/lego:latest')"
  assert_eq "renewal lego pinned to v4"       "yes" "$(has "$units" 'goacme/lego:v4')"
  assert_eq "renewal ExecStart action is renew" "yes" \
    "$(grep '^ExecStart=' <<<"$units" | grep -qE ' renew$' && echo yes || echo no)"
  assert_eq "renewal reloads caddy"     "yes" "$(has "$units" 'docker exec amp-caddy caddy reload')"
  assert_eq "renewal reads env-file"    "yes" "$(has "$units" '--env-file /opt/amp/amp-config.env')"
  assert_eq "renewal timer is daily"    "yes" "$(has "$units" 'OnCalendar=daily')"
  assert_eq "renewal has unit separator" "yes" "$(has "$units" '---UNIT-SEPARATOR---')"
)

# --- inotify_bump_target: bump to floor only when below it (or unreadable) ---
assert_eq "inotify below floor bumps"         "512"    "$(inotify_bump_target 128 512)"
assert_eq "inotify at floor no bump"          ""       "$(inotify_bump_target 512 512)"
assert_eq "inotify above floor never lowers"  ""       "$(inotify_bump_target 1024 512)"
assert_eq "inotify empty current bumps"       "512"    "$(inotify_bump_target "" 512)"
assert_eq "inotify non-numeric current bumps" "512"    "$(inotify_bump_target foo 512)"
assert_eq "inotify watches floor"             "524288" "$(inotify_bump_target 8192 524288)"

if [[ -s "$FAILLOG" ]]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
