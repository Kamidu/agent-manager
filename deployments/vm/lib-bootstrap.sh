#!/usr/bin/env bash
# lib-bootstrap.sh — host preparation shared by install-vm.sh and install-advanced.sh.
# Sourcing only defines functions (no side effects). The caller is expected to define
# log()/die(); fallbacks are provided so this file is usable standalone.

command -v log >/dev/null 2>&1 || log() { printf '\033[0;34m[bootstrap]\033[0m %s\n' "$*"; }
command -v die >/dev/null 2>&1 || die() { printf '\033[0;31m[bootstrap] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker via get.docker.com"
    curl -fsSL https://get.docker.com | sh
  else
    log "Docker CLI present"
  fi
  systemctl enable --now docker
  local _
  for _ in $(seq 1 15); do docker info >/dev/null 2>&1 && return; sleep 2; done
  die "Docker daemon did not become ready"
}

ensure_prerequisites() {
  local arch; arch="$(dpkg --print-architecture)"   # amd64 | arm64
  local pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v lsof >/dev/null 2>&1 || pkgs+=(lsof)
  command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
  if (( ${#pkgs[@]} )); then
    log "Installing base packages: ${pkgs[*]}"
    apt-get update -qq && apt-get install -y -qq "${pkgs[@]}"
  fi

  ensure_docker

  if ! command -v k3d >/dev/null 2>&1; then
    log "Installing k3d"
    curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    log "Installing kubectl (${arch})"
    local kver; kver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${kver}/bin/linux/${arch}/kubectl"
    chmod +x /usr/local/bin/kubectl
  fi
  if ! command -v helm >/dev/null 2>&1; then
    log "Installing helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

# configure_docker_mirrors <reg1:auth1> [<reg2:auth2> ...]
# Configures Docker daemon and /root/.docker/config.json for multiple Artifactory
# remotes. Restarts the daemon so mirrors are active before any image pulls.
configure_docker_mirrors() {
  [[ $# -gt 0 ]] || { log "No registries configured"; return 0; }
  log "Configuring Docker daemon mirrors for $# registry(ies)"

  mkdir -p /root/.docker
  local config_json='{"auths":{'
  local daemon_mirrors='[]'
  local first=true

  for pair in "$@"; do
    local registry="${pair%%:*}" auth="${pair##*:}"
    [[ -z "$registry" || -z "$auth" ]] && { log "WARNING: invalid registry:auth pair '$pair'"; continue; }

    # Add to docker config.json auths.
    if [[ "$first" == true ]]; then
      config_json+="\"${registry}\":{\"auth\":\"${auth}\"}"
      first=false
    else
      config_json+=",\"${registry}\":{\"auth\":\"${auth}\"}"
    fi

    # Add to daemon mirror list.
    daemon_mirrors="$(python3 -c "import json; m = json.loads('${daemon_mirrors}'); m.append('https://${registry}'); print(json.dumps(m))")"
  done

  config_json+='}}'
  printf '%s\n' "$config_json" >/root/.docker/config.json
  chmod 600 /root/.docker/config.json

  # Merge mirrors into /etc/docker/daemon.json.
  local daemon=/etc/docker/daemon.json
  local current='{"registry-mirrors":'
  current+="${daemon_mirrors}}"
  [[ -f "$daemon" ]] && current="$(cat "$daemon")"
  python3 - "$daemon" "$daemon_mirrors" <<'PYEOF'
import json, sys, os
d = json.loads(open(sys.argv[1], 'r').read() if os.path.exists(sys.argv[1]) else '{}')
mirrors = json.loads(sys.argv[2])
if mirrors:
    d['registry-mirrors'] = mirrors
with open(sys.argv[1], 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
PYEOF
  systemctl reload-or-restart docker 2>/dev/null || true
  local _
  for _ in $(seq 1 10); do docker info >/dev/null 2>&1 && break; sleep 2; done
  log "Docker mirrors configured for $# registry(ies)"
}

# configure_helm_registries <reg1:auth1> [<reg2:auth2> ...]
# Logs helm into each Artifactory registry so OCI chart pulls are authenticated.
configure_helm_registries() {
  command -v helm >/dev/null 2>&1 || return 0
  for pair in "$@"; do
    local registry="${pair%%:*}" auth="${pair##*:}"
    [[ -z "$registry" || -z "$auth" ]] && continue
    local decoded username password
    decoded="$(printf '%s' "$auth" | base64 -d 2>/dev/null)" || continue
    username="${decoded%%:*}"
    password="${decoded#*:}"
    helm registry login "$registry" --username "$username" --password "$password" 2>/dev/null \
      && log "helm: logged in to ${registry}" \
      || log "WARNING: helm registry login failed for ${registry} (non-fatal)"
  done
}

# ensure_firewall <port> — open the given inbound TCP port on the OS firewall.
ensure_firewall() {
  local port="${1:?ensure_firewall requires a port}"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${port}/tcp" || true
    log "ufw: opened ${port}"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" || true
    firewall-cmd --reload || true
    log "firewalld: opened ${port}"
  else
    log "No ufw/firewalld found; assuming the host firewall is open for ${port}"
  fi
  log "Ensure inbound ${port}/tcp is open in your cloud security group (raw TCP, no TLS-terminating proxy in front) — Caddy needs it."
}

ensure_disk() {
  local avail_kb min_kb=$((40 * 1024 * 1024))
  avail_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$min_kb" ]]; then
    log "WARNING: only $((avail_kb / 1024 / 1024)) GB free on / — agent builds may"
    log "         hit DiskPressure. A 50 GB+ disk is recommended (see the VM docs)."
  fi
}

# inotify_bump_target <current> <floor> — echo <floor> when the current sysctl value is
# below it (or empty/non-numeric, i.e. unreadable), else echo nothing. Pure: lets the
# caller decide whether a bump is needed without touching sysctl, and keeps the
# never-lower-an-existing-higher-value rule unit-testable.
inotify_bump_target() {
  local current="$1" floor="$2"
  if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= floor )); then return 0; fi
  printf '%s' "$floor"
}

# ensure_inotify_limits — raise fs.inotify.max_user_{instances,watches} to the floors k3d
# needs (kubelet + many containers each open watches) and persist them. A fresh
# single-user install can otherwise exhaust the default instance ceiling: systemd logs
# "Failed to allocate directory watch: Too many open files" and k3d configmap/secret
# watches silently go stale. Only keys actually below their floor are touched/persisted,
# so a host already tuned higher is never lowered.
ensure_inotify_limits() {
  local inst_floor=512 watch_floor=524288 cur tgt conf=/etc/sysctl.d/99-amp-inotify.conf
  local -a lines=()

  cur="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || true)"
  tgt="$(inotify_bump_target "$cur" "$inst_floor")"
  if [[ -n "$tgt" ]]; then
    sysctl -w "fs.inotify.max_user_instances=$tgt" >/dev/null 2>&1 || true
    lines+=("fs.inotify.max_user_instances=$tgt")
  fi

  cur="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || true)"
  tgt="$(inotify_bump_target "$cur" "$watch_floor")"
  if [[ -n "$tgt" ]]; then
    sysctl -w "fs.inotify.max_user_watches=$tgt" >/dev/null 2>&1 || true
    lines+=("fs.inotify.max_user_watches=$tgt")
  fi

  if (( ${#lines[@]} )); then
    printf '%s\n' "${lines[@]}" > "$conf" 2>/dev/null || true
    log "Raised inotify limits for k3d (${lines[*]})"
  else
    log "inotify limits already sufficient for k3d"
  fi
}

# verify_caddy_up — fail loudly if the amp-caddy container isn't healthy shortly after
# start. Caddy runs on the host network, so a port collision (e.g. an UPSTREAM_LISTEN_PORT
# already bound by k3d) makes it crash-loop; without this check the installer would
# report success while every request 404s through a dead proxy.
verify_caddy_up() {
  sleep 5
  local status restarts
  status="$(docker inspect -f '{{.State.Status}}' amp-caddy 2>/dev/null || true)"
  restarts="$(docker inspect -f '{{.RestartCount}}' amp-caddy 2>/dev/null || echo 0)"
  if [[ "$status" != "running" || "${restarts:-0}" -gt 0 ]]; then
    log "amp-caddy is not healthy (status=${status:-missing}, restarts=${restarts:-?}). Recent logs:"
    docker logs --tail 25 amp-caddy 2>&1 | sed 's/^/    /' >&2 || true
    die "Caddy failed to start — see logs above (in upstream mode, a common cause is UPSTREAM_LISTEN_PORT colliding with a loopback-bound cluster port)"
  fi
  log "Caddy healthy (status=${status})"
}
