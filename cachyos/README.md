# CachyOS 配置脚本

## Proton：RX 9070 XT / 4K 120Hz HDR + VRR

`proton_setup.sh` 设置统一环境参数，默认帧率上限为 **117 FPS**。运行后仍需在 **Steam 设置 → 兼容性**中将默认兼容性工具选为 **Proton-CachyOS 的 SLR 构建**。若游戏在“属性 → 兼容性”中强制指定了其它版本，取消该覆盖或改选 CachyOS SLR。脚本不切换 Proton 版本，也不修改游戏画质菜单；官方 Proton 不保证支持这些扩展参数。

普通用户运行，无需 sudo：

```bash
# 在仓库根目录执行：先预览，再持久化
bash cachyos/proton_setup.sh --print-config
bash cachyos/proton_setup.sh --apply

# 注销重登后，从应用菜单启动 Steam。
# 不想立即注销：从 Steam 菜单完全退出 Steam，再执行：
bash cachyos/proton_setup.sh --steam

# 检查显示设置、配置文件和 Steam 启动时继承的参数
bash cachyos/proton_setup.sh --diagnose

# 恢复最近一次应用前的配置；之后注销重登
bash cachyos/proton_setup.sh --restore
```

`--apply` 写入 `${XDG_CONFIG_HOME:-~/.config}/environment.d/gaming.conf`；覆盖前保存完整文件或符号链接到 `${XDG_STATE_HOME:-~/.local/state}/cachyos-proton/backups/`。相同配置重复应用不增加备份。若此前已有 `gaming.conf`，该文件会整体备份、替换；其它配置文件不受影响。恢复也以整个文件为单位。参数作用于继承该环境的进程，包括之后安装的游戏和 Proton 版本，不依赖修改 Proton 安装目录。

`environment.d` 由 systemd 用户环境生成器处理，是否进入桌面进程还取决于会话如何启动。注销重登后请用诊断确认；仅 `daemon-reload` 或重启终端无法更新已运行的桌面、Steam。`--steam` 显式传递参数，便于立即测试；它使用**本次命令选项**生成参数，不读取 `gaming.conf`，自定义选项需再次传入。Flatpak 请用 `--steam --flatpak`，脚本通过 `flatpak run --env=...` 传入参数；本脚本不持久化 Flatpak overrides。

### 默认参数和取舍

| 参数 | 默认值 | 用途与限制 |
| --- | --- | --- |
| `PROTON_ENABLE_WAYLAND` | `1` | 请求 Wine 原生 Wayland；不会自动打开显示器 HDR、VRR |
| `PROTON_DXVK_LOWLATENCY` | `1` | 使用 DXVK 低延迟分支，主要针对 D3D9/10/11 |
| `DXVK_FRAME_PACE` | `low-latency-vrr` | DXVK 低延迟 VRR 模式；需对应分支版本和实际启用 VRR |
| `DXVK_FRAME_RATE` / `VKD3D_FRAME_RATE` | `117` | 请求帧率上限，不能保证性能不足时也达到 117 FPS |
| `PROTON_VKD3D_LOWLATENCY` | `0` | 默认采用普通 VKD3D，保留游戏原有 Anti-Lag 2/帧生成路径 |
| `MESA_SHADER_CACHE_MAX_SIZE` | `12G` | Mesa 磁盘着色器缓存上限，不是显存，也不是所有缓存的总上限 |

脚本不再设置 `DXVK_HDR`、`PROTON_FSR4_UPGRADE` 或 `DXVK_CONFIG`。新版 Proton-CachyOS 在受支持的 KDE Wayland 环境下自动检测 HDR；本机安装版也已默认启用兼容游戏的 FSR 4 升级，首次使用可能由 Proton 下载 DLL。游戏内 HDR 和 FSR 仍需开启。这些默认行为不适用于所有旧版或其它 Proton 分支。

不要在其它位置再设置不同的帧率上限。CachyOS 当前 `protonfixes/utilities.py::setup_frame_rate()` 按 `DXVK_FRAME_RATE`、`VKD3D_FRAME_RATE`、`PROTON_FRAME_RATE` 的顺序取值，再追加 DXGI、D3D9 限帧配置。脚本保留两个分支各自使用的帧率变量，全部设为同一个值，且不再覆盖已有 `DXVK_CONFIG` 的其它键。从旧版脚本更新后请注销重登，清除旧会话继承的参数。

### 游戏内仍需设置

1. KDE 显示设置确认 **3840×2160 / 120Hz / HDR**，自适应同步选择“自动”或“始终”；显示器 OSD 也启用 FreeSync/Adaptive-Sync。HDR 开启不等于 VRR 已开启。
2. 游戏输出分辨率保持 3840×2160，FSR 从 **Quality（质量）**起步。时间升频需要游戏集成，并不能靠环境变量给任意游戏添加。支持升级的游戏可能仍显示“FSR 3.1”；用水印确认实际实现。
3. 游戏支持 **AMD Anti-Lag 2** 时在游戏内开启。它需要游戏发送延迟标记；DXVK/VKD3D 低延迟分支与 Anti-Lag 2 是不同机制。
4. 优先以**关闭帧生成**的状态检查基础帧率、VRR 和输入延迟，再逐游戏比较是否启用帧生成。117 是上限，不会把低基础帧率变为 117 FPS 的响应速度；帧生成后的显示帧率与基础帧率也不相同。

### 可选低延迟路径

```bash
# 验证兼容游戏是否真的启用了 FSR 4
bash cachyos/proton_setup.sh --steam --fsr-indicator

# 单独测试 low_latency_layer 的 Anti-Lag 模式
# 需要所选 Proton 带有该层，游戏也确实调用 Anti-Lag API
bash cachyos/proton_setup.sh --steam --anti-lag-layer

# 单独测试 DX12 实验性低延迟：游戏需使用 Reflex 或 Waitable Swapchains
# 此模式关闭游戏内帧生成，并避免同时使用 Anti-Lag 2
bash cachyos/proton_setup.sh --steam --dx12-lowlatency

# 自定义持久配置；即时启动时重复相同选项
bash cachyos/proton_setup.sh --apply --fps 117 --cache-size 12G
```

截至本次查阅，`vkd3d-low-latency` README 明确列出 **Anti-Lag 2、帧生成尚不支持**，并非适合所有 DX12 游戏的全局开关。因此默认关闭它。可在单个游戏启动选项里设 `PROTON_VKD3D_LOWLATENCY=1 %command%` 逐个测试，支持的游戏可通过 Proton 日志里的 `waitable dxgi swapchain present percentage` 验证 Waitable Swapchains 路径。

`--anti-lag-layer` 仅启用 `LOW_LATENCY_LAYER=1`。默认保留系统/游戏原有 Anti-Lag 路径，不叠加该层。脚本不设置 `LOW_LATENCY_LAYER_REFLEX=1`、`PROTON_FORCE_NVAPI=1` 或显卡厂商伪装；尤其 NVIDIA 伪装可能破坏 FSR 4 的 AMD 识别。Reflex 替代方案需要按具体游戏测试，不能当作所有游戏默认值。`--steam` 会清除这两个可选项（Anti-Lag 层、FSR 水印）及 `LOW_LATENCY_LAYER_REFLEX` 的旧会话残留，再启用本次明确请求的选项。

原生 Wayland 下如游戏启动器白屏或手柄异常，先在该游戏启动选项测试 `PROTON_ENABLE_WAYLAND=0 %command%`。桌面环境里的参数和单个游戏启动参数可能覆盖默认值；诊断里的 Steam 环境也不能证明最终游戏已经启用 HDR、FSR 或低延迟。

### 核对依据

文档核对日期：2026-10-25；本机安装的 `proton-cachyos-slr/proton`、`protonfixes/utilities.py`、`protonfixes/upscalers.py` 也核对了参数解析、限帧和升级路径。升级 Proton 后，应以所装版本的实现为准。

- [Proton-CachyOS 配置说明](https://github.com/CachyOS/proton-cachyos/blob/cachyos_main/README.md)：Wayland、HDR、FSR 升级和可选组件。
- [DXVK low-latency](https://github.com/netborg-afps/dxvk-low-latency)：VRR pacing 与帧率上限；较旧版本的 VRR 模式名称不同。
- [VKD3D low-latency](https://github.com/netborg-afps/vkd3d-low-latency#status--limitations)：触发条件和 Anti-Lag 2 / 帧生成限制。
- [low_latency_layer](https://github.com/Korthos-Software/low_latency_layer#usage-and-configuration)：Anti-Lag 与 Reflex 模式、显卡伪装对 FSR 的影响。
- [Proton-EM FSR 4 说明](https://github.com/Etaash-mathamsetty/Proton/blob/em-10/docs/FSR4.md)：RDNA4 和 Mesa 支持条件；CachyOS 的水印开关以自身文档为准。
