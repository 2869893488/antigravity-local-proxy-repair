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

修改前均会在原文件旁生成 `.bak-proxy-年月日-时分秒` 备份文件，恢复时改回原文件名即可。
