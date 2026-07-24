#!/usr/bin/env bash
# lib-advanced.sh — config loading, host derivation, and pre-flight validation for
# install-advanced.sh. Sourcing only defines functions (no side effects).

# derive_hosts — from DOMAIN_BASE (+ optional HOST_* overrides, AGENTS_BASE,
# EXTERNAL_GATEWAYS), set the AMP_HOST_*/AMP_AGENTS_BASE variables the lib-vm.sh
# cores read. Caller should declare these in its scope (or accept globals).
# shellcheck disable=SC2034  # AMP_HOST_*/AMP_AGENTS_BASE are consumed by the lib-vm.sh cores.
derive_hosts() {
  : "${DOMAIN_BASE:?derive_hosts requires DOMAIN_BASE}"
  AMP_HOST_CONSOLE="${HOST_CONSOLE:-console.${DOMAIN_BASE}}"
  AMP_HOST_API="${HOST_API:-api.${DOMAIN_BASE}}"
  AMP_HOST_THUNDER="${HOST_THUNDER:-thunder.${DOMAIN_BASE}}"
  AMP_HOST_OBSERVER="${HOST_OBSERVER:-observer.${DOMAIN_BASE}}"
  AMP_HOST_GATEWAY="${HOST_GATEWAY:-gateway.${DOMAIN_BASE}}"
  AMP_HOST_REGISTRY="${HOST_REGISTRY:-registry.${DOMAIN_BASE}}"
  AMP_AGENTS_BASE="${AGENTS_BASE:-agents.${DOMAIN_BASE}}"
  if [[ "${EXTERNAL_GATEWAYS:-true}" == "true" ]]; then
    AMP_HOST_CP="${HOST_CP:-cp.${DOMAIN_BASE}}"
  else
    AMP_HOST_CP=""
  fi
}

# load_config <file> — source an env-style config file in the caller's scope.
load_config() {
  local file="${1:?load_config requires a config file path}"
  [[ -f "$file" ]] || { printf 'config file not found: %s\n' "$file" >&2; return 1; }
  # Export every assignment so DNS-provider credentials (CF_*, AWS_*, GCE_*, ...) reach
  # the dockerized lego: _lego_cred_env_args lists them via `compgen -e` (exported only)
  # and forwards them with `docker run -e`. A plain `source` leaves them unexported, so
  # token-based providers (Cloudflare/route53/azuredns) would silently get no credentials.
  # shellcheck disable=SC1090
  set -a; source "$file"; set +a
}

# validate_config — check required keys and mode-specific requirements. Populates the
# CONFIG_ERRORS array (reset on each call) and returns 1 if any error was recorded.
validate_config() {
  CONFIG_ERRORS=()
  [[ -n "${AMP_VERSION:-}" ]]  || CONFIG_ERRORS+=("AMP_VERSION is required (an amp/v* release tag, e.g. 0.15.0)")
  [[ -n "${DOMAIN_BASE:-}" ]]  || CONFIG_ERRORS+=("DOMAIN_BASE is required (e.g. amp.mycompany.com)")
  case "${TLS_MODE:-}" in
    letsencrypt)
      # ACME_EMAIL is recommended but optional (Caddy issues without it; you just
      # miss expiry notices), so warn rather than fail validation.
      [[ -n "${ACME_EMAIL:-}" ]] || printf '[config] NOTE: ACME_EMAIL is recommended for letsencrypt mode (ACME contact)\n' >&2
      ;;
    byoc)
      [[ -n "${TLS_CERT_FILE:-}" ]] || CONFIG_ERRORS+=("TLS_CERT_FILE is required for byoc mode")
      [[ -n "${TLS_KEY_FILE:-}" ]]  || CONFIG_ERRORS+=("TLS_KEY_FILE is required for byoc mode")
      ;;
    upstream)
      # UPSTREAM_LISTEN_PORT defaults to 80; if set, it must be a valid port (so a typo
      # like "http" fails here, not deep in the Caddy step) and must not collide with a
      # loopback-bound cluster port — Caddy runs on the host network, so binding one of
      # those crash-loops it (e.g. 8080 is the in-cluster Thunder/kgateway port).
      if [[ -n "${UPSTREAM_LISTEN_PORT:-}" ]]; then
        if [[ "$UPSTREAM_LISTEN_PORT" =~ ^[0-9]+$ ]] && (( UPSTREAM_LISTEN_PORT >= 1 && UPSTREAM_LISTEN_PORT <= 65535 )); then
          case "$UPSTREAM_LISTEN_PORT" in
            3000|8080|9000|9098|9243|19080|22893)
              CONFIG_ERRORS+=("UPSTREAM_LISTEN_PORT=${UPSTREAM_LISTEN_PORT} collides with a loopback-bound cluster port (3000/8080/9000/9098/9243/19080/22893); pick another, e.g. 80") ;;
          esac
        else
          CONFIG_ERRORS+=("UPSTREAM_LISTEN_PORT must be a port number 1-65535 (got '${UPSTREAM_LISTEN_PORT}')")
        fi
      fi
      ;;
    letsencrypt-dns)
      # DNS-01: the ACME CA never connects to the VM (reads a TXT record from public
      # DNS), so this works on a private VM. lego needs a provider to write the TXT
      # record and an account email to register.
      [[ -n "${DNS_PROVIDER:-}" ]] || CONFIG_ERRORS+=("DNS_PROVIDER is required for letsencrypt-dns mode (a lego DNS provider, e.g. route53 | cloudflare | gcloud | azuredns)")
      [[ -n "${ACME_EMAIL:-}" ]]   || CONFIG_ERRORS+=("ACME_EMAIL is required for letsencrypt-dns mode (lego registers an ACME account with it)")
      ;;
    selfsigned)
      # Offline: a local CA + leaf is generated; no public zone, CA, or email needed.
      :
      ;;
    "")
      CONFIG_ERRORS+=("TLS_MODE is required (letsencrypt | letsencrypt-dns | byoc | selfsigned | upstream)")
      ;;
    *)
      CONFIG_ERRORS+=("TLS_MODE must be one of: letsencrypt | letsencrypt-dns | byoc | selfsigned | upstream (got '${TLS_MODE}')")
      ;;
  esac
  (( ${#CONFIG_ERRORS[@]} == 0 ))
}

# validate_cert <cert_file> <key_file> — verify a BYOC cert covers the derived hosts.
# Reads AMP_HOST_*/AMP_AGENTS_BASE. Populates CERT_ERRORS; returns 1 on any error.
# Prints a soft note (does not fail) when expiry is under 30 days.
validate_cert() {
  local cert="$1" key="$2"
  CERT_ERRORS=()
  [[ -r "$cert" ]] || CERT_ERRORS+=("cert file not readable: $cert")
  [[ -r "$key" ]]  || CERT_ERRORS+=("key file not readable: $key")
  if (( ${#CERT_ERRORS[@]} )); then return 1; fi

  # 1. Cert and key are a pair — compare public keys. Works for RSA and EC keys
  #    (the older `openssl rsa -modulus` only handles RSA and errors on EC).
  local cpub kpub
  cpub="$(openssl x509 -noout -pubkey -in "$cert" 2>/dev/null | openssl md5)"
  kpub="$(openssl pkey -pubout -in "$key" 2>/dev/null | openssl md5)"
  [[ -n "$cpub" && "$cpub" == "$kpub" ]] || CERT_ERRORS+=("cert and key do not match (public key mismatch)")

  # 2. Expiry: hard-fail if already expired; soft-note if < 30 days remain.
  if ! openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then
    CERT_ERRORS+=("cert is expired")
  elif ! openssl x509 -checkend $((30*24*3600)) -noout -in "$cert" >/dev/null 2>&1; then
    printf '[preflight] NOTE: cert expires in under 30 days\n' >&2
  fi

  # 3. SAN coverage: every service host + *.<AGENTS_BASE>.
  local sans want
  sans="$(openssl x509 -noout -ext subjectAltName -in "$cert" 2>/dev/null | tr ',' '\n' | sed 's/.*DNS://; s/[[:space:]]//g')"
  _san_covers() {  # _san_covers <hostname>
    local host="$1" s
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      [[ "$s" == "$host" ]] && return 0
      # wildcard match: *.foo.com covers bar.foo.com (exactly one extra label)
      if [[ "$s" == \*.* ]]; then
        local base="${s#\*.}"
        [[ "$host" == *."$base" && "${host%."$base"}" != *.* ]] && return 0
      fi
    done <<<"$sans"
    return 1
  }
  for want in "$AMP_HOST_CONSOLE" "$AMP_HOST_API" "$AMP_HOST_THUNDER" \
              "$AMP_HOST_OBSERVER" "$AMP_HOST_GATEWAY" "${AMP_HOST_REGISTRY:-}" "${AMP_HOST_CP:-}"; do
    [[ -z "$want" ]] && continue
    _san_covers "$want" || CERT_ERRORS+=("cert SANs do not cover $want")
  done
  # The deployed-agent tier needs the *.<AGENTS_BASE> wildcard explicitly.
  grep -qxF "*.${AMP_AGENTS_BASE}" <<<"$sans" \
    || CERT_ERRORS+=("cert is missing the deployed-agent wildcard SAN: *.${AMP_AGENTS_BASE}")
  unset -f _san_covers

  (( ${#CERT_ERRORS[@]} == 0 ))
}

# _resolve_host <hostname> — print ALL A records (one per line). Overridable in tests.
# Uses dig if present, else getent. Prints nothing if unresolved.
_resolve_host() {
  if command -v dig >/dev/null 2>&1; then
    dig +short +time=2 +tries=1 A "$1" | grep -E '^[0-9.]+$'
  else
    getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

# _local_ips — print this host's IPv4 addresses (one per line), excluding loopback.
_local_ips() {
  if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
    hostname -I | tr ' ' '\n' | grep -E '^[0-9.]+$' | grep -vE '^127\.'
  else
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  fi
}

# _public_ip — best-effort public egress IP (cloud VMs are NAT'd, so a host's own
# interfaces show only the private IP while DNS must point at the public one). Empty
# if it can't be determined. Overridable in tests.
_public_ip() {
  local ip
  for url in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    if command -v curl >/dev/null 2>&1; then
      ip="$(curl -fsS --max-time 4 "$url" 2>/dev/null)"
    elif command -v wget >/dev/null 2>&1; then
      ip="$(wget -qO- --timeout=4 "$url" 2>/dev/null)"
    fi
    ip="$(echo "$ip" | tr -d '[:space:]')"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return; }
  done
}

# validate_dns <ip> [more_ips...] — confirm derived hosts resolve to one of the given
# candidate IPs (this VM's local addresses + its public egress IP). Hard-fail in
# letsencrypt mode (ACME needs correct DNS); advisory otherwise. Populates DNS_ERRORS.
# shellcheck disable=SC2154  # AMP_HOST_*/AMP_AGENTS_BASE come from the caller's scope.
validate_dns() {
  local -a candidates=("$@")
  DNS_ERRORS=()
  local host got ip ok e
  for host in "$AMP_HOST_CONSOLE" "$AMP_HOST_API" "$AMP_HOST_THUNDER" \
              "$AMP_HOST_OBSERVER" "$AMP_HOST_GATEWAY" "${AMP_HOST_REGISTRY:-}" "${AMP_HOST_CP:-}" \
              "probe.${AMP_AGENTS_BASE}"; do
    [[ -z "$host" ]] && continue
    got="$(_resolve_host "$host")"
    if [[ -z "$got" ]]; then
      DNS_ERRORS+=("$host does not resolve to any A record")
      continue
    fi
    # Every A record must point at this VM (a resolver may return several / rotate
    # them), so a host that partly points elsewhere is caught regardless of order.
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      ok=no
      for e in "${candidates[@]}"; do [[ -n "$e" && "$ip" == "$e" ]] && { ok=yes; break; }; done
      [[ "$ok" == yes ]] || DNS_ERRORS+=("$host resolves to '${ip}', not this VM (${candidates[*]})")
    done <<<"$got"
  done
  if (( ${#DNS_ERRORS[@]} )); then
    printf '[preflight] DNS issue: %s\n' "${DNS_ERRORS[@]}" >&2
    if [[ "${TLS_MODE:-}" == letsencrypt ]]; then
      printf '[preflight] In letsencrypt mode every hostname (incl. *.%s) must A-record to this VM before ACME can issue. Create those records and re-run.\n' "$AMP_AGENTS_BASE" >&2
      return 1
    fi
    printf '[preflight] (advisory in %s mode; ensure your DNS or client hosts entries point at this VM)\n' "${TLS_MODE:-?}" >&2
  fi
  return 0
}
