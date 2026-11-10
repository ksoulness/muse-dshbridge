$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_launcher-common.ps1')
$env:DSH_HOME = $script:DshHome
$env:DSH_RELAY_TITLE_PREFIX = ''
$script:workspace = $PSScriptRoot
$script:port = $script:DshPort
$script:url = "http://127.0.0.1:$($script:port)/"
$script:dataRoot = $script:DshHome
$script:logPath = Join-Path $PSScriptRoot 'dsh-web.log'
$script:autoRefreshSecs = 30
$script:lastResult = ''
$script:Action = if ($args.Count -gt 0) { ([string]$args[0]).ToLowerInvariant() } else { 'menu' }
$script:ActionArg = if ($args.Count -gt 1) { ([string]$args[1]).ToLowerInvariant() } else { '' }
$commands = @('menu','status','start','stop','restart','url','url-remote','mcp-status','mcp-start','mcp-stop','mcp-restart','lane-tailnet','doctor')
if ($script:Action -notin $commands -or $args.Count -gt 2 -or
    ($args.Count -gt 1 -and $script:Action -notin @('lane-tailnet')) -or
    ($script:ActionArg -and $script:ActionArg -notin @('start','stop','status','toggle'))) {
    Write-Host ('未知命令或参数。可用：' + ($commands -join ' ')) -ForegroundColor Red
    exit 2
}
if (-not $script:ActionArg) { $script:ActionArg = 'toggle' }

# Wait only for the elevated launcher, not its long-lived DSH descendants.
if (-not (Test-DshAdministrator)) {
    try {
        $childArgs = @('-NoProfile','-File',$PSCommandPath,$script:Action)
        if ($script:Action -in @('lane-tailnet')) { $childArgs += $script:ActionArg }
        $child = Start-Process -FilePath $script:DshPowerShell -ArgumentList (Join-DshArguments $childArgs) -WorkingDirectory $PSScriptRoot -Verb RunAs -PassThru
        $child.WaitForExit()
        exit $child.ExitCode
    } catch {
        Write-Host '无法取得管理员权限或已取消 UAC；命令未执行。' -ForegroundColor Red
        exit 1
    }
}
# Progress rendering only helps an interactive console; scheduled-task and piped runs stay clean.
$script:interactiveOutput = -not [Console]::IsOutputRedirected
$script:progressText = ''

function Clear-DshPendingKeys {
    # Keys pressed while a blocking action runs stay queued in the console input buffer and would
    # replay the same action on the next menu read (this is how one [3] became several restarts).
    try {
        if ([Console]::IsInputRedirected) { return }
        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    } catch { }
}

function Test-DshInteractiveConsole {
    if ($null -ne $script:interactiveOutput) { return [bool]$script:interactiveOutput }
    return (-not [Console]::IsOutputRedirected)
}

function Write-DshProgress {
    param([string]$Text)
    if (-not (Test-DshInteractiveConsole)) { return }
    try { $width = [Math]::Max(24, [Console]::WindowWidth - 1) } catch { $width = 79 }
    if ($Text.Length -gt $width) { $Text = $Text.Substring(0, $width) }
    Write-Host ("`r" + $Text.PadRight($width)) -NoNewline
    $script:progressText = $Text
}

function Clear-DshProgress {
    if (-not $script:progressText) { return }
    Write-Host ("`r" + (' ' * $script:progressText.Length) + "`r") -NoNewline
    $script:progressText = ''
}

function Write-DshStreamedLines {
    # Streams only the child output that appeared since the previous poll, so the operator sees
    # "停止 DSH PID …" / "DSH 已就绪 …" while the action is still running instead of after 2 minutes.
    param([string]$Path, [int]$Seen)
    if (-not (Test-Path -LiteralPath $Path)) { return $Seen }
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $Path -Encoding utf8 -ErrorAction SilentlyContinue) } catch { return $Seen }
    if ($lines.Count -le $Seen) { return $Seen }
    Clear-DshProgress
    for ($i = $Seen; $i -lt $lines.Count; $i++) {
        $text = [regex]::Replace([string]$lines[$i], 'token=[^&\s\)]+', 'token=<redacted>')
        if (-not $text.Trim()) { continue }
        Write-Host ('   ' + $text.TrimEnd())
    }
    return $lines.Count
}

function Get-DshActionLabel {
    param([string]$Action, [string]$Verb = 'toggle')
    switch ($Action) {
        'start'          { '正在启动 DSH 3079' }
        'stop'           { '正在关闭 DSH 3079' }
        'restart'        { '正在重启 DSH 3079' }
        'mcp-start'      { '正在启动 / 修复远程接入' }
        'mcp-stop'       { '正在停止远程接入' }
        'mcp-restart'    { '正在重启远程接入' }
        'doctor'         { '正在自检远程接入' }
        'lane-tailnet'   { if ($Verb -eq 'status') { '正在读取内网车道状态' } else { '正在切换内网车道（muse）' } }
        default          { '正在执行' }
    }
}

function Remove-DshMarkOfTheWeb {
    # A Zone.Identifier stream makes Windows show "无法验证发布者" for the .bat before this script
    # can run. Clearing it once here means the prompt can never come back on a later launch.
    foreach ($pattern in @('*.bat','*.cmd','*.ps1','*.psm1')) {
        foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter $pattern -File -ErrorAction SilentlyContinue)) {
            try {
                if (Get-Item -LiteralPath $file.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
                    Unblock-File -LiteralPath $file.FullName -ErrorAction Stop
                    Write-Host ("已解除下载标记（Zone.Identifier）：{0}" -f $file.Name) -ForegroundColor DarkGray
                }
            } catch { }
        }
    }
}

Remove-DshMarkOfTheWeb
. (Join-Path $PSScriptRoot '_remote-stack.ps1')

function Get-DshLoginUrl {
    # 2026-10-30：原来只读 "$logPath.raw" 一处，且宿主被非启动器路径重启时该文件不会刷新
    # （token 已轮换）→ 菜单里"网址"直接抛"HTTP 401"。现在按多来源取候选、逐个探活：
    #   ① dsh-web.url.txt（restart-dsh.ps1 / restart-web-logged.ps1 启动成功后写入）
    #   ② launcher 的 dsh-web.log.raw  ③ vbs 路径的 web-current.log / web-previous.log
    # 全部失效且是本地请求时，退回 windsh 网关（127.0.0.1:3088，免 token 入口）。
    param([switch]$Remote)
    $stage = '读取启动日志'
    $loginStatus = 0
    $urlFile = Join-Path $PSScriptRoot 'dsh-web.url.txt'
    $sources = @(
        @{ Path = $urlFile; Bare = $true },
        @{ Path = "$($script:logPath).raw"; Bare = $false },
        @{ Path = 'D:\Program Files\DSH\logs\web-current.log'; Bare = $false },
        @{ Path = 'D:\Program Files\DSH\logs\web-previous.log'; Bare = $false }
    )
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    do {
        $candidates = New-Object System.Collections.ArrayList
        foreach ($src in $sources) {
            if (-not (Test-Path -LiteralPath $src.Path)) { continue }
            try {
                $raw = Get-Content -LiteralPath $src.Path -Raw -Encoding utf8 -ErrorAction Stop
            } catch { continue }
            if (-not $raw) { continue }
            if ($src.Bare) {
                $bare = ([string]$raw).Trim()
                if ($bare -match '^http://127\.0\.0\.1:3079/\?token=[A-Za-z0-9_-]+$') { [void]$candidates.Add($bare) }
            } else {
                $logins = [regex]::Matches([string]$raw, 'dsh web: (http://127\.0\.0\.1:3079/\?token=[A-Za-z0-9_-]+)')
                if ($logins.Count -gt 0) { [void]$candidates.Add($logins[$logins.Count - 1].Groups[1].Value) }
            }
        }
        foreach ($candidate in $candidates) {
            $stage = '验证登录地址'
            try {
                $response = Invoke-WebRequest -Uri $candidate -NoProxy -SkipHttpErrorCheck -TimeoutSec 2 -ErrorAction Stop
                $loginStatus = [int]$response.StatusCode
            } catch { $loginStatus = 0 }
            if ($loginStatus -ne 200) { continue }
            # 探活通过：顺手把它写成稳定文件，下次即使日志被清也有来源。
            try { [IO.File]::WriteAllText($urlFile, $candidate + "`r`n") } catch { }
            if ($Remote) { return $candidate.Replace($script:url, 'https://win.tailbc7c29.ts.net/') }
            return $candidate
        }
        if (-not $Remote) {
            $stage = '尝试网关免 token 入口'
            $gwPort = if ($env:WINDSH_GATEWAY_PORT) { $env:WINDSH_GATEWAY_PORT } else { '3088' }
            try {
                $gw = Invoke-WebRequest -Uri "http://127.0.0.1:$gwPort/" -NoProxy -SkipHttpErrorCheck -TimeoutSec 2 -ErrorAction Stop
                if ([int]$gw.StatusCode -eq 200) { return "http://127.0.0.1:$gwPort/" }
            } catch { }
        }
        Start-Sleep -Milliseconds 200
    } while ([datetime]::UtcNow -lt $deadline)
    throw "当前登录网址不可用（$stage，HTTP $loginStatus）：本机能找到的 token 全部失效（多半是宿主被非启动器方式重启）。请用启动器重启一次后重试。"
}

function Copy-DshLoginUrl {
    param([switch]$Remote)
    $loginUrl = Get-DshLoginUrl -Remote:$Remote
    try { Set-Clipboard -Value $loginUrl -ErrorAction Stop }
    catch { throw '无法写入剪贴板，请在本机交互式终端重试。' }
    Write-Host '当前登录网址已复制。' -ForegroundColor Green
}

function Invoke-DshLifecycle {
    # 2026-10-25: 原 120s 短于内层 restart-dsh.ps1 的 150s 等待，会先转圈超时再看到内层结果。
    # 外层统一留 20s 余量，保证"外层转圈"始终包住"内层判定"。
    param([string]$Mode, [string]$Label, [double]$TimeoutSeconds = 170)
    # A native pipeline can remain open through the long-lived Node descendants.
    # Capture to files and wait for the immediate lifecycle process only.
    if (-not $Label) { $Label = Get-DshActionLabel -Action $Mode.ToLowerInvariant() }
    $outputPath = Join-Path $PSScriptRoot "_launcher-command-$PID.log"
    $errorPath = Join-Path $PSScriptRoot "_launcher-command-$PID.error.log"
    foreach ($path in @($outputPath, $errorPath)) {
        try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
    }
    $arguments = @('-NoProfile','-File',(Join-Path $PSScriptRoot 'restart-dsh.ps1'),'-Mode',$Mode)
    $timeoutSeconds = $TimeoutSeconds
    $process = Start-Process -FilePath $script:DshPowerShell -ArgumentList (Join-DshArguments $arguments) -WindowStyle Hidden -PassThru -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
    if (-not $process) {
        Write-Host ("{0}：无法启动启停脚本（{1}）。" -f $Label, $script:DshPowerShell) -ForegroundColor Red
        return $false
    }
    # Poll instead of one 120-second WaitForExit so the operator sees stages and elapsed time.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $outSeen = 0
    $errSeen = 0
    $spin = '|/-\'
    $tick = 0
    $exited = $false
    while (-not $exited) {
        $exited = [bool]$process.WaitForExit(250)
        $outSeen = Write-DshStreamedLines -Path $outputPath -Seen $outSeen
        $errSeen = Write-DshStreamedLines -Path $errorPath -Seen $errSeen
        if ($exited) { break }
        if ($clock.Elapsed.TotalSeconds -ge $timeoutSeconds) { break }
        $tick++
        Write-DshProgress -Text ("{0}… {1} 已用 {2}s（最长 {3}s，请勿重复按键）" -f $Label, $spin[$tick % 4], [int]$clock.Elapsed.TotalSeconds, $timeoutSeconds)
    }
    # The redirect files can lag the process exit by a moment; give them one short drain.
    Start-Sleep -Milliseconds 150
    $outSeen = Write-DshStreamedLines -Path $outputPath -Seen $outSeen
    $errSeen = Write-DshStreamedLines -Path $errorPath -Seen $errSeen
    Clear-DshProgress
    Clear-DshPendingKeys
    if (-not $exited) {
        Write-Host ("{0}：超过 {1} 秒未返回；未重复启动，请勿重复按键，先检查当前服务状态。" -f $Label, $timeoutSeconds) -ForegroundColor Red
        return $false
    }
    $code = $process.ExitCode
    if ($code -eq 0) {
        Write-Host ("{0}：完成（用时 {1:N1} 秒）。" -f $Label, $clock.Elapsed.TotalSeconds) -ForegroundColor Green
    } else {
        Write-Host ("{0}：失败（退出码 {1}，用时 {2:N1} 秒）。" -f $Label, $code, $clock.Elapsed.TotalSeconds) -ForegroundColor Red
    }
    return ($code -eq 0)
}

function Write-DshStatus {
    param([switch]$SkipRemote)
    $listeners = @(Get-DshListeners)
    if ($listeners.Count -eq 0) {
        Write-Host "服务状态：未运行（端口 $($script:port) 未监听）" -ForegroundColor Yellow
    } else {
        foreach ($listener in $listeners) {
            $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)" -ErrorAction Stop
            if (Test-DshServiceProcess $owner) {
                Write-Host "服务状态：运行中（端口 $($script:port)，进程 PID：$($owner.ProcessId)）" -ForegroundColor Green
            } else {
                Write-Host "端口 $($script:port) 占用者身份不符或不可读（PID $($listener.OwningProcess)）；不会停止该进程。" -ForegroundColor Red
            }
        }
    }
    Write-Host "访问地址：$($script:url)"
    Write-Host "数据根（DSH_HOME）：$($script:dataRoot)"
    Write-Host "启动日志：$($script:logPath)"
    if ($SkipRemote) { return }
    Write-Host ''
    [void](Write-RemoteStatus)
}

function Invoke-LauncherCommand {
    param([string]$Action, [string]$Verb = 'toggle')
    $remoteLock = $null
    $locked = $false
    Clear-DshPendingKeys
    $label = Get-DshActionLabel -Action $Action -Verb $Verb
    Write-Host ''
    Write-Host ("== {0} ==" -f $label) -ForegroundColor Cyan
    try {
        if ($Action -in @('mcp-start','mcp-stop','mcp-restart') -or
            ($Action -eq 'lane-tailnet' -and $Verb -ne 'status')) {
            $remoteLock = [Threading.Mutex]::new($false, 'Local\DSH-Remote-Lifecycle-3079')
            try { $locked = $remoteLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
            if (-not $locked) { throw '远程链路操作正在进行，请等待完成后再试。' }
        }
        $ok = $true
        switch ($Action) {
            'status' { Write-DshStatus }
            'start' { $ok = Invoke-DshLifecycle -Mode Start -Label $label }
            'stop' { $ok = Invoke-DshLifecycle -Mode Stop -Label $label }
            'restart' { $ok = Invoke-DshLifecycle -Mode Restart -Label $label }
            'url' { Write-Host (Get-DshLoginUrl) }
            'url-remote' { Write-Host (Get-DshLoginUrl -Remote) }
            'mcp-status' { $ok = Write-RemoteStatus }
            'mcp-start' { $ok = Invoke-RemoteStart }
            'mcp-stop' { $ok = Invoke-RemoteStop }
            'mcp-restart' { $ok = Invoke-RemoteStop; if ($ok) { $ok = Invoke-RemoteStart } }
            'lane-tailnet' { $ok = Invoke-RsLaneAction -Lane tailnet -Verb $Verb }
            'doctor' { $ok = Invoke-RemoteDoctor }
            default { return 2 }
        }
        $script:lastResult = ('{0} {1}：{2}' -f (Get-Date -Format 'HH:mm:ss'), $label, $(if ($ok) { '成功' } else { '未通过，见上方输出' }))
        if ($ok) { return 0 }
        return 1
    } catch {
        $script:lastResult = ('{0} {1}：失败' -f (Get-Date -Format 'HH:mm:ss'), $label)
        Write-Host ('执行失败：' + $_.Exception.Message) -ForegroundColor Red
        return 1
    } finally {
        Clear-DshPendingKeys
        if ($locked) { $remoteLock.ReleaseMutex() }
        if ($remoteLock) { $remoteLock.Dispose() }
    }
}

function Show-MainMenu {
    # A host without a real console (scheduled run, captured output) cannot clear the screen;
    # that must never stop the status block from rendering.
    try { Clear-Host } catch { }
    Write-Host 'DeepSeek Harness 启动器（3079）' -ForegroundColor Cyan
    Write-Host "工作目录：$script:workspace"
    if ($script:lastResult) { Write-Host "上次操作：$script:lastResult" -ForegroundColor DarkGray }
    Write-Host ''
    Write-DshStatus -SkipRemote
    Write-Host ''
    Write-Host '[0] 刷新状态'
    Write-Host '[1] 启动'
    Write-Host '[2] 关闭 DSH（远程车道由 [7] 单独停止）'
    Write-Host '[3] 重启 DSH'
    Write-Host '[4] 复制本机登录网址'
    Write-Host '[5] 复制远程登录网址'
    Write-Host '[6] 启动 / 修复远程接入'
    Write-Host '[7] 停止远程接入（保留 DSH 与 tailscale）'
    Write-Host '[8] 远程接入自检'
    Write-Host "（每 $script:autoRefreshSecs 秒刷新；启停操作会先提示状态并显示实时进度）"
    Write-Host '[Q] 退出'
    Write-Host ''
    # The remote-lane probe is the slowest part of the page; rendering it last keeps the menu
    # usable within about a second of the window opening. A probe failure must never block the menu.
    try { [void](Write-RemoteStatus) } catch { Write-Host ('远程链路状态读取失败：' + $_.Exception.Message) -ForegroundColor DarkYellow }
}

function Read-ChoiceWithTimeout {
    param([int]$TimeoutSecs)
    if ([Console]::IsInputRedirected) { throw '菜单需要交互式终端；自动化请使用子命令。' }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSecs)
    while ([datetime]::UtcNow -lt $deadline) {
        if ([Console]::KeyAvailable) { return ([string][Console]::ReadKey($true).KeyChar).ToUpperInvariant() }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

if ($script:Action -ne 'menu') { exit (Invoke-LauncherCommand -Action $script:Action -Verb $script:ActionArg) }
$menuActions = @{'0'='status';'1'='start';'2'='stop';'3'='restart';'6'='mcp-start';'7'='mcp-stop';'8'='doctor'}
while ($true) {
    try {
        Show-MainMenu
        $choice = Read-ChoiceWithTimeout -TimeoutSecs $script:autoRefreshSecs
        if ($null -eq $choice -or $choice -eq '' -or $choice -eq '0' -or $choice -in @("`r","`n")) { continue }
        if ($choice -eq 'Q') { exit 0 }
        $rc = 0
        if ($choice -in @('4','5')) {
            Clear-DshPendingKeys
            Copy-DshLoginUrl -Remote:($choice -eq '5')
            $script:lastResult = ('{0} 复制{1}登录网址：成功' -f (Get-Date -Format 'HH:mm:ss'), $(if ($choice -eq '5') { '远程' } else { '本机' }))
        }
        elseif ($menuActions.ContainsKey($choice)) { $rc = Invoke-LauncherCommand -Action $menuActions[$choice] }
        else { Write-Host '无效选择，请重试。' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700; continue }
        if ($rc -ne 0) {
            Write-DshFailureLog -Launcher $PSScriptRoot
            $null = Read-Host '操作失败，已保留现场。按回车返回菜单'
        } else { Write-Host '操作完成。' -ForegroundColor Green; Start-Sleep -Seconds 2 }
        # Long operations can leave keys queued in the console buffer; drop them so one press never
        # replays the same action several times.
        Clear-DshPendingKeys
    } catch {
        Write-Host ('执行失败：' + $_.Exception.Message) -ForegroundColor Red
        if ([Console]::IsInputRedirected) { exit 1 }
        $null = Read-Host '按回车返回菜单'
    }
}
