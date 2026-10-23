# Windows PowerShell / PowerShell 7 integration smoke tests.
# All installation paths are redirected into a disposable temp folder.
# Run from the repository root:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UninstallRestore.ps1

$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-AgyProxyPatch.ps1'
$engine = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ("agy-uninstall-test-$([guid]::NewGuid().ToString('N'))")
$bin = Join-Path $root 'bin'
$configPath = Join-Path $root 'settings.json'
$statePath = "$configPath.agy-proxy-state.json"

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
}

function Invoke-Patch([string]$Proxy, [switch]$Uninstall) {
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $installer,
        '-ConfigPath', $configPath,
        '-AgyBinDirectory', $bin,
        '-NoProfileHook', '-NoShim'
    )
    if ($Uninstall) {
        $arguments += '-Uninstall'
    } else {
        $arguments += @('-ProxyUrl', $Proxy)
    }
    & $engine @arguments | Out-Host
    return $LASTEXITCODE
}

function Read-Config {
    return ([System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json)
}

function Save-Config($Config) {
    [System.IO.File]::WriteAllText(
        $configPath,
        (($Config | ConvertTo-Json -Depth 30) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
}

try {
    New-Item -ItemType Directory -Path $bin -Force | Out-Null

    # Fresh install and repeat install must preserve the first original state.
    $original = [pscustomobject]@{
        proxyServerURL = 'http://127.0.0.1:8111'
        modelProvider  = 'original-provider'
        untouched      = 'keep-me'
    }
    Save-Config $original
    Assert-True ((Invoke-Patch 'http://127.0.0.1:8121') -eq 0) 'initial installation'
    Assert-True ((Invoke-Patch 'http://127.0.0.1:8122') -eq 0) 'reinstallation'
    $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($state.originalProxy.value -eq 'http://127.0.0.1:8111') 'original proxy retained'
    Assert-True ($state.originalModelProvider.value -eq 'original-provider') 'original provider retained'

    # A user's later edit must be preserved even while an unrelated field is restored.
    $edited = Read-Config
    $edited.proxyServerURL = 'http://127.0.0.1:8999'
    Save-Config $edited
    Assert-True ((Invoke-Patch -Uninstall) -eq 1) 'conflicting edit signals incomplete restoration'
    $afterConflict = Read-Config
    Assert-True ($afterConflict.proxyServerURL -eq 'http://127.0.0.1:8999') 'manual proxy preserved'
    Assert-True ($afterConflict.modelProvider -eq 'original-provider') 'original provider restored'
    Assert-True (Test-Path -LiteralPath $statePath) 'state retained for retry'

    # Retrying after removing the conflict must be idempotent.
    $afterConflict.proxyServerURL = 'http://127.0.0.1:8122'
    Save-Config $afterConflict
    Assert-True ((Invoke-Patch -Uninstall) -eq 0) 'retry uninstall'
    $restored = Read-Config
    Assert-True ($restored.proxyServerURL -eq 'http://127.0.0.1:8111') 'original proxy restored'
    Assert-True ($restored.modelProvider -eq 'original-provider') 'original provider still present'
    Assert-True ($restored.untouched -eq 'keep-me') 'unrelated field intact'
    Assert-True (-not (Test-Path -LiteralPath $statePath)) 'state removed on success'

    # A config created by this installer should be removed if still otherwise empty.
    Remove-Item -LiteralPath $configPath -Force
    Assert-True ((Invoke-Patch 'http://127.0.0.1:8123') -eq 0) 'fresh empty config'
    Assert-True ((Invoke-Patch -Uninstall) -eq 0) 'remove generated config'
    Assert-True (-not (Test-Path -LiteralPath $configPath)) 'generated settings removed'
    Assert-True (-not (Test-Path -LiteralPath $statePath)) 'generated state removed'

    # Legacy installations without a state file must NOT lose user settings.
    Save-Config $original
    Assert-True ((Invoke-Patch -Uninstall) -eq 1) 'legacy uninstall warns'
    $legacy = Read-Config
    Assert-True ($legacy.proxyServerURL -eq 'http://127.0.0.1:8111') 'legacy proxy preserved'
    Assert-True ($legacy.modelProvider -eq 'original-provider') 'legacy provider preserved'

    # An unrelated agy.cmd is not owned by the installer and must survive uninstall.
    $foreignCmd = Join-Path $bin 'agy.cmd'
    [System.IO.File]::WriteAllText($foreignCmd, '@echo off' + [Environment]::NewLine)
    $null = Invoke-Patch -Uninstall
    Assert-True ((Test-Path -LiteralPath $foreignCmd)) 'foreign launcher remains'
    Assert-True (([System.IO.File]::ReadAllText($foreignCmd)) -match '@echo off') 'foreign launcher content remains'

    Write-Host 'All uninstall restoration smoke tests passed.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
