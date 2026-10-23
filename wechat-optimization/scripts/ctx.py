#!/usr/bin/env python3
"""Per-sender conversation context store for the wx-bot pull flow.

Each WeChat sender (from_wxid) gets its own JSONL log, so one conversation
stays coherent across hook wake-ups while staying isolated from other chats.

Commands:
  ctx.py read <sender> [--limit N]   print last N exchanges as plain text
  ctx.py add <sender> <event_id> <in|out> <text...>
                                     append one exchange (flock-guarded,
                                     dedupes on event_id; text is stored
                                     with newlines collapsed)

Store: ~/workspace/wechat-bridge/context/
"""
import hashlib
import json
import os
import re
import sys
import time

CTX_DIR = os.path.expanduser("~/workspace/wechat-bridge/context")


def sender_file(sender: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9]", "_", sender)[:64]
    digest = hashlib.sha1(sender.encode("utf-8")).hexdigest()[:8]
    return os.path.join(CTX_DIR, f"{safe}_{digest}.jsonl")


def cmd_read(sender: str, limit: int) -> None:
    path = sender_file(sender)
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    for line in lines[-limit:]:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = rec.get("ts", 0)
        when = time.strftime("%m-%d %H:%M", time.localtime(ts)) if ts else "?"
        who = "用户" if rec.get("dir") == "in" else "我"
        print(f"[{when}] {who}: {rec.get('text', '')}")


def cmd_add(sender: str, event_id: str, direction: str, text: str) -> None:
    os.makedirs(CTX_DIR, mode=0o700, exist_ok=True)
    path = sender_file(sender)
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return
    rec = json.dumps(
        {"event_id": event_id, "ts": int(time.time()), "dir": direction, "text": text[:2000]},
        ensure_ascii=False,
    ) + "\n"
    import fcntl
    with open(path, "a+", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            f.seek(0)
            if event_id:
                for line in f:
                    try:
                        if json.loads(line).get("event_id") == event_id:
                            return  # already recorded
                    except json.JSONDecodeError:
                        pass
            f.write(rec)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def main(argv):
    if len(argv) < 3:
        sys.exit("usage: ctx.py read <sender> [--limit N] | ctx.py add <sender> <event_id> <in|out> <text...>")
    op = argv[1]
    if op == "read":
        limit = 40
        if "--limit" in argv:
            limit = int(argv[argv.index("--limit") + 1])
        cmd_read(argv[2], limit)
    elif op == "add":
        if len(argv) < 6:
            sys.exit("usage: ctx.py add <sender> <event_id> <in|out> <text...>")
        cmd_add(argv[2], argv[3], argv[4], " ".join(argv[5:]))
    else:
        sys.exit(f"unknown command: {op}")


if __name__ == "__main__":
    main(sys.argv)
