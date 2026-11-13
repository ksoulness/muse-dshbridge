#!/usr/bin/env python3
"""归档清扫（2026-11-13 LEE 定）：每次新派单前，把「我派出的」旧会话归档，列表只留当前事项。

规则（硬边界）：
- 只归档 sessionId 出现在我的 runs-ledger.jsonl 里的会话（我派单的证据）；别人的会话一律不碰。
- 跳过：已归档的、running 的、以及 pending 登记里未标 closed 的会话（事项未结束）。
- DSH 派给我的单（队列/门铃）不在这里处理。
用法：python3 sweep_archive.py [workspace ...] [--dry-run]
     无 workspace 参数时默认扫 E:\\Code\\muse 与 E:\\Code\\Ops。
也可被派发脚本 import：run_sweep(workspaces, keep_extra=set()) -> dict
"""
import json, os, sys, glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dsh_client as dc

BASE = os.path.expanduser("~/workspace/dsh-study/hidden_files")
DEFAULT_WS = ["E:\\Code\\muse", "E:\\Code\\Ops"]


def my_session_ids():
    ids = set()
    with open(os.path.join(BASE, "runs-ledger.jsonl"), encoding="utf-8") as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("sessionId"):
                ids.add(d["sessionId"])
    return ids


def open_matter_sessions():
    ids = set()
    for p in glob.glob(os.path.join(BASE, "pending", "*.json")):
        if p.endswith(".result.json"):
            continue
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception:
            continue
        if not d.get("closed") and d.get("session_id"):
            ids.add(d["session_id"])
    return ids


def run_sweep(workspaces=None, keep_extra=None, dry_run=False):
    workspaces = workspaces or DEFAULT_WS
    keep = open_matter_sessions() | set(keep_extra or [])
    mine = my_session_ids()
    st = dc.ensure_token(dc.load())
    result = {"archived": [], "skipped_running": [], "skipped_open": [], "errors": []}
    for ws in workspaces:
        out = dc.call(st, "list_workspace_sessions", {"workspace": ws}, timeout=120)
        for s in out.get("sessions", []):
            sid = s["sessionId"]
            if sid not in mine or s.get("archived"):
                continue
            if s.get("running"):
                result["skipped_running"].append(sid)
                continue
            if sid in keep:
                result["skipped_open"].append(sid)
                continue
            if dry_run:
                result["archived"].append(sid + " (dry-run)")
                continue
            try:
                r = dc.call(st, "archive_terminal_session", {"session_id": sid}, timeout=120)
                if isinstance(r, dict) and r.get("archived"):
                    result["archived"].append(sid)
                else:
                    result["errors"].append(f"{sid}: {str(r)[:120]}")
            except Exception as e:
                result["errors"].append(f"{sid}: {str(e)[:120]}")
    return result


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    res = run_sweep(args or None, dry_run="--dry-run" in sys.argv)
    print(json.dumps(res, ensure_ascii=False))
