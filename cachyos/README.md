# CachyOS 配置脚本

## Steam 统一启动设置

`steam_setup.sh` 管理原生 Steam 的 Proton 环境参数与 SDL 手柄分类。针对 RX 9070 XT / KDE Wayland / 4K 120Hz HDR + VRR，默认请求 **117 FPS** 上限。旧 `proton_setup.sh` 已删除，不提供旧命令兼容入口。

### 使用

普通用户运行，不要 sudo：

```bash
bash cachyos/steam_setup.sh --print-config
bash cachyos/steam_setup.sh --apply
# 完全退出 Steam，再从应用菜单或标准 Steam 固定图标启动。
# 也可以使用相同的已保存配置启动：
bash cachyos/steam_setup.sh --steam
bash cachyos/steam_setup.sh --diagnose

# 修改已有配置时，只更新明确指定的选项
bash cachyos/steam_setup.sh --apply --fps 117 --cache-size 12G

# 无备份清除本脚本添加的启动设置
bash cachyos/steam_setup.sh --remove
```

按本机用户要求，应用与清理**不创建备份**。首次安装使用下表默认值；后续读取已有配置，不用默认值覆盖用户选择。修改 `gaming.conf` 后，完全退出并重新启动 Steam 即可，无需再次应用；现有进程不会自动改变。系统 Steam 菜单入口更新后，再运行 `--apply` 同步菜单动作。

### 唯一参数来源

| 文件 | 作用 |
| --- | --- |
| `${XDG_CONFIG_HOME:-~/.config}/environment.d/gaming.conf` | 唯一参数来源；systemd 用户环境生成器直接读取 |
| `~/.local/bin/steam-managed` | 每次启动读取配置，清除本脚本管理的旧变量后启动 Steam |
| `${XDG_DATA_HOME:-~/.local/share}/steam-setup/environment.sh` | 启动器和 KDE 共用的参数校验及加载逻辑 |
| `${XDG_CONFIG_HOME:-~/.config}/plasma-workspace/env/gaming-env.sh` | KDE 登录时读取同一配置，供会话启动的程序继承 |
| `${XDG_DATA_HOME:-~/.local/share}/applications/steam.desktop` | 只调用启动器，保留 Steam URI、翻译和右键菜单动作 |

配置使用普通 `KEY=VALUE`；不要加引号、`export`、行尾注释或变量展开。仅接受已支持的键和值，不会 `source`/`eval` 配置内容。Xbox 分类值中的第二个 `=` 会完整保留。无效配置会阻止启动，并输出错误。

`--apply` 只更新已标记属于本脚本的文件；遇到其它文件或符号链接，会在写入前退出，避免无备份覆盖自定义内容。`--remove` 同样只清理本脚本的文件，不改 Steam 账户、已安装游戏、存档、手柄布局或游戏启动选项。部署新版前，旧方案添加的配置、登录脚本和用户级 Steam 快捷方式应先清理；没有旧版迁移或恢复分支。

原生菜单启动可立即使用新配置；脚本也刷新可访问的 KDE systemd 用户管理器环境。**已运行的桌面、终端和 D-Bus 服务仍可能保留旧值，彻底更新这些路径需注销重登。** 直接在旧终端运行 `/usr/bin/steam` 不一定经过统一启动器；可以运行 `~/.local/bin/steam-managed`。这里的会话环境也可能影响其它读取相同变量的程序。

### 默认参数及核对结果

| 参数 | 默认值 | 实际作用 |
| --- | --- | --- |
| `PROTON_ENABLE_WAYLAND` | `1` | 请求 Wine 原生 Wayland；不负责开启显示器 HDR/VRR |
| `PROTON_DXVK_LOWLATENCY` | `1` | 选择随 Proton 提供的 DXVK 低延迟分支，主要用于 D3D9/10/11 |
| `DXVK_FRAME_PACE` | `low-latency-vrr` | 对应 DXVK 分支的 VRR 帧节奏；需实际启用 VRR |
| `DXVK_FRAME_RATE` / `VKD3D_FRAME_RATE` | `117` | 两个分支各自读取限帧；数值必须一致 |
| `MESA_SHADER_CACHE_MAX_SIZE` | `12G` | Mesa 磁盘着色器缓存上限，不能消除所有首次编译卡顿 |
| `LOW_LATENCY_LAYER` | `1` | 加载 Proton 提供的可选 Anti-Lag 层；游戏仍需支持并启用 Anti-Lag 2 |
| `SDL_GAMECONTROLLERTYPE` | 检测到 `37d7:2401` 时为 `0x37d7/0x2401=Xbox360` | 将 Vader 5 Pro 按 Xbox 360 分类，不等于关闭 Steam Input |

核对日期 **2026-10-29**：本机 `proton-cachyos-slr 11.0.20261015` 的 `proton` 确认读取三个功能开关；DXVK 低延迟 DLL 确认包含 `DXVK_FRAME_PACE`、`DXVK_FRAME_RATE` 和 VRR 模式，普通 VKD3D DLL 确认包含 `VKD3D_FRAME_RATE`。`protonfixes/utilities.py::setup_frame_rate()` 还会将限帧映射到 `dxgi.maxFrameRate` / `d3d9.maxFrameRate`；因此保留两个分支变量，不直接覆盖 `DXVK_CONFIG`。

省略默认关闭的 `PROTON_VKD3D_LOWLATENCY=0`，加载器会清除旧会话残留再读配置。HDR 自动检测与兼容游戏的 FSR 4 升级沿用本机新版 Proton-CachyOS 默认行为，不重复添加 `DXVK_HDR=1`、`PROTON_FSR4_UPGRADE=1`，也不固定某个 FSR 版本。加载器同时清除这两个旧强制变量及 `LOW_LATENCY_LAYER_REFLEX`；保留其它用户变量，例如自定义的 `DXVK_CONFIG`。

Anti-Lag 层是本机用户偏好，**不是 CachyOS 上游默认或全游戏兼容保证**。实验性 VKD3D 低延迟目前仍不支持 Anti-Lag 2 和帧生成，因此默认不启用。选用 `--dx12-lowlatency` 会移除 Anti-Lag 层；显式同时要求两者则报错。FPS 与实际低延迟改善、游戏菜单是否可用需要游戏内验证，环境匹配不代表功能已经生效。

### 单游戏设置与可选项

Steam 默认兼容性工具仍需选择 **Proton-CachyOS SLR**；游戏属性中指定的其它 Proton 版本可能覆盖它。KDE 和显示器 OSD 中开启 VRR，游戏内按需开启 HDR、FSR、Anti-Lag 2。

```bash
# 持久关闭 Anti-Lag 层，或打开 FSR 验证水印
bash cachyos/steam_setup.sh --apply --no-anti-lag-layer
bash cachyos/steam_setup.sh --apply --fsr-indicator

# 可选实验路径；游戏中关闭 Anti-Lag 2 和帧生成
bash cachyos/steam_setup.sh --apply --dx12-lowlatency

# 临时启动 Flatpak；不安装 Flatpak overrides，也不改 Flatpak 菜单
bash cachyos/steam_setup.sh --steam --flatpak

# Steam 客户端参数或 URI 原样转发；不把它们当成游戏参数
bash cachyos/steam_setup.sh --steam -- steam://open/games
```

`--steam` 只读取已保存配置；选项先通过 `--apply` 保存。单个游戏异常时，可在该游戏启动选项中使用 `DISABLE_LOW_LATENCY_LAYER=1 %command%` 或 `PROTON_ENABLE_WAYLAND=0 %command%` 对比。《鬼武者：剑之道》的 `/WineDetectionEnabled:False` 继续留在该游戏 `%command%` 后面，不推广为全局参数。

CachyOS 文档说明原生 Wayland 的 Steam Input 存在限制，可按游戏测试 `PROTON_USE_SDL=1`；不把它强制加入所有游戏。Xbox 分类不能提供飞智专用背键、陀螺仪等额外功能；本脚本不替换 SDL 库、不解绑 `xpad`。

### 验证与依据

```bash
bash -n cachyos/steam_setup.sh
sh -n cachyos/steam/environment.sh cachyos/steam/steam-managed
PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s cachyos/tests -p test_steam_setup.py -v
```

测试使用独立的空白 HOME/XDG 目录和假 Steam，覆盖首次安装、已有选择保留、幂等、运行时读取配置、参数转发、KDE/systemd 一致性、配置注入拒绝、自定义文件保护及清理。测试不会启动真实 Steam。需要本机另行核对实际启动环境与手柄日志；电脑重启和游戏表现仍需实测。

- [Proton-CachyOS 文档](https://github.com/CachyOS/proton-cachyos/blob/cachyos_main/README.md)：Wayland、HDR、升级器和可选层。
- [DXVK low-latency](https://github.com/netborg-afps/dxvk-low-latency)：分支开关、VRR 帧节奏与限帧。
- [VKD3D low-latency 限制](https://github.com/netborg-afps/vkd3d-low-latency#status--limitations)：Anti-Lag 2、帧生成限制。
- [low_latency_layer](https://github.com/Korthos-Software/low_latency_layer#usage-and-configuration)：可选层、游戏调用要求和开关。
