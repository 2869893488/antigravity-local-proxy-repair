<#
.SYNOPSIS
    Antigravity CLI PowerShell 局部代理包装器
.DESCRIPTION
    利用 try...finally 结构保证仅在当前会话运行 agy 时注入代理环境，
    即使发生异常或 Ctrl+C 中断，外部 PowerShell 环境也不会被污染。
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$targetProxy = if ($env:AGY_PROXY_URL) { $env:AGY_PROXY_URL } else { 'http://127.0.0.1:7890' }

$oldHttpProxy       = $env:HTTP_PROXY
$oldHttpsProxy      = $env:HTTPS_PROXY
$oldHttpProxyLower  = $env:http_proxy
$oldHttpsProxyLower = $env:https_proxy
$oldAllProxy        = $env:ALL_PROXY
$oldAllProxyLower   = $env:all_proxy
$oldNoProxy         = $env:NO_PROXY

try {
    $env:HTTP_PROXY  = $targetProxy
    $env:HTTPS_PROXY = $targetProxy
    $env:http_proxy  = $targetProxy
    $env:https_proxy = $targetProxy
    $env:ALL_PROXY   = $targetProxy
    $env:all_proxy   = $targetProxy
    $env:NO_PROXY    = 'localhost,127.0.0.1,::1,*.local'

    $targetRealExe = Join-Path $PSScriptRoot 'agy-real.exe'
    $targetExe     = Join-Path $PSScriptRoot 'agy.exe'
    if (Test-Path -LiteralPath $targetRealExe) {
        & $targetRealExe @RemainingArgs
    } elseif (Test-Path -LiteralPath $targetExe) {
        & $targetExe @RemainingArgs
    } else {
        & agy @RemainingArgs
    }
} finally {
    $env:HTTP_PROXY  = $oldHttpProxy
    $env:HTTPS_PROXY = $oldHttpsProxy
    $env:http_proxy  = $oldHttpProxyLower
    $env:https_proxy = $oldHttpsProxyLower
    $env:ALL_PROXY   = $oldAllProxy
    $env:all_proxy   = $oldAllProxyLower
    $env:NO_PROXY    = $oldNoProxy
}
