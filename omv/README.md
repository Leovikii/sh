# OpenMediaVault 工具

## `subtitle-sync.sh` · v1.0.0

### 功能

管理 FFsubsync 组件，选择一组视频与字幕进行调轴。自动列出视频同目录的 SRT / ASS 字幕，也可手动输入路径；结果按视频文件名保存，已有字幕确认后覆盖，不生成备份，临时文件自动清理。

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

首次运行自动安装 `subsync` 快捷命令（需要管理员权限）。进入「组件管理 → 安装 / 修复组件」后即可调轴，以后直接运行 `subsync`。

路径须为 NAS 上的文件路径，支持 Tab 补全。输出示例：`Episode01.mkv` + `中文字幕.srt` → `Episode01.srt`，保留源字幕。

「脚本管理」提供仓库版本检查、自更新和脚本卸载；更新后重新启动。`subsync version` 查看版本。卸载脚本只删除快捷命令，组件在「组件管理」中另行卸载。
