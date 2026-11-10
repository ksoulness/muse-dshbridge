# launcher/ —— 浏览器侧启动器（muse-only，2026-11-11）

本目录是 Windows 上 DSH 启动器的**当前生效副本**，用于以后换机/恢复时按原路径放回。

## 原路径

| 仓库内文件 | 本机原路径 |
|---|---|
| `DeepSeek-Harness.ps1` | `E:\Code\DSH\launcher\DeepSeek-Harness.ps1` |
| `_remote-stack.ps1` | `E:\Code\DSH\launcher\_remote-stack.ps1` |
| `启动器管理手册.md` | `E:\Code\DSH\launcher\启动器管理手册.md` |

点源关系：`DeepSeek-Harness.ps1` 第 ~119 行 `. (Join-Path $PSScriptRoot '_remote-stack.ps1')`，两者必须在同一目录。
含中文的 `.ps1` **必须 UTF-8 with BOM**（否则 Windows PowerShell 5.1 按 ANSI 解码 → 乱码语法错误）。
入口调用：`pwsh.exe -NoProfile -File "E:\Code\DSH\launcher\DeepSeek-Harness.ps1"`。

## 状态：只剩 muse 内网车道

| 键 | 动作 | 子命令 |
|---|---|---|
| `6` | 启动/修复远程接入（muse 内网 + tailscale serve） | `mcp-start` |
| `7` | 停止远程接入（保留 DSH 与 tailscale） | `mcp-stop` |
| `8` | 远程接入自检（7 项） | `doctor` |

内网链路：`127.0.0.1:18081` 适配器（`E:\Code\Tools\DSH-Remote-MCP\remote\server.mjs`）→
`tailscale serve --bg --https=8443 http://127.0.0.1:18081` →
`https://win.tailbc7c29.ts.net:8443/mcp`，由计划任务 `DSH-TailnetMCP-Watchdog` 每分钟自愈。

## 已删除（2026-11-11，按用户要求）

- gpt 公网车道：Cloudflare 隧道 `dsh-mcp-private`（id `8a575cfd-b943-409b-88a3-22450d7a4da8`）→ `127.0.0.1:18080`，入口 `https://dshmcp.ccwu.cc/mcp`，守护任务 `DSH-PublicMCP-Watchdog`
- codex 本地车道在状态里的第三行显示（relay 插件本体仍在，供 muse 适配器使用）
- 启动器菜单 `[8] 重启公网隧道` / `[P] 切换公网车道` 与子命令 `tunnel-restart` / `lane-public`

**恢复公网车道**：改动前的两份原件（`DeepSeek-Harness.ps1.pre-muse-only`、`_remote-stack.ps1.pre-muse-only`）与全套公网侧配置/守护脚本在
<https://github.com/ksoulness/dsh-gptbridge> → `ops/public-lane-2026-11-11/`，按其中 `RESTORE.md` 的 7 步还原。
