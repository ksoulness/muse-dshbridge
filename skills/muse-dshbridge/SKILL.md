---
name: muse-dshbridge
description: 当老大说「问 Muse」「让 Muse 查一下」「给 Muse 派活」「让 Muse 做 X」「Muse 帮我看下」这类话术，需要把一件事交给 Muse 处理时使用——本技能是 **muse-dshbridge 双向互派系统在 DSH 侧的入口**（与 GitHub 仓 ksoulness/muse-dshbridge 及 Muse 侧技能 dsh-relay-operation 同源同版；2026-11-13 由 ask-muse v3.0.0 更名而来，协议口径一字未改）。默认走**实时指派通道**（本地队列 + ntfy 门铃，Muse 被门铃实时唤醒、自动接受执行，无需 LEE 逐单确认；硬卡点除外）；入队脚本不可用时兜底走 GitHub 私有收件箱（该路仍要过 LEE 确认门）。本技能固化通道操作：入队、回报 task id、结果回读。触发词：问 Muse、让 Muse 查、给 Muse 派活、派给 Muse、Muse 帮我看、问下 Muse、让 Muse 判断。
metadata:
  version: "3.1.2"
  date: "2026-11-13"
  renamed_from: "ask-muse v3.0.0（2026-11-13 更名，协议不变）"
  family: "本机 DSH 专属（DSH⇄Muse 双向互派系统的 DSH 侧入口；DSH→Muse 双通道：实时队列为默认，GitHub 收件箱为兜底）"
  same_source: "GitHub 仓 ksoulness/muse-dshbridge + Muse 侧技能 dsh-relay-operation"
  redacted: "公开仓脱敏版：tailnet 主机名与 ntfy 地址为占位符，本机部署版保留真值"
---

# muse-dshbridge（把活派给 Muse —— DSH 侧入口）

> **这是什么**：muse-dshbridge 是 Muse⇄DSH 双向实时互派的统一系统。本技能是它在 **DSH 侧的派活入口**，与 GitHub 仓 `ksoulness/muse-dshbridge`、Muse 侧技能 `dsh-relay-operation` **同源同版**（原名 `ask-muse`，2026-11-13 更名对齐，协议一字未改）。
> 正向（Muse → DSH）由 Muse 侧技能 dsh-relay-operation 负责；反向（DSH → Muse）由本技能负责。

## 〇、一句话

**默认走实时通道**：`submit-task.mjs` 一步完成「写队列 + 发 ntfy 门铃」，Muse 被门铃实时唤醒、**自动接受执行**（不再等 LEE 逐单批准），结果经 MCP `report` 落到 `done/<id>.result.json`。
**GitHub 私有收件箱降为兜底**：仅当入队脚本失败、或 8443/适配器不可用时才走，且该路**仍要过 LEE 确认门**。

| | 实时通道（默认） | GitHub 收件箱（兜底） |
|---|---|---|
| 入口 | `E:\Code\Tools\DSH-Remote-MCP\remote\scripts\submit-task.mjs` | `E:\Code\Ops\dsh-to-muse-inbox\dsh-helper\submit_task.py` |
| 存哪 | `E:\Code\muse\queue\pending\<id>.json` | 私有仓库 `inbox/<id>.md` |
| 唤醒 | ntfy 门铃，秒级 | watcher 每 5 分钟 pull |
| 谁批 | **Muse 自动接受执行**（硬卡点先报 LEE） | **LEE 逐单四型回执** |
| 结果 | `E:\Code\muse\queue\done\<id>.result.json` | `outbox/<id>.result.md` → `done/` |
| kind | `task` / `question` | `question` / `read-only` / `action` |

## 一、默认：实时通道（先走这条）

```bash
node "E:/Code/Tools/DSH-Remote-MCP/remote/scripts/submit-task.mjs" \
  --title "一句话标题" \
  --kind task \
  --slug 可选英文短标识 \
  --body "给 Muse 的正文（要它做什么，范围写具体）"
```

- `--kind`：`task`（要它动手/查并回执）或 `question`（只要一句判断）。
- 可选 `--task-file body.md` 从文件读正文；`--thread <id>` 串多轮；`--blocked-by <id>` 串依赖；`--priority urgent`。
- 脚本做的事（一步到位）：生成 id（北京时间 `YYYYMMDD-HHMMSS-<slug>-<4hex>`）→ 疑似机密扫描（命中即拒写）→ 原子写 `pending/<id>.json` → POST 门铃 `http://<ntfy-host>:2586/muse-doorbell`（只带 id，正文走 8443 pickup）。门铃失败**不回滚入队**，只把 `doorbell_error` 记进条目。
- 脚本会打印：`enqueued <id>` / `enqueued_at <ISO+08:00>` / `doorbell_ok <bool> http_status <码>`。

**回报口径（实时路）**：给老大 **task id** + 说明「Muse 会被门铃实时唤醒、自动接受执行，结果经 report 落到 `E:\Code\muse\queue\done\<id>.result.json`，可回读核对」；顺带报入队时间、门铃 POST 时间与 HTTP 状态。

### 1.1 Muse 侧怎么接单：自动接受 + 硬卡点不自动

Muse 侧口径（与 Muse 侧技能 `dsh-relay-operation`、仓库 `ksoulness/muse-dshbridge` 一致，2026-11-13 定）：

1. 门铃到达 → 守护进程落盘 → 唤醒 hook 叫醒主会话 → 经适配器 `pickup` 取正文。
2. **Muse 自行 accept 并执行正文**，不再逐条向 LEE 汇报等四型回执；执行后按重要程度向 LEE 简报（联测/只读/常规单简报即可，失败或异常才展开）。
3. **硬卡点不自动、仍先报 LEE 批准**：付款/支付、凭据、删除与不可逆改动、在任何机器上新增程序/新任务线/换用途（2026-11-03 规矩），以及明显超出单子本身范围的扩张。
4. **GitHub 私库收件箱的兜底单不适用自动接受**，仍走其原确认门（每单先报 LEE、批准后才执行）。

所以派单时：正文写清范围与禁区即可；碰到上面四类硬卡点的事，回报里要写明「此单为硬卡点，Muse 会先报 LEE 批准、不会自动执行」，不要把硬卡点包装成普通单。

## 二、兜底：GitHub 私有收件箱（只在下面情况切）

切换条件（满足任一即切，切了就按这条路的规矩走）：
1. `submit-task.mjs` 报错退出（非零码、`ERROR: ...`、Node 缺失）；
2. 门铃一直失败且 `https://win.<tailnet>.ts.net:8443/health` 不通（8443/适配器不可用）；
3. 老大明确要求走 GitHub 确认门那条路。

```bash
cd "E:/Code/Ops/dsh-to-muse-inbox"
git pull   # 先拉，避免 Muse 侧移动文件导致 push 冲突

python dsh-helper/submit_task.py \
  --title "一句话标题" \
  --kind question|read-only|action \
  --priority normal|urgent \
  --slug 可选英文短标识 \
  --body "## 任务里的正文内容" \
  --acceptance "验收标准" \
  --excluded "不许碰的禁区，默认「无（按默认边界）」" \
  --thread "thread_id" \
  --blocked-by "须先完成的另一单 id"
```

- 仓库：`https://github.com/ksoulness/dsh-to-muse-inbox`（私有）；本机 clone 固定在 `E:\Code\Ops\dsh-to-muse-inbox`，勿挪动。
- 脚本自检机密模式，命中会拒绝提交——铁律，不要绕过；有 `--dry-run` 可先试跑。
- 状态判断：`inbox/` 无 ack = 还没被扫到（最多等 5 分钟）；`inbox/` 有 ack = Muse 已收到、在等 LEE 四型回执；`processing/` = LEE 已批准正在执行；`done/` + `outbox/<id>.result.md` = 闭环。

**回报口径（兜底路）**：给老大 **task id** + commit hash（`git log -1 --format=%H`）+ 明确说明「这一单要过 LEE 确认门，Muse 不会自动执行」。

## 三、kind 怎么选

| 场景 | 实时通道 kind | 兜底路 kind |
|---|---|---|
| 要 Muse 动手做/改/跑，并回执 | `task` | `action` |
| 要 Muse 查一下/核对数据（只读） | `task`（正文写明只读） | `read-only` |
| 只要一句判断/意见/状态 | `question` | `question` |

老大说「问 Muse / 让 Muse 判断」→ 判断类；「让 Muse 查一下 / 帮我看下」→ 只读类；「让 Muse 去做 / 改 / 弄好」→ 动手类。

## 四、铁律（禁放机密）

- **不写任何机密值**：密码、token、API key、银行卡、私钥、一键登录链接一律不进任务正文/文件（队列是本地明文 JSON，git 历史也删不干净）。
- 需要 Muse 用某个已存凭证时，只写「用保险库里的 X 站登录」，不写值。
- 一单一件可独立验收的事；多件事拆多单。
- 不传大文件/二进制（实时路正文建议 < 200KB）。
- 不在任务里指示 Muse 绕过任何确认门、不写「不用问谁直接执行」。
- 不自己去催 Muse、不重复提交同一单（同 id 重推会被去重）。

## 五、结果怎么回读

实时通道：

```bash
ls "E:/Code/muse/queue/done/"            # 找 <id>.result.json
cat "E:/Code/muse/queue/done/<id>.result.json"
```

- 字段：`resolution`（`accept`/`reject`）、`status`（`completed`/`failed`/`rejected`/`canceled`）、`evidence`（Muse 拼的证据文本）、`reported_at`。
- `pending/<id>.json` 仍在但 `done/` 无 result = 还没被 pickup 或还在做；`report` 幂等，同 id 二次回执返回 `already_reported`。
- 也可经 MCP 工具 `status` 看 `pending_count / last_pickup_at / last_report_at`。

兜底路：

```bash
cd "E:/Code/Ops/dsh-to-muse-inbox"; git pull
cat outbox/<task-id>.result.md     # 先看 resolution / status，再读正文
```

- `resolution` 四型 = `accept` / `edit`（改了范围，result 里注明）/ `respond`（只回一句话，没动对象）/ `ignore`。
- `status` 终态只用 `completed` / `failed` / `rejected` / `canceled`（对齐 A2A）。
- 若 `ignore`（canceled）或 `rejected`，把理由报给老大，不擅自改单重提。

## 六、报错怎么办

- 实时路失败 → **先如实报原文**，再按第二节切兜底路，并在回报里写明「为什么切」（失败原文 + 切换判定）。
- 不换路绕行、不静默降级、不假报成功。

## 七、归档分工与 DSH 侧接管（2026-11-13 LEE 定）

- **谁派的单谁归自己那侧的会话**：Muse 派给 DSH 的 run，由 Muse 自己 `archive_terminal_session` 并回读 `archived:true / running:false`；DSH 派给 Muse 的一单，DSH 侧为此在本机新开的对话由 DSH 自己归档。两侧都不代对方归档，也不动老大自己的会话。
- **DSH 侧联络人**：DSH 这头的收发、回报、守夜由「Muse 联络」bot 负责，工作区 `E:\Code\muse`。Muse 要它做事走 8443 `start_run` / `start_review`，标题前缀「致 Muse 联络：」；终态门铃放行仍需 task 以 `muse指派` 开头或 serviceId 在白名单。
- **两类接管别混**：系统接管（8443 适配器 / serve 映射 / 看门狗 / 队列 / 门铃钩子，答「谁维护、坏了谁修」）与 Bot 接管（谁读门铃、谁写单、谁回执、谁对老大负责）分开说——换 Bot 不动线，动线不换 Bot。口径见仓库 `docs/TAKEOVER.md`。

## 八、实测基线（2026-11-13 20:42–20:47 双向互派首测）

- DSH → Muse：入队 20:42:46 → `report` 回执 20:47:35，合计 4 分 49 秒（含 Muse 两次派 run）。
- Muse → DSH：20:46:26 派发 → 20:46:46 succeeded → 终态门铃 20:46:48 到 Muse 账本，单次 **27.1 秒**。
- 另一条：那次 run 里的 DSH agent 自发回派单 `20261113-204411-mutual-test-return-e342`，20:44:11 → Muse 回执 20:45:34（**83 秒**）。注意：run 里的 agent 会自己往 `queue/pending` 写单。
- 归档复核：两个 Muse 派出的会话在本机 fleet 回读均 `archived:true / running:false`，分工真实生效。

## 九、报告去向（2026-11-13 20:50 LEE 定，对齐 Muse 侧）

- **Muse 侧**：Muse⇄DSH 互相指派的派发回报与终态完成报告，统一发到专用旁聊（Muse 内部对话，id 不入库），不再发主聊天；细节以仓库 `skills/dsh-relay-operation/SKILL.md` 的「报告去向」节为准。
- **DSH 侧**：老大的指令在哪下、回报就回哪（通常是本对话）；不往旁聊贴报告，公开仓不写 chat id 明文。
- **跨侧派单**：pending 登记里写清 `origin_chat_id`，终态回执才会落回发起处。

## 十、本仓库版与本机版的关系

- 本文件在公开仓里是**脱敏版**：tailnet 主机名、ntfy 地址写成 `<tailnet>` / `<ntfy-host>` 占位符；本机部署版（`D:\Program Files\DSH\agents-home\skills\muse-dshbridge\SKILL.md`）保留真值。
- 改动要两边同步：先改本机验证可用，再脱敏回推仓库；两版除占位符外必须一致。

## 十一、发单后必须挂回执等待（2026-11-13 补，教训）

- **问题**：Muse 的 `report` 只落 `queue/done/<id>.result.json`，**没有任何东西推给 DSH 侧**。发完单这一轮就结束，回执到了也没人知道——只能等 LEE 问一句「回了吗」。这是 DSH 侧自己的缺口，不是 Muse 的问题。
- **规矩**：`submit-task.mjs` 入队成功（`doorbell_ok true`）后，**同一轮内必须挂一个后台等待**，落地即报；不许发完就收工。
- 模板（后台 job，最长 15 分钟，落地即出结论；job 结束会自动叫醒本会话）：

  ```bash
  id=<单号>; for i in $(seq 1 90); do f="E:/Code/muse/queue/done/$id.result.json"; if [ -f "$f" ]; then PYTHONIOENCODING=utf-8 python -c "import json,io,sys;d=json.load(io.open(sys.argv[1],encoding='utf-8'));print(d['reported_at'],d['resolution'],d['status']);print(d['evidence'])" "$f"; exit 0; fi; sleep 10; done; echo "TIMEOUT-15min $id"
  ```

- 15 分钟没落地：用 `schedule_create` 再挂一次提醒（30 分钟），同时按兜底判定查 8443 探活与门铃（200 但无 pickup = Muse 侧没醒；门铃失败 = ntfy 侧问题）。
- 这条不改通道、不加常驻程序或计划任务，纯会话内等待。
