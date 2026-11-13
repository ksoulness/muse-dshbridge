#!/usr/bin/env python3
"""DSH 8443 (tailnet) MCP 客户端：读 hidden_files/oauth-state.json，
access 过期时自动用 refresh_token 轮换，并把新 access+refresh 原子落盘（600）。
用法: dsh_client.py <tool> [json-args]  |  dsh_client.py tools/list
token 绝不打印到 stdout（只打印业务结果）。"""
import subprocess, json, re, os, sys, time, fcntl
from contextlib import contextmanager
from datetime import datetime

STATE = os.path.expanduser("~/workspace/dsh-study/hidden_files/oauth-state.json")
LOCK = os.path.expanduser("~/workspace/dsh-study/hidden_files/.dsh-client.lock")

@contextmanager
def _token_lock():
    """跨进程串行化 token 读改写：refresh 轮换会作废旧 token 家族，
    并发 refresh 撞车会把通道打死（2026-11-13 第 2 轮前置修复）。"""
    fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
PROXY = os.environ["HTTPS_PROXY"].rsplit(":", 1)[0] + ":3130"

def load():
    with open(STATE, encoding="utf-8") as f: return json.load(f)

def save(st):
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f: json.dump(st, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600); os.replace(tmp, STATE)

def http_post(url, body, token=None, timeout=240, retries=3):
    cmd = ["curl", "-sSk", "--proxy", PROXY, "--connect-timeout", "10", "--max-time", str(timeout),
           "-X", "POST", url, "-H", "content-type: application/json",
           "-H", "accept: application/json, text/event-stream", "-d", json.dumps(body)]
    if token: cmd += ["-H", f"Authorization: Bearer {token}"]
    last = None
    for attempt in range(retries + 1):
        r = subprocess.run(cmd, capture_output=True, text=True)
        t = "\n".join(l[5:].strip() if l.startswith("data:") else l for l in r.stdout.splitlines())
        m = re.search(r"\{.*\}", t, re.S)
        if m:
            try: return json.loads(m.group(0))
            except Exception as e: last = e
        else:
            last = RuntimeError(f"empty reply: {r.stderr[:120]}")
        if attempt < retries: time.sleep(15)  # 适配器秒级窗口：等一下重试（DSH 侧口径）
    raise RuntimeError(f"response failed after retries from {url}: {last}")

def refresh(st):
    d = http_post(st["base"] + "/token", {"grant_type": "refresh_token", "refresh_token": st["refresh_token"]})
    if "access_token" not in d: raise RuntimeError(f"refresh failed: {json.dumps(d)[:300]}")
    st["access_token"] = d["access_token"]; st["refresh_token"] = d["refresh_token"]
    # UTC 数字 + 正确时区标：旧写法用 localtime 数字硬贴 +08:00，写读双方时区一旦不一致，
    # 就把 token 算成“未来签发”而跳过 refresh（2026-11-13 19:22–19:31 通道 FORBIDDEN/expired 的根因）
    st["issued_at"] = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
    save(st)  # 先落盘再干活：旧 refresh 已被轮换作废
    return st

def ensure_token(st):
    with _token_lock():
        # 锁内以磁盘为准：可能已有别的进程刚刷新过，拿最新状态再判断
        try:
            disk = load()
            if disk.get("issued_at", "") >= st.get("issued_at", ""):
                st = disk
        except Exception: pass
        try:
            try:
                # 时区感知解析：按 issued_at 自带的偏移算真实年龄；旧值（localtime 数字硬贴 +08:00）
                # 也能正确解析，不再被误判为“未来签发”而跳过 refresh；解析失败则回退旧口径
                issued = datetime.fromisoformat(st["issued_at"]).timestamp()
            except Exception:
                issued = time.mktime(time.strptime(st["issued_at"], "%Y-%m-%dT%H:%M:%S+08:00"))
            if time.time() - issued > 3300: return refresh(st)
        except Exception: pass
        return st

_STRUCTURED_FIELDS = ("reviewTargets", "contextReadScope", "excludedPaths", "writeScope")

def _manifest_gate(name, args):
    """派发硬门（2026-11-13 移植自 dsh-codex-kit 的 build_task_manifest）：
    start_review/start_run 只要带了任一结构化范围字段，就必须带齐
    reviewTargets+contextReadScope，且路径/权限关系先过词法校验，不过不发。
    不带结构化字段的纯正文派单（历史探针等）不受影响。返回 error dict 或 None。"""
    if name not in ("start_review", "start_run") or not isinstance(args, dict):
        return None
    if not any(args.get(f) for f in _STRUCTURED_FIELDS):
        return None
    if not args.get("reviewTargets") or not args.get("contextReadScope"):
        return {"_error": "manifest gate: reviewTargets and contextReadScope are both required "
                          "when a structured task scope is supplied", "_manifest_gate": True}
    mode = "read-only" if name == "start_review" else (args.get("permissionPreset") or "workspace-write")
    if mode not in ("read-only", "workspace-write", "danger-full-access"):
        mode = "workspace-write"
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from build_task_manifest import validate_paths
        validate_paths(paths=list(args.get("reviewTargets") or []),
                       context_paths=list(args.get("contextReadScope") or []),
                       exclude_paths=list(args.get("excludedPaths") or []),
                       write_paths=list(args.get("writeScope") or []),
                       permission_mode=mode)
    except Exception as e:
        return {"_error": f"manifest gate: {e}", "_manifest_gate": True}
    return None

_PROVIDER_ALIASES = {"wb2api": "wb2api-nas"}  # 2026-11-13 接管后改名，旧名派单会被服务端拒
_SCOPE_FIELDS = ("reviewTargets", "contextReadScope", "writeScope")
_DEFAULT_EXCLUDED = (".git", ".env", ".credentials.yaml")

def _normalize_and_preflight(st, name, args):
    """派发前自修复（2026-11-13 LEE 定：同类错误不许再犯，全部在客户端机械兜底）：
    ① provider 旧名自动映射现行名；② start_review 自动补 authorizationBasis；
    ③ 范围路径规范化：工作区内绝对路径转相对、默认排除项（.git 等）从范围里摘除；
    ④ 模型预检：查 list_capabilities 核对 provider/model 是否可路由，不对就先报清再发，
       不让服务端回不透明的 model-unavailable。
    返回 (args, notes)；致命问题返回 error dict。"""
    notes = []
    args = dict(args)
    prov = args.get("provider")
    if prov in _PROVIDER_ALIASES:
        args["provider"] = _PROVIDER_ALIASES[prov]
        notes.append(f"provider 别名映射：{prov} → {args['provider']}（旧名已退役）")
    if name == "start_review" and not args.get("authorizationBasis"):
        args["authorizationBasis"] = "explicit-user-request"
        notes.append("已自动补 authorizationBasis=explicit-user-request（start_review 必填）")
    ws = str(args.get("workspace") or "").rstrip("\\/")
    for f in _SCOPE_FIELDS:
        vals = args.get(f)
        if not isinstance(vals, list):
            continue
        fixed = []
        for p in vals:
            s = str(p)
            if ws and s.lower().startswith(ws.lower()) and s[len(ws):len(ws) + 1] in ("\\", "/"):
                rel = s[len(ws) + 1:].replace("\\", "/")
                notes.append(f"{f}：绝对路径转相对 {s} → {rel}")
                s = rel
            if s in _DEFAULT_EXCLUDED or s.split("/")[0] in _DEFAULT_EXCLUDED:
                notes.append(f"{f}：摘除默认排除项 {s}（不可作范围目标）")
                continue
            fixed.append(s)
        args[f] = fixed
    if name == "start_run" and args.get("writeScope") and (
            not args.get("reviewTargets") or not args.get("contextReadScope")):
        args["reviewTargets"] = args.get("reviewTargets") or list(args["writeScope"])
        args["contextReadScope"] = args.get("contextReadScope") or list(args["writeScope"])
        notes.append("start_run 带 writeScope 时自动以其补齐 reviewTargets/contextReadScope（读范围至少覆盖写目标）")
    if args.get("provider") or args.get("model"):
        try:
            caps = call(st, "list_capabilities", {}, timeout=60, _skip_preflight=True)
            models = (caps or {}).get("models") or {}
            routable = models.get("routableProviders") or []
            by_provider = {}
            for g in models.get("groups") or []:
                by_provider[g.get("id")] = [m.get("id") for m in g.get("models") or []]
            prov = args.get("provider")
            if prov and routable and prov not in routable and prov not in by_provider:
                return {"_error": f"preflight: provider {prov!r} 当前不可路由；可路由：{routable}",
                        "_preflight": True, "_client_notes": notes}
            model = args.get("model")
            if prov and model and prov in by_provider and model not in by_provider[prov]:
                return {"_error": f"preflight: 模型 {model!r} 不在 provider {prov} 下；该 provider 可用：{by_provider[prov]}",
                        "_preflight": True, "_client_notes": notes}
        except Exception as e:
            notes.append(f"模型预检跳过（能力表读取失败：{str(e)[:80]}）")
    return args, notes

_id = [100]
def _looks_auth_error(out):
    if not isinstance(out, dict) or "_error" not in out: return False
    s = json.dumps(out["_error"], ensure_ascii=False).lower()
    return ("401" in s or "unauthorized" in s or "invalid_token" in s
            or "token expired" in s or "token_expired" in s)

def call(st, name, args=None, timeout=70, _auth_retried=False, _skip_preflight=False):
    args = dict(args or {})
    notes = []
    if name in ("start_review", "start_run") and not _skip_preflight:
        pf = _normalize_and_preflight(st, name, args)
        if isinstance(pf, dict):
            return pf
        args, notes = pf
    gate = _manifest_gate(name, args)
    if gate is not None:
        if notes: gate["_client_notes"] = notes
        return gate
    _id[0] += 1
    d = http_post(st["base"] + "/mcp", {"jsonrpc": "2.0", "id": _id[0], "method": "tools/call",
                                        "params": {"name": name, "arguments": args or {}}}, st["access_token"], timeout)
    if "error" in d:
        err = {"_error": d["error"]}
        # 竞态兜底：别的进程刚轮换过 token、本进程手里是旧 access → 重读最新状态重试一次
        if _looks_auth_error(err) and not _auth_retried:
            fresh = ensure_token(load())
            st.update(fresh)
            return call(st, name, args, timeout, _auth_retried=True, _skip_preflight=True)
        if notes: err["_client_notes"] = notes
        return err
    c = (d.get("result") or {}).get("content") or []
    txt = c[0].get("text") if c else None
    if txt is None: return {"_result": d.get("result")}
    try: out = json.loads(txt)
    except Exception: out = {"_text": txt[:600]}
    # 台账：start 结果与终态回复立即落盘，避免适配器层 FORBIDDEN/expired 后无据可查
    if name in ("start_review", "start_run") and isinstance(out, dict) and out.get("runId"):
        ledger({"event": "started", "tool": name, "runId": out.get("runId"),
                "sessionId": out.get("sessionId"), "operationId": out.get("operationId"),
                "idempotencyKey": (args or {}).get("idempotencyKey")})
    if name in ("wait_run", "get_run") and isinstance(out, dict) and str(out.get("status") or "") in (
            "succeeded", "failed", "cancelled", "timeout", "orphaned"):
        ledger({"event": "terminal", "runId": out.get("runId"), "sessionId": out.get("sessionId"),
                "status": out.get("status"), "startedAt": out.get("startedAt"),
                "finishedAt": out.get("finishedAt"), "assistantText": str(out.get("assistantText") or "")[:4000]})
    if notes and isinstance(out, dict): out["_client_notes"] = notes
    return out

LEDGER = os.path.expanduser("~/workspace/dsh-study/hidden_files/runs-ledger.jsonl")
def ledger(rec):
    rec["at"] = time.strftime("%Y-%m-%dT%H:%M:%S+08:00", time.localtime())
    try:
        with open(LEDGER, "a", encoding="utf-8") as f: f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception: pass

if __name__ == "__main__":
    st = ensure_token(load())
    tool = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    if tool == "tools/list":
        _id[0] += 1
        d = http_post(st["base"] + "/mcp", {"jsonrpc": "2.0", "id": _id[0], "method": "tools/list"}, st["access_token"])
        print(json.dumps([t["name"] for t in (d.get("result") or {}).get("tools", [])], ensure_ascii=False))
    else:
        print(json.dumps(call(st, tool, args), ensure_ascii=False))
