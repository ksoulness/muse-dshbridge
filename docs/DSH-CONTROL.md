# Muse 控制 DSH：经 tailnet 8443 派发任务

云端的 Muse 如何远程调用用户 Windows 电脑上的 DSH（DeepSeek Harness）：通道结构、下令定式、派发流程与全部实测结论。配套技能文件见 `skills/dsh-relay-operation/SKILL.md`。

## 1. 通道结构

```
Muse（云电脑）
  │  HTTPS + OAuth Bearer，Tailscale 隧道
  ▼
https://win.<tailnet>.ts.net:8443        ← Tailscale Serve（tailnet-only）
  │  http://127.0.0.1:18081
  ▼
DSH-Remote-MCP 适配器（第二实例，独立 OAuth 库 state-tailnet/）
  │  Authorization: Bearer <relay-token>（本机文件，按 mtime 自动重读跟随轮换）
  ▼
DSH Relay MCP  http://127.0.0.1:3079/plugins/dsh-relay/mcp
  ▼
DSH 本体（会话按工作区原生归属）
```

### 为什么不能直连 Relay

Relay 的 `RequestPolicy.authorize` 在源码层面锁死：请求来源必须是 loopback，且 `Host` 必须在硬编码白名单 `{127.0.0.1:3079, localhost:3079}` 内，否则在校验 Bearer 之前就回 `403 HOST_REJECTED`。经 Tailscale Serve 转发时 Host 是 tailnet 主机名，必然被拒；强行改 Host 头，Serve 直接断连。**远程必须经一个跑在 Windows 本机内的适配器中介**，没有例外。

### 为什么不用公网桥

同一台机器另有公网实例（Cloudflare Tunnel → `:18080`，见 dsh-gptbridge），那是给 ChatGPT 连接器的。Muse 专用 tailnet 通道的好处：不经公网、不经第三方、客户端与令牌库完全独立，出问题互不影响。

### 适配器运维（Windows 侧）

- 计划任务 watchdog 每分钟探活，进程被杀 10 秒内自愈拉起——所以你会看到适配器进程 PID 频繁变化，**那是人为操作与自愈验证，不是崩溃**（日志无崩溃栈时不要按「不稳定」处理）
- 适配器每次调上游前按 mtime 重读 `relay-endpoint.json`，DSH 重启轮换 relay token 后自动跟随，无需人工同步
- 残留风险只有秒级窗口：DSH Web（3079）重启的 1~2 秒、token 轮换瞬间；客户端遇到空响应先等 30 秒重试

## 2. 鉴权：OAuth + 自续 token

- 适配器是 OAuth 2.1 授权服务器：`/.well-known/oauth-authorization-server`、`/register`（DCR）、`/authorize`（所有者口令 + CSRF）、`/token`（PKCE S256）、`/revoke`；scope 统一 `dsh:read`
- token 只能在 Windows 侧签发（所有者口令只有 scrypt 哈希，读不出原值；签发脚本一把跑完 register → authorize → token）
- 客户端拿到 **access（1 小时）+ refresh（30 天滚动）** 后自续：调 `/token` 用 `grant_type=refresh_token`
- **轮换纪律（源码已核，违反会全族吊销）**：每次 refresh 后旧 refresh 立即作废、旧 access 立即失效；**重放旧 refresh 会吊销整个 token 家族**。所以客户端 refresh 后必须**先把新 token 对原子落盘（600 权限文件），再继续干活**
- relay 的静态 Bearer token 永不离开 Windows，不经聊天、不进任何仓库

> ⚠️ 已知设计问题（使用前须知）：当前 scope 塌陷——单个 `dsh:read` 即可驱动 `start_run / steer_run / cancel_run`，且适配器对 `start_run` 默认注入 `danger-full-access`。派**实施类**任务前先和所有者确认权限档位；只读任务走 `start_review`（固定 read-only）不受影响。

## 3. 下令定式（用户 → Muse）+ 派发前二次确认

用户只需要一句话：

> **指派 DSH 去完成 `<任务>`**（工作区/模型没点名就走默认）

例如：「指派 DSH 去 NAS 上取一个文件」「让 DSH 在量化看下 XX」。

### 3.1 派发前确认门（2026-11-09 改版，每个新事项必过）

**旧口径已废止**：以前 Muse 收到下令就自动补齐、直接派发，不会先问用户、不问不换。废止的是这种不问直接派（默认模型本身几经变更，2026-11-10 现行定为 flash/high，见下表）；现在**改为二次确认**：

1. 收到下令后，**先只回复确认、不调任何 `start_*`**。先定好本次模型（默认 flash/high，或拟建议的允许模型，见下表），再套确认门句式（平台/模型换成本次选定的；会话状态如实注明）：

   > 将使用模型 wb2api 平台的 DeepSeek V4.1 Flash（`wb2api-nas` / `cn:deepseek-v4.1-flash` / `high`），DSH 工作区是 `E:\Code\Ops`，没问题就继续。

   会话变体（用户 2026-11-09 截图确认「就这样才是对的」）：上一条会话已归档、本轮是新事项要新开会话时，在工作区后加注说明——

   > 将使用模型 wb2api 平台的 DeepSeek V4.1 Flash（`wb2api-nas` / `cn:deepseek-v4.1-flash` / `high`），DSH 工作区是 `E:\Code\Ops`（上一条会话已归档，这轮会新开一个会话），没问题就继续。

2. 用户回「继续」→ 按确认的选型派发。用户有异议时按类型给**现查清单**让他挑，不猜、不默认替换：
   - 说换模型：当场 `list_capabilities`，**只列可推荐范围**（wb2api 全部模型 + antigravity 的 Gemini 两个），等用户指定后再派。
   - 说换目录：当场 `list_workspaces`，**只列路径在 `E:\Code\` 之下的已注册工作区**，等用户指定后再派。
3. 确认门**只对新事项的首轮派发**。同一事项的后续轮次（收敛、转实施、纠偏、补答）继承首轮已确认的模型/工作区，不再重复确认；后续要换模型或换工作区才重新过门。
4. 用户在下令的同一条消息里已经明确写了模型和/或工作区，视为已确认该项，确认门只报未定的那项；都写全了就直接报「按你写的 X/Y 派发」并执行。

| 项 | 定式（2026-11-10 现行） |
|---|---|
| 工作区 | **默认** `E:\Code\Ops`（标题 Ops）；派发前 `list_workspaces` 现查现用，注册表已重构为 12 个，旧 15 个速查表作废 |
| 模型 | **默认** `wb2api-nas / cn:deepseek-v4.1-flash / high`（2026-11-10 改定，不再按复杂度分层；flash 的 reasoningEffort 只有 `low/high/max`，无 `medium`、无 `off`、无 defaultEffort 字段，传 medium/off 必报 model-unavailable；省略该参数走上游默认，但 LEE 定默认显式传 `high` 好记）；换模型只能由 Muse 在确认门里建议、用户点头才换；只许扫/用三个平台：wb2api（`wb2api-nas`）、antigravity（Gemini 两个可自主选型）、mq-gpt（仅用户强制指定才可用）；antigravity 的 `claude-opus-5-5-low/medium/high` 同 mq-gpt，仅指定可用、绝不推荐；不可用就报告，不静默换到范围外 |
| 任务文本 | 以 `muse指派-` 开头接任务正文（忠实原话要点，只给范围/路径/验收，不贴源码） |
| 工具 | 只读/核对 → `start_review`；明确要改文件 → `start_run` 或对正会话 `reply_run` 升档（先确认权限档） |
| 会话 | **同一事项沿用同一会话**：新事项首轮才 `sessionMode: fresh`；后续轮次走 `reply_run`（可升权限档）或带原 `sessionId` 复用，不许每阶段另开新会话；`openBrowser: false` |
| 授权依据 | `authorizationBasis: explicit-user-request` + 稳定 `idempotencyKey` |

回报格式写死，每单必报：**runId、完整 sessionId、起止时间、终态、交付摘要（正文要点）、归档状态**。

## 4. 派发流程（客户端）

```
【确认门】先报模型+工作区 → 用户回「继续」（未过门不调任何 start_*）
  → doctor → list_workspaces（复核）→ list_capabilities（只扫允许三平台，确认选型）
  → 查同事项正会话（pending 登记 + 台账）：有未关闭 sessionId 就复用，不 fresh
  → start_review / start_run（新事项首轮）或 reply_run（同事项续接）
       （响应里的 runId/operationId/sessionId 立即落盘）
  → 长单三件套：pending 登记 + watcher 子代理（tools/dsh_watch.py，deadline 制）
       + per-task 5 分钟兜底 cron —— 没挂机制不许说「会跟进」
  → wait_run(timeoutMs=30000) 循环，直到终态
       succeeded | failed | cancelled | timeout | orphaned
  → 读 assistantText 自行复核（DSH 的自述 ≠ 验收通过）
       收到终态回执的那个回合必须当场续接/落实/汇报，不许只报完成再承诺下一轮
  → 整件事结束才 archive_terminal_session，并回读复核 archived:true, running:false
  → 写台账 + 按格式回报用户
```

要点：

- **wait_run 单次上限就是 30 秒**（服务端源码定死，传更大无用）；靠循环等，不是靠单次长等
- **运行时长方差极大**：同一个只读元数据问题，实测有 22 秒完成的，也有跑了 **17 分 33 秒**的（22:30:58 → 22:48:31）。总轮询窗口至少留 20 分钟
- **响应丢失 ≠ 派发失败**：start 的 HTTP 响应没回来时，请求可能已在服务端落地。先用**同一 idempotencyKey** 重放或用 `get_operation / list_runs` 对账，确认不存在才重试，**绝不换新键重派**
- MCP 端点是无状态的（每次 POST 新建 transport），客户端进程不必常驻；但**台账必须落盘**：`runs-ledger.jsonl` 记每单的 started / terminal 两行（含 assistantText 全文截断备份）

## 5. 已知的适配器层问题：`FORBIDDEN / expired`

现象：某单派发成功、DSH 里也跑完了，事后 `get_run / get_run_summary / wait_run` 全部回 `-32003 FORBIDDEN, reason: "expired"`，正文读不回来。

已由源码核查定性（Relay 0.2.17）：

- 该错误**不是 Relay 发的**——Relay 里根本没有 `-32003 / FORBIDDEN`；它的 runs/operations 落盘在 `%LOCALAPPDATA%\dsh-relay\state.json`，重启恢复、无 TTL 无删除；Relay 的 `expired` 只指权限回滚租约（默认 24 小时）
- 错误来自生产适配器层（`E:\Code\Tools\DSH-Remote-MCP`）自己的校验路径；其确切失效条件待该目录代码/日志定论（该目录未注册为 DSH 工作区，远程只读不到）

应对就是第 4 节的姿势：**不等「事后取回」，在派发当场用 wait_run 循环消费到终态并落盘**。GPT 侧（公网桥）全程这么做，从未丢单。

## 6. 归档

- 工具 `archive_terminal_session { session_id: <完整 session-UUID>, confirm: true }` 是适配器本地工具（Relay 本体没有），它调 DSH Web 的归档 API
- 历史坑：适配器持有的浏览器授据失效时回 `archive_pending / HTTP_401`——属 Windows 侧 grant 问题，修复后恢复 `archived: true`
- 只归档本事项的正会话，且必须在**整个事项结束**、终态正文已消费、无后续轮次之后；事项未结束不归档（后续轮次还要复用同一会话）；归档后必须再用 `list_workspace_sessions` 回读复核 `archived: true, running: false`，只凭归档调用返回值不算验完；不按标题/日期批量归档，不动用户自己的会话
