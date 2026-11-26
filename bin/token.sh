#!/usr/bin/env bash
# Manage the GitLab / GitHub API tokens that let `autodeploy add` and
# `autodeploy connect` create deploy keys and webhooks for you (root only).
#
#   sudo autodeploy token set [host] [--provider gitlab|github]   (default host: gitlab.com)
#   sudo autodeploy token list
#   sudo autodeploy token test [host]
#   sudo autodeploy token remove <host>
#
# The token is read from the terminal without echo (or from stdin when piped)
# and stored in /etc/autodeploy/tokens/<host>.token, mode 600, owned by root.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${AUTODEPLOY_LIB:-$SCRIPT_DIR/../lib}"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../lib/remote.sh
source "$LIB_DIR/remote.sh"

[[ $EUID -eq 0 ]] || die "run as root: sudo autodeploy token …"

cmd="${1:-}"; shift || true
host="gitlab.com"
provider=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) provider="${2:-}"; shift 2 ;;
    -*) die "unknown option '$1'" ;;
    *) host="$1"; shift ;;
  esac
done
[[ "$host" =~ $HOST_RE ]] || die "invalid host '$host'"
provider="${provider:-$(provider_for_host "$host")}"
[[ "$provider" == "gitlab" || "$provider" == "github" ]] || die "provider must be gitlab or github"

case "$cmd" in
  set)
    if [[ "$provider" == "github" ]]; then
      cat <<'EOF'
GitHub token needed: a fine-grained personal access token limited to the
repositories you deploy, with these repository permissions:
  Administration: Read and write   (deploy keys)
  Webhooks:       Read and write
(Or a classic token with the 'repo' and 'admin:repo_hook' scopes.)
EOF
    else
      cat <<'EOF'
GitLab token needed: a personal, group or project access token with the 'api'
scope and the Maintainer role on the projects you deploy.
(GitLab > Preferences > Access tokens, or Group/Project > Settings > Access tokens)
EOF
    fi
    if [[ -t 0 ]]; then
      read -r -s -p "Paste the token for $host (input hidden): " tok; echo
    else
      read -r tok || true
    fi
    tok="$(tr -d '\r\n ' <<<"$tok")"
    [[ -n "$tok" ]] || die "empty token"
    who="$(token_whoami "$provider" "$host" "$tok")" || die "the token was not accepted by $host; nothing saved"
    install -d -m 700 -o root -g root "$TOKENS_DIR"
    tmp="$(mktemp "$TOKENS_DIR/.tmp.XXXXXX")"
    printf '%s\n' "$tok" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$(token_file "$host")"
    info "token for $host saved (account: $who, $provider)"
    ;;
  list)
    shopt -s nullglob
    files=("$TOKENS_DIR"/*.token)
    (( ${#files[@]} )) || { echo "no tokens saved"; exit 0; }
    for f in "${files[@]}"; do basename "$f" .token; done
    ;;
  test)
    have_token "$host" || die "no token saved for $host"
    who="$(token_whoami "$provider" "$host" "$(read_token "$host")")" || exit 1
    info "token for $host works (account: $who)"
    ;;
  remove)
    have_token "$host" || die "no token saved for $host"
    rm -f "$(token_file "$host")"
    info "token for $host deleted from this server. Revoke it on $host too."
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
