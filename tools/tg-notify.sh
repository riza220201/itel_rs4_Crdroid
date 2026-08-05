#!/bin/bash
#
# Send a build/release notification to Telegram.
#
# Credentials come from ~/.telegram_bot_env (chmod 600), never from the command
# line or the environment of a shared host:
#     TELEGRAM_BOT_TOKEN=...
#     TELEGRAM_CHAT_ID=...
#
# Usage:
#   tg-notify.sh "message text"          # markdown, multi-line ok
#   echo "text" | tg-notify.sh -         # read from stdin
#   tg-notify.sh -f FILE "caption"       # send a document (Bot API caps at 50 MB)
#
# The 50 MB sendDocument limit is why release ZIPs are NOT sent through this --
# post a link instead.

set -u

ENV_FILE="${TELEGRAM_ENV:-$HOME/.telegram_bot_env}"
[ -r "${ENV_FILE}" ] || { echo "!! no ${ENV_FILE}" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "${ENV_FILE}"; set +a
: "${TELEGRAM_BOT_TOKEN:?missing TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?missing TELEGRAM_CHAT_ID}"

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

if [ "${1:-}" = "-f" ]; then
    FILE="${2:?usage: -f FILE [caption]}"
    CAPTION="${3:-}"
    [ -f "${FILE}" ] || { echo "!! no such file: ${FILE}" >&2; exit 2; }
    SZ=$(stat -c %s "${FILE}")
    if [ "${SZ}" -gt 52428800 ]; then
        echo "!! ${FILE} is $((SZ / 1048576)) MB; Bot API limit is 50 MB. Send a link instead." >&2
        exit 3
    fi
    RESP=$(curl -s --max-time 180 -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "document=@${FILE}" -F "caption=${CAPTION}" "${API}/sendDocument")
else
    if [ "${1:-}" = "-" ]; then TEXT="$(cat)"; else TEXT="${1:?usage: tg-notify.sh <text>}"; fi
    # Markdown first, then PLAIN TEXT on a parse failure. Telegram rejects the
    # whole message for one stray '_' or '*', and a build notification that
    # silently does not arrive is worse than an unformatted one.
    send() {
        curl -s --max-time 60 \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${TEXT}" \
            ${1:+--data-urlencode "parse_mode=$1"} \
            --data-urlencode "disable_web_page_preview=true" \
            "${API}/sendMessage"
    }
    RESP=$(send Markdown)
    case "${RESP}" in
        *"can't parse entities"*) RESP=$(send "") ;;
    esac
fi

# Never print the response verbatim: on some errors Telegram echoes the request
# URL, which contains the token.
python3 - "$RESP" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("  send failed: unparseable response"); sys.exit(1)
if d.get("ok"):
    print(f"  sent (message_id {d.get('result',{}).get('message_id')})")
else:
    print(f"  send failed: {d.get('error_code')} {d.get('description')}")
    sys.exit(1)
PY
