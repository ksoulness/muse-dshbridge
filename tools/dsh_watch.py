#!/usr/bin/env python3
"""DSH run 跟进 watcher：由后台子代理/后台进程运行，循环 wait_run 直到终态。

为什么需要它：DSH Relay 是拉模式，没有任何推送。主会话回合结束 = 没人在等。
本脚本（经子代理在后台跑）结束时其完成回执会被运行时投递回原会话，
主助手收到回执后必须在那个回合里执行 pending 登记里的 next_action（续接下一轮/
落实修改/汇报），不许只报「第 1 轮完成」再口头承诺下一轮。

用法:
  dsh_watch.py <runId> [--deadline-min 90] [--out <result.json>]

行为:
- 每 30 秒调一次 wait_run(timeoutMs=30000)，直到终态
  succeeded|failed|cancelled|timeout|orphaned，或超过 deadline。
- get_run 读回 FORBIDDEN/expired 时改读 runs-ledger.jsonl 的 terminal 记录兜底；
  ledger 也没有就继续等，不误判终态。
- 终态结果（status/startedAt/finishedAt/assistantText 全文）写入 out 文件
  （默认 ~/workspace/dsh-study/hidden_files/pending/<runId>.result.json）
  并打印到 stdout，供后台子代理原样带回主会话。
"""
import json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
spec = importlib.util.spec_from_file_location("dsh_client", os.path.join(os.path.dirname(os.path.abspath(__file__)), "dsh_client.py"))
dc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dc)

TERMINAL = ("succeeded", "failed", "cancelled", "timeout", "orphaned")
PENDING_DIR = os.path.expanduser("~/workspace/dsh-study/hidden_files/pending")
LEDGER = os.path.expanduser("~/workspace/dsh-study/hidden_files/runs-ledger.jsonl")


def ledger_terminal(run_id):
    try:
        with open(LEDGER, encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("event") == "terminal" and rec.get("runId") == run_id:
                    return rec
    except FileNotFoundError:
        pass
    return None


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: dsh_watch.py <runId> [--deadline-min N] [--out path]"}))
        return 2
    run_id = sys.argv[1]
    deadline_min = 90
    out_path = os.path.join(PENDING_DIR, f"{run_id}.result.json")
    args = sys.argv[2:]
    for i, a in enumerate(args):
        if a == "--deadline-min" and i + 1 < len(args):
            deadline_min = int(args[i + 1])
        if a == "--out" and i + 1 < len(args):
            out_path = args[i + 1]

    st = dc.ensure_token(dc.load())
    deadline = time.time() + deadline_min * 60
    last = None
    while True:
        try:
            out = dc.call(st, "wait_run", {"runId": run_id, "timeoutMs": 30000}, timeout=70)
        except Exception as e:
            out = {"_watch_error": str(e)[:200]}
        status = str(out.get("status") or "")
        if status in TERMINAL:
            last = out
            break
        if out.get("_error") or "FORBIDDEN" in json.dumps(out)[:500] or "expired" in json.dumps(out)[:500]:
            rec = ledger_terminal(run_id)
            if rec:
                last = {"runId": run_id, "sessionId": rec.get("sessionId"), "status": rec.get("status"),
                        "startedAt": rec.get("startedAt"), "finishedAt": rec.get("finishedAt"),
                        "assistantText": rec.get("assistantText"), "_source": "ledger"}
                break
        if time.time() > deadline:
            last = {"runId": run_id, "status": "watch_deadline_exceeded",
                    "note": f"{deadline_min} 分钟内未见终态；pending 登记保留，兜底 cron 继续查，不许当作完成或失败结案。"}
            break
        time.sleep(5)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(last, f, ensure_ascii=False, indent=1)
    os.replace(tmp, out_path)
    print(json.dumps(last, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
