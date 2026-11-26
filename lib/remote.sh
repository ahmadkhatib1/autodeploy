# shellcheck shell=bash
# GitLab / GitHub API: create or remove a project's deploy key and webhook.
# Tokens are root-only files: $TOKENS_DIR/<host>.token (see `autodeploy token`).
# Expects project settings loaded (NAME, REPO_URL, BRANCH, GIT_PROVIDER,
# DEPLOY_TOKEN) plus WEBHOOK_BASE, and lib/steps.sh sourced.

TOKENS_DIR="${AUTODEPLOY_TOKENS_DIR:-/etc/autodeploy/tokens}"
HOST_RE='^[A-Za-z0-9.-]+(:[0-9]+)?$'

# Split REPO_URL (git@host:group/repo.git or ssh://git@host[:port]/group/repo.git)
# into REPO_HOST and REPO_PATH.
parse_repo_url() {
  local url="$1"
  if [[ "$url" =~ ^ssh://[^@]+@([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
    REPO_HOST="${BASH_REMATCH[1]}"; REPO_PATH="${BASH_REMATCH[3]}"
  elif [[ "$url" =~ ^[^@]+@([^:/]+):(.+)$ ]]; then
    REPO_HOST="${BASH_REMATCH[1]}"; REPO_PATH="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  REPO_PATH="${REPO_PATH%.git}"
  REPO_PATH="${REPO_PATH%/}"
}

token_file() { echo "$TOKENS_DIR/$1.token"; }
have_token() { [[ -r "$(token_file "$1")" && -s "$(token_file "$1")" ]]; }
read_token() { tr -d '\r\n ' < "$(token_file "$1")"; }

provider_for_host() { [[ "$1" == *github* ]] && echo github || echo gitlab; }

api_base() {
  local provider="$1" host="$2"
  if [[ "$provider" == "github" ]]; then
    [[ "$host" == "github.com" ]] && echo "https://api.github.com" || echo "https://$host/api/v3"
  else
    echo "https://$host/api/v4"
  fi
}

# _api PROVIDER TOKEN METHOD URL [JSON]  -> sets API_STATUS and API_BODY
_api() {
  local provider="$1" token="$2" method="$3" url="$4" data="${5:-}" out auth
  local -a args=(-sS -m 30 -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
  if [[ "$provider" == "github" ]]; then
    args+=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
    auth="Authorization: Bearer $token"
  else
    auth="PRIVATE-TOKEN: $token"
  fi
  [[ -n "$data" ]] && args+=(--data-binary "$data")
  # The token goes through a curl config file, never the command line.
  out="$(curl "${args[@]}" -K <(printf 'header = %s\n' "$(_cfg_quote "$auth")") "$url" 2>&1)" || true
  API_STATUS="${out##*$'\n'}"
  API_BODY="${out%$'\n'*}"
  [[ "$API_STATUS" =~ ^[0-9]{3}$ ]] || { API_BODY="$out"; API_STATUS="000"; }
}

_cfg_quote() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "$v"; }

# Short, secret-free description of an API error.
_api_error() {
  local msg
  msg="$(jq -r '(.message // .error // .errors // empty) | tostring' <<<"$API_BODY" 2>/dev/null || true)"
  [[ -n "$msg" ]] || msg="$(head -c 200 <<<"$API_BODY")"
  msg="$(sed -E 's/token=[A-Za-z0-9]+/token=<hidden>/g' <<<"$msg")"
  echo "HTTP $API_STATUS: $msg"
}

_ok() { [[ "$API_STATUS" =~ ^2 ]]; }

# Does a hook URL belong to this project?  ...?project=<name> or &project=<name>
_hook_matches() { [[ "$1" =~ [?\&]project=${NAME}($|\&) ]]; }

# Prepare REMOTE_* for the current project. Returns 1 when no token is saved.
remote_init() {
  parse_repo_url "$REPO_URL" || { warn "cannot read host/path from REPO_URL '$REPO_URL'"; return 1; }
  [[ "$REPO_HOST" =~ $HOST_RE ]] || return 1
  have_token "$REPO_HOST" || return 1
  REMOTE_PROVIDER="${GIT_PROVIDER:-$(provider_for_host "$REPO_HOST")}"
  REMOTE_TOKEN="$(read_token "$REPO_HOST")"
  REMOTE_API="$(api_base "$REMOTE_PROVIDER" "$REPO_HOST")"
  if [[ "$REMOTE_PROVIDER" == "github" ]]; then
    REMOTE_PROJECT_URL="$REMOTE_API/repos/$REPO_PATH"
  else
    REMOTE_PROJECT_URL="$REMOTE_API/projects/$(jq -rn --arg p "$REPO_PATH" '$p|@uri')"
  fi
}

r_api() { _api "$REMOTE_PROVIDER" "$REMOTE_TOKEN" "$@"; }

# ------------------------------------------------------------------ setup
remote_add_deploy_key() {
  local title pub body path
  title="$(deploy_key_title)"
  pub="$(cat "$KEYS_DIR/$NAME.pub")"
  if [[ "$REMOTE_PROVIDER" == "github" ]]; then
    path="/keys"
    body="$(jq -nc --arg t "$title" --arg k "$pub" '{title:$t, key:$k, read_only:true}')"
  else
    path="/deploy_keys"
    body="$(jq -nc --arg t "$title" --arg k "$pub" '{title:$t, key:$k, can_push:false}')"
  fi
  r_api POST "$REMOTE_PROJECT_URL$path" "$body"
  if _ok; then echo "    deploy key added (read-only): $title"; return 0; fi
  # Already there? (re-running connect)
  r_api GET "$REMOTE_PROJECT_URL$path?per_page=100"
  if _ok && jq -e --arg k "${pub% *}" 'any(.[]; (.key | split(" ")[0:2] | join(" ")) == $k)' <<<"$API_BODY" >/dev/null 2>&1; then
    echo "    deploy key already present"
    return 0
  fi
  warn "could not add the deploy key: $(_api_error)"
  return 1
}

remote_set_webhook() {
  local url ssl hook_id body path
  [[ -n "${WEBHOOK_BASE:-}" ]] || { warn "WEBHOOK_BASE is not set in $CONFIG_DIR/server.env"; return 1; }
  url="$(webhook_url)"
  [[ "$url" == https://* ]] && ssl=true || ssl=false
  path="/hooks"
  r_api GET "$REMOTE_PROJECT_URL$path?per_page=100"
  _ok || { warn "could not list webhooks: $(_api_error)"; return 1; }
  if [[ "$REMOTE_PROVIDER" == "github" ]]; then
    hook_id="$(jq -r '.[] | "\(.id) \(.config.url // "")"' <<<"$API_BODY" | while read -r id u; do if _hook_matches "$u"; then echo "$id"; break; fi; done || true)"
    body="$(jq -nc --arg u "$url" --arg i "$([[ $ssl == true ]] && echo 0 || echo 1)" \
      '{name:"web", active:true, events:["push"], config:{url:$u, content_type:"json", insecure_ssl:$i}}')"
  else
    hook_id="$(jq -r '.[] | "\(.id) \(.url // "")"' <<<"$API_BODY" | while read -r id u; do if _hook_matches "$u"; then echo "$id"; break; fi; done || true)"
    body="$(jq -nc --arg u "$url" --arg t "$DEPLOY_TOKEN" --arg b "$BRANCH" --argjson s "$ssl" \
      '{url:$u, token:$t, push_events:true, push_events_branch_filter:$b, enable_ssl_verification:$s,
        tag_push_events:false, merge_requests_events:false, issues_events:false, note_events:false,
        pipeline_events:false, job_events:false, wiki_page_events:false, releases_events:false}')"
  fi
  if [[ -n "$hook_id" ]]; then
    if [[ "$REMOTE_PROVIDER" == "github" ]]; then
      r_api PATCH "$REMOTE_PROJECT_URL$path/$hook_id" "$(jq -c 'del(.name)' <<<"$body")"
    else
      r_api PUT "$REMOTE_PROJECT_URL$path/$hook_id" "$body"
    fi
    _ok || { warn "could not update the webhook: $(_api_error)"; return 1; }
    echo "    webhook updated (push events, branch $BRANCH)"
  else
    r_api POST "$REMOTE_PROJECT_URL$path" "$body"
    _ok || { warn "could not create the webhook: $(_api_error)"; return 1; }
    echo "    webhook created (push events, branch $BRANCH)"
  fi
  [[ "$ssl" == true ]] || warn "the webhook uses plain HTTP; the token travels unencrypted. Give n8n a domain (HTTPS)."
}

# remote_setup: returns 0 on success, 1 on failure, 2 when no token is saved.
remote_setup() {
  remote_init || return 2
  info "Connecting $(provider_label) ($REPO_HOST/$REPO_PATH) through the API"
  remote_add_deploy_key || return 1
  remote_set_webhook || return 1
}

# ------------------------------------------------------------------ teardown
remote_teardown() {
  remote_init || return 2
  local title id ids path_k
  title="$(deploy_key_title)"
  info "Removing deploy key and webhook from $(provider_label) ($REPO_HOST/$REPO_PATH)"
  [[ "$REMOTE_PROVIDER" == "github" ]] && path_k="/keys" || path_k="/deploy_keys"
  r_api GET "$REMOTE_PROJECT_URL$path_k?per_page=100"
  if _ok; then
    for id in $(jq -r --arg t "$title" '.[] | select(.title == $t) | .id' <<<"$API_BODY"); do
      r_api DELETE "$REMOTE_PROJECT_URL$path_k/$id"
      _ok && echo "    deploy key removed" || warn "could not remove deploy key $id: $(_api_error)"
    done
  else
    warn "could not list deploy keys: $(_api_error)"
  fi
  r_api GET "$REMOTE_PROJECT_URL/hooks?per_page=100"
  if _ok; then
    if [[ "$REMOTE_PROVIDER" == "github" ]]; then
      ids="$(jq -r '.[] | "\(.id) \(.config.url // "")"' <<<"$API_BODY")"
    else
      ids="$(jq -r '.[] | "\(.id) \(.url // "")"' <<<"$API_BODY")"
    fi
    while read -r id u; do
      [[ -n "$id" ]] && _hook_matches "$u" || continue
      r_api DELETE "$REMOTE_PROJECT_URL/hooks/$id"
      _ok && echo "    webhook removed" || warn "could not remove webhook $id: $(_api_error)"
    done <<<"$ids"
  else
    warn "could not list webhooks: $(_api_error)"
  fi
}

# Verify a token: prints the account name. Usage: token_whoami <provider> <host> <token>
token_whoami() {
  local provider="$1" host="$2" token="$3"
  _api "$provider" "$token" GET "$(api_base "$provider" "$host")/user"
  _ok || { echo "token rejected: $(_api_error)" >&2; return 1; }
  jq -r '.login // .username // "?"' <<<"$API_BODY"
}
