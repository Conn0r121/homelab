#!/usr/bin/env bash
# bootstrap.sh — converge an Ubuntu host to the state described in hosts/<host>/.
#
#   sudo ./bootstrap.sh [host]        host defaults to `hostname -s`
#
# Installs base packages, Docker and sops; decrypts hosts/<host>/secrets.sops.env
# in memory with the age key at /etc/homelab/age.key; runs Portainer from
# platform/portainer; then registers every stack in STACKS as a Git-backed
# Portainer stack. Every step checks current state first, so re-running on a
# configured host changes nothing unless the repo or secrets changed.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/install.sh
source "$REPO_DIR/lib/install.sh"
# shellcheck source=lib/portainer.sh
source "$REPO_DIR/lib/portainer.sh"

HOST="${1:-$(hostname -s)}"
HOST_DIR="$REPO_DIR/hosts/$HOST"
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/etc/homelab/age.key}"

HL_TMP=$(mktemp -d)
PT_RESP="$HL_TMP/resp.json"
trap 'rm -rf "$HL_TMP"' EXIT
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

preflight() {
  step "Preflight ($HOST)"
  require_root "$@"
  require_ubuntu
  [[ -f $HOST_DIR/host.env ]] || die "no host profile: hosts/$HOST/host.env (copy hosts/_template)"
  [[ -f $HOST_DIR/secrets.sops.env ]] || die "no secrets: hosts/$HOST/secrets.sops.env (see README)"
  [[ -f $AGE_KEY_FILE ]] || die "age key not found at $AGE_KEY_FILE (see README 'Bootstrap a new host')"
  if [[ $(stat -c '%u %a' "$AGE_KEY_FILE") != "0 600" ]]; then
    chown root:root "$AGE_KEY_FILE" && chmod 600 "$AGE_KEY_FILE"
    warn "tightened $AGE_KEY_FILE to root:root 0600"
  fi
  if [[ -n $(git -C "$REPO_DIR" status --porcelain 2>/dev/null) ]]; then
    warn "local checkout has uncommitted changes; Portainer deploys stacks from GitHub, not from this checkout"
  fi
  ok "repo at $REPO_DIR ($(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
}

load_config() {
  step "Configuration"
  load_dotenv_file "$HOST_DIR/host.env"
  local secrets
  secrets=$(SOPS_AGE_KEY_FILE=$AGE_KEY_FILE sops decrypt --input-type dotenv --output-type dotenv \
    "$HOST_DIR/secrets.sops.env") || die "could not decrypt hosts/$HOST/secrets.sops.env with $AGE_KEY_FILE"
  load_dotenv_string "secrets.sops.env" "$secrets"
  unset secrets
  ok "loaded host.env + secrets (${#HL_ENV[@]} settings)"
}

main() {
  preflight "$@"

  step "Base packages"; install_base_packages
  step "Docker";        install_docker
  step "sops";          install_sops

  load_config

  step "Portainer"
  deploy_portainer
  portainer_wait
  portainer_ensure_admin
  portainer_login
  portainer_endpoint_id
  portainer_ensure_git_source

  local stacks stack
  stacks=$(env_get STACKS "")
  step "Stacks: ${stacks:-none}"
  for stack in $stacks; do
    deploy_stack "$stack"
  done
  report_unmanaged_stacks "$stacks"

  step "Done"
  info "Portainer: https://$(hostname -s).local:9443"
  info "Stacks redeploy automatically when $(env_get HOMELAB_REPO_REF refs/heads/main) changes (polled every $(env_get GITOPS_POLL_INTERVAL 5m))."
}

main "$@"
