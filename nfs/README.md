# 局域网 NFS 挂载

Linux 交互菜单：挂载、卸载、查看、开机自动连接开关。输入服务器 IPv4、共享路径和本地目录（默认 `/mnt/nfs`），支持路径中的空格和中文。

```bash
sudo bash nfs/mount.sh
```

先安装客户端：Debian/Ubuntu 用 `sudo apt install nfs-common`，Arch/CachyOS 用 `sudo pacman -S nfs-utils`，Fedora 用 `sudo dnf install nfs-utils`。

NFS 无需输入用户名或密码；服务端须允许本机 IP，文件权限由服务端的 UID/GID 和导出规则决定。此脚本用于常见的 `sec=sys` 共享，不配置 Kerberos 认证。

挂载时默认开启「开机自动连接」，输入 `n` 可关闭；挂载后也可通过菜单 **4** 切换。需要 systemd，配置保存到 `/etc/fstab`，下次开机建立自动挂载入口，访问目录时连接服务器。使用 `_netdev,nofail,x-systemd.automount` 避免等待 NFS 挂载拖慢开机，连接超时为 15 秒。关闭开关后，下次开机不再建立入口，当前挂载及已运行的自动挂载入口保留至卸载或重启。

脚本只修改带 `#nfs-mount.sh` 标记的条目，同一目录已有手动配置时拒绝接管。每次修改前将原文件备份到 `/etc/fstab.nfs.bak`，刷新 systemd 失败则还原。重复开启不会产生重复条目。

挂载默认读写、自动协商 NFS 版本，启用 `hard,nosuid,nodev`。服务端离线时，正在访问共享的程序可能等待恢复，15 秒超时只针对建立连接。只接受空目录，不覆盖已有挂载；卸载不强制操作，保留本地目录。菜单 **2** 仅卸载当前共享，开机自动连接设置保留，可用菜单 **4** 关闭。

测试（模拟挂载，不需要 root 或 NFS 服务器）：

```bash
bash nfs/tests/mount-test.sh
```
