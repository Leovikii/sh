# CachyOS 工具

KDE 美化、字体、Proton / Steam 手柄设置和登录界面单屏配置已迁至独立仓库 [CachyOS Setup](https://github.com/Leovikii/cachyos-setup)，使用方法见其 README。本仓库已移除对应旧脚本、测试和资源。

本目录保留尚未迁移的工具：

- [`wakeup_setup.sh`](./wakeup_setup.sh)：USB / ACPI 唤醒与网络唤醒（WOL）管理，需要 root 权限，会修改系统 udev 规则和 systemd 服务。
- [`font_test.html`](./font_test.html)：用浏览器打开，比较本机已安装字体的字形与渲染效果；不依赖初始化脚本。
