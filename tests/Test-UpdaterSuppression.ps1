# Windows-only smoke test of the generated launchers.
# Fake agy.exe records the updater environment variable: no real CLI installation is touched.
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-AgyProxyPatch.ps1'
$engine = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ("agy-updater-test-$([guid]::NewGuid().ToString('N'))")
$bin = Join-Path $root 'bin'
$exe = Join-Path $bin 'agy.exe'
$config = Join-Path $root 'settings.json'
$shimPs = Join-Path $bin 'agy-proxy.ps1'
$shimCmd = Join-Path $bin 'agy-proxy.cmd'
$takeover = Join-Path $bin 'agy.cmd'
$output = Join-Path $root 'seen.txt'
$before = $env:AGY_CLI_DISABLE_AUTO_UPDATE
$beforeOutput = $env:AGY_TEST_OUTPUT

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
}
function Install-Patch([switch]$Takeover) {
    $parameters = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $installer,
        '-ConfigPath', $config, '-AgyBinDirectory', $bin, '-NoProfileHook', '-ProxyUrl', 'http://127.0.0.1:8123')
    if ($Takeover) { $parameters += '-TakeoverAgy' }
    & $engine @parameters | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) 'installer succeeded'
}
function Run-And-Assert([string]$Launcher, [string]$Expected) {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
    & $Launcher --version
    Assert-True ($LASTEXITCODE -eq 0) "$Launcher exited successfully"
    Assert-True (([System.IO.File]::ReadAllText($output)) -eq $Expected) "$Launcher passed $Expected to child process"
}

try {
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $program = @'
using System;
using System.IO;
public class FakeAgy {
    public static int Main(string[] args) {
        File.WriteAllText(Environment.GetEnvironmentVariable("AGY_TEST_OUTPUT"),
                          Environment.GetEnvironmentVariable("AGY_CLI_DISABLE_AUTO_UPDATE") ?? "<unset>");
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $program -OutputAssembly $exe -OutputType ConsoleApplication
    $env:AGY_TEST_OUTPUT = $output

    Install-Patch
    Assert-True (Test-Path -LiteralPath $shimPs) 'PowerShell shim generated'
    Assert-True (Test-Path -LiteralPath $shimCmd) 'CMD shim generated'

    Remove-Item Env:\AGY_CLI_DISABLE_AUTO_UPDATE -ErrorAction SilentlyContinue
    Run-And-Assert $shimPs 'true'
    Assert-True (-not (Test-Path Env:\AGY_CLI_DISABLE_AUTO_UPDATE)) 'PowerShell environment restored'
    Run-And-Assert $shimCmd 'true'
    Assert-True (-not (Test-Path Env:\AGY_CLI_DISABLE_AUTO_UPDATE)) 'CMD wrapper does not pollute parent'

    $env:AGY_CLI_DISABLE_AUTO_UPDATE = 'false'
    Run-And-Assert $shimPs 'false'
    Run-And-Assert $shimCmd 'false'
    Assert-True ($env:AGY_CLI_DISABLE_AUTO_UPDATE -eq 'false') 'explicit override preserved'

    Remove-Item Env:\AGY_CLI_DISABLE_AUTO_UPDATE -ErrorAction SilentlyContinue
    Install-Patch -Takeover
    Assert-True (Test-Path -LiteralPath (Join-Path $bin 'agy-real.exe')) 'binary takeover'
    Run-And-Assert $takeover 'true'
    $env:AGY_CLI_DISABLE_AUTO_UPDATE = 'false'
    Run-And-Assert $takeover 'false'

    Write-Host 'CLI auto-update environment isolation tests passed.' -ForegroundColor Green
} finally {
    $env:AGY_CLI_DISABLE_AUTO_UPDATE = $before
    $env:AGY_TEST_OUTPUT = $beforeOutput
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
