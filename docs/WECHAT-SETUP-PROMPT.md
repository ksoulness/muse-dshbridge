# 给新 Muse 的执行指令：把微信接入 Muse（wx-bot 桥接）

你要把用户的微信通过桥接程序 wx-bot 接到你（Muse）这里，实现用户在微信里和你对话。照下面执行，每一步都有验收点，不要跳步。

## 原理

腾讯官方出了 ClawBot 微信插件和公开协议（仓库 tencent/openclaw-weixin，协议后端 ilinkai.weixin.qq.com）：扫码登录、长轮询收消息、接口发消息，纯 HTTPS。桥接程序用 lawrencewzen/wx-bot（实测版本 v0.4.8），它跑在你的运行环境里作为 systemd 服务常驻，把微信消息放进本地收件箱；一个 hook 每几秒检测，有新消息就唤醒你领取、回复、确认。

仓库地址：https://github.com/lawrencewzen/wx-bot —— 先 clone 下来，它自带给 Muse 的手册 `docs/agents/muse.md` 和通用规则 `AGENTS.md`，主体步骤按手册做；下面是手册之外的关键补充和两个必踩的坑，优先级高于手册。

## 前提

让用户先在微信里装好插件：微信 → 我 → 设置 → 插件 → 安装 ClawBot。没装插件扫码也绑不上。

## 步骤

1. **安装 wx-bot**：按手册第 1 步，从 GitHub releases 下载对应架构的单文件二进制到 `~/.local/bin/wx-bot`，用 checksums.txt 校验 sha256，再 `wx-bot version` 确认。

2. **写配置**：`~/.config/wx-bot/config.json`（目录权限 0700、文件 0600），照仓库 `examples/config.pull.example.json`，binding 名为 `muse`、`"delivery": "pull"`。shell 里若有代理变量（`env | grep -i _proxy` 有输出），必须按手册第 2 步写进 `~/.config/wx-bot/env`——systemd 服务不继承 shell 的代理变量，不写就连不上微信。

3. **扫码登录**：按手册第 3 步，用 `setsid nohup` 让登录进程脱离当前命令运行（`wx-bot login muse --qr-png ... --timeout 10m`）。每张二维码只有约 2 分钟有效：日志里一出现新的 `QR PNG: <路径>`，立刻把那个路径的图片原图发给用户，中间不要做别的事；不要改名或复制成固定文件名（聊天按路径缓存图片，同路径会一直显示第一张过期码）。盯日志：新码出现就发新图，出现 `login ok` 即成功。只有绑定用户本人的 wxid 进白名单。

4. **⚠️ 坑一（云环境绑定必遇，先看完再扫码）**：腾讯服务端按出口 IP 做风控。云电脑/机房 IP 扫码绑定会被拦：手机上弹「此 OpenClaw 的运行环境存在风险，暂无法连接」，二维码在服务端约 121 秒就过期、服务端不返回错误码；反复续码、改客户端都没用（官方仓库有同款 issue，别人卡了很久）。解法：**只在绑定阶段**让 wx-bot 的流量改走用户家庭网络出口——例如经 Tailscale 连到用户家里一台设备（Mac/PC）上临时跑一个代理，wx-bot 经本机中转代理链过去，扫码一次就能通过。**绑定成功后立刻把出口切回机房直连**（收发实测都正常），家里设备上的代理窗口可以关，中转只为了绑定，不要长期挂着。

5. **常驻服务**：按手册第 4 步，取仓库 `adapters/muse/wx-bot.service` 模板，把 `__HOME__` 换成你 home 的绝对路径、`__USER__` 换成属主，装到 `/etc/systemd/system/wx-bot.service`，`systemctl daemon-reload && systemctl enable --now wx-bot`。验收：`wx-bot status` 显示 `logged_in: true`、`delivery: pull`；等 15 秒跑 `wx-bot health --binding muse --grace 0`，**退出码 0 才算装好**，不是 0 按输出和仓库 troubleshoot.md 处理，不要只看服务 active 就报成功。每次重扫或改了 env 文件都要 `systemctl restart wx-bot`。

6. **收件箱 hook**：按仓库 `adapters/muse/wechat-hook.sh` 写检测脚本，**poll_interval_secs 设为 5**（默认 60 太慢）。规则：`wx-bot inbox count --binding muse` 大于 0 就唤醒；否则跑 `wx-bot health --binding muse --liveness`，退出码非 0 时唤醒且文字以「wx-bot 异常：」开头（同一问题只唤醒一次、之后每小时最多再提醒一次）。先 dry_run 再 enable。

7. **唤醒后处理规则**（把这段完整写进 hook 的唤醒指令里）：
   - 唤醒原因是「wx-bot 异常」：不要 pull 消息、不要自行重启服务（可能用户故意停的）；跑一次 health 对照原因，必须在你的主聊天里用中文告诉用户异常原因和建议处理办法，等他决定。这步不能省。
   - 唤醒原因是新事件：`wx-bot inbox pull --binding muse --lease 30m` 领取，逐条处理，每条处理完 `wx-bot inbox ack <event_id>`（不 ack 的 30 分钟后会重复唤醒）。同一 event_id 只处理一次。
   - `kind` 为 `alert` 的事件是 wx-bot 的异常通知，不是微信消息：把内容用中文在主聊天报告给用户、问要不要处理，**不要回微信**，然后照常 ack。
   - 其余事件当作用户直接对你说的话来处理（text 是文字、voice_text 是语音转写、media[].path 是本机文件可直接读）。
   - 回复微信**只发纯文本**，不要 Markdown，链接直接写网址。发文字一律用 heredoc：`wx-bot send --binding muse --to <from_wxid> --text - <<'EOF'` … `EOF`；发图片/文件用 `--image` / `--file`。长任务先回一句简短确认，做完再发结果。
   - `send` 失败含义：`no context_token` = 对方还没先给 ClawBot 发过消息，等对方先发；`expired` 或 `-14` = 登录过期，按第 3 步重扫并重启服务。失败情况在主聊天告诉用户，不要反复重试。

8. **⚠️ 坑二（会被替换的云 VM 必加）**：如果你的运行环境是会被平台替换的 VM，替换后 /etc 下的 systemd unit 会被清空、服务全灭（登录态存在 home 里，不用重扫）。加一个 watchdog hook（60 秒轮询）：health 存活检查失败时自动按第 5 步重装 unit 并拉起服务，修不好才唤醒报告。实测靠它自愈过 VM 替换和服务短停。

## 验收

三条都过才算接通：① `wx-bot health --binding muse --grace 0` 退出码 0；② 用户用微信给 ClawBot 发一条消息，你能收到并回复；③ `wx-bot send --image` 发一张图能送达。
