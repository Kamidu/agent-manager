#!/usr/bin/env bash
set -euo pipefail

DST_REGISTRY="${DST_REGISTRY:-registry.amp.asgard-e.aws.insim.biz}"
SRC_DOCKER="${SRC_DOCKER:-nn-docker.artifactory.insim.biz}"
SRC_GHCR="${SRC_GHCR:-ghcr.io}"
SRC_QUAY="${SRC_QUAY:-quay.io}"
SRC_KGATEWAY="${SRC_KGATEWAY:-cr.kgateway.dev}"
SRC_GCR="${SRC_GCR:-gcr.io}"

if [[ -n "${ARTIFACTORY_AUTH_B64:-}" ]]; then
  decoded_auth="$(printf '%s' "$ARTIFACTORY_AUTH_B64" | base64 -d)"
  art_user="${decoded_auth%%:*}"
  art_pass="${decoded_auth#*:}"
  printf '%s' "$art_pass" | docker login "$SRC_DOCKER" --username "$art_user" --password-stdin >/dev/null
fi

ENGINE=""
if command -v skopeo >/dev/null 2>&1; then
  ENGINE="skopeo"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
else
  echo "Need either skopeo or docker installed" >&2
  exit 1
fi

copy_image() {
  local src="$1"
  local dst="$2"

  echo "Copying ${src} -> ${dst}"
  case "$ENGINE" in
    skopeo)
      skopeo copy --all "docker://${src}" "docker://${dst}"
      ;;
    docker)
      docker pull "$src"
      docker tag "$src" "$dst"
      docker push "$dst"
      ;;
  esac
}

copy_many() {
  local -a items=("$@")
  local item src dst
  for item in "${items[@]}"; do
    src="${item%%|*}"
    dst="${item#*|}"
    copy_image "$src" "$dst"
  done
}

core_images=(
  "${SRC_GHCR}/wso2/amp-api:v0.18.0|${DST_REGISTRY}/wso2/amp-api:v0.18.0"
  "${SRC_GHCR}/wso2/amp-console:v0.18.0|${DST_REGISTRY}/wso2/amp-console:v0.18.0"
  "${SRC_GHCR}/wso2/amp-traces-observer:v0.18.0|${DST_REGISTRY}/wso2/amp-traces-observer:v0.18.0"
  "${SRC_GHCR}/thunder-id/thunderid:0.45.0|${DST_REGISTRY}/thunder-id/thunderid:0.45.0"
  "${SRC_DOCKER}/library/postgres:16-alpine|${DST_REGISTRY}/library/postgres:16-alpine"
  "${SRC_DOCKER}/library/alpine:3.21|${DST_REGISTRY}/library/alpine:3.21"
  "${SRC_DOCKER}/alpine/k8s:1.32.3|${DST_REGISTRY}/alpine/k8s:1.32.3"
  "${SRC_DOCKER}/buildpacksio/lifecycle:0.20.5|${DST_REGISTRY}/buildpacksio/lifecycle:0.20.5"
  "${SRC_DOCKER}/library/caddy:2|${DST_REGISTRY}/library/caddy:2"
  "${SRC_GHCR}/openchoreo/buildpack/ballerina:18|${DST_REGISTRY}/openchoreo/buildpack/ballerina:18"
  "${SRC_GHCR}/openchoreo/buildpack/ballerina:18-run|${DST_REGISTRY}/openchoreo/buildpack/ballerina:18-run"
  "${SRC_DOCKER}/bitnamilegacy/kubectl:1.32.4|${DST_REGISTRY}/bitnamilegacy/kubectl:1.32.4"
  "${SRC_DOCKER}/fluent/fluent-bit:4.2.3|${DST_REGISTRY}/fluent/fluent-bit:4.2.3"
  "${SRC_DOCKER}/rancher/k3s:v1.32.9-k3s1|${DST_REGISTRY}/rancher/k3s:v1.32.9-k3s1"
)

build_images=(
  "${SRC_GHCR}/openchoreo/podman-runner:v1.0|${DST_REGISTRY}/openchoreo/podman-runner:v1.0"
  "${SRC_GHCR}/openchoreo/podman-runner:v1.2|${DST_REGISTRY}/openchoreo/podman-runner:v1.2"
  "${SRC_GHCR}/jqlang/jq:1.7.1|${DST_REGISTRY}/jqlang/jq:1.7.1"
  "${SRC_DOCKER}/alpine/git:latest|${DST_REGISTRY}/alpine/git:latest"
  "${SRC_DOCKER}/library/busybox:1.36|${DST_REGISTRY}/library/busybox:1.36"
)

optional_images=(
  "${SRC_GCR}/buildpacks/builder@sha256:5977b4bd47d3e9ff729eefe9eb99d321d4bba7aa3b14986323133f40b622aef1|${DST_REGISTRY}/buildpacks/builder@sha256:5977b4bd47d3e9ff729eefe9eb99d321d4bba7aa3b14986323133f40b622aef1"
  "${SRC_GCR}/buildpacks/google-22/run:latest|${DST_REGISTRY}/buildpacks/google-22/run:latest"
)

echo "Using engine: ${ENGINE}"
echo "Destination registry: ${DST_REGISTRY}"

copy_many "${core_images[@]}"
copy_many "${build_images[@]}"

if [[ "${INCLUDE_OPTIONAL:-false}" == "true" ]]; then
  copy_many "${optional_images[@]}"
fi

echo "Done."
