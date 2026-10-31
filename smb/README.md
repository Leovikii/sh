# 局域网 SMB 挂载

Linux / systemd 交互菜单：挂载或重连、卸载、查看状态、开机按需连接开关。提供普通本地路径，适合 Dolphin 和播放器访问 NAS。

先安装 `cifs-utils`：Arch/CachyOS 用 `sudo pacman -S cifs-utils`，Debian/Ubuntu 用 `sudo apt install cifs-utils`，Fedora 用 `sudo dnf install cifs-utils`。

```bash
sudo bash smb/mount.sh
```

菜单 **1** 依次输入：

- 本地完整挂载点，例如 `/mnt/omv`；默认 `/mnt/smb`。目录须为空，已有目录须由 root 拥有，不能经过符号链接。
- 服务器 IPv4，例如 `10.9.6.2`。
- **SMB 共享名**，例如 `OMV`；这是 OMV 的 SMB/CIFS 共享名称，不是 NFS 路径 `/export/OMV`。
- OMV 用户名、隐藏输入的密码；域 / 工作组通常留空。
- 本机访问用户，例如 `viki`；通过 sudo 运行时默认使用当前用户。
- 读写或只读、是否开机按需连接，最后确认保存并连接。

OMV 须先启用 **服务 → SMB/CIFS**，添加共享，并给账号分配共享权限和文件系统访问权限。仅启用 NFS 不够。

凭据保存于 `/etc/smb-mount.credentials/`：目录权限 `700`，文件权限 `600`，由 root 持有。密码不会写入命令参数、菜单输出或 fstab；凭据文件本身为明文，仅限 root 读取。重启后无需重新输入密码。已有配置时菜单 **1** 可选择直接重连或重新配置；更换账号或共享前须先用菜单 **2** 卸载。旧凭据文件保留，便于配合 fstab 备份恢复，管理员确认不再被配置或备份引用后可删除。

开启自动连接：下次开机只建立按需入口，访问时连接，空闲 60 秒后尝试卸载；被程序占用时可能无法卸载。关闭自动连接：保留凭据和 `noauto` 配置，下次开机不自动建立入口，可用菜单 **1** 手动连接。菜单 **4** 的修改下次开机生效；若要立即应用，先用菜单 **2** 卸载，再用菜单 **1** 连接。

首次保存会立即连接。连接失败时保留配置和凭据，修正服务端后可从菜单 **1** 重试；若开启了自动连接，系统仍可在后续目录访问或下次开机时尝试连接。卸载会停止当前按需入口，保留开机设置；脚本不强制或延迟卸载。

采用内核 CIFS、`vers=3`（协商 SMB 3.x）、`soft,echo_interval=5,nosuid,nodev`，连接由 systemd 管理。15 秒挂载超时仅限制建立连接，不是文件读写的总时限，无法保证服务器断线时 Dolphin 立即响应。断线可能导致读写失败，重要写入请确认结果。

未挂载时将空挂载点设为 `0555`，防止普通用户误写到本机；root 仍能写入。挂载后使用指定用户 UID/GID 和 `file_mode=0664,dir_mode=0775`，服务端权限仍然有效，协商出的 Unix/POSIX 权限也可能影响实际访问。

只维护带 `#smb-mount.sh` 标记的 fstab 条目，不接管旧 NFS、手动配置或已有挂载。修改前备份到 `/etc/fstab.smb.bak`，刷新 systemd 失败或超时会尝试还原。不会自动移除 NFS 挂载或更改 Dolphin。

测试（模拟 systemd，不连接服务器）：

```bash
bash smb/tests/mount-test.sh
```
