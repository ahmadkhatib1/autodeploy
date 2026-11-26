#!/usr/bin/env bash
# For APP_TYPE=script projects with DEPLOY_AS_ROOT=yes: let the deploy user run
# exactly that project's script(s) as root, and nothing else.
# Usage (as root): autodeploy allow-sudo <project>
#
# Refuses scripts that the deploy user (or anyone but root) could modify,
# because sudo would then hand out root to whoever can edit them.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${AUTODEPLOY_LIB:-$SCRIPT_DIR/../lib}"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"

[[ $EUID -eq 0 ]] || die "run as root: sudo autodeploy allow-sudo <project>"
NAME="${1:-}"
valid_project_name "$NAME" || die "usage: autodeploy allow-sudo <project>"
load_env_file "$PROJECTS_DIR/$NAME.env" || die "project '$NAME' not found"
[[ "${APP_TYPE:-}" == "script" ]] || die "'$NAME' is not a script project (APP_TYPE=${APP_TYPE:-node})"
[[ "${DEPLOY_AS_ROOT:-no}" == "yes" ]] || die "'$NAME' has DEPLOY_AS_ROOT=no; sudo is not needed"
id "$AUTODEPLOY_USER" >/dev/null 2>&1 || die "user '$AUTODEPLOY_USER' does not exist"
command -v visudo >/dev/null 2>&1 || die "visudo not found (apt-get install sudo)"

# check_secure <path>: root-owned regular file, writable only by root, and every
# parent directory root-owned and not writable by group/others.
check_secure() {
  local path="$1" mode owner dir
  [[ "$path" =~ $SCRIPT_PATH_RE ]] || die "$path: must be an absolute path using letters, digits, . _ - /"
  [[ ! -L "$path" ]] || die "$path is a symlink; point the project to the real file"
  [[ -f "$path" ]] || die "$path does not exist (pull the repository on the server first)"
  owner="$(stat -c %u "$path")"
  mode="$(stat -c %a "$path")"
  (( owner == 0 )) || die "$path must be owned by root:   sudo chown root:root $path"
  (( (8#$mode & 8#022) == 0 )) || die "$path is writable by group/others:   sudo chmod 750 $path"
  [[ -x "$path" ]] || die "$path is not executable:   sudo chmod 750 $path"
  dir="$(dirname "$path")"
  while :; do
    owner="$(stat -c %u "$dir")"
    mode="$(stat -c %a "$dir")"
    (( owner == 0 )) || die "folder $dir is not owned by root, so its owner could swap the script. Fix: sudo chown root:root $dir"
    # A sticky folder (like /tmp) is fine: others can't rename or delete root's files in it.
    if (( (8#$mode & 8#1000) == 0 && (8#$mode & 8#022) != 0 )); then
      die "folder $dir is writable by group/others, so the script could be swapped. Fix: sudo chmod go-w $dir"
    fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
}

check_secure "$DEPLOY_SCRIPT"
rules="$AUTODEPLOY_USER ALL=(root) NOPASSWD: $DEPLOY_SCRIPT \"\", $DEPLOY_SCRIPT --dry-run"
if [[ -n "${ROLLBACK_SCRIPT:-}" ]]; then
  check_secure "$ROLLBACK_SCRIPT"
  rules+=$'\n'"$AUTODEPLOY_USER ALL=(root) NOPASSWD: $ROLLBACK_SCRIPT \"\""
fi

TARGET="$SUDOERS_DIR/autodeploy-$NAME"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '# Managed by autodeploy for project %s. Remove with: autodeploy remove %s\n%s\n' "$NAME" "$NAME" "$rules" > "$tmp"
visudo -cf "$tmp" >/dev/null || die "generated sudoers rule did not validate"
[[ -d "$SUDOERS_DIR" ]] || install -d -m 750 "$SUDOERS_DIR"
install -m 440 -o root -g root "$tmp" "$TARGET"

info "sudo rule written to $TARGET:"
sed 's/^/    /' "$TARGET"
echo
echo "Only these exact commands are allowed (no other arguments, no environment variables)."
