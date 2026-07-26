#!/usr/bin/env bash
# lib-vm.sh — pure helpers for the VM standalone install.
# Sourcing this file has no side effects; every function writes only to stdout.
#
# The VM installer is Let's Encrypt only and 443-only: certificates issue via the
# TLS-ALPN-01 ACME challenge (inside the :443 handshake), so no inbound port 80 is
# ever required and every public URL is https.

# vm_host <subdomain> <ip> -> "<sub>.amp.<ip>.sslip.io"
vm_host() {
  printf '%s.amp.%s.sslip.io' "$1" "$2"
}

# build_amp_helm_args <ip> <external_gateways:true|false (default true)>
# Prints helm args, one token per line (--set and KEY=VALUE on separate lines).
# Consume with (bash >=4):  mapfile -t ARR < <(build_amp_helm_args ...)
# bash 3.2 (macOS):         while IFS= read -r l; do ARR+=("$l"); done < <(build_amp_helm_args ...)
# amp_helm_args — hostname-driven core. Reads AMP_HOST_API/THUNDER/CONSOLE/OBSERVER/
# GATEWAY/CP (CP empty => external gateways off). Emits one helm token per line.
#
# The service config lives under different top-level keys across chart versions:
# `agentManager` (<=main) was renamed to `agentManagerService` (>=0.15.0). Emit
# both; helm silently ignores whichever key the installed chart doesn't define,
# so the right one always wins regardless of the --version pulled.
#
# config.tlsEnabled (env TLS_ENABLED) selects which advertised endpoint variant
# amp-api hands the console for deployed agents: when true it emits the https URL
# from the release binding instead of the http one. It does NOT change amp-api's
# own serving (that is internalServer.tlsEnabled) — it is purely the endpoint
# scheme. The agent host is only reachable over TLS via Caddy's wildcard site, so
# without this the console emits http:// and the browser blocks it as mixed content.
# shellcheck disable=SC2154  # AMP_HOST_* come from the caller's scope by design.
amp_helm_args() {
  local k
  for k in agentManager agentManagerService; do
    printf '%s\n' \
      "--set" "${k}.config.serverPublicURL=https://${AMP_HOST_API}" \
      "--set" "${k}.config.oauthAuthorizationServers=https://${AMP_HOST_THUNDER}" \
      "--set" "${k}.config.keyManager.issuer=https://${AMP_HOST_THUNDER}" \
      "--set" "${k}.config.tlsEnabled=true"
  done

  printf '%s\n' \
    "--set" "console.config.auth.baseUrl=https://${AMP_HOST_THUNDER}" \
    "--set" "console.config.auth.signInRedirectURL=https://${AMP_HOST_CONSOLE}/login" \
    "--set" "console.config.auth.signOutRedirectURL=https://${AMP_HOST_CONSOLE}/login" \
    "--set" "console.config.apiBaseUrl=https://${AMP_HOST_API}" \
    "--set" "console.config.obsApiBaseUrl=https://${AMP_HOST_OBSERVER}" \
    "--set" "console.config.instrumentationUrl=https://${AMP_HOST_GATEWAY}/otel"

  if [[ -n "$AMP_HOST_CP" ]]; then
    # Full URL: the console parses it with new URL() to build gateway setup commands.
    printf '%s\n' "--set" "console.config.gatewayControlPlaneUrl=https://${AMP_HOST_CP}"
  fi
}

# build_amp_helm_args <ip> <external_gateways:true|false> — sslip.io-from-IP wrapper.
build_amp_helm_args() {
  local ip="$1" external_gateways="${2:-true}"
  local AMP_HOST_API AMP_HOST_THUNDER AMP_HOST_CONSOLE AMP_HOST_OBSERVER AMP_HOST_GATEWAY AMP_HOST_CP
  AMP_HOST_API="$(vm_host api "$ip")"
  AMP_HOST_THUNDER="$(vm_host thunder "$ip")"
  AMP_HOST_CONSOLE="$(vm_host console "$ip")"
  AMP_HOST_OBSERVER="$(vm_host observer "$ip")"
  AMP_HOST_GATEWAY="$(vm_host gateway "$ip")"
  AMP_HOST_CP=""; [[ "$external_gateways" == "true" ]] && AMP_HOST_CP="$(vm_host cp "$ip")"
  amp_helm_args
}

# build_gateway_helm_args <ip>
# Prints GATEWAY_HELM_ARGS tokens. Sets the published vhost so deployed-agent
# endpoint URLs are externally reachable (path-routed under this single host),
# and points the gateway runtime's user-token key manager (ThunderKeyManager) at
# the public Thunder issuer. The runtime validates the JWT `iss` claim
# (validateissuer=true); user tokens are minted by the public Thunder, so without
# this invoking a deployed agent 401s.
#
# The whole keymanagers list is supplied via --set-json: a `--set keymanagers[1].issuer`
# does NOT merge into the chart's list, it replaces it with [null, {issuer}], which
# wipes keymanager[0] (agent-manager-service, used for OTel ingest) and the name/jwks
# of [1] -> malformed config.toml -> gateway crash loop. So both entries are restated
# in full; only the ThunderKeyManager issuer differs from the chart default. This is
# chart-version-coupled: re-verify both keymanagers (names + jwks URIs) on chart bumps.
# gateway_helm_args — hostname-driven core. Reads AMP_HOST_GATEWAY, AMP_HOST_THUNDER.
#
# gateway.hostname MUST match the host in gateway.vhost. vhost is the public URL the
# controller mints into LLM-proxy endpoints; hostname is the host the kgateway
# catch-all HTTPRoute matches to forward traffic to the gateway runtime. Left unset,
# hostname defaults to "<env>-<org>.gateway.localhost", which never matches the public
# vhost the LLM judge calls, so the proxy request 404s at kgateway. Keep them aligned.
# shellcheck disable=SC2154  # AMP_HOST_* come from the caller's scope by design.
gateway_helm_args() {
  local thunder keymanagers
  thunder="https://${AMP_HOST_THUNDER}"
  keymanagers=$(printf '[{"name":"agent-manager-service","issuer":"agent-manager-service","jwks":{"remote":{"uri":"http://amp-api.wso2-amp.svc.cluster.local:9000/auth/external/jwks.json","skipTlsVerify":true}}},{"name":"ThunderKeyManager","issuer":"%s","jwks":{"remote":{"uri":"http://amp-thunder-extension-service.amp-thunder:8090/oauth2/jwks","skipTlsVerify":true}}}]' "$thunder")
  printf '%s\n' \
    "--set" "gateway.vhost=https://${AMP_HOST_GATEWAY}" \
    "--set" "gateway.hostname=${AMP_HOST_GATEWAY}" \
    "--set-json" "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers=${keymanagers}"
}

# build_gateway_helm_args <ip> — sslip.io-from-IP wrapper.
build_gateway_helm_args() {
  local ip="$1"
  local AMP_HOST_GATEWAY AMP_HOST_THUNDER
  AMP_HOST_GATEWAY="$(vm_host gateway "$ip")"
  AMP_HOST_THUNDER="$(vm_host thunder "$ip")"
  gateway_helm_args
}

# build_observability_helm_args <ip>
# Prints OBSERVABILITY_HELM_ARGS tokens. The traces observer validates the same
# user token (its `iss` must match), so the console's traces page 401s until its
# issuer is the public Thunder URL too. jwksUrl stays on the in-cluster service.
# observability_helm_args — hostname-driven core. Reads AMP_HOST_THUNDER.
# shellcheck disable=SC2154  # AMP_HOST_THUNDER comes from the caller's scope by design.
observability_helm_args() {
  printf '%s\n' \
    "--set" "tracesObserver.auth.issuer=https://${AMP_HOST_THUNDER}"
}

# build_observability_helm_args <ip> — sslip.io-from-IP wrapper.
build_observability_helm_args() {
  local ip="$1"
  local AMP_HOST_THUNDER
  AMP_HOST_THUNDER="$(vm_host thunder "$ip")"
  observability_helm_args
}

# build_cp_helm_args <ip>
# Prints CP_HELM_ARGS tokens for the OpenChoreo control-plane install. Thunder's
# issuer is moved to the public sslip.io URL, so the OpenChoreo CP OIDC config
# (which validates the issuer string statically) must accept that same issuer —
# otherwise amp-api -> OpenChoreo calls fail with "INVALID_CLAIMS". jwksUrl /
# wellKnownEndpoint stay on the internal service (they still resolve in-cluster).
# cp_helm_args — hostname-driven core. Reads AMP_HOST_THUNDER.
# shellcheck disable=SC2154  # AMP_HOST_THUNDER comes from the caller's scope by design.
cp_helm_args() {
  printf '%s\n' \
    "--set" "security.oidc.issuer=https://${AMP_HOST_THUNDER}" \
    "--set" "security.oidc.authorizationUrl=https://${AMP_HOST_THUNDER}/oauth2/authorize" \
    "--set" "security.oidc.tokenUrl=https://${AMP_HOST_THUNDER}/oauth2/token"
}

# build_cp_helm_args <ip> — sslip.io-from-IP wrapper.
build_cp_helm_args() {
  local ip="$1"
  local AMP_HOST_THUNDER
  AMP_HOST_THUNDER="$(vm_host thunder "$ip")"
  cp_helm_args
}

# build_platform_resources_helm_args
# Prints PLATFORM_RESOURCES_HELM_ARGS tokens. Two overrides:
#
# 1. OAuth token endpoint. The platform-resources chart's workload-publisher
#    defaults its OAuth token endpoint to the kgateway path
#    (`host.k3d.internal:8080/oauth2/token` + Host `thunder.amp.localhost`). On the
#    VM that route no longer matches: build_cp_helm_args / build_thunder_helm_args
#    move Thunder's vhost to the public sslip.io host, so the localhost Host header
#    404s and `generate-workload-cr` fails with "Failed to get access token". Point
#    it at the Thunder service directly (no gateway, no Host header, no issuer
#    coupling) — the same in-cluster endpoint every other extension already uses.
#
# 2. Default-Environment agent-facing gateway host. The chart seeds the default
#    Environment CR with environment.gateway.http (default am-gateway.localhost:19080).
#    OpenChoreo builds deployed-agent route hostnames as "<env>-<org>.<that host>",
#    and the Environment's external WHOLLY REPLACES the dataplane's, so without this
#    override agent routes land on *.am-gateway.localhost: the console then shows an
#    empty invoke URL and try-out 405s against its own host. Point it at the public
#    agents base (AMP_AGENTS_BASE, e.g. agents.<domain> or agents.<ip>.sslip.io) on
#    :443 so routes resolve to <org>-<project>.<AMP_AGENTS_BASE>, served by Caddy's
#    wildcard *.agents site.
#
#    Set BOTH the http and https variants. Because the override wholly replaces the
#    dataplane's external endpoint, an http-only override drops the https variant
#    dataplane_external_ingress emits. The console reads the https variant when
#    tlsEnabled=true, so an http-only override leaves the binding with only an http
#    externalURL: the invoke URL is empty and try-out falls back to a relative /chat
#    (405) — the very symptom this override exists to fix. Both bind listenerName
#    http (TLS terminates at Caddy) and differ only in advertised scheme.
#
# AMP_REGISTRY_CA_FILE (optional, caller's scope): path to the PEM file for the CA
# that signed the registry's TLS certificate, when it isn't publicly trusted
# (selfsigned/byoc TLS_MODE). Passed via --set-file so the chart can inject it into
# the build/publish Podman containers' per-registry trust dir — see
# global.registry.caCert in wso2-amp-platform-resources-extension/values.yaml. Left
# unset (the default), the registry falls back to its stock CA bundle, which is
# correct for letsencrypt/letsencrypt-dns (publicly-trusted certs).
# shellcheck disable=SC2154  # AMP_AGENTS_BASE/AMP_HOST_REGISTRY/AMP_REGISTRY_CA_FILE come from the caller's scope by design.
build_platform_resources_helm_args() {
  printf '%s\n' \
    "--set" "global.oauth.tokenUrl=http://amp-thunder-extension-service.amp-thunder.svc.cluster.local:8090/oauth2/token" \
    "--set" "global.registry.endpoint=${AMP_HOST_REGISTRY}" \
    "--set" "global.defaultResources.registry.tlsVerify=true" \
    "--set" "environment.gateway.http.host=${AMP_AGENTS_BASE}" \
    "--set" "environment.gateway.http.port=443" \
    "--set" "environment.gateway.https.host=${AMP_AGENTS_BASE}" \
    "--set" "environment.gateway.https.port=443"
  if [[ -n "${AMP_REGISTRY_CA_FILE:-}" ]]; then
    printf '%s\n' "--set-file" "global.registry.caCert=${AMP_REGISTRY_CA_FILE}"
  fi
}

# build_thunder_helm_args <ip>
# Prints helm args, one token per line.
# thunder_helm_args — hostname-driven core. Reads AMP_HOST_THUNDER, AMP_HOST_CONSOLE.
# shellcheck disable=SC2154  # AMP_HOST_* come from the caller's scope by design.
thunder_helm_args() {
  printf '%s\n' \
    "--set" "thunder.ocIngress.hostname=${AMP_HOST_THUNDER}" \
    "--set" "thunder.configuration.server.publicUrl=https://${AMP_HOST_THUNDER}" \
    "--set" "thunder.configuration.jwt.issuer=https://${AMP_HOST_THUNDER}" \
    "--set" "thunder.configuration.gateClient.hostname=${AMP_HOST_THUNDER}" \
    "--set" "thunder.configuration.gateClient.scheme=https" \
    "--set" "thunder.configuration.gateClient.port=443" \
    "--set" "thunder.configuration.cors.allowedOrigins[0]=https://${AMP_HOST_CONSOLE}"

  # The console client's registered redirect URI lives under `setup` (<=main) and
  # was renamed to `bootstrap` (>=0.15.0, which is what the registration template
  # actually reads). Emit both; helm ignores the inert one. Must match the
  # console's signInRedirectURL or Thunder rejects login with "Invalid redirect URI".
  local k
  for k in setup bootstrap; do
    printf '%s\n' "--set" "thunder.${k}.ampConsoleClient.redirectUris[0]=https://${AMP_HOST_CONSOLE}/login"
  done
}

# build_thunder_helm_args <ip> — sslip.io-from-IP wrapper.
build_thunder_helm_args() {
  local ip="$1"
  local AMP_HOST_THUNDER AMP_HOST_CONSOLE
  AMP_HOST_THUNDER="$(vm_host thunder "$ip")"
  AMP_HOST_CONSOLE="$(vm_host console "$ip")"
  thunder_helm_args
}

# render_k3d_vm_config [node_host]  (reads k3d config on stdin, writes VM config on stdout)
# Two rewrites:
#  1. '- port: <host>:<container>' -> '- port: 127.0.0.1:<host>:<container>' so the
#     k3d host ports bind to loopback only. Already-bound entries are left untouched.
#  2. The containerd registry mirror *endpoint* host.k3d.internal:10082 -> <node_host>:10082.
#     The mirror key stays host.k3d.internal:10082 (it must match the image tag the
#     publish step writes), but the node's containerd resolves host.k3d.internal via
#     its own /etc/hosts to the Docker bridge gateway — which has nothing listening
#     once ports are loopback-bound, so agent image pulls fail with ImagePullBackOff.
#     The node *can* reach the registry LoadBalancer at its own node hostname, which
#     k3d puts in the node's /etc/hosts (IP-independent). Pod-side DNS is handled
#     separately by render_coredns_vm_config; this covers the node containerd path.
render_k3d_vm_config() {
  local node_host="${1:-k3d-amp-local-server-0}"
  sed -E \
    -e 's/^([[:space:]]*- port: )([0-9]+:[0-9]+)/\1127.0.0.1:\2/' \
    -e "s#^([[:space:]]*- )http://host\\.k3d\\.internal:10082#\\1http://${node_host}:10082#"
}
# inject_artifactory_k3d_registries <k3d-config-file> <source1|artifactory1:auth1> [...]
# Appends source-registry mirror mappings + Artifactory auth into the containerd
# registries config embedded in the k3d config file.
# Format: "docker.io|nn-docker-remote.artifactory.insim.biz:base64auth"
# Values are YAML-double-quoted so passwords with colons/special chars are safe.
inject_artifactory_k3d_registries() {
  local file="$1"; shift
  [[ $# -gt 0 ]] || return 0
  log "Injecting $# Artifactory k3d registry mirror(s)"

  local tmp_mirrors; tmp_mirrors="$(mktemp)"
  local tmp_configs; tmp_configs="$(mktemp)"

  for triplet in "$@"; do
    local source="${triplet%%|*}" rest="${triplet#*|}"
    local artifactory="${rest%%:*}" auth="${rest#*:}"
    [[ -z "$source" || -z "$artifactory" || -z "$auth" ]] && \
      { log "WARNING: invalid format '$triplet' (expected source|artifactory:auth)"; continue; }
    local decoded username password
    decoded="$(printf '%s' "$auth" | base64 -d 2>/dev/null)" \
      || { log "WARNING: could not decode auth for $artifactory (not valid base64)"; continue; }
    username="${decoded%%:*}"
    password="${decoded#*:}"
    # Mirror entry — map source registry to Artifactory endpoint.
    cat >>"$tmp_mirrors" <<EOF
      "${source}":
        endpoint:
          - "https://${artifactory}"
EOF
    # Config entry — YAML-double-quoted to handle colons in Artifactory tokens.
    # The password may contain colons (e.g. reftkn:01:...) so must be quoted.
    cat >>"$tmp_configs" <<EOF
      "${artifactory}":
        auth:
          username: "${username}"
          password: "${password}"
EOF
    log "  ${source} -> ${artifactory}"
  done

  cat "$tmp_mirrors" >>"$file"
  if [[ -s "$tmp_configs" ]]; then
    printf '    configs:\n' >>"$file"
    cat "$tmp_configs" >>"$file"
  fi
  rm -f "$tmp_mirrors" "$tmp_configs"

  log "Rendered k3d registries section:"
  grep -A 9999 'registries:' "$file" | sed 's/^/  /' >&2 || true
}
# render_coredns_vm_config <node_host>
# Prints a `coredns-custom` ConfigMap that rewrites the in-cluster *.localhost /
# host.k3d.internal names to the k3d server node (<node_host>, e.g.
# k3d-amp-local-server-0), instead of the base config's `host.k3d.internal`.
#
# Why the VM needs this: the stock config points these names at host.k3d.internal,
# which ensure_coredns_host_aliases maps to the Docker bridge gateway (the host),
# relying on a host hairpin to the published service ports. But the VM installer
# binds every k3d host port to 127.0.0.1 (render_k3d_vm_config), so the gateway IP
# has nothing listening — observer->authz (build logs) and the registry push/pull
# both fail with "connection refused". The server node is where klipper exposes
# all the LoadBalancer service ports, so rewriting straight to its hostname is
# reachable and, unlike a NodeHosts alias, survives k3s NodeHosts reconciliation
# (the node entry is always present). Applied via install.sh's COREDNS_FILE hook.
render_coredns_vm_config() {
  local node_host="$1"
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  amp.override: |
    rewrite stop {
      name regex (.+\\.)?amp\\.localhost ${node_host}
      answer auto
    }
  openchoreo.override: |
    rewrite stop {
      name regex (.+\\.)?openchoreo\\.localhost ${node_host}
      answer auto
    }
  hostalias.override: |
    rewrite stop {
      name regex (host\\.k3d\\.internal|host\\.docker\\.internal) ${node_host}
      answer auto
    }
EOF
}

# render_dataplane_external_ingress <ip>
# Prints the `external:` http/https entries for install.sh's ClusterDataPlane
# (DP_EXTERNAL_INGRESS hook), advertising deployed-agent endpoints under the
# public host <org>-<project>.agents.<ip>.sslip.io instead of the local default
# openchoreoapis.localhost:19080.
#
# Emits BOTH entries on :443, bound to the internal http listener (TLS is
# terminated at Caddy's wildcard *.agents site). Both variants resolve to the same
# host:port/path and differ only in scheme; amp-api advertises the https one to the
# console (build_amp_helm_args sets config.tlsEnabled=true), so the browser calls
# https://...:443 directly and the wildcard site serves it. The http entry is kept
# too: a release binding missing a variant makes the console fall back to a relative
# /chat (405 from its own nginx), so emitting both keeps the binding complete.
# dataplane_external_ingress — hostname-driven core; reads AMP_AGENTS_BASE.
# shellcheck disable=SC2154  # AMP_AGENTS_BASE comes from the caller's scope by design.
dataplane_external_ingress() {
  local host="$AMP_AGENTS_BASE"
  printf '        http:\n          host: "%s"\n          listenerName: http\n          port: 443\n' "$host"
  printf '        https:\n          host: "%s"\n          listenerName: http\n          port: 443\n' "$host"
}

# render_dataplane_external_ingress <ip> — sslip.io-from-IP wrapper.
render_dataplane_external_ingress() {
  local AMP_AGENTS_BASE="agents.${1}.sslip.io"
  dataplane_external_ingress
}

# caddyfile <tls_mode> <email> <cert_file> <key_file> <listen_port>
# Hostname-driven core. Reads AMP_HOST_CONSOLE/API/THUNDER/OBSERVER/GATEWAY/REGISTRY/CP
# (CP empty => no cp site) and AMP_AGENTS_BASE. tls_mode is one of:
#   letsencrypt  — terminate TLS on :443, auto-ACME via TLS-ALPN-01 (no port 80),
#                  on-demand certs for the per-agent wildcard.
#   byoc         — terminate TLS on :443 with the operator-supplied cert/key (no ACME).
#   upstream     — a load balancer / proxy in front terminates TLS; Caddy listens on
#                  plain HTTP at <listen_port> and only routes by Host.
# In every mode the published URLs are https:// (what the browser sees); only Caddy's
# listener differs.
# shellcheck disable=SC2154  # AMP_HOST_*/AMP_AGENTS_BASE come from the caller's scope.
caddyfile() {
  local tls_mode="$1" email="$2" cert_file="$3" key_file="$4" listen_port="${5:-80}" trusted_proxies="${6:-0.0.0.0/0}"
  local console_origin="https://${AMP_HOST_CONSOLE}"

  # Per-mode building blocks computed once.
  local tls_block="" agent_tls="" gopts="" scheme="https" addr_suffix=""
  case "$tls_mode" in
    letsencrypt)
      # Every public site forces the TLS-ALPN-01 ACME challenge (it runs inside the
      # :443 TLS handshake) so certificate issuance never depends on inbound port 80.
      tls_block=$'\ttls {\n\t\tissuer acme {\n\t\t\tdisable_http_challenge\n\t\t}\n\t}\n'
      agent_tls=$'\ttls {\n\t\ton_demand\n\t\tissuer acme {\n\t\t\tdisable_http_challenge\n\t\t}\n\t}\n'
      [[ -n "$email" ]] && gopts+=$'\temail '"$email"$'\n'
      gopts+=$'\tauto_https disable_redirects\n'
      gopts+=$'\ton_demand_tls {\n\t\task http://127.0.0.1:9753\n\t}\n'
      ;;
    byoc)
      # Serve the operator-supplied cert/key on every site (incl. the agent wildcard,
      # whose cert must carry the *.<AGENTS_BASE> SAN — enforced by validate_cert).
      tls_block=$'\ttls '"$cert_file"' '"$key_file"$'\n'
      agent_tls="$tls_block"
      gopts+=$'\tauto_https disable_redirects\n'
      ;;
    upstream)
      # The LB owns the public cert; Caddy routes plain HTTP and trusts the LB's
      # X-Forwarded-* headers (so backends still see the https scheme). Only the
      # configured proxy CIDRs are trusted — scope this to the LB's source ranges
      # (and firewall :<listen_port> to the LB) so a direct caller can't spoof them.
      scheme="http"; addr_suffix=":${listen_port}"
      gopts+=$'\thttp_port '"$listen_port"$'\n'
      gopts+=$'\tservers {\n\t\ttrusted_proxies static '"$trusted_proxies"$'\n\t}\n'
      ;;
    *) printf 'caddyfile: unknown tls_mode %q\n' "$tls_mode" >&2; return 1 ;;
  esac

  printf '{\n%s}\n\n' "$gopts"

  _site() {   # _site <host> <upstream_port>
    printf '%s%s {\n%s\treverse_proxy 127.0.0.1:%s\n}\n\n' \
      "$([[ "$scheme" == http ]] && printf 'http://')" "$1$addr_suffix" "$tls_block" "$2"
  }

  _site "$AMP_HOST_CONSOLE"  3000   # console UI
  _site "$AMP_HOST_API"      9000   # agent-manager REST API
  _site "$AMP_HOST_THUNDER"  8080   # Thunder OAuth (OC kgateway, host-routed)
  _site "$AMP_HOST_OBSERVER" 9098   # traces observer
  # The api-platform gateway runtime is a ClusterIP service (ports 22893/22894 are
  # not node-published), so it is reached through the kgateway data plane on 19080 —
  # which has a catch-all HTTPRoute for AMP_HOST_GATEWAY that forwards to the runtime
  # (see gateway_helm_args setting gateway.hostname). Pointing here at 22893 dead-ends
  # (Caddy gets an empty reply -> 502), breaking the publicly-minted LLM-judge proxy
  # URL. (Agent OTel ingestion is unaffected: it goes in-cluster to the runtime
  # ClusterIP, not through this host.)
  _site "$AMP_HOST_GATEWAY"  19080  # api-platform gateway via kgateway (LLM proxy)
  if [[ -n "${AMP_HOST_REGISTRY:-}" ]]; then
    _site "$AMP_HOST_REGISTRY" 10082  # workflow-plane docker registry (public TLS front door)
  fi

  if [[ -n "$AMP_HOST_CP" ]]; then
    # 9243 is HTTPS with a self-signed cert -> proxy over TLS, skip verification.
    # reverse_proxy upgrades the gateway control WebSocket transparently.
    printf '%s%s {\n%s\treverse_proxy 127.0.0.1:9243 {\n\t\ttransport http {\n\t\t\ttls\n\t\t\ttls_insecure_skip_verify\n\t\t}\n\t}\n}\n\n' \
      "$([[ "$scheme" == http ]] && printf 'http://')" "${AMP_HOST_CP}$addr_suffix" "$tls_block"
  fi

  # On-demand TLS ask endpoint exists only in letsencrypt mode (always-allow; Caddy
  # only triggers on-demand for SNI matching the *.agents wildcard).
  [[ "$tls_mode" == letsencrypt ]] && printf 'http://127.0.0.1:9753 {\n\trespond 200\n}\n\n'

  # Deployed-agent endpoints: <org>-<project>.<AGENTS_BASE> (one host per org/project,
  # dynamic), proxied to the data-plane gateway + CORS (the gateway adds none);
  # X-API-Key is the header the console sends the token in.
  local cors_block
  cors_block=$(printf '\theader {\n\t\tAccess-Control-Allow-Origin "%s"\n\t\tAccess-Control-Allow-Methods "GET, POST, PUT, DELETE, PATCH, OPTIONS"\n\t\tAccess-Control-Allow-Headers "Authorization, Content-Type, X-API-Key"\n\t\tAccess-Control-Allow-Credentials "true"\n\t\tAccess-Control-Max-Age "3600"\n\t\tVary Origin\n\t\tdefer\n\t}\n\t@cors_preflight method OPTIONS\n\trespond @cors_preflight 204\n' "$console_origin")
  printf '%s*.%s%s {\n%s%s\n\treverse_proxy 127.0.0.1:19080\n}\n\n' \
    "$([[ "$scheme" == http ]] && printf 'http://')" "$AMP_AGENTS_BASE" "$addr_suffix" "$agent_tls" "$cors_block"

  unset -f _site
}

# render_caddyfile <ip> <acme_email> <external_gateways:true|false (default true)>
# sslip.io-from-IP wrapper, letsencrypt only. Preserves the original output
# byte-for-byte. Prints a complete Caddyfile to stdout: 443-only, every site forces
# the TLS-ALPN-01 challenge so issuance never needs inbound port 80.
render_caddyfile() {
  local ip="$1" email="$2" external_gateways="${3:-true}"
  local AMP_HOST_CONSOLE AMP_HOST_API AMP_HOST_THUNDER AMP_HOST_OBSERVER AMP_HOST_GATEWAY AMP_HOST_REGISTRY AMP_HOST_CP AMP_AGENTS_BASE
  AMP_HOST_CONSOLE="$(vm_host console "$ip")"
  AMP_HOST_API="$(vm_host api "$ip")"
  AMP_HOST_THUNDER="$(vm_host thunder "$ip")"
  AMP_HOST_OBSERVER="$(vm_host observer "$ip")"
  AMP_HOST_GATEWAY="$(vm_host gateway "$ip")"
  AMP_HOST_REGISTRY="$(vm_host registry "$ip")"
  AMP_HOST_CP=""; [[ "$external_gateways" == "true" ]] && AMP_HOST_CP="$(vm_host cp "$ip")"
  AMP_AGENTS_BASE="agents.${ip}.sslip.io"
  caddyfile letsencrypt "$email" "" "" ""
}
