# 两边怎么互通（全景）

> 一句话：**Muse（云端 VM）与 DSH（用户 Windows 机上的执行端）互相派活，靠的是两条不对称通道**——
> Muse→DSH 走 tailnet 直连调用（DSH 有可达入口）；DSH→Muse 只能走「门铃＋自取」（Muse 没有可达入口，见文末）。
> 给对方派活的入口，**两边都是「技能」，不是插件**；全图里唯一的插件是 DSH 内部的 Relay。

## 先回答：技能还是插件？

| 入口 | 形态 | 说明 |
|---|---|---|
| Muse 侧派单入口 `dsh-relay-operation` | **技能**（SKILL.md 操作手册＋配套脚本） | Muse 照它派单、跟进、验收；它本身不执行任何东西 |
| DSH 侧派单入口 `muse-dshbridge`（原 ask-muse，2026-11-13 更名对齐） | **技能**（SKILL.md 操作手册） | DSH 照它入队＋发门铃；托住它的是下面的适配器**脚本/程序**，不是插件 |
| DSH 的 Relay | **插件**（DSH 平台内的 dsh-relay 插件） | 唯一的一个插件，是任务执行引擎的底座，与上面两个入口技能不是一回事 |

其余组件全是脚本、独立程序、常驻守护、平台机制或配置——下表逐个标明，不含糊。

## 组件全图

### Muse 侧（云端 VM）

| 组件 | 形态 | 干什么 |
|---|---|---|
| `dsh-relay-operation` | 技能（本仓 `skills/` 有公开版） | 派单定式：选型、工作区、跟进两件套、验收、归档 |
| `tools/dsh_client.py` | 脚本（客户端） | 经 8443 调 DSH：OAuth token 自续、台账 `runs-ledger.jsonl`、manifest 硬门、401 重读重试 |
| `tools/build_task_manifest.py` | 脚本 | 派单前把结构化范围编成清单并校验（只读禁写、写模式必给写范围等） |
| `tools/watch_run_event.py` | 脚本 | 铃驱动 watcher：等本地账本出现终态铃才取一次终态，全程零远程轮询 |
| `tools/sweep_archive.py` | 脚本 | 每次新派单前归档清扫：只归「我派出的、已终态且事项已关闭」的旧会话（LEE 2026-11-13 定，只归 Muse 指派 DSH 的，DSH 的会话与其派给 Muse 的单都不碰） |
| 门铃守护进程 `daemon.py` | 常驻程序 | 订阅 ntfy 两个 topic（`muse-doorbell` 入队铃、`muse-run-events` 终态铃），落盘成本地账本 |
| 唤醒/保活 hook | 平台机制 | 入队铃 10 秒内唤醒主会话处理；60 秒看门狗保活守护进程 |
| pending 登记 | 本地数据 | 每单一张：runId/会话/事项/next_action；终态处理与归档清扫都认它判「事项是否结束」 |

### 通道与中间件

| 组件 | 形态 | 干什么 |
|---|---|---|
| Tailscale tailnet | 网络 | 两条方向共用的传输底座；Muse 的车道是 `serve` 映射到 DSH 的 8443（曾于 2026-11-12 被误删、已按归档恢复） |
| 8443 适配器（DSH-Remote-MCP 第二实例） | 独立程序（Windows 上的 Node 服务） | 对 tailnet 暴露 MCP 工具面：正向执行工具（doctor/start_run/reply_run/wait_run/…）＋反向队列工具（pickup/report/status）；OAuth 鉴权 |
| ntfy（自托管） | 独立服务 | 门铃投递：只带 id 的短消息，12 小时缓存＋断线补投；两个 topic 分开入队铃与终态铃 |
| 队列 `E:\Code\muse\queue\{pending,done}` | 数据目录 | DSH→Muse 的单子正文存放处（文件队列） |
| GitHub 私库收件箱 | 兜底通道 | 实时通道不可用时才用，仍逐单走确认门 |

### Windows / DSH 侧

| 组件 | 形态 | 干什么 |
|---|---|---|
| DSH 本体＋Relay | **插件**（平台内启用） | 真正跑任务的执行引擎：会话、run 生命周期、模型调用都在这里 |
| `muse-dshbridge` 技能 | **技能**（agents-home 的 skills 目录，宿主扫目录实时索引） | DSH 给 Muse 派活的入口手册：何时用、怎么写单、硬卡点 |
| `submit-task.mjs` | 脚本 | DSH 侧入队：机密扫描 → 原子写队列 pending → POST 门铃（正文只带 task id） |
| 终态门铃 poll 钩子 | 代码补丁（Relay 运行包内） | 独立 5 秒 poll loop 检测 run 终态 → 发铃到 `muse-run-events`；放行条件＝serviceId 白名单或任务以 `muse指派` 开头 |
| 工作区 `E:\Code\muse` | 目录＋注册 | 互派专区：Muse 的派单默认落这里，队列也在这里 |

## 两条方向的时序

**Muse → DSH（同步调用＋异步跟进）**

```
技能定式选型 → sweep 归档清扫 → dsh_client 经 8443（tailnet）start_run/reply_run
→ 写 pending 登记 → 子代理跑 watch_run_event.py 等终态铃
→ Relay 终态 → poll 钩子发铃 → ntfy muse-run-events → 守护进程落盘
→ watcher 取回终态 → Muse 验收（实施类必须附日志证据）→ 汇报/续接/归档
```

**DSH → Muse（门铃＋自取）**

```
技能 muse-dshbridge → submit-task.mjs 入队（队列 pending）→ POST 门铃 muse-doorbell
→ Muse 守护进程落盘 → hook 10 秒内唤醒主会话
→ 主会话 pickup 取正文 → 自动接受并执行（硬卡点先报批）→ report 回执 → 队列移入 done
```

## 为什么反向只能是「门铃＋自取」

Muse 的运行环境是受管容器：tailscale 只有出站客户端能力，没有可被入站连接的网卡，serve/funnel 也不支持——DSH 无法主动连进 Muse（2026-11-13 实测判死「Muse 当 MCP 服务端」路线）。所以反向通道必然由 Muse 侧主动订阅门铃、自己去取单；正向则因为 DSH 有 8443 入口，可以直连调用。两条通道形态不同，是网络可达性决定的，不是偏好。

## 规矩锚点（细节看对应文档）

- 选型与确认门：[DSH-CONTROL.md](DSH-CONTROL.md)（正向）；反向门铃单自动接受、硬卡点先报批，同文件第 7 节。
- 参数与坑：[dsh-connection/README.md](../dsh-connection/README.md)。
- 新 Muse 上手：[FOR-NEW-MUSE.md](FOR-NEW-MUSE.md)。
