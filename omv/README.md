# OpenMediaVault 工具

## `subtitle-sync.sh`

### 功能

管理 FFsubsync 组件，选择一组视频与字幕进行调轴。自动列出视频同目录的 SRT / ASS 字幕，也可手动输入路径；结果按视频文件名保存，已有字幕须确认备份后替换。

### 下载

```sh
wget -O subtitle-sync.sh https://raw.githubusercontent.com/Leovikii/sh/main/omv/subtitle-sync.sh
```

中国大陆网络可使用 CDN 加速：

```sh
wget -O subtitle-sync.sh https://cdn.jsdelivr.net/gh/Leovikii/sh@main/omv/subtitle-sync.sh
```

### 运行

```sh
bash subtitle-sync.sh
```

首次进入「组件管理 → 安装 / 修复组件」，再选择「开始调轴」。安装后可直接运行 `subtitle-sync`；组件管理需要管理员权限，调轴使用当前用户权限。

路径须为 NAS 上的文件路径，支持 Tab 补全。输出示例：`Episode01.mkv` + `中文字幕.srt` → `Episode01.srt`，保留源字幕。
