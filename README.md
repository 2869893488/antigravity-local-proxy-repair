# Antigravity Local Proxy Repair

在 Windows 上为 **Antigravity 桌面端** 与 **Antigravity CLI (`agy`)** 配置本机代理的维护工具。

仅对 Antigravity 进程注入局部代理，**不修改** Windows 系统代理，**不修改**系统或用户全局环境变量。修改前均自动创建时间戳备份。

---

## 1. 命令行端 (`agy`)

在 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
# 自动检测本地活动代理并配置：
.\Install-AgyProxyPatch.ps1

# 或手动指定代理端口（以 33210 为例）：
.\Install-AgyProxyPatch.ps1 -ProxyUrl 'http://127.0.0.1:33210'
```

* **直接运行**：安装后在终端直接输入 `agy` 即可使用代理。若需 CMD、Git Bash 等所有终端都能直接生效，追加 `-TakeoverAgy`。
* **Google 账号登录**：脚本会自动处理配置，启动后直接拉起浏览器完成授权。
* **检查状态**：`.\Install-AgyProxyPatch.ps1 -Check`
* **还原卸载**：`.\Install-AgyProxyPatch.ps1 -Uninstall`
* **安全卸载**：新版安装会保留首次安装前的 `proxyServerURL` 和 `modelProvider` 字段状态。卸载时会恢复原值，而不是直接删除；若安装后用户手动修改过配置，会保留当前值并提示核对。
* **旧版安装注意**：旧版未记录安装前的字段原值，无法安全自动恢复。此时卸载器不会擅自修改 `settings.json`，可根据 `.bak-proxy-*` 备份手工还原。

---

## 2. 桌面端应用

1. 完全退出 Antigravity。
2. 在 PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-AntigravityProxyPatch.ps1 -ProxyUrl 'http://127.0.0.1:7890'
```

* **检查状态**：`.\Install-AntigravityProxyPatch.ps1 -Check`
* **更新兼容**：新版重新打包为 `app.asar` 时，脚本会自动解包并完成注入。
* **快捷方式启动器（可选）**：可将桌面快捷方式指向 `wscript.exe "路径\Launch-AntigravityWithProxy.vbs"` 实现无黑框启动。

---

## 回退

修改前会在原文件旁生成 `.bak-proxy-年月日-时分秒` 备份。新版 CLI 安装器还会在 `settings.json` 旁创建 `settings.json.agy-proxy-state.json`，用于记录**首次安装前**的字段值。重复安装不会覆盖初始记录；卸载完成后自动清理。若发现冲突，会保留这份记录，供人工核对。

桌面端脚本目前没有自动卸载命令；桌面端修改仍需根据备份手工恢复。
