#!/usr/bin/env python3
"""DSH 8443 (tailnet) MCP 客户端 —— muse-dshbridge 配套工具。

功能：
- 从 oauth-state.json 读取 access/refresh token 对（文件权限必须 600）
- access 过期（>55 分钟）自动用 refresh_token 轮换，并把新 token 对再继续
（轮换后旧 refresh 作废、旧 access 立即失效；重放旧 refresh 会吊销整个 token 家族）
- start_review/start_run 的 runId/sessionId/operationId/幂等键、以及终态 assistantText
自动写入同目录 runs-ledger.jsonl 台账
- 空响应（适配器秒级窗口）自动等 15 秒重试，最多 3 次；默认单次超时 240 秒

环境变量：
- DSH_OAUTH_STATE state 文件路径（默认 ~/.muse-dsh/oauth-state.json）
- DSH_PROXY 代理 URL；默认取 HTTPS_PROXY 并把端口换成 3130（Muse 宿主的
tailnet 隧道口）。直连环境设 DSH_PROXY=DIRECT

state 文件格式：
{"base": "https://win.<tailnet>.ts.net:8443", "access_token": "dsh_at_...",
"refresh_token": "dsh_rt_...", "issued_at": "2026-10-20T22:21:45+08:00"}

用法：
dsh_client.py tools/list
dsh_client.py doctor
dsh_client.py start_review '{"workspace": "...", "task": "muse指派-...",...}'
dsh_client.py wait_run '{"runId": "...", "timeoutMs": 30000}'
token 绝不打印到 stdout（只打印业务结果）。
"""
import subprocess, json, re, os, sys, time

STATE = os.environ.get("DSH_OAUTH_STATE", os.path.expanduser("~/.muse-dsh/oauth-state.json"))
LEDGER = os.path.join(os.path.dirname(os.path.abspath(STATE)), "runs-ledger.jsonl")


def proxy_args():
p = os.environ.get("DSH_PROXY", "")
if p == "DIRECT":
return []
if not p:
base = os.environ.get("HTTPS_PROXY", "")
p = base.rsplit(":", 1)[0] + ":3130" if ":" in base else ""
return ["--proxy", p] if p else []


def load():
with open(STATE, encoding="utf-8") as f:
return json.load(f)


def save(st):
tmp = STATE + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
json.dump(st, f, ensure_ascii=False, indent=1)
os.chmod(tmp, 0o600)
os.replace(tmp, STATE)


def ledger(rec):
rec["at"] = time.strftime("%Y-%m-%dT%H:%M:%S+08:00", time.localtime())
try:
with open(LEDGER, "a", encoding="utf-8") as f:
f.write(json.dumps(rec, ensure_ascii=False) + "\n")
except Exception:
pass


def http_post(url, body, token=None, timeout=240, retries=3):
cmd = ["curl", "-sSk", "--connect-timeout", "10", "--max-time", str(timeout),
"-X", "POST", url, "-H", "content-type: application/json",
"-H", "accept: application/json, text/event-stream", "-d", json.dumps(body)]
cmd[2:2] = proxy_args()
if token:
cmd += ["-H", f"Authorization: Bearer {token}"]
last = None
for attempt in range(retries + 1):
r = subprocess.run(cmd, capture_output=True, text=True)
t = "\n".join(l[5:].strip() if l.startswith("data:") else l for l in r.stdout.splitlines())
m = re.search(r"\{.*\}", t, re.S)
if m:
try:
return json.loads(m.group(0))
except Exception as e:
last = e
else:
last = RuntimeError(f"empty reply: {r.stderr[:120]}")
if attempt < retries:
time.sleep(15) # 适配器秒级窗口：等一下重试
raise RuntimeError(f"response failed after retries from {url}: {last}")


def refresh(st):
d = http_post(st["base"] + "/token",
{"grant_type": "refresh_token", "refresh_token": st["refresh_token"]})
if "access_token" not in d:
raise RuntimeError(f"refresh failed: {json.dumps(d)[:300]}")
st["access_token"] = d["access_token"]
st["refresh_token"] = d["refresh_token"]
st["issued_at"] = time.strftime("%Y-%m-%dT%H:%M:%S+08:00", time.localtime())
save(st) # 先落盘再干活：旧 refresh 已被轮换作废
return st


def ensure_token(st):
try:
issued = time.mktime(time.strptime(st["issued_at"], "%Y-%m-%dT%H:%M:%S+08:00"))
if time.time() - issued > 3300:
return refresh(st)
except Exception:
pass
return st


_id = [100]


def call(st, name, args=None, timeout=240):
_id[0] += 1
d = http_post(st["base"] + "/mcp",
{"jsonrpc": "2.0", "id": _id[0], "method": "tools/call",
"params": {"name": name, "arguments": args or {}}},
st["access_token"], timeout)
if "error" in d:
return {"_error": d["error"]}
c = (d.get("result") or {}).get("content") or []
txt = c[0].get("text") if c else None
if txt is None:
return {"_result": d.get("result")}
try:
out = json.loads(txt)
except Exception:
out = {"_text": txt[:600]}
if name in ("start_review", "start_run") and isinstance(out, dict) and out.get("runId"):
ledger({"event": "started", "tool": name, "runId": out.get("runId"),
"sessionId": out.get("sessionId"), "operationId": out.get("operationId"),
"idempotencyKey": (args or {}).get("idempotencyKey")})
if name in ("wait_run", "get_run") and isinstance(out, dict) and str(out.get("status") or "") in (
"succeeded", "failed", "cancelled", "timeout", "orphaned"):
ledger({"event": "terminal", "runId": out.get("runId"), "sessionId": out.get("sessionId"),
"status": out.get("status"), "startedAt": out.get("startedAt"),
"finishedAt": out.get("finishedAt"),
"assistantText": str(out.get("assistantText") or "")[:4000]})
return out


if __name__ == "__main__":
st = ensure_token(load())
tool = sys.argv[1]
args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
if tool == "tools/list":
_id[0] += 1
d = http_post(st["base"] + "/mcp",
{"jsonrpc": "2.0", "id": _id[0], "method": "tools/list"},
st["access_token"])
print(json.dumps([t["name"] for t in (d.get("result") or {}).get("tools", [])],
ensure_ascii=False))
else:
print(json.dumps(call(st, tool, args), ensure_ascii=False))
