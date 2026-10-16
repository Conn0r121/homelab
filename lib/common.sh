# shellcheck shell=bash
# Shared helpers: logging, preflight checks, and a dotenv loader that never
# evaluates file contents as shell (values are taken literally).

declare -gA HL_ENV=()

info()  { printf '  %s\n' "$*"; }
ok()    { printf '  \033[32mok\033[0m  %s\n' "$*"; }
warn()  { printf '  \033[33mwarn\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

require_root() {
  [[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
}

require_ubuntu() {
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ ${ID:-} != ubuntu ]]; then
    warn "tested on Ubuntu Server; detected '${ID:-unknown}'. Continuing anyway."
  fi
}

# Parse KEY=VALUE lines from stdin into HL_ENV. Later loads override earlier
# ones, so load host.env first and secrets second. Blank lines and full-line
# comments are skipped; one layer of matching surrounding quotes is stripped.
_load_dotenv() {
  local src=$1 line key val n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] \
      || die "$src:$n: not a KEY=VALUE line"
    key=${BASH_REMATCH[2]}
    val=${BASH_REMATCH[3]}
    if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then
      val=${BASH_REMATCH[1]}
    fi
    HL_ENV[$key]=$val
  done
}

load_dotenv_file()   { local f=$1; _load_dotenv "${f##*/}" < "$f"; }
load_dotenv_string() { _load_dotenv "$1" <<< "$2"; }

# env_get KEY [DEFAULT] — print HL_ENV[KEY], the default, or die if neither.
env_get() {
  local key=$1
  if [[ -n ${HL_ENV[$key]+x} ]]; then
    printf '%s' "${HL_ENV[$key]}"
  elif [[ $# -ge 2 ]]; then
    printf '%s' "$2"
  else
    die "required setting '$key' is missing from hosts/$HOST/host.env or secrets"
  fi
}

# List the KEY names declared in a stack.env.example (its contract).
example_keys() {
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$1"
}
