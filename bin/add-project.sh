#!/usr/bin/env bash
# Register a new project for auto-deploy.
# Usage: autodeploy add            (interactive)
# Every question can be answered in advance with an env var of the same
# name, e.g.  NAME=hisabyy REPO_URL=git@gitlab.com:me/hisabyy.git autodeploy add
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${AUTODEPLOY_LIB:-$SCRIPT_DIR/../lib}"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../lib/steps.sh
source "$LIB_DIR/steps.sh"

ensure_deploy_user "$@"

load_env_file "$CONFIG_DIR/server.env" || true
mkdir -p "$PROJECTS_DIR" "$KEYS_DIR" "$APPS_DIR"
chmod 700 "$PROJECTS_DIR" "$KEYS_DIR"

echo
echo "=== Add a project to autodeploy ==="
echo

ask NAME "Project name (lowercase letters, digits, dashes; e.g. hisabyy)"
valid_project_name "$NAME" || die "invalid name '$NAME'"
[[ -f "$PROJECTS_DIR/$NAME.env" ]] && die "project '$NAME' already exists. Remove it first: autodeploy remove $NAME"

ask REPO_URL "Repository URL on GitLab or GitHub (SSH or HTTPS)"
[[ -n "$REPO_URL" ]] || die "repo URL is required"
# Convert https://host/group/repo(.git) to git@host:group/repo.git
if [[ "$REPO_URL" =~ ^https?://([^/]+)/(.+)$ ]]; then
  REPO_URL="git@${BASH_REMATCH[1]}:${BASH_REMATCH[2]%.git}.git"
  info "using SSH URL: $REPO_URL"
fi

# github for github.com (or a host with "github" in it), gitlab for everything else.
if [[ "$REPO_URL" =~ ^[^@]+@([^:/]+) && "${BASH_REMATCH[1]}" == *github* ]]; then
  detected_provider="github"
else
  detected_provider="gitlab"
fi
ask GIT_PROVIDER "Git provider: gitlab or github" "$detected_provider"
[[ "$GIT_PROVIDER" == "gitlab" || "$GIT_PROVIDER" == "github" ]] || die "GIT_PROVIDER must be gitlab or github"

ask BRANCH "Branch to deploy" "main"
echo "App types:"
echo "  node    build here and keep it running with pm2"
echo "  static  build here, files only (served by Nginx/Caddy)"
echo "  script  your own deploy script does everything (Docker Compose, migrations, backups…)"
ask APP_TYPE "App type" "node"
[[ "$APP_TYPE" == "node" || "$APP_TYPE" == "static" || "$APP_TYPE" == "script" ]] || die "APP_TYPE must be node, static or script"

DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-}"
DEPLOY_AS_ROOT="${DEPLOY_AS_ROOT:-}"
ROLLBACK_SCRIPT="${ROLLBACK_SCRIPT:-}"
if [[ "$APP_TYPE" == "script" ]]; then
  ask DEPLOY_SCRIPT "Absolute path of the deploy script on this server (e.g. /opt/myapp/deploy/auto-deploy.sh)"
  [[ "$DEPLOY_SCRIPT" =~ $SCRIPT_PATH_RE ]] || die "the script path must be absolute and use only letters, digits, . _ - /"
  ask DEPLOY_AS_ROOT "Run it as root through sudo? (yes/no)" "yes"
  [[ "$DEPLOY_AS_ROOT" == "yes" || "$DEPLOY_AS_ROOT" == "no" ]] || die "answer yes or no"
  ask ROLLBACK_SCRIPT "Rollback script for 'autodeploy rollback' ('none' if you don't have one)" "none"
  [[ "$ROLLBACK_SCRIPT" == "none" ]] && ROLLBACK_SCRIPT=""
  [[ -z "$ROLLBACK_SCRIPT" || "$ROLLBACK_SCRIPT" =~ $SCRIPT_PATH_RE ]] || die "the rollback script path must be absolute"
  INSTALL_CMD="none"
  BUILD_CMD="none"
  START_CMD="none"
  PORT=""
  ask HEALTHCHECK_URL "Healthcheck URL checked after the script succeeds ('none' to skip)" "none"
  [[ "$HEALTHCHECK_URL" == "none" ]] && HEALTHCHECK_URL=""
else
  ask INSTALL_CMD "Install command ('auto' detects npm/pnpm/yarn/bun)" "auto"
  ask BUILD_CMD "Build command ('none' to skip)" "npm run build"
fi

if [[ "$APP_TYPE" == "script" ]]; then
  :
elif [[ "$APP_TYPE" == "node" ]]; then
  ask START_CMD "Start command" "npm start"
  ask PORT "Port the app listens on" "3000"
  [[ "$PORT" =~ ^[0-9]{2,5}$ ]] || die "invalid port '$PORT'"
  for f in "$PROJECTS_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    if grep -qx "PORT='$PORT'" "$f"; then
      die "port $PORT is already used by $(basename "$f" .env)"
    fi
  done
  ask HEALTHCHECK_URL "Healthcheck URL ('none' to skip)" "http://127.0.0.1:$PORT"
  [[ "$HEALTHCHECK_URL" == "none" ]] && HEALTHCHECK_URL=""
else
  START_CMD="none"
  PORT=""
  HEALTHCHECK_URL=""
fi

ask NOTIFY_CHANNELS "Notifications for this project (empty = server default; e.g. 'telegram email whatsapp')" ""

DEPLOY_TOKEN="$(random_token)"

# Deploy key: read-only access to this one repository.
KEY="$KEYS_DIR/$NAME"
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N "" -C "autodeploy-$NAME@$(hostname)" -f "$KEY"
chmod 600 "$KEY"

ENV_FILE="$PROJECTS_DIR/$NAME.env"
umask 077
: > "$ENV_FILE"
write_env_var "$ENV_FILE" GIT_PROVIDER "$GIT_PROVIDER"
write_env_var "$ENV_FILE" REPO_URL "$REPO_URL"
write_env_var "$ENV_FILE" BRANCH "$BRANCH"
write_env_var "$ENV_FILE" APP_TYPE "$APP_TYPE"
if [[ "$APP_TYPE" == "script" ]]; then
  write_env_var "$ENV_FILE" DEPLOY_SCRIPT "$DEPLOY_SCRIPT"
  write_env_var "$ENV_FILE" DEPLOY_AS_ROOT "$DEPLOY_AS_ROOT"
  write_env_var "$ENV_FILE" ROLLBACK_SCRIPT "$ROLLBACK_SCRIPT"
else
  write_env_var "$ENV_FILE" INSTALL_CMD "$INSTALL_CMD"
  write_env_var "$ENV_FILE" BUILD_CMD "$BUILD_CMD"
  write_env_var "$ENV_FILE" START_CMD "$START_CMD"
  [[ -n "$PORT" ]] && write_env_var "$ENV_FILE" PORT "$PORT"
  write_env_var "$ENV_FILE" KEEP_RELEASES "5"
fi
write_env_var "$ENV_FILE" HEALTHCHECK_URL "$HEALTHCHECK_URL"
[[ -n "$NOTIFY_CHANNELS" ]] && write_env_var "$ENV_FILE" NOTIFY_CHANNELS "$NOTIFY_CHANNELS"
write_env_var "$ENV_FILE" DEPLOY_TOKEN "$DEPLOY_TOKEN"
umask 022

mkdir -p "$APPS_DIR/$NAME"
[[ "$APP_TYPE" == "script" ]] || mkdir -p "$APPS_DIR/$NAME/shared"

[[ -n "${AUTODEPLOY_RESULT_FILE:-}" ]] && printf '%s\n' "$NAME" > "$AUTODEPLOY_RESULT_FILE"

# "sudo autodeploy add" finishes the setup itself (API connect, sudo rule, first run).
if [[ "${AUTODEPLOY_DEFER_SETUP:-}" == "1" ]]; then
  info "Project '$NAME' is registered."
  exit 0
fi

print_key_step
wait_for_key_access
print_webhook_step
print_final_steps
echo
echo "Project '$NAME' is registered."

if [[ "$APP_TYPE" != "script" ]] && ask_yes_no "Run the first deploy now?" "y"; then
  "$SCRIPT_DIR/deploy.sh" "$NAME" --force
fi
