#!/usr/bin/env bash
# Finish setting up a registered project (run as root):
#   - with a saved API token for its Git host: add the deploy key and webhook
#     automatically (safe to re-run; updates instead of duplicating)
#   - without one: print the manual steps
#   - check that the deploy key can read the branch
#   - script projects running as root: create the sudo rule
#   - offer a dry run (script) or the first deploy (node/static)
# Usage: sudo autodeploy connect <project> [--no-run]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${AUTODEPLOY_LIB:-$SCRIPT_DIR/../lib}"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../lib/steps.sh
source "$LIB_DIR/steps.sh"
# shellcheck source=../lib/remote.sh
source "$LIB_DIR/remote.sh"

[[ $EUID -eq 0 ]] || die "run as root: sudo autodeploy connect <project>"
NAME="${1:-}"
NO_RUN="${2:-}"
valid_project_name "$NAME" || die "usage: autodeploy connect <project> [--no-run]"
load_env_file "$CONFIG_DIR/server.env" || true
load_env_file "$PROJECTS_DIR/$NAME.env" || die "project '$NAME' not found"
GIT_PROVIDER="${GIT_PROVIDER:-gitlab}"
APP_TYPE="${APP_TYPE:-node}"
BRANCH="${BRANCH:-main}"

auto=0
set +e
remote_setup
rc=$?
set -e
case $rc in
  0) auto=1 ;;
  2)
    parse_repo_url "$REPO_URL" || true
    info "No API token saved for ${REPO_HOST:-this host}; showing the manual steps."
    echo "    (To automate this next time: sudo autodeploy token set ${REPO_HOST:-<host>})"
    print_key_step
    wait_for_key_access
    print_webhook_step
    ;;
  *)
    warn "automatic setup failed (see above). Fix the token or permissions and re-run:"
    warn "    sudo autodeploy connect $NAME"
    warn "or add the key and webhook by hand:"
    print_key_step
    print_webhook_step
    exit 1
    ;;
esac

if (( auto )); then
  info "Checking that the deploy key can read '$BRANCH'"
  ok=0
  for ((i = 0; i < ${CONNECT_RETRIES:-5}; i++)); do
    if check_key_access; then ok=1; break; fi
    (( i + 1 < ${CONNECT_RETRIES:-5} )) && sleep 2
  done
  if (( ok )); then
    echo "    access OK"
  else
    warn "the deploy key cannot read $REPO_URL ($BRANCH) yet. Check the branch name and try: autodeploy deploy $NAME"
  fi
fi

if [[ "$APP_TYPE" == "script" && "${DEPLOY_AS_ROOT:-no}" == "yes" ]]; then
  info "Setting up sudo for '$NAME'"
  if ! "$SCRIPT_DIR/allow-sudo.sh" "$NAME"; then
    warn "sudo is not set up yet. Fix the problem above, then run: sudo autodeploy allow-sudo $NAME"
    exit 1
  fi
fi

if [[ "$APP_TYPE" == "script" ]]; then
  cat <<EOF

Your script contract:
  - called with no arguments to deploy, or --dry-run to only show the plan
  - exit 0 = deployed, anything else = failed (its output goes in the notification)
  - it pulls the code, builds, migrates and rolls back by itself
EOF
else
  echo
  echo "App secrets (if any) go in $APPS_DIR/$NAME/shared/.env"
fi

[[ "$NO_RUN" == "--no-run" ]] && exit 0

if [[ "$APP_TYPE" == "script" ]]; then
  if ask_yes_no "Run a dry run of the script now?" "y"; then
    run_as_deploy "$SCRIPT_DIR/deploy.sh" "$NAME" --dry-run || true
  fi
else
  if ask_yes_no "Run the first deploy now?" "y"; then
    run_as_deploy "$SCRIPT_DIR/deploy.sh" "$NAME" --force || true
  fi
fi

echo
info "'$NAME' is ready. Push to '$BRANCH' to deploy."
