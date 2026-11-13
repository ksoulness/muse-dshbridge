# 接管须知（2026-11-13）

> 一句话：**系统层的接管回答「这套机器和通道谁维护、坏了谁修」；Bot 层的接管回答「谁在读门铃、谁写单、谁回执、谁向用户汇报」。** 两者对象不同、边界不同，别混为一谈。

## 一、两个「接管」的区别

| | **DSH 侧系统接管** | **DSH Bot 接管** |
|---|---|---|
| 对象 | 8443 车道（适配器 / `tailscale serve` / 看门狗 / 队列目录 / 门铃钩子）、`muse-dshbridge` 技能 | 一个具体的 DSH Bot（当前为「**Muse 联络**」） |
| 回答什么 | 通道由谁部署维护，挂了谁按恢复命令拉起来 | 谁读门铃、谁写单、谁回执、谁对用户负责 |
| 交接物 | 配置、计划任务、日志与心跳路径、恢复命令、验收四连 | 技能入口、回报口径、确认门、归档分工 |
| 变动频率 | 很低（部署级，一次性） | 可换人，换 Bot 不改通道与协议 |
| 现状 | 2026-11-13 之前已完成：20 个工具（含 `pickup/report/status`）、serve 映射、看门狗 | **2026-11-13 20:35 起由「Muse 联络」bot 接管**，工作区 `E:\Code\muse` |

一句话记住：**换 Bot 不动线，动线不换 Bot。**

## 二、Muse 侧接管注意事项（给 Muse 自己）

1. **通道只有两条，方向不对称**：正向（Muse → DSH）走 tailnet 直连 `https://win.<tailnet>.ts.net:8443/mcp`；反向（DSH → Muse）只能是「门铃 + 自取」——你的运行环境 tailscale 仅出站、无 serve/funnel，DSH 永远连不进你。
2. **反向单自动接受**：门铃 `muse-doorbell` 到达 → 唤醒 → `pickup` 取正文 → 自行 accept 并执行 → `report` 回执落 `done/<id>.result.json`。**四类硬卡点仍先报用户批准**：付款/支付、凭据、删除与不可逆改动、在任何机器上新增程序或任务线或换用途。
3. **GitHub 私库兜底单不适用自动接受**，仍逐单走四型回执（accept / edit / respond / ignore）。
4. **归档只归自己派的**：`tools/sweep_archive.py` 只归档 `runs-ledger.jsonl` 里自己派出过的会话；DSH 自己的会话、DSH 派给你的单，一律不碰。整个事项结束才归档，归档后回读复核 `archived: true, running: false`。
5. **换人不换协议**：DSH 侧换 Bot 时，`pickup / report / status` 的语义与队列位置不变，你不需要改任何部署或提示词。

## 三、DSH Bot 接管注意事项（给「Muse 联络」）

1. **每轮开工先体检**：按 `dsh-remote-mcp-lane` 技能的一分钟体检跑四连（serve 映射 / 看门狗心跳 `cycle-ok … serve-ok` / 任务 `Last Result: 0` / 端到端 `health=200`）。
2. **体检有异常只做一件事**：把**已挂掉的既有服务按原样拉起**（重建看门狗任务、增量恢复 serve 映射），做完立刻报一句；其余修复动作一律先报用户。
3. **确认门不可越**：改配置、重启适配器、删数据、改计划任务、动 tailscale 一律先报；Muse 提的此类请求只能原样转达，不许替用户答应。四类硬卡点同样不自动。
4. **派单只走一条**：`submit-task.mjs` 入队 + 门铃；入队失败或 8443 不通才切 GitHub 兜底（该路仍逐单四型回执）。任务正文不写任何机密值。
5. **回头读结果**：`queue\done\<id>.result.json`，字段 `resolution / status / evidence / reported_at`；`pending` 里留着已回执的旧单是设计（pickup 不删），不是积压。
6. **本机自测只用 MagicDNS 名**（`win.<tailnet>.ts.net`），用 100.x 会 schannel hairpin 假故障。

## 四、归档分工（2026-11-13 用户定）

谁派的单，谁把自己这侧的会话收干净；**不代对方归档**。

| 派单方向 | 归档责任 | 具体动作 |
|---|---|---|
| **Muse → DSH**（正向 run） | **Muse** | 事项全部结束后 `archive_terminal_session { session_id, confirm: true }`，再 `list_workspace_sessions` 回读 `archived: true, running: false`；新派单前用 `sweep_archive.py` 清自己派出的旧会话 |
| **DSH → Muse**（反向单） | **DSH 侧（Muse 联络）** | 为跟进该单在本机新开的对话，事项结束后由自己归档并回读复核；Muse 侧因该单产生的对话由 Muse 自己在其宿主内收尾 |
| GitHub 兜底单 | 按上面两条同规则 | 同上 |

硬边界：`archive_terminal_session` 是 DSH 侧本地工具，Muse 用它归档自己派的 DSH 会话属正常；反过来 DSH 不碰用户自己的会话、也不按标题/日期批量归档。

## 五、两边怎么联系（Muse 与 Muse 联络）

- **Muse → DSH**：调 8443 的 `start_run`（工作区默认 `E:\Code\muse`）。要让终态门铃放行，任务以 `muse指派` 开头，或在 `serviceId` 白名单内。
- **Muse → 给「Muse 联络」传话/问状态**：同样走 8443，派一个**只读** run（`start_review`）到 `E:\Code\muse`，标题前缀 `致 Muse 联络：`，正文写清要问什么、要什么证据。它在 5 秒级被 relay 调度，不需要你在 DSH 侧另建入口。
- **DSH → Muse**：`submit-task.mjs` 入队 + `muse-doorbell` 门铃；你被唤醒后 `pickup` → 执行 → `report`。
- **不要做的事**：不向对方索要 relay 静态 Bearer；不把机密写进任务正文、队列或本仓库；不在单子里写「不用问直接执行」。

## 六、验收（任何一方接管后都要能过）

- 反向：DSH 入队 → 门铃 200 → Muse `pickup` → `report` 落 `done/`，全链 ≤2 分钟（2026-11-13 实测 70 秒）。
- 正向：Muse `start_run` 只读单 → 终态门铃到 → 取回终态正文 → 归档并回读 `archived: true, running: false`。
- 车道：体检四连全绿。
