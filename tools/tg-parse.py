#!/usr/bin/env python3
"""Append Telegram getUpdates results to the inbox log; print the next offset.

Split out of tg-watch.sh deliberately: the same logic inlined as `python3 -c`
inside a shell loop needs three levels of quoting and broke on the first
f-string. A file has no quoting problem at all.

stdin  : raw getUpdates JSON
argv[1]: current offset
argv[2]: log path
stdout : next offset (unchanged if nothing new, so the caller can detect it)
"""
import datetime
import json
import sys


def main() -> int:
    offset = int(sys.argv[1])
    log_path = sys.argv[2]

    try:
        payload = json.load(sys.stdin)
    except Exception:
        print(offset)
        return 0

    if not payload.get("ok"):
        print(offset)
        return 0

    updates = payload.get("result", [])
    if not updates:
        print(offset)
        return 0

    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_path, "a", encoding="utf-8") as fh:
        for upd in updates:
            offset = max(offset, upd["update_id"] + 1)

            msg = (
                upd.get("message")
                or upd.get("channel_post")
                or upd.get("edited_message")
            )
            if not msg:
                # membership changes, callback queries, etc. Worth recording:
                # a "bot left/rejoined" event is what explained privacy mode
                # taking effect.
                kinds = ",".join(k for k in upd if k != "update_id")
                fh.write(f"{now}\t-\t<event>\t{kinds}\n")
                continue

            frm = msg.get("from") or {}
            who = frm.get("username") or frm.get("first_name") or "?"
            chat = msg.get("chat") or {}
            where = chat.get("title") or str(chat.get("id"))
            text = msg.get("text") or msg.get("caption") or "<non-text>"
            fh.write(f"{now}\t{where}\t{who}\t" + text.replace("\n", "\\n") + "\n")

    print(offset)
    return 0


if __name__ == "__main__":
    sys.exit(main())
