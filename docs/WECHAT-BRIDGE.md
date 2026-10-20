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

## 6. 使用规矩（实测约定）

- 通道只是通道：审批、付款、敏感操作仍走 Muse 主界面的正式流程，微信里只做对话与转达
- 初期只处理绑定用户的文字私聊；群聊、公众号等不在范围内
- 短暂断线并自动恢复的，不必通知用户；断线超过 1 小时未恢复才报

## 7. 验收（三条全过才算接通）

1. `wx-bot health --binding muse --grace 0` 退出码 0
2. 用户微信给 ClawBot 发一条消息，Muse 能收到并回复
3. `wx-bot send --image` 发图能送达
