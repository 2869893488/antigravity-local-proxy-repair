# Antigravity Local Proxy Repair

用于在 Windows 上为 **Antigravity 桌面端** 与 **Antigravity CLI (`agy`)** 恢复与注入本机代理配置的完整维护工具集。

适合应用或 CLI 更新后，网络连接失败、启动卡住、无法登录 Google 账号或无法正常对话的场景。

---

## 核心设计与安全边界

本工具的核心哲学是 **“最小侵入、严格限定进程生命周期、零系统污染”**：

- **零系统污染**：绝不修改 Windows 系统代理（WinINet / PAC），绝不修改系统或用户的全局环境变量，不篡改其他终端或软件。
- **作用域隔离**：
  - **桌面端**：代理配置仅注入 Antigravity 的语言服务（`languageServer`）子进程启动路径中；
  - **CLI 端**：通过专用环境垫片启动器（Process-Scoped Shim），环境变量仅存在于当前会话及派生的进程树（Git, Curl, Python, MCP 等），关闭窗口或会话结束即自动随进程销毁。
- **大小写全覆盖**：同时注入 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 及其对应全部小写变量，彻底解决 Go、Node.js、Python、Curl 等不同运行时对代理环境变量识别规范的不一致。
- **自动安全备份**：任何文件在修改前均会在原目录生成带时间戳的 `.bak-proxy-年月日-时分秒` 备份。

---

## 工具目录与组件

| 文件 | 适用端 | 说明 |
| :--- | :--- | :--- |
| `Install-AntigravityProxyPatch.ps1` | **桌面端** | 自动化打补丁脚本（支持 app.asar 解包降级与正则锚点注入） |
| `Launch-AntigravityWithProxy.vbs` | **桌面端** | 可选的桌面快捷方式静默启动器（无黑框弹窗） |
| `Install-AgyProxyPatch.ps1` | **CLI (`agy`)** | CLI 代理修复与维护脚本（自动探针、settings.json 安全写入、垫片生成） |
| `agy-proxy.cmd` | **CLI (`agy`)** | 通用终端环境隔离启动器（支持 CMD、PowerShell、Git Bash） |
| `agy-proxy.ps1` | **CLI (`agy`)** | PowerShell 原生包装器（基于 `try...finally` 杜绝环境残留） |

---

## 1. Antigravity CLI (`agy`) 修复与使用

### (1) 先用检查模式确认状态 (-Check)
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-AgyProxyPatch.ps1 -Check
```
> **说明**：`-Check` 模式不会修改任何文件。脚本会自动探测本机正在运行的代理客户端端口（如 Clash/V2Ray 常见的 7890、7897、33210、10809 等）并输出诊断报告。

### (2) 应用代理补丁
```powershell
# 如果使用默认/自动检测端口：
.\Install-AgyProxyPatch.ps1

# 或者手动指定你的本地代理地址与端口（以 33210 为例）：
.\Install-AgyProxyPatch.ps1 -ProxyUrl 'http://127.0.0.1:33210'
```

### (3) 原生命令直接调用与代理接管机制
脚本提供两种无感接管模式，使用户无需输入额外前缀，可直接使用原生 `agy` 命令：
* **PowerShell Profile 钩子（默认自动配置）**：
  在用户的 PowerShell Profile 中注入优先级更高的 `agy` 函数。终端中执行 `agy` 命令将直接调用代理包装器，无需修改或重命名本体二进制文件。
* **全终端接管模式（`-TakeoverAgy`）**：
  ```powershell
  .\Install-AgyProxyPatch.ps1 -ProxyUrl 'http://127.0.0.1:33210' -TakeoverAgy
  ```
  借鉴桌面端将 `app.asar` 重命名为 `app.asar.disabled` 的无感降级思想，该模式会将 `agy.exe` 安全备份为 `agy-real.exe` 并部署 `agy.cmd` 命令垫片，实现在 **CMD、PowerShell、Git Bash 等所有终端环境**中直接执行 `agy` 均自动启用代理加速。

### (4) Google 账号身份验证与配置说明
如果 `settings.json` 中配置了 `"modelProvider": "gemini"`，CLI 会强制要求提供独立的开发者 API Key；若需使用个人的 Google 账号授权登录，需移除 `modelProvider`。`Install-AgyProxyPatch.ps1` 在检测到未配置 `GEMINI_API_KEY` 时会**自动完成该项优化**，启动时即可拉起浏览器完成 Google 账号 OAuth 授权流程。

### (5) CLI 卸载与回滚
```powershell
.\Install-AgyProxyPatch.ps1 -Uninstall
```

---

## 2. Antigravity 桌面端修复与使用

### (1) 使用步骤
1. 先完全退出 Antigravity。
2. 确认本机代理正在运行（如 `http://127.0.0.1:7890`）。
3. 打开 PowerShell 执行：
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Install-AntigravityProxyPatch.ps1 -ProxyUrl 'http://127.0.0.1:7890'
   ```

### (2) 检查模式 (-Check)
```powershell
.\Install-AntigravityProxyPatch.ps1 -ProxyUrl 'http://127.0.0.1:7890' -Check
```

### (3) 更新 Antigravity 桌面端后
应用更新通常会覆盖 `languageServer.js` 或重新生成 `resources\app.asar`。当检测到新版 `app.asar` 时，脚本会临时通过 `ProxyUrl` 调用官方 `@electron/asar` 工具完整解包，并验证关键文件无误后，将原包切换为 `app.asar.disabled` 并完成局部代理注入。

### (4) 桌面启动器模板
`Launch-AntigravityWithProxy.vbs` 是可选的静默启动模板。若要替换桌面快捷方式目标，将其指向：
```text
wscript.exe "完整路径\Launch-AntigravityWithProxy.vbs"
```

---

## 回退说明

每次实际修改都会在原文件旁创建 `.bak-proxy-年月日-时分秒` 备份。需要手动回退时，先退出应用，再将对应备份文件改回原名即可。

---

## 注意事项

- 此项目不包含 Antigravity 本体、账号信息或代理订阅。
- `ProxyUrl` 必须是本机可用的 HTTP 代理地址；端口取决于你自己的代理软件（如 Clash Verge、v2rayN、Sing-box 等）。
