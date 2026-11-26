#!/usr/bin/env bash
# Choose notification channels and save their settings.
# Usage: autodeploy notify-setup     (choose / change channels)
#        autodeploy notify-test      (send a test message)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="${AUTODEPLOY_LIB:-$SCRIPT_DIR/../lib}"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../lib/notify.sh
source "$LIB_DIR/notify.sh"

ensure_deploy_user "$@"

FILE="$CONFIG_DIR/notify.env"
mkdir -p "$CONFIG_DIR"

send_test() {
  load_env_file "$FILE" || die "no notification settings yet. Run: autodeploy notify-setup"
  [[ -n "${NOTIFY_CHANNELS:-}" ]] || die "no channels selected"
  info "sending a test message to: $NOTIFY_CHANNELS"
  notify "🔔 رسالة تجربة من autodeploy" "السيرفر: $(hostname)
إذا وصلتك هذه الرسالة فالإشعارات تعمل."
}

if [[ "${1:-}" == "--test" ]]; then
  send_test
  exit 0
fi

# Keep current values as defaults when re-running.
load_env_file "$FILE" 2>/dev/null || true

echo
echo "=== Notification channels ==="
echo "Pick one or more. You can change this any time with: autodeploy notify-setup"
echo

channels=()
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"

# Answers are read fresh on every run, so clear the loaded values first.
prompt() { local var="$1" q="$2" def="${!1:-${3:-}}"; unset "$var"; ask "$var" "$q" "$def"; }

if ask_yes_no "Telegram?" "$([[ " ${NOTIFY_CHANNELS:-} " == *" telegram "* ]] && echo y || echo n)"; then
  echo "  1) Create a bot with @BotFather and copy its token."
  echo "  2) Send any message to your bot, then open:"
  echo "     https://api.telegram.org/bot<TOKEN>/getUpdates  and copy chat.id"
  prompt TG_BOT_TOKEN "  Bot token"
  prompt TG_CHAT_ID "  Chat ID"
  write_env_var "$TMP" TG_BOT_TOKEN "$TG_BOT_TOKEN"
  write_env_var "$TMP" TG_CHAT_ID "$TG_CHAT_ID"
  channels+=(telegram)
fi

if ask_yes_no "Email?" "$([[ " ${NOTIFY_CHANNELS:-} " == *" email "* ]] && echo y || echo n)"; then
  echo "  Any SMTP account works. For Gmail use smtp.gmail.com, port 465,"
  echo "  and an App Password (Google Account > Security > App passwords)."
  prompt SMTP_HOST "  SMTP host" "smtp.gmail.com"
  prompt SMTP_PORT "  SMTP port (465 or 587)" "465"
  prompt SMTP_USER "  SMTP username"
  prompt SMTP_PASS "  SMTP password / app password"
  prompt SMTP_FROM "  From address" "${SMTP_USER:-}"
  prompt EMAIL_TO "  Send to (comma separated)" "${SMTP_FROM:-}"
  for v in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_FROM EMAIL_TO; do
    write_env_var "$TMP" "$v" "${!v}"
  done
  channels+=(email)
fi

if ask_yes_no "WhatsApp?" "$([[ " ${NOTIFY_CHANNELS:-} " == *" whatsapp "* ]] && echo y || echo n)"; then
  echo "  Providers:"
  echo "    cloud     - official WhatsApp Cloud API (Meta developer account)"
  echo "    callmebot - free, personal use only, quick setup (callmebot.com)"
  prompt WA_PROVIDER "  Provider (cloud/callmebot)" "cloud"
  prompt WA_TO "  Your number with country code, digits only (e.g. 9639xxxxxxxx)"
  write_env_var "$TMP" WA_PROVIDER "$WA_PROVIDER"
  write_env_var "$TMP" WA_TO "$WA_TO"
  if [[ "$WA_PROVIDER" == "cloud" ]]; then
    prompt WA_PHONE_NUMBER_ID "  Phone number ID (from Meta app > WhatsApp > API setup)"
    prompt WA_TOKEN "  Access token (permanent system-user token recommended)"
    write_env_var "$TMP" WA_PHONE_NUMBER_ID "$WA_PHONE_NUMBER_ID"
    write_env_var "$TMP" WA_TOKEN "$WA_TOKEN"
  else
    prompt CALLMEBOT_APIKEY "  CallMeBot API key"
    write_env_var "$TMP" CALLMEBOT_APIKEY "$CALLMEBOT_APIKEY"
  fi
  channels+=(whatsapp)
fi

write_env_var "$TMP" NOTIFY_CHANNELS "${channels[*]:-}"
install -m 600 "$TMP" "$FILE"

if (( ${#channels[@]} )); then
  info "saved: ${channels[*]}"
  if ask_yes_no "Send a test message now?" "y"; then
    NOTIFY_CHANNELS=""
    send_test
  fi
else
  info "no channels selected; deploys will run without notifications"
fi
