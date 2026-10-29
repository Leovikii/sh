# KDE 方案 A

`kde_setup.sh` 面向 CachyOS/Arch 的 **Plasma 6 Wayland** 会话，采用以下组合：

| 部件 | 选择 | 应用范围 |
| --- | --- | --- |
| 应用样式 | Breeze | 原生 Qt Widgets 样式 |
| Plasma 样式 | Breeze（`default`） | 由桌面配色提供颜色 |
| 窗口装饰 | Klassy（`org.kde.klassy`） | 仅使用原生 C++ 窗口装饰插件 |
| 配色 | Catppuccin Mocha Pink | 深色背景、官方粉色强调色 `#F5C2E7` |
| 图标 | Papirus-Dark | 使用已有主题或包管理器安装 |
| 光标 | Bibata Modern Ice | 保留当前光标尺寸 |

不调用全局主题安装器、`lookandfeeltool` 或布局脚本，不重建面板，不添加第三方 QML 布局。安装 Klassy 包会附带它的应用样式等资源，完整方案仍选择 Breeze 应用样式；单独选择 Klassy 时只改窗口装饰。Breeze 自带的原生 QML 桌面组件照常使用。

脚本不设置 Qt 渲染环境变量，不修改 KWin 合成器、HDR、VRR、缩放、字体、壁纸、GTK 或登录界面，也不自动禁用用户已有的扩展。原生插件仍需与当前 KWin/KDecoration 版本兼容；这套组合不能保证第三方插件与 Breeze 完全相同的性能或兼容性。

## 使用

在仓库根目录以普通用户执行，不要对整个脚本使用 `sudo`：

```bash
# 打开交互菜单
bash cachyos/kde_setup.sh

# 一键安装并应用完整方案
bash cachyos/kde_setup.sh --setup

# 也可只安装并应用指定组件（可空格分隔多个）
bash cachyos/kde_setup.sh --setup colors papirus

# 已应用旧版 Lavender 时，只更新为 Pink，保留其它组件设置
bash cachyos/kde_setup.sh --setup colors

# 只读诊断
bash cachyos/kde_setup.sh --diagnose

# 只安装缺少的组件，不改变当前外观
bash cachyos/kde_setup.sh --install

# 在 Plasma 6 Wayland 的终端中应用
bash cachyos/kde_setup.sh --apply

# 有需要时恢复应用前的配置，然后注销重登
bash cachyos/kde_setup.sh --restore
```

主菜单只保留一键安装并应用、选择组件安装并应用、查看当前状态、恢复上次配置和退出。组件页显示“已安装 / 待安装”，输入 `2 3 4` 即可多选，输入 `0` 返回；安装并应用完成后退出。查看菜单本身不安装软件或写入主题配置。

| 编号 | 命令行组件名 | 修改范围 |
| --- | --- | --- |
| 1 | `breeze` | 应用与 Plasma 桌面样式 |
| 2 | `klassy` | 窗口装饰 |
| 3 | `colors` | Catppuccin Mocha 配色及强调色 |
| 4 | `papirus` | 图标 |
| 5 | `bibata` | 光标，保留尺寸 |

`--setup`、`--install`、`--apply` 和 `--diagnose` 都接受上述组件名；省略时选择全部。手动指定时仅检查、安装并应用所选组件，未选组件缺失不会阻止操作。包管理器仍可能安装依赖及进行完整系统升级。只有选择 `colors` 时才重置强调色，只有选择 `breeze` 时才切换应用与桌面样式。

`--setup` 在安装前先检查 Plasma 6 Wayland 会话、KWin 可访问性和配置文件；安装失败时不继续应用。`--apply` 在所选组件可用、配置文件检查通过且 KWin 会话可访问后才备份并写入。它使用 KDE 官方工具应用配色、Plasma 样式和光标，通过 KConfig 写入其余配置，并请求 KWin 重新读取设置。不会自动重启 Plasma 或 KWin。建议应用后注销重登，让已运行的应用完整同步图标、样式和光标；应用自行绘制的标题栏也不一定受 Klassy 控制。

## 检测与重复运行

**每次运行都检测目标系统当时的实际状态，不保存本机检测结果，也不硬编码任何组件为“已安装”。** 在全新系统上，缺什么就安装什么；系统预装的部件跳过。安装完成后再次运行，才会跳过已齐全的部件。本机核对记录仅供参考，不参与脚本判断。

- 按 Qt 6 插件路径及 XDG 数据目录检测实际文件，不仅查询包名；也检测传统 `~/.icons` 下的 Bibata。
- 以原生 Breeze 窗口装饰所在目录判断 KDecoration2/3 ABI；旧 ABI 下的 Klassy 不视为当前可用组件。配置组仍然叫 `org.kde.kdecoration2`，新版 KWin 也沿用此名称。
- 已有组件跳过安装。所有组件齐全时，`--install` 不调用包管理器；已有同名 Catppuccin 配色也保留原文件。
- 已符合目标的配置跳过写入；全部符合时不备份、不调用应用工具，也不发送 KWin 重配置请求。
- 为保持 Mocha 原配色，应用时会关闭壁纸强调色，将自定义强调色设为透明（使用配色自身的颜色）。已有字体和光标尺寸保留。

当前默认配色是官方 **Mocha Pink**，强调色为 `#F5C2E7`。从旧版 Lavender 更新时，运行 `--setup colors` 会检测并补齐 Pink 文件，再切换配色；已有 Lavender 资源保留，不会被当成 Pink 而跳过。Pink 已安装但尚未选中时，只应用配色；重复运行后配置已符合目标就跳过写入。

如果包管理器显示包已安装，但所需文件缺失或 Klassy 仅在旧 ABI 目录中，脚本会停止并提示检查完整性或重编译，避免重复安装掩盖问题。插件文件目录匹配仍不能代替实际加载验证；滚动升级后有装饰异常时，应检查 Klassy 上游与本机 KDecoration 版本。

## 安装来源

先查当前 pacman 仓库中的 `breeze`、`papirus-icon-theme`、`klassy`、`bibata-cursor-theme`；后两个不存在于仓库时，分别使用 AUR 的 `klassy`、`bibata-cursor-theme-bin`。脚本只使用本机已有的 `paru` 或 `yay`，保留包清单、PKGBUILD 审阅和安装确认，不自动安装 helper，不直接运行网络下载的 Shell 安装器。

**需要安装缺失包时，使用 `pacman -Syu --needed` 或 helper 的 `-Syu --needed`，可能包含完整系统/AUR 升级。** 这是为了遵循 Arch 不支持局部升级的要求；即使只缺少一个部件，也应检查包管理器展示的升级清单。若包管理器失败，脚本会停止，不继续应用主题。

配色直接使用仓库附带的纯数据文件：

- [CatppuccinMochaPink.colors](./kde/CatppuccinMochaPink.colors)
- 上游：[catppuccin/kde](https://github.com/catppuccin/kde)，固定提交 `6606b5179cfc1e9ba5c3b6b70e15c468e2dddca2`，路径 `generated/color-schemes/CatppuccinMochaPink.colors`。
- 许可证：[MIT](./kde/LICENSE.catppuccin)。仅在缺少同名配色时复制到 `${XDG_DATA_HOME:-~/.local/share}/color-schemes/`。
- 原生装饰：[Klassy](https://github.com/paulmcauley/klassy)；光标：[Bibata](https://github.com/ful1e5/Bibata_Cursor)；图标：[Papirus](https://github.com/PapirusDevelopmentTeam/papirus-icon-theme)。

## 备份与恢复

备份位于 `${XDG_STATE_HOME:-~/.local/state}/cachyos-kde/backups/`，`latest` 指向最近一次需要改动配置的应用快照，包含：

```text
kdeglobals
plasmarc
kcminputrc
kwinrc
```

**`--restore` 恢复四个完整文件，会覆盖应用之后对这些文件做的其它修改。** 应用前不存在的文件，恢复时会删除。恢复不卸载组件、不删除配色资源；恢复后注销重登。即使不在图形会话中，也可从普通用户的 TTY 运行恢复。脚本拒绝覆盖上述配置文件或配置根目录的符号链接，dotfiles 用户请通过自己的管理工具应用设置。

工具中途失败时不会报告成功，已经完成的部分修改可通过 `--restore` 撤回；脚本不会自动恢复或重启桌面。

## 本机核对与验证

2026-10-29 只读核对：CachyOS，Plasma/KDecoration `6.8.2-1.1`，Wayland，使用 KDecoration3；Breeze 与 Papirus 已安装。未发现 Klassy、Catppuccin Mocha Lavender 或 Bibata Modern Ice。本机已有 Papirus 当前选择为 `Papirus`，应用时只切换到同包提供的 `Papirus-Dark`，不重复安装。

```bash
bash -n cachyos/kde_setup.sh
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s cachyos/tests -p test_kde_setup.py -v
```

测试在临时 HOME/XDG 目录内使用真实 KConfig 6 读写，替换 Plasma、D-Bus 与包管理器，覆盖菜单退出/输入结束不改配置、一键安装并应用、组件多选不触碰未选配置、无效组件拒绝、全新系统安装全部缺失组件后再次运行跳过、只读诊断、只补配色、重复应用不写入、旧 ABI 拒绝、强调色重置、尺寸与字体保留、符号链接保护、失败后备份恢复及原先缺失文件恢复。测试不安装包、不加载真实装饰、不切换真实桌面；真实会话视觉效果与插件加载仍需应用后验证。
