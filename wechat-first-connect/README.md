# 第一次连接微信：出问题怎么办

这是**首次把微信接进来**（安装 → 配置 → 扫码绑定 → 常驻服务 → 验收）
整个过程中已实测的问题和解法。完整部署步骤见
[docs/WECHAT-BRIDGE.md](../docs/WECHAT-BRIDGE.md)，
部署好之后的优化见 [wechat-optimization/](../wechat-optimization/)。

## 0. 前置清单（先过一遍，避免返工）

- 用户微信「我 → 设置 → 插件」里装好 **ClawBot 插件**
- 下载 wx-bot 单文件二进制（实测 v0.4.8），用 releases 的 `checksums.txt` 校验 sha256，
  `wx-bot version` 确认版本
- 配置目录 `~/.config/wx-bot` 权限 0700、配置文件 0600；binding 名固定 `muse`，
  `delivery` 设 `pull`
- shell 里有代理变量的，必须写进 `~/.config/wx-bot/env`——
  **systemd 服务不继承 shell 环境**，不写就连不上后端

## 1. 扫码时手机弹「运行环境存在风险，暂无法连接」

**这是最常见、也是最费时间的一关。** 定性：腾讯按**出口 IP** 做风控，
云电脑 / 机房 IP 扫码绑定会被拦。二维码在服务端约 **121 秒**过期且不回错误码——
反复续码、换客户端都没用（官方仓库有同款 issue）。

解法：

1. **只在绑定阶段**让 wx-bot 流量改走用户家庭网络出口：
   例如经 Tailscale 到家里一台 Mac/PC 上临时开个代理，wx-bot 经本机中转代理链过去
2. 扫码一次通过。**绑定成功立刻切回机房直连出口**——实测直连收发都正常，
   家庭代理窗口随手关掉，中转只为绑定、不长期挂

操作细节：

- 用 `setsid nohup` 让登录进程脱离当前命令：
  `wx-bot login muse --qr-png <路径> --timeout 10m`
- 每张二维码约 2 分钟有效：日志一出现新的 `QR PNG: <路径>`，立刻把**原图**发给用户扫，
  中间不做别的事；**不要改名 / 不要复制到固定文件名**（聊天按文件路径缓存图片，
  同路径会一直显示第一张过期码）
- 只有绑定用户本人的 wxid 进白名单

## 2. 服务 active 但 health 非 0

**active ≠ 可用。** 验收只认 `wx-bot health --binding muse --grace 0` 的**退出码**，
0 才算接通。服务起来了但 health 失败，常见原因：

- `env` 里没写代理（见第 0 节）
- 登录态失效（见第 3 节）
- 按 health 输出的提示 + 上游仓库的
  [troubleshoot.md](https://github.com/lawrencewzen/wx-bot/blob/main/docs/agents/troubleshoot.md)
  处理，不要只看服务状态就告诉用户「装好了」

## 3. send 报 expired / -14（登录过期）

含义是登录过期（二维码登录态丢了、账号被挤掉等）。处理：
重新扫码登录（流程同第 1 节，但此时已绑定过，走直连通常没问题；
如果还被风控拦，再借一次家庭出口），然后 `systemctl restart wx-bot`，
等 15 秒 `health --grace 0` 退出码 0 验收。

## 4. send 报 no context_token

含义是对方还没先给 ClawBot 发过消息。解法：让对方（用户本人微信）
先给 ClawBot 插件发一条消息，再回复。不是桥的故障。

## 5. 收件箱消息重复唤醒

处理完没 ack，30 分钟租约到期会重新投递。闭环要求：

- 逐条处理完逐条 `wx-bot inbox ack <event_id>`
- 同一 `event_id` 只处理一次（重复投递进来只 ack、不重复回复）
- `kind=alert` 的事件是 wx-bot 的异常通知（连不上微信、登录过期、已恢复），
  不是微信消息：把 `alert.message` 和 `alert.hint` 用中文转报到主聊天，
  不要用 `wx-bot send` 回微信，然后照常 ack

## 6. 二维码图发过去总是同一张旧码

聊天按文件路径缓存图片，每次新码必须用**新路径**发原图；
把文件改名或复制到固定文件名，聊天端会一直显示第一张过期码。

## 7. 被平台替换的云 VM：服务突然消失

会被替换的 VM 在替换后 `/etc/systemd/system` 下的 unit 消失、服务全灭
（登录态在 home，不受影响，不用重扫）。治本办法是按
[docs/WECHAT-BRIDGE.md](../docs/WECHAT-BRIDGE.md) 第 2 节第 6 步加 **watchdog hook**：
60 秒轮询，unit 被清掉就自动重装并拉起。没有 watchdog 的环境，
按部署第 4 步手动重装单元文件并 `enable --now` 即可。

写 watchdog 时有一条硬性要求：**unit 文件不存在时必须立即重装、不许走
失败计数/防抖**——unit 缺失是换机后的确定状态，套上多轮计数只会让每次
断线白白多出约 2 分钟（实测对比：走计数约 2–3 分钟恢复，加快速分支后
模拟删 unit 仅 38 秒恢复）。防抖只用于「unit 存在但 health 失败」的
瞬时抖动。另外注意：若断线长达数小时且**没有任何告警**、两个 hook 的
日志同一分钟一起断档，那是运行环境整体停摆，机内自愈原理上救不了，
看 [docs/WECHAT-BRIDGE.md](../docs/WECHAT-BRIDGE.md) 坑四，不要当桥的 bug 追。

## 验收（三条全过才算接通）

1. `wx-bot health --binding muse --grace 0` 退出码 0
2. 用户微信给 ClawBot 发一条消息，Muse 能收到并回复
3. `wx-bot send --image` 发图能送达
