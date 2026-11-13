#!/usr/bin/env python3
"""铃驱动 watcher：等本地 run_events.jsonl 出现指定 runId 的终态铃（DSH 侧终态门铃
经 ntfy muse-run-events → dsh-doorbell 守护进程落盘），出现后用 get_run_summary
取回终态全文，输出与 dsh_watch.py 同契约的一行 JSON 并落 <runId>.result.json。
铃迟迟不来（超过 --deadline-min）输出 watch_deadline_exceeded，不当完成/失败结案；
兜底 cron 仍是最后一道保险。铃到达前的本地轮询间隔 2 秒、零远程调用。"""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dsh_client as dc  # noqa: E402

EVENTS = os.path.expanduser("~/workspace/dsh-doorbell/state/run_events.jsonl")
TERMINAL = {"succeeded", "failed", "cancelled", "canceled", "error", "completed"}


def find_bell(run_id):
    if not os.path.exists(EVENTS):
        return None
    with open(EVENTS, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("run_id") == run_id and str(rec.get("status") or "") in TERMINAL:
                return rec
    return None


def main():
    args = sys.argv[1:]
    run_id = args[0]
    deadline_min = 120
    out_path = os.path.join(HERE, "..", "hidden_files", "pending", f"{run_id}.result.json")
    out_path = os.path.normpath(out_path)
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--deadline-min" and i + 1 < len(args):
            deadline_min = int(args[i + 1])
        if a == "--out" and i + 1 < len(args):
            out_path = args[i + 1]
        i += 1

    deadline = time.time() + deadline_min * 60
    bell = None
    while time.time() <= deadline:
        bell = find_bell(run_id)
        if bell:
            break
        time.sleep(2)

    if not bell:
        last = {"runId": run_id, "status": "watch_deadline_exceeded",
                "note": f"{deadline_min} 分钟内未见终态门铃；pending 登记保留，兜底 cron 继续查，不许当作完成或失败结案。"}
    else:
        st = dc.ensure_token(dc.load())
        try:
            summary = dc.call(st, "get_run_summary", {"runId": run_id}, timeout=60)
        except Exception as e:
            summary = {"_summary_error": str(e)[:200]}
        last = summary if isinstance(summary, dict) else {"summary": summary}
        last.setdefault("runId", run_id)
        last["_source"] = "run-events-bell"
        last["_bell"] = {"status": bell.get("status"), "finished_at": bell.get("finished_at"),
                         "received_at": bell.get("received_at"), "ntfy_id": bell.get("ntfy_id")}

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(last, f, ensure_ascii=False, indent=1)
    os.replace(tmp, out_path)
    print(json.dumps(last, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
