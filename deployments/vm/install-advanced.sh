#!/usr/bin/env bash
# install-advanced.sh — config-driven Agent Manager install on a VM with Docker.
# Run ON the target VM with sudo. Supports custom domains and three TLS modes
# (letsencrypt | byoc | upstream). See --init for the annotated config template.
#
# Usage:
#   sudo ./install-advanced.sh --config amp-config.env
#   ./install-advanced.sh --init > amp-config.env      # emit annotated template
#   sudo ./install-advanced.sh --config amp-config.env --dry-run   # validate + render only
set -euo pipefail

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This installer wraps the quick-start installer (install.sh + k3d-config.yaml).
QS_DIR="$(cd "${VM_DIR}/../quick-start" && pwd)"

log() { printf '\033[0;34m[install-advanced]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[install-advanced] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib-vm.sh
source "${VM_DIR}/lib-vm.sh"
# shellcheck source=lib-advanced.sh
source "${VM_DIR}/lib-advanced.sh"
# shellcheck source=lib-bootstrap.sh
source "${VM_DIR}/lib-bootstrap.sh"
# shellcheck source=lib-tls.sh
source "${VM_DIR}/lib-tls.sh"

print_template() {
  cat <<'TEMPLATE'
# amp-config.env — Agent Manager advanced VM install configuration.
# Sourced by install-advanced.sh. Lines are shell assignments.

# --- Required ---
AMP_VERSION=0.15.0                 # amp/v* release tag (see github.com/wso2/agent-manager/tags)
DOMAIN_BASE=amp.mycompany.com      # service hosts derived as <svc>.<DOMAIN_BASE>
TLS_MODE=letsencrypt               # letsencrypt | letsencrypt-dns | byoc | selfsigned | upstream

# --- letsencrypt mode ---
ACME_EMAIL=ops@mycompany.com       # ACME contact (recommended)

# --- letsencrypt-dns mode (DNS-01: public-trusted certs on a PRIVATE VM) ---
# The ACME CA never connects to the VM; it reads a DNS TXT record, so no public
# ingress is needed (egress only). Requires a public DNS zone you control — A records
# may point at the VM's private IP (split-horizon is fine). ACME_EMAIL (above) is
# required in this mode. Set DNS_PROVIDER to a lego provider and supply that provider's
# credentials as env vars in this file (lego reads them natively). Documented
# providers: route53 (AWS) | cloudflare | gcloud (Google Cloud DNS) | azuredns.
# DNS_PROVIDER=route53
#   AWS:        AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_REGION=us-east-1
#   Cloudflare: CF_DNS_API_TOKEN=...
#   Google:     GCE_PROJECT=... GCE_SERVICE_ACCOUNT_FILE=/opt/amp/gcp-sa.json
#   Azure:      AZURE_TENANT_ID=... AZURE_CLIENT_ID=... AZURE_CLIENT_SECRET=... AZURE_SUBSCRIPTION_ID=...
# ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory  # optional: LE staging for testing

# --- selfsigned mode (fully offline: no public zone, no internal CA) ---
# Generates a local CA + leaf covering every service host + the *.<AGENTS_BASE>
# wildcard. The CA is written to /opt/amp/certs/ca.crt — import it into client trust
# stores (MDM/GPO) so browsers trust the console/API without warnings. No extra keys.

# --- byoc mode (operator-supplied cert/key) ---
# The cert MUST carry SANs covering *.<DOMAIN_BASE> AND *.<AGENTS_BASE>.
# TLS_CERT_FILE=/opt/amp/certs/fullchain.pem
# TLS_KEY_FILE=/opt/amp/certs/privkey.pem

# --- upstream mode (TLS terminated by a cloud LB / proxy in front of the VM) ---
# The LB must forward each hostname to the VM and set X-Forwarded-Proto: https.
# UPSTREAM_LISTEN_PORT=80          # plain-HTTP port the LB forwards to (default 80).
#   Must not be a loopback-bound cluster port (3000/8080/9000/9098/9243/19080/22893);
#   80 is safe.
# Restrict the listen port to the LB at the firewall, and set the LB's source CIDRs
# below so only it can set X-Forwarded-* (default 0.0.0.0/0 trusts any source). Use a
# space-separated list; the example is the GCP Application Load Balancer's ranges.
# UPSTREAM_TRUSTED_PROXIES="130.211.0.0/22 35.191.0.0/16"

# --- Optional ---
EXTERNAL_GATEWAYS=true             # expose the cp endpoint for external data-plane gateways

# --- Optional: Artifactory mirror registries (air-gapped installs) ---
# Set these when the VM cannot reach docker.io / ghcr.io / quay.io directly.
# Each requires the base64-encoded auth from your Artifactory config.json.
# ARTIFACTORY_DOCKER_REGISTRY=nn-docker-remote.artifactory.insim.biz
# ARTIFACTORY_DOCKER_AUTH=bTY1aDQ5MDpjbVZtZEd0dU9qQXhPakU0TVRVeU1UUTRPREE2V1dSQ2EyMVFUamR1VmtaaFdqZFhlV3R1U0RscGVFTlRlbVo1
# ARTIFACTORY_GHCR_REGISTRY=nn-ghcr-remote.artifactory.insim.biz
# ARTIFACTORY_GHCR_AUTH=bTY1aDQ5MDpjbVZtZEd0dU9qQXhPakU0TVRVeU1UWXdNalk2U0RZME1ERk1WMEpzTTFGeGEweHRaM2N4ZFhkSE5FdG9SVW94
# ARTIFACTORY_QUAY_REGISTRY=quay-io.artifactory.insim.biz
# ARTIFACTORY_QUAY_AUTH=bTY1aDQ5MDpjbVZtZEd0dU9qQXhPakU0TVRVeU1UWXdNalk2U0RZME1ERk1WMEpzTTFGeGEweHRaM2N4ZFhkSE5FdG9SVW94
# ARTIFACTORY_KGATEWAY_REGISTRY=kgateway.artifactory.insim.biz
# ARTIFACTORY_KGATEWAY_AUTH=<base64 auth for cr.kgateway.dev remote>
# --- Optional: local kgateway Helm chart files (avoids needing a cr.kgateway.dev Artifactory remote) ---
# Download with: helm pull oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds --version v2.2.1
#                helm pull oci://cr.kgateway.dev/kgateway-dev/charts/kgateway --version v2.2.1
# LOCAL_KGATEWAY_CRDS_CHART=/home/ssm-user/agent-manager/kgateway-crds-v2.2.1.tgz
# LOCAL_KGATEWAY_CHART=/home/ssm-user/agent-manager/kgateway-v2.2.1.tgz

# --- Optional per-service host overrides (default: <svc>.<DOMAIN_BASE>) ---
# HOST_CONSOLE=console.amp.mycompany.com
# HOST_API=api.amp.mycompany.com
# HOST_THUNDER=thunder.amp.mycompany.com
# HOST_OBSERVER=observer.amp.mycompany.com
# HOST_GATEWAY=gateway.amp.mycompany.com
# HOST_CP=cp.amp.mycompany.com
# AGENTS_BASE=agents.amp.mycompany.com   # deployed-agent wildcard base
TEMPLATE
}

CONFIG_FILE="" DRY_RUN="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --init) print_template; exit 0 ;;
    --config) CONFIG_FILE="${2:?--config requires a path}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[[ -n "$CONFIG_FILE" ]] || die "--config <file> is required (or --init to emit a template)"

# Load + validate config, derive hostnames.
load_config "$CONFIG_FILE" || die "could not load config: $CONFIG_FILE"
if ! validate_config; then
  printf '%s\n' "${CONFIG_ERRORS[@]}" >&2
  die "config validation failed (${#CONFIG_ERRORS[@]} error(s)) — fix amp-config.env and re-run"
fi
# Declare the host vars in this scope so the lib-vm.sh cores (dynamic scope) see them.
AMP_HOST_CONSOLE="" AMP_HOST_API="" AMP_HOST_THUNDER="" AMP_HOST_OBSERVER=""
AMP_HOST_GATEWAY="" AMP_HOST_CP="" AMP_AGENTS_BASE=""
derive_hosts

# letsencrypt-dns and selfsigned both produce a cert/key and reuse the byoc serving
# path, so default the served paths to the canonical cert dir when unset.
if [[ "$TLS_MODE" == letsencrypt-dns || "$TLS_MODE" == selfsigned ]]; then
  TLS_CERT_FILE="${TLS_CERT_FILE:-/opt/amp/certs/fullchain.pem}"
  TLS_KEY_FILE="${TLS_KEY_FILE:-/opt/amp/certs/privkey.pem}"
fi

# BYOC cert validation happens before any cluster work.
if [[ "$TLS_MODE" == byoc ]]; then
  if ! validate_cert "$TLS_CERT_FILE" "$TLS_KEY_FILE"; then
    printf '%s\n' "${CERT_ERRORS[@]}" >&2
    die "certificate validation failed — see errors above"
  fi
fi

render_active_caddyfile() {   # echoes the Caddyfile for the active TLS_MODE
  case "$TLS_MODE" in
    letsencrypt) caddyfile letsencrypt "${ACME_EMAIL:-}" "" "" "" ;;
    byoc|letsencrypt-dns|selfsigned) caddyfile byoc "" "$TLS_CERT_FILE" "$TLS_KEY_FILE" "" ;;
    upstream)    caddyfile upstream "" "" "" "${UPSTREAM_LISTEN_PORT:-80}" "${UPSTREAM_TRUSTED_PROXIES:-0.0.0.0/0}" ;;
  esac
}

# start_caddy_advanced — render the active Caddyfile and (re)start the Caddy container.
# The cert-file modes (byoc, letsencrypt-dns, selfsigned) bind-mount the cert/key
# read-only into the container.
start_caddy_advanced() {
  mkdir -p /opt/amp
  render_active_caddyfile >/opt/amp/Caddyfile
  log "Wrote /opt/amp/Caddyfile (${TLS_MODE})"

  local mounts=(-v amp-caddy-data:/data -v amp-caddy-config:/config
                -v /opt/amp/Caddyfile:/etc/caddy/Caddyfile:ro)
  if [[ "$TLS_MODE" == byoc || "$TLS_MODE" == letsencrypt-dns || "$TLS_MODE" == selfsigned ]]; then
    mounts+=(-v "${TLS_CERT_FILE}:${TLS_CERT_FILE}:ro" -v "${TLS_KEY_FILE}:${TLS_KEY_FILE}:ro")
  fi

  docker rm -f amp-caddy >/dev/null 2>&1 || true
  local caddy_image="${ARTIFACTORY_DOCKER_REGISTRY:+${ARTIFACTORY_DOCKER_REGISTRY}/}caddy:2"
  docker run -d --name amp-caddy --restart unless-stopped --network host \
    "${mounts[@]}" "$caddy_image"
  verify_caddy_up
}

# preflight_dns <strict|advisory> — confirm the derived hostnames point at THIS VM.
# On a NAT'd cloud VM the host's own interfaces show only the private IP while DNS
# points at the public one, so candidates = local IPs + the public egress IP. In
# strict mode a letsencrypt mismatch aborts (only when the public IP is known, so a
# detection failure doesn't block a correct install); in advisory mode (dry-run) it
# reports without aborting.
preflight_dns() {
  local mode="$1"
  local -a cand=(); local ip pub
  while IFS= read -r ip; do [[ -n "$ip" ]] && cand+=("$ip"); done < <(_local_ips)
  pub="$(_public_ip)"; [[ -n "$pub" ]] && cand+=("$pub")
  if (( ${#cand[@]} == 0 )); then
    log "Could not determine the VM's IP for the DNS check; skipping (verify DNS manually)."
    return 0
  fi
  if validate_dns "${cand[@]}"; then
    # validate_dns returns 0 in advisory modes even when some hosts did not resolve,
    # so only claim success when it actually recorded no errors; otherwise tell the
    # operator to point their private DNS / client hosts at this VM.
    if [[ "$mode" == advisory ]]; then
      if (( ${#DNS_ERRORS[@]} == 0 )); then
        log "DNS check: all hostnames resolve to this VM."
      else
        log "DNS check: some hostnames do not resolve to this VM yet (advisory; see above). Point your private DNS, or client /etc/hosts entries, at this VM before connecting."
      fi
    fi
    return 0
  fi
  # validate_dns already printed the per-host details + (letsencrypt) remediation.
  if [[ "$mode" == strict && "${TLS_MODE:-}" == letsencrypt ]]; then
    [[ -n "$pub" ]] && die "DNS pre-flight failed (letsencrypt) — see remediation above"
    log "WARNING: DNS check inconclusive (could not determine the VM's public IP); proceeding — Caddy will fail loudly if the hostnames don't point at this VM."
  fi
  return 0
}

run_advanced_install() {
  [[ "$(id -u)" -eq 0 ]] || die "run with sudo — this installs Docker, opens the firewall and creates the cluster"

  preflight_dns strict

  log "Phase 1/2: bootstrap (Docker + tools + firewall)"
  ensure_prerequisites
  # Configure Artifactory as Docker registry mirrors before any image pulls.
  local -a docker_mirrors=()
  [[ -n "${ARTIFACTORY_DOCKER_REGISTRY:-}" && -n "${ARTIFACTORY_DOCKER_AUTH:-}" ]] && \
    docker_mirrors+=("${ARTIFACTORY_DOCKER_REGISTRY}:${ARTIFACTORY_DOCKER_AUTH}")
  [[ -n "${ARTIFACTORY_GHCR_REGISTRY:-}" && -n "${ARTIFACTORY_GHCR_AUTH:-}" ]] && \
    docker_mirrors+=("${ARTIFACTORY_GHCR_REGISTRY}:${ARTIFACTORY_GHCR_AUTH}")
  [[ -n "${ARTIFACTORY_QUAY_REGISTRY:-}" && -n "${ARTIFACTORY_QUAY_AUTH:-}" ]] && \
    docker_mirrors+=("${ARTIFACTORY_QUAY_REGISTRY}:${ARTIFACTORY_QUAY_AUTH}")
  [[ -n "${ARTIFACTORY_KGATEWAY_REGISTRY:-}" && -n "${ARTIFACTORY_KGATEWAY_AUTH:-}" ]] && \
    docker_mirrors+=("${ARTIFACTORY_KGATEWAY_REGISTRY}:${ARTIFACTORY_KGATEWAY_AUTH}")
  if (( ${#docker_mirrors[@]} )); then
    configure_docker_mirrors "${docker_mirrors[@]}"
    # Also log helm into each Artifactory remote for OCI chart pulls.
    configure_helm_registries "${docker_mirrors[@]}"
  fi
  ensure_inotify_limits
  if [[ "$TLS_MODE" == upstream ]]; then ensure_firewall "${UPSTREAM_LISTEN_PORT:-80}"; else ensure_firewall 443; fi
  ensure_disk

  # Produce the cert before the cluster work for the cert-file modes; both then reuse
  # the byoc serving path in start_caddy_advanced below.
  case "$TLS_MODE" in
    selfsigned)
      log "Generating local CA + leaf (offline TLS)"
      generate_selfsigned_ca "$(dirname "$TLS_CERT_FILE")"
      validate_cert "$TLS_CERT_FILE" "$TLS_KEY_FILE" \
        || { printf '%s\n' "${CERT_ERRORS[@]}" >&2; die "generated self-signed cert failed validation"; }
      ;;
    letsencrypt-dns)
      mkdir -p /opt/amp
      install -m 600 "$CONFIG_FILE" /opt/amp/amp-config.env
      issue_dns01_cert "$(dirname "$TLS_CERT_FILE")"
      ;;
  esac

  log "Phase 2/2: install Agent Manager + start Caddy (this takes 8-15 min)"
  # Build the override arrays install.sh honors, from the hostname-driven cores.
  # shellcheck disable=SC2034  # arrays are inherited by the subshell that sources install.sh
  mapfile -t AMP_HELM_ARGS < <(amp_helm_args)
  # shellcheck disable=SC2034
  mapfile -t THUNDER_HELM_ARGS < <(thunder_helm_args)
  # shellcheck disable=SC2034
  mapfile -t GATEWAY_HELM_ARGS < <(gateway_helm_args)
  # shellcheck disable=SC2034
  mapfile -t CP_HELM_ARGS < <(cp_helm_args)
  # shellcheck disable=SC2034
  mapfile -t PLATFORM_RESOURCES_HELM_ARGS < <(build_platform_resources_helm_args)
  # shellcheck disable=SC2034
  mapfile -t OBSERVABILITY_HELM_ARGS < <(observability_helm_args)

  DP_EXTERNAL_INGRESS="$(dataplane_external_ingress)"; export DP_EXTERNAL_INGRESS
  export VERSION="$AMP_VERSION"
  export SHOW_LOCALHOST_URLS=false

  render_k3d_vm_config <"${QS_DIR}/k3d-config.yaml" >/tmp/k3d-config-vm.yaml
  # Rewrite the k3s node image to pull via Artifactory instead of docker.io.
  if [[ -n "${ARTIFACTORY_DOCKER_REGISTRY:-}" ]]; then
    sed -i "s|^image: rancher/k3s:|image: ${ARTIFACTORY_DOCKER_REGISTRY}/rancher/k3s:|" \
      /tmp/k3d-config-vm.yaml
    log "k3d node image rewritten to ${ARTIFACTORY_DOCKER_REGISTRY}/rancher/k3s:..."
  fi
  # Inject Artifactory mirrors into containerd registries config when configured.
  # Format: "source_registry|artifactory_registry:auth" so containerd rewrites
  # docker.io / ghcr.io / quay.io pulls through the correct Artifactory remotes.
  local -a k3d_registries=()
  [[ -n "${ARTIFACTORY_DOCKER_REGISTRY:-}" && -n "${ARTIFACTORY_DOCKER_AUTH:-}" ]] && \
    k3d_registries+=("docker.io|${ARTIFACTORY_DOCKER_REGISTRY}:${ARTIFACTORY_DOCKER_AUTH}")
  [[ -n "${ARTIFACTORY_GHCR_REGISTRY:-}" && -n "${ARTIFACTORY_GHCR_AUTH:-}" ]] && \
    k3d_registries+=("ghcr.io|${ARTIFACTORY_GHCR_REGISTRY}:${ARTIFACTORY_GHCR_AUTH}")
  [[ -n "${ARTIFACTORY_QUAY_REGISTRY:-}" && -n "${ARTIFACTORY_QUAY_AUTH:-}" ]] && \
    k3d_registries+=("quay.io|${ARTIFACTORY_QUAY_REGISTRY}:${ARTIFACTORY_QUAY_AUTH}")
  [[ -n "${ARTIFACTORY_KGATEWAY_REGISTRY:-}" && -n "${ARTIFACTORY_KGATEWAY_AUTH:-}" ]] && \
    k3d_registries+=("cr.kgateway.dev|${ARTIFACTORY_KGATEWAY_REGISTRY}:${ARTIFACTORY_KGATEWAY_AUTH}")
  if (( ${#k3d_registries[@]} )); then
    inject_artifactory_k3d_registries /tmp/k3d-config-vm.yaml "${k3d_registries[@]}"
  fi
  export K3D_CONFIG=/tmp/k3d-config-vm.yaml
  # Pre-pull the k3d-tools image from Artifactory and re-tag it as the original
  # ghcr.io URL so k3d finds it locally and never contacts ghcr.io directly.
  if [[ -n "${ARTIFACTORY_GHCR_REGISTRY:-}" ]] && command -v k3d >/dev/null 2>&1; then
    local k3d_ver; k3d_ver="$(k3d version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -n "$k3d_ver" ]]; then
      local tools_art="${ARTIFACTORY_GHCR_REGISTRY}/k3d-io/k3d-tools:${k3d_ver}"
      local tools_orig="ghcr.io/k3d-io/k3d-tools:${k3d_ver}"
      log "Pre-pulling k3d-tools: ${tools_art}"
      if docker pull "${tools_art}"; then
        docker tag "${tools_art}" "${tools_orig}"
        log "k3d-tools tagged locally as ${tools_orig} — k3d will use local image"
      else
        log "WARNING: k3d-tools pre-pull failed from Artifactory — k3d may fail to create the cluster"
      fi
    fi
  fi
  render_coredns_vm_config "k3d-amp-local-server-0" >/tmp/coredns-amp-vm.yaml
  export COREDNS_FILE=/tmp/coredns-amp-vm.yaml

  # If Artifactory mirrors are configured and a cluster already exists, delete it
  # so it is recreated with the correct containerd registry mirror config.
  # An existing cluster has no mirror config and will fail to pull images.
  if (( ${#k3d_registries[@]} )) && k3d cluster list 2>/dev/null | grep -q "^amp-local"; then
    log "Deleting existing cluster 'amp-local' — it was created without Artifactory registry mirrors and must be recreated."
    k3d cluster delete amp-local || true
    docker rm -f amp-caddy >/dev/null 2>&1 || true
  fi

  log "Running base installer with custom-domain overrides (${TLS_MODE})"
  # Patch the base installer's OCI chart URLs to route through Artifactory.
  local install_script="${QS_DIR}/install.sh"
  if [[ -n "${ARTIFACTORY_GHCR_REGISTRY:-}" || -n "${ARTIFACTORY_QUAY_REGISTRY:-}" ]]; then
    # Copy install.sh AND any helper scripts it sources to a temp dir so relative
    # source paths (e.g. install-helpers.sh) resolve correctly from the same dir.
    local patch_dir; patch_dir="$(mktemp -d)"
    cp "${QS_DIR}"/install.sh "${QS_DIR}"/install-helpers.sh "$patch_dir/" 2>/dev/null || true
    install_script="${patch_dir}/install.sh"
    [[ -n "${ARTIFACTORY_GHCR_REGISTRY:-}" ]] && \
      sed -i "s|oci://ghcr.io/|oci://${ARTIFACTORY_GHCR_REGISTRY}/|g" "$install_script"
    [[ -n "${ARTIFACTORY_QUAY_REGISTRY:-}" ]] && \
      sed -i "s|oci://quay.io/|oci://${ARTIFACTORY_QUAY_REGISTRY}/|g" "$install_script"
    # kgateway charts live on cr.kgateway.dev — use a dedicated remote if set,
    # otherwise fall back to the docker.io remote (push the chart there manually).
    # If local .tgz files are provided they take precedence over any registry.
    if [[ -n "${LOCAL_KGATEWAY_CRDS_CHART:-}" && -f "${LOCAL_KGATEWAY_CRDS_CHART}" ]]; then
      sed -i "s|oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds|${LOCAL_KGATEWAY_CRDS_CHART}|g" "$install_script"
      log "kgateway-crds: using local chart ${LOCAL_KGATEWAY_CRDS_CHART}"
    else
      local _kgateway_reg="${ARTIFACTORY_KGATEWAY_REGISTRY:-${ARTIFACTORY_DOCKER_REGISTRY:-}}"
      [[ -n "${_kgateway_reg}" ]] && \
        sed -i "s|oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds|oci://${_kgateway_reg}/kgateway-dev/charts/kgateway-crds|g" "$install_script"
    fi
    if [[ -n "${LOCAL_KGATEWAY_CHART:-}" && -f "${LOCAL_KGATEWAY_CHART}" ]]; then
      sed -i "s|oci://cr.kgateway.dev/kgateway-dev/charts/kgateway |${LOCAL_KGATEWAY_CHART} |g" "$install_script"
      log "kgateway: using local chart ${LOCAL_KGATEWAY_CHART}"
    else
      local _kgateway_reg="${ARTIFACTORY_KGATEWAY_REGISTRY:-${ARTIFACTORY_DOCKER_REGISTRY:-}}"
      [[ -n "${_kgateway_reg}" ]] && \
        sed -i "s|oci://cr.kgateway.dev/kgateway-dev/charts/kgateway |oci://${_kgateway_reg}/kgateway-dev/charts/kgateway |g" "$install_script"
    fi
    log "Patched base installer OCI chart URLs to use Artifactory (dir: ${patch_dir})"
  fi
  local rc=0
  ( set +e; source "$install_script" ) || rc=$?
  [[ "$rc" -eq 0 ]] || die "Base installer exited $rc"

  start_caddy_advanced

  # DNS-01 certs are short-lived; install a daily renewal timer (lego renew + Caddy
  # reload). The timer reads provider creds from the saved config copy.
  if [[ "$TLS_MODE" == letsencrypt-dns ]]; then
    install_renewal_timer "$(dirname "$TLS_CERT_FILE")" /opt/amp/amp-config.env
  fi

  log "Done. Access URLs:"
  cat <<EOF

  Console:   https://${AMP_HOST_CONSOLE}
  API:       https://${AMP_HOST_API}
  Thunder:   https://${AMP_HOST_THUNDER}
  Observer:  https://${AMP_HOST_OBSERVER}
  OTel ingest: https://${AMP_HOST_GATEWAY}/otel
  Deployed agents: https://<org>-<project>.${AMP_AGENTS_BASE}/...
EOF
  [[ -n "$AMP_HOST_CP" ]] && echo "  Gateway control plane: https://${AMP_HOST_CP}  (connect external gateways here; registration token is secret-bearing)"
  [[ "$TLS_MODE" == selfsigned ]] && cat <<EOF

  Self-signed mode: import the CA into client trust stores so browsers trust these
  hosts without warnings:
    CA cert: $(dirname "$TLS_CERT_FILE")/ca.crt
EOF
}

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY RUN — derived hosts:"
  printf '  console=%s api=%s thunder=%s observer=%s gateway=%s cp=%s agents=%s\n' \
    "$AMP_HOST_CONSOLE" "$AMP_HOST_API" "$AMP_HOST_THUNDER" "$AMP_HOST_OBSERVER" \
    "$AMP_HOST_GATEWAY" "${AMP_HOST_CP:-<none>}" "$AMP_AGENTS_BASE"
  log "DRY RUN — amp helm args:"; amp_helm_args
  log "DRY RUN — Caddyfile (${TLS_MODE}):"; render_active_caddyfile
  case "$TLS_MODE" in
    letsencrypt-dns)
      log "DRY RUN — DNS-01 issuance plan (lego):"
      build_lego_args "${ACME_EMAIL:-}" "$DNS_PROVIDER" "$(dirname "$TLS_CERT_FILE")" "${ACME_SERVER:-}" run
      ;;
    selfsigned)
      log "DRY RUN — self-signed cert SANs:"
      tls_san_list
      ;;
  esac
  log "DRY RUN — k3d registries config (with Artifactory mirrors):"
  render_k3d_vm_config <"${QS_DIR}/k3d-config.yaml" >/tmp/k3d-config-dryrun.yaml
  local -a dry_k3d_registries=()
  [[ -n "${ARTIFACTORY_DOCKER_REGISTRY:-}" && -n "${ARTIFACTORY_DOCKER_AUTH:-}" ]] && \
    dry_k3d_registries+=("docker.io|${ARTIFACTORY_DOCKER_REGISTRY}:${ARTIFACTORY_DOCKER_AUTH}")
  [[ -n "${ARTIFACTORY_GHCR_REGISTRY:-}" && -n "${ARTIFACTORY_GHCR_AUTH:-}" ]] && \
    dry_k3d_registries+=("ghcr.io|${ARTIFACTORY_GHCR_REGISTRY}:${ARTIFACTORY_GHCR_AUTH}")
  [[ -n "${ARTIFACTORY_QUAY_REGISTRY:-}" && -n "${ARTIFACTORY_QUAY_AUTH:-}" ]] && \
    dry_k3d_registries+=("quay.io|${ARTIFACTORY_QUAY_REGISTRY}:${ARTIFACTORY_QUAY_AUTH}")
  if (( ${#dry_k3d_registries[@]} )); then
    inject_artifactory_k3d_registries /tmp/k3d-config-dryrun.yaml "${dry_k3d_registries[@]}"
  fi
  cat /tmp/k3d-config-dryrun.yaml
  log "DRY RUN — Docker daemon mirrors:"
  if [[ -n "${ARTIFACTORY_DOCKER_REGISTRY:-}" ]]; then
    printf '  docker.io  → https://%s\n' "${ARTIFACTORY_DOCKER_REGISTRY}"
  fi
  if [[ -n "${ARTIFACTORY_GHCR_REGISTRY:-}" ]]; then
    printf '  ghcr.io    → https://%s\n' "${ARTIFACTORY_GHCR_REGISTRY}"
  fi
  if [[ -n "${ARTIFACTORY_QUAY_REGISTRY:-}" ]]; then
    printf '  quay.io    → https://%s\n' "${ARTIFACTORY_QUAY_REGISTRY}"
  fi
  if [[ -z "${ARTIFACTORY_DOCKER_REGISTRY:-}${ARTIFACTORY_GHCR_REGISTRY:-}${ARTIFACTORY_QUAY_REGISTRY:-}" ]]; then
    printf '  (none configured — VM must reach docker.io/ghcr.io/quay.io directly)\n'
  fi
  log "DRY RUN — DNS pre-flight (advisory):"; preflight_dns advisory
  exit 0
fi

run_advanced_install
