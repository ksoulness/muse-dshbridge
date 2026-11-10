# 给新 Muse 的总入口：学会这两个技能

你（一个新接手的 Muse）要用这个仓库学会两件事：**① 经 tailnet 调用用户 Windows 电脑上的 DSH 派活；② 把用户的微信接给自己。** 按下面顺序读、按清单向用户要东西，不要跳步、不要猜。

## 先读什么（顺序写死）

1. `README.md` —— 两条线的总览与安全边界
2. **技能一（DSH）**：`skills/dsh-relay-operation/SKILL.md`（定式手册，全文执行）+ `docs/DSH-CONTROL.md`（原理与坑）
3. **技能二（微信）**：`docs/WECHAT-SETUP-PROMPT.md`（逐步执行指令，照着做）+ `docs/WECHAT-BRIDGE.md`（原理与规矩）
4. `docs/TROUBLESHOOTING.md` —— 动手前先扫一遍，今晚所有的坑都在里面

## 技能一：调用 DSH —— 你需要先从用户那里拿到什么

代码和手册只是方法，**权限不在仓库里**。开工前确认这四样，缺哪样找用户要哪样：

| # | 需要的东西 | 说明 |
|---|---|---|
| 1 | 你的宿主已加入用户的 tailnet | 通道是 tailnet-only；不在网里，`win.<tailnet>.ts.net:8443` 根本解析不到 |
| 2 | Windows 侧适配器已部署 | DSH 在运行、Relay 插件启用、本机 `:18081` 第二实例 + Serve `:8443` 已配（属用户/DSH 侧工程，本仓库只记录形态） |
| 3 | **一对 OAuth token**（access 1h + refresh 30d） | 只能由用户在 Windows 侧签发后交给你，或用户在浏览器里走完授权把 token 对给你。存进 600 权限的 state 文件（格式见 `tools/dsh_client.py` 头注），**只记位置、不要把值写进任何文档/记忆** |
| 4 | 客户端脚本 | 就用本仓库 `tools/dsh_client.py`（自带 token 自续、台账、空响应重试），不要自己重写 |

**三条铁律（违反过的都付出了丢单代价）：**

- **永远不要向用户索要 Relay 的静态 Bearer token**——那是那台机器的完整执行权，用户已明确拒绝经聊天传递；你只用 OAuth token 对
- **派发前必须二次确认（2026-11-09 改版，旧「不问直接派」已废止）**：默认模型 `wb2api-nas / cn:deepseek-v4.1-flash / high`、默认工作区 `E:\Code\Ops`；用户说「指派 DSH 去完成 `<任务>`」后，先只报确认门——「将使用模型 wb2api 平台的 DeepSeek V4.1 Flash（`wb2api-nas` / `cn:deepseek-v4.1-flash` / `high`），DSH 工作区是 `E:\Code\Ops`，没问题就继续。」（上一条会话已归档、本轮新开会话时在工作区后加注这一句）——等用户回「继续」才派，不调任何 `start_*` 抢跑；无特别建议时走默认 flash（其 reasoningEffort 只有 `low/high/max`，无 `medium`、无 `off`、无 defaultEffort，默认显式传 `high`，不要传 medium/off、也不要省略）；按复杂度分层不取消、但走建议制：Muse 按复杂度（简单→flash/hy3 类、标准/复杂→v4-pro `medium` 起、换家族视角→Gemini）在确认门里建议允许平台内的其他模型、等用户点头才换，档位必须按所选模型自己的 capabilities 清单选（各模型档位不同，有些就没有 medium），mq-gpt 与 antigravity 的 opus 仅用户强制指定才可用；同一事项后续轮次继承已确认选型、不重复确认，整件事沿用同一会话；其余按 SKILL.md 定式补齐，回报必含 runId / sessionId / 起止时间 / 终态 / 交付摘要 / 归档状态
- 派发后用 `wait_run(timeoutMs=30000)` **循环等到终态、当场把正文落盘**；运行时长方差极大（22 秒 ~ 17 分钟都出现过），事后按 runId 取回可能被适配器层 `FORBIDDEN / expired` 拒掉——不要把「事后取回」当保障

验收标准（做到才算学会）：先过确认门（报默认/推荐模型 + 工作区、等用户回「继续」）→ 在确认的工作区派一个只读任务 → 拿到终态 → 正文与事实对得上 → 整件事结束才归档并回读复核 `archived: true, running: false` → 台账里 started/terminal 两行齐全。

## 技能二：连接微信 —— 你需要先从用户那里拿到什么

| # | 需要的东西 | 说明 |
|---|---|---|
| 1 | 用户先在微信装好 ClawBot 插件 | 微信 → 我 → 设置 → 插件 → 安装 ClawBot；没装，扫码也绑不上 |
| 2 | 用户本人扫码一次 | 二维码约 2 分钟一张、滚动刷新；你负责盯日志出新码立刻发图，扫码动作只能用户做 |
| 3 | （云机房环境）绑定阶段的家庭网络出口 | 机房 IP 绑定必被腾讯风控拦；经 tailnet 借用户家里设备上的临时代理过绑定，绑完切回直连。细节在 SETUP-PROMPT 坑一 |

**三条铁律：**

- 只处理绑定用户本人的白名单私聊；**回复微信只发纯文本、不用 Markdown**
- 服务好坏只认 `wx-bot health --binding muse --grace 0` 的**退出码 0**，不看「进程在跑」；且 health 0 不证明能发送（发送会话会单独过期，send 报 `ret=-2` 也可能是它），验收必须含一次真实 send 成功；**重新扫码前先停服务**，重扫后仍报 expired 先查状态目录的 `expired` 残留标记，不要让用户反复扫码（见 WECHAT-BRIDGE.md 坑五）
- 在会被替换的云 VM 上必须装 watchdog hook（/etc 会被清空），否则 VM 一换微信就断；且 watchdog 里 **unit 文件缺失必须立即重装、不走失败计数**，systemd 模板的 StartLimit 两键必须在模板源文件的 `[Unit]` 段（细则见 WECHAT-BRIDGE.md 坑二、WECHAT-SETUP-PROMPT.md 第 8 步）
- 运行环境整体停摆时，机内自愈与告警会一起失效（可无声十几小时）——这在机内无解，部署时要把机外死亡开关的选项摆给用户拍板，不要承诺机内监控能兜住（见 WECHAT-BRIDGE.md 坑四）

验收标准：health 退出码 0 + 用户微信发消息你能收到并回复 + 发图能送达，三条全过。

## 通用纪律（两个技能都适用）

- 凭据（口令、token、key、二维码之外的敏感值）不进聊天明文、不进仓库、不进长期记忆正文；要存就存 600 权限文件，记忆里只记位置
- 付款、密码、人机验证、扫码这类步骤永远留给用户本人；你把流程推到那一步之前为止
- 出错先查 `docs/TROUBLESHOOTING.md`；表里没有的新坑，解决后把条目补回去——这个仓库是活的项目记录
