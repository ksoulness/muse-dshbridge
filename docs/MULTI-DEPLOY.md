# 多机部署：两套形态与门铃拓扑

本文回答两个问题：**这套系统怎么装到第二台、第三台电脑上**；以及**是不是一台 DSH 就要配一个新的门铃**。

先给结论，再给步骤。

---

## 0. 结论先行

### 门铃不按 DSH 数量配

门铃（ntfy topic）是按**收单方**和**方向**配的，不是按发送方配的。所以「一台 DSH 一个门铃」是错的。

| 东西 | 数量关系 | 为什么 |
|---|---|---|
| **`muse-doorbell`（收单铃，DSH→Muse）** | **一个 Muse = 一条** | 收单方只有那一个 Muse；N 台 DSH 都往同一条 topic 发，Muse 读一条流就能收全部单。要区分来源就加字段（`origin_host`），不要加 topic |
| **`muse-run-events`（终态铃，Muse→DSH）** | **一台 DSH = 一条更干净** | 这是广播式推送：所有订阅者都会收到每条事件。多台 DSH 共用一条时，每台都会收到别人的 run 终态，只能靠 `serviceId` / 主机名过滤。N 台机器就建 `muse-run-events-<host>`，事件按来源发到对应 topic |
| **8443 车道（serve + 适配器 + OAuth 库 + relay token）** | **一台 DSH = 一套** | 每台机器有自己的 Relay、自己的 token、自己的证书与 OAuth 注册表。这部分**必须**一机一套，不能共用 |
| **队列目录 `queue/{pending,done}`** | 一机一套（本机工作区） | 反向单的正文与回执落在这台机器自己的磁盘上 |

一句话：**收单门铃按 Muse 数（1 个），回报门铃按 DSH 数（N 个），8443 车道按 DSH 数（N 个）。**

### 两种形态

| | 形态一：我自己的其他电脑 | 形态二：别人的全新一套 |
|---|---|---|
| tailnet | **同一套**（我的 tailscale 账号） | **对方自己的** tailscale 账号 |
| Muse | **同一个**（我的 Muse 实例） | 对方自己的 Muse 实例 |
| ntfy | 我自己的（tailnet 内，或放公网） | 对方自备（自己的 VPS 或公共 ntfy.sh） |
| 工作区 | `E:\Code\muse`（可在各机同名） | 对方自己的路径 |
| 与我的关系 | 同一身份下的多台机器 | **零交集**，只共用这份公开文档 |
| 需要公网 | 不需要 | 不需要 |
| 门铃 | 共用我那一条 `muse-doorbell` | 对方自己的一条 |

---

## 1. 形态一：我自己的其他电脑（同一 tailnet）

拓扑：**一个 Muse + N 台 DSH，同一条 tailnet，共用一个收单门铃。**

```
                    ┌────────── Muse（云电脑，唯一）──────────┐
                    │ dsh_client.py  ── 订阅 muse-doorbell     │
                    │ doorbell daemon ── 订阅 muse-run-events-* │
                    └───┬──────────────────────────▲──────────┘
        tailnet :8443   │                          │ 终态铃（按机分流）
        ┌───────────────┴───┐   ┌──────────────────┴───┐
        │ DSH-A             │   │ DSH-B                │
        │ serve :8443       │   │ serve :8443          │
        │ 适配器 :18081     │   │ 适配器 :18081        │
        │ queue/ (本机)     │   │ queue/ (本机)        │
        └───────────────────┘   └──────────────────────┘
                 └──────────── 都往同一条 muse-doorbell 发 ────────┘
```

### 1.1 新 DSH 机器上要做的事

设新机 tailscale 名为 `win2.<tailnet>.ts.net`。

1. **装 DSH**，确认 `curl http://127.0.0.1:3079/` 回 **401**（401 = 服务在、鉴权在位）。
2. **装 tailscale**，`tailscale up` 登录**同一个账号**，`tailscale status` 记下 DNSName。
3. **拷适配器工程**：把现有 `DSH-Remote-MCP` 整个目录拷到新机同一路径（`server.mjs`、`gateway/`、`auth/`、`scripts/`、`config/`）。
4. **改配置** `remote/config/dsh-remote-mcp.tailnet.json` 两个字段：
   - `publicUrl` → `https://win2.<tailnet>.ts.net:8443`
   - `allowedHosts` → `["win2.<tailnet>.ts.net"]`
   其余照抄：`adapterPort: 18081`、`titlePrefix: muse指派-`、`taskPrefix: muse指派｜`、`runPermissionPreset`（按信任级别调，见 §1.4）。
5. **起适配器** `node remote/server.mjs --port 18081`，`curl 127.0.0.1:18081/health` 要 **200**。
6. **serve 出去**：`tailscale serve --bg --https=8443 http://127.0.0.1:18081`，`tailscale serve status` 要有这条映射（`tailnet only`）。
7. **装看门狗**：拷 `tasks/DSH-TailnetMCP-Watchdog.xml`，改路径与用户名，`schtasks /create /tn "DSH-TailnetMCP-Watchdog" /f /xml "<xml>"`。它负责保活适配器、同步 relay token、探测 serve。
8. **装技能 + 克隆仓库**：技能目录放 `muse-dshbridge`、`dsh-remote-mcp-lane`；`git clone <本仓>` 到工作区。
9. **验收四连**：`/health` 200、`/.well-known/oauth-authorization-server` 200、无 token `POST /mcp` **401**、`serve status` 映射在位；再从 Muse 侧 `access` 一次（走 OAuth 注册，成功即通）。
10. **回报门铃**（可选但推荐）：给新机一条自己的 topic `muse-run-events-win2`，把 Muse 侧终态发送按 `serviceId`/主机名分流。共用一条也能用，但要靠过滤，别让 A 机收到 B 机的终态。

### 1.2 门铃地址两种选择：tailnet 内 / 放公网

| | ① tailnet 内地址（推荐） | ② 放公网 |
|---|---|---|
| 地址 | `http://<ntfy-host>:2586/muse-doorbell` | `https://<公网域名>/muse-doorbell` |
| 谁能订阅 | 只有 tailnet 内的机器 | 任何人（凭 topic 名当半密钥） |
| 前提 | Muse 在这条 tailnet 里 | 需要域名 + 证书 + 反代/隧道 |
| 风险 | 几乎没有 | 会被扫；必须加访问控制 |

**关键约束（必须一起做）**：门铃只带任务 id，**正文要经 8443 `pickup` 取**。所以把门铃放公网，**8443 也必须同时公网可达**，否则 Muse 收到铃却取不到单——铃是响的，单是死的。

两种放公网的方式：
- **tailscale funnel**：`tailscale funnel --bg --https=8443 http://127.0.0.1:18081`，拿到公网 `https://win.<tailnet>.ts.net:8443`。证书自动签，不用买域名；但等于把这台机器的执行入口暴露到公网，**只靠 OAuth 挡门**。
- **VPS 反代**：公网 VPS 上跑 nginx/caddy 反代到 tailnet 或内网，前面加 IP 白名单或 mTLS。多一层可控性，多一台机器要维护。

放公网时必须补三件事：
1. **topic 名换成不可猜的随机串**（`muse-doorbell-<32位随机>`），别用 `muse-doorbell`；
2. ntfy 开 **basic auth 或 access token**，订阅端带凭据；
3. 8443 保持 OAuth + `allowedHosts` 白名单，**绝不放 relay token 出去**。

> 判断标准：如果你要放公网门铃，先问一句「Muse 为什么不能进 tailnet」。能进，就别放公网——省两层风险。

### 1.3 同 tailnet 多机的冲突点

- **同名 host**：两台机器都叫 `win` 会撞 `allowedHosts` 与 `publicUrl`。tailscale 会自动改名（`win-1`），但配置要跟实际 DNSName 对齐。
- **同端口**：`18081` 在各自机器上互不冲突；`8443` 由各自的 serve 管，也不冲突。
- **同一个工作区路径**：`E:\Code\muse` 可以在每台机同名，但**队列互不相通**——每台机的 `queue/pending` 是各自的。Muse 取单要按机器分别取（`pickup` 打到对应 8443）。
- **Muse 侧要记清"这台单属于哪台机"**：给队列条目加 `origin_host`，回执按 host 回写对应机器的 `done/`。

### 1.4 权限预设

配置里 `runPermissionPreset: danger-full-access` 表示 Muse 派进来的 run 拿全权限（可写、可执行）。新机器上线前按信任级别选：
- `read-only`：只读核查、审计用；
- 工作区可写（默认）：常规开发；
- `danger-full-access`：只在完全信任的机器上。

---

## 2. 形态二：别人的全新一套（零交集）

对方**不需要你的任何东西**，除了这份公开仓库。但对方必须自备四件，缺一件不成立：

| 件 | 说明 | 没有会怎样 |
|---|---|---|
| **DSH** | 他自己的 Windows 机器 + DSH 安装 | 没有执行端 |
| **Muse** | 他自己账号里的 Muse 实例（受管容器，不是能装出来的软件） | 只有 DSH，没人来派单，也没有 pickup/report 的对端 |
| **tailscale** | 他自己的账号 / tailnet（免费档够） | 两台机器互相看不见 |
| **ntfy** | 他自己的推送中继（VPS 自托管，或公共 ntfy.sh） | 门铃不响，Muse 不会被唤醒 |

### 2.1 对方要做的步骤

**DSH 侧**（同 §1.1 的 1–9，只把名字换成他自己的）

**Muse 侧**

1. `git clone <本仓>`，先读 `docs/FOR-NEW-MUSE.md`（给新 Muse 的总入口：阅读顺序、三条铁律）。
2. 装技能 `skills/dsh-relay-operation/SKILL.md` 到他的 skills 目录。
3. 配 8443 客户端：从 `https://<他的DSH机>:8443/.well-known/oauth-authorization-server` 发现 → 注册 → 取 token，接到 `tools/dsh_client.py`。
4. 配门铃：`daemon.py` 出站订阅 `<他的ntfy>:<port>/muse-doorbell/json`；`dsh-doorbell-watchdog` 60 秒保活；`dsh-doorbell-inbox` 10 秒扫账本并唤醒。
5. 建目录 `~/workspace/dsh-doorbell/{state,scripts}`，hook 脚本按仓内模板改写路径。
6. 验收：他在 DSH 侧发一单，看 Muse 是否 30 秒内 `pickup`、几分钟内 `report`。

### 2.2 对方必须改的变量清单

| 变量 | 本仓占位 | 换成 |
|---|---|---|
| tailnet 名 | `<tailnet>` | 他自己的 tailnet |
| DSH 机名 | `win.<tailnet>.ts.net` | 他那台机器 |
| 适配器 `publicUrl` / `allowedHosts` | 同上 | 同上 |
| 门铃地址 | `<ntfy-host>:2586/muse-doorbell` | 他自己的 ntfy |
| relay token | `remote/config/secrets/relay-token` | 他那台 DSH 生成，看门狗自动同步 |
| Muse 侧 daemon/hook 路径 | `~/workspace/dsh-doorbell/` | 他容器内实际路径 |
| 工作区 | `E:\Code\muse` | 他的路径 |

### 2.3 与你的边界

- **不同 tailnet**：他的机器看不见你的机器，反之亦然。
- **不同 ntfy**：他的门铃响在他的网络里。
- **不同 Muse**：他不知道你派了什么单，你也收不到他的。
- **唯一的共享物**：这份公开仓库（含脱敏后的技能与文档）。
- 如果他要把自己的 DSH 和**你的** Muse 配上（跨人协作）：那就是跨 tailnet，默认不通，只有两条路——共享 tailnet，或双侧都放公网（门铃 + 8443 一起，见 §1.2）。这属于网络安全边界变更，要单独决定。

### 2.4 一个容易走错的地方

**门铃 + 队列 + 出站订阅这套绕法，是专门为「Muse 是受管容器、只能出站、不能监听」设计的。**

如果对方的 agent 不是这种受限环境（比如一台普通 Linux 上跑自己的 worker，能监听端口），反向根本不用这么绕——直接给对方一个 8443，或者用 SSH 就够了。硬套这套，会白白多出两个常驻组件和一条推送中继。

判断方法很简单：**对端能不能主动监听一个端口并被你连上？** 能，就用直连；不能（或不允许入站），才用门铃 + 队列。

---

## 3. 验收清单（两套通用）

| # | 检查 | 期望 |
|---|---|---|
| 1 | `curl http://127.0.0.1:3079/` | 401 |
| 2 | relay 上游 `initialize`（带 `accept` 与 `protocolVersion`） | 200，`serverInfo.name = harness-relay-mcp` |
| 3 | `curl http://127.0.0.1:18081/health` | 200 |
| 4 | `curl https://<host>:8443/health` | 200，延迟 < 100ms |
| 5 | 无 token `POST /mcp` | 401 |
| 6 | `tailscale serve status` | 有 `:8443 → 127.0.0.1:18081`，`tailnet only` |
| 7 | 看门狗心跳 | `cycle-ok`，`lane=[...=Running/serve-ok]` |
| 8 | 反向单端到端 | 入队 → 门铃 200 → 数十秒内落盘 → `pickup` → `report` |
| 9 | 正向 run 端到端 | 派 run → 终态 → 回读 `assistantText` → 归档回读 `archived:true, running:false` |
| 10 | 终态门铃 | Muse 账本 `run_events.jsonl` 里能看到该 run 的记录（**这一项最容易漏，见下**） |

> 第 10 项说明：终态铃的放行条件是 `serviceId` 白名单或任务标题以 `muse指派` 开头。实操中遇到过「run 正常跑完但账本里没有终态铃」的情况——此时 `get_run` 能拿到结果，但 Muse 侧不会自动被提醒。新装环境务必单独验这一条，别只看 run 成功。

---

## 4. 常见错误

| 错误 | 后果 | 正确做法 |
|---|---|---|
| 每台 DSH 建一条新的收单门铃 | N 条 topic 白建，Muse 要订阅 N 条流 | 收单铃一条，按 Muse 数配 |
| 多台 DSH 共用一条回报铃又不做过滤 | 每台都收到别人的终态，误报 | 按 host 分流 topic，或严格按 `serviceId` 过滤 |
| 只把门铃放公网、8443 留在 tailnet | 铃响了，Muse 取不到单 | 两个一起放，或都不放 |
| 公网门铃用可猜的 topic 名 | 被人订阅、探测单号 | 随机 topic + ntfy 鉴权 |
| 把 relay token 拷给别人 | 等于把整台机器的执行权交出去 | 只给 OAuth；token 永不离开本机 |
| 对端能监听却硬套门铃 | 多两个组件、多一条故障链 | 能直连就直连 |

---

## 5. 相关文档

- [INTEROP.md](INTEROP.md)：整体互通全景，为什么反向只能门铃 + 自取
- [TAKEOVER.md](TAKEOVER.md)：两类接管的区别、归档分工、两边怎么联系
- [FOR-NEW-MUSE.md](FOR-NEW-MUSE.md)：给新 Muse 的总入口
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md)：车道故障判定树
