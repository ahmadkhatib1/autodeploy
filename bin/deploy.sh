#!/usr/bin/env bash
# Build and release one project.
# Usage: deploy.sh <project> [--force]
#   --force  deploy even if the commit is already live
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${AUTODEPLOY_LIB:-$SCRIPT_DIR/../lib}"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../lib/notify.sh
source "$LIB_DIR/notify.sh"

ensure_deploy_user "$@"

NAME="${1:-}"
FORCE="${2:-}"
valid_project_name "$NAME" || die "usage: deploy.sh <project> [--force]"

load_env_file "$CONFIG_DIR/notify.env" || true
load_env_file "$PROJECTS_DIR/$NAME.env" || die "project '$NAME' not found ($PROJECTS_DIR/$NAME.env)"

: "${REPO_URL:?REPO_URL missing in $NAME.env}"
BRANCH="${BRANCH:-main}"
INSTALL_CMD="${INSTALL_CMD:-auto}"
BUILD_CMD="${BUILD_CMD-npm run build}"
START_CMD="${START_CMD-npm start}"
PORT="${PORT:-3000}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
SHARED_PATHS="${SHARED_PATHS:-.env .env.local .env.production}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-60}"
PM2_NAME="${PM2_NAME:-$NAME}"

APP_DIR="$APPS_DIR/$NAME"
REPO_CACHE="$APP_DIR/repo.git"
RELEASES_DIR="$APP_DIR/releases"
SHARED_DIR="$APP_DIR/shared"
CURRENT="$APP_DIR/current"

mkdir -p "$RELEASES_DIR" "$SHARED_DIR" "$LOGS_DIR/$NAME" "$LOCKS_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOGS_DIR/$NAME/$STAMP.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# One deploy per project at a time; later pushes wait their turn.
exec 9>"$LOCKS_DIR/$NAME.lock"
info "waiting for lock…"
flock -w 1800 9 || die "another deploy of $NAME has been running for 30 minutes"

export GIT_SSH_COMMAND="ssh -i $KEYS_DIR/$NAME -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$CONFIG_DIR/known_hosts"

STEP="start"
STARTED_AT="$(date +%s)"
RELEASE=""
COMMIT=""
COMMIT_SHORT=""
COMMIT_MSG=""
COMMIT_AUTHOR=""
SWITCHED=0
PREVIOUS=""

elapsed() { echo "$(( $(date +%s) - STARTED_AT ))s"; }

commit_lines() {
  printf 'الفرع: %s\nالـCommit: %s — %s\nالكاتب: %s' "$BRANCH" "${COMMIT_SHORT:-?}" "${COMMIT_MSG:-?}" "${COMMIT_AUTHOR:-?}"
}

on_error() {
  local code=$?
  # set -E makes subshells inherit this trap; only the main shell reports.
  if (( BASH_SUBSHELL > 0 )); then exit "$code"; fi
  trap - ERR
  set +e
  echo "!! failed at step: $STEP (exit $code)"
  local tail_log state
  if (( SWITCHED )) && [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then
    rollback_to_previous
    state="تم الرجوع تلقائياً إلى النسخة السابقة."
  elif (( SWITCHED )); then
    state="هذا أول نشر ولا توجد نسخة سابقة للرجوع إليها، لذلك قد يكون التطبيق متوقفاً."
  else
    state="الموقع ما زال يعمل على النسخة السابقة، لم يتغير شيء."
  fi
  # A failed release is never kept, so a later rollback can't pick it.
  if [[ -n "$RELEASE" && -d "$RELEASE" && "$(readlink -f "$CURRENT")" != "$RELEASE" ]]; then
    rm -rf "$RELEASE"
  fi
  tail_log="$(tail -n 25 "$LOG_FILE" 2>/dev/null)"
  notify "❌ فشل نشر $NAME" "$(commit_lines)
الخطوة: $STEP
المدة: $(elapsed)
$state

آخر سطور السجل:
$tail_log

السجل الكامل على السيرفر: $LOG_FILE"
  exit "$code"
}
trap on_error ERR

detect_install_cmd() {
  local dir="$1"
  if [[ -f "$dir/pnpm-lock.yaml" ]]; then echo "corepack pnpm install --frozen-lockfile"
  elif [[ -f "$dir/yarn.lock" ]]; then echo "corepack yarn install"
  elif [[ -f "$dir/bun.lockb" || -f "$dir/bun.lock" ]]; then echo "bun install --frozen-lockfile"
  elif [[ -f "$dir/package-lock.json" || -f "$dir/npm-shrinkwrap.json" ]]; then echo "npm ci"
  elif [[ -f "$dir/package.json" ]]; then echo "npm install"
  else echo ""
  fi
}

switch_current_to() {
  local target="$1"
  ln -sfn "$target" "$APP_DIR/current.tmp"
  mv -Tf "$APP_DIR/current.tmp" "$CURRENT"
}

restart_app() {
  [[ -n "$START_CMD" ]] || return 0
  local eco="$APP_DIR/ecosystem.config.json"
  jq -n \
    --arg name "$PM2_NAME" --arg cwd "$CURRENT" --arg cmd "$START_CMD" --arg port "$PORT" \
    --arg out "$LOGS_DIR/$NAME/app.out.log" --arg err "$LOGS_DIR/$NAME/app.err.log" \
    '{apps:[{name:$name, cwd:$cwd, script:"bash", args:["-c",$cmd], interpreter:"none",
             env:{PORT:$port, NODE_ENV:"production"},
             out_file:$out, error_file:$err, merge_logs:true,
             autorestart:true, max_restarts:10, restart_delay:2000}]}' > "$eco"
  pm2 startOrRestart "$eco" --update-env
  pm2 save >/dev/null 2>&1 || true
}

rollback_to_previous() {
  if [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then
    echo "-> rolling back to $(basename "$PREVIOUS")"
    switch_current_to "$PREVIOUS"
    restart_app || echo "!! restart after rollback failed"
  else
    echo "!! no previous release to roll back to"
  fi
}

healthcheck() {
  [[ -n "$HEALTHCHECK_URL" ]] || return 0
  local deadline=$(( $(date +%s) + HEALTHCHECK_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    if curl -fsS -o /dev/null --max-time 5 "$HEALTHCHECK_URL"; then
      echo "-> healthcheck OK ($HEALTHCHECK_URL)"
      return 0
    fi
    sleep 3
  done
  echo "!! healthcheck failed: $HEALTHCHECK_URL did not answer within ${HEALTHCHECK_TIMEOUT}s"
  return 1
}

# ---------------------------------------------------------------- fetch
STEP="جلب الكود (git fetch)"
info "$STEP"
if [[ ! -d "$REPO_CACHE" ]]; then
  git clone --bare --quiet "$REPO_URL" "$REPO_CACHE"
fi
git -C "$REPO_CACHE" remote set-url origin "$REPO_URL"
git -C "$REPO_CACHE" fetch --quiet --prune origin "+refs/heads/$BRANCH:refs/heads/$BRANCH"
COMMIT="$(git -C "$REPO_CACHE" rev-parse "refs/heads/$BRANCH")"
COMMIT_SHORT="${COMMIT:0:8}"
COMMIT_MSG="$(git -C "$REPO_CACHE" log -1 --format=%s "$COMMIT")"
COMMIT_AUTHOR="$(git -C "$REPO_CACHE" log -1 --format=%an "$COMMIT")"
info "commit $COMMIT_SHORT: $COMMIT_MSG"

if [[ -L "$CURRENT" ]]; then
  PREVIOUS="$(readlink -f "$CURRENT")"
fi
if [[ "$FORCE" != "--force" && -n "$PREVIOUS" && -f "$PREVIOUS/.autodeploy-commit" ]] \
   && [[ "$(cat "$PREVIOUS/.autodeploy-commit")" == "$COMMIT" ]]; then
  info "commit $COMMIT_SHORT is already live, nothing to do"
  exit 0
fi

# ---------------------------------------------------------------- prepare
STEP="تجهيز النسخة"
RELEASE="$RELEASES_DIR/$STAMP-$COMMIT_SHORT"
info "$STEP -> $RELEASE"
mkdir -p "$RELEASE"
git -C "$REPO_CACHE" archive "$COMMIT" | tar -x -C "$RELEASE"
echo "$COMMIT" > "$RELEASE/.autodeploy-commit"
for p in $SHARED_PATHS; do
  if [[ -e "$SHARED_DIR/$p" ]]; then
    rm -rf "${RELEASE:?}/$p"
    ln -s "$SHARED_DIR/$p" "$RELEASE/$p"
    echo "-> linked shared $p"
  fi
done

# ---------------------------------------------------------------- install
if [[ "$INSTALL_CMD" == "auto" ]]; then
  INSTALL_CMD="$(detect_install_cmd "$RELEASE")"
fi
if [[ -n "$INSTALL_CMD" && "$INSTALL_CMD" != "none" ]]; then
  STEP="تثبيت الحزم ($INSTALL_CMD)"
  info "$STEP"
  (cd "$RELEASE" && bash -c "$INSTALL_CMD")
fi

# ---------------------------------------------------------------- build
if [[ -n "$BUILD_CMD" && "$BUILD_CMD" != "none" ]]; then
  STEP="البناء ($BUILD_CMD)"
  info "$STEP"
  (cd "$RELEASE" && PORT="$PORT" bash -c "$BUILD_CMD")
fi

# ---------------------------------------------------------------- release
STEP="تبديل النسخة"
info "$STEP"
switch_current_to "$RELEASE"
SWITCHED=1

if [[ -n "$START_CMD" && "$START_CMD" != "none" ]]; then
  STEP="تشغيل التطبيق (pm2)"
  info "$STEP"
  restart_app
else
  START_CMD=""
fi

STEP="فحص الموقع"
healthcheck

# ---------------------------------------------------------------- cleanup
STEP="تنظيف النسخ القديمة"
mapfile -t old < <(ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null | tail -n +"$(( KEEP_RELEASES + 1 ))")
for dir in "${old[@]}"; do
  dir="${dir%/}"
  [[ "$(readlink -f "$dir")" == "$(readlink -f "$CURRENT")" ]] && continue
  rm -rf "$dir"
done
find "$LOGS_DIR/$NAME" -name '*.log' ! -name 'app.*' -mtime +30 -delete 2>/dev/null || true

trap - ERR
info "done in $(elapsed)"
notify "✅ تم نشر $NAME" "$(commit_lines)
المدة: $(elapsed)"
