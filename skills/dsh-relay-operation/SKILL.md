---
name: dsh-relay-operation
description: "通过 tailnet 直连用户 Windows 电脑上的 DSH（DeepSeek Harness）Relay MCP 端点派发、监控、验收和归档任务。学自 ksoulness/dsh-codex-kit 与 ksoulness/dsh-gptbridge。用户要求调用 DSH、在其电脑上安排 DSH 任务时使用。"
---

# 操作 DSH（经 tailnet 直连 Relay MCP）

## 用户下令方式与定式（2026-10-20 用户定，最重要，先读这节）

用户通常这样下令：「在 **主机NAS** 里调用 DSH 执行 XX」「让 DSH 在 **量化** 看下 XX」「在 `E:\Code\DSH` 里让 DSH 做 XX」——即 **工作区（标题或路径）+ 任务**，其余全部按下面定式自动补齐，不要反问：

- **工作区解析**：按标题或路径对下表（派发前用 `list_workspaces` 复核该路径仍在册，不在册就报告、不猜）：

  | 标题 | 路径 | 标题 | 路径 |
  |---|---|---|---|
  | 主机NAS | `E:\Code\主机NAS` | 量化 | `E:\Code\poly` |
  | DSH | `E:\Code\DSH` | 合约 | `E:\Code\perp` |
  | 商城 | `E:\Code\商城` | 套利 | `E:\Code\arbitrage` |
  | BRAINqunat | `E:\Code\BRAINqunat` | IM | `E:\Code\DSH\IM` |
  | VPN | `E:\Code\VPN` | case-desk | `E:\Code\case-desk` |
  | 自媒体 | `E:\Code\自媒体` | tkcrx | `E:\Code\商城\tkcrx` |
  | 小说 | `E:\Code\小说` | DevSpace | `E:\Code\Tools\DevSpace` |
  | 狗头军师 | `E:\Code\狗头军师` | | |

- **模型固定，不问不换**：provider `wb2api-nas`、model `cn:deepseek-v4.1-flash`（用户明示默认永远是它）。`reasoningEffort` 取 `list_capabilities` 的默认（缺省 `low`）。模型不可用就如实报告，**不静默换其他 provider/model**。
- **定式参数**：task 以 `muse指派-` 开头接任务正文（正文忠实于用户原话要点，不自行扩大范围、不贴源码）；`sessionMode: "fresh"`、`openBrowser: false`、`authorizationBasis: "explicit-user-request"`、稳定 `idempotencyKey`。只读/核对/调研 → `start_review`（read-only）；用户明确要改文件/执行实施 → `start_run`（派发前按适配器现状确认权限档，见安全边界）。
- **执行工具**：`~/workspace/dsh-study/tools/dsh_client.py`（已内置：从 600 隐藏文件读 token、过期自动 refresh 并原子落盘新对、长超时、空响应自动重试）。不要再手拼 curl。
- **回报格式（每次必报）**：runId、完整 sessionId、起止时间（北京时间）、终态、交付摘要（assistantText 要点，自己复核过）、归档状态（archived:true 或 archive_pending+原因）。

## 连接模型（已核源码，2026-10-20）

- DSH Web 监听用户 Windows 本机 `127.0.0.1:3079`；其内嵌 relay 插件的 MCP 路由为 `/plugins/dsh-relay/mcp`，即上游 `http://127.0.0.1:3079/plugins/dsh-relay/mcp`。
- relay 启动时把描述符写到 `<DSH安装目录>\plugins\dsh-relay\<profile>\relay-endpoint.json`（gptbridge 脚本里的默认位置示例：`D:\Program Files\DSH\plugins\dsh-relay\web\relay-endpoint.json`）。描述符字段：`schemaVersion:1, authorityId, mode(embedded|standalone), mcpUrl, tokenFilePath, hostWebUrl, ownerEpoch, updatedAt`。
- 鉴权：静态 Bearer。token 明文在 `tokenFilePath` 指向的文件里，客户端发 `Authorization: Bearer <token>`。DSH 重启会轮换 token。
- **relay 直连远程客户端在源码层面被锁死**（2026-10-20 实测+读码确认）：`RequestPolicy.authorize` 要求请求来源为 loopback、且 `Host` 必须在硬编码白名单 `127.0.0.1:3079` / `localhost:3079`（harness-entry.ts）内，否则先回 403 `HOST_REJECTED`（在 Bearer 校验之前）。用户机上 Tailscale Serve 早已配好（`https://win.<tailnet>.ts.net / → 127.0.0.1:3079`，实测 GET / 回 401 DSH Web 鉴权页，链路是活的），但 serve 转发的 Host 是 tailnet 主机名 → relay 路径实测 403 HOST_REJECTED；强行改 Host 头 serve 直接断连。此路不通，不要再尝试绕。
- **远程正路 = gptbridge 的 OAuth 通道（已部署在用户机上）**：`https://dshmcp.ccwu.cc` → cloudflared → 本机 18080 适配器 → loopback 调 relay（适配器在本机内持 relay token、按 mtime 热更新）。2026-10-20 实测 `/.well-known/oauth-authorization-server` 回 200，issuer/authorize/token/register/revoke 齐全，PKCE S256、`token_endpoint_auth_method: none`、scope `dsh:read`。
- **优先通道（2026-10-20 晚新增，用户指定不用公网 dshmcp 时走这条）**：tailnet 专用实例 `https://win.<tailnet>.ts.net:8443` → serve(8443, tailnet-only) → 本机 `127.0.0.1:18081` 第二个适配器实例 → relay。独立 OAuth 库（`state-tailnet/`），客户端注册不与公网实例共享。助手实测：`/health` 200（17 工具）、well-known 200、无 token `/mcp` 401。
- 运维状态（2026-10-20 22:03 DSH 侧纠正，取代旧「不托管」说法）：自启 + watchdog **已落地并验证**（计划任务 `DSH-TailnetMCP-Watchdog` 每分钟 tick，杀进程后 10 秒内自愈）；upstream token **已于 21:46 改为自动跟随**（每次调上游前按 mtime 重读 relay-endpoint.json）。进程 boot/PID 频繁变化是人为操作与自愈验证（打补丁、杀进程验证、计划重启），日志无崩溃栈——**不要再把 PID 变化当作不稳定/崩溃**。真实残留风险只有秒级窗口：DSH web(3079) 重启的 1~2 秒、relay token 轮换瞬间；调用偶发 Empty reply/超时先等 30 秒重试一次再下结论。仍有效的注意项：`remote/server.mjs:91` 为放行带端口 publicUrl 改过一行正则，git pull/重装会被覆盖；scope 塌陷同公网实例（`dsh:read` 单 scope 可驱动 start_run/steer_run/cancel_run 且 run 以 danger-full-access 起跑）——派实施任务前必须与用户确认。
- token 签发：access token 只能在 Windows 侧用 owner password 走 OAuth 签发（DSH 侧脚本 `scripts\verify-8443-oauth.ps1` 一把跑完 register→authorize→token），Mac 客户端不能签发。助手需要带 token 复测时直接向用户/DSH 侧要一个 1 小时 token，不要自己尝试签发。
- Muse 的接入流程：① `POST /register` 动态注册自己的 client（redirect_uris 须 https 或 loopback http、精确匹配；8443 实例的 client_id 与公网实例不同）；② 构造 `/authorize` URL（带 PKCE challenge + `resource=<该实例>/mcp`），**owner 口令由用户本人在自己设备的浏览器授权页输入**（tailnet 地址助手的浏览器够不着，必须用户在 tailnet 内设备打开；口令绝不经聊天）；③ 浏览器 302 跳 redirect_uri 带回一次性 code（5 分钟有效），用户把跳转后地址栏完整 URL 发回（code 没有助手的 PKCE verifier 无法使用，可安全经聊天传递），助手立即用 code_verifier `POST /token` 换 access（1h）+ refresh（30d）；④ 之后 `POST /mcp` 带 `Authorization: Bearer <access>` 调工具。（此手动流程已被下面的自续安排取代，仅作原理参考。）
- **现行 token 安排（2026-10-20 22:21 用户定）**：用户一次性给出 access（1h）+ refresh（30d 滚动）对，存于 `~/workspace/dsh-study/hidden_files/oauth-state.json`（600 权限；记忆只记位置、不记值）。refresh 轮换规则（源码已核）：每次 refresh 后旧 refresh 作废、旧 access 立即失效，**重放旧 refresh 会吊销整个 token 家族**——所以 `dsh_client.py` 在 refresh 后先原子落盘新对、再继续干活。此安排仅适用于这对 OAuth token；relay 静态 bearer 的禁令不变。
- **relay token 绝不经聊天传递**（用户 2026-10-20 明确拒绝并给出理由，遵行）：该 token = 该机完整执行权（start_run 走 danger-full-access），且其机器上 session-archive 进程会把对话 transcript 复制落盘，「不存档」不成立。不要再向用户索要 relay token。

## 调用方式

标准 MCP Streamable HTTP：`POST <mcpUrl>`，头 `content-type: application/json`、`accept: application/json, text/event-stream`、`Authorization: Bearer <token>`，体为 JSON-RPC 2.0：

- `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` 列工具（relay 全量 25 个）。
- `{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"<工具>","arguments":{...}}}` 调工具；业务结果在 `result.content[0].text`，其内容是一段 JSON 字符串，需再 parse；`result.isError` 或顶层 `error` 为失败。

经 dshmcp 通道时工具面是适配器白名单子集（默认 16+1：含 start_review/start_run/wait_run/steer_run/reply_run/cancel_run/reconcile_permissions 与本地版 archive_terminal_session；无 service 运维组）。注意：适配器对 start_run 默认注入 `runPermissionPreset: danger-full-access` + enforce（config 可改），派实施任务前先与用户确认该档位。

**前缀规矩（用户 2026-10-20 定）**：Muse 指派的任务一律以 `muse指派-` 为标识。现状适配器在 mcp.mjs 里写死给 task 加 `gpt指派｜`、终态给标题加 `gpt指派-`（非配置项）；在 DSH 侧把 8443 实例前缀改成 muse指派（配置化）之前，Muse 派发时在 task 开头自带 `muse指派-`，接受短期内与适配器前缀叠加。改完后标题应为 `muse指派-<原标题>`，且 prefixTitle 的剥离正则需包含 muse指派以防叠加。

现成客户端（远程默认）：`~/workspace/dsh-study/tools/dsh_client.py`，见上节定式。旧脚本 `dsh-call.sh`（环境变量喂 relay token）仅适用于本机 loopback 场景，已弃用为远程入口。

## 工具面（relay 25 个，节选关键）

- 自检/发现：`doctor`、`setup_doctor`、`setup_plan`、`list_workspaces`、`list_workspace_sessions`、`list_capabilities`
- 派发：`start_review`（只读，权限固定 read-only）、`start_run`（实施，`permissionPreset: workspace-write`；`danger-full-access` 非经用户明确授权不用）
- 监控：`wait_run`、`get_run`、`get_run_summary`、`status_run`、`list_runs`、`read_notifications`、`open_run`
- 干预：`steer_run`（活动中纠偏）、`reply_run`（终态后同会话续接）、`cancel_run`
- 核对：`get_operation`、`reconcile_operation`、`reconcile_permissions`（权限降级卡住时按 sessionId 恢复）
- 运维（默认不用）：`start_service`/`open_service`/`list_services`/`stop_service`
- 归档：`archive_terminal_session`（relay 本身不含此工具；在 gptbridge 里是适配器本地工具、在 codex-kit 里是独立归档 MCP。直连 relay 时如无此工具，跳过归档并在交付中注明 `archive_pending: no-archive-tool-on-relay`，不得用终端/改库绕过）

## 标准作业流程（源自两仓库 skill，不得简化）

1. `list_workspaces` 按真实路径选已注册工作区；不凭调用方 cwd 猜。
2. `list_capabilities` 取真实 provider/model/reasoningEffort/权限；不猜模型标识、不静默换提供商；未约定时用其默认路由，模型不可用就报告。
3. 派发参数：`workspace`、`task`（只给范围/路径/授权/验收，**不贴源码、diff、压缩包**，由 DSH 自己读）、`provider`、`model`、`reasoningEffort`、`sessionMode: "fresh"`、`openBrowser: false`、稳定 `idempotencyKey`、`authorizationBasis: "explicit-user-request"`（仅在用户明确要求调用 DSH 时）。
   - 只读任务走 `start_review`，并给 `reviewTargets`、`contextReadScope`、`excludedPaths`（凭据、.env、浏览器存储、生产数据等）。
   - 实施任务走 `start_run` + `permissionPreset: "workspace-write"` + `writeScope` 限定写入位置；任务文本声明：保留已有改动、无 commit/push/外部消息/凭据访问/破坏性清理授权。
4. 记录返回的 `promptAdmission`、`runId`、完整 `sessionId`、`sessionReused: false`、`webUrl`。不确定是否派发成功时用 `get_operation`/原幂等键核对，最多同键重试一次，不换新键重复派发。
5. 循环 `wait_run { runId, timeoutMs: 20000 }` 直到终态：`succeeded | failed | cancelled | timeout | orphaned`。单次超时或 `hostMustCallWaitRunAgain: true` 都不是终态，继续等；运行中不宣布完成。
   - **长耗时教训（2026-10-20 实测）**：该机一个只读 run 实测跑了 17 分 33 秒（22:30:58→22:48:31）才 succeeded，且 start 调用的 HTTP 响应本身也迟迟不回。所有调用必须用长超时（start_* 与轮询单次 ≥240 秒、总轮询窗口 ≥20 分钟）；30–90 秒短超时必然读到空响应并误判失败。**响应丢失 ≠ 派发失败**：start 的响应没回来时，请求可能已在服务端落地，先用同一 idempotencyKey 经 get_operation/reconcile_operation 或按 runId/会话列表核对，确认不存在才允许同键重试，绝不换新键重派。现成客户端 `dsh_client.py` 已内置长超时与空响应重试。
   - **句柄过期教训（2026-10-20 夜实测 + GPT 侧源码核查修正）**：经 8443 派发的 run，事后 get_run/get_run_summary/wait_run 可能回 `-32003 FORBIDDEN / reason: expired`，**run 在 DSH 里正常跑完也读不回 assistantText**。GPT 侧查 Relay 0.2.17 源码证实：该错误码**不是 Relay 的**（Relay 无 -32003/FORBIDDEN；其 runs/operations 会落盘到 `%LOCALAPPDATA%\dsh-relay\state.json` 并在重启时恢复、无 TTL/删除逻辑；Relay 的 expired 仅指权限回滚租约、默认 24h）——错误来自生产 8443 适配器层（真实代码在 `E:\Code\Tools\DSH-Remote-MCP`，**未注册为 DSH 工作区**、外部只读不到，其确切失效条件未定论，勿再猜「句柄只存内存」）。可靠姿势（GPT 侧验证 + 其源码建议）：① start 前生成 idempotencyKey 并连同响应里的 runId/operationId/sessionId **立即落盘**（`dsh_client.py` 自动记 `hidden_files/runs-ledger.jsonl`）；② 用 `wait_run(timeoutMs: 30000)` 循环等终态（服务端单次上限就是 30 秒，传更大无用；MCP 端点无状态、不需常驻连接，但必须指向同一 Relay authority/state）；③ 终态立刻把 assistantText 落盘，不把「事后靠 runId 取回」当唯一保障；④ start 响应丢失用同一 idempotencyKey 重放，再用 get_operation/list_runs 对账。实例：md 计数单（runId 22e3cb35-bc06-45da-8ace-a79c23a1043a、session-42f7a707-d1bf-4385-9a2d-a9483043e762）即因此未能自取其回复，最终答案由 GPT 侧另行实测给出（主机NAS 根目录 .md 共 2 个）。
6. 读终态 `assistantText` 自行复核（只读结论核对文件/行证据；实施任务对照实际改动与测试结果）。DSH 的自述不等于验收通过。
7. 收尾：仅当本次 fresh 会话、终态结果已消费、无活动 run、用户未要求保留时，才 `archive_terminal_session { session_id: <完整 session-UUID>, confirm: true }`；`archived: true` 才算成功，否则记 `archive_pending`。不按标题/日期批量归档，不动用户自己的会话。

## 安全边界

- 路径声明（reviewTargets 等）是指令而非沙箱：范围内内容会被 DSH 发给所选模型提供商。
- `workspace-write` 碰越界写入会等人在 Windows 本机点确认，远程无人点会表现为卡住：派活前与用户约定确认方式，或缩小 writeScope。
- token = 该机代码执行入口：不落盘、不进记忆、不转发给任何第三方/子代理的持久上下文。
