#!/usr/bin/env bash
# Switch a project back to an earlier release.
# Usage: autodeploy rollback <project> [release-folder-name]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${AUTODEPLOY_LIB:-$SCRIPT_DIR/../lib}"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../lib/notify.sh
source "$LIB_DIR/notify.sh"

ensure_deploy_user "$@"

NAME="${1:-}"
TARGET_NAME="${2:-}"
valid_project_name "$NAME" || die "usage: rollback.sh <project> [release]"
load_env_file "$CONFIG_DIR/notify.env" || true
load_env_file "$PROJECTS_DIR/$NAME.env" || die "project '$NAME' not found"

if [[ "${APP_TYPE:-node}" == "script" ]]; then
  if [[ -z "${ROLLBACK_SCRIPT:-}" ]]; then
    die "'$NAME' is deployed by its own script ($DEPLOY_SCRIPT), so autodeploy has no releases to switch.
Roll back with your script, or 'git revert' and push. To make this command work, set ROLLBACK_SCRIPT in $PROJECTS_DIR/$NAME.env"
  fi
  [[ "$ROLLBACK_SCRIPT" =~ $SCRIPT_PATH_RE ]] || die "ROLLBACK_SCRIPT must be an absolute path"
  build_script_cmd "$ROLLBACK_SCRIPT"
  mkdir -p "$LOGS_DIR/$NAME" "$LOCKS_DIR"
  exec 9>"$LOCKS_DIR/$NAME.lock"
  flock -w 600 9 || die "a deploy of $NAME is running"
  LOG_FILE="$LOGS_DIR/$NAME/$(date +%Y%m%d-%H%M%S)-rollback.log"
  info "running: ${SCRIPT_RUN[*]}"
  set +e
  AUTODEPLOY_PROJECT="$NAME" "${SCRIPT_RUN[@]}" 2>&1 | tee "$LOG_FILE"
  code=${PIPESTATUS[0]}
  set -e
  if (( code == 0 )); then
    notify "↩️ رجوع يدوي في $NAME" "نفّذ سكربت الرجوع بنجاح."
  else
    notify "❌ فشل الرجوع في $NAME" "سكربت الرجوع انتهى بخطأ (exit $code).

آخر سطور السجل:
$(tail -n 25 "$LOG_FILE")"
  fi
  exit "$code"
fi

APP_DIR="$APPS_DIR/$NAME"
CURRENT="$APP_DIR/current"
START_CMD="${START_CMD-npm start}"
[[ "$START_CMD" == "none" ]] && START_CMD=""
PORT="${PORT:-3000}"
PM2_NAME="${PM2_NAME:-$NAME}"

exec 9>"$LOCKS_DIR/$NAME.lock"
flock -w 600 9 || die "a deploy of $NAME is running"

live="$(readlink -f "$CURRENT" 2>/dev/null || true)"
mapfile -t releases < <(ls -1d "$APP_DIR"/releases/*/ 2>/dev/null | sed 's:/$::' | sort -r)
(( ${#releases[@]} )) || die "no releases found for $NAME"

if [[ -n "$TARGET_NAME" ]]; then
  [[ "$TARGET_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release name"
  target="$APP_DIR/releases/$TARGET_NAME"
  [[ -d "$target" ]] || die "release '$TARGET_NAME' not found"
else
  target=""
  for i in "${!releases[@]}"; do
    if [[ "${releases[$i]}" == "$live" ]]; then
      target="${releases[$((i + 1))]:-}"
      break
    fi
  done
  [[ -n "$target" ]] || die "no older release than the live one. Available: $(printf '%s ' "${releases[@]##*/}")"
fi

info "switching $NAME to $(basename "$target")"
ln -sfn "$target" "$APP_DIR/current.tmp"
mv -Tf "$APP_DIR/current.tmp" "$CURRENT"

if [[ -n "$START_CMD" ]]; then
  pm2 startOrRestart "$APP_DIR/ecosystem.config.json" --update-env
  pm2 save >/dev/null 2>&1 || true
fi

commit="$(cat "$target/.autodeploy-commit" 2>/dev/null || echo '?')"
notify "↩️ رجوع يدوي في $NAME" "النسخة الحالية الآن: $(basename "$target")
الـCommit: ${commit:0:8}"
info "done"
