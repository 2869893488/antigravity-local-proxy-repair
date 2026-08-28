# Antigravity Local Proxy Repair

用于在 Windows 上为 Antigravity 恢复本机代理配置的维护工具。适合 Antigravity 更新后，语言服务直连网络失败、启动卡住或无法正常对话的场景。

## 安全边界

本工具只会读取或修改以下 Antigravity 文件，并在修改前分别创建带时间戳的备份：

- `%APPDATA%\Antigravity\gui_config.json`
- `%LOCALAPPDATA%\Programs\antigravity\resources\app\dist\languageServer.js`
- 仅当新版安装包只有 `resources\app.asar` 时：该 ASAR 文件会在验证完整解包后改名为 `app.asar.disabled`，原文件另存为带时间戳的备份。

它不会修改 Windows 系统代理、WinHTTP、用户或系统环境变量、代理客户端配置、其他应用或桌面快捷方式。

语言服务补丁仅对子进程设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 及小写同名变量。启动器模板同样只影响它启动的 Antigravity 进程树。

这是本工具的核心设计：代理配置被注入 Antigravity 的语言服务启动路径，而不是写入 Windows。即使本机代理关闭或端口调整，影响范围也只限 Antigravity；浏览器、终端、游戏和其他软件不会被改变。

## 使用方法

1. 先完全退出 Antigravity。
2. 确认本机代理正在运行，并记下 HTTP 代理地址。例如：`http://127.0.0.1:7890`（请根据实际代理客户端端口填写）。
3. 在本目录打开 PowerShell，执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-AntigravityProxyPatch.ps1 -ProxyUrl 'http://127.0.0.1:7890'
```

`Set-ExecutionPolicy` 只影响当前 PowerShell 进程，关闭窗口后自动失效。

## 更新 Antigravity 后

应用更新通常会覆盖 `languageServer.js`，也可能将解包目录收回为 `resources\app.asar`。更新完成后，重新执行上面的安装命令即可恢复 Antigravity 专用代理补丁。

先用检查模式确认状态：

```powershell
.\Install-AntigravityProxyPatch.ps1 -ProxyUrl 'http://127.0.0.1:7890' -Check
```

脚本只接受包含 `AGY_BROWSER_ACTIVE_PORT_FILE` 的已知启动结构。若新版不再具有该结构，它会退出并提示人工检查，不会写入文件。

当检测到新版 `app.asar` 时，实际安装会临时通过 `ProxyUrl` 调用官方 `@electron/asar` 工具完整解包。脚本会先确认 `dist\languageServer.js` 和 `dist\ideInstall\constants.js` 均存在，再切换 Antigravity 读取解包目录并注入代理。该临时代理环境变量只在该次工具执行期间存在，随后立即恢复。

## 桌面启动器

`Launch-AntigravityWithProxy.vbs` 是可选启动器模板。它不会设置永久环境变量，也不会修改代理设置。若要替换桌面快捷方式的目标，请将快捷方式指向：

```text
wscript.exe "完整路径\Launch-AntigravityWithProxy.vbs"
```

保留快捷方式原有图标即可。

## 回退

每次实际修改都会在原文件旁创建 `.bak-proxy-年月日-时分秒` 备份。需要回退时，先退出 Antigravity，再将对应备份改回原文件名。不要覆盖更新后来自新版本的文件，除非已确认需要恢复到那一版。

## 注意事项

- 此项目不包含 Antigravity 本体、账号信息或代理订阅。
- 本工具不保证特定 Antigravity 版本兼容。升级后请先运行 `-Check`。
- `ProxyUrl` 必须是本机可用的 HTTP 代理地址；端口取决于你自己的代理软件。

