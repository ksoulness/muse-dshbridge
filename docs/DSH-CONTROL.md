# Muse ⇄ DSH 互相指派：经 tailnet 8443 的双向实时通道

云端的 Muse 与用户 Windows 电脑上的 DSH（DeepSeek Harness）如何**互相指派任务**：正向（Muse → DSH）经 8443 适配器派发 + 终态门铃推送跟进；反向（DSH → Muse）经队列入队 + ntfy 门铃唤醒 + 8443 取单。通道结构、下令定式、双向流程与全部实测结论都在本篇，配套技能文件见 `skills/dsh-relay-operation/SKILL.md`。

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

## 3. 下令定式（用户 → Muse）

用户只需要一句话：

> **指派 DSH 去完成 `<任务>`**（工作区/模型没点名就走默认）

例如：「指派 DSH 去 NAS 上取一个文件」「让 DSH 在量化看下 XX」。

### 3.1 选型与派发（2026-11-13 改定：确认门取消、自主选型直接派）

**旧口径已废止**：2026-11-09 起每个新事项要先过确认门（先报模型+工作区、等用户回「继续」才派），2026-11-10 定默认 flash/high + 分层建议制。**2026-11-13 用户改定：确认门取消。** 现行做法：

1. 收到下令后，Muse **按任务复杂度自主选型、直接派发**，不调任何确认流程。选型调色板：默认只在 wb2api 的 `cn:deepseek-v4.1-flash` 与 `cn:deepseek-v4-pro` 之间选，档位自定（分层参考：简单/常规 → flash 的 `low`/`high`；标准/复杂 → v4-pro 的 `medium` 起，最难升 `high`/`max`；需要换家族视角 → antigravity 的 Gemini 两个也可自主选）。档位必须按所选模型自己的 capabilities 清单选（flash 只有 `low/high/max`，无 `medium`、无 `off`；Gemini 只有 `low/medium/high`）。
2. **派发回报与结果汇报里写明本次选型**（模型/档位/工作区/会话新开还是沿用）。用户对选型有异议会当场纠正，按纠正调整后续轮次，不因此恢复逐单确认。
3. 硬范围不变：只许扫/用三个平台（wb2api、antigravity、mq-gpt）；mq-gpt 全部模型与 antigravity 的 `claude-opus-5-5-low/medium/high` **仅用户强制指定才可用、绝不推荐绝不自主选**；某模型不可用就报告，不静默换到范围外。
4. 用户在下令时点名了模型和/或工作区，按点名走；工作区没点名走默认 `E:\Code\muse`。

| 项 | 定式（2026-11-13 现行） |
|---|---|
| 工作区 | **默认** `E:\Code\muse`（标题 muse，互派专区，2026-11-13 改定）；派发前 `list_workspaces` 现查现用，用户点名其他工作区按点名走 |
| 模型 | Muse 在 wb2api 的 `cn:deepseek-v4.1-flash` / `cn:deepseek-v4-pro` 间按复杂度**自主选型、档位自定、直接派发**（确认门已取消）；换家族视角可自主选 antigravity 的 Gemini 两个；只许扫/用三个平台：wb2api（`wb2api-nas`）、antigravity、mq-gpt（仅用户强制指定才可用）；antigravity 的 `claude-opus-5-5-low/medium/high` 同 mq-gpt，仅指定可用、绝不推荐；档位逐模型各查各的（flash 只有 `low/high/max`、无 `medium/off`；Gemini 只有 `low/medium/high`）；不可用就报告，不静默换到范围外 |
| 任务文本 | 以 `muse指派-` 开头接任务正文（忠实原话要点，只给范围/路径/验收，不贴源码） |
| 工具 | 只读/核对 → `start_review`；明确要改文件 → `start_run` 或对正会话 `reply_run` 升档（先确认权限档） |
| 会话 | **同一事项沿用同一会话**：新事项首轮才 `sessionMode: fresh`；后续轮次走 `reply_run`（可升权限档）或带原 `sessionId` 复用，不许每阶段另开新会话；`openBrowser: false` |
| 授权依据 | `authorizationBasis: explicit-user-request` + 稳定 `idempotencyKey` |

回报格式写死，每单必报：**runId、完整 sessionId、起止时间、终态、交付摘要（正文要点）、归档状态**。

## 4. 派发流程（客户端）

```
【选型】按复杂度在 flash / v4-pro 间自选（点名按点名），直接派发、回报写明选型
  → doctor → list_workspaces（复核）→ list_capabilities（只扫允许三平台，确认选型可用）
  → 查同事项正会话（pending 登记 + 台账）：有未关闭 sessionId 就复用，不 fresh
  → start_review / start_run（新事项首轮）或 reply_run（同事项续接）
       （响应里的 runId/operationId/sessionId 立即落盘）
  → 长单三件套：pending 登记 + 铃驱动 watcher 子代理（tools/watch_run_event.py，deadline 制）
       + per-task 5 分钟兜底 cron —— 没挂机制不许说「会跟进」
  → relay 终态门铃到达本地账本（muse-run-events → 守护进程落盘），watcher 取回终态
       succeeded | failed | cancelled | timeout | orphaned
       （门铃失效才降级：dsh_watch.py 循环 wait_run(timeoutMs=30000)）
  → 读 assistantText 自行复核（DSH 的自述 ≠ 验收通过；实施类必须附日志原文证据）
       收到终态回执的那个回合必须当场续接/落实/汇报，不许只报完成再承诺下一轮
  → 整件事结束才 archive_terminal_session，并回读复核 archived:true, running:false
  → 写台账 + 按格式回报用户
```

要点：

- **终态门铃（2026-11-13 建成）**：relay 运行包内加 5 秒 poll loop，对终态 run 调 `__fireMuseRunDoorbells` 发铃到自托管 ntfy 的 `muse-run-events`（POST 用 node:http 短连接、不用 fetch——fetch 会被 Windows 的 HTTP_PROXY 劫持）；放行条件 = serviceId 白名单或 task 以 `muse指派` 开头；去重 Set 只在进程内存，**relay 重启会把存量终态单重发一遍铃**，消费侧按 runId + 状态去重。第一版曾把发铃挂在事件流路径上，因宿主 `supportsEventStreams()` 恒 false 成了死代码——挂钩前先验触发路径真的会跑
- **wait_run 单次上限就是 30 秒**（服务端源码定死，传更大无用）；降级轮询时靠循环等，不是靠单次长等
- **运行时长方差极大**：同一个只读元数据问题，实测有 22 秒完成的，也有跑了 **17 分 33 秒**的（22:30:58 → 22:48:31）。总轮询窗口至少留 20 分钟
- **响应丢失 ≠ 派发失败**：start 的 HTTP 响应没回来时，请求可能已在服务端落地。先用**同一 idempotencyKey** 重放或用 `get_operation / list_runs` 对账，确认不存在才重试，**绝不换新键重派**
- MCP 端点是无状态的（每次 POST 新建 transport），客户端进程不必常驻；但**台账必须落盘**：`runs-ledger.jsonl` 记每单的 started / terminal 两行（含 assistantText 全文截断备份）

## 5. 已知的适配器层问题：`FORBIDDEN / expired`

现象：某单派发成功、DSH 里也跑完了，事后 `get_run / get_run_summary / wait_run` 全部回 `-32003 FORBIDDEN, reason: "expired"`，正文读不回来。

已由源码核查定性（Relay 0.2.17）：

- 该错误**不是 Relay 发的**——Relay 里根本没有 `-32003 / FORBIDDEN`；它的 runs/operations 落盘在 `%LOCALAPPDATA%\dsh-relay\state.json`，重启恢复、无 TTL 无删除；Relay 的 `expired` 只指权限回滚租约（默认 24 小时）
- 错误来自生产适配器层（`E:\Code\Tools\DSH-Remote-MCP`）自己的校验路径；其确切失效条件待该目录代码/日志定论（该目录未注册为 DSH 工作区，远程只读不到）

应对就是第 4 节的姿势：**不等「事后取回」，在派发当场用 wait_run 循环消费到终态并落盘**。GPT 侧（公网桥）全程这么做，从未丢单。

**2026-11-13 补充**：relay 重启窗口内（约数分钟）8443 会整体回 FORBIDDEN/expired、连 `tools/list` 都为空，重启完成即自愈、工具面全回——这段是「读不到」，不是「确认还在跑」，不要在窗口里下结论。终态门铃建成后，主跟进路径不再依赖事后取回（铃 + 账本在本地），该问题只剩降级轮询时才相关。

## 6. 归档

- 工具 `archive_terminal_session { session_id: <完整 session-UUID>, confirm: true }` 是适配器本地工具（Relay 本体没有），它调 DSH Web 的归档 API
- 历史坑：适配器持有的浏览器授据失效时回 `archive_pending / HTTP_401`——属 Windows 侧 grant 问题，修复后恢复 `archived: true`
- 只归档本事项的正会话，且必须在**整个事项结束**、终态正文已消费、无后续轮次之后；事项未结束不归档（后续轮次还要复用同一会话）；归档后必须再用 `list_workspace_sessions` 回读复核 `archived: true, running: false`，只凭归档调用返回值不算验完；不按标题/日期批量归档，不动用户自己的会话

## 7. 反向通道（DSH → Muse)：队列 + 门铃 + pickup（2026-11-13 建成）

正向通道解决「Muse 派得出去」；反向解决「DSH 派得回来」。为什么不用「Muse 当 MCP 服务端让 DSH 直连」：Muse 的运行环境是受限容器、tailnet 只有出站客户端能力，接不了入站连接——反向必须用「DSH 入队 + 门铃，Muse 自取」的形态。

### 7.1 DSH 侧入口：muse-dshbridge 技能（是技能，不是插件）

- DSH 侧装有一个名为 `muse-dshbridge` 的**技能**（SKILL.md，位于 DSH 的技能目录 `agents-home\skills\muse-dshbridge\`；原名 ask-muse，2026-11-13 更名为与本项目同名，协议口径未随改名变动；v3.0.0 起默认走实时通道）。用户在 DSH 侧说「问 Muse / 让 Muse 查 / 给 Muse 派活」，DSH 即按技能投单：调入队脚本 `submit-task.mjs submit <type> <title> <body>`。
- 入队脚本三步：①**机密扫描**（body 与 title 过凭据模式，命中即拒）；②任务文件**原子写入**队列 `pending/`（先写 `.tmp` 再改名，防读到半截）；③往 ntfy 的 `muse-doorbell` topic POST 一条**只带任务 id** 的门铃。发布须用 node:http 短连接（agent:false）走 tailnet 直连——经 tailscale serve 的 HTTPS 地址发布会因 Windows schannel 握手失败，fetch 还会被系统代理劫持。
- 任务 id 格式沿用 GitHub 兜底协议：`<yyyymmdd>-<hhmmss>-<slug>-<4 位随机>`；回执四型 accept / edit / respond / ignore 的语义也与兜底协议一致。

### 7.2 队列与适配器工具（Windows 侧）

- 队列落在互派专区 `E:\Code\muse\queue\{pending,done}`（该目录已注册为 DSH 工作区，队列、回执、双方的调研/报告都归一处）。
- 适配器 `delegation.mjs` 提供三个本地工具（经 8443 暴露，与派发工具同一通道）：`pickup {id}` 取走并返回条目全文（取走不删，服务端以 `done/` 判已办，天然幂等）、`report {id, resolution, status, evidence}` 写回执到 `done/<id>.result.json`（二次 report 回 `already_reported`）、`status` 查队列深度与最老条目年龄。
- 工具注解教训：MCP 工具的只读提示要**逐工具**设（三工具均只读语义也只改它们自己）——曾把整个工具集的注解统一改掉，波及了 `start_run` 等写工具的可用性。

### 7.3 Muse 侧：守护进程 + 唤醒 hook

- **订阅守护进程**：仅出站订阅自托管 ntfy 的两条流——`muse-doorbell`（反向新单）与 `muse-run-events`（正向终态铃）；收到即落本地账本（JSONL），断线带 `since` 补投（ntfy 服务端缓存 12 小时），单实例 flock；独立看门狗 hook 每 60 秒保活，拉起失败才告警。
- **推送服务选型实测**（2026-11-13 调研 8 个现役通道）：只有这台自托管 ntfy 合格——匿名开放、仅 tailnet 可达、SSE/WS/JSON 订阅全通、带缓存补投。其余候选各有硬伤：某兼容层消息流不按 token 隔离、某镜像已退网、IM 类通道要么没有 webhook 入口要么唤不醒 agent。
- **唤醒 hook**（10 秒周期）：扫账本检出新单，先标 woken 再唤醒主会话（防重复唤醒有兜底重唤醒窗口）；唤醒后 Muse 调 `pickup` 取正文。

### 7.4 处理协议（2026-11-13 改定：门铃单自动接受）

1. **Muse 自行 accept 并执行**门铃单正文，不再逐单向用户汇报等回执；执行后按重要程度简报结果（常规单简报即可，失败/异常才展开）。
2. **硬卡点仍先报用户批准**：付款/支付、凭据、删除与不可逆改动、在任何机器上新增程序/新任务线/换用途（2026-11-03 规矩）、明显超出单子本身范围的扩张。
3. 执行完调 `report` 落回执、本地账本标 done。pickup 查无此 id（测试铃/已处理）就标 done 一句带过。
4. **GitHub 私有收件箱是兜底不是主路**：实时通道不可用或用户点名时 DSH 才走 GitHub 投单；兜底单**仍逐单确认门**（先报用户、批准后才执行），与门铃单的自动接受严格区分。同一 id 两边都出现时只处理一次（先到为准、另一边标 done）。

### 7.5 延迟口径（实测基线）

- DSH 入队 → 守护进程落盘：约 1~6 秒；唤醒 hook 周期 10 秒；端到端约 10~35 秒到用户眼前。
- 终态铃（正向）见第 4 节要点：新鲜单端到端 6~8 秒。
