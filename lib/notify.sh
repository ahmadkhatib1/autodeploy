# shellcheck shell=bash
# Notification channels: telegram, email, whatsapp.
# Channels are chosen in config/notify.env (NOTIFY_CHANNELS="telegram email")
# and can be overridden per project in projects/<name>.env.
# A failing channel never fails the deploy.

NOTIFY_MAX_CHARS=3500

# Escape a value for a curl config file (-K).
_curl_cfg_value() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

_send_telegram() {
  local text="$1"
  [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || { warn "telegram: TG_BOT_TOKEN or TG_CHAT_ID missing"; return 1; }
  curl -fsS --max-time 20 -o /dev/null \
    -K <(printf 'url = %s\n' "$(_curl_cfg_value "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage")") \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "disable_web_page_preview=true"
}

_send_email() {
  local subject="$1" body="$2" proto="smtp" rcpt b64subj
  [[ -n "${SMTP_HOST:-}" && -n "${SMTP_FROM:-}" && -n "${EMAIL_TO:-}" ]] || { warn "email: SMTP_HOST, SMTP_FROM or EMAIL_TO missing"; return 1; }
  local port="${SMTP_PORT:-587}"
  [[ "$port" == "465" ]] && proto="smtps"
  local -a rcpt_args=()
  IFS=',' read -r -a _rcpts <<< "$EMAIL_TO"
  for rcpt in "${_rcpts[@]}"; do
    rcpt="${rcpt//[[:space:]]/}"
    [[ -n "$rcpt" ]] && rcpt_args+=(--mail-rcpt "$rcpt")
  done
  b64subj="$(printf '%s' "$subject" | base64 | tr -d '\n')"
  printf 'From: %s\r\nTo: %s\r\nSubject: =?UTF-8?B?%s?=\r\nDate: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n%s\r\n' \
    "$SMTP_FROM" "$EMAIL_TO" "$b64subj" "$(LC_ALL=C date -R)" "$body" |
  curl -fsS --max-time 30 --ssl-reqd \
    --url "${proto}://${SMTP_HOST}:${port}" \
    --mail-from "$SMTP_FROM" "${rcpt_args[@]}" \
    -K <(printf 'user = %s\n' "$(_curl_cfg_value "${SMTP_USER:-}:${SMTP_PASS:-}")") \
    --upload-file -
}

_send_whatsapp() {
  local text="$1"
  case "${WA_PROVIDER:-cloud}" in
    cloud)
      [[ -n "${WA_TOKEN:-}" && -n "${WA_PHONE_NUMBER_ID:-}" && -n "${WA_TO:-}" ]] || { warn "whatsapp: WA_TOKEN, WA_PHONE_NUMBER_ID or WA_TO missing"; return 1; }
      jq -n --arg to "$WA_TO" --arg body "$text" \
        '{messaging_product:"whatsapp", to:$to, type:"text", text:{body:$body, preview_url:false}}' |
      curl -fsS --max-time 20 -o /dev/null \
        -K <(printf 'header = %s\n' "$(_curl_cfg_value "Authorization: Bearer ${WA_TOKEN}")") \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        "https://graph.facebook.com/${WA_API_VERSION:-v21.0}/${WA_PHONE_NUMBER_ID}/messages"
      ;;
    callmebot)
      [[ -n "${WA_TO:-}" && -n "${CALLMEBOT_APIKEY:-}" ]] || { warn "whatsapp: WA_TO or CALLMEBOT_APIKEY missing"; return 1; }
      curl -fsS --max-time 20 -o /dev/null -G "https://api.callmebot.com/whatsapp.php" \
        --data-urlencode "phone=${WA_TO}" \
        --data-urlencode "text=${text}" \
        -K <(printf 'data-urlencode = %s\n' "$(_curl_cfg_value "apikey=${CALLMEBOT_APIKEY}")")
      ;;
    *) warn "whatsapp: unknown WA_PROVIDER '${WA_PROVIDER}'"; return 1 ;;
  esac
}

# notify "subject" "body"
notify() {
  local subject="$1" body="$2" text ch
  text="${subject}"$'\n\n'"${body}"
  if (( ${#text} > NOTIFY_MAX_CHARS )); then
    text="${text:0:NOTIFY_MAX_CHARS}"$'\n…'
  fi
  for ch in ${NOTIFY_CHANNELS:-}; do
    if [[ "${NOTIFY_DRY_RUN:-}" == "1" ]]; then
      printf '[notify:%s] %s\n' "$ch" "$text" >&2
      continue
    fi
    case "$ch" in
      telegram) _send_telegram "$text" || warn "telegram notification failed" ;;
      email)    _send_email "$subject" "$body" || warn "email notification failed" ;;
      whatsapp) _send_whatsapp "$text" || warn "whatsapp notification failed" ;;
      *)        warn "unknown notification channel '$ch'" ;;
    esac
  done
  return 0
}
