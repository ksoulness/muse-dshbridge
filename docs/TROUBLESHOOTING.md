# 故障速查（两条线，全部实测过）

## DSH 线

| 现象 | 定性 | 处理 |
|---|---|---|
| 经 Serve 访问 Relay 路径回 `403 HOST_REJECTED` | Relay 源码锁死：来源须 loopback 且 Host 在白名单内，Bearer 校验之前就拒 | 放弃直连；远程必须经 Windows 本机内的适配器（8443 通道） |
| 适配器进程 PID 一天变好几次 | 多为人为操作（打补丁、杀进程验证自愈、计划重启）+ watchdog 拉起，日志无崩溃栈 | 不要按「不稳定」排期；先看 service 日志有没有崩溃栈 |
| 授权页 POST 回 `csrf verification failed (malformed)` | 回传的 csrf_token 结构损坏（空/没抓到/被截断），与口令无关，校验顺序在口令之前 | 同实例先 GET 拿页 → hidden 字段原样带回 → URLSearchParams 编码 POST，5 分钟内完成。此错不触发口令锁定；另三种为 bad_signature / expired / binding_mismatch |
| 工具调用长时间 Empty reply / 超时 | 多半是 run 本身耗时极长（实测最长 17 分 33 秒）+ start 响应慢，短超时读空是假象 | 单次超时 ≥240 秒、总轮询 ≥20 分钟；`wait_run` 每轮 timeoutMs=30000 循环；不要据此判通道坏 |
| start 响应丢失、不知道派没派成 | 请求可能已在服务端落地 | 用同一 idempotencyKey 重放或 `get_operation / list_runs` 对账；确认不存在才重试，绝不换新键重派 |
| 事后 get_run 回 `-32003 FORBIDDEN / expired` | **不是 Relay 的错**（Relay 无此错误、records 落盘无 TTL）；是生产适配器层的校验，确切条件待其代码定论 | 当场用 wait_run 消费到终态并落盘正文；已过期的只能在 DSH 界面读，或请服务端给 transcript 读取口 |
| `archive_terminal_session` 回 `archive_pending / HTTP_401` | 适配器调 DSH 归档 API 的浏览器授据失效，属 Windows 侧 grant 问题 | DSH 侧修授据后重试归档；会话留在侧栏无害，不要用改库等方式绕 |
| 上游突然 401 / 工具面消失 | DSH 重启轮换 relay token 后适配器未跟随（旧版本静态副本问题） | 新版适配器按 mtime 重读 descriptor 自动跟随；仍异常时查适配器 upstream 配置是否指向活文件 |
| 派发后标题前缀叠加 | 适配器已配置化加 `muse指派｜`，客户端 task 又自带 `muse指派-` | 二选一：适配器加前缀后，客户端 task 不再自带 |

## 微信线

| 现象 | 定性 | 处理 |
|---|---|---|
| 扫码时手机弹「运行环境存在风险，暂无法连接」 | 腾讯按出口 IP 风控，机房 IP 绑定必拦；二维码约 121 秒服务端过期、无错误码 | 绑定阶段改走家庭网络出口（tailnet 到家用设备开临时代理），绑好立刻切回直连 |
| wx-bot 服务 active 但 health 非 0 | env 没写代理、登录态失效等都会这样，active ≠ 可用 | 以 `wx-bot health --binding muse --grace 0` 退出码为准，按输出与仓库 troubleshoot.md 处理 |
| 服务突然消失 / unit 不存在 | 云 VM 被替换，/etc 被清空（登录态在 home 还在） | watchdog hook 自动重装 unit 拉起；没有 watchdog 的环境按部署第 4 步手动重装，不用重扫 |
| 每次 VM 重启后都要断 2–3 分钟才自愈 | watchdog 把「unit 文件不存在」也套了多轮失败计数/防抖，白等好几轮才动手 | 看守加确定性快速分支：unit 缺失不等计数、立即重装拉起（实测恢复 38 秒）；防抖只保留给「unit 存在但 health 失败」；改法见 WECHAT-BRIDGE.md 坑二 |
| 断线数小时无人知晓、没有任何告警，查日志发现两个 hook 日志同一分钟一起断档 | 运行环境整体停摆：看守、检测、告警同机同生共死，停摆期间谁都跑不了；不是桥或某个 hook 的 bug，不要在机内追查 | 机内无解。恢复靠环境被唤醒后自愈；防「无声」只能机外死亡开关（桥每分钟向机外报平安、超时桥外通道报警），装不装由用户拍板；见 WECHAT-BRIDGE.md 坑四 |
| systemd 报 StartLimit 相关 `Unknown key name` / 重启速率限制不生效 | 模板把 `StartLimitIntervalSec` / `StartLimitBurst` 写在了 `[Service]` 段，被 systemd 忽略 | 两键移到 `[Unit]` 段，**必须改模板源文件**并按新模板重装；只改现行 unit 会被下一次自愈重装覆盖 |
| 想把 wx-bot 单独搬到稳定 VPS 根除断线 | pull 投递靠 Muse 在本机执行 `inbox pull/send` 读写本机状态，桥搬走 pull 链路就断 | 迁移必须连投递一起设计：改 webhook、或 hook 经 Tailscale/SSH 远程执行 pull/send、或加转发层；切换先停旧再启新，防双实例抢 cursor；见 WECHAT-BRIDGE.md 坑四 |
| `send` 报 `no context_token` | 对方还没先给 ClawBot 发过消息 | 等对方先发一条，再回复 |
| `send` 报 `expired` / `-14` | 登录过期 | 重新扫码登录 + `systemctl restart wx-bot` |
| 二维码图发过去总是同一张旧码 | 聊天按文件路径缓存图片 | 每次新码用新路径发原图，不要改名/复制到固定文件名 |
| 收件箱消息重复唤醒 | 处理完没 ack，租约（30 分钟）到期重投 | 逐条处理完逐条 `wx-bot inbox ack <event_id>`；同一 event_id 只处理一次 |
| 微信反复收到「Agent 已 X 分钟没处理 / 已恢复处理」成对通知 | wx-bot 内置 stallwatch 阈值硬编码 10 分钟；Agent 回合串行时，长任务、上下文压缩、VM 替换都会让领取延迟超 10 分钟，属误报刷屏 | 按 WECHAT-BRIDGE.md「坑三」打补丁：阈值改 60 分钟并从源码自建二进制；切勿跑 `wx-bot update`（会覆盖回原版） |
