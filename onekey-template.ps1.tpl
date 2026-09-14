# ============================================================
# campus-auth one-click installer (for campus-mates)
# - asks for username & password right in the terminal
# - resolves latest release dynamically (fallback: pinned URL)
# - downloads (gh-proxy fallback), extracts, writes full config
# - starts the tray app; the web console is never needed
# ============================================================
# options via env vars (silent/test runs): CA_INSTALLDIR / CA_USERNAME /
# CA_PASSWORD / CA_ASSUMEYES / CA_NOLAUNCH
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

Write-Host "================ campus-auth 一键安装 ================"
Write-Host ("安装目录: " + $InstallDir)

# ---- already installed? -> update mode (keep config & tasks) ----
$updateMode = Test-Path (Join-Path $InstallDir 'campus-auth.exe')
if ($updateMode) {
    Write-Host "检测到已安装 -> 更新模式（保留账号配置与任务，仅更新程序）"
    if (-not (Read-Choice '继续更新?')) { Write-Host "已取消。"; exit 0 }
} else {
    if (-not (Read-Choice '开始全新安装?')) { Write-Host "已取消。"; exit 0 }
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
            $Password = Read-Host "请输入校园网密码"
            if ($Password) { break }
            Write-Host "密码不能为空，请重新输入。"
        }
    }
    Write-Host ("账号: " + $Username + "   密码: 已输入")
    Write-Host "------------------------------------------------------"
}

# ---- download (resolve latest version dynamically, pinned fallback) ----
$tmpZip  = Join-Path $env:TEMP ("campus-auth-" + [Guid]::NewGuid().ToString('N') + ".zip")
$tmpSha  = $tmpZip + ".sha256"
$tmpDir  = Join-Path $env:TEMP ("campus-auth-extract-" + [Guid]::NewGuid().ToString('N'))
try {
    # resolve latest version dynamically; pinned URL as fallback
    $zipUrl = $FALLBACK; $verLabel = 'v5.0.0-alpha.10'
    try {
        Write-Host "查询最新版本..."
        $rel = Invoke-RestMethod -Uri $API_URL -TimeoutSec 20 -UseBasicParsing
        $a = $rel.assets | Where-Object { $_.name -match 'x86_64-pc-windows-msvc\.zip$' } | Select-Object -First 1
        if ($a) { $zipUrl = $a.browser_download_url; $verLabel = $rel.tag_name; Write-Host ("  最新版: " + $verLabel) }
    } catch { Write-Host "  查询失败，使用内置链接兜底。" }
    Write-Host ("准备下载: campus-auth " + $verLabel + " (Windows x64)")
if (-not (Invoke-Download $zipUrl $tmpZip)) {
    Write-Host "所有下载通道均失败。请手动下载后重试："
    Write-Host ("  " + $zipUrl)
    exit 1
}
if (Invoke-Download ($zipUrl + '.sha256') $tmpSha -MinSize 16 -Quiet) {
        $expect = ((Get-Content $tmpSha -TotalCount 1) -split '\s+')[0].Trim().ToLower()
        $actual = (Get-FileHash $tmpZip -Algorithm SHA256).Hash.ToLower()
        if ($expect -ne $actual) { Write-Host "SHA256 校验失败，安装中止。"; exit 1 }
        Write-Host "SHA256 校验通过"
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
                New-Item -ItemType Directory -Path $uvDir -Force | Out-Null
                $uvVer = $null
                try {
                    $uvApi = 'https://gh-proxy.com/https://api.github.com/repos/astral-sh/uv/releases/latest'
                    $uvVer = (Get-ApiJson $uvApi @{} 20).tag_name
                } catch {}
                if ($uvVer) {
                    $uvBase = ("https://github.com/astral-sh/uv/releases/download/" + $uvVer + "/uv-x86_64-pc-windows-msvc")
                    $uvTmp = Join-Path $uvDir 'uv-preset.zip'
                    $uvOk = $false
                    # zip 与校验值必须取自同一镜像（同源才保证一致），逐镜像成对下载
                    foreach ($uvPrefix in @('https://gh-proxy.com/', 'https://ghfast.top/')) {
                        try {
                            $uvUa = @{ 'User-Agent' = 'campus-auth-installer/1.0' }
                            Invoke-WebRequest -Uri ($uvPrefix + $uvBase + '.zip.sha256') -OutFile ($uvTmp + '.sha256') -Headers $uvUa -UseBasicParsing -TimeoutSec 60
                            Invoke-WebRequest -Uri ($uvPrefix + $uvBase + '.zip') -OutFile $uvTmp -Headers $uvUa -UseBasicParsing -TimeoutSec 300
                            $want = ([IO.File]::ReadAllText($uvTmp + '.sha256').Trim() -split '\s+')[0]
                            $got = (Get-FileHash -Path $uvTmp -Algorithm SHA256).Hash.ToLower()
                            if ($got -eq $want) {
                                $uvX = Join-Path $uvDir ('uv-preset-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                                Expand-Archive -Path $uvTmp -DestinationPath $uvX -Force
                                $found = Get-ChildItem -Path $uvX -Recurse -Filter 'uv.exe' | Select-Object -First 1
                                if ($found) { Move-Item -Path $found.FullName -Destination $uvExe -Force; $uvOk = $true }
                                Remove-Item $uvX -Recurse -Force -ErrorAction SilentlyContinue
                            } else {
                                Write-Host ("  镜像 " + $uvPrefix + " 校验不一致，换下一个源...")
                            }
                        } catch {
                            Write-Host ("  镜像 " + $uvPrefix + " 不可用，换下一个源...")
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
