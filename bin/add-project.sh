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
ask APP_TYPE "App type: node (runs with pm2) or static (files only)" "node"
[[ "$APP_TYPE" == "node" || "$APP_TYPE" == "static" ]] || die "APP_TYPE must be node or static"
ask INSTALL_CMD "Install command ('auto' detects npm/pnpm/yarn/bun)" "auto"
ask BUILD_CMD "Build command ('none' to skip)" "npm run build"

if [[ "$APP_TYPE" == "node" ]]; then
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
write_env_var "$ENV_FILE" INSTALL_CMD "$INSTALL_CMD"
write_env_var "$ENV_FILE" BUILD_CMD "$BUILD_CMD"
write_env_var "$ENV_FILE" START_CMD "$START_CMD"
[[ -n "$PORT" ]] && write_env_var "$ENV_FILE" PORT "$PORT"
write_env_var "$ENV_FILE" HEALTHCHECK_URL "$HEALTHCHECK_URL"
[[ -n "$NOTIFY_CHANNELS" ]] && write_env_var "$ENV_FILE" NOTIFY_CHANNELS "$NOTIFY_CHANNELS"
write_env_var "$ENV_FILE" KEEP_RELEASES "5"
write_env_var "$ENV_FILE" DEPLOY_TOKEN "$DEPLOY_TOKEN"
umask 022

mkdir -p "$APPS_DIR/$NAME/shared"

if [[ "$GIT_PROVIDER" == "github" ]]; then
  PROVIDER_LABEL="GitHub"
  KEY_WHERE="Repository > Settings > Deploy keys > Add deploy key  (leave 'Allow write access' OFF)"
else
  PROVIDER_LABEL="GitLab"
  KEY_WHERE="Project > Settings > Repository > Deploy keys > Add new key  (no write access)"
fi

cat <<EOF

------------------------------------------------------------------
STEP 1 — Add this Deploy Key in $PROVIDER_LABEL (read-only):
  $KEY_WHERE
  Title: autodeploy-$(hostname)
  Key:

$(cat "$KEY.pub")

------------------------------------------------------------------
EOF

if [[ "${AUTODEPLOY_NONINTERACTIVE:-}" != "1" ]]; then
  for attempt in 1 2 3; do
    read -r -p "Press Enter after you add the key (attempt $attempt/3)… " _
    if GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$CONFIG_DIR/known_hosts" \
       git ls-remote --heads "$REPO_URL" "$BRANCH" | grep -q .; then
      info "$PROVIDER_LABEL access OK, branch '$BRANCH' found"
      break
    fi
    warn "could not read branch '$BRANCH' from $REPO_URL yet"
    [[ $attempt == 3 ]] && warn "continuing anyway; the first deploy will fail until the key works"
  done
fi

BASE="${WEBHOOK_BASE:-https://YOUR-N8N-HOST/webhook/deploy}"

if [[ "$GIT_PROVIDER" == "github" ]]; then
  # GitHub has no plain secret header, so the token travels in the URL (use HTTPS).
  cat <<EOF

------------------------------------------------------------------
STEP 2 — Add the webhook in GitHub:
  Repository > Settings > Webhooks > Add webhook
  Payload URL:   $BASE?project=$NAME&token=$DEPLOY_TOKEN
  Content type:  application/json
  Secret:        (leave empty)
  SSL verification: Enable (needs n8n on https)
  Which events:  Just the push event
EOF
else
  cat <<EOF

------------------------------------------------------------------
STEP 2 — Add the webhook in GitLab:
  Project > Settings > Webhooks > Add new webhook
  URL:           $BASE?project=$NAME
  Secret token:  $DEPLOY_TOKEN
  Trigger:       Push events  (branch filter: $BRANCH)
  SSL verification: on (if n8n uses https)
EOF
fi

cat <<EOF

STEP 3 — Put the app's secrets (if any) here, they are linked into
every release automatically:
  $APPS_DIR/$NAME/shared/.env
------------------------------------------------------------------

Project '$NAME' is registered.
EOF

if ask_yes_no "Run the first deploy now?" "y"; then
  "$SCRIPT_DIR/deploy.sh" "$NAME" --force
fi
