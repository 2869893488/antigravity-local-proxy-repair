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

function Expand-AntigravityAsar([string]$AsarPath, [string]$UnpackedAppPath, [string]$ExpectedLanguageServerPath, [string]$ProxyUrl) {
    $disabledAsarPath = "$AsarPath.disabled"
    if (Test-Path -LiteralPath $UnpackedAppPath) {
        throw "发现不完整的解包目录：$UnpackedAppPath。请先人工检查或还原后再执行。"
    }
    if (Test-Path -LiteralPath $disabledAsarPath) {
        throw "已存在禁用的 ASAR 备份：$disabledAsarPath。请先人工检查或还原后再执行。"
    }

    $npm = Get-Command npm -ErrorAction Stop
    $previousHttpProxy = $env:HTTP_PROXY
    $previousHttpsProxy = $env:HTTPS_PROXY
    try {
        # These values exist only while npm fetches/runs the official ASAR tool.
        $env:HTTP_PROXY = $ProxyUrl
        $env:HTTPS_PROXY = $ProxyUrl
        Write-Status '正在使用官方 @electron/asar 完整解包新版应用包...'
        & $npm.Source exec --yes --package '@electron/asar@4.3.0' -- asar extract $AsarPath $UnpackedAppPath
        if ($LASTEXITCODE -ne 0) {
            throw "官方 ASAR 工具退出失败，代码：$LASTEXITCODE"
        }
    } finally {
        $env:HTTP_PROXY = $previousHttpProxy
        $env:HTTPS_PROXY = $previousHttpsProxy
    }

    $constantsPath = Join-Path $UnpackedAppPath 'dist\ideInstall\constants.js'
    if (-not (Test-Path -LiteralPath $ExpectedLanguageServerPath) -or -not (Test-Path -LiteralPath $constantsPath)) {
        throw '官方解包结果缺少关键模块；未切换 Antigravity 读取解包目录。'
    }

    Backup-File $AsarPath
    Move-Item -LiteralPath $AsarPath -Destination $disabledAsarPath -ErrorAction Stop
    Write-Status "已切换到经验证的完整解包目录：$UnpackedAppPath"
}

$appExe = Join-Path $InstallDirectory 'Antigravity.exe'
$resourcesDirectory = Join-Path $InstallDirectory 'resources'
$unpackedAppPath = Join-Path $resourcesDirectory 'app'
$asarPath = Join-Path $resourcesDirectory 'app.asar'
$languageServerPath = Join-Path $unpackedAppPath 'dist\languageServer.js'
$configPath = Join-Path $env:APPDATA 'Antigravity\gui_config.json'

if (-not (Test-Path -LiteralPath $appExe)) {
    throw "未找到 Antigravity.exe：$appExe"
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

if (-not (Test-Path -LiteralPath $languageServerPath)) {
    if ($Check -and (Test-Path -LiteralPath $asarPath)) {
        Write-Status '检测到新版 app.asar；实际安装时将使用官方 ASAR 工具完整解包后再修补。'
        exit 0
    }
    if (-not (Test-Path -LiteralPath $asarPath)) {
        throw "未找到语言服务启动文件或 app.asar：$languageServerPath"
    }
    Expand-AntigravityAsar $asarPath $unpackedAppPath $languageServerPath $ProxyUrl
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
