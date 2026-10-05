# rclone 磁盘管理

适用于 Windows 10/11，支持 Windows PowerShell 5.1 和 PowerShell 7。提供远端配置、磁盘挂载、登录自启，以及通过 winget 安装和卸载 rclone、WinFsp。Linux 暂不支持。

## 使用

下载本目录，在普通权限 PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\RcloneDriveManager.ps1
```

首次使用：**9 安装组件 → 1 配置远端 → 2 挂载设置 → 3 挂载**。已有远端可跳过配置步骤。缺少 winget 时，从 Microsoft Store 安装或更新“应用安装程序”。安装组件可能弹出 UAC。

| 菜单 | 功能 |
| --- | --- |
| 1 / 2 | 配置远端 / 保存挂载设置 |
| 3 / 4 / 5 | 挂载 / 安全卸载 / 查看状态 |
| 6 / 7 | 开启 / 关闭登录自启 |
| 8 | 删除挂载设置，保留远端、缓存和日志 |
| 9 | 安装、查询或卸载 rclone 和 WinFsp |
| 0 | 退出界面，保留正在运行的挂载 |

挂载支持 D–Z 盘符、远端子目录、网络/固定磁盘、缓存、只读和自定义显示容量。默认使用网络驱动器、full 缓存、20G 缓存清理目标；容量显示不改变服务端配额，剩余量可能不准确。

## 注意事项

- 安全卸载前关闭文件并等待上传完成；有未完成上传或状态不明时会拒绝卸载。不要删除待上传缓存。
- 卸载组件前先关闭登录自启、安全卸载磁盘并退出所有 rclone 实例；卸载 WinFsp 还需关闭其他依赖它的应用。
- 登录自启使用无窗口计划任务，登录约 20 秒后挂载。升级脚本后重新选择 **6 开启自启**，更新后台脚本副本。
- 配置、缓存和日志保存在 `%LOCALAPPDATA%\RcloneDriveManager`。组件卸载保留这些文件；便携版由原安装方式管理。
- 本脚本的挂载通过菜单管理，独立启动的 rclone GUI 不会自动显示它们。

## 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-RcloneDriveManager.ps1
```

加 `-Integration` 可验证本机控制接口和隐藏启动器。真实挂载、组件安装/卸载和重启恢复需手动验收。

脚本沿用仓库的 GPL-3.0 许可证；rclone 和 WinFsp 使用各自许可证。
