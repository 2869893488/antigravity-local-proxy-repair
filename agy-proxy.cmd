@echo off
rem ====================================================================
rem Antigravity CLI Process-Scoped Proxy Launcher
rem 作用域严格限定在当前进程及其衍生的子进程树（Git, Curl, MCP, Python等）
rem 不修改 Windows 系统代理，不修改系统/用户环境变量
rem ====================================================================
setlocal

rem 默认代理端口，可通过 Install-AgyProxyPatch.ps1 自定义或在此修改
set "DEFAULT_PROXY=http://127.0.0.1:7890"

if "%AGY_PROXY_URL%"=="" (
    set "TARGET_PROXY=%DEFAULT_PROXY%"
) else (
    set "TARGET_PROXY=%AGY_PROXY_URL%"
)

rem 同时注入大写、小写和 ALL_PROXY，满足 Go, Node, Python, C-Curl 各自运行时的兼容性
set "HTTP_PROXY=%TARGET_PROXY%"
set "HTTPS_PROXY=%TARGET_PROXY%"
set "http_proxy=%TARGET_PROXY%"
set "https_proxy=%TARGET_PROXY%"
set "ALL_PROXY=%TARGET_PROXY%"
set "all_proxy=%TARGET_PROXY%"
set "NO_PROXY=localhost,127.0.0.1,::1"

if exist "%~dp0agy-real.exe" (
    "%~dp0agy-real.exe" %*
) else if exist "%~dp0agy.exe" (
    "%~dp0agy.exe" %*
) else (
    agy %*
)

set "EXITCODE=%ERRORLEVEL%"
endlocal & exit /b %EXITCODE%
