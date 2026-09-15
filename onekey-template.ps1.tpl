# ============================================================
# campus-auth one-click installer (for campus-mates)
# - asks for username & password right in the terminal
# - resolves latest release dynamically (fallback: pinned URL)
# - downloads (gh-proxy fallback), extracts, writes full config
# - starts the tray app; the web console is never needed
# ============================================================
# options via env vars (silent/test runs): CA_INSTALLDIR / CA_USERNAME /
# CA_PASSWORD / CA_ASSUMEYES / CA_NOLAUNCH / CA_LOG_DIR（日志目录，默认 %TEMP%）
$DefaultDir = if (Test-Path 'D:\') { 'D:\campus-auth' } else { "$env:LOCALAPPDATA\campus-auth" }
$InstallDir = if ($env:CA_INSTALLDIR) { $env:CA_INSTALLDIR } else { $DefaultDir }
$Username   = $env:CA_USERNAME
$Password   = $env:CA_PASSWORD
$AssumeYes  = [bool]$env:CA_ASSUMEYES
$NoLaunch   = [bool]$env:CA_NOLAUNCH

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------- school-specific settings (edit if needed) ----------------
$AUTH_URL   = 'http://211.69.15.10:6060/portalReceiveAction.do'
$ISP        = '本地账号'
$API_URL    = 'https://api.github.com/repos/Misyra/Campus-Auth-rs/releases/latest'
$FALLBACK   = 'https://github.com/Misyra/Campus-Auth-rs/releases/latest/download/campus-auth-v5.0.0-alpha.10-x86_64-pc-windows-msvc.zip'
$CHANNELS   = @('', 'https://gh-proxy.com/')   # direct first, then gh-proxy

# ---- 是否已在管理员上下文（提权动作放到下面日志就绪之后，确保任何提前退出都留证据）----
$IsAdmin = $false
try {
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $IsAdmin = $false }

# ---------------- 诊断日志：窗口一闪而过 / 报错时，把下面这个文件发回来即可定位 ----------------
# 必须在任何 exit 之前初始化：早前版本把日志建在提权块之后，导致提权交接一出问题就零证据。
# 只写系统缓存目录（%TEMP%），**不在安装器同目录留任何文件**（同目录通常就是桌面，不该被污染）。
# 提权后若换了账户（标准用户 + 输入另一个管理员密码），子进程自己的 %TEMP% 会变；
# 由提权引导码把父进程的 CA_LOG_DIR 传下去，保证父/子进程始终写同一个日志文件。
$LogDir = $env:TEMP
if ($env:CA_LOG_DIR) { try { if (Test-Path -LiteralPath $env:CA_LOG_DIR) { $LogDir = $env:CA_LOG_DIR } } catch {} }
if (-not $LogDir) { $LogDir = $env:TEMP }
$LogFile        = Join-Path $LogDir 'campus-auth-install.log'
$TranscriptFile = Join-Path $LogDir 'campus-auth-install-transcript.log'
# .bat 头自带 pause，无需再等一次；但提权窗口是 powershell 直启（没有 .bat 的 pause），必须自己留住窗口
$UnderBat = [bool]($env:CA_SELF -and ($env:CA_SELF -match '(?i)\.bat$') -and (-not $env:CA_ELEV_CHILD))
function Write-Log([string]$msg) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}
function Wait-ExitKey([string]$tip) {
    if ($AssumeYes -or $UnderBat) { return }
    try { Write-Host ""; Read-Host ("按回车键关闭窗口（" + $tip + "）") | Out-Null } catch {}
}
function Die([string]$msg) {
    Write-Host ""
    Write-Host $msg
    Write-Log ("安装中止: " + $msg)
    Write-Host ("诊断日志: " + $LogFile)
    Wait-ExitKey '安装未完成'
    exit 1
}
Write-Log "================ 安装器启动 ================"
Write-Log ("时间=" + (Get-Date).ToString('s') + "  PS=" + $PSVersionTable.PSVersion.ToString() + "  语言模式=" + $ExecutionContext.SessionState.LanguageMode)
Write-Log ("系统=" + [Environment]::OSVersion.VersionString + "  64位进程=" + [Environment]::Is64BitProcess)
Write-Log ("用户=" + $env:USERDOMAIN + "\" + $env:USERNAME + "  管理员=" + $IsAdmin + "  已尝试提权=" + [bool]$env:CA_ELEV_TRIED)
Write-Log ("自身=" + $env:CA_SELF + "  脚本=" + $MyInvocation.MyCommand.Path + "  TEMP=" + $env:TEMP)
Write-Log ("日志=" + $LogFile + "  CA_LOG_DIR=" + $env:CA_LOG_DIR)
# 权限环境快照：判断"提权到底有没有可能成功"（不是管理员账户 / UAC 被关 / 被策略禁止提权）
try {
    $inAdminGrp = $false
    try {
        $inAdminGrp = [bool]([Security.Principal.WindowsIdentity]::GetCurrent().Groups | Where-Object { $_.Value -eq 'S-1-5-32-544' })
    } catch {}
    $uacInfo = 'uac=读取失败'
    try {
        $pk = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
        $uacInfo = 'EnableLUA=' + $pk.EnableLUA + ' ConsentPromptBehaviorAdmin=' + $pk.ConsentPromptBehaviorAdmin + ' PromptOnSecureDesktop=' + $pk.PromptOnSecureDesktop
    } catch {}
    Write-Log ('权限环境: 属管理员组(SID544)=' + $inAdminGrp + '  ' + $uacInfo + '  ComSpec=' + $env:ComSpec + '  提权子进程=' + [bool]$env:CA_ELEV_CHILD)
} catch {}
try { Start-Transcript -Path $TranscriptFile -Append -ErrorAction Stop | Out-Null; Write-Log 'transcript=on' } catch { Write-Log ('transcript=off: ' + $_.Exception.Message) }
Write-Host ("诊断日志: " + $LogFile)

# ---- 管理员权限：注册「登录 + 唤醒」自启任务需要管理员 ----
# 直接双击（非提权）时自动请求 UAC 提权重跑；用户取消/失败则按普通权限继续（仅登录自启）。
# 静默模式(CA_ASSUMEYES)不弹 UAC，避免打断自动化。
# 提权只试一次（CA_ELEV_TRIED），避免提权后仍非管理员时无限弹窗。
if ((-not $IsAdmin) -and (-not $AssumeYes) -and (-not $env:CA_ELEV_TRIED)) {
    $SelfPath = $env:CA_SELF
    if (-not $SelfPath) { try { $SelfPath = $MyInvocation.MyCommand.Path } catch {} }
    Write-Log ("提权目标=" + $SelfPath)
    if ($SelfPath -and (Test-Path $SelfPath)) {
        Write-Host "本安装器需要管理员权限（用于注册开机/唤醒自启任务）。正在请求提权，请在弹窗中点「是」..."
        $env:CA_ELEV_TRIED = '1'
        $child = $null
        try {
            if ($SelfPath -match '\.ps1$') {
                $child = Start-Process powershell -Verb RunAs -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $SelfPath + '"'))
            } else {
                # 提权重跑：用 -EncodedCommand 传一段 Base64 引导码，命令行里只有纯 ASCII。
                # 早前用 cmd /c "路径" 的写法，在部分机器上管理员窗口会秒退（退出码 1）且原因被 cmd 吞掉：
                # 路径里的中文/括号要过 cmd 的代码页与语法解析，任一不匹配就失败。
                # 现在直接让提权后的 PowerShell 重新读本文件执行，绕开 cmd 与路径编码。
                $q  = [char]39   # 单引号
                $boot = '$env:CA_ELEV_CHILD=' + $q + '1' + $q + '; $env:CA_ELEV_TRIED=' + $q + '1' + $q +
                        '; $env:CA_LOG_DIR=' + $q + $LogDir + $q +
                        '; $env:CA_SELF=' + $q + $SelfPath + $q +
                        '; iex ([IO.File]::ReadAllText(' + $q + $SelfPath + $q + ',[Text.Encoding]::UTF8) -split (' + $q + '#' + $q + '+' + $q + 'CAMPUSAUTH_PS' + $q + '+' + $q + '#' + $q + '),2)[1]'
                $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($boot))
                $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                Write-Log ("提权引导码长度=" + $boot.Length)
                $child = Start-Process -FilePath $psExe -Verb RunAs -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$enc)
            }
        } catch {
            Write-Log ("提权失败: " + $_.Exception.Message)
            Write-Host ("未获得管理员权限（可能被取消）：" + $_.Exception.Message)
            Write-Host "将按普通权限继续安装 —— 仅启用登录自启（无唤醒自启）。如需唤醒自启，请右键安装器 -> 以管理员身份运行。"
        }
        if ($child) {
            # 等管理员窗口跑完再退出：否则本窗口一闪而过，用户会以为"闪退"且拿不到任何结果
            Write-Log ("已发起提权 PID=" + $child.Id + "，本进程等待管理员窗口结束")
            Write-Host ("已请求管理员权限（管理员窗口 PID " + $child.Id + "）。本窗口会等它跑完再关闭，请在管理员窗口里继续操作。")
            Start-Sleep -Milliseconds 2500
            $alive = $true
            try { $alive = -not $child.HasExited } catch {}
            if ($alive) {
                try { $child.WaitForExit() } catch { Write-Log ("等待子进程异常: " + $_.Exception.Message) }
                $rc = 'unknown'
                try { $rc = $child.ExitCode } catch {}
                Write-Log ("管理员窗口已结束 退出码=" + $rc)
                Write-Host ("管理员窗口已结束（退出码 " + $rc + "）。诊断日志: " + $LogFile)
                Wait-ExitKey '提权安装结束'
                exit 0
            }
            # 管理员窗口秒退 = 提权没接上（早期"窗口一闪而过"就是这么来的）。
            # 不让本窗口跟着闪退：改为当前窗口继续安装，降级为仅登录自启。
            $rc2 = 'unknown'
            try { $rc2 = $child.ExitCode } catch {}
            Write-Log ("管理员窗口启动后 2.5 秒内即退出（退出码 " + $rc2 + "），判定提权未生效，改为当前窗口继续安装")
            Write-Host ""
            Write-Host ("管理员窗口没能跑起来（退出码 " + $rc2 + "），改为在当前窗口继续安装。")
            Write-Host "两种常见原因："
            Write-Host "  1) UAC 弹窗上点了「否」或没点 —— 重新双击本安装器，弹窗出来时点「是」；"
            Write-Host "  2) 这个 Windows 账户不在管理员组，或 UAC 被策略关闭 —— 提权不可能成功，"
            Write-Host "     请换管理员账户登录后再运行（或右键本安装器 -> 以管理员身份运行）。"
            Write-Host "影响：仅少了「睡眠唤醒后自动重连」，登录自启照常可用。"
            Write-Host ("诊断日志: " + $LogFile)
        }
    } else {
        Write-Host "提示：当前非管理员，仅启用登录自启（无唤醒自启）。如需唤醒自启，请以管理员身份运行本安装器。"
        Write-Log "未取到自身路径，跳过提权，按普通权限继续"
    }
}

function Read-Choice([string]$msg) {
    if ($AssumeYes) { return $true }
    $a = Read-Host "$msg [Y/N]"
    return ($a -match '^[Yy]')
}

function Invoke-Download([string]$url, [string]$outFile, [long]$MinSize = 1MB, [switch]$Quiet) {
    foreach ($ch in $CHANNELS) {
        $u = $ch + $url
        try {
            if (-not $Quiet) { Write-Host ("  下载中: " + ($(if ($ch) { $ch + ' (加速)' } else { 'GitHub 直连' }))) }
            # 先 HEAD 查总大小（镜像不支持则只显示 MB 数）
            [long]$total = 0
            try {
                $hr = [Net.HttpWebRequest]::Create($u)
                $hr.Method = 'HEAD'; $hr.Timeout = 15000
                $resp = $hr.GetResponse(); $total = $resp.ContentLength; $resp.Close()
            } catch { $total = 0 }
            if (-not $Quiet -and $total -gt 0) { Write-Host ("    文件大小 {0:N1} MB" -f ($total/1MB)) }
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'campus-auth-installer/1.0')
            $task = $wc.DownloadFileTaskAsync($u, $outFile)
            while (-not $task.IsCompleted) {
                Start-Sleep -Milliseconds 400
                if (-not $Quiet) {
                    $cur = (Get-Item $outFile -ErrorAction SilentlyContinue).Length
                    if ($cur) {
                        if ($total -gt 0) {
                            $pct = [math]::Min(99, [int]($cur * 100 / $total))
                            Write-Host -NoNewline ("    已下载 {0:N1} / {1:N1} MB ({2}%)   `r" -f ($cur/1MB), ($total/1MB), $pct)
                        } else {
                            Write-Host -NoNewline ("    已下载 {0:N1} MB   `r" -f ($cur/1MB))
                        }
                    }
                }
            }
            if ($task.IsFaulted) { throw $task.Exception.InnerException }
            if (-not $Quiet) { Write-Host "" }
            if ((Get-Item $outFile).Length -ge $MinSize) { return $true }
            throw "文件过小"
        } catch {
            Write-Host ""
            Write-Host ("  该通道失败: " + $_.Exception.Message)
        }
    }
    return $false
}

function Save-UrlWithProgress([string]$url, [string]$outFile, [string]$label, [int]$StallSec = 60, [hashtable]$Headers) {
    # 单 URL 下载 + 实时进度条（MB / 百分比 / 速度 / 秒数）。
    # 目的：uv 等组件下载时长时间无输出会让人以为卡死；这里每秒跳动一次给人确定感。
    # 停滞 StallSec 秒仍无新字节 -> 判该源失败，交给上层换源。
    [long]$total = 0
    try {
        $hr = [Net.HttpWebRequest]::Create($url)
        $hr.Method = 'HEAD'; $hr.Timeout = 15000
        $hr.UserAgent = 'campus-auth-installer/1.0'
        # Accept 属受限标头，必须用属性赋值；其余走 Headers 集合
        if ($Headers) {
            foreach ($k in $Headers.Keys) {
                if ($k -ieq 'Accept') { $hr.Accept = [string]$Headers[$k] } else { $hr.Headers[$k] = [string]$Headers[$k] }
            }
        }
        $resp = $hr.GetResponse(); $total = $resp.ContentLength; $resp.Close()
    } catch { $total = 0 }
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'campus-auth-installer/1.0')
    if ($Headers) {
        foreach ($k in $Headers.Keys) {
            try { $wc.Headers.Add($k, [string]$Headers[$k]) } catch { $wc.Headers[$k] = [string]$Headers[$k] }
        }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $task = $wc.DownloadFileTaskAsync($url, $outFile)
    [long]$lastSize = 0; $lastGrow = 0.0
    while (-not $task.IsCompleted) {
        Start-Sleep -Milliseconds 400
        [long]$cur = 0
        try { $cur = (Get-Item $outFile -ErrorAction SilentlyContinue).Length } catch {}
        $sec = $sw.Elapsed.TotalSeconds
        if ($cur -gt $lastSize) { $lastSize = $cur; $lastGrow = $sec }
        $spd = 0.0
        if ($sec -gt 0.5) { $spd = $cur / 1MB / $sec }
        if ($total -gt 0) {
            $pct = [int]($cur * 100 / $total); if ($pct -gt 99) { $pct = 99 }
            Write-Host -NoNewline ("    {0}: {1:N1}/{2:N1} MB ({3}%)  {4:N1} MB/s  {5}s   `r" -f $label, ($cur/1MB), ($total/1MB), $pct, $spd, [int]$sec)
        } else {
            Write-Host -NoNewline ("    {0}: 已下载 {1:N1} MB  {2:N1} MB/s  已用 {3}s   `r" -f $label, ($cur/1MB), $spd, [int]$sec)
        }
        if ($StallSec -gt 0 -and ($sec - $lastGrow) -gt $StallSec) {
            try { $wc.CancelAsync() } catch {}
            Start-Sleep -Milliseconds 300
            try { $wc.Dispose() } catch {}
            Write-Host ""
            throw ("下载停滞超过 " + $StallSec + " 秒，判定该源不可用")
        }
    }
    if ($task.IsFaulted) {
        try { $wc.Dispose() } catch {}
        throw $task.Exception.InnerException
    }
    try { $wc.Dispose() } catch {}
    [long]$len = 0
    try { $len = (Get-Item $outFile).Length } catch {}
    Write-Host ("    {0}: 完成 {1:N1} MB，用时 {2} 秒" -f $label, ($len/1MB), [int]$sw.Elapsed.TotalSeconds)
    return $true
}

function Stop-RunningApp {
    # 关闭 exe 位于 $InstallDir 的运行中实例：更新模式下会锁定文件；
    # 残留进程还会占住单实例互斥体，让新启动的进程秒退
    $mine = Join-Path $InstallDir '*'
    $hit = @()
    foreach ($n in @('campus-auth', 'campus-auth-helper')) {
        foreach ($p in (Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            $pp = ''
            try { $pp = $p.Path } catch {}
            if ((-not $pp) -or ($pp -like $mine)) { $hit += $p }
        }
    }
    if ($hit.Count -eq 0) { return $false }
    Write-Host ("检测到程序正在运行(PID " + (($hit | ForEach-Object { $_.Id }) -join ', ') + ")，先关闭以免文件被锁...")
    $hit | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    return $true
}

function Register-Autostart {
    # 目标：让 campus-auth 在「登录」和「从睡眠/锁屏唤醒解锁」时都能自启。
    # 纯 Run 键(HKCU\...\Run)只在登录/重启触发，睡眠唤醒不补拉起——这是“自启动不太灵”的根因。
    # 计划任务同时挂 Logon + SessionUnlock 两个触发器，补齐唤醒缺口；多实例策略 IgnoreNew 防止与 Run 键重复拉起。
    # 注册计划任务需要管理员权限；若当前无管理员，则回退到仅 Run 键（登录自启，已是 app 自带机制），并提示唤醒自启需手动授权。
    # 全部按当前账户($env:USERDOMAIN\$env:USERNAME)与真实安装目录($InstallDir)动态生成 -> 随安装器分发、换机即用，不写死任何机器信息。
    $exePath = Join-Path $InstallDir 'campus-auth.exe'
    if (-not (Test-Path $exePath)) { return }
    $taskName = 'Campus-Auth Autostart'
    $user = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }

    # XML 文本转义（路径里若带 & < > 需转义，否则 schtasks 报“意外节点”）
    $esc = { param($s) $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' }
    $exeEsc = & $esc $exePath
    $dirEsc = & $esc $InstallDir

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$user</Author>
    <Description>Campus-Auth 开机/唤醒自启动（覆盖 Run 键不响应睡眠唤醒的缺口）</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger><UserId>$user</UserId><Delay>PT30S</Delay></LogonTrigger>
    <SessionStateChangeTrigger><UserId>$user</UserId><StateChange>SessionUnlock</StateChange><Delay>PT30S</Delay></SessionStateChangeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>$user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure>
  </Settings>
  <Actions Context="Author"><Exec><Command>$exeEsc</Command><WorkingDirectory>$dirEsc</WorkingDirectory></Exec></Actions>
</Task>
"@

    $isAdmin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = ($id.Groups | ForEach-Object { $_.Value }) -contains 'S-1-5-32-544'
    } catch { $isAdmin = $false }

    $taskOk = $false
    if ($isAdmin) {
        $xmlFile = Join-Path $env:TEMP ("campus-auth-task-" + [Guid]::NewGuid().ToString('N') + ".xml")
        try {
            $sw = New-Object System.IO.StreamWriter($xmlFile, $false, [Text.Encoding]::Unicode)  # UTF-16LE + BOM，schtasks 兼容
            $sw.Write($xml); $sw.Close()
            # 局部降级 ErrorActionPreference：native 命令写 stderr 时，全局 Stop 会将其当终止错误抛出，
            # 导致「其实注册成功却被误判失败」。改为 Continue + 显式读退出码。
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $schOut = schtasks /Create /TN "$taskName" /XML "$xmlFile" /F 2>&1
            $rc = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            if ($rc -eq 0) { $taskOk = $true; Write-Host ("  [OK] 已注册计划任务「" + $taskName + "」：登录 + 唤醒均自启") }
            else {
                Write-Host ("  [!] 计划任务注册失败(返回 " + $rc + ")，回退 Run 键")
                if ($schOut) { Write-Host ("      " + (($schOut | Out-String).Trim())) }
            }
        } catch {
            Write-Host ("  [!] 计划任务注册异常: " + $_.Exception.Message)
        } finally {
            Remove-Item $xmlFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "  [i] 当前非管理员，跳过计划任务（唤醒自启需授权）；改用 Run 键保证登录自启"
    }

    if (-not $taskOk) {
        # 回退：写 HKCU Run 键（无需管理员，已是 app 自带机制；这里显式兜底确保即便尚未启动过也能登录自启）
        try {
            $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            $cmd = '"{0}"' -f $exePath
            New-ItemProperty -Path $runKey -Name 'Campus-Auth' -Value $cmd -PropertyType String -Force | Out-Null
            Write-Host "  [OK] 已写入 Run 键（登录自启；唤醒自启请以管理员身份重跑本安装器）"
        } catch {
            Write-Host ("  [!] Run 键写入失败（不影响使用，可在程序设置里开启自启）: " + $_.Exception.Message)
        }
    }
}

function Get-ApiPort {
    # actual port is written by the app into config\.instance (line1=PID, line2=port);
    # only trust it while that PID is alive -> stale files from old runs are ignored
    $inst = Join-Path $InstallDir 'config\.instance'
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $inst) {
            try {
                $nums = (Get-Content $inst) | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
                if ($nums.Count -ge 2) {
                    $alive = $false
                    try { $alive = [bool](Get-Process -Id ([int]$nums[0]) -ErrorAction Stop) } catch {}
                    if ($alive) { return [string]$nums[1] }
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 600
    }
    return [string]((Get-Content (Join-Path $InstallDir 'config\settings.json') -Raw | ConvertFrom-Json).global.app.port)
}

function Wait-ApiReady([int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $port = Get-ApiPort
        try {
            $r = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $port + '/api/health') -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { $script:ApiBase = 'http://127.0.0.1:' + $port; return $true }
        } catch { Start-Sleep -Milliseconds 700 }
    }
    return $false
}

function Get-ApiJson([string]$url, $headers, [int]$timeoutSec = 4) {
    # PS5.1 对未标 charset 的 JSON 响应按 Latin-1 误解码 -> 中文变乱码；手动取原始字节按 UTF-8 解
    $r = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec $timeoutSec
    $txt = $null
    try {
        if ($r.RawContentStream -and $r.RawContentStream.Length -gt 0) { $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
    } catch {}
    if (-not $txt) {
        if ($r.Content -is [byte[]]) { $txt = [Text.Encoding]::UTF8.GetString($r.Content) }
        else { $txt = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes([string]$r.Content)) }
    }
    return ($txt | ConvertFrom-Json)
}

function Test-EnvReady([string]$apiBase) {
    # 真实状态端点是 GET /api/init-status：响应外包一层 data，环境状态在 .data.environment，
    # 就绪判定与网页一致用 capability_ready（旧版误读不存在的 /api/environment/status，永远检测不到成功）
    try {
        $token = [IO.File]::ReadAllText((Join-Path $InstallDir 'config\.auth_token')).Trim()
        $s = Get-ApiJson ($apiBase + '/api/init-status') @{ 'X-Auth-Token' = $token } 4
        $root = if ($s.data) { $s.data } else { $s }
        $e = $root.environment
        if ($e) {
            if ($e.PSObject.Properties['capability_ready']) { return ([bool]$e.capability_ready) }
            return ([bool]$e.python_ready -and [bool]$e.worker_ready)
        }
        return ([bool]$root.python_ready -and [bool]$root.worker_ready)
    } catch { return $false }
}

function Invoke-EnvBootstrap([string]$apiBase) {
    $token = [IO.File]::ReadAllText((Join-Path $InstallDir 'config\.auth_token')).Trim()
    Write-Host ""
    Write-Host ">>> 正在下载并配置 Python 运行环境（首次约 1~5 分钟，视网速可能更久）<<<"
    Write-Host ">>> 下方秒数持续跳动 = 正在下载中，属正常现象；请勿关闭本窗口，也不要退出右下角托盘程序 <<<"
    Write-Host ">>> 个别阶段百分比可能一直停在 0%，只要秒数在走、阶段名在变就是在正常下载 <<<"
    $job = Start-Job -ScriptBlock {
        param($u, $t)
        try {
            $r = Invoke-WebRequest -Uri ($u + '/api/environment/bootstrap') -Method POST -Headers @{ 'X-Auth-Token' = $t } -UseBasicParsing -TimeoutSec 900
            $txt = $null
            try { if ($r.RawContentStream -and $r.RawContentStream.Length -gt 0) { $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } } catch {}
            if (-not $txt) {
                if ($r.Content -is [byte[]]) { $txt = [Text.Encoding]::UTF8.GetString($r.Content) }
                else { $txt = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes([string]$r.Content)) }
            }
            return $txt
        } catch { return ('ERR:' + $_.Exception.Message) }
    } -ArgumentList $apiBase, $token
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stageShown = ''; $noStatusApi = $false
    while ($job.State -eq 'Running') {
        Start-Sleep -Seconds 2
        # 若程序提供环境状态接口则同步显示当前阶段（接口不存在时静默放弃）
        if (-not $noStatusApi) {
            try {
                # 实时进度走 GET /api/init-status（.environment.stage / .environment.progress）
                $s = Get-ApiJson ($apiBase + '/api/init-status') @{ 'X-Auth-Token' = $token } 2
                $root = if ($s.data) { $s.data } else { $s }
                $stg = ''
                if ($root.environment) {
                    $e = $root.environment
                    if ($e.stage) { $stg = [string]$e.stage }
                    if ($e.progress) {
                        $pg = $e.progress
                        if ($pg.message) { $stg = ($stg + ' ' + [int]$pg.percent + '% ' + [string]$pg.message).Trim() }
                        else { $stg = ($stg + ' ' + [int]$pg.percent + '%').Trim() }
                    }
                }
                if ($stg -and $stg -ne $stageShown) { Write-Host ("    状态: " + $stg); $stageShown = $stg }
            } catch { $noStatusApi = $true }
        }
        Write-Host -NoNewline ("    已等待 " + [int]$sw.Elapsed.TotalSeconds + " 秒 ...  `r")
    }
    $out = Receive-Job $job -Wait
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Write-Host ""
    if ($out -is [string] -and $out.StartsWith('ERR:')) { Write-Host ("  环境安装请求失败: " + $out.Substring(4)); return $null }
    try { return ($out | ConvertFrom-Json) } catch { return $null }
}

# ==================== 主流程（整体兜底） ====================
# 任何未预期的错误都会被捕获 -> 写入诊断日志 + 把窗口留住，避免"一闪而过、啥也看不到"
try {
Write-Host "================ campus-auth 一键安装 ================"
Write-Host ("安装目录: " + $InstallDir)

# ---- already installed? -> update mode (keep config & tasks) ----
$updateMode = Test-Path (Join-Path $InstallDir 'campus-auth.exe')
if ($updateMode) {
    Write-Host "检测到已安装 -> 更新模式（保留账号配置与任务，仅更新程序）"
    if (-not (Read-Choice '继续更新?')) { Write-Host "已取消。"; Write-Log "用户取消（更新）"; Wait-ExitKey '已取消'; exit 0 }
} else {
    if (-not (Read-Choice '开始全新安装?')) { Write-Host "已取消。"; Write-Log "用户取消（安装）"; Wait-ExitKey '已取消'; exit 0 }
}

# ---- credentials (fresh install only; terminal input, no web console) ----
if (-not $updateMode) {
    Write-Host ""
    Write-Host "---------- 首次配置：输入你的校园网账号密码 ----------"
    if (-not $Username) {
        while ($true) {
            $Username = Read-Host "请输入校园网账号(学号)"
            if ($Username -and $Username.Trim()) { $Username = $Username.Trim(); break }
            Write-Host "账号不能为空，请重新输入。"
        }
    }
    if (-not $Password) {
        while ($true) {
            # 明文回显：方便同学核对输入（安装场景多为本人操作）
            $Password = Read-Host "请输入校园网密码"
            if ($Password) { break }
            Write-Host "密码不能为空，请重新输入。"
        }
    }
    Write-Host ("账号: " + $Username + "   密码: " + $Password)
    Write-Host "------------------------------------------------------"
}

# ---- download (resolve latest version dynamically, pinned fallback) ----
$tmpZip  = Join-Path $env:TEMP ("campus-auth-" + [Guid]::NewGuid().ToString('N') + ".zip")
$tmpSha  = $tmpZip + ".sha256"
$tmpDir  = Join-Path $env:TEMP ("campus-auth-extract-" + [Guid]::NewGuid().ToString('N'))
try {
    # resolve latest version dynamically; pinned URL as fallback
    $zipUrl = $FALLBACK; $verLabel = 'v5.0.0-alpha.10'; $zipAssetId = 0; $shaAssetId = 0
    try {
        Write-Host "查询最新版本..."
        $rel = Invoke-RestMethod -Uri $API_URL -TimeoutSec 20 -UseBasicParsing
        $a = $rel.assets | Where-Object { $_.name -match 'x86_64-pc-windows-msvc\.zip$' } | Select-Object -First 1
        if ($a) { $zipUrl = $a.browser_download_url; $zipAssetId = $a.id; $verLabel = $rel.tag_name; Write-Host ("  最新版: " + $verLabel) }
        $s = $rel.assets | Where-Object { $_.name -match 'x86_64-pc-windows-msvc\.zip\.sha256$' } | Select-Object -First 1
        if ($s) { $shaAssetId = $s.id }
    } catch { Write-Host "  查询失败，使用内置链接兜底。" }
    Write-Host ("准备下载: campus-auth " + $verLabel + " (Windows x64)")
    # 通道顺序：① GitHub API 资产端点（校园网/受限网络下 github.com 与各类镜像常被阻断，
    #   而 api.github.com 通常可达，302 到 CDN 直下、实测最快）② github.com 直连 ③ 加速镜像
    # 每个通道都逐秒刷新进度（MB / 百分比 / 速度 / 秒数），单通道停滞 60 秒自动换下一个。
    $octet     = @{ 'Accept' = 'application/octet-stream' }
    $assetBase = 'https://api.github.com/repos/Misyra/Campus-Auth-rs/releases/assets/'
    $chans = New-Object System.Collections.ArrayList
    if ($zipAssetId) { [void]$chans.Add(@{ u = $assetBase + $zipAssetId; h = $octet; t = 'GitHub API 直下' }) }
    [void]$chans.Add(@{ u = $zipUrl; h = $null; t = 'GitHub 直连' })
    foreach ($m in @('https://gh-proxy.com/', 'https://ghfast.top/')) { [void]$chans.Add(@{ u = $m + $zipUrl; h = $null; t = ('加速镜像 ' + $m.TrimEnd('/')) }) }

    $dlOk = $false
    foreach ($c in $chans) {
        $tag = $c.t
        Write-Host ("  下载通道: " + $tag)
        try {
            Save-UrlWithProgress $c.u $tmpZip $tag 60 $c.h | Out-Null
            if ((Get-Item $tmpZip).Length -lt 1MB) { throw "文件过小，可能是错误页" }
            $dlOk = $true
            break
        } catch {
            Write-Host ("  " + $tag + " 失败: " + $_.Exception.Message)
            Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $dlOk) {
        Write-Host "所有下载通道均失败。请手动下载后重试："
        Write-Host ("  " + $zipUrl)
        Die "下载失败：所有下载通道均不可用（网络受限/被拦截）。"
    }
    $shaGot = $false
    if ($shaAssetId) {
        try { Save-UrlWithProgress ($assetBase + $shaAssetId) $tmpSha '校验和' 20 $octet | Out-Null; $shaGot = $true } catch { $shaGot = $false }
    }
    if ((-not $shaGot) -and (Invoke-Download ($zipUrl + '.sha256') $tmpSha -MinSize 16 -Quiet)) { $shaGot = $true }
    if ($shaGot) {
        $expect = ((Get-Content $tmpSha -TotalCount 1) -split '\s+')[0].Trim().ToLower()
        # 上游若未附 .sha256，或镜像返回的是错误页，拿到的都不是 64 位十六进制：
        # 此时「跳过校验」而非「中止安装」，避免上游打包问题挡住正常安装（用户曾遇此坑）
        if ($expect -match '^[0-9a-f]{64}$') {
            $actual = (Get-FileHash $tmpZip -Algorithm SHA256).Hash.ToLower()
            if ($expect -ne $actual) { Die "SHA256 校验失败（下载文件与官方校验值不符），安装中止。" }
            Write-Host "SHA256 校验通过"
        } else {
            Write-Host "未取得有效 SHA256 校验值，跳过校验（不影响安装）"
        }
    } else {
        Write-Host "该版本未附带 SHA256 校验文件，跳过校验（不影响安装）"
    }

    # ---- extract (handle top-level dir) ----
    Write-Host "解压中..."
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $items = Get-ChildItem $tmpDir
    $src = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $tmpDir }

    # ---- install ----
    Stop-RunningApp | Out-Null
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $skip = @('config', 'tasks', 'logs')   # never overwrite user data on update
    Get-ChildItem $src | Where-Object { -not ($updateMode -and $skip -contains $_.Name) } | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $InstallDir $_.Name) -Recurse -Force
    }
    Write-Host ("程序文件已就位: " + $InstallDir)

    # ---- configure autostart (login + wake/unlock coverage, portable) ----
    Write-Host "配置开机/唤醒自启..."
    Register-Autostart

    # ---- pre-configure (fresh install only) ----
    if (-not $updateMode) {
        Write-Host "写入预配置（学校认证地址 / 修好的通用任务）..."

        New-Item -ItemType Directory -Path (Join-Path $InstallDir 'config\profiles') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $InstallDir 'tasks\browser')    -Force | Out-Null

        $utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM

        # settings: auto-monitor on startup, headless, zh-CN
        $settingsJson = @'
@@SETTINGS_JSON@@
'@
        [IO.File]::WriteAllText((Join-Path $InstallDir 'config\settings.json'), $settingsJson, $utf8)

        # task: fixed universal login (icon-only carrier radio supported)
        $taskJson = @'
@@TASK_JSON@@
'@
        [IO.File]::WriteAllText((Join-Path $InstallDir 'tasks\browser\default.json'), $taskJson, $utf8)

        # task order / active task
        $orderJson = @'
@@ORDER_JSON@@
'@
        [IO.File]::WriteAllText((Join-Path $InstallDir 'tasks\.order.json'), $orderJson, $utf8)

        # profile: school auth url + terminal-entered credentials
        $profileObj = [ordered]@{
            id          = 'default'
            name        = '校园网'
            username    = $Username
            password    = $Password
            auth_url    = $AUTH_URL
            trigger_url = 'http://www.msftconnecttest.com/redirect'
            isp         = $ISP
            gateway_ip  = ''
            wifi_ssid   = ''
            active_task = 'default'
        }
        $profileJson = $profileObj | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $InstallDir 'config\profiles\default.json'), $profileJson, $utf8)

        # license-agreed marker (skip first-run prompt)
        [IO.File]::WriteAllText((Join-Path $InstallDir 'config\.agreed'), (Get-Date).ToUniversalTime().ToString('o'), $utf8)
    }

    # ---- done: launch + auto-prepare Python environment ----
    Write-Host ""
    Write-Host "================ 安装完成 ================"
    Write-Host ("程序目录 : " + $InstallDir)
    if ($NoLaunch) {
        Write-Host "测试模式：未启动程序。"
    } else {
        Write-Host "启动程序（后台隐藏窗口 + 托盘常驻）... 管理网页由程序自动打开，无需手动开浏览器"
        Write-Host "提示: 程序装好后就挂在右下角托盘，本安装窗口随时可以关，不影响程序运行。"
        Stop-RunningApp | Out-Null
        Remove-Item (Join-Path $InstallDir 'config\.instance') -Force -ErrorAction SilentlyContinue
        # ---- 预置 uv：提前把 uv.exe 放进 environment\，后端启动即判定 uv 就绪， ----
        # ---- 跳过程序自带的 uv 下载校验环节（该环节多镜像混下偶发校验不一致）  ----
        try {
            $uvDir = Join-Path $InstallDir 'environment'
            $uvExe = Join-Path $uvDir 'uv.exe'
            if (Test-Path $uvExe) {
                Write-Host "uv 已存在，跳过预置。"
            } else {
                Write-Host "预置 uv（镜像加速下载，之后后端将跳过 uv 下载环节）..."
                Write-Host "  uv 约 20 MB，下方进度会持续跳动；秒数在走即为正常，请稍候。"
                New-Item -ItemType Directory -Path $uvDir -Force | Out-Null
                $uvVer = $null; $uvRel = $null
                # 版本号：先直连 api.github.com（受限网络下它通常仍可达），失败再走镜像包装
                foreach ($uvApi in @('https://api.github.com/repos/astral-sh/uv/releases/latest', 'https://gh-proxy.com/https://api.github.com/repos/astral-sh/uv/releases/latest')) {
                    try { $uvRel = Get-ApiJson $uvApi @{} 20; if ($uvRel -and $uvRel.tag_name) { $uvVer = $uvRel.tag_name; break } } catch {}
                }
                if ($uvVer) {
                    $uvName = 'uv-x86_64-pc-windows-msvc'
                    $uvBase = ("https://github.com/astral-sh/uv/releases/download/" + $uvVer + "/" + $uvName)
                    $uvTmp  = Join-Path $uvDir 'uv-preset.zip'
                    $uvOk   = $false
                    # 通道：① API 资产端点直下（zip 与 sha 同源、官方权威）② 直连 ③ 加速镜像；
                    # zip 与校验值始终取自同一通道（同源才保证一致）
                    $uvAssetBase = 'https://api.github.com/repos/astral-sh/uv/releases/assets/'
                    $uvChans = New-Object System.Collections.ArrayList
                    try {
                        $uz = $uvRel.assets | Where-Object { $_.name -eq ($uvName + '.zip') } | Select-Object -First 1
                        $us = $uvRel.assets | Where-Object { $_.name -eq ($uvName + '.zip.sha256') } | Select-Object -First 1
                        if ($uz) {
                            $usUrl = if ($us) { $uvAssetBase + $us.id } else { $null }
                            [void]$uvChans.Add(@{ z = $uvAssetBase + $uz.id; s = $usUrl; h = $octet; t = 'GitHub API 直下' })
                        }
                    } catch {}
                    [void]$uvChans.Add(@{ z = $uvBase + '.zip'; s = $uvBase + '.zip.sha256'; h = $null; t = 'GitHub 直连' })
                    foreach ($um in @('https://gh-proxy.com/', 'https://ghfast.top/')) {
                        [void]$uvChans.Add(@{ z = $um + $uvBase + '.zip'; s = $um + $uvBase + '.zip.sha256'; h = $null; t = ('加速镜像 ' + $um.TrimEnd('/')) })
                    }
                    foreach ($c in $uvChans) {
                        Write-Host ("  uv 通道: " + $c.t)
                        try {
                            if ($c.s) { Save-UrlWithProgress $c.s ($uvTmp + '.sha256') '校验文件' 30 $c.h | Out-Null }
                            Save-UrlWithProgress $c.z $uvTmp ('uv ' + $uvVer) 60 $c.h | Out-Null
                            $want = ''
                            if (Test-Path ($uvTmp + '.sha256')) { $want = (([IO.File]::ReadAllText($uvTmp + '.sha256')).Trim() -split '\s+')[0].ToLower() }
                            $got = (Get-FileHash -Path $uvTmp -Algorithm SHA256).Hash.ToLower()
                            if (($want -match '^[0-9a-f]{64}$') -and ($got -ne $want)) {
                                Write-Host ("  " + $c.t + " 校验不一致，换下一个源...")
                            } else {
                                if ((-not ($want -match '^[0-9a-f]{64}$'))) { Write-Host "  未取得有效校验值，跳过校验（不影响安装）" }
                                $uvX = Join-Path $uvDir ('uv-preset-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                                Expand-Archive -Path $uvTmp -DestinationPath $uvX -Force
                                $found = Get-ChildItem -Path $uvX -Recurse -Filter 'uv.exe' | Select-Object -First 1
                                if ($found) { Move-Item -Path $found.FullName -Destination $uvExe -Force; $uvOk = $true }
                                Remove-Item $uvX -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        } catch {
                            Write-Host ("  " + $c.t + " 不可用: " + $_.Exception.Message)
                        }
                        Remove-Item ($uvTmp + '.sha256') -Force -ErrorAction SilentlyContinue
                        Remove-Item $uvTmp -Force -ErrorAction SilentlyContinue
                        if ($uvOk) { break }
                    }
                    if ($uvOk) { Write-Host ("  uv " + $uvVer + " 预置成功。") }
                    else { Write-Host "  uv 预置未成功（不影响安装），程序稍后会自行下载 uv。" }
                } else {
                    Write-Host "  无法获取 uv 版本号（不影响安装），程序稍后会自行下载 uv。"
                }
            }
        } catch {
            Write-Host ("  预置 uv 跳过（不影响安装）: " + $_.Exception.Message)
        }
        # ---- 预置 CPython 3.12 ----
        # Worker 工程的 pyproject 要求 python >=3.12,<3.13；机器上没有 3.12 时，
        # uv sync 会去 github.com 拉 managed CPython（受限/校园网络下常被阻断）→ venv 建不起来 → 后端报
        # "Worker import 探针失败（退出码 1）: No module named 'playwright'"。
        # 这里先用国内镜像把 3.12 装好，后端 uv sync 直接复用，不再联网下载解释器。
        try {
            if (Test-Path $uvExe) {
                Write-Host "预置 Python 3.12 解释器（Worker 依赖要求 3.12；避免后端从 github 下载失败）..."
                $pyMirror = 'https://mirror.nju.edu.cn/github-release/astral-sh/python-build-standalone/'
                $pyOk = $false
                foreach ($mm in @($pyMirror, '')) {
                    if ($mm) {
                        $env:UV_PYTHON_INSTALL_MIRROR = $mm
                        Write-Host "  解释器通道: 国内镜像 (mirror.nju.edu.cn)"
                    } else {
                        Remove-Item Env:UV_PYTHON_INSTALL_MIRROR -ErrorAction SilentlyContinue
                        Write-Host "  解释器通道: 官方源（github.com）"
                    }
                    try {
                        $pp = Start-Process -FilePath $uvExe -ArgumentList @('python', 'install', '3.12') -PassThru -WindowStyle Hidden
                        $pySw = [System.Diagnostics.Stopwatch]::StartNew()
                        while ((-not $pp.HasExited) -and ($pySw.Elapsed.TotalSeconds -lt 240)) {
                            Write-Host -NoNewline ("    已等待 " + [int]$pySw.Elapsed.TotalSeconds + " 秒 ...  `r")
                            Start-Sleep -Seconds 2
                        }
                        Write-Host ""
                        if (-not $pp.HasExited) {
                            try { $pp.Kill() } catch {}
                            Write-Host "    该通道超时（4 分钟），换下一个。"
                            Write-Log ("python 3.12 预置超时 mirror=" + $mm)
                        } elseif ($pp.ExitCode -eq 0) {
                            $pyOk = $true
                            break
                        } else {
                            Write-Host ("    该通道失败（退出码 " + $pp.ExitCode + "），换下一个。")
                            Write-Log ("python 3.12 预置失败 exit=" + $pp.ExitCode)
                        }
                    } catch {
                        Write-Host ("    通道异常: " + $_.Exception.Message)
                    }
                }
                Remove-Item Env:UV_PYTHON_INSTALL_MIRROR -ErrorAction SilentlyContinue
                if ($pyOk) {
                    Write-Host "  Python 3.12 预置成功（后端 uv sync 直接复用，不再联网下载解释器）。"
                    Write-Log "python 3.12 预置成功"
                } else {
                    Write-Host "  Python 3.12 预置未成功（不影响安装），后端会自行尝试下载。"
                }
            }
        } catch {
            Write-Host ("  预置 Python 解释器跳过（不影响安装）: " + $_.Exception.Message)
        }
        $launched = $false
        try {
            # 经系统 WMI 服务代为拉起进程：后端父进程是系统服务、无控制台、与任何命令行窗口零关联，
            # 安装窗口/任何命令行怎么关都带不走后端（此前直接 Start-Process 时后端会跟着命令行一起死）
            $exePath = Join-Path $InstallDir 'campus-auth.exe'
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Start-Process -FilePath '$exePath' -WorkingDirectory '$InstallDir' -WindowStyle Hidden"))
            $wmi = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "powershell -NoProfile -WindowStyle Hidden -EncodedCommand $enc" }
            if ($wmi.ReturnValue -eq 0) { $launched = $true } else { Write-Host ("  WMI 启动返回码: " + $wmi.ReturnValue) }
        } catch {
            Write-Host ("  WMI 启动不可用: " + $_.Exception.Message)
        }
        if (-not $launched) {
            # 备用通道：直接隐藏窗口启动
            try {
                Start-Process -FilePath (Join-Path $InstallDir 'campus-auth.exe') -WorkingDirectory $InstallDir -WindowStyle Hidden
                $launched = $true
            } catch {
                Write-Host ("  启动命令失败: " + $_.Exception.Message)
            }
        }
        Start-Sleep -Seconds 3
        $alive = $false
        if ($launched) {
            $mine2 = Join-Path $InstallDir '*'
            foreach ($try in 1..4) {
                foreach ($p in (Get-Process -Name 'campus-auth' -ErrorAction SilentlyContinue)) {
                    $pp = ''
                    try { $pp = $p.Path } catch {}
                    if ((-not $pp) -or ($pp -like $mine2)) { $alive = $true; break }
                }
                if ($alive) { break }
                Start-Sleep -Seconds 3
            }
        }
        if ($launched -and $alive) {
            if (Wait-ApiReady 75) {
            Write-Host ("程序已就绪: " + $script:ApiBase)
            $ready = $false; $lastErr = ''
            if (Test-EnvReady $script:ApiBase) {
                $ready = $true
                Write-Host "环境已就绪（此前已装好），无需再装。"
            }
            for ($i = 1; $i -le 3 -and -not $ready; $i++) {
                if ($i -gt 1) { Write-Host ("开始第 " + $i + "/3 次重试（已下载部分会续用，不会从头再来）...") }
                $st = Invoke-EnvBootstrap $script:ApiBase
                # 响应外包一层 data；就绪判定与网页一致：capability_ready（兜底 python_ready + worker_ready）
                $stRoot = if ($st -and $st.data) { $st.data } else { $st }
                if ($stRoot -and ($stRoot.capability_ready -or ($stRoot.python_ready -and $stRoot.worker_ready))) { $ready = $true; break }
                $lastErr = if ($stRoot -and $stRoot.last_error) { $stRoot.last_error } else { '请求失败（服务无响应）' }
                Write-Host ("  第 " + $i + " 次尝试未完成: " + $lastErr)
                if ($i -lt 3) { Start-Sleep -Seconds 3 }
            }
            if (-not $ready) {
                # 常见情况：环境其实已装好，只是后端状态回报慢/网页没刷新 -> 最后复核最多 5 次
                Write-Host "三轮尝试结束，最后复核环境实际状态（最多 5 次，环境可能已装好，只是状态刷新慢）..."
                for ($n2 = 1; $n2 -le 5; $n2++) {
                    Write-Host -NoNewline ("    复核中 (第 " + $n2 + "/5 次) ...  `r")
                    if (Test-EnvReady $script:ApiBase) { $ready = $true; break }
                    Start-Sleep -Seconds 5
                }
                Write-Host ""
            }
            if ($ready) {
                Write-Host ""
                Write-Host "全部就绪！管理网页已由程序自动打开（浏览器没弹的话，手动访问: $script:ApiBase ）"
                Write-Host "程序现在后台/托盘常驻：本窗口、浏览器都可随时关闭，不影响自动登录。"
                Write-Host "连上校园网 WiFi 后程序会自动登录，全程无需再开网页。"
                Write-Host "注意: 现在没上网/没登录动作是正常的 - 程序只在检测到校园网未认证状态时才自动登录，"
                Write-Host "      平时挂在托盘没有动静不代表坏了。回到学校连上校园网它自己就会干活。"
            } else {
                Write-Host ""
                Write-Host "环境自动配置未完成。请按下面顺序处理："
                Write-Host "  0) 先看管理网页: 若出现红色\"环境未配置/环境异常\"之类的红色提示，直接点一下那个红色提示刷新状态"
                Write-Host "     —— 多次尝试后环境大概率已经实际装好，只是网页状态没自动刷新，点一下通常就变绿"
                Write-Host "  1) 手机热点连上电脑（或先手动用浏览器登录一次校园网），保证有外网"
                Write-Host "  2) 重新双击运行本脚本 -> 自动继续安装环境（已下载部分不会重来）"
                Write-Host ("  3) 仍失败: 浏览器打开 " + $script:ApiBase + " -> 设置 -> 环境，手动安装")
                if ($lastErr) { Write-Host ("  最后错误: " + $lastErr) }
            }
            } else {
                Write-Host "程序已启动，但服务端口迟迟未就绪。"
                Write-Host "请看右下角托盘有无 campus-auth 图标，稍等 1 分钟再刷新管理网页。"
                Write-Host "若托盘始终没有图标：重新双击本脚本，或直接双击安装目录里的 campus-auth.exe。"
            }
        } else {
            Write-Host ""
            Write-Host "程序未能保持运行（启动命令失败，或进程数秒内退出）。最常见原因:"
            Write-Host "  1) 杀毒软件拦截/删除了 campus-auth.exe -> 加入信任区，或从隔离区还原"
            Write-Host "  2) 有残留的旧实例占用 -> 重启电脑后再双击本脚本"
            Write-Host "处理后重新双击本脚本，或直接双击安装目录里的 campus-auth.exe。程序启动后会自动打开管理网页。"
        }
    }
} finally {
    Remove-Item $tmpZip, $tmpSha -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
} catch {
    $em = $_.Exception.Message
    Write-Log "==== 未捕获异常 ===="
    try { Write-Log ($_ | Out-String) } catch {}
    if ($_.InvocationInfo) { Write-Log ("位置: 第 " + $_.InvocationInfo.ScriptLineNumber + " 行") }
    Write-Host ""
    Write-Host ("安装过程中出现未预期的错误: " + $em)
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { Write-Host ("  出错位置: 第 " + $_.InvocationInfo.ScriptLineNumber + " 行") }
    Write-Host "可能原因：杀毒/安全软件拦截、系统脚本策略受限、网络被阻断、文件在传输中损坏。"
    Write-Host ("诊断日志（请把这个文件发回来）: " + $LogFile)
    Wait-ExitKey '出错了'
    exit 1
}
# 正常走完（直接双击 .ps1 时窗口不会一闪而过）
Write-Log "================ 安装器结束 ================"
Wait-ExitKey '安装流程结束'
