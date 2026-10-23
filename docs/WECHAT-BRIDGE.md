# Muse 连微信：ClawBot 官方协议 + wx-bot 桥接

Muse 官方通道只有 WhatsApp、没有微信。本文是把**用户本人微信**接给云端 Muse 的已实测方法：腾讯官方 ClawBot 插件提供协议，[wx-bot](https://github.com/lawrencewzen/wx-bot)（实测 v0.4.8）做桥接，Muse 侧用收件箱 hook + watchdog hook 完成常驻自愈。

## 1. 原理

腾讯官方仓库 [tencent/openclaw-weixin](https://github.com/tencent/openclaw-weixin) 公开了 ClawBot 微信插件与协议（`docs/protocol_zh_CN.md`）：

- 后端 `ilinkai.weixin.qq.com`，纯 HTTPS JSON
- 二维码扫码登录；`getUpdates` 长轮询收消息；`sendMessage` 发消息
- 前提：用户在微信「我 → 设置 → 插件」里装好 ClawBot 插件

桥接形态与飞书 bot 同构：**wx-bot 常驻收消息 → 落本地收件箱 → hook 轮询发现新消息 → 唤醒 Muse 领取处理 → Muse 调 wx-bot 发送回复**。

## 2. 部署步骤

仓库自带给 Muse 的手册 `docs/agents/muse.md`，主体按手册做；以下为完整流程与手册之外的关键点。

1. **安装**：从 GitHub releases 下载对应架构单文件二进制到 `~/.local/bin/wx-bot`，用 checksums.txt 校验 sha256，`wx-bot version` 确认。
2. **配置**：`~/.config/wx-bot/config.json`（目录 0700、文件 0600），照 `examples/config.pull.example.json`：binding 名 `muse`、`"delivery": "pull"`。若 shell 里有代理变量，必须写进 `~/.config/wx-bot/env`——**systemd 服务不继承 shell 环境**，不写就连不上。
3. **扫码登录**：用 `setsid nohup` 让登录进程脱离当前命令（`wx-bot login muse --qr-png ... --timeout 10m`）。每张二维码约 2 分钟有效：日志一出现新的 `QR PNG: <路径>`，立刻把原图发给用户扫，中间不做别的事；**不要改名/复制二维码文件**（聊天按路径缓存图片，同路径会一直显示第一张过期码）。只有绑定用户本人的 wxid 进白名单。
4. **常驻服务**：取仓库 `adapters/muse/wx-bot.service` 模板（替换 `__HOME__` / `__USER__`），装到 `/etc/systemd/system/wx-bot.service`，`daemon-reload && enable --now`。验收看 `wx-bot health --binding muse --grace 0` **退出码 0**（不要只看服务 active）。改 env 或重扫后必须 `systemctl restart wx-bot`。
5. **收件箱 hook**：按 `adapters/muse/wechat-hook.sh` 写检测脚本，**poll_interval_secs 设 5**（默认 60 太慢）。规则：`wx-bot inbox count --binding muse` > 0 就唤醒领消息；否则跑 health 存活检查，异常时唤醒报告（同一问题只报一次、之后每小时最多一次）。先 dry_run 再 enable。
6. **watchdog hook**（会被替换的云 VM 必加）：60 秒轮询 health；若 systemd unit 被 VM 替换清掉，自动按第 4 步重装并拉起，修不好才唤醒报告。登录态存在 home 里，不用重扫。

## 3. 唤醒后的处理规则（写进 hook 指令）

- 异常类唤醒：不 pull 消息、不自行重启服务（可能用户故意停的）；在主聊天用中文报告原因与建议，等用户决定
- 新消息：`wx-bot inbox pull --binding muse --lease 30m` 领取，逐条处理完逐条 `ack`（不 ack 的 30 分钟后重复投递）；同一 event_id 只处理一次
- `kind=alert` 是 wx-bot 的异常通知、不是微信消息：转报主聊天，不回微信，照常 ack
- 其余事件当作用户直接说的话：text 是文字、voice_text 是语音转写、media[].path 是本机文件可直接读
- **回复微信只发纯文本，不用 Markdown**，链接直接写网址；发文字用 heredoc：`wx-bot send --binding muse --to <from_wxid> --text - <<'EOF' … EOF`；图片/文件用 `--image` / `--file`（实测可达）。长任务先回一句确认，做完再发结果
- send 失败含义：`no context_token` = 对方还没先给 ClawBot 发过消息，等对方先发；`expired` / `-14` = 登录过期，重扫 + 重启服务。失败要报主聊天，不要反复重试

## 4. 坑一：绑定阶段的风控（云环境必遇）

腾讯按出口 IP 做风控：云电脑/机房 IP 扫码绑定会被拦，手机弹「此 OpenClaw 的运行环境存在风险，暂无法连接」，二维码在服务端约 121 秒过期且不回错误码——反复续码、改客户端都没用（官方仓库有同款 issue）。

解法：**只在绑定阶段**让 wx-bot 流量改走用户家庭网络出口（例如经 Tailscale 到家里一台 Mac/PC 上临时开个代理，wx-bot 经本机中转代理链过去），扫码一次通过。**绑定成功立刻切回机房直连出口**——实测直连收发都正常，家庭代理窗口随手关掉，中转只为绑定、不长期挂。

## 5. 坑二：云 VM 替换丢 /etc

会被平台替换的 VM，替换后 `/etc/systemd/system` 下的 unit 消失、服务全灭（登录态在 home，不受影响）。靠第 2 节第 6 步的 watchdog hook 自愈：检测 health 失败 → 重装 unit → 拉起服务。实测自愈过 VM 替换与服务短停。

## 6. 坑三：stallwatch「没处理 / 已恢复」通知刷屏（已打补丁修复）

症状：主人微信里反复收到成对消息——「【wx-bot】你的 Agent（muse）已经 10 分钟没有处理微信消息，目前有 N 条在排队…」，过一会儿又来「【wx-bot】Agent 已恢复处理微信消息。」桥其实没坏，一天能刷好几对。

定性：

- 这是 wx-bot 内置的 stallwatch（源码 `packages/cli/src/cmd/run.ts` 的 `stallWatch` + `packages/core/src/alerts.ts`）：每 30 秒查一次收件箱，某条事件处于 pending 且无人领取的时长超过 `AGENT_STALL_MS`，就给登录账号主人发「没处理」；队列清空后再发「已恢复」。
- `AGENT_STALL_MS = 10 * 60_000` 是**源码硬编码常量**，v0.4.8（当前最新版）没有配置项、环境变量或开关能改，GitHub 上也没有现成修复。
- Muse 这类回合串行的运行时里，长任务、上下文压缩、云 VM 替换都会让消息领取延迟超过 10 分钟，于是误报成对出现。所谓「回复慢」同理：慢的是 Agent 回合排队，桥本身的轮询是秒级。

修复（2026-10-22 实测落地）：

1. 改源码 `packages/core/src/alerts.ts`：`AGENT_STALL_MS` 改为 `60 * 60_000`（60 分钟，对齐下文「断线超 1 小时才通知」的使用规矩），在补丁处写明原因注释，`git diff` 保持可见。
2. 按 install.sh 同款命令从源码构建：仓库根 `bun install --frozen-lockfile --production --filter @wx-bot/cli`，再在 `packages/cli` 下 `bun build src/main.ts --compile --minify --define WXBOT_VERSION="\"<版本>-stall60\"" --outfile <输出文件>`。
3. `bun test` 全过（69 个）后，先备份原版二进制（如 `~/.local/bin/wx-bot.stock-v0.4.8`），再换上自建版，`systemctl restart wx-bot`，等 15 秒以 `health --grace 0` 退出码 0 验收。

注意事项：

- **不要运行 `wx-bot update`**：会覆盖回官方版，阈值变回 10 分钟。以后升级上游版本，先在新源码上重打这个补丁再构建。
- 真故障不受影响：Agent 真死掉超过 1 小时，仍会通知主人一次。

附带修复：官方 systemd 模板把 `StartLimitIntervalSec` / `StartLimitBurst` 写在 `[Service]` 段，systemd 会报 `Unknown key name` 并忽略；把两行移到 `[Unit]` 段即可（已安装的单元和 `adapters/muse/wx-bot.service` 模板都要改）。

## 7. 使用规矩（实测约定）

- 通道只是通道：审批、付款、敏感操作仍走 Muse 主界面的正式流程，微信里只做对话与转达
- 初期只处理绑定用户的文字私聊；群聊、公众号等不在范围内
- 短暂断线并自动恢复的，不必通知用户；断线超过 1 小时未恢复才报
- 通知去哪儿看 [docs/NOTIFICATION-ROUTING.md](NOTIFICATION-ROUTING.md)：用户点名要的（早晚报）微信直推不隔离，异常和需用户动手的按原通道通知，纯后台成功静默

## 8. 验收（三条全过才算接通）

1. `wx-bot health --binding muse --grace 0` 退出码 0
2. 用户微信给 ClawBot 发一条消息，Muse 能收到并回复
3. `wx-bot send --image` 发图能送达

## 9. 会话隔离：用户的微信对话与其他会话互不串扰（2026-10-23 用户要求入库）

用户的要求是：他在微信里与 Muse 的对话，必须与其他所有会话相互隔离、互不串扰。实现机制四条（仓库只记机制，不记真实 wxid 等凭据）：

1. **事件来源隔离**：binding=muse 是独立绑定，扫码登录的是用户本人的微信账号；收件箱只处理白名单内用户本人的私聊事件（from_wxid 不在白名单的一律不领取、不回复），群聊与公众号不在范围内。
2. **处理上下文隔离**：每个微信事件都由一个独立的唤醒 worker 处理，与 Muse 主聊天、DSH 派发任务运行在不同的执行上下文里；事件内容只用于处理该事件，不把微信对话全文搬进其他会话，其他会话的上下文也不会混进微信回复。
3. **回复去向隔离**：回复只发回该事件的 from_wxid（用户本人）；`kind=alert` 是桥的异常通知，一律转报主聊天、不回微信；主聊天给用户的回执只写处理结论（成功/失败/原因），不复述微信对话原文。
4. **去重防重入**：同一 event_id 只处理一次（已处理的只 ack、不重复回复）；没 ack 的事件 30 分钟后才会重新投递，不会同时有两个 worker 处理同一条消息。

**与通知隔离口径的区别**：[docs/NOTIFICATION-ROUTING.md](NOTIFICATION-ROUTING.md) 回答的是「后台任务产出的信息推去哪儿」，本节回答的是「微信对话本身跟其他会话隔不隔离」——两个口径都有效，互不替代。
