#!/bin/bash
#
# Perpetual Telegram inbox watcher.
#
# Long-polls getUpdates forever and appends every message to a log. Runs as a
# daemon so the backlog is complete whenever anyone comes to read it.
#
# WHY A DAEMON AND NOT AD-HOC POLLING
#   getUpdates is SINGLE-CONSUMER: an update is delivered once and confirming an
#   offset drops everything before it. Two pollers steal each other's messages.
#   So exactly one process owns getUpdates -- this one -- and everything else
#   reads the log it writes.
#
#   It also means no message is missed between reads. Ad-hoc polling only ever
#   sees what happens to be queued at that instant.
#
# WHAT IT DOES NOT DO
#   It cannot notify a person or an agent. It records. Read the log:
#       tail -f ~/.telegram_inbox.log
#
# USAGE
#   tools/tg-watch.sh                 # run in foreground
#   tools/tg-watch.sh --daemon        # detach, survives logout
#   tools/tg-watch.sh --status        # is it running, how many messages
#   tools/tg-watch.sh --stop
#
# Credentials come from ~/.telegram_bot_env (chmod 600).

set -u

ENV_FILE="${TELEGRAM_ENV:-$HOME/.telegram_bot_env}"
LOG="${TELEGRAM_INBOX:-$HOME/.telegram_inbox.log}"
OFFSET_FILE="${TELEGRAM_OFFSET:-$HOME/.telegram_offset}"
PIDFILE="${TELEGRAM_PIDFILE:-$HOME/.telegram_watch.pid}"

case "${1:-}" in
    --status)
        if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
            echo "  running (pid $(cat "${PIDFILE}"))"
        else
            echo "  not running"
        fi
        echo "  log: ${LOG} ($( [ -f "${LOG}" ] && wc -l < "${LOG}" || echo 0 ) lines)"
        echo "  next offset: $( [ -f "${OFFSET_FILE}" ] && cat "${OFFSET_FILE}" || echo '(none)' )"
        exit 0 ;;
    --stop)
        if [ -f "${PIDFILE}" ] && kill "$(cat "${PIDFILE}")" 2>/dev/null; then
            echo "  stopped"; rm -f "${PIDFILE}"
        else
            echo "  not running"
        fi
        exit 0 ;;
    --daemon)
        # Re-exec detached. setsid survives logout and terminal close.
        if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
            echo "  already running (pid $(cat "${PIDFILE}"))"; exit 0
        fi
        setsid nohup "$0" >/dev/null 2>&1 < /dev/null &
        sleep 1
        [ -f "${PIDFILE}" ] && echo "  daemon started (pid $(cat "${PIDFILE}"))" || echo "  failed to start"
        exit 0 ;;
esac

[ -r "${ENV_FILE}" ] || { echo "!! no ${ENV_FILE}" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "${ENV_FILE}"; set +a
: "${TELEGRAM_BOT_TOKEN:?}"

echo $$ > "${PIDFILE}"
trap 'rm -f "${PIDFILE}"; exit 0' TERM INT

HERE="$(cd "$(dirname "$0")" && pwd)"
API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
OFFSET="$( [ -f "${OFFSET_FILE}" ] && cat "${OFFSET_FILE}" || echo 0 )"

while :; do
    RESP="$(curl -s --max-time 70 "${API}/getUpdates?timeout=55&offset=${OFFSET}" 2>/dev/null)"
    if [ -z "${RESP}" ]; then sleep 5; continue; fi

    NEXT="$(printf '%s' "${RESP}" | python3 "${HERE}/tg-parse.py" "${OFFSET}" "${LOG}" 2>/dev/null)"

    if [ -n "${NEXT}" ] && [ "${NEXT}" != "${OFFSET}" ]; then
        OFFSET="${NEXT}"
        printf '%s' "${OFFSET}" > "${OFFSET_FILE}"
    fi
done
