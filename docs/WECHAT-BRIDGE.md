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
3. **扫码登录**：用 `setsid nohup` 让登录进程脱离当前命令（`wx-bot login muse --qr-png ... --timeout 10m`）。每张二维码约 2 分钟有效：日志一出现新的 `QR PNG: <路径>`，立刻把原图发给用户扫，中间不做别的事；**不要改名/复制二维码文件**（聊天按路径缓存图片，同路径会一直显示第一张过期码）。只有绑定用户本人的 wxid 进白名单。**重新扫码（登录过期后重登）前必须先 `systemctl stop wx-bot` 停服务**——不停服务直接重登，旧会话的 poller 可能在新会话写好后几秒内写下过期的 `expired` 标记、把新会话盖住，重登成功也会报 expired（见坑五）；扫码环节也要压紧来回耗时，一张码约 2 分钟，聊着聊着就过期了，实测连过两张码才在第三张扫上。
4. **常驻服务**：取仓库 `adapters/muse/wx-bot.service` 模板（替换 `__HOME__` / `__USER__`），装到 `/etc/systemd/system/wx-bot.service`，`daemon-reload && enable --now`。**装之前先查模板**：`StartLimitIntervalSec` / `StartLimitBurst` 两键必须在 `[Unit]` 段——上游模板曾把它们写在 `[Service]` 段，systemd 会直接忽略；模板不对就**先改模板源文件**再安装，只改已装好的 unit 文件没用（下一次自愈重装就会被模板打回原样，见坑三附带修复）。验收看 `wx-bot health --binding muse --grace 0` **退出码 0**（不要只看服务 active）。改 env 或重扫后必须 `systemctl restart wx-bot`。
5. **收件箱 hook**：按 `adapters/muse/wechat-hook.sh` 写检测脚本，**poll_interval_secs 设 5**（默认 60 太慢）。规则：`wx-bot inbox count --binding muse` > 0 就唤醒领消息；否则跑 health 存活检查，异常时唤醒报告（同一问题只报一次、之后每小时最多一次）。先 dry_run 再 enable。
6. **watchdog hook**（会被替换的云 VM 必加）：60 秒轮询。**看守逻辑有硬性要求，照下面写，不要自由发挥**（原理与实测证据见坑二）：
   - 每轮**先查 unit 文件是否存在，再查 health**。unit 不存在是换机后的确定状态、不是抖动：**立即按模板重装并 `enable --now` 拉起，不许走任何失败计数/防抖**。这条快速分支是必备项，缺了它每次换机都要多断约 2 分钟。
   - unit 存在但 health 失败，才走防抖计数（如连续 3 次失败再动手）——防抖只防瞬时抖动误杀健康服务，**整体调小或取消都会重开误杀口子，但把它套在 unit 缺失上同样是错的**，两种错都不要犯。
   - 拉起后等约 12 秒复查 `health --grace 0`，退出码 0 才算修好；修不好才唤醒报告。dry_run 只报预测、不碰 systemd。
   - 登录态存在 home 里，换机不用重扫。装好后做一次模拟验收：停服 + 删 unit，看守应在下一轮（约 1 分钟内）恢复服务，实测最快 38 秒。

## 3. 唤醒后的处理规则（写进 hook 指令）

- 异常类唤醒：不 pull 消息、不自行重启服务（可能用户故意停的）；在主聊天用中文报告原因与建议，等用户决定
- 新消息：`wx-bot inbox pull --binding muse --lease 30m` 领取，逐条处理完逐条 `ack`（不 ack 的 30 分钟后重复投递）；同一 event_id 只处理一次
- `kind=alert` 是 wx-bot 的异常通知、不是微信消息：转报主聊天，不回微信，照常 ack
- 其余事件当作用户直接说的话：text 是文字、voice_text 是语音转写、media[].path 是本机文件可直接读
- **回复微信只发纯文本，不用 Markdown**，链接直接写网址；发文字用 heredoc：`wx-bot send --binding muse --to <from_wxid> --text - <<'EOF' … EOF`；图片/文件用 `--image` / `--file`（实测可达）。长任务先回一句确认，做完再发结果
- send 失败含义：`no context_token` = 对方还没先给 ClawBot 发过消息，等对方先发；`expired` / `-14` = 登录过期，重扫 + 重启服务；`ret=-2 (HTTP 502)` 也可能是发送会话过期被包了一层（health 全绿也会发生），同样按登录过期处理、不要当临时网关错误反复重试。重扫前先停服务、重扫后仍报 expired 先查残留标记，见坑五。失败要报主聊天

## 4. 坑一：绑定阶段的风控（云环境必遇）

腾讯按出口 IP 做风控：云电脑/机房 IP 扫码绑定会被拦，手机弹「此 OpenClaw 的运行环境存在风险，暂无法连接」，二维码在服务端约 121 秒过期且不回错误码——反复续码、改客户端都没用（官方仓库有同款 issue）。

解法：**只在绑定阶段**让 wx-bot 流量改走用户家庭网络出口（例如经 Tailscale 到家里一台 Mac/PC 上临时开个代理，wx-bot 经本机中转代理链过去），扫码一次通过。**绑定成功立刻切回机房直连出口**——实测直连收发都正常，家庭代理窗口随手关掉，中转只为绑定、不长期挂。

## 5. 坑二：云 VM 替换丢 /etc（watchdog 必须带 unit 缺失快速分支）

会被平台替换的 VM，替换后 `/etc/systemd/system` 下的 unit 消失、服务全灭（登录态在 home，不受影响）。靠第 2 节第 6 步的 watchdog hook 自愈：检测 health 失败 → 重装 unit → 拉起服务。实测自愈过 VM 替换与服务短停。

**这个坑的完整量级（另一套同架构实例 2026-10 实测，3 天内 32 次 VM 重启）**：每次重启 unit 必丢。看守若对「unit 缺失」也走多轮失败计数才动手（如探活 60 秒一轮、连续 3 次才修），每次断线约 2–3 分钟，其中约 2 分钟纯粹是白等——unit 不存在是确定状态，没有任何「等一等它会自己好」的可能。

**正确做法（2026-10-26 落地并验收）**：看守每轮先做文件检查——unit 不存在就跳过全部计数、立即重装拉起；unit 存在但 health 失败才走防抖计数。模拟验收（停服 + 删 unit，用户在场）：删 unit 到服务恢复 active 仅 **38 秒**，且装回的 unit 的 StartLimit 两键确实在 `[Unit]` 段，证明模板修正会经由自愈正确传播。

**不要重复踩的死路**（全部实测走不通）：

- 用户级 systemd 单元放 `~/.config/systemd/user/` 靠 home 持久化：这类云环境**没有用户级总线**（`systemctl --user` 直接报错），此路不通。
- `@reboot` cron 之类的开机自启：crontab 与 `/var` 同样不跨 replacement 保留，与 /etc 单元同一命运。
- 只修 `/etc` 下现行 unit 不改模板：下一次自愈重装即被打回，等于没修；模板修正只留草稿不应用，同样等于没改。
- 靠机内 journal 还原换机前的过程：journal 只保留当次启动，换机即失。
- 追查某一次重启的平台原因：机内无证据，且高频更换是系统性行为，个案归因改变不了复发。

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

## 7. 坑四：运行环境整体停摆造成的「无声断线」（机内无解，只能机外兜底）

症状：微信断线长达数小时甚至十几小时，期间**没有任何自愈、没有任何告警**，用户自己发现才知道。回来查日志会发现：看守 hook（60 秒）与收件箱 hook（5 秒）的日志在**同一分钟一起断档、又在同一分钟一起恢复**，中间是一整段空白（实测最长一段约 17.4 小时）。

定性：这不是桥的新 bug，也不是某个 hook 坏了——是**运行环境整体停摆**（VM 被平台长时间暂停/收走）。现行自愈有一个原理性的前提缺陷：**看守、检测、告警全都跑在同一台会被停摆的机器上**；环境一停，它们同生共死。所以：

- **不要试图在机内修这个**：把看守写得更勤、加第二层机内看守、加机内告警，全都没用，停摆时一行都执行不到。机内修复（坑二的快速分支）只能缩短「环境活着时」的断线，对停摆型断线无能为力，投入到此为止。
- **唯一的检测手段在机外——死亡开关（Dead Man's Switch）**：不要让机外探针来轮询桥（wx-bot 接口只监听本机，机外根本问不到）；反过来，桥每分钟探活通过后主动向一个机外服务打一次心跳 ping（如 healthchecks.io 一类，免费档足够；或用户自有稳定主机上的极简端点），机外超过阈值（建议 5 分钟，避开单次换机自愈的 1–3 分钟窗口）没收到心跳，就用**桥外通道**（邮件/飞书/ntfy/短信）报警。要点：心跳必须「探活通过才发」，只报「看守还活着」会漏掉环境活着但桥死了的情况；ping 的 UUID 按密码对待，只写本机配置、不进仓库；报警文案要点明用户动作（如「打开 Muse 看一眼」——停摆型断线里，用户打开运行时本身往往就是唤醒环境、触发自愈的那一步）。验收必须做一次人为停发心跳测试，确认 ≤10 分钟收到报警才算落地。
- **死亡开关是用户的选择，不是默认必装**：有的用户宁可自己发现断线再回来找（实测有用户明确这么决定并暂缓此方案）。部署时把「机内修不了停摆、最长可能无声十几小时」讲清，让用户拍板；用户暂缓就记录在案、不再主动推进，设计留作备选。
- **根除只有迁移**：把桥迁到不被更换的稳定主机（家里机器/NAS/稳定 VPS）。但有一个极易漏掉的前提——**pull 投递靠 Muse 在本机执行 `inbox pull / send` 读写本机状态目录，只把 wx-bot 二进制搬走，pull 链路会直接断**。迁移必须连投递一起设计：改 webhook（前提是运行时有 webhook 触发入口）、或 Muse 侧 hook 改为经 Tailscale/SSH 远程执行稳定主机上的 pull/send、或加转发层，三选一。切换时先停旧实例再启新实例，两边同时 poll 会互相顶掉 cursor；定制二进制要在目标机按原补丁重新构建；登录态迁移失效需重扫，预案要提前告诉用户，不要切换当天才说。

## 8. 坑五：发送会话过期（health 全绿也发不出）与重登后的 expired 残留标记

第一幕——**收正常 ≠ 发正常**（2026-10-26 实测）：`wx-bot send` 连续失败，报 `/ilink/bot/sendmessage: ret=-2 (HTTP 502)`；同期 health 退出码 0、`logged_in: true`、poll 一切正常，看起来桥完全没病。经代理直连发送端点探针，真实返回是 `errcode: -14, session timeout`——**发送会话已过期，收消息的长轮询却不受影响**。所以：

- health 退出码 0 只证明轮询与登录态标记，**不证明发送通道可用**；验收与排障都要包含一次真实 `send` 成功，光看 health 会误判「桥是好的」。
- send 报 `ret=-2` 不要按「502 是网关临时错误」放过去重试：它可能正是会话过期（-14）被包了一层。按登录过期处理：重新扫码（流程见下）。

第二幕——**重登成功却仍报 expired**：停服这一步若漏了（或旧 poller 还在跑），新 `session.json` 写好仅几秒后，旧会话过期的 poller 会写下状态目录里的 `expired` 标记文件（内容是旧过期时间戳），把新会话盖住。之后服务只认这个标记：`expired: true`、poll 不运行、health 报 login expired——**但新会话本身是有效的，`status` 的 `expired` 字段只反映标记文件存在与否**。

正确处理顺序（先查标记、再考虑重扫，别一上来又让用户扫码）：

1. 对照时间戳：看状态目录（如 `~/.local/state/wx-bot/<binding>/`）里 `session.json` 与 `expired` 两个文件的写入时间；`expired` 紧跟在新 session 之后几秒内、且内容是旧时间戳，就是残留。
2. 把 `expired` 移走备份（改名为带日期的 `.bak`，不要直接删，留证），`systemctl restart wx-bot`。
3. 复查 health 退出码 0、`expired: false`、poll 恢复，再用一次真实收发 + 发图关闭问题（实测照此修复后当场全通）。

防复发就一条：**任何重新扫码之前，先停服务**（第 2 节第 3 步已写死）；重登后仍报 expired，先按上面三步查残留标记，再决定是否需要用户再扫一次。

## 9. 使用规矩（实测约定）

- 通道只是通道：审批、付款、敏感操作仍走 Muse 主界面的正式流程，微信里只做对话与转达
- 初期只处理绑定用户的文字私聊；群聊、公众号等不在范围内
- 短暂断线并自动恢复的，不必通知用户；断线超过 1 小时未恢复才报（此规则只在运行环境活着、看守能跑时成立；环境整体停摆时连这条也发不出来，见坑四）
- 通知去哪儿看 [docs/NOTIFICATION-ROUTING.md](NOTIFICATION-ROUTING.md)：用户点名要的（早晚报）微信直推不隔离，异常和需用户动手的按原通道通知，纯后台成功静默

## 10. 验收（三条全过才算接通）

1. `wx-bot health --binding muse --grace 0` 退出码 0
2. 用户微信给 ClawBot 发一条消息，Muse 能收到并回复
3. `wx-bot send --image` 发图能送达
4. （云 VM 环境加测）模拟删 unit：停服并删除 unit 文件，watchdog 应在下一轮约 1 分钟内按模板重装并恢复 health 退出码 0（坑二快速分支的验收，实测 38 秒）

## 11. 会话隔离：用户的微信对话与其他会话互不串扰（2026-10-23 用户要求入库）

用户的要求是：他在微信里与 Muse 的对话，必须与其他所有会话相互隔离、互不串扰。实现机制四条（仓库只记机制，不记真实 wxid 等凭据）：

1. **事件来源隔离**：binding=muse 是独立绑定，扫码登录的是用户本人的微信账号；收件箱只处理白名单内用户本人的私聊事件（from_wxid 不在白名单的一律不领取、不回复），群聊与公众号不在范围内。
2. **处理上下文隔离**：每个微信事件都由一个独立的唤醒 worker 处理，与 Muse 主聊天、DSH 派发任务运行在不同的执行上下文里；事件内容只用于处理该事件，不把微信对话全文搬进其他会话，其他会话的上下文也不会混进微信回复。
3. **回复去向隔离**：回复只发回该事件的 from_wxid（用户本人）；`kind=alert` 是桥的异常通知，一律转报主聊天、不回微信；主聊天给用户的回执只写处理结论（成功/失败/原因），不复述微信对话原文。
4. **去重防重入**：同一 event_id 只处理一次（已处理的只 ack、不重复回复）；没 ack 的事件 30 分钟后才会重新投递，不会同时有两个 worker 处理同一条消息。

**与通知隔离口径的区别**：[docs/NOTIFICATION-ROUTING.md](NOTIFICATION-ROUTING.md) 回答的是「后台任务产出的信息推去哪儿」，本节回答的是「微信对话本身跟其他会话隔不隔离」——两个口径都有效，互不替代。
