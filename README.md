# muse-dshbridge

把云端的 **Meta Muse**（跑在云电脑上的个人 agent）接到用户自己的两个世界里：

- **Muse → DSH 派活**：经 Tailscale 私有网络，远程调用用户 Windows 电脑上的 **DSH（DeepSeek Harness）**，在指定工作区里发起对话、执行任务、验收结果；
- **DSH → Muse 派活**（2026-11-13 建成）：DSH 侧的 `muse-dshbridge` 技能把任务入队并按响门铃，Muse 被唤醒后取单、自动执行、回执——两个 agent 自此**互相指派**，不再经 GitHub 中转、不再靠定时轮询跟进；
- **随身对话**：经腾讯官方 ClawBot 微信插件 + wx-bot 桥接，让用户在微信里直接和 Muse 聊天。

一句话：**DSH 线是一套双向实时互派系统——正向是「Muse → tailnet → OAuth 适配器 → DSH Relay」派发 + 「relay 终态门铃 → ntfy → Muse」推送跟进；反向是「DSH 入队 + ntfy 门铃 → Muse 守护进程唤醒 → 经适配器 pickup 取单」；两个方向共用一个互派专区工作区 `E:\Code\muse`。微信线是「微信 → ClawBot 协议 → wx-bot 收件箱 → 唤醒 Muse」的消息通道。** 本仓库是这些链路的**项目记录 + 操作手册 + 技能文件**：正向 2026-10-20 实测打通，双向实时 2026-11-13 建成并四轮实测验收。

```
                        ┌──────────────── 云电脑（Muse 常驻）────────────────┐
                        │  Muse 本体 ── dsh_client.py（OAuth 自续 + 台账）      │
                        │           ── doorbell daemon（订阅 ntfy 两条流落盘）    │
                        │           ── hooks（门铃唤醒 / 微信收件箱 / 看门狗）      │
                        └──────┬──────────────────────┬───────────────┬───────┘
              tailnet (Tailscale Serve :8443)   ntfy（自托管，tailnet-only）  HTTPS 长轮询（微信）
                               ▼              ▲        │               ▼
                 Windows 电脑 · DSH      终态铃        门铃        wx-bot（用户微信）
                   Relay MCP :3079     muse-run-events  muse-doorbell
                   互派专区 E:\Code\muse（队列 + 共享工作区）
                   muse-dshbridge 技能（DSH → Muse 的派活入口）
```

## 为什么需要这两条线

| 问题 | 解法 |
|---|---|
| DSH 的 Relay 只监听本机 `127.0.0.1:3079`，且源码锁死：来源必须 loopback、Host 必须在白名单内，远程直连回 `403 HOST_REJECTED` | 在 Windows 本机放一个 OAuth 适配器实例，经 **Tailscale Serve（tailnet-only :8443）** 暴露给云端 Muse；适配器在本机内持 Relay token 并自动跟随轮换 |
| Relay 只认静态 Bearer（= 该机完整执行权），不能经聊天/公网传递 | 对外只发 **OAuth access token（1 小时）+ refresh token（30 天滚动）**；客户端自续、轮换即落盘，relay token 永不离开那台 Windows |
| Muse 官方通道只有 WhatsApp，没有微信 | 腾讯官方 ClawBot 插件 + 公开协议（`ilinkai.weixin.qq.com`，扫码登录、长轮询收、接口发），用 **wx-bot** 桥接到 Muse 的收件箱/hook 机制 |

## 特性

**DSH 线（正向：Muse → DSH）**
- **下令定式（2026-11-13 改定：确认门取消、选型自主）**：用户说「指派 DSH 去完成 `<任务>`」，Muse 在 wb2api 的 DeepSeek V4.1 Flash 与 V4 Pro 之间按复杂度自选模型与推理档位、**直接派发**，并在回报里写明本次选型；默认工作区 `E:\Code\muse`（互派专区），用户点名其他工作区时按点名走。平台范围仍只许三家（wb2api / antigravity / mq-gpt），其中 mq-gpt 全部模型与 antigravity 的 Opus 仅用户强制指定才可用、绝不自主选；任务前缀 `muse指派-`、同一事项沿用同一会话、只读走 `start_review`、稳定幂等键。旧口径「派发前先过确认门、等用户回继续」已于 2026-11-13 废止。见 [docs/DSH-CONTROL.md](docs/DSH-CONTROL.md)
- **终态门铃（2026-11-13 建成，跟进从拉改推）**：relay 内加一个 5 秒 poll loop，run 到终态（succeeded / incomplete / failed / cancelled）即往自托管 ntfy 的 `muse-run-events` topic 发一条铃（runId / sessionId / 状态）；放行条件是 serviceId 白名单或任务以 `muse指派` 开头。Muse 侧守护进程订阅落盘，watcher 改等本地账本（`tools/watch_run_event.py`，零远程轮询），铃到才取一次终态正文；跟进只靠 pending 登记 + 铃驱动 watcher 两件套（per-task 兜底 cron 已于 2026-11-13 晚取消不再建，门铃已稳定）。实测新鲜单端到端 6~8 秒（DSH 侧发铃 <2 秒，其余是 ntfy 送达）
- **长任务可靠姿势**：终态正文立即落盘，run 台账（runId / sessionId / 幂等键 / 起止 / 正文）自动记入本地 ledger；`wait_run` 轮询只作门铃失效时的降级备用
- **token 自续**：access 过期自动用 refresh 轮换，新 token 对原子落盘（600 权限）；旧 refresh 重放会吊销整族，所以永远先落盘再干活
- **验收闭环**：派发（长单先挂 pending 登记 + 铃驱动 watcher 两件套）→ 铃到取终态 → 读 `assistantText` 自行复核（**实施类单子必须附日志原文证据，自报结论不算数**——2026-11-13 四轮实测的教训，见下）→ 整件事结束才归档正会话并回读复核（`archived: true, running: false` 才算数）→ 按固定格式回报

**DSH 线（反向：DSH → Muse，2026-11-13 建成）**
- **入口是技能，不是插件**：DSH 侧装了一个名为 `muse-dshbridge` 的**技能**（v3.0.0，位于 DSH 的技能目录 `agents-home\skills\muse-dshbridge\`；2026-11-13 由原名 ask-muse 更名，与本项目同名同源）；用户在 DSH 侧说「问 Muse / 让 Muse 查 / 给 Muse 派活」，DSH 即走该技能投单
- **入队 + 门铃**：入队脚本先做机密扫描，再把任务原子写入互派专区队列 `E:\Code\muse\queue\{pending,done}`，同时往 ntfy 的 `muse-doorbell` topic 发一条**只带任务 id** 的门铃（正文不走 ntfy，经 8443 取）
- **取单 + 自动接受**：Muse 侧守护进程收到铃落盘，唤醒 hook 约 10 秒内叫醒主会话；Muse 经适配器的 `pickup` 工具取正文，**自行 accept 并执行**（2026-11-13 改定，不再逐单等用户回执），办完调 `report` 回执落 `done/`；硬卡点不自动——付款/支付、凭据、删除与不可逆改动、在任何机器上新增程序/新任务线/换用途，仍先报用户批准
- **GitHub 私有收件箱降为兜底**：实时通道不可用（入队失败/适配器不通）或用户点名时才走 GitHub 私库投单，仍逐单确认门；同一 id 两边都出现只处理一次。门铃断档不丢件：ntfy 缓存 12 小时 + 队列在 DSH 侧常存

**微信线**
- **纯官方协议**：ClawBot 插件扫码绑定，`getUpdates` 长轮询收消息、`sendMessage` 发消息，全程 HTTPS，不碰任何非官方 Hook
- **常驻自愈**：wx-bot 以 systemd 服务运行；收件箱 hook 5 秒轮询唤醒 Muse；watchdog hook 在云 VM 被替换、`/etc` 被清空时自动重装服务（unit 缺失走快速分支、不等失败计数，实测 38 秒恢复）；并诚实标注边界——运行环境整体停摆时，机内自愈会一起失效，只能靠机外死亡开关发现（见 docs/WECHAT-BRIDGE.md 坑四）
- **绑定风控解法**：云机房 IP 绑定会被腾讯风控拦——只在绑定阶段经 tailnet 借家庭网络出口扫码，通过后切回直连（实测收发均正常）

## 快速开始

**DSH 线**（详见 [docs/DSH-CONTROL.md](docs/DSH-CONTROL.md)）

1. Windows 侧：DSH 运行中（Relay 插件启用）；适配器起第二个实例监听本机 `:18081`（独立 OAuth 库），`tailscale serve` 把 tailnet 的 `:8443` 指给它
2. 云端：客户端向 `:8443` 动态注册（DCR），所有者在本机浏览器走完 OAuth 授权（口令只在本机输），拿到 access + refresh 对
3. 反向与门铃（Windows 侧）：适配器加三个本地工具 `pickup / report / status` + 建队列目录（落在互派专区工作区 `E:\Code\muse\queue`，该工作区先注册好）；relay 运行包里加终态门铃 poll 钩子（改前留备份）；DSH 侧装 `muse-dshbridge` 技能（入队脚本 + 发门铃）
4. 云端：跑门铃守护进程（订阅自托管 ntfy 的 `muse-doorbell` 与 `muse-run-events` 两条流、落盘、断线带 `since` 补投）+ 唤醒 hook（约 10 秒）+ 守护进程看门狗
5. 之后双向都走技能手册：`skills/dsh-relay-operation/SKILL.md` —— 把它交给 Muse，它就会按定式双向派活

**微信线**（详见 [docs/WECHAT-BRIDGE.md](docs/WECHAT-BRIDGE.md)）

1. 微信里装 ClawBot 插件（我 → 设置 → 插件）
2. 云电脑装 wx-bot 单文件二进制，写 pull 模式配置（binding 名 `muse`）
3. 扫码绑定（云 IP 先借家庭出口过风控），装 systemd 服务 + 收件箱 hook + watchdog hook，health 退出码 0 验收

## 三大部分

两条链路的经验按主题收进三个专属文件夹，每部分独立成章：

| 部分 | 文件夹 | 内容 |
|---|---|---|
| 一、微信链的优化 | [wechat-optimization/](wechat-optimization/) | 上下文连贯 + 对话隔离（ctx.py）、stallwatch 10 分钟误报刷屏的补丁修复、systemd 模板修复、hook 轮询与自愈（unit 缺失快速分支）、无声断线的机外死亡开关备选设计、通知与回复规矩 |
| 二、第一次连接微信出问题怎么办 | [wechat-first-connect/](wechat-first-connect/) | 前置清单、扫码绑定被腾讯风控拦（运行环境存在风险）的解法、health 非 0、登录过期 `expired / -14`、`no context_token`、消息重复唤醒、二维码旧码缓存、云 VM 替换丢服务、接通验收标准 |
| 三、DSH 的连接 | [dsh-connection/](dsh-connection/) | 通道结构（8443 tailnet-only → 适配器 → Relay）、为什么不能直连 Relay、OAuth 建连三步、token 自续轮换纪律、客户端与派发流程、`FORBIDDEN / expired` 适配器层问题、安全边界 |

`docs/` 下的原有方法文档（`DSH-CONTROL.md`、`WECHAT-BRIDGE.md`、`TROUBLESHOOTING.md`
等）仍保留，被这三个文件夹引用，不重复写。

## 实测记录（2026-11-13）

- **双向实时互派建成**：DSH → Muse 联测单入队 → 守护进程约 6 秒落盘 → 唤醒 → pickup 取单 → report 回执 → 队列归零，全程秒级，不再经 GitHub 中转
- **互派专区归一**：`E:\Code\muse` 建成并注册为 DSH 工作区（标题 muse），队列、回执、调研报告都归一处；正向默认工作区同步改到这里。自此正反两向是同一套系统、同一份记录，不再分开维护
- **终态门铃四轮才通**：第 1 轮把铃挂在宿主的事件流路径上——该路径的前置开关 `supportsEventStreams()` 在 DSH 宿主里恒为 false，钩子是死代码，真单全漏；第 2 轮自报的根因（relay 从未重启）被日志证伪（当日实际重启多次）；第 3 轮改 5 秒 poll loop 并定位真根因；第 4 轮换另一个模型（Flash）独立调取 relay 侧日志原文交叉核验，确认 FIRE 在终态后约 0.3 秒、POST 约 1 秒内完成。教训：**执行方的自报根因不可信，验收要一手日志**
- **铃时延三连实测**：新鲜真单终态 → Muse 侧账本落盘约 6 秒 / 8 秒 / 7 秒（flash 与 pro 的单无差别）；重启会把存量终态单重发一遍铃（去重表只在进程内存），消费侧按 runId + 状态去重即可无害
- **确认门取消**：同日用户改定——选型由 Muse 在 Flash / V4 Pro 间自选自定、直接派发、回报写明，不再逐单等「继续」

## 实测记录（2026-10-20）

- DSH 线全链打通：`tools/list` 17 个工具、`doctor` ok、15 个工作区可见
- 只读派发三连：根目录盘点（28 项，17 分 33 秒）、`PROJECT.md` 大小 = 693,257 bytes（22 秒）、`项目管理教学模板.md` = 6,005 bytes（22 秒），均归档成功
- 踩过的坑全部记在 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)：`HOST_REJECTED`、CSRF malformed、长耗时误判空响应、适配器层 `FORBIDDEN / expired`、归档 401、微信绑定风控、VM 替换丢服务

## 安全边界

- **relay 静态 token 永不离开 Windows 本机**；对外只有可吊销、短时效的 OAuth token
- 8443 通道 **tailnet-only**，不经公网；公网桥见姊妹项目 [dsh-gptbridge](https://github.com/ksoulness/dsh-gptbridge)
- 微信侧只处理绑定用户本人的白名单私聊；回复只发纯文本
- 微信对话与其他会话互不串扰：独立 binding 与白名单收件箱、独立唤醒 worker 处理、回复只发回用户本人（详见 docs/WECHAT-BRIDGE.md 第 11 节）
- 本仓库**不含任何真实凭据**：token、口令、wxid、tailnet 名均为占位符，部署时替换为你自己的

## 目录

```
README.md                  本文件：总览、快速开始、三大部分导览
wechat-optimization/       ★ 一、微信链的优化：上下文连贯+隔离、stallwatch 补丁、systemd 修复、hook 自愈
wechat-optimization/scripts/ctx.py
                           按发送者隔离的对话上下文脚本（hook 唤醒前 read，处理完 in/out 记录）
wechat-first-connect/      ★ 二、第一次连接微信出问题怎么办：绑定风控、登录过期、重复唤醒、验收标准
dsh-connection/            ★ 三、DSH 的连接：8443 通道、OAuth 建连、token 自续、派发流程
docs/FOR-NEW-MUSE.md       ★ 给新 Muse 的总入口：阅读顺序、前置清单、铁律、验收标准
docs/DSH-CONTROL.md        DSH 线完整方法：双向通道（正向派发 + 终态门铃 + 反向入队取单）、定式、流程、坑
docs/WECHAT-BRIDGE.md      微信线完整方法：协议、部署、hook、坑
docs/NOTIFICATION-ROUTING.md
                           通知路由与隔离口径：哪些推微信、哪些静默（用户确认生效）
docs/WECHAT-SETUP-PROMPT.md
                           给新 Muse 的微信接入逐步执行指令（照着做）
docs/TROUBLESHOOTING.md    两条线的故障速查表
skills/dsh-relay-operation/SKILL.md
                           交给 Muse 的 DSH 操作技能手册（定式版）
tools/dsh_client.py        DSH 客户端：token 自续 + 台账 + 长超时重试（带并发锁与 401 重读重试）
tools/watch_run_event.py   铃驱动 watcher：等本地终态铃账本出现目标 run 才取回终态（现行跟进主力）
tools/dsh_watch.py         轮询版 watcher：deadline 制 wait_run 循环，门铃失效时的降级备用
```

**让一个新的 Muse 学会这两件事**：把本仓库地址给它，并让它先读 `docs/FOR-NEW-MUSE.md`。仓库教方法，但权限不在仓库里——DSH 的 OAuth token 对要所有者在 Windows 侧签发后交付，微信要所有者装插件并扫码一次，这两步天然只能由人完成。

## 相关项目

- [ksoulness/dsh-gptbridge](https://github.com/ksoulness/dsh-gptbridge) — DSH 的公网 OAuth 桥（给 ChatGPT 连接器用），8443 适配器与之同源
- [ksoulness/dsh-codex-kit](https://github.com/ksoulness/dsh-codex-kit) — DSH Relay 的本机操作套件与协议教材
- [lawrencewzen/wx-bot](https://github.com/lawrencewzen/wx-bot) — 微信桥接程序（ClawBot 协议，pull 模式接 Muse）
- [tencent/openclaw-weixin](https://github.com/tencent/openclaw-weixin) — 腾讯官方 ClawBot 微信插件与协议文档

## License

MIT
