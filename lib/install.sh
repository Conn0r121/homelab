# shellcheck shell=bash
# Host package installation. Each function checks what is already present and
# only changes what's missing, so re-runs are no-ops.

SOPS_VERSION=3.13.3
declare -gA SOPS_SHA256=(
  [amd64]=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
  [arm64]=53b0abacd38ef1b12a66d6c100956691b9cefce018d91f81e73ddf7438b94d77
)

BASE_PACKAGES=(ca-certificates curl jq git age avahi-daemon)

install_base_packages() {
  local missing=() p
  for p in "${BASE_PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then
    ok "already installed: ${BASE_PACKAGES[*]}"
    return
  fi
  info "installing: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
  ok "installed: ${missing[*]}"
}

install_docker() {
  local fresh=0
  if ! command -v docker >/dev/null; then
    info "installing Docker Engine from download.docker.com"
    local codename
    # shellcheck disable=SC1091
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
      > /etc/apt/sources.list.d/docker.list
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fresh=1
  else
    ok "docker present ($(docker --version | cut -d, -f1))"
  fi

  if ! docker compose version >/dev/null 2>&1; then
    # Match the compose package to however Docker was installed, so we never
    # mix Ubuntu's docker.io with Docker's own repo.
    if dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q 'install ok installed'; then
      info "installing docker-compose-v2 (Ubuntu docker.io detected)"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-v2
    else
      info "installing docker-compose-plugin"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin
    fi
  fi
  ok "$(docker compose version)"

  # Default json-file logging grows without bound; the 'local' driver rotates.
  # Only written when absent, so an existing daemon.json is never touched.
  if [[ ! -f /etc/docker/daemon.json ]]; then
    printf '{\n  "log-driver": "local"\n}\n' > /etc/docker/daemon.json
    if ((fresh)); then
      systemctl restart docker
      ok "set log-driver=local"
    else
      warn "wrote /etc/docker/daemon.json (log-driver=local); it applies after 'systemctl restart docker' (restarts containers) and only to new containers"
    fi
  fi

  systemctl enable --now docker >/dev/null 2>&1 || true
}

install_sops() {
  if command -v sops >/dev/null && sops --version 2>/dev/null | grep -q "sops $SOPS_VERSION"; then
    ok "sops $SOPS_VERSION present"
    return
  fi
  local arch; arch=$(dpkg --print-architecture)
  [[ -n ${SOPS_SHA256[$arch]:-} ]] || die "no pinned sops checksum for arch '$arch'"
  local url="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}"
  info "installing sops $SOPS_VERSION ($arch)"
  curl -fsSL "$url" -o "$HL_TMP/sops"
  echo "${SOPS_SHA256[$arch]}  $HL_TMP/sops" | sha256sum -c --quiet - || die "sops checksum mismatch"
  install -m 0755 "$HL_TMP/sops" /usr/local/bin/sops
  ok "sops $SOPS_VERSION installed"
}
