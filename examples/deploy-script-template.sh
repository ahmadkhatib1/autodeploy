#!/usr/bin/env bash
# Template for an APP_TYPE=script project (Docker Compose example).
# Copy it into your repository, adapt the marked parts, and register it with:
#   sudo autodeploy add      (App type: script)
#
# Contract with autodeploy:
#   - called with no arguments to deploy, or with --dry-run to only print the plan
#   - exit 0 = deployed; any other code = failed (output is sent in the notification)
#   - this script pulls the code, builds, migrates, restarts and rolls back by itself
#   - when run through sudo, no environment variables reach it; keep settings here
#
# The whole body is inside { … } so bash reads it completely before running:
# "git merge" below can replace this very file while it runs.
set -Eeuo pipefail
{
APP_DIR="/opt/myapp"                 # <- the server's checkout of the repository
BRANCH="main"                        # <- must match the project's branch in autodeploy
HEALTH_URL="https://example.com/health"   # <- checked at the end
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

say() { printf '\n==> %s\n' "$*"; }
cd "$APP_DIR"

# Refuse to deploy over local edits or a diverged history.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "uncommitted changes in $APP_DIR"; exit 1; }
git fetch --quiet origin "$BRANCH"
OLD="$(git rev-parse HEAD)"
NEW="$(git rev-parse "origin/$BRANCH")"
if [[ "$OLD" == "$NEW" ]]; then say "nothing new (${NEW:0:8})"; exit 0; fi
git merge-base --is-ancestor "$OLD" "$NEW" || { echo "local branch diverged from origin/$BRANCH"; exit 1; }

say "plan ${OLD:0:8} -> ${NEW:0:8}"
git log --oneline "$OLD..$NEW" | head -15
if (( DRY_RUN )); then say "dry run: nothing changed"; exit 0; fi

rollback() {
  trap - ERR; set +e
  echo "!! rolling code back to ${OLD:0:8}"
  git reset --hard "$OLD" >/dev/null
  docker compose up -d --build              # <- rebuild/restart the old version
}
trap 'code=$?; rollback; exit $code' ERR

# --- your steps --------------------------------------------------------------
# say "backup";  ./deploy/backup.sh
say "pull";      git merge --ff-only "origin/$BRANCH" >/dev/null
say "build";     docker compose build
# say "migrate"; docker compose run --rm -T app npm run migrate
say "restart";   docker compose up -d
# ------------------------------------------------------------------------------

say "healthcheck"
for _ in $(seq 1 30); do
  curl -fsS -m 5 -o /dev/null "$HEALTH_URL" && { trap - ERR; say "deployed ${NEW:0:8}"; exit 0; }
  sleep 3
done
echo "!! $HEALTH_URL did not answer"
false
}
