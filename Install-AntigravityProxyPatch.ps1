[CmdletBinding()]
param(
    [ValidatePattern('^https?://')]
    [string]$ProxyUrl = 'http://127.0.0.1:7890',

    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\antigravity'),

    [switch]$Check
)

$ErrorActionPreference = 'Stop'

function Write-Status([string]$Message) {
    Write-Host "[Antigravity Proxy] $Message"
}

function Add-OrReplaceProperty($Object, [string]$Name, $Value) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $property.Value = $Value
    }
}

function Backup-File([string]$Path) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$Path.bak-proxy-$timestamp"
    Copy-Item -LiteralPath $Path -Destination $backupPath -ErrorAction Stop
    Write-Status "已创建备份：$backupPath"
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$appExe = Join-Path $InstallDirectory 'Antigravity.exe'
$languageServerPath = Join-Path $InstallDirectory 'resources\app\dist\languageServer.js'
$configPath = Join-Path $env:APPDATA 'Antigravity\gui_config.json'

if (-not (Test-Path -LiteralPath $appExe)) {
    throw "未找到 Antigravity.exe：$appExe"
}
if (-not (Test-Path -LiteralPath $languageServerPath)) {
    throw "未找到语言服务启动文件：$languageServerPath"
}

$running = Get-Process -Name 'Antigravity', 'language_server' -ErrorAction SilentlyContinue
if ($running) {
    $names = ($running | Select-Object -ExpandProperty ProcessName -Unique) -join '、'
    if ($Check) {
        Write-Status "检测到正在运行：$names（检查模式未修改任何内容）"
    } else {
        throw "请先完全退出 Antigravity 后再执行。正在运行：$names"
    }
}

$js = [System.IO.File]::ReadAllText($languageServerPath)
$beginMarker = '// ANTIGRAVITY_PROXY_PATCH_BEGIN'
$endMarker = '// ANTIGRAVITY_PROXY_PATCH_END'
$patchPattern = '(?ms)^[ \t]*// ANTIGRAVITY_PROXY_PATCH_BEGIN.*?^[ \t]*// ANTIGRAVITY_PROXY_PATCH_END\r?\n?'
$legacyPatchPattern = '(?ms)^[ \t]*env\[''HTTP_PROXY''\][ \t]*=.*?;\r?\n[ \t]*env\[''HTTPS_PROXY''\][ \t]*=.*?;\r?\n[ \t]*env\[''http_proxy''\][ \t]*=.*?;\r?\n[ \t]*env\[''https_proxy''\][ \t]*=.*?;\r?\n[ \t]*env\[''ALL_PROXY''\][ \t]*=.*?;\r?\n[ \t]*env\[''all_proxy''\][ \t]*=.*?;\r?\n?'
$anchorPattern = '(?m)^(?<line>[ \t]*env\[[''"]AGY_BROWSER_ACTIVE_PORT_FILE[''"]\][ \t]*=.*?;\r?\n)'

$existingPatch = $js -match [regex]::Escape($beginMarker)
$legacyPatch = $js -match $legacyPatchPattern
$hasExpectedProxy = $js -match [regex]::Escape("env['HTTPS_PROXY'] = '$ProxyUrl';")
$hasAnchor = $js -match $anchorPattern

Write-Status "Antigravity：$appExe"
Write-Status "语言服务补丁：$(if ($existingPatch) { '已存在（当前格式）' } elseif ($legacyPatch) { '已存在（旧格式，可自动规范化）' } else { '未安装' })"
Write-Status "目标代理：$ProxyUrl"

if ($Check) {
    if (Test-Path -LiteralPath $configPath) {
        $configText = [System.IO.File]::ReadAllText($configPath)
        $configMatches = $configText -match [regex]::Escape($ProxyUrl)
        Write-Status "图形界面代理配置：$(if ($configMatches) { '包含目标地址' } else { '未包含目标地址' })"
    } else {
        Write-Status '图形界面代理配置：文件不存在'
    }
    if (-not $existingPatch -and -not $hasAnchor) {
        throw '未识别当前语言服务启动结构；未做任何修改。'
    }
    exit 0
}

if (Test-Path -LiteralPath $configPath) {
    $config = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
} else {
    $config = [pscustomobject]@{}
}

if ($null -eq $config.proxy) {
    Add-OrReplaceProperty $config 'proxy' ([pscustomobject]@{})
}
if ($null -eq $config.proxy.upstream_proxy) {
    Add-OrReplaceProperty $config.proxy 'upstream_proxy' ([pscustomobject]@{})
}
Add-OrReplaceProperty $config.proxy.upstream_proxy 'enabled' $true
Add-OrReplaceProperty $config.proxy.upstream_proxy 'url' $ProxyUrl

if (Test-Path -LiteralPath $configPath) {
    Backup-File $configPath
} else {
    New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
}
Write-Utf8NoBom $configPath (($config | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
Write-Status "已写入图形界面代理配置：$configPath"

$proxyBlock = @"
        // ANTIGRAVITY_PROXY_PATCH_BEGIN
        // Scoped to Antigravity's language-server child process only.
        env['HTTP_PROXY'] = '$ProxyUrl';
        env['HTTPS_PROXY'] = '$ProxyUrl';
        env['http_proxy'] = '$ProxyUrl';
        env['https_proxy'] = '$ProxyUrl';
        env['ALL_PROXY'] = '$ProxyUrl';
        env['all_proxy'] = '$ProxyUrl';
        // ANTIGRAVITY_PROXY_PATCH_END
"@

if ($existingPatch) {
    $newJs = [regex]::Replace($js, $patchPattern, $proxyBlock, 1)
} elseif ($legacyPatch) {
    $newJs = [regex]::Replace($js, $legacyPatchPattern, $proxyBlock, 1)
} elseif ($hasAnchor) {
    $newJs = [regex]::Replace($js, $anchorPattern, "`${line}$proxyBlock", 1)
} else {
    throw '未识别当前语言服务启动结构；未修改 languageServer.js。'
}

if ($newJs -ne $js) {
    Backup-File $languageServerPath
    Write-Utf8NoBom $languageServerPath $newJs
    Write-Status "已写入语言服务专用代理：$languageServerPath"
} elseif (-not $hasExpectedProxy) {
    throw '未能写入目标代理地址；已停止。'
} else {
    Write-Status '语言服务已使用目标代理，无需改动。'
}

Write-Status '完成。现在可通过原桌面快捷方式启动 Antigravity。'
