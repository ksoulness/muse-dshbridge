# 微信链条优化

对微信链（微信 → ClawBot 协议 → wx-bot 收件箱 → 唤醒 Muse → 回复）的全部实测优化，
全部 2026-10-22 起实测落地。部署方法见
[docs/WECHAT-BRIDGE.md](../docs/WECHAT-BRIDGE.md)，
首次连接出问题看 [wechat-first-connect/](../wechat-first-connect/)。

## 1. 上下文连贯 + 对话隔离（2026-10-23）

**问题**：Muse 的微信唤醒是事件驱动的，每次唤醒都是一次全新 Agent 会话，
默认记不住上一轮说了什么——用户体感是「跟你发消息都不连贯」。

**做法**：给每个发送者维护一份独立的本地对话记录。唤醒后处理 message 事件前，
先读出该 `from_wxid` 的最近记录当作上下文；处理完把用户的话和自己的回复都追加回去。

- 隔离：每个 `from_wxid` 一个独立 JSONL 文件，不同发送者（其他对话）互不可见；
没有记录的发送者就是全新对话
- 记录只记文本摘要：text / voice_text / media 说明，不存原文件
- 追加用 flock 文件锁保护，按 `event_id` 去重（同一消息只记一次、不重复回复）
- 从部署这条规则起开始累积，之前的聊天不会自动补上；记录是明文本地文件，
目录权限 0700

实现脚本见 [scripts/ctx.py](scripts/ctx.py)：

```bash
python3 ctx.py read <from_wxid> [--limit N] # 读最近 N 条（纯文本）
python3 ctx.py add <from_wxid> <event_id> in "<用户的话>" # 记录用户消息
python3 ctx.py add <from_wxid> <event_id>-reply out "<我的回复>" # 记录我的回复
```

唤醒指令里要写死三句话：处理前先 `read`、处理时先记 `in` 再记 `out`、
同一 `event_id` 已记录过的不重复写不重复回复。

## 2. stallwatch「没处理 / 已恢复」通知刷屏（已修复）

**症状**：主人微信里反复收到成对消息——
「你的 Agent（muse）已经 10 分钟没有处理微信消息，目前有 N 条在排队…」，
过一会儿又来「Agent 已恢复处理微信消息。」桥其实没坏，一天能刷好几对。

**定性**：

- 这是 wx-bot 内置的 stallwatch（`packages/cli/src/cmd/run.ts` 的 `stallWatch` +
`packages/core/src/alerts.ts`）：每 30 秒查一次收件箱，某事件处于 pending
且无人领取超过 `AGENT_STALL_MS`，就给登录账号主人发「没处理」；队列清空后再发「已恢复」
- `AGENT_STALL_MS = 10 * 60_000` 是**源码硬编码常量**，v0.4.8（当前最新版）
没有配置项、环境变量或开关，GitHub 上也没有现成修复
- Muse 这类回合串行的运行时里，长任务、上下文压缩、云 VM 替换都会让消息领取
延迟超过 10 分钟，于是误报成对出现。所谓「回复慢」同理：
慢的是 Agent 回合排队，桥本身的轮询是秒级

**修复（2026-10-22 实测落地）**：

1. 改源码 `packages/core/src/alerts.ts`：`AGENT_STALL_MS` 改为 `60 * 60_000`
（60 分钟，对齐下文「断线超 1 小时才通知」的规矩），补丁处写明原因注释，
`git diff` 保持可见
2. 按 install.sh 同款命令从源码构建：仓库根
`bun install --frozen-lockfile --production --filter @wx-bot/cli`，
再在 `packages/cli` 下
`bun build src/main.ts --compile --minify --define WXBOT_VERSION="\"<版本>-stall60\"" --outfile <输出文件>`
3. `bun test` 全过（69 个）后，先备份原版二进制（如 `~/.local/bin/wx-bot.stock-v0.4.8`），
再换上自建版，`systemctl restart wx-bot`，等 15 秒以 `health --grace 0` 退出码 0 验收

**注意事项**：

- **切勿运行 `wx-bot update`**：会覆盖回官方版，阈值变回 10 分钟。
以后升级上游版本，先在新源码上重打这个补丁再构建
- 真故障不受影响：Agent 真死掉超过 1 小时，仍会通知主人一次

## 3. systemd 单元模板修复

官方 `adapters/muse/wx-bot.service` 把 `StartLimitIntervalSec` / `StartLimitBurst`
写在 `[Service]` 段，systemd 会报 `Unknown key name` 并直接忽略这两行。
修复是把两行移到 `[Unit]` 段。已安装的单元和模板都要改。

```ini
[Unit]
Description=wx-bot WeChat iLink bridge (pull delivery for Muse)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10
```

## 4. hook 轮询与自愈（常驻部分）

- **收件箱 hook 5 秒轮询**（默认 60 秒太慢）：`wx-bot inbox count --binding muse`
> 0 就唤醒 Muse 领消息；否则跑 `health` 存活检查，异常时唤醒报告
（同一问题只报一次，之后每小时最多一次）
- **watchdog hook 60 秒轮询**（会被平台替换的云 VM 必加）：health 失败 → 检查
systemd unit 是否被 VM 替换清掉 → 自动重装 unit 并拉起服务；
登录态存在 home 里，不用重扫。修不好才唤醒报告
- 异常类唤醒的纪律：不 pull 消息、不自行重启服务（用户可能是故意停的），
只在主聊天报告原因与建议，等用户决定

## 5. 通知与回复规矩（实测约定）

- 短暂断线并自动恢复的，不必通知用户；**断线超过 1 小时未恢复才报**
- 通知去向按 [docs/NOTIFICATION-ROUTING.md](../docs/NOTIFICATION-ROUTING.md)：
用户点名要的（早晚报）微信直推不隔离；异常和需用户动手的按原通道通知；
纯后台成功静默
- **回复微信只发纯文本，不用 Markdown**，链接直接写完整网址；
发文字一律 heredoc：

```bash
~/.local/bin/wx-bot send --binding muse --to <from_wxid> --text - <<'EOF'
<回复>
EOF
```

图片/文件/视频分别用 `--image` / `--file` / `--video`（发图实测可达）。
长任务先回一句简短确认，做完再发结果
- 处理事件的闭环：逐条处理完逐条 `wx-bot inbox ack <event_id>`；
没 ack 的 30 分钟后租约到期会重复投递，同一 `event_id` 只处理一次
