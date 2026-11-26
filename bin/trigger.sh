#!/usr/bin/env bash
# Entry point for n8n. Installed as a forced SSH command, so the n8n key can
# run nothing else on the server.
# Input (from SSH_ORIGINAL_COMMAND or arguments): <project> <token> <ref>
# Only the last three words are used, because the n8n SSH node may prefix
# the command with "cd <dir> ;". Nothing from the input is ever executed.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${AUTODEPLOY_LIB:-$SCRIPT_DIR/../lib}"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

INPUT="${SSH_ORIGINAL_COMMAND:-$*}"
read -r -a words <<< "$INPUT"

mkdir -p "$LOGS_DIR"
TRIGGER_LOG="$LOGS_DIR/trigger.log"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$TRIGGER_LOG"; }

reply() { echo "$1"; log "$1"; exit "$2"; }

(( ${#words[@]} >= 3 )) || reply "ERR bad_input" 2
n=${#words[@]}
project="${words[n-3]}"
token="${words[n-2]}"
ref="${words[n-1]}"

[[ "$project" =~ $PROJECT_RE ]] || reply "ERR bad_project" 2
[[ "$token" =~ $TOKEN_RE ]]     || reply "ERR bad_token_format project=$project" 2
[[ "$ref" =~ $REF_RE ]]         || reply "ERR bad_ref project=$project" 2

[[ -f "$PROJECTS_DIR/$project.env" ]] || reply "ERR unknown_project project=$project" 4

DEPLOY_TOKEN=""
BRANCH="main"
load_env_file "$PROJECTS_DIR/$project.env"

[[ -n "$DEPLOY_TOKEN" && "$token" == "$DEPLOY_TOKEN" ]] || reply "ERR unauthorized project=$project" 3
[[ "$ref" == "refs/heads/$BRANCH" ]] || reply "SKIP branch ${ref#refs/heads/} != $BRANCH project=$project" 0

setsid nohup "$SCRIPT_DIR/deploy.sh" "$project" </dev/null >/dev/null 2>&1 &
reply "OK queued project=$project" 0
