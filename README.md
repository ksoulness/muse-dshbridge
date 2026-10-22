# muse-dshbridge

把云端的 **Meta Muse**（跑在云电脑上的个人 agent）接到用户自己的两个世界里：

- **向下派活**：经 Tailscale 私有网络，远程调用用户 Windows 电脑上的 **DSH（DeepSeek Harness）**，在指定工作区里发起对话、执行任务、验收结果；
- **随身对话**：经腾讯官方 ClawBot 微信插件 + wx-bot 桥接，让用户在微信里直接和 Muse 聊天。

一句话：**DSH 线是「Muse → tailnet → OAuth 适配器 → DSH Relay」的受控派发通道；微信线是「微信 → ClawBot 协议 → wx-bot 收件箱 → 唤醒 Muse」的消息通道。** 本仓库是这两条链路的**项目记录 + 操作手册 + 技能文件**，2026-10-20 一晚全部实测打通。

```
                        ┌──────────────── 云电脑（Muse 常驻）────────────────┐
                        │  Muse 本体 ── dsh_client.py（OAuth 自续 + 台账）      │
                        │  Muse 本体 ── hooks（微信收件箱轮询 / 看门狗）        │
                        └──────┬──────────────────────────────┬─────────────────┘
              tailnet (Tailscale Serve :8443)        HTTPS 长轮询 (ilinkai.weixin.qq.com)
                               ▼                              ▼
                 Windows 电脑 · DSH            wx-bot（systemd 常驻，pull 模式）
                   Relay MCP :3079                    │ 微信 ClawBot 插件
                   15 个工作区 / 模型固定              ▼
                   wb2api-nas / cn:deepseek-      用户的微信
                   v4.1-flash
```

## 为什么需要这两条线

| 问题 | 解法 |
|---|---|
| DSH 的 Relay 只监听本机 `127.0.0.1:3079`，且源码锁死：来源必须 loopback、Host 必须在白名单内，远程直连回 `403 HOST_REJECTED` | 在 Windows 本机放一个 OAuth 适配器实例，经 **Tailscale Serve（tailnet-only :8443）** 暴露给云端 Muse；适配器在本机内持 Relay token 并自动跟随轮换 |
| Relay 只认静态 Bearer（= 该机完整执行权），不能经聊天/公网传递 | 对外只发 **OAuth access token（1 小时）+ refresh token（30 天滚动）**；客户端自续、轮换即落盘，relay token 永不离开那台 Windows |
| Muse 官方通道只有 WhatsApp，没有微信 | 腾讯官方 ClawBot 插件 + 公开协议（`ilinkai.weixin.qq.com`，扫码登录、长轮询收、接口发），用 **wx-bot** 桥接到 Muse 的收件箱/hook 机制 |

## 特性

**DSH 线**
- **下令定式**：用户只说「在 `<工作区>` 调用 DSH 执行 `<任务>`」，客户端自动补齐：固定模型 `wb2api-nas / cn:deepseek-v4.1-flash`、任务前缀 `muse指派-`、fresh 会话、只读走 `start_review`、稳定幂等键。见 [docs/DSH-CONTROL.md](docs/DSH-CONTROL.md)
- **长任务可靠姿势**：`wait_run` 每 30 秒一轮跟到终态（实测有单跑了 17 分 33 秒）；终态正文立即落盘，run 台账（runId / sessionId / 幂等键 / 起止 / 正文）自动记入本地 ledger
- **token 自续**：access 过期自动用 refresh 轮换，新 token 对原子落盘（600 权限）；旧 refresh 重放会吊销整族，所以永远先落盘再干活
- **验收闭环**：派发 → 等终态 → 读 `assistantText` 自行复核 → 归档会话（`archived: true` 才算数）→ 按固定格式回报

**微信线**
- **纯官方协议**：ClawBot 插件扫码绑定，`getUpdates` 长轮询收消息、`sendMessage` 发消息，全程 HTTPS，不碰任何非官方 Hook
- **常驻自愈**：wx-bot 以 systemd 服务运行；收件箱 hook 5 秒轮询唤醒 Muse；watchdog hook 在云 VM 被替换、`/etc` 被清空时自动重装服务
- **绑定风控解法**：云机房 IP 绑定会被腾讯风控拦——只在绑定阶段经 tailnet 借家庭网络出口扫码，通过后切回直连（实测收发均正常）

## 快速开始

**DSH 线**（详见 [docs/DSH-CONTROL.md](docs/DSH-CONTROL.md)）

1. Windows 侧：DSH 运行中（Relay 插件启用）；适配器起第二个实例监听本机 `:18081`（独立 OAuth 库），`tailscale serve` 把 tailnet 的 `:8443` 指给它
2. 云端：客户端向 `:8443` 动态注册（DCR），所有者在本机浏览器走完 OAuth 授权（口令只在本机输），拿到 access + refresh 对
3. 之后一切走技能手册：`skills/dsh-relay-operation/SKILL.md` —— 把它交给 Muse，它就会按定式派活

**微信线**（详见 [docs/WECHAT-BRIDGE.md](docs/WECHAT-BRIDGE.md)）

1. 微信里装 ClawBot 插件（我 → 设置 → 插件）
2. 云电脑装 wx-bot 单文件二进制，写 pull 模式配置（binding 名 `muse`）
3. 扫码绑定（云 IP 先借家庭出口过风控），装 systemd 服务 + 收件箱 hook + watchdog hook，health 退出码 0 验收

## 实测记录（2026-10-20）

- DSH 线全链打通：`tools/list` 17 个工具、`doctor` ok、15 个工作区可见
- 只读派发三连：根目录盘点（28 项，17 分 33 秒）、`PROJECT.md` 大小 = 693,257 bytes（22 秒）、`项目管理教学模板.md` = 6,005 bytes（22 秒），均归档成功
- 踩过的坑全部记在 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)：`HOST_REJECTED`、CSRF malformed、长耗时误判空响应、适配器层 `FORBIDDEN / expired`、归档 401、微信绑定风控、VM 替换丢服务

## 安全边界

- **relay 静态 token 永不离开 Windows 本机**；对外只有可吊销、短时效的 OAuth token
- 8443 通道 **tailnet-only**，不经公网；公网桥见姊妹项目 [dsh-gptbridge](https://github.com/ksoulness/dsh-gptbridge)
- 微信侧只处理绑定用户本人的白名单私聊；回复只发纯文本
- 本仓库**不含任何真实凭据**：token、口令、wxid、tailnet 名均为占位符，部署时替换为你自己的

## 目录

```
README.md                  本文件：总览与快速开始
docs/FOR-NEW-MUSE.md       ★ 给新 Muse 的总入口：阅读顺序、前置清单、铁律、验收标准
docs/DSH-CONTROL.md        DSH 线完整方法：通道、定式、流程、坑
docs/WECHAT-BRIDGE.md      微信线完整方法：协议、部署、hook、坑
docs/NOTIFICATION-ROUTING.md
                           通知路由与隔离口径：哪些推微信、哪些静默（用户确认生效）
docs/WECHAT-SETUP-PROMPT.md
                           给新 Muse 的微信接入逐步执行指令（照着做）
docs/TROUBLESHOOTING.md    两条线的故障速查表
skills/dsh-relay-operation/SKILL.md
                           交给 Muse 的 DSH 操作技能手册（定式版）
tools/dsh_client.py        DSH 客户端：token 自续 + 台账 + 长超时重试
```

**让一个新的 Muse 学会这两件事**：把本仓库地址给它，并让它先读 `docs/FOR-NEW-MUSE.md`。仓库教方法，但权限不在仓库里——DSH 的 OAuth token 对要所有者在 Windows 侧签发后交付，微信要所有者装插件并扫码一次，这两步天然只能由人完成。

## 相关项目

- [ksoulness/dsh-gptbridge](https://github.com/ksoulness/dsh-gptbridge) — DSH 的公网 OAuth 桥（给 ChatGPT 连接器用），8443 适配器与之同源
- [ksoulness/dsh-codex-kit](https://github.com/ksoulness/dsh-codex-kit) — DSH Relay 的本机操作套件与协议教材
- [lawrencewzen/wx-bot](https://github.com/lawrencewzen/wx-bot) — 微信桥接程序（ClawBot 协议，pull 模式接 Muse）
- [tencent/openclaw-weixin](https://github.com/tencent/openclaw-weixin) — 腾讯官方 ClawBot 微信插件与协议文档

## License

MIT
