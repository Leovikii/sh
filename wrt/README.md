# OpenWrt 工具

## `overlay.sh`

### 功能

自动识别 OpenWrt 25.12+ 的根磁盘、rootfs 分区及 overlay 文件系统，完成只读诊断、依赖安装、分区扩展和 ext2/ext3/ext4/f2fs 在线扩容。

### 下载

```sh
wget -O overlay.sh https://raw.githubusercontent.com/Leovikii/sh/main/wrt/overlay.sh
```

中国大陆网络可使用 CDN 加速：

```sh
wget -O overlay.sh https://cdn.jsdelivr.net/gh/Leovikii/sh@main/wrt/overlay.sh
```

### 运行

```sh
chmod +x overlay.sh && ./overlay.sh
```

## `eximg.sh`

### 功能

在 Debian/Ubuntu 环境中复制或解压 OpenWrt 镜像，扩展镜像容量，修复 GPT 备份分区表并将第二分区扩展到镜像末尾。

### 下载

```sh
wget -O eximg.sh https://raw.githubusercontent.com/Leovikii/sh/main/wrt/eximg.sh
```

### 运行

```sh
chmod +x eximg.sh && sudo ./eximg.sh <镜像文件> <目标容量GB>
```
