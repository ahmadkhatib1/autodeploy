# shellcheck shell=bash
# Setup instructions and access checks shared by add-project.sh and connect.sh.
# Expects the project's settings to be loaded: NAME, REPO_URL, BRANCH,
# GIT_PROVIDER, DEPLOY_TOKEN, APP_TYPE, DEPLOY_AS_ROOT, and WEBHOOK_BASE.

provider_label() { [[ "${GIT_PROVIDER:-gitlab}" == "github" ]] && echo "GitHub" || echo "GitLab"; }

deploy_key_title() { echo "autodeploy-$(hostname)-$NAME"; }

# Full webhook URL for this project.
webhook_url() {
  local base="${WEBHOOK_BASE:-https://YOUR-N8N-HOST/webhook/deploy}"
  if [[ "${GIT_PROVIDER:-gitlab}" == "github" ]]; then
    echo "$base?project=$NAME&token=$DEPLOY_TOKEN"
  else
    echo "$base?project=$NAME"
  fi
}

git_ssh_command() {
  echo "ssh -i $KEYS_DIR/$NAME -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$CONFIG_DIR/known_hosts"
}

# check_key_access: can the deploy key read the branch? (runs as the deploy user)
check_key_access() {
  run_as_deploy env GIT_SSH_COMMAND="$(git_ssh_command)" \
    git ls-remote --heads "$REPO_URL" "$BRANCH" 2>/dev/null | grep -q .
}

print_key_step() {
  local where
  if [[ "${GIT_PROVIDER:-gitlab}" == "github" ]]; then
    where="Repository > Settings > Deploy keys > Add deploy key  (leave 'Allow write access' OFF)"
  else
    where="Project > Settings > Repository > Deploy keys > Add new key  (no write access)"
  fi
  cat <<EOF

------------------------------------------------------------------
STEP 1 — Add this Deploy Key in $(provider_label) (read-only):
  $where
  Title: $(deploy_key_title)
  Key:

$(cat "$KEYS_DIR/$NAME.pub")

------------------------------------------------------------------
EOF
}

# Interactive: wait until the user has added the key and it works.
wait_for_key_access() {
  [[ "${AUTODEPLOY_NONINTERACTIVE:-}" == "1" ]] && return 0
  local attempt
  for attempt in 1 2 3; do
    read -r -p "Press Enter after you add the key (attempt $attempt/3)… " _
    if check_key_access; then
      info "$(provider_label) access OK, branch '$BRANCH' found"
      return 0
    fi
    warn "could not read branch '$BRANCH' from $REPO_URL yet"
  done
  warn "continuing anyway; deploys will fail until the key works"
}

print_webhook_step() {
  if [[ "${GIT_PROVIDER:-gitlab}" == "github" ]]; then
    cat <<EOF

------------------------------------------------------------------
STEP 2 — Add the webhook in GitHub:
  Repository > Settings > Webhooks > Add webhook
  Payload URL:   $(webhook_url)
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
  URL:           $(webhook_url)
  Secret token:  $DEPLOY_TOKEN
  Trigger:       Push events  (branch filter: $BRANCH)
  SSL verification: on (if n8n uses https)
EOF
  fi
}

print_final_steps() {
  if [[ "${APP_TYPE:-node}" == "script" ]]; then
    if [[ "${DEPLOY_AS_ROOT:-no}" == "yes" ]]; then
      cat <<EOF

STEP 3 — Allow the deploy user to run ONLY this script as root
  (done for you when you run 'sudo autodeploy add'):
    sudo autodeploy allow-sudo $NAME
EOF
    fi
    cat <<EOF

STEP 4 — Dry run (your script receives --dry-run and should change nothing):
    autodeploy deploy $NAME --dry-run

Then push to '$BRANCH'. Your script contract:
  - exit 0 = deployed, anything else = failed (its output goes in the notification)
  - it pulls the code, builds, migrates and rolls back by itself
------------------------------------------------------------------
EOF
  else
    cat <<EOF

STEP 3 — Put the app's secrets (if any) here, they are linked into
every release automatically:
  $APPS_DIR/$NAME/shared/.env
------------------------------------------------------------------
EOF
  fi
}
