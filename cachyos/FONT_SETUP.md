# 更纱字体设置

面向 CachyOS / Arch、KDE Wayland。默认配置适合从 4K / 150% 缩放开始比较：

| 用途 | 字体与设置 |
| --- | --- |
| 中英文界面 | Sarasa UI SC，11pt |
| 终端、代码 | Sarasa Term SC |
| 衬线正文 | Noto Serif CJK SC |
| Emoji | Noto Color Emoji |
| 渲染 | 灰度抗锯齿、轻微 hinting |

更纱 UI 的英文基于 Inter，Term 的英文基于 Iosevka；保留这套搭配即可兼顾英文界面和代码。UI 使用较窄的引号，Term 使用半宽破折号；不喜欢连字时可在编辑器里关闭，或自行选择 Sarasa Fixed SC。

## 使用

以桌面普通用户运行，不要 sudo 整个脚本。无参数时进入菜单：

```bash
bash cachyos/font_setup.sh --diagnose
bash cachyos/font_setup.sh --print-config
bash cachyos/font_setup.sh --apply
```

缺字体时执行 `bash cachyos/font_setup.sh --install`。字体来自官方仓库，无需 AUR 助手；更纱完整包约 818 MiB。**安装操作使用 `sudo pacman -Syu --needed ...`，包含系统升级**，pacman 会列出清单并询问确认。Arch 不支持刷新仓库后仅升级个别包。

字体已通过其他方式安装到当前用户目录时，也可以直接应用。脚本使用 `fc-list` 检查真实字体，不依赖 pacman 安装记录。

```bash
# 比较字号；rgba 可选 none、rgb、bgr、vrgb、vbgr
bash cachyos/font_setup.sh --apply --size 10 --rgba none
```

`none` 只关闭次像素彩色渲染，抗锯齿仍开启。确认显示器的次像素排列后再试 RGB/BGR，出现彩边就用 `none`。保持日常 150% 缩放，不额外叠加字体 DPI 或缩放环境变量。

应用后注销重登，再打开 [字体对比页](./font_test.html)，浏览器页面缩放保持 100%。测试页上的 Noto 和文泉驿只作对比；未安装的字体会回退，可用浏览器开发者工具检查实际渲染字体。仅部分应用整体发糊时，检查是否经 XWayland 缩放；浏览器、GTK、终端和编辑器的显式字体仍需在应用内设置。

## 备份与恢复

写入 `${XDG_CONFIG_HOME:-~/.config}/fontconfig/conf.d/60-cachyos-fonts.conf`，KDE 下同步 `kdeglobals`。保留已有 `fonts.conf`；若旧脚本曾生成强制字体替换，请自行备份并移出加载路径，以免规则冲突。`kdeglobals` 是符号链接时，脚本退出，请通过原 dotfiles 工具修改。

应用前将这两个文件备份到 `${XDG_STATE_HOME:-~/.local/state}/cachyos-fonts/backups/`，恢复最近一次应用前的快照：

```bash
bash cachyos/font_setup.sh --restore
```

**恢复包括整个 `kdeglobals`**，应用后另行修改的 KDE 主题等设置也会回退。历史备份保留；应用中途失败后也可恢复。

## 验证与依据

```bash
bash -n cachyos/font_setup.sh
python3 -B -m unittest discover -s cachyos/tests -v
```

测试使用临时 HOME，覆盖中英文和地区字形匹配、Emoji、显式字体、备份恢复及失败退出，不修改桌面或安装软件。需要更纱、Noto CJK/Emoji 和 KDE 配置工具的测试在缺依赖时跳过。

本次优化保留更纱，修复强制 RGB、覆盖配置、影响 Emoji 的位图设置、无效 KDE 键及失败后报告成功的问题。2026-10-25 核对资料：

- [更纱官方说明](https://github.com/be5invis/Sarasa-Gothic#what-are-the-names)与 [Arch 官方字体包](https://archlinux.org/packages/extra/any/ttf-sarasa-gothic/)。
- [Arch Wiki 字体配置](https://wiki.archlinux.org/title/Font_configuration)：次像素、hinting、Emoji 与 GTK4。
- [KDE 字体设置源码](https://github.com/KDE/plasma-workspace/blob/master/kcms/fonts/fontsaasettings.cpp)：使用 `XftAntialias`、`XftHintStyle`、`XftSubPixel`。
- [fontconfig 度量兼容别名](https://github.com/fontconfig/fontconfig/blob/main/conf.d/30-metric-aliases.conf)：保留 Arial 等现有兼容替换。
