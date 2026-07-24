#!/usr/bin/env bash
# lib-tls.sh — cert production for the private VM install modes (letsencrypt-dns,
# selfsigned). Sourcing only defines functions (no side effects). The caller is
# expected to define log()/die(); fallbacks are provided so this file is usable
# standalone. The pure functions (tls_san_list, build_lego_args, render_renewal_units)
# write only to stdout; issue_dns01_cert/generate_selfsigned_ca/install_renewal_timer
# touch disk + docker and are the only side-effecting members.
command -v log >/dev/null 2>&1 || log() { printf '\033[0;34m[tls]\033[0m %s\n' "$*"; }
command -v die >/dev/null 2>&1 || die() { printf '\033[0;31m[tls] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Pin the lego image. The v5 CLI dropped the global flags build_lego_args emits
# (e.g. --accept-tos), so goacme/lego:latest (now v5.x) breaks DNS-01 issuance with
# "flag provided but not defined". v4.x keeps the flag syntax. Override via env if needed.
LEGO_IMAGE="${LEGO_IMAGE:-goacme/lego:v4.35.2}"

# tls_san_list — print the SAN hostnames (one per line) the cert must cover: every
# service host + the deployed-agent wildcard. AMP_HOST_CONSOLE is emitted first so it
# is the cert's primary/CN and lego's output filename is deterministic. CP is omitted
# when AMP_HOST_CP is empty (external gateways off). Reads AMP_HOST_*/AMP_AGENTS_BASE
# from the caller's scope (dynamic scope), matching the lib-vm.sh cores.
# shellcheck disable=SC2154,SC2153  # AMP_HOST_*/AMP_AGENTS_BASE come from the caller's scope by design.
tls_san_list() {
  printf '%s\n' "$AMP_HOST_CONSOLE" "$AMP_HOST_API" "$AMP_HOST_THUNDER" \
    "$AMP_HOST_OBSERVER" "$AMP_HOST_GATEWAY" "${AMP_HOST_REGISTRY:-}"
  [[ -n "${AMP_HOST_CP:-}" ]] && printf '%s\n' "$AMP_HOST_CP"
  printf '*.%s\n' "$AMP_AGENTS_BASE"
}

# build_lego_args <email> <provider> <path> <server> <action> — print the lego CLI
# args (one token per line) for a DNS-01 issuance/renewal covering tls_san_list.
# Pure: no docker, no network. action is "run" (issue) or "renew". Consume with:
#   mapfile -t ARGS < <(build_lego_args ...)
build_lego_args() {
  local email="$1" provider="$2" path="$3" server="$4" action="$5"
  printf '%s\n' --accept-tos --path "$path" --dns "$provider"
  [[ -n "$email" ]]  && printf '%s\n' --email "$email"
  [[ -n "$server" ]] && printf '%s\n' --server "$server"
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] && printf '%s\n' --domains "$d"
  done < <(tls_san_list)
  printf '%s\n' "$action"
}

# generate_selfsigned_ca <cert_dir> [days] — create a local CA + a leaf signed by it
# covering tls_san_list. Writes ca.crt (distribute to client trust stores),
# fullchain.pem (leaf + CA) and privkey.pem (leaf key) under <cert_dir>. Side-effecting
# (openssl + disk). Reads AMP_HOST_*/AMP_AGENTS_BASE.
generate_selfsigned_ca() {
  local dir="${1:?generate_selfsigned_ca requires a cert dir}" days="${2:-3650}"
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:4096 -nodes -days "$days" \
    -keyout "${dir}/ca.key" -out "${dir}/ca.crt" \
    -subj "/CN=Agent Manager Internal CA/O=Agent Manager" >/dev/null 2>&1 \
    || die "self-signed CA generation failed"
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${dir}/privkey.pem" -out "${dir}/leaf.csr" \
    -subj "/CN=${AMP_HOST_CONSOLE}" >/dev/null 2>&1 || die "leaf CSR generation failed"
  local san; san="$(tls_san_list | sed 's/^/DNS:/' | paste -sd, -)"
  openssl x509 -req -in "${dir}/leaf.csr" -CA "${dir}/ca.crt" -CAkey "${dir}/ca.key" \
    -CAcreateserial -days "$days" \
    -extfile <(printf 'subjectAltName=%s\n' "$san") \
    -out "${dir}/leaf.crt" >/dev/null 2>&1 || die "leaf signing failed"
  cat "${dir}/leaf.crt" "${dir}/ca.crt" > "${dir}/fullchain.pem"
}

# _lego_cred_env_args — print docker `-e NAME` args for every exported provider
# credential var (lego reads these natively: Cloudflare CF_*, AWS AWS_*, Google GCE_*/
# GOOGLE_*, Azure AZURE_*). Used for the initial issuance where the config is already
# sourced into the environment.
_lego_cred_env_args() {
  local v
  while IFS= read -r v; do
    printf '%s\n' -e "$v"
  done < <(compgen -e | grep -E '^(CF_|CLOUDFLARE_|AWS_|GCE_|GOOGLE_|AZURE_)' || true)
}

# issue_dns01_cert <cert_dir> — run dockerized lego to issue the cert into <cert_dir>,
# then copy the issued primary pair to the byoc-served fullchain.pem/privkey.pem.
# Reads ACME_EMAIL, DNS_PROVIDER, ACME_SERVER (optional), AMP_HOST_*/AMP_AGENTS_BASE.
# Side-effecting (docker + disk).
issue_dns01_cert() {
  local cert_dir="${1:-/opt/amp/certs}"
  mkdir -p "$cert_dir"
  local -a args envargs
  mapfile -t args    < <(build_lego_args "${ACME_EMAIL:-}" "$DNS_PROVIDER" "$cert_dir" "${ACME_SERVER:-}" run)
  mapfile -t envargs < <(_lego_cred_env_args)
  log "Issuing cert via DNS-01 (lego, provider=${DNS_PROVIDER})"
  docker run --rm -v "${cert_dir}:${cert_dir}" "${envargs[@]}" \
    "$LEGO_IMAGE" "${args[@]}" \
    || die "lego DNS-01 issuance failed (check DNS_PROVIDER credentials and that the zone is delegated)"
  cp "${cert_dir}/certificates/${AMP_HOST_CONSOLE}.crt" "${cert_dir}/fullchain.pem" \
    || die "lego succeeded but the expected cert ${AMP_HOST_CONSOLE}.crt was not found"
  cp "${cert_dir}/certificates/${AMP_HOST_CONSOLE}.key" "${cert_dir}/privkey.pem"
}

# render_renewal_units <cert_dir> <env_file> — print the systemd service + timer
# (separated by a "---UNIT-SEPARATOR---" marker line) that renew the DNS-01 cert daily
# and reload Caddy. Pure: writes only to stdout. The service reads provider creds from
# <env_file> (a copy of amp-config.env) via docker --env-file. action=renew skips
# re-issuing certs that are not near expiry.
render_renewal_units() {
  local cert_dir="$1" env_file="$2" cmd="" tok qtok
  # Build the lego renew command as a single quoted string. A while-read loop (not
  # mapfile) keeps this function runnable under bash 3.2 so the unit tests work on macOS.
  while IFS= read -r tok; do
    printf -v qtok ' %q' "$tok"
    cmd+="$qtok"
  done < <(build_lego_args "${ACME_EMAIL:-}" "$DNS_PROVIDER" "$cert_dir" "${ACME_SERVER:-}" renew)
  cat <<EOF
[Unit]
Description=Agent Manager TLS cert renewal (lego DNS-01)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker run --rm --env-file ${env_file} -v ${cert_dir}:${cert_dir} ${LEGO_IMAGE}${cmd}
ExecStartPost=/usr/bin/cp ${cert_dir}/certificates/${AMP_HOST_CONSOLE}.crt ${cert_dir}/fullchain.pem
ExecStartPost=/usr/bin/cp ${cert_dir}/certificates/${AMP_HOST_CONSOLE}.key ${cert_dir}/privkey.pem
ExecStartPost=/usr/bin/docker exec amp-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
---UNIT-SEPARATOR---
[Unit]
Description=Run Agent Manager TLS cert renewal daily

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# install_renewal_timer <cert_dir> <env_file> — write the renewal service + timer to
# /etc/systemd/system and enable the timer. Side-effecting (root).
install_renewal_timer() {
  local cert_dir="$1" env_file="$2" units svc timer
  units="$(render_renewal_units "$cert_dir" "$env_file")"
  svc="${units%%---UNIT-SEPARATOR---*}"
  timer="${units#*---UNIT-SEPARATOR---$'\n'}"
  printf '%s' "$svc"   > /etc/systemd/system/amp-cert-renew.service
  printf '%s' "$timer" > /etc/systemd/system/amp-cert-renew.timer
  systemctl daemon-reload
  systemctl enable --now amp-cert-renew.timer
  log "Installed daily cert-renewal timer (amp-cert-renew.timer)"
}
