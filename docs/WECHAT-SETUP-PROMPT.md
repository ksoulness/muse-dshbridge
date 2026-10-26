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

3. **扫码登录**：按手册第 3 步，用 `setsid nohup` 让登录进程脱离当前命令运行（`wx-bot login muse --qr-png ... --timeout 10m`）。每张二维码只有约 2 分钟有效：日志里一出现新的 `QR PNG: <路径>`，立刻把那个路径的图片原图发给用户，中间不要做别的事；不要改名或复制成固定文件名（聊天按路径缓存图片，同路径会一直显示第一张过期码）。盯日志：新码出现就发新图，出现 `login ok` 即成功。只有绑定用户本人的 wxid 进白名单。**如果是登录过期后的重新扫码，先 `systemctl stop wx-bot` 停服务再启动 login**——不停服务，旧会话的 poller 可能在新会话写好后几秒内写下过期的 `expired` 标记把新会话盖住（见 WECHAT-BRIDGE.md 坑五）；重扫后若仍报 expired，先查状态目录里 `expired` 标记是不是残留（对照它与 `session.json` 的时间戳），移走备份 + 重启即可，**不要一上来就让用户再扫一遍**。扫码来回要压紧：实测一张码约 2 分钟，来回聊两句就过期，可能连过两三张才扫上。

4. **⚠️ 坑一（云环境绑定必遇，先看完再扫码）**：腾讯服务端按出口 IP 做风控。云电脑/机房 IP 扫码绑定会被拦：手机上弹「此 OpenClaw 的运行环境存在风险，暂无法连接」，二维码在服务端约 121 秒就过期、服务端不返回错误码；反复续码、改客户端都没用（官方仓库有同款 issue，别人卡了很久）。解法：**只在绑定阶段**让 wx-bot 的流量改走用户家庭网络出口——例如经 Tailscale 连到用户家里一台设备（Mac/PC）上临时跑一个代理，wx-bot 经本机中转代理链过去，扫码一次就能通过。**绑定成功后立刻把出口切回机房直连**（收发实测都正常），家里设备上的代理窗口可以关，中转只为了绑定，不要长期挂着。

5. **常驻服务**：按手册第 4 步，取仓库 `adapters/muse/wx-bot.service` 模板，把 `__HOME__` 换成你 home 的绝对路径、`__USER__` 换成属主，装到 `/etc/systemd/system/wx-bot.service`，`systemctl daemon-reload && systemctl enable --now wx-bot`。**装之前先查模板**：`StartLimitIntervalSec` / `StartLimitBurst` 两键必须在 `[Unit]` 段（写在 `[Service]` 段会被 systemd 忽略）；模板不对，**先改模板源文件再装**——只改装好的 unit 文件，下一次自愈重装就会被模板打回原样。验收：`wx-bot status` 显示 `logged_in: true`、`delivery: pull`；等 15 秒跑 `wx-bot health --binding muse --grace 0`，**退出码 0 才算装好**，不是 0 按输出和仓库 troubleshoot.md 处理，不要只看服务 active 就报成功。每次重扫或改了 env 文件都要 `systemctl restart wx-bot`。

6. **收件箱 hook**：按仓库 `adapters/muse/wechat-hook.sh` 写检测脚本，**poll_interval_secs 设为 5**（默认 60 太慢）。规则：`wx-bot inbox count --binding muse` 大于 0 就唤醒；否则跑 `wx-bot health --binding muse --liveness`，退出码非 0 时唤醒且文字以「wx-bot 异常：」开头（同一问题只唤醒一次、之后每小时最多再提醒一次）。先 dry_run 再 enable。

7. **唤醒后处理规则**（把这段完整写进 hook 的唤醒指令里）：
   - 唤醒原因是「wx-bot 异常」：不要 pull 消息、不要自行重启服务（可能用户故意停的）；跑一次 health 对照原因，必须在你的主聊天里用中文告诉用户异常原因和建议处理办法，等他决定。这步不能省。
   - 唤醒原因是新事件：`wx-bot inbox pull --binding muse --lease 30m` 领取，逐条处理，每条处理完 `wx-bot inbox ack <event_id>`（不 ack 的 30 分钟后会重复唤醒）。同一 event_id 只处理一次。
   - `kind` 为 `alert` 的事件是 wx-bot 的异常通知，不是微信消息：把内容用中文在主聊天报告给用户、问要不要处理，**不要回微信**，然后照常 ack。
   - 其余事件当作用户直接对你说的话来处理（text 是文字、voice_text 是语音转写、media[].path 是本机文件可直接读）。
   - 回复微信**只发纯文本**，不要 Markdown，链接直接写网址。发文字一律用 heredoc：`wx-bot send --binding muse --to <from_wxid> --text - <<'EOF'` … `EOF`；发图片/文件用 `--image` / `--file`。长任务先回一句简短确认，做完再发结果。
   - `send` 失败含义：`no context_token` = 对方还没先给 ClawBot 发过消息，等对方先发；`expired` 或 `-14` = 登录过期，按第 3 步重扫并重启服务；`ret=-2 (HTTP 502)` 也可能是发送会话过期被包了一层——**health 退出码 0、poll 正常也发不出是可能的（收发两条通道分开过期）**，同样按登录过期处理，不要当临时网关错误反复重试。失败情况在主聊天告诉用户。

8. **⚠️ 坑二（会被替换的云 VM 必加，watchdog 写法有硬性要求）**：如果你的运行环境是会被平台替换的 VM，替换后 /etc 下的 systemd unit 会被清空、服务全灭（登录态存在 home 里，不用重扫）。加一个 watchdog hook（60 秒轮询），逻辑必须按下面写，**不要自己发明防抖方案**（实测教训：另一套同架构实例曾让「unit 缺失」也走连续 3 次失败计数，每次换机白白多断约 2 分钟；3 天 32 次重启，每次都断 2–3 分钟）：

   - **先查 unit 文件、再查 health**：unit 文件不存在 = 换机后的确定状态，**立即按模板重装并拉起，不许走任何失败计数**；
   - unit 存在但 health 失败，才走防抖（如连续 3 次失败再动手）——防抖只防瞬时抖动误杀，整体调小/取消会误杀健康服务，套在 unit 缺失上则纯属白等，两种错都不要犯；
   - 拉起后等约 12 秒复查 health，退出码 0 才算修好，修不好才唤醒报告；dry_run 只报预测、不碰 systemd；
   - 装好必须做模拟验收（请用户在场）：停服 + 删 unit 文件，看守应在下一轮约 1 分钟内恢复（实测 38 秒），且装回的 unit 里 StartLimit 两键在 `[Unit]` 段。
   - 别试这两条死路（实测不通）：用户级 systemd（这类环境无用户总线）、`@reboot` cron（/var 同样不跨替换保留）。

9. **⚠️ 环境整体停摆（WECHAT-BRIDGE.md 坑四；先讲清、由用户拍板）：运行环境整体停摆时，机内一切自愈都会失效。** 看守和告警都跑在这台会被停摆的机器上，环境被平台长时间暂停时，它们会一起停（实测发生过约 17.4 小时的无声断线：两个 hook 日志同一分钟一起断档、一起恢复，期间无自愈无告警，用户自己发现才知道）。这在机内**无解**，不要承诺「加个更勤的看守就行」。两个选项如实摆给用户决定：
   - **机外死亡开关（推荐）**：桥每分钟探活通过后向机外服务（如 healthchecks.io）打一次心跳，机外超 5 分钟没收到就用桥外通道（邮件/飞书/ntfy 等）报警。注意是桥主动报平安，不是机外来轮询（wx-bot 接口只在本机，机外问不到）。用户同意才装；同意后必须做一次停发心跳测试验收。
   - **不装**：用户若表示断线会自己回来找，就记录在案、不再主动推进，以后也不要把长时间无声断线当新 bug 重新追查。
   另外提醒：将来若想把桥迁到稳定主机根除断线，**不能只搬 wx-bot**——pull 投递靠你在本机跑 `inbox pull/send`，搬走桥 pull 链路就断，迁移要连投递方式一起设计（见 WECHAT-BRIDGE.md 坑四），不要随口承诺「搬过去就行」。

## 验收

三条都过才算接通：① `wx-bot health --binding muse --grace 0` 退出码 0；② 用户用微信给 ClawBot 发一条消息，你能收到并回复；③ `wx-bot send --image` 发一张图能送达。云 VM 环境另加一条：④ 按第 8 步做模拟删 unit 测试，看守约 1 分钟内自愈。
