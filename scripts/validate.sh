#!/usr/bin/env bash
# validate.sh — repo consistency checks, run by CI and safe to run locally.
# Needs bash, git and docker (compose plugin). Touches nothing outside a temp dir.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0
err() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 1. Every compose file renders, in Portainer's layout: stack.env at the repo
#    root, compose file under stacks/<s>/. Relative paths in a compose file
#    resolve from its own directory, so this catches a wrong env_file path.
[[ -e stack.env ]] && { err "remove ./stack.env first (validate.sh writes its own)"; exit 1; }
trap 'rm -rf "$tmp" stack.env' EXIT
for dir in stacks/*/; do
  stack=$(basename "$dir")
  [[ -f $dir/docker-compose.yml ]] || { err "$dir has no docker-compose.yml"; continue; }
  [[ -f $dir/stack.env.example ]] || { err "$dir has no stack.env.example"; continue; }
  cp "$dir/stack.env.example" stack.env
  # No --project-directory: like Portainer, compose then resolves relative
  # paths from the compose file's own directory.
  if docker compose --env-file stack.env -f "$dir/docker-compose.yml" config -q; then
    echo "ok   compose: $stack"
  else
    err "compose config failed: $stack"
  fi
done
rm -f stack.env
if PORTAINER_DATA_DIR=/tmp/portainer docker compose -f platform/portainer/docker-compose.yml config -q; then
  echo "ok   compose: platform/portainer"
else
  err "compose config failed: platform/portainer"
fi

# 2. Every stack a host asks for exists.
for host_env in hosts/*/host.env; do
  stacks=$(sed -nE 's/^STACKS=(.*)$/\1/p' "$host_env" | tr -d '"'"'")
  for s in $stacks; do
    [[ -d stacks/$s ]] || err "$host_env lists unknown stack '$s'"
  done
done
echo "ok   host stack lists"

# 3. No plaintext secrets: committed secrets files must be sops-encrypted.
while IFS= read -r f; do
  grep -q '^sops_mac=' "$f" || err "$f is not sops-encrypted"
done < <(git ls-files '*.sops.env')
if git ls-files | grep -qE '(^|/)(secrets\.env|\.env|stack\.env|age\.key|keys\.txt)$|\.agekey$'; then
  err "a plaintext secret or key file is tracked by git"
fi
echo "ok   secrets"

# 4. Shell scripts lint clean (skipped locally if shellcheck isn't installed).
if command -v shellcheck >/dev/null; then
  shellcheck -x bootstrap.sh lib/*.sh scripts/*.sh && echo "ok   shellcheck"
else
  echo "skip shellcheck (not installed)"
fi

exit "$fail"
