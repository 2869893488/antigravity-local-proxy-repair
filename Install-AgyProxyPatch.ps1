<#
.SYNOPSIS
    Antigravity CLI (agy) 本地代理修复与局部注入维护脚本
.DESCRIPTION
    将 antigravity-local-proxy-repair 的核心防御性工程思想迁移至 Antigravity CLI。
    实现：
    1. settings.json (proxyServerURL) 的安全注入与时间戳备份。
    2. 生成进程级隔离启动器 (agy-proxy.cmd / agy-proxy.ps1)，注入大/小写全覆盖代理环境变量。
    3. 支持 PowerShell Profile 钩子注入，直接执行 agy 命令即可自动启用代理。
    4. 支持 -TakeoverAgy 二进制接管模式（将 agy.exe 备份更名为 agy-real.exe，部署 agy.cmd），实现在所有终端（CMD/PowerShell/Git Bash 等）中直接调用 agy 均自动生效。
    5. 自动优化认证模式：若未指定独立 API Key，自动移除 modelProvider 以支持使用个人 Google 账号登录。
    6. 零系统污染：不修改 Windows 全局注册表或用户环境变量。
    7. 支持 -Check 探针模式、-Uninstall 卸载模式及代理端口连通性检查。
#>

[CmdletBinding()]
param(
    [ValidatePattern('^https?://')]
    [string]$ProxyUrl = 'http://127.0.0.1:7890',

    [string]$AgyBinDirectory = (Join-Path $env:LOCALAPPDATA 'agy\bin'),

    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.gemini\antigravity-cli\settings.json'),

    [switch]$TakeoverAgy,

    [switch]$NoProfileHook,

    [switch]$Check,

    [switch]$Uninstall,

    [switch]$NoShim
)

$ErrorActionPreference = 'Stop'

function Write-Status([string]$Message) {
    Write-Host "[Antigravity CLI Proxy] $Message"
}

function Write-WarnStatus([string]$Message) {
    Write-Host "[Antigravity CLI Proxy][警告] $Message" -ForegroundColor Yellow
}

function Add-OrReplaceProperty($Object, [string]$Name, $Value) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $property.Value = $Value
    }
}

function Remove-PropertyIfExists($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Backup-File([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = "$Path.bak-proxy-$timestamp"
        Copy-Item -LiteralPath $Path -Destination $backupPath -ErrorAction Stop
        Write-Status "已创建备份：$backupPath"
    }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Test-PortListening([string]$HostAddress, [int]$Port) {
    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new()
        $asyncResult = $tcpClient.BeginConnect($HostAddress, $Port, $null, $null)
        $success = $asyncResult.AsyncWaitHandle.WaitOne(600, $false)
        if ($success -and $tcpClient.Connected) {
            $tcpClient.EndConnect($asyncResult)
            $tcpClient.Close()
            return $true
        }
        $tcpClient.Close()
        return $false
    } catch {
        return $false
    }
}

function Test-ProxyReachability([string]$Url) {
    try {
        $uri = [System.Uri]$Url
        return Test-PortListening $uri.Host $uri.Port
    } catch {
        return $false
    }
}

function Detect-ActiveProxyPort {
    $candidatePorts = @(7890, 7897, 33210, 10809, 10808)
    foreach ($p in $candidatePorts) {
        if (Test-PortListening '127.0.0.1' $p) {
            return "http://127.0.0.1:$p"
        }
    }
    return $null
}

function Get-RelevantProfilePaths {
    $paths = [System.Collections.Generic.List[string]]::new()
    if ($PROFILE) {
        if ($PROFILE.CurrentUserAllHosts) { $paths.Add($PROFILE.CurrentUserAllHosts) }
        if ($PROFILE.CurrentUserCurrentHost) { $paths.Add($PROFILE.CurrentUserCurrentHost) }
    }
    $pwshDir = Join-Path $env:USERPROFILE 'Documents\PowerShell'
    $paths.Add((Join-Path $pwshDir 'Microsoft.PowerShell_profile.ps1'))
    $paths.Add((Join-Path $pwshDir 'profile.ps1'))

    return ($paths | Select-Object -Unique)
}

$agyExe = Join-Path $AgyBinDirectory 'agy.exe'
$agyRealExe = Join-Path $AgyBinDirectory 'agy-real.exe'
$takeoverCmd = Join-Path $AgyBinDirectory 'agy.cmd'
$shimCmd = Join-Path $AgyBinDirectory 'agy-proxy.cmd'
$shimPs1 = Join-Path $AgyBinDirectory 'agy-proxy.ps1'

$beginMarker = '# ANTIGRAVITY_PROXY_PATCH_BEGIN'
$endMarker   = '# ANTIGRAVITY_PROXY_PATCH_END'
$profilePattern = '(?ms)^[ \t]*# ANTIGRAVITY_PROXY_PATCH_BEGIN.*?^[ \t]*# ANTIGRAVITY_PROXY_PATCH_END\r?\n?'

# 1. 基础路径及运行状态检测
$running = Get-Process -Name 'agy', 'agy-node', 'agy-real' -ErrorAction SilentlyContinue
if ($running) {
    $names = ($running | Select-Object -ExpandProperty ProcessName -Unique) -join '、'
    if ($Check) {
        Write-Status "检测到正在运行的 CLI 进程：$names (检查模式未做任何修改)"
    } else {
        Write-WarnStatus "检测到正在运行的 CLI 进程：$names。建议先退出相关进程再应用修改。"
    }
}

# 自动端口诊断与推荐
$portAccessible = Test-ProxyReachability $ProxyUrl
if (-not $portAccessible) {
    $detectedProxy = Detect-ActiveProxyPort
    if ($detectedProxy) {
        Write-Status "提示：检测到本机 $detectedProxy 正在监听代理服务。"
        if ($PSBoundParameters.ContainsKey('ProxyUrl')) {
            Write-WarnStatus "你指定的代理地址 $ProxyUrl 目前未连通，可考虑更换为 $detectedProxy。"
        } else {
            Write-Status "已自动选用检测到的活动代理：$detectedProxy"
            $ProxyUrl = $detectedProxy
            $portAccessible = $true
        }
    }
}

$exeFound = (Test-Path -LiteralPath $agyExe) -or (Test-Path -LiteralPath $agyRealExe)
$isTakeoverActive = (Test-Path -LiteralPath $agyRealExe) -and (Test-Path -LiteralPath $takeoverCmd)

# 2. 检查模式 (-Check)
if ($Check) {
    Write-Status "=== Antigravity CLI 代理状态诊断 ==="
    $exeStatus = if (Test-Path -LiteralPath $agyRealExe) {
        "$agyRealExe (已由 agy.cmd 接管)"
    } elseif (Test-Path -LiteralPath $agyExe) {
        "$agyExe (原生二进制)"
    } else {
        '未找到 [请确认是否安装]'
    }
    Write-Status "CLI 路径：$exeStatus"
    Write-Status "目标代理：$ProxyUrl"
    $portStatus = if ($portAccessible) { '正常 [监听中]' } else { '未连通 [代理客户端可能未启动或端口不匹配]' }
    Write-Status "代理端口连通性：$portStatus"

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $currentConfig = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
            $currentProxyUrl = $currentConfig.proxyServerURL
            if ($currentProxyUrl) {
                Write-Status "配置文件代理 (settings.json)：$currentProxyUrl"
            } else {
                Write-Status "配置文件代理 (settings.json)：未配置 proxyServerURL"
            }
            if ($currentConfig.modelProvider) {
                Write-WarnStatus "当前 modelProvider 设置为 $($currentConfig.modelProvider)（若未设置对应 API KEY 会导致无法打开，建议移除以使用 Google 账号官方登录）"
            } else {
                Write-Status "认证模式：Google 账号默认后端 (Default Backend)"
            }
        } catch {
            Write-WarnStatus "配置文件无法正常解析为 JSON：$ConfigPath"
        }
    } else {
        Write-Status "配置文件代理 (settings.json)：文件不存在"
    }

    $shimCmdStatus = if (Test-Path -LiteralPath $shimCmd) { '已就绪' } else { '未安装' }
    $shimPs1Status = if (Test-Path -LiteralPath $shimPs1) { '已就绪' } else { '未安装' }
    $takeoverStatus = if ($isTakeoverActive) { '已激活 (直接执行 agy 自动启用代理)' } else { '未激活' }

    Write-Status "专用垫片 (agy-proxy.cmd)：$shimCmdStatus"
    Write-Status "PowerShell 垫片 (agy-proxy.ps1)：$shimPs1Status"
    Write-Status "全终端 agy 接管 (agy.cmd)：$takeoverStatus"

    $profilePaths = Get-RelevantProfilePaths
    $hookFound = $false
    foreach ($p in $profilePaths) {
        if (Test-Path -LiteralPath $p) {
            $text = [System.IO.File]::ReadAllText($p)
            if ($text -match [regex]::Escape($beginMarker)) {
                $hookFound = $true
                Write-Status "PowerShell Profile 钩子：已安装于 $p"
            }
        }
    }
    if (-not $hookFound) {
        Write-Status "PowerShell Profile 钩子：未安装"
    }

    exit 0
}

# 3. 卸载/还原模式 (-Uninstall)
if ($Uninstall) {
    Write-Status "=== 正在还原 Antigravity CLI 代理配置 ==="

    # 3.1 还原 settings.json
    if (Test-Path -LiteralPath $ConfigPath) {
        Backup-File $ConfigPath
        try {
            $config = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
            Remove-PropertyIfExists $config 'proxyServerURL'
            Write-Utf8NoBom $ConfigPath (($config | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
            Write-Status "已从 settings.json 中移除 proxyServerURL"
        } catch {
            Write-WarnStatus "更新 settings.json 失败：$_"
        }
    }

    # 3.2 还原二进制接管
    if (Test-Path -LiteralPath $takeoverCmd) {
        Remove-Item -LiteralPath $takeoverCmd -Force
        Write-Status "已移除接管启动器：$takeoverCmd"
    }
    if (Test-Path -LiteralPath $agyRealExe) {
        if (Test-Path -LiteralPath $agyExe) {
            Write-WarnStatus "同时存在 agy.exe 与 agy-real.exe，保留原 agy.exe"
        } else {
            Move-Item -LiteralPath $agyRealExe -Destination $agyExe -Force
            Write-Status "已还原二进制名称：$agyRealExe -> $agyExe"
        }
    }

    # 3.3 移除垫片
    if (Test-Path -LiteralPath $shimCmd) {
        Remove-Item -LiteralPath $shimCmd -Force
        Write-Status "已移除命令垫片：$shimCmd"
    }
    if (Test-Path -LiteralPath $shimPs1) {
        Remove-Item -LiteralPath $shimPs1 -Force
        Write-Status "已移除 PowerShell 垫片：$shimPs1"
    }

    # 3.4 清理 PowerShell Profile 钩子
    $profilePaths = Get-RelevantProfilePaths
    foreach ($p in $profilePaths) {
        if (Test-Path -LiteralPath $p) {
            $text = [System.IO.File]::ReadAllText($p)
            if ($text -match [regex]::Escape($beginMarker)) {
                Backup-File $p
                $newText = [regex]::Replace($text, $profilePattern, '')
                Write-Utf8NoBom $p $newText
                Write-Status "已从 Profile 移除钩子：$p"
            }
        }
    }

    Write-Status "卸载与还原完成。"
    exit 0
}

# 4. 实际安装 / 修复流程
Write-Status "=== 正在应用 Antigravity CLI 代理补丁 ==="
Write-Status "目标代理地址：$ProxyUrl"

if (-not $portAccessible) {
    Write-WarnStatus "目标代理地址 $ProxyUrl 目前无法连接！请确保代理客户端（如 Clash/V2Ray/Sing-box 等）已开启且监听对应端口。"
}

# 4.1 更新 settings.json
if (Test-Path -LiteralPath $ConfigPath) {
    Backup-File $ConfigPath
    try {
        $config = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    } catch {
        Write-WarnStatus "原配置文件损坏，将新建配置对象"
        $config = [pscustomobject]@{}
    }
} else {
    $config = [pscustomobject]@{}
}

Add-OrReplaceProperty $config 'proxyServerURL' $ProxyUrl

# 若未设置自定义 GEMINI_API_KEY，自动移除 modelProvider，避免因缺少 Key 导致无法启动
if ($null -ne $config.modelProvider -and -not $env:GEMINI_API_KEY) {
    Remove-PropertyIfExists $config 'modelProvider'
    Write-Status "已自动移除 modelProvider，配置为支持 Google 账号官方登录"
}

Write-Utf8NoBom $ConfigPath (($config | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
Write-Status "已安全写入 settings.json (UTF-8 无 BOM)"

# 4.2 安装环境隔离 Shim 启动器 (agy-proxy.cmd / agy-proxy.ps1)
if (-not $NoShim) {
    if (-not (Test-Path -LiteralPath $AgyBinDirectory)) {
        New-Item -ItemType Directory -Path $AgyBinDirectory -Force | Out-Null
    }

    $cmdContent = @"
@echo off
rem ====================================================================
rem Antigravity CLI Process-Scoped Proxy Wrapper
rem Generated by Install-AgyProxyPatch.ps1
rem ====================================================================
setlocal

set "HTTP_PROXY=$ProxyUrl"
set "HTTPS_PROXY=$ProxyUrl"
set "http_proxy=$ProxyUrl"
set "https_proxy=$ProxyUrl"
set "ALL_PROXY=$ProxyUrl"
set "all_proxy=$ProxyUrl"
set "NO_PROXY=localhost,127.0.0.1,::1,*.local"

if exist "%~dp0agy-real.exe" (
    "%~dp0agy-real.exe" %*
) else if exist "%~dp0agy.exe" (
    "%~dp0agy.exe" %*
) else (
    agy %*
)

set "EXITCODE=%ERRORLEVEL%"
endlocal & exit /b %EXITCODE%
"@

    $ps1Content = @"
<#
    Antigravity CLI Process-Scoped Proxy Wrapper for PowerShell
    Generated by Install-AgyProxyPatch.ps1
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = `$true)]
    [string[]]`$RemainingArgs
)

`$oldHttpProxy       = `$env:HTTP_PROXY
`$oldHttpsProxy      = `$env:HTTPS_PROXY
`$oldHttpProxyLower  = `$env:http_proxy
`$oldHttpsProxyLower = `$env:https_proxy
`$oldAllProxy        = `$env:ALL_PROXY
`$oldAllProxyLower   = `$env:all_proxy
`$oldNoProxy         = `$env:NO_PROXY

try {
    `$env:HTTP_PROXY  = '$ProxyUrl'
    `$env:HTTPS_PROXY = '$ProxyUrl'
    `$env:http_proxy  = '$ProxyUrl'
    `$env:https_proxy = '$ProxyUrl'
    `$env:ALL_PROXY   = '$ProxyUrl'
    `$env:all_proxy   = '$ProxyUrl'
    `$env:NO_PROXY    = 'localhost,127.0.0.1,::1,*.local'

    `$targetRealExe = Join-Path `$PSScriptRoot 'agy-real.exe'
    `$targetExe     = Join-Path `$PSScriptRoot 'agy.exe'
    if (Test-Path -LiteralPath `$targetRealExe) {
        & `$targetRealExe @RemainingArgs
    } elseif (Test-Path -LiteralPath `$targetExe) {
        & `$targetExe @RemainingArgs
    } else {
        & agy @RemainingArgs
    }
} finally {
    `$env:HTTP_PROXY  = `$oldHttpProxy
    `$env:HTTPS_PROXY = `$oldHttpsProxy
    `$env:http_proxy  = `$oldHttpProxyLower
    `$env:https_proxy = `$oldHttpsProxyLower
    `$env:ALL_PROXY   = `$oldAllProxy
    `$env:all_proxy   = `$oldAllProxyLower
    `$env:NO_PROXY    = `$oldNoProxy
}
"@

    Backup-File $shimCmd
    Backup-File $shimPs1
    Write-Utf8NoBom $shimCmd ($cmdContent + [Environment]::NewLine)
    Write-Utf8NoBom $shimPs1 ($ps1Content + [Environment]::NewLine)

    $localBinCmd = Join-Path $PSScriptRoot 'agy-proxy.cmd'
    $localBinPs1 = Join-Path $PSScriptRoot 'agy-proxy.ps1'
    Write-Utf8NoBom $localBinCmd ($cmdContent + [Environment]::NewLine)
    Write-Utf8NoBom $localBinPs1 ($ps1Content + [Environment]::NewLine)

    Write-Status "已就绪专用垫片启动器：$shimCmd"
}

# 4.3 二进制接管模式 (-TakeoverAgy)
if ($TakeoverAgy) {
    Write-Status "正在配置全局 agy 命令接管..."
    if ((Test-Path -LiteralPath $agyExe) -and -not (Test-Path -LiteralPath $agyRealExe)) {
        Backup-File $agyExe
        Move-Item -LiteralPath $agyExe -Destination $agyRealExe -Force
        Write-Status "已将原二进制安全重命名：$agyExe -> $agyRealExe"
    }

    $agyCmdContent = @"
@echo off
rem ====================================================================
rem Antigravity CLI Direct Takeover Wrapper (agy)
rem Generated by Install-AgyProxyPatch.ps1
rem ====================================================================
setlocal

set "HTTP_PROXY=$ProxyUrl"
set "HTTPS_PROXY=$ProxyUrl"
set "http_proxy=$ProxyUrl"
set "https_proxy=$ProxyUrl"
set "ALL_PROXY=$ProxyUrl"
set "all_proxy=$ProxyUrl"
set "NO_PROXY=localhost,127.0.0.1,::1,*.local"

if exist "%~dp0agy-real.exe" (
    "%~dp0agy-real.exe" %*
) else if exist "%~dp0agy.exe" (
    "%~dp0agy.exe" %*
) else (
    echo [Antigravity CLI Proxy Error] agy-real.exe not found!
    exit /b 1
)

set "EXITCODE=%ERRORLEVEL%"
endlocal & exit /b %EXITCODE%
"@
    Write-Utf8NoBom $takeoverCmd ($agyCmdContent + [Environment]::NewLine)
    Write-Status "已部署接管入口：$takeoverCmd"
}

# 4.4 PowerShell Profile 钩子注入（默认启用）
if (-not $NoProfileHook) {
    $profileHookBlock = @"
# ANTIGRAVITY_PROXY_PATCH_BEGIN
# Scoped process-isolated proxy wrapper for Antigravity CLI
function agy {
    & "$shimPs1" @args
}
# ANTIGRAVITY_PROXY_PATCH_END
"@

    $profilePaths = Get-RelevantProfilePaths
    foreach ($p in $profilePaths) {
        $parent = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $existingContent = if (Test-Path -LiteralPath $p) {
            [System.IO.File]::ReadAllText($p)
        } else {
            ''
        }

        if ($existingContent -match [regex]::Escape($beginMarker)) {
            $newProfileContent = [regex]::Replace($existingContent, $profilePattern, ($profileHookBlock + [Environment]::NewLine))
        } else {
            $newProfileContent = $existingContent
            if ($newProfileContent.Length -gt 0 -and -not $newProfileContent.EndsWith([Environment]::NewLine)) {
                $newProfileContent += [Environment]::NewLine
            }
            $newProfileContent += ($profileHookBlock + [Environment]::NewLine)
        }

        if ($newProfileContent -ne $existingContent) {
            Backup-File $p
            Write-Utf8NoBom $p $newProfileContent
            Write-Status "已在 PowerShell Profile 中装载 agy 代理包装函数：$p"
        } else {
            Write-Status "PowerShell Profile 已配置钩子，无需改动：$p"
        }
    }
}

Write-Status "=== 补丁配置完成 ==="
Write-Status "验证指引："
Write-Status "1. 在终端中直接执行 agy 即可启动已启用局部代理的 CLI 会话。"
Write-Status "2. 所有派生命令（Git, Curl, Python, MCP 等）均自动继承局部代理，会话结束自动销毁。"
