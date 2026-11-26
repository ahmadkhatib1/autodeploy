# shellcheck shell=bash
# Shared helpers for autodeploy. Sourced by every script in bin/.

AUTODEPLOY_HOME="${AUTODEPLOY_HOME:-/opt/autodeploy}"
AUTODEPLOY_USER="${AUTODEPLOY_USER:-deploy}"
PROJECTS_DIR="$AUTODEPLOY_HOME/projects"
APPS_DIR="$AUTODEPLOY_HOME/apps"
LOGS_DIR="$AUTODEPLOY_HOME/logs"
LOCKS_DIR="$AUTODEPLOY_HOME/locks"
CONFIG_DIR="$AUTODEPLOY_HOME/config"
KEYS_DIR="$AUTODEPLOY_HOME/keys"

PROJECT_RE='^[a-z0-9][a-z0-9-]{0,39}$'
TOKEN_RE='^[A-Za-z0-9]{16,128}$'
REF_RE='^refs/heads/[A-Za-z0-9._/-]{1,100}$'

SCRIPT_PATH_RE='^/[A-Za-z0-9._/-]+$'

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

valid_project_name() { [[ "$1" =~ $PROJECT_RE ]]; }

# Re-run the current script as the deploy user when started as root,
# so every file it creates is owned by that user.
ensure_deploy_user() {
  if [[ $EUID -eq 0 && -z "${AUTODEPLOY_ALLOW_ROOT:-}" ]]; then
    id "$AUTODEPLOY_USER" >/dev/null 2>&1 || die "user '$AUTODEPLOY_USER' does not exist. Run install.sh first."
    exec sudo -u "$AUTODEPLOY_USER" -H env AUTODEPLOY_HOME="$AUTODEPLOY_HOME" "$0" "$@"
  fi
}

# Read KEY=VALUE lines into exported variables without executing anything.
# Values may be wrapped in single or double quotes.
load_env_file() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    printf -v "$key" '%s' "$val"
    export "${key?}"
  done < "$file"
}

# Append KEY='value' to a file. Refuses values that would break the format.
write_env_var() {
  local file="$1" key="$2" val="$3"
  [[ "$val" == *"'"* || "$val" == *$'\n'* ]] && die "value for $key must not contain a single quote or a newline"
  printf "%s='%s'\n" "$key" "$val" >> "$file"
}

# ask VAR "Question" "default"
# Skips the prompt if VAR is already set in the environment, or uses the
# default when AUTODEPLOY_NONINTERACTIVE=1.
ask() {
  local var="$1" question="$2" default="${3:-}" answer
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ "${AUTODEPLOY_NONINTERACTIVE:-}" == "1" ]]; then
    printf -v "$var" '%s' "$default"; return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$question [$default]: " answer
  else
    read -r -p "$question: " answer
  fi
  printf -v "$var" '%s' "${answer:-$default}"
}

ask_yes_no() {
  local question="$1" default="${2:-y}" answer
  if [[ "${AUTODEPLOY_NONINTERACTIVE:-}" == "1" ]]; then
    [[ "$default" == "y" ]]; return
  fi
  read -r -p "$question [$( [[ $default == y ]] && echo Y/n || echo y/N )]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

# For APP_TYPE=script: put the command that runs <script> [args] into the
# SCRIPT_RUN array, through "sudo -n" when DEPLOY_AS_ROOT=yes.
build_script_cmd() {
  local script="$1"; shift
  if [[ "${DEPLOY_AS_ROOT:-no}" == "yes" ]]; then
    SCRIPT_RUN=(sudo -n "$script" "$@")
  else
    SCRIPT_RUN=("$script" "$@")
  fi
}

random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 48
  fi
}
