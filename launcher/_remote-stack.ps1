# _remote-stack.ps1 —— DSH 远程接入链路：只剩 muse 内网车道
# 由 DeepSeek-Harness.ps1 点源加载。仅本文件修改链路状态；其余函数只做只读探测。
#
# 拓扑（2026-11-11 起）
#   muse → https://win.tailbc7c29.ts.net:8443/mcp → tailscale serve → 127.0.0.1:18081 适配器
#   适配器反代到 DSH 内置 relay（127.0.0.1:3079/plugins/dsh-relay/mcp）；relay 未就绪时适配器只能空转。
#   历史：gpt 公网车道（Cloudflare 隧道 dsh-mcp-private → 18080）与 codex 本地车道
#   （Codex 插件 stdio 代理）已于 2026-11-11 按用户要求整体删除：无隧道配置、无 18080 适配器、
#   无 DSH-PublicMCP-Watchdog 任务。旧版脚本见 _remote-stack.ps1.bak-20261111-pre-muse-only。

$script:RS = @{
    Root        = 'E:\Code\Tools\DSH-Remote-MCP'
    Node        = 'D:\Program Files\nodejs\node.exe'
    TailnetTask = 'DSH-TailnetMCP-Watchdog'
    TailnetPort = 18081
    TailnetUrl  = 'https://win.tailbc7c29.ts.net:8443/mcp'
}
$script:RS.ServerMjs   = Join-Path $script:RS.Root 'remote\server.mjs'
$script:RS.Watchdog    = Join-Path $script:RS.Root 'scripts\watchdog-tailnet.ps1'
$script:RS.TailnetHb   = Join-Path $script:RS.Root 'logs\watchdog-heartbeat.txt'
$script:RS.Descriptor  = 'D:\Program Files\DSH\plugins\dsh-relay\web\relay-endpoint.json'
$script:RS.Tailscale   = 'C:\Program Files\Tailscale\tailscale.exe'
$script:RS.ServerMatch = [regex]::Escape($script:RS.ServerMjs)

function Test-RsListen {
    param([int]$Port)
    # netstat fast path when the shared launcher helpers are loaded (they always are in
    # DeepSeek-Harness.ps1); Get-NetTCPConnection costs ~1.3 s and used to dominate the menu.
    if (Get-Command Get-DshTcpListeners -ErrorAction SilentlyContinue) {
        return [bool](@(Get-DshTcpListeners -Port $Port).Count)
    }
    [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Test-RsHealth {
    param([int]$Port)
    try {
        $code = & curl.exe --noproxy 127.0.0.1,localhost -sS -o NUL -w '%{http_code}' --max-time 4 ("http://127.0.0.1:{0}/health" -f $Port) 2>$null
        return ($code -eq '200')
    } catch { return $false }
}

function Get-RsAdapterPids {
    param([int]$Port)
    @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $script:RS.ServerMatch -and $_.CommandLine -match ('--port\s+' + $Port + '(\s|$)') } |
        Select-Object -ExpandProperty ProcessId)
}

function Get-RsWatchdogResidentPids {
    # 守护脚本都是「一分钟一次」的短周期调用，正常时抓不到；抓到即说明有常驻循环需要收掉。
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(powershell|pwsh)\.exe$' -and $_.CommandLine -and
            $_.CommandLine -match 'watchdog-(tailnet|adapter)\.ps1' } |
        Select-Object -ExpandProperty ProcessId)
}

function Get-RsTaskState {
    param([string]$Name)
    # Get-ScheduledTask costs ~1 s per call on this host (measured 2026-10-22); schtasks.exe answers
    # the same question in ~70 ms. The cmdlet stays as the fallback when the text parse fails.
    $state = $null
    $result = $null
    $lastRun = $null
    try {
        $text = @(& schtasks.exe /query /tn $Name /fo list /v 2>$null)
        if ($text.Count -gt 0) {
            foreach ($line in $text) {
                if ($line -match '^Status:\s*(.+?)\s*$') { $state = $Matches[1] }
                elseif ($line -match '^Last Result:\s*(-?\d+)\s*$') { $result = [int]$Matches[1] }
                elseif ($line -match '^Last Run Time:\s*(.+?)\s*$') { $lastRun = $Matches[1] }
            }
            if ($state -eq 'Could not start' -or $state -eq '') { $state = $null }
        }
    } catch { }
    if (-not $state) {
        $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $t) { return [pscustomobject]@{ Name = $Name; State = 'missing'; LastResult = $null; LastRun = $null } }
        $i = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Name = $Name; State = "$($t.State)"; LastResult = $i.LastTaskResult; LastRun = $i.LastRunTime }
    }
    # schtasks reports "Ready"/"Running"/"Disabled"; the cmdlet reports the same words.
    $parsed = $null
    try { $parsed = [datetime]::Parse($lastRun) } catch { }
    [pscustomobject]@{ Name = $Name; State = $state; LastResult = $result; LastRun = $parsed }
}

function Get-RsHeartbeatAge {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return -1 }
    try { return [int]((Get-Date) - (Get-Item $Path).LastWriteTime).TotalSeconds } catch { return -1 }
}

function Get-RsServeTailnet {
    # tailscale serve 是否仍把 :8443 指向 18081（只读解析，失败返回 $null）
    try {
        $out = (& $script:RS.Tailscale serve status --json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return $null }
        $serve = $out | ConvertFrom-Json -ErrorAction Stop
        foreach ($site in $serve.Web.PSObject.Properties) {
            if ($site.Name -match ':8443$' -and $site.Value.Handlers.'/'.Proxy -eq 'http://127.0.0.1:18081') { return $true }
        }
        return $false
    } catch { return $null }
}

function Get-RsRelayState {
    $o = [pscustomobject]@{ Descriptor = $false; McpUrl = ''; Token = $false }
    if (Test-Path $script:RS.Descriptor) {
        try {
            $d = Get-Content $script:RS.Descriptor -Raw -Encoding UTF8 | ConvertFrom-Json
            $o.Descriptor = $true
            $o.McpUrl = [string]$d.mcpUrl
            $o.Token = [bool]($d.tokenFilePath -and (Test-Path $d.tokenFilePath))
        } catch { }
    }
    $o
}

function Get-RemoteSnapshot {
    $relay = Get-RsRelayState
    [pscustomobject]@{
        DshUp         = (Test-RsListen -Port 3079)
        Relay         = $relay
        TailnetPids   = @(Get-RsAdapterPids -Port $script:RS.TailnetPort)
        TailnetListen = (Test-RsListen -Port $script:RS.TailnetPort)
        TailnetHealth = (Test-RsHealth -Port $script:RS.TailnetPort)
        TailnetTask   = (Get-RsTaskState -Name $script:RS.TailnetTask)
        TailnetHbAge  = (Get-RsHeartbeatAge -Path $script:RS.TailnetHb)
        ServeTailnet  = (Get-RsServeTailnet)
    }
}

function Format-RsMark {
    param([bool]$Ok)
    if ($Ok) { '✓' } else { '✗' }
}

function Write-RemoteStatus {
    $s = Get-RemoteSnapshot
    Write-Host '远程接入链路（muse 内网）' -ForegroundColor Cyan

    $tnOk = $s.TailnetHealth -and ($s.ServeTailnet -eq $true) -and $s.TailnetTask.State -in @('Ready','Running')
    $color = if ($tnOk) { 'Green' } else { 'Yellow' }
    $hbTxt = if ($s.TailnetHbAge -ge 0) { "$($s.TailnetHbAge)s 前" } else { '无心跳' }
    $serveTxt = if ($s.ServeTailnet -eq $true) { '✓' } elseif ($s.ServeTailnet -eq $false) { '✗' } else { '?' }
    Write-Host ("  [muse 内网]  18081 适配器 {0} pid={1} 健康{2} | serve:8443 {3} | 守护 {4} {5} | {6}" -f `
        (Format-RsMark $s.TailnetListen), $(if ($s.TailnetPids) { $s.TailnetPids -join ',' } else { '-' }), `
        (Format-RsMark $s.TailnetHealth), $serveTxt, $s.TailnetTask.State, $hbTxt, $script:RS.TailnetUrl) -ForegroundColor $color

    if (-not $s.DshUp) {
        Write-Host '  ⚠ DSH 3079 未运行：适配器即使活着也无法派发任务，请先按 [1] 启动。' -ForegroundColor Yellow
    } elseif (-not ($s.Relay.Descriptor -and $s.Relay.Token)) {
        Write-Host '  ⚠ relay 尚未发布 descriptor/token（3079 刚启动时需等几秒）；适配器会自行重试。' -ForegroundColor Yellow
    }
    if ($s.TailnetTask.State -eq 'Disabled') {
        Write-Host '  ⚠ 守护任务处于 Disabled：链路不会自愈，按 [6] 恢复。' -ForegroundColor Yellow
    }
    return ($tnOk -and $s.DshUp -and $s.Relay.Descriptor -and $s.Relay.Token)
}

function Start-RsTailnetAdapter {
    # 直接跑一个 tailnet 守护周期：按 descriptor 刷新 relay token，缺失就拉起 18081 适配器。
    if (-not (Test-Path $script:RS.Watchdog)) {
        Write-Host ("   找不到守护脚本：{0}" -f $script:RS.Watchdog) -ForegroundColor Red
        return
    }
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -ExecutionPolicy Bypass -File $script:RS.Watchdog -Port $script:RS.TailnetPort 2>&1 |
        Select-Object -Last 8 | ForEach-Object { Write-Host ("     " + $_) -ForegroundColor DarkGray }
}

function Enable-RsTasks {
    $bad = @()
    foreach ($n in @($script:RS.TailnetTask)) {
        try {
            $t = Get-ScheduledTask -TaskName $n -ErrorAction Stop
            if ("$($t.State)" -eq 'Disabled') { Enable-ScheduledTask -TaskName $n | Out-Null; Write-Host ("   已启用守护任务：{0}" -f $n) -ForegroundColor Green }
            Start-ScheduledTask -TaskName $n
            Write-Host ("   已触发一次：{0}" -f $n) -ForegroundColor DarkGray
        } catch {
            $bad += $n + '（' + $_.Exception.Message + '）'
        }
    }
    $bad
}

function Wait-RsLane {
    param([int]$Port, [int]$Seconds = 75)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-RsHealth -Port $Port)) { return $true }
        Start-Sleep -Milliseconds 900
        Write-Host ("`r   等待 127.0.0.1:{0} 就绪…" -f $Port) -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''
    return $false
}

function Invoke-RemoteStart {
    param([switch]$Force)
    Write-Host '== 远程接入：启动 / 修复（muse 内网车道）==' -ForegroundColor Cyan

    if (-not (Test-RsListen -Port 3079)) {
        Write-Host '   DSH 3079 未运行 —— relay 是车道的上游，请先按 [1] 启动 DSH，再执行本项。' -ForegroundColor Red
        return $false
    }
    $relay = Get-RsRelayState
    if (-not ($relay.Descriptor -and $relay.Token)) {
        Write-Host '   relay descriptor/token 尚未就绪，先触发一次守护并等待（适配器会自行重试）。' -ForegroundColor Yellow
    }

    Write-Host '   1/3 守护任务（每分钟自愈）' -ForegroundColor Cyan
    $bad = @(Enable-RsTasks)
    foreach ($b in $bad) { Write-Host ("     ✗ {0}" -f $b) -ForegroundColor Red }

    Write-Host '   2/3 等待 18081 适配器健康' -ForegroundColor Cyan
    $tnOk = Wait-RsLane -Port $script:RS.TailnetPort
    if ($Force -or -not $tnOk) {
        if (-not $tnOk) {
            Write-Host '   适配器未就绪，手工跑一次 tailnet 守护周期（刷新 relay token + 拉起适配器）' -ForegroundColor Yellow
            Start-RsTailnetAdapter
            $tnOk = Wait-RsLane -Port $script:RS.TailnetPort -Seconds 40
        }
    }

    Write-Host '   3/3 tailscale serve :8443 → 18081' -ForegroundColor Cyan
    $serve = Get-RsServeTailnet
    if ($serve -eq $true) {
        Write-Host '   映射在位' -ForegroundColor DarkGray
    } else {
        Write-Host '   serve 映射缺失，手工恢复：' -ForegroundColor Yellow
        Write-Host ('     "{0}" serve --bg --https=8443 http://127.0.0.1:18081' -f $script:RS.Tailscale) -ForegroundColor DarkGray
    }

    Write-Host ''
    $all = Write-RemoteStatus
    $all = $all -and $bad.Count -eq 0 -and $tnOk -and ($serve -eq $true)
    if ($all) { Write-Host '远程接入：全部就绪' -ForegroundColor Green } else { Write-Host '远程接入：仍有未就绪项（见上）' -ForegroundColor Yellow }
    return $all
}

function Invoke-RemoteStop {
    Write-Host '== 远程接入：停止（muse 内网车道）==' -ForegroundColor Cyan

    Write-Host '   1/3 关闭守护任务（防止 1 分钟内自动拉回）' -ForegroundColor Cyan
    try {
        Stop-ScheduledTask -TaskName $script:RS.TailnetTask -ErrorAction SilentlyContinue
        Disable-ScheduledTask -TaskName $script:RS.TailnetTask -ErrorAction Stop | Out-Null
        Write-Host ("   已停用：{0}" -f $script:RS.TailnetTask) -ForegroundColor Green
    } catch { Write-Host ("   ✗ {0}: {1}" -f $script:RS.TailnetTask, $_.Exception.Message) -ForegroundColor Red; return $false }

    Write-Host '   2/3 常驻 watchdog 进程与 18081 适配器' -ForegroundColor Cyan
    $wd = @(Get-RsWatchdogResidentPids)
    foreach ($p in $wd) { & cmd.exe /c "taskkill /PID $p /T /F >nul 2>&1" }
    Write-Host ("   watchdog：{0}" -f $(if ($wd) { '已结束 pid=' + ($wd -join ',') } else { '无' })) -ForegroundColor DarkGray
    $pids = @(Get-RsAdapterPids -Port $script:RS.TailnetPort)
    foreach ($p in $pids) { & cmd.exe /c "taskkill /PID $p /T /F >nul 2>&1" }
    Write-Host ("   适配器 {0}：{1}" -f $script:RS.TailnetPort, $(if ($pids) { '已结束 pid=' + ($pids -join ',') } else { '无' })) -ForegroundColor DarkGray

    Start-Sleep -Milliseconds 800
    Write-Host '   3/3 复核' -ForegroundColor Cyan
    $left = @()
    if (Test-RsListen -Port $script:RS.TailnetPort) { $left += '18081' }
    if ($left.Count -eq 0) {
        Write-Host '远程接入：已停止（DSH 3079、tailscaled 均未触碰）' -ForegroundColor Green
        Write-Host '注意：tailscale serve 的 :8443 → 18081 映射保留（配置态，无进程）。' -ForegroundColor DarkGray
        return $true
    }
    Write-Host ("远程接入：仍有残留 → {0}" -f ($left -join ', ')) -ForegroundColor Red
    return $false
}

function Invoke-RemoteDoctor {
    Write-Host '== 远程接入：自检（muse 内网车道）==' -ForegroundColor Cyan
    $fails = @()

    # 1) DSH 与 relay
    if (Test-RsListen -Port 3079) { Write-Host '   [ok] DSH 3079 监听' -ForegroundColor Green }
    else { Write-Host '   [!!] DSH 3079 未监听' -ForegroundColor Red; $fails += 'dsh-3079' }

    $relay = Get-RsRelayState
    if ($relay.Descriptor -and $relay.Token) { Write-Host ("   [ok] relay descriptor：{0}" -f $relay.McpUrl) -ForegroundColor Green }
    else { Write-Host '   [!!] relay descriptor 或 token 缺失（3079 刚启动？）' -ForegroundColor Red; $fails += 'relay-descriptor' }

    # 2) 18081 本地健康 + 未授权探针
    $port = $script:RS.TailnetPort
    if (Test-RsHealth -Port $port) { Write-Host ("   [ok] muse 内网 127.0.0.1:{0}/health" -f $port) -ForegroundColor Green }
    else { Write-Host ("   [!!] muse 内网 127.0.0.1:{0}/health 不可达" -f $port) -ForegroundColor Red; $fails += "health-$port" }
    # 鉴权探针用 tools/list：initialize 按 MCP 规范是公开的（2026-10-22 实测 200），
    # 真正需要 token 的是 tools/list 与 tools/call（实测 401 + WWW-Authenticate）。
    $probe = '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{}}'
    $code = & curl.exe --noproxy 127.0.0.1,localhost -sS -o NUL -w '%{http_code}' --max-time 6 -X POST -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d $probe ("http://127.0.0.1:{0}/mcp" -f $port) 2>$null
    if ($code -eq '401') { Write-Host '   [ok] tools/list 未授权 → 401（OAuth 生效）' -ForegroundColor Green }
    elseif ($code -eq '200') { Write-Host '   [!!] tools/list 未带 token 竟然 200 —— 鉴权失效，需立即排查' -ForegroundColor Red; $fails += "oauth-$port" }
    else { Write-Host ("   [!!] tools/list 期望 401，实际 {0}" -f $code) -ForegroundColor Yellow; $fails += "oauth-$port" }

    # 3) tailscale serve
    $serve = Get-RsServeTailnet
    if ($serve -eq $true) { Write-Host '   [ok] tailscale serve :8443 → 127.0.0.1:18081' -ForegroundColor Green }
    elseif ($serve -eq $false) { Write-Host '   [!!] tailscale serve 缺少 :8443 映射（内网车道不可达）' -ForegroundColor Red; $fails += 'serve-8443' }
    else { Write-Host '   [??] tailscale serve status 读取失败' -ForegroundColor Yellow; $fails += 'serve-unknown' }

    # 4) 守护任务
    $st = Get-RsTaskState -Name $script:RS.TailnetTask
    if ($st.State -in @('Ready', 'Running')) {
        Write-Host ("   [ok] 守护任务 {0} = {1}（上次结果 {2}）" -f $script:RS.TailnetTask, $st.State, $st.LastResult) -ForegroundColor Green
    } else {
        Write-Host ("   [!!] 守护任务 {0} = {1}" -f $script:RS.TailnetTask, $st.State) -ForegroundColor Red; $fails += "task-$($script:RS.TailnetTask)"
    }

    # 5) 隧道侧入口（只报状态，不参与判定：本机经 tailnet 回环访问，偶发 DNS 抖动不算车道故障）
    $muse = & curl.exe --noproxy '' -sS -o NUL -w '%{http_code}' --max-time 10 $script:RS.TailnetUrl 2>$null
    if ($muse -in @('401', '405', '406')) { Write-Host ("   [ok] tailnet 入口 {0} → {1}（入口可达；OAuth 以上述 tools/list 探针为准）" -f $script:RS.TailnetUrl, $muse) -ForegroundColor Green }
    else { Write-Host ("   [--] tailnet 入口 {0} 返回 {1}（不影响本地判定，先看 serve 与适配器）" -f $script:RS.TailnetUrl, $muse) -ForegroundColor Yellow }

    Write-Host ''
    if ($fails.Count -eq 0) { Write-Host '自检通过：服务、适配器、门禁与 serve 映射正常（未执行真实任务派发）。' -ForegroundColor Green; return $true }
    Write-Host ("自检发现问题：{0}" -f ($fails -join ', ')) -ForegroundColor Red
    return $false
}

function Get-RsLaneSpec {
    param([string]$Lane)
    switch ($Lane.ToLowerInvariant()) {
        'tailnet' { return [pscustomobject]@{ Name = 'tailnet'; Port = $script:RS.TailnetPort; Task = $script:RS.TailnetTask; Label = 'muse 内网' } }
        default   { throw ("未知车道：{0}（现在只剩 tailnet / muse 内网）" -f $Lane) }
    }
}

function Get-RsLaneUp {
    param([string]$Lane)
    $spec = Get-RsLaneSpec -Lane $Lane
    $health = Test-RsHealth -Port $spec.Port
    $pids = @(Get-RsAdapterPids -Port $spec.Port)
    return ($health -and $pids.Count -ge 1)
}

function Stop-RsLane {
    param([string]$Lane)
    $spec = Get-RsLaneSpec -Lane $Lane
    Write-Host ("== 停止车道：{0} ==" -f $spec.Label) -ForegroundColor Cyan
    try {
        Stop-ScheduledTask -TaskName $spec.Task -ErrorAction SilentlyContinue
        Disable-ScheduledTask -TaskName $spec.Task -ErrorAction Stop | Out-Null
        Write-Host ("   已停用守护任务：{0}" -f $spec.Task) -ForegroundColor Green
    } catch { Write-Host ("   ✗ {0}: {1}" -f $spec.Task, $_.Exception.Message) -ForegroundColor Red; return $false }
    $wd = @(Get-RsWatchdogResidentPids)
    foreach ($p in $wd) { & cmd.exe /c "taskkill /PID $p /T /F >nul 2>&1" }
    Write-Host ("   常驻 watchdog：{0}" -f $(if ($wd) { '已结束 pid=' + ($wd -join ',') } else { '无' })) -ForegroundColor DarkGray
    $pids = @(Get-RsAdapterPids -Port $spec.Port)
    foreach ($p in $pids) { & cmd.exe /c "taskkill /PID $p /T /F >nul 2>&1" }
    Write-Host ("   适配器 {0}：{1}" -f $spec.Port, $(if ($pids) { '已结束 pid=' + ($pids -join ',') } else { '无' })) -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 700
    if (-not (Test-RsListen -Port $spec.Port)) { Write-Host ("车道 {0}：已停止" -f $spec.Label) -ForegroundColor Green; return $true }
    Write-Host ("车道 {0}：残留 → 适配器 {1}" -f $spec.Label, $spec.Port) -ForegroundColor Red
    return $false
}

function Start-RsLane {
    param([string]$Lane)
    $spec = Get-RsLaneSpec -Lane $Lane
    Write-Host ("== 启动车道：{0} ==" -f $spec.Label) -ForegroundColor Cyan
    if (-not (Test-RsListen -Port 3079)) {
        Write-Host '   DSH 3079 未运行 —— relay 是车道的上游，请先按 [1] 启动 DSH。' -ForegroundColor Red
        return $false
    }
    try {
        $t = Get-ScheduledTask -TaskName $spec.Task -ErrorAction Stop
        if ("$($t.State)" -eq 'Disabled') { Enable-ScheduledTask -TaskName $spec.Task | Out-Null; Write-Host ("   已启用守护任务：{0}" -f $spec.Task) -ForegroundColor Green }
        Start-ScheduledTask -TaskName $spec.Task
        Write-Host ("   已触发一次：{0}" -f $spec.Task) -ForegroundColor DarkGray
    } catch { Write-Host ("   ✗ {0}: {1}" -f $spec.Task, $_.Exception.Message) -ForegroundColor Red; return $false }
    $ok = Wait-RsLane -Port $spec.Port
    if ($ok) { Write-Host ("车道 {0}：已就绪" -f $spec.Label) -ForegroundColor Green }
    else { Write-Host ("车道 {0}：未就绪，查看 logs\watchdog-tailnet.log" -f $spec.Label) -ForegroundColor Yellow }
    return $ok
}

function Invoke-RsLaneAction {
    param([string]$Lane, [string]$Verb = 'toggle')
    switch ($Verb.ToLowerInvariant()) {
        'start'  { return (Start-RsLane -Lane $Lane) }
        'stop'   { return (Stop-RsLane -Lane $Lane) }
        'status' { return (Get-RsLaneUp -Lane $Lane) }
        'toggle' {
            if (Get-RsLaneUp -Lane $Lane) { return (Stop-RsLane -Lane $Lane) }
            return (Start-RsLane -Lane $Lane)
        }
        default { throw ("未知动作：{0}（可用 start / stop / status / toggle）" -f $Verb) }
    }
}
