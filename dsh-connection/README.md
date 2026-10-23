# DSH 的连接

把云端 Meta Muse（云电脑上的个人 agent）接到用户 Windows 电脑上的
DSH（DeepSeek Harness），实现远程派单、执行、验收的受控通道。
这是**连接部分**：通道怎么打通、token 怎么来、客户端怎么干活。
派单定式与完整方法见 [docs/DSH-CONTROL.md](../docs/DSH-CONTROL.md)，
交给 Muse 的技能手册见 [skills/dsh-relay-operation/SKILL.md](../skills/dsh-relay-operation/SKILL.md)。

## 1. 通道结构

```
Muse（云电脑）
  │  HTTPS + OAuth Bearer，Tailscale 隧道
  ▼
https://win.<tailnet>.ts.net:8443        ← Tailscale Serve（tailnet-only）
  │  http://127.0.0.1:18081
  ▼
DSH-Remote-MCP 适配器（第二实例，独立 OAuth 库 state-tailnet/）
  │  Authorization: Bearer <relay-token>（本机文件，按 mtime 自动重读跟随轮换）
  ▼
DSH Relay MCP  http://127.0.0.1:3079/plugins/dsh-relay/mcp
  ▼
DSH 本体（会话按工作区原生归属）
```

（示意图里的主机名是占位，部署时替换为你自己的）

### 为什么不能直连 Relay

Relay 的 `RequestPolicy.authorize` 在源码层面锁死：请求来源必须是 loopback，
且 `Host` 必须在硬编码白名单 `{127.0.0.1:3079, localhost:3079}` 内，
否则在校验 Bearer 之前就回 `403 HOST_REJECTED`。经 Tailscale Serve 转发时
Host 是 tailnet 主机名，必然被拒；强行改 Host 头，Serve 直接断连。
**远程必须经一个跑在 Windows 本机内的适配器中介**，没有例外。

### 为什么不用公网桥

同一台机器另有公网实例（Cloudflare Tunnel → `:18080`，见姊妹项目
[dsh-gptbridge](https://github.com/ksoulness/dsh-gptbridge)），那是给 ChatGPT 连接器的。
Muse 专用 tailnet 通道的好处：不经公网、不经第三方、客户端与令牌库完全独立，
出问题互不影响。

### 适配器运维（Windows 侧）

- 计划任务 watchdog 每分钟探活，进程被杀 10 秒内自愈拉起——
  所以你会看到适配器进程 PID 频繁变化，**那是人为操作与自愈验证，不是崩溃**
  （日志无崩溃栈时不要按「不稳定」处理）
- 适配器每次调上游前按 mtime 重读 `relay-endpoint.json`，
  DSH 重启轮换 relay token 后自动跟随，无需人工同步
- 残留风险只有秒级窗口：DSH Web（3079）重启的 1~2 秒、token 轮换瞬间；
  客户端遇到空响应先等 30 秒重试

## 2. 鉴权：OAuth + 自续 token

- 适配器是 OAuth 2.1 授权服务器：`/.well-known/oauth-authorization-server`、
  `/register`（DCR）、`/authorize`（所有者口令 + CSRF）、`/token`（PKCE S256）、`/revoke`；
  scope 统一 `dsh:read`
- token 只能在 Windows 侧签发（所有者口令只有 scrypt 哈希，读不出原值；
  签发脚本一把跑完 register → authorize → token）
- 客户端拿到 **access（1 小时）+ refresh（30 天滚动）** 后自续：
  调 `/token` 用 `grant_type=refresh_token`
- **轮换纪律（源码已核，违反会全族吊销）**：每次 refresh 后旧 refresh 立即作废、
  旧 access 立即失效；**重放旧 refresh 会吊销整个 token 家族**。
  所以客户端 refresh 后必须**先把新 token 对原子落盘（600 权限文件），再继续干活**
- relay 的静态 Bearer 永不离开 Windows，不经聊天、不进任何仓库

> ⚠️ 已知设计问题（使用前须知）：当前 scope 塌陷——单个 `dsh:read` 即可驱动
> `start_run / steer_run / cancel_run`，且适配器对 `start_run` 默认注入
> `danger-full-access`。派**实施类**任务前先和所有者确认权限档位；
> 只读任务走 `start_review`（固定 read-only）不受影响。

## 3. 建立连接（三步）

1. **Windows 侧**：DSH 运行中（Relay 插件启用）；适配器起第二个实例监听本机
   `:18081`（独立 OAuth 库），`tailscale serve` 把 tailnet 的 `:8443` 指给它
2. **云端**：客户端向 `:8443` 动态注册（DCR），所有者在本机浏览器走完 OAuth 授权
   （口令只在本机输），拿到 access + refresh 对
3. 之后一切走技能手册：[skills/dsh-relay-operation/SKILL.md](../skills/dsh-relay-operation/SKILL.md)

## 4. 客户端与派发流程

客户端 [tools/dsh_client.py](../tools/dsh_client.py)：token 自续 + 台账 + 长超时重试。
MCP 端点是无状态的（每次 POST 新建 transport），客户端进程不必常驻；
但**台账必须落盘**：`runs-ledger.jsonl` 记每单的 started / terminal 两行
（含 assistantText 全文截断备份）。

```
doctor → list_workspaces（复核）→ list_capabilities（确认默认模型）
  → start_review / start_run（响应里的 runId/operationId/sessionId 立即落盘）
  → wait_run(timeoutMs=30000) 循环，直到终态
       succeeded | failed | cancelled | timeout | orphaned
  → 读 assistantText 自行复核（DSH 的自述 ≠ 验收通过）
  → archive_terminal_session（archived:true 才算归档成功）
  → 写台账 + 按格式回报用户
```

要点：

- **wait_run 单次上限就是 30 秒**（服务端源码定死，传更大无用）；靠循环等，不是靠单次长等
- **运行时长方差极大**：同一个只读元数据问题，实测有 22 秒完成的，也有跑了
  **17 分 33 秒**的。总轮询窗口至少留 20 分钟
- **响应丢失 ≠ 派发失败**：start 的 HTTP 响应没回来时，请求可能已在服务端落地。
  先用**同一 idempotencyKey** 重放或用 `get_operation / list_runs` 对账，
  确认不存在才重试，**绝不换新键重派**
- 回报格式写死，每单必报：**runId、完整 sessionId、起止时间、终态、
  交付摘要（正文要点）、归档状态**

## 5. 已知的适配器层问题：`FORBIDDEN / expired`

现象：某单派发成功、DSH 里也跑完了，事后 `get_run / get_run_summary / wait_run`
全部回 `-32003 FORBIDDEN, reason: "expired"`，正文读不回来。

已由源码核查定性（Relay 0.2.17）：

- 该错误**不是 Relay 发的**——Relay 里根本没有 `-32003 / FORBIDDEN`；
  它的 runs/operations 落盘在 `%LOCALAPPDATA%\dsh-relay\state.json`，重启恢复、
  无 TTL 无删除；Relay 的 `expired` 只指权限回滚租约（默认 24 小时）
- 错误来自生产适配器层（`E:\Code\Tools\DSH-Remote-MCP`）自己的校验路径；
  其确切失效条件待该目录代码/日志定论

应对就是第 4 节的姿势：**不等「事后取回」，在派发当场用 wait_run 循环
消费到终态并落盘**。GPT 侧（公网桥）全程这么做，从未丢单。

## 6. 安全边界

- **relay 静态 token 永不离开 Windows 本机**；对外只有可吊销、短时效的 OAuth token
- 8443 通道 **tailnet-only**，不经公网
- 本仓库**不含任何真实凭据**：token、口令、wxid、tailnet 名均为占位符，
  部署时替换为你自己的
