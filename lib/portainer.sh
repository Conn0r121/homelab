# shellcheck shell=bash
# Portainer: run it from platform/portainer (outside GitOps, so it never
# redeploys itself), then drive its API to register the homelab repo as a Git
# source and each stack as a Git-backed stack. API shapes match Portainer
# 2.45 LTS (git credentials + polling interval live on a "source").
#
# Secrets never appear in process arguments: JSON bodies are built by jq from
# environment variables and the auth header is read from a 0600 file.

PORTAINER_URL=https://localhost:9443
PT_STATUS=
PT_RESP=
PT_ENDPOINT_ID=
PT_SOURCE_ID=

# pt_api METHOD PATH [BODY_FILE] — response body lands in $PT_RESP, HTTP status
# in $PT_STATUS. Never dies on HTTP errors; callers decide.
pt_api() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sk -o "$PT_RESP" -w '%{http_code}' -X "$method" -H 'Content-Type: application/json')
  [[ -s $HL_TMP/auth_header ]] && args+=(-H "@$HL_TMP/auth_header")
  [[ -n $body ]] && args+=(--data-binary "@$body")
  PT_STATUS=$(curl "${args[@]}" "$PORTAINER_URL/api$path") || PT_STATUS=000
}

pt_fail() { die "$1 (HTTP $PT_STATUS): $(head -c 500 "$PT_RESP")"; }

deploy_portainer() {
  local data_dir; data_dir=$(env_get PORTAINER_DATA_DIR)
  local project_containers
  project_containers=$(docker ps -aq --filter label=com.docker.compose.project=portainer)

  # Refuse to fight a Portainer that was installed some other way (e.g. the
  # classic `docker run --name portainer`). Replacing it is a decision, not a
  # side effect — see README "Existing Portainer".
  if [[ -z $project_containers ]] && docker ps -a --format '{{.Image}} {{.Names}}' | grep -qE '^portainer/portainer-(ce|ee)'; then
    die "a Portainer container not managed by platform/portainer already exists; see README 'Existing Portainer' before re-running"
  fi

  install -d -m 0700 "$data_dir"
  PORTAINER_DATA_DIR=$data_dir docker compose -p portainer \
    -f "$REPO_DIR/platform/portainer/docker-compose.yml" up -d --remove-orphans --quiet-pull
  ok "portainer running (data: $data_dir)"
}

portainer_wait() {
  local _
  for _ in $(seq 1 60); do
    pt_api GET /system/status
    [[ $PT_STATUS == 200 ]] && { ok "API up ($(jq -r .Version "$PT_RESP"))"; return; }
    sleep 2
  done
  die "Portainer API did not come up at $PORTAINER_URL"
}

portainer_ensure_admin() {
  pt_api GET /users/admin/check
  [[ $PT_STATUS == 204 ]] && { ok "admin user exists"; return; }

  # No admin yet. A fresh Portainer locks itself if no admin is created within
  # 5 minutes, and (since 2.45) admin init needs the one-time setup token it
  # prints at startup. Restart for a fresh window and token, then read the
  # token back from the container logs.
  info "no admin yet; restarting Portainer for a fresh setup window"
  docker restart portainer >/dev/null
  portainer_wait
  pt_api GET /users/admin/check
  [[ $PT_STATUS == 404 ]] || pt_fail "admin check failed after restart"

  local token
  token=$(docker logs portainer 2>&1 | grep -oE 'setup_token=[0-9a-f]{64}' | tail -n 1 | cut -d= -f2 || true)
  [[ -n $token ]] || die "could not find Portainer's setup token in 'docker logs portainer'"

  write_credentials_body
  # Not logged in yet, so the header file carries only the setup token here;
  # portainer_login replaces it with the session token.
  ( umask 077; printf 'X-Setup-Token: %s\n' "$token" > "$HL_TMP/auth_header" )
  pt_api POST /users/admin/init "$HL_TMP/body.json"
  : > "$HL_TMP/auth_header"
  [[ $PT_STATUS == 200 ]] || pt_fail "admin init failed"
  ok "admin user created"
}

write_credentials_body() {
  local user pw
  user=$(env_get PORTAINER_ADMIN_USER admin)
  pw=$(env_get PORTAINER_ADMIN_PASSWORD)
  ((${#pw} >= 12)) || die "PORTAINER_ADMIN_PASSWORD must be at least 12 characters"
  PT_USER=$user PT_PW=$pw jq -n '{Username: env.PT_USER, Password: env.PT_PW}' > "$HL_TMP/body.json"
}

portainer_login() {
  write_credentials_body
  pt_api POST /auth "$HL_TMP/body.json"
  [[ $PT_STATUS == 200 ]] || pt_fail "login failed — does PORTAINER_ADMIN_PASSWORD match the existing admin?"
  ( umask 077; printf 'Authorization: Bearer %s\n' "$(jq -r .jwt "$PT_RESP")" > "$HL_TMP/auth_header" )
  ok "logged in"
}

# The local Docker environment is created by Portainer itself (-H flag) once
# the admin exists; wait for it rather than creating one.
portainer_endpoint_id() {
  local _
  for _ in $(seq 1 30); do
    pt_api GET /endpoints
    if [[ $PT_STATUS == 200 ]]; then
      PT_ENDPOINT_ID=$(jq -r '[.[] | select(.URL == "unix:///var/run/docker.sock")][0].Id // empty' "$PT_RESP")
      [[ -n $PT_ENDPOINT_ID ]] && { ok "local environment id=$PT_ENDPOINT_ID"; return; }
    fi
    sleep 2
  done
  pt_fail "local Docker environment never appeared"
}

portainer_ensure_git_source() {
  local url interval
  url=$(env_get HOMELAB_REPO_URL)
  interval=$(env_get GITOPS_POLL_INTERVAL 5m)

  pt_api GET /gitops/sources
  [[ $PT_STATUS == 200 ]] || pt_fail "listing git sources failed"
  PT_SOURCE_ID=$(U=$url jq -r '[.[] | select(.url == env.U)][0].id // empty' "$PT_RESP")

  # Credentials are optional: the repo is public, so Portainer clones
  # anonymously unless PORTAINER_GIT_TOKEN is set (e.g. if it goes private).
  export SRC_URL=$url SRC_INTERVAL=$interval
  export SRC_USER; SRC_USER=$(env_get PORTAINER_GIT_USERNAME "")
  export SRC_TOKEN; SRC_TOKEN=$(env_get PORTAINER_GIT_TOKEN "")
  local auth='if env.SRC_TOKEN != "" then {authentication: {username: env.SRC_USER, password: env.SRC_TOKEN}} else {} end'
  if [[ -z $PT_SOURCE_ID ]]; then
    jq -n "{name: \"homelab\", url: env.SRC_URL, interval: env.SRC_INTERVAL,
            administratorsOnly: true} + ($auth)" > "$HL_TMP/body.json"
    pt_api POST /gitops/sources/git "$HL_TMP/body.json"
    [[ $PT_STATUS == 201 ]] || pt_fail "creating git source failed"
    PT_SOURCE_ID=$(jq -r .id "$PT_RESP")
    ok "git source created (id=$PT_SOURCE_ID, polling every $interval${SRC_TOKEN:+, authenticated})"
  else
    # Always push the interval (and credentials, if any) so changes apply on re-run.
    jq -n "{interval: env.SRC_INTERVAL} + ($auth)" > "$HL_TMP/body.json"
    pt_api PUT "/gitops/sources/$PT_SOURCE_ID" "$HL_TMP/body.json"
    [[ $PT_STATUS == 200 ]] || pt_fail "updating git source failed"
    ok "git source up to date (id=$PT_SOURCE_ID, polling every $interval)"
  fi
  unset SRC_USER SRC_TOKEN

  if [[ $(jq -r '.statusError // empty' "$PT_RESP") != "" ]]; then
    warn "Portainer reports the repo is unreachable: $(jq -r .statusError "$PT_RESP")"
  fi
}

# stack_env_json STACK — resolve every key in the stack's stack.env.example to
# a [{name, value}] array. Lookup order: <STACK>__KEY, then KEY. Creates any
# absolute path held by a *_DIR or *_LOCATION key.
stack_env_json() {
  local stack=$1 prefix key val pairs=()
  prefix=$(tr '[:lower:]-' '[:upper:]_' <<< "$stack")__
  local example="$REPO_DIR/stacks/$stack/stack.env.example"
  [[ -f $example ]] || die "stacks/$stack/stack.env.example is missing"

  while IFS= read -r key; do
    if [[ -n ${HL_ENV[$prefix$key]+x} ]]; then
      val=${HL_ENV[$prefix$key]}
    elif [[ -n ${HL_ENV[$key]+x} ]]; then
      val=${HL_ENV[$key]}
    else
      die "stack '$stack' needs $key: set ${prefix}${key} (or $key) in hosts/$HOST/host.env or secrets"
    fi
    if [[ $key =~ _(DIR|LOCATION)$ && $val == /* && ! -d $val ]]; then
      install -d -m 0755 "$val"
      info "created $val" >&2  # stdout is the JSON result
    fi
    pairs+=("$(K=$key V=$val jq -cn '{name: env.K, value: env.V}')")
  done < <(example_keys "$example")

  printf '%s\n' "${pairs[@]}" | jq -cs 'sort_by(.name)'
}

deploy_stack() {
  local stack=$1 ref compose env_json
  ref=$(env_get HOMELAB_REPO_REF refs/heads/main)
  compose="stacks/$stack/docker-compose.yml"
  [[ -f $REPO_DIR/$compose ]] || die "$compose not found"
  env_json=$(stack_env_json "$stack")

  pt_api GET /stacks
  [[ $PT_STATUS == 200 ]] || pt_fail "listing stacks failed"
  local existing
  existing=$(N=$stack E=$PT_ENDPOINT_ID jq -c \
    '[.[] | select(.Name == env.N and (.EndpointId | tostring) == env.E)][0] // empty' "$PT_RESP")

  export ST_NAME=$stack ST_REF=$ref ST_COMPOSE=$compose ST_ENV=$env_json ST_SRC=$PT_SOURCE_ID

  if [[ -z $existing ]]; then
    jq -n '{Name: env.ST_NAME, SourceID: (env.ST_SRC | tonumber),
            RepositoryReferenceName: env.ST_REF, ComposeFile: env.ST_COMPOSE,
            Env: (env.ST_ENV | fromjson)}' > "$HL_TMP/body.json"
    pt_api POST "/stacks/create/standalone/repository?endpointId=$PT_ENDPOINT_ID" "$HL_TMP/body.json"
    [[ $PT_STATUS == 200 ]] || pt_fail "creating stack '$stack' failed"
    ok "$stack: created and deployed"
    return
  fi

  local id
  id=$(jq -r .Id <<< "$existing")
  [[ $(jq -r '.GitConfig // empty' <<< "$existing") != "" ]] \
    || die "stack '$stack' already exists but is not Git-backed; remove it in Portainer (containers keep running) and re-run"

  # Only touch the stack when its desired state differs, so re-runs are no-ops.
  local current_env current_ref current_compose
  current_env=$(jq -c '(.Env // []) | map({name, value}) | sort_by(.name)' <<< "$existing")
  current_ref=$(jq -r '.GitConfig.ReferenceName' <<< "$existing")
  current_compose=$(jq -r '.GitConfig.ConfigFilePath' <<< "$existing")
  if [[ $current_env == "$env_json" && $current_ref == "$ref" && $current_compose == "$compose" ]]; then
    ok "$stack: up to date (id=$id)"
    return
  fi

  jq -n '{SourceID: (env.ST_SRC | tonumber), RepositoryReferenceName: env.ST_REF,
          ConfigFilePath: env.ST_COMPOSE, Env: (env.ST_ENV | fromjson), Prune: false}' > "$HL_TMP/body.json"
  pt_api POST "/stacks/$id/git?endpointId=$PT_ENDPOINT_ID" "$HL_TMP/body.json"
  [[ $PT_STATUS == 200 ]] || pt_fail "updating stack '$stack' failed"

  jq -n '{RepositoryReferenceName: env.ST_REF, Env: (env.ST_ENV | fromjson),
          Prune: false, RepullImageAndRedeploy: false}' > "$HL_TMP/body.json"
  pt_api PUT "/stacks/$id/git/redeploy?endpointId=$PT_ENDPOINT_ID" "$HL_TMP/body.json"
  [[ $PT_STATUS == 200 ]] || pt_fail "redeploying stack '$stack' failed"
  ok "$stack: updated and redeployed (id=$id)"
}

# Stacks that exist in Portainer but aren't listed in STACKS are reported,
# never deleted.
report_unmanaged_stacks() {
  pt_api GET /stacks
  [[ $PT_STATUS == 200 ]] || return 0
  local name
  for name in $(E=$PT_ENDPOINT_ID jq -r '.[] | select((.EndpointId | tostring) == env.E) | .Name' "$PT_RESP"); do
    [[ " $1 " == *" $name "* ]] || warn "stack '$name' is in Portainer but not in STACKS (left alone)"
  done
}
