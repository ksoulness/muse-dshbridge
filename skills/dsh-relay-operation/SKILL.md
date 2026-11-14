---
name: dsh-relay-operation
description: "通过 tailnet 直连用户 Windows 电脑上的 DSH（DeepSeek Harness）Relay MCP 端点派发、监控、验收和归档任务。学自 ksoulness/dsh-codex-kit 与 ksoulness/dsh-gptbridge。用户要求调用 DSH、在其电脑上安排 DSH 任务时使用。"
---

# 操作 DSH（经 tailnet 直连 Relay MCP）

## 用户下令方式与定式（2026-11-09 LEE 改版，最重要，先读这节）

用户通常这样下令：「指派 DSH 去完成 XX」「让 DSH 在 **量化** 看下 XX」——即 **任务**（工作区/模型没点名就走下面的默认），按定式补齐后**直接派发**（2026-11-13 起确认门取消，见下），派完在回报里写明本次选型。

### 允许的模型平台范围（2026-11-09 LEE 限定，硬范围）

只许用三个平台，`list_capabilities` 也只扫这三个、其他 provider 一律忽略（不列、不推荐、不用）：

| 平台（LEE 叫法） | provider id | 使用规则 |
|---|---|---|
| wb2api | `wb2api-nas` | 可自主选型（见下），默认平台 |
| antigravity | `antigravity` | Gemini 两个可自主选型；Opus 三个属「仅指定可用」（见下） |
| mq-gpt | 待确认映射：暂按 `magpie-responses`（其模型全是 `codex/gpt-*`，是清单里唯一的纯 GPT 平台；映射未经 LEE 确认，用前在回报里注明这一理解） | 「仅指定可用」（见下） |

**仅 LEE 强制指定才可用（2026-11-09 LEE 定）**：mq-gpt 的全部模型，以及 antigravity 的 `claude-opus-5-5-low` / `-medium` / `-high`。这些模型**能用，但助手绝不推荐、绝不自主选、选型和异议清单里也不主动列**；只有 LEE 在当次任务里明确点名（如「用 mq-gpt」「用 opus」）才可使用。

新平台只有 LEE 明说加入才扩围。某模型不可用就如实报告，在允许范围内换或停，**不静默换到范围外 provider/model**。

**wb2api 全模型**（2026-11-09 实查）：`cn:deepseek-v4-pro`、`cn:deepseek-v4.1-flash`（x0.11）、`cn:hy3`（x0.00）、`cn:hy4free`、`cn:glm-5.3-flash`（x0.06）、`cn:space-bunny`（x0.03）、`cn:minimax-m3.1-flash`。
**antigravity 全模型**：可推荐的只有 `gemini-4-argon`、`gemini-3.8-flash`；`claude-opus-5-5-low` / `-medium` / `-high` 仅指定可用。

### 默认值与选型（2026-11-13 LEE 改定：双模型自选、确认门取消）

- **模型调色板**：默认只在 wb2api 两个 DeepSeek 里选——`cn:deepseek-v4.1-flash` 与 `cn:deepseek-v4-pro`。**由 Muse 按任务复杂度自己评估选哪个、用什么 reasoningEffort，选完直接派，不再事前请示**；派发回报里写明选型与一句理由即可。变动等 LEE 另行通知。
- **分层参考（自主选型用）**：
  - 简单/常规（只读核对、列目录、查状态、格式化、小改动）→ flash（图快 `low`、稳妥 `high`）。
  - 标准/复杂（多文件实施、架构讨论、疑难排查、长推理）→ v4-pro（`medium`；最难的 quality-first 任务升 `high` / `max`）。
  - 需要换个家族的视角（复核另一模型的结论、长上下文梳理、Gemini 更擅长的审读类）→ 仍可自主选 antigravity `gemini-4-argon` 或 `gemini-3.8-flash`。
  - **opus 与 mq-gpt 仍是仅指定可用**（见上节硬范围，不因确认门取消而变）：LEE 当次点名才用。
- **档位必须按模型各查各的——有些模型没有 medium（硬规矩，2026-11-10 LEE 提醒 + 实查定版）**：reasoningEffort 的合法取值**逐模型不同、不可套用别家的**，派发前必须按所选模型在 `list_capabilities` 里的那一条选，清单变了以现查为准。已实查的各模型档位（2026-11-09/10）：
  - `cn:deepseek-v4.1-flash`：只有 `low` / `high` / `max`——**没有 medium、没有 off（关闭推理）**，且无 defaultEffort 字段；同组其他模型都有 off，唯独它没有，不是 relay 漏传，是上游条目本身就这样；给它传 medium/off 必报 model-unavailable（纯枚举拒绝，relay 本身没毛病）。
  - `cn:deepseek-v4-pro`、`cn:hy3`、`cn:hy4free`、`cn:glm-5.3-flash`、`cn:space-bunny`、`cn:minimax-m3.1-flash`：`off` / `low` / `medium` / `high` / `max`（这些才有 medium）。
  - antigravity `gemini-4-argon`、`gemini-3.8-flash`：只有 `low` / `medium` / `high`——没有 max、没有 off，别给它们传 max。
- **默认工作区**：`E:\Code\muse`（标题 muse，workspaceId `7357e936-cf7d-478f-8f58-ce2567493d87`，2026-11-13 LEE 改定）。用户点名其他工作区（如「在量化看」）时按点名走。工作区注册表以 `list_workspaces` 现查为准。

### 派发方式（2026-11-13 LEE 改定：确认门取消）

原「每个新事项先报模型+工作区、等 LEE 回继续才派」的确认门**已取消**。现行做法：Muse 按上节自选模型与档位、工作区走默认或用户点名，**直接派发**，并在派发回报与结果汇报里写明本次选型（模型/档位/工作区/会话新开还是沿用）。LEE 若对选型有异议会当场纠正，按纠正调整后续轮次即可，不因此恢复逐单确认。仍然有效的硬规矩不变：平台三家范围、仅指定可用模型（mq-gpt/opus）、2026-11-03 的「新增程序/新任务线/换用途先经 LEE 同意」（那是任务内容层面的同意，不是选型确认）、同一事项同一会话。

### 同一事项沿用同一会话（2026-11-09 LEE 定）

- **一件事 = 一个 DSH 会话。** 首轮派发新建会话后，把 sessionId 记为该事项的正会话（写入 pending 登记，见跟进闭环节）。之后同一事项的每一轮——讨论、收敛、转实施、纠偏、验收补问——**必须沿用这个 sessionId**，上下文连贯，不许每轮/每阶段另开新会话。2026-11-09 fleet-relay 一事就是反例：讨论一个会话、实施又 fresh 一个新会话（session-c5add557…），清单被迫整段重贴、上下文断裂，此后禁止。
- 沿用方法（已实查工具面支持）：终态后优先 `reply_run { runId: <上一轮终态 runId>, task: …, permissionPreset: <本轮所需档位> }`——`reply_run` 支持改 `permissionPreset`，所以**只读讨论转实施也走 reply_run 升档**（workspace-write / 经确认的 danger-full-access），不开新会话；`reply_run` 不可用（句柄 expired 等）时退 `start_run`/`start_review` 并带 `sessionId: <正会话>` 复用（两者的 schema 都有 sessionId + sessionMode 字段）；两种都失败才许 fresh，并必须在回报里写明复用失败的原因。
- 只有这些情况才开新会话：真正的新事项；用户明说开新对话；换到另一个工作区且事项无关。拿不准是不是同一事项时，按同一事项处理、先复用。
- 归档按事项收尾：整件事结束才归档正会话，不按轮次归档。

### 定式参数

- task 以 `muse指派-` 开头接任务正文（正文忠实于用户原话要点，不自行扩大范围、不贴源码）；`openBrowser: false`、`authorizationBasis: "explicit-user-request"`、稳定 `idempotencyKey`。首轮新会话 `sessionMode: "fresh"`；复用会话按上一节走 reply_run / 带 sessionId。只读/核对/调研 → `start_review`（read-only）；改文件/实施 → `start_run` 或 reply_run 升档（派发前按适配器现状确认权限档，见安全边界）。
- **执行工具**：`~/workspace/dsh-study/tools/dsh_client.py`（已内置：从 600 隐藏文件读 token、过期自动 refresh 并原子落盘新对、长超时、空响应自动重试）。不要再手拼 curl。
- **派发前 manifest 校验（2026-11-13 LEE 批准移植，自 dsh-codex-kit 的 `build_task_manifest.py`）**：凡派单带结构化范围（`reviewTargets`/`contextReadScope`/`excludedPaths`/`writeScope` 任一），派发前先跑 `python3 ~/workspace/dsh-study/tools/build_task_manifest.py <工作区路径> --path … --context-path … --scope <单行范围> [--permission-mode … --write-path …] --idempotency-key <本单键> --out ~/workspace/dsh-study/hidden_files/manifests/<idempotencyKey>.json` 生成清单，**清单里的四组路径原样用作派发参数**。校验器是远程词法版：只查路径规范化/逃逸、目标⊆可读范围、目标∩排除=∅、只读禁写/写模式必给写范围、scope 单行 ≤2000 字禁贴代码；工作区在 Windows、本机不验存在性（manifest 标 `existenceVerified:false`，存在性由 DSH 读盘坐实），默认排除 `.env`/`.credentials.yaml`/`.git`。校验不过＝不派发、先修范围再报。`dsh_client.py` 内置同一校验的硬门：带结构化字段却缺 `reviewTargets`/`contextReadScope` 或关系不过，会在发网络请求前直接返回 `_manifest_gate` 错误——绕过清单工具手拼参数也拦得住。不带结构化字段的纯正文派单不受硬门影响，但新派单应优先带结构化范围＋清单。
- **回报格式（每次必报）**：runId、完整 sessionId、起止时间（北京时间）、终态、交付摘要（assistantText 要点，自己复核过）、归档状态（archived:true 或 archive_pending+原因）。

## 长任务跟进闭环（2026-11-09 LEE 定，治「说了会跟进却不跟进」）

**根因（写死，别再犯）**：2026-11-13 前 DSH Relay 是纯拉模式——没有任何推送，`wait_run` 必须由 Muse 主动调；2026-11-13 晚终态门铃已通（relay 内 5 秒 poll loop 在 run 终态时往 ntfy `muse-run-events` 发铃，Muse 守护进程落盘到 `~/workspace/dsh-doorbell/state/run_events.jsonl`），watcher 改为等本地账本、不再远程轮询。无论哪种形态，主会话的回合一旦结束，就没有进程在等；口头说「回复一到我就续接第 2 轮」而不挂任何机制，等于永不续接。子代理/后台进程/cron 的完成回执才会由运行时重新投递进原会话、把主助手唤醒。所以：**没有挂上机制的等待承诺一律禁止说出口。**

派发任何预计超过约 1 分钟、或带后续轮次（收敛/实施/验收）的 run，必须在向用户说「已派发」之前，两件套全部落地：

1. **pending 登记**：写 `~/workspace/dsh-study/hidden_files/pending/<runId>.json`，字段至少含：`runId`、`sessionId`（事项正会话）、`matter`（事项一句话）、`origin_chat_id`、`stage`（如 round1-discussion）、`next_action`（终态后具体要做什么：续接的轮次与要点/要落实的修改/只需汇报，写到可直接执行）、`provider/model/workspace`、`dispatched_at`、`deadline`。
2. **watcher 子代理（2026-11-13 起改铃驱动）**：立刻 spawn 一个后台子代理，只做一件事：跑 `python3 ~/workspace/dsh-study/tools/watch_run_event.py <runId> --deadline-min <预计上限，如 90>` 并把脚本输出的终态 JSON（status + assistantText）原样带回。该脚本等本地 `run_events.jsonl` 出现该 run 的终态铃（relay 终态门铃经 ntfy 落盘），出现后才调一次 `get_run_summary` 取回终态——全程零远程轮询。铃超 deadline 未到输出 `watch_deadline_exceeded`，不当完成/失败结案，登记保留、由主会话后续回合的 pending 自检补查。子代理不做判断、不续接、不改文件。它的完成回执就是主助手的唤醒信号。派单文本只给 runId 与脚本路径——token 由脚本自己读隐藏文件，不进子代理提示词。旧脚本 `dsh_watch.py`（循环 `wait_run`）只作门铃失效时的降级备用。
2b. **跟进节奏（LEE 2026-11-14 定版，两侧同守）**：扫描不要密——前 30 分钟 **60 秒一轮**，超过 30 分钟 **5 分钟一轮**，超过 2 小时不再紧盯终态、每轮着重核一次任务**还在不在运行**（存活核对）。两个 watcher 脚本已按此实现（`watch_run_event.py` 本地账本 60s→300s；`dsh_watch.py` 周期 60s→300s＋2 小时后每轮 `get_run` 存活核对写进 `liveness`）。DSH 侧发铃 poll loop 同步为 60 秒。
3. **兜底 cron 已取消（2026-11-13 晚 LEE 定）**：终态门铃实测稳定后，per-task 的 5 分钟兜底 cron（`dsh-followup-*`）**不再建**；跟进只靠 pending 登记 + 铃驱动 watcher 两件套。watcher 异常退出或超 deadline 时，靠主会话每回合开始的 pending 自检（见本节末自检条）补上，不再另设定时任务。

**轮询形状教训（2026-11-09 fleet-relay 实测）**：那次跟进表面上靠临时后台轮询循环撑住了，但循环是「6/8/10/16 次 × 30 秒」的定次短循环，单轮只有 3–8 分钟，而 run 本身要 14–17 分钟——循环反复在 still running 时耗尽、靠不断重新拉起才没断档，实施阶段仍逼得用户发「他回复好了，你去看」。所以定次短循环**不算**挂上机制：watcher 必须以 deadline 等到终态为止（`watch_run_event.py` 的 `--deadline-min` 要 ≥ 预计时长＋余量，默认 90），耗尽未终态靠 pending 登记在后续回合自检补查。

**收到终态回执的那个回合（watcher 回执）必须当场执行 next_action**：要续接就当场 `reply_run` 沿用正会话派下一轮（并给新一轮重新挂两件套、更新登记的 runId/stage），要落实修改就当场派实施，要汇报就完整汇报。禁止在这一回合只说「第 1 轮完成了，我接下来会…」然后结束回合——那正是旧毛病。

**收尾**：事项全链结束（终轮已消费、无后续动作）→ 登记标 `closed`（或删除 pending 文件）、按事项归档正会话。watcher 到 deadline 仍未终态：登记保留、向用户如实报「仍在跑/疑似卡住」一次，不许当完成或失败结案。

**自检**：每次新回合开始处理 DSH 相关事项前，先扫 `pending/` 有没有未 closed 的登记；有且已终态未续接的，先补续接再答新话。

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
2. `list_capabilities` 取真实 provider/model/reasoningEffort/权限；不猜模型标识、不静默换提供商。扫描只看允许范围三平台（wb2api/antigravity/mq-gpt，其余 provider 忽略）。选型按首节自主选型口径（wb2api 的 flash / v4-pro 二选一为主），模型不可用就报告。
3. 派发前先查同事项正会话：扫 pending 登记 + runs-ledger，有同事项未关闭 sessionId 就复用（见「同一事项沿用同一会话」节），不 fresh。**派发前归档清扫（2026-11-13 LEE 定）**：派发脚本在调 start_\* 之前先跑 `sweep_archive.run_sweep([本单工作区])`（工具 `~/workspace/dsh-study/tools/sweep_archive.py`），把我方已终态、事项已关闭的旧会话自动归档，让 DSH 侧列表只留当前事项——清扫只认 runs-ledger 里我派出的 sessionId，跳过 running 与未关闭登记的会话；**只归我指派 DSH 的旧任务，DSH 的自有会话、DSH 指派给我的单都不归我管、不碰**。带结构化范围的派单先按「定式参数」的 manifest 校验生成清单并落盘，清单四组路径原样进派发参数，校验不过不派发。派发参数：`workspace`、`task`（只给范围/路径/授权/验收，**不贴源码、diff、压缩包**，由 DSH 自己读）、`provider`、`model`、`reasoningEffort`、`openBrowser: false`、稳定 `idempotencyKey`、`authorizationBasis: "explicit-user-request"`（仅在用户明确要求调用 DSH 时）。新事项首轮才用 `sessionMode: "fresh"`；复用走 `reply_run` 或带 `sessionId` 的 start_\*。
   - 只读任务走 `start_review`，并给 `reviewTargets`、`contextReadScope`、`excludedPaths`（凭据、.env、浏览器存储、生产数据等）。**接管后新规（2026-11-13 20:46 实测）**：`start_review` 必填 `authorizationBasis: "explicit-user-request"`，缺了直接 INVALID_PARAMS；同日 provider 已由 `wb2api` 改名为 `wb2api-nas`（模型 id 不变，仍 `cn:deepseek-v4.1-flash` / `cn:deepseek-v4-pro`），用旧名派单回 session/model-unavailable。范围路径一律工作区相对路径（如 `docs`、`queue`），绝对路径被 manifest 门拦；`.git` 在默认排除内、不可作 review target（要 git 信息在正文里让执行端跑命令）。
- **客户端已内置自修复（2026-11-13 LEE 定，同类错误不许再犯；`dsh_client.call` 在 manifest 门之前自动处理，修了什么写在返回的 `_client_notes` 里，必须回读）**：① provider 旧名 `wb2api` 自动映射 `wb2api-nas`；② `start_review` 自动补 `authorizationBasis`；③ 范围里的绝对路径自动转相对、`.git`/`.env` 等默认排除项自动摘除；④ `start_run` 只带 writeScope 时自动以其补齐 review/context 范围；⑤ 派发前查 `list_capabilities` 做模型预检，provider/model 不可路由时先报清（可路由清单）再发，不让服务端回不透明错误。2026-11-13 20:50 回归探针把五种旧错塞进一单实测：全部自动修正、一次派发成功（run 8ca6373c，19 秒终态）。
   - 实施任务走 `start_run` + `permissionPreset: "workspace-write"` + `writeScope` 限定写入位置，或对正会话 `reply_run` 升档；任务文本声明：保留已有改动、无 commit/push/外部消息/凭据访问/破坏性清理授权。
4. 记录返回的 `promptAdmission`、`runId`、完整 `sessionId`、`sessionReused`、`webUrl`，并立即写 pending 登记、挂铃驱动 watcher 子代理（见跟进闭环节）。不确定是否派发成功时用 `get_operation`/原幂等键核对，最多同键重试一次，不换新键重复派发。
5. 等待终态由铃驱动 watcher（`watch_run_event.py` 等本地 `run_events.jsonl` 的终态铃）在后台执行，主会话不空转干等、也不在无机制时结束回合假装在等。终态：`succeeded | failed | cancelled | timeout | orphaned`。单次超时或 `hostMustCallWaitRunAgain: true` 都不是终态，继续等；运行中不宣布完成。门铃失效时降级用 `dsh_watch.py` 循环 `wait_run { runId, timeoutMs: 30000 }`。
   - **长耗时教训（2026-10-20 实测）**：该机一个只读 run 实测跑了 17 分 33 秒（22:30:58→22:48:31）才 succeeded，且 start 调用的 HTTP 响应本身也迟迟不回。所有调用必须用长超时（start_* 与轮询单次 ≥240 秒、总轮询窗口 ≥20 分钟）；30–90 秒短超时必然读到空响应并误判失败。**响应丢失 ≠ 派发失败**：start 的响应没回来时，请求可能已在服务端落地，先用同一 idempotencyKey 经 get_operation/reconcile_operation 或按 runId/会话列表核对，确认不存在才允许同键重试，绝不换新键重派。现成客户端 `dsh_client.py` 已内置长超时与空响应重试。
   - **句柄过期教训（2026-10-20 夜实测 + GPT 侧源码核查修正）**：经 8443 派发的 run，事后 get_run/get_run_summary/wait_run 可能回 `-32003 FORBIDDEN / reason: expired`，**run 在 DSH 里正常跑完也读不回 assistantText**。GPT 侧查 Relay 0.2.17 源码证实：该错误码**不是 Relay 的**（Relay 无 -32003/FORBIDDEN；其 runs/operations 会落盘到 `%LOCALAPPDATA%\dsh-relay\state.json` 并在重启时恢复、无 TTL/删除逻辑；Relay 的 expired 仅指权限回滚租约、默认 24h）——错误来自生产 8443 适配器层（真实代码在 `E:\Code\Tools\DSH-Remote-MCP`，**未注册为 DSH 工作区**、外部只读不到，其确切失效条件未定论，勿再猜「句柄只存内存」）。可靠姿势（GPT 侧验证 + 其源码建议）：① start 前生成 idempotencyKey 并连同响应里的 runId/operationId/sessionId **立即落盘**（`dsh_client.py` 自动记 `hidden_files/runs-ledger.jsonl`）；② 用 `wait_run(timeoutMs: 30000)` 循环等终态（服务端单次上限就是 30 秒，传更大无用；MCP 端点无状态、不需常驻连接，但必须指向同一 Relay authority/state）；③ 终态立刻把 assistantText 落盘，不把「事后靠 runId 取回」当唯一保障；④ start 响应丢失用同一 idempotencyKey 重放，再用 get_operation/list_runs 对账。实例：md 计数单（runId 22e3cb35-bc06-45da-8ace-a79c23a1043a、session-42f7a707-d1bf-4385-9a2d-a9483043e762）即因此未能自取其回复，最终答案由 GPT 侧另行实测给出（主机NAS 根目录 .md 共 2 个）。
6. 读终态 `assistantText` 自行复核（只读结论核对文件/行证据；实施任务对照实际改动与测试结果）。DSH 的自述不等于验收通过。
7. 收尾：仅当**整个事项**已结束、正会话的终态结果已消费、无活动 run、用户未要求保留时，才 `archive_terminal_session { session_id: <正会话完整 session-UUID>, confirm: true }` 并关闭 pending 登记；`archived: true` 才算成功，否则记 `archive_pending`。归档后必须再用 `list_workspace_sessions` 回读该 sessionId 复核 `archived: true, running: false`（2026-11-09 fleet-relay 两会话即如此验过），只凭归档调用的返回值不算验完。事项未结束不归档（后续轮次还要复用）。不按标题/日期批量归档，不动用户自己的会话。**归档分工（2026-11-13 LEE 定）**：谁派的单谁归自己那侧的会话——你派给 DSH 的 run 由你自己归档并回读复核；DSH 派给你的一单里、DSH 侧为此新开的对话由 DSH 自己归档。两侧都不代对方归档。

## 安全边界

- 路径声明（reviewTargets 等）是指令而非沙箱：范围内内容会被 DSH 发给所选模型提供商。
- `workspace-write` 碰越界写入会等人在 Windows 本机点确认，远程无人点会表现为卡住：派活前与用户约定确认方式，或缩小 writeScope。
- token = 该机代码执行入口：不落盘、不进记忆、不转发给任何第三方/子代理的持久上下文。

## 反向通道（DSH→Muse，8443 pickup + ntfy 门铃，2026-11-13 第 2 轮建成）

与 GitHub 收件箱并行的实时通道：DSH 用入队口投单到适配器队列（`E:\Code\muse\queue\{pending,done}`，2026-11-13 晚自适配器 state-tailnet 迁入互派专区；`E:\Code\muse` 已注册为 DSH 工作区，workspaceId `7357e936-cf7d-478f-8f58-ce2567493d87`、标题 muse，互派通道相关的派单/调研/报告默认以它为工作区），同时往 free-vps ntfy 的 topic `muse-doorbell` 发一条只带任务 id 的门铃。DSH 侧 `muse-dshbridge` 技能（原名 ask-muse，2026-11-13 更名为与项目同名）v3.0.0 起默认走此实时通道，GitHub 私库降为兜底（入队失败/适配器不通/LEE 点名才走，仍逐单确认门）。同一 id 两边都出现时只处理一次（先到为准、另一边标 done）。

**DSH 侧联络人（2026-11-13 20:35 起）**：DSH 这头的收发、回报与车道守夜由「**Muse 联络**」bot 负责，工作区 `E:\Code\muse`。你要它做事，走 8443 的 `start_run` / `start_review`（工作区默认 `E:\Code\muse`），标题前缀「**致 Muse 联络：**」，正文写清要问什么、要什么证据；终态门铃放行仍需 task 以 `muse指派` 开头或 serviceId 在白名单。两类接管的区别（系统接管 vs Bot 接管）、两边联系定式见仓库 `docs/TAKEOVER.md`。

**Muse 侧组件**：

- 订阅守护进程 `~/workspace/dsh-doorbell/daemon.py`（仅出站订阅 `<ntfy-host>:2586/muse-doorbell/json` 流、断线带 `since` 补投、单实例 flock），收到铃落 `state/inbox.jsonl`；hook `dsh-doorbell-watchdog`（60 秒）保活，拉起失败才唤醒告警。
- 唤醒 hook `dsh-doorbell-inbox`（10 秒，delivery 为 DSH-MUSE-bridge 专用旁聊，见下节「报告去向」）：脚本 `~/hooks/scripts/dsh-doorbell-inbox.sh` 扫账本，检出先 mark woken 再唤醒；账本工具 `~/workspace/dsh-doorbell/check.py`（scan/mark，状态 new→woken→notified→done；woken 超 15 分钟未推进会兜底重唤醒一次）。
- `dsh_client.py` 已加 token 锁内重读 + flock 串行 refresh、401 重读重试（2026-11-13），多进程并发调 8443 不再怕轮换撞车。

**被唤醒后的处理协议（2026-11-13 17:38 LEE 改定：门铃单自动接受，不再逐单等回执）**：

1. 调 `pickup` 取 id 对应条目全文（pickup 取走不删、服务端以 `done/` 判已办，天然幂等）。
2. **Muse 自行 accept 并执行正文**，不再逐条向 LEE 汇报等四型回执。执行后按重要程度向 LEE 简报结果（联测/只读/常规单简报即可，失败或异常才展开）。
3. **硬卡点不自动、仍先报 LEE 批准**：付款/支付、凭据、删除与不可逆改动、在任何机器上新增程序/新任务线/换用途（2026-11-03 规矩），以及明显超出单子本身范围的扩张。GitHub 私库收件箱的兜底单不适用本节自动接受，仍走其原确认门（每单先报 LEE、批准后才执行）。
4. 执行完调 `report {id, resolution, status, evidence}` 落 `done/<id>.result.json`（二次 report 回 already_reported，不报错），本地 `mark <id> done`。
5. pickup 里查无此 id（测试铃/已处理）：mark done、一句说明，不刷屏。
6. 队列深度与最老条目年龄可调 `status` 查；门铃断档不丢件——ntfy 缓存 12 小时 + 队列在 DSH 侧常存，最坏退回 git 兜底。

延迟口径（实测基线）：发布→守护进程落盘约 1 秒（2026-11-13 自测）；唤醒 hook 周期 10 秒；端到端目标 10–35 秒到 LEE 眼前。


## 终态铃会被 DSH 升级抹掉（2026-11-14 实证）

发铃 poll loop 是打在 DSH 运行真身 bundle（`dsh-relay-harness.mjs`）上的**非版本化本地 patch**；DSH 升级/重装会把 bundle 换回干净 dist、连含 patch 的 .bak 备份一并删掉，症状＝真单终态后本地 `run_events.jsonl` 无新铃（2026-11-14 升级 0.2.2-rc.1 即如此，只读诊断确证：四符号 `__fireMuseRunDoorbells/__postMuseDoorbell/museRunDoorbellSeen/muse-run-events` 计数全 0、门铃日志停写）。处置：派只读单核四符号计数；为 0 即按工作区 `research/realtime-channel/RUNBOOK-runevents-doorbell.md` 用同目录幂等脚本 `reapply-runevents-doorbell.py` 重打（锚点失配停手不许硬打）＋重启宿主＋合成铃自验；重启后 poll loop 首轮会补发存量终态铃。每次 DSH 升级后都应主动查一次四符号，别等缺铃才发现。

## 报告去向（2026-11-13 20:50 LEE 定）

- 专用对话：Muse 侧旁聊「DSH-MUSE-bridge 任务 派发 报告 群」（Muse 内部对话，id 不入库）是 Muse⇄DSH 互相指派的派发与完成报告群。Muse→DSH 的派发回报与终态完成报告、DSH→Muse 的收单汇报与执行结果，一律发到该旁聊，**不再发主聊天**。
- 三个 DSH hook 的 delivery 已改到该旁聊：`dsh-doorbell-inbox`（10 秒）、`dsh-inbox-watch`（GitHub 兜底收件箱，5 分钟）、`dsh-doorbell-watchdog`（60 秒，门铃守护告警）。
- 新派单写 pending 登记时，`origin_chat_id` 默认写该旁聊 id，使铃驱动 watcher 的终态回执落回该旁聊；LEE 在别处下令派 DSH 时，派发与完成报告仍归该旁聊（下令处至多留一句已转该群的指路，不在主聊天展开报告）。

## 双向互派实测基线（2026-11-13 20:42–20:47 首测，两边都过）

- **DSH → Muse**：入队 20:42:46 → `report` 回执 20:47:35，合计 4 分 49 秒（含 Muse 侧两次派 run）。
- **Muse → DSH**：20:46:26 `start_review` 派发 → 20:46:46 succeeded → 终态门铃 20:46:48 落到本地 `run_events.jsonl`，单次 **27.1 秒**。
- **附带一条**：那次 run 里的 DSH agent 自发回派单 `20261113-204411-mutual-test-return-e342`，20:44:11 → Muse 20:45:34 回执（**83 秒**）。注意 run 里的 agent 会自己往 `queue/pending` 写单——不希望它自主派活就在 run 的正文里写明禁止。
- **归档复核**：两个 Muse 派出的会话在 DSH 侧 fleet 回读均 `archived: true / running: false`，归档分工真实生效。
