#!/usr/bin/env bash
# RX 9070 XT / KDE Wayland / 4K 120Hz：用户级 Proton-CachyOS 默认参数。
# 普通用户运行；仅 --apply/--restore 写文件，--steam 才启动 Steam。
set -euo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/cachyos-proton"
CONFIG_FILE="$CONFIG_HOME/environment.d/gaming.conf"
FPS=117
CACHE_SIZE=12G
DX12_LOWLATENCY=0
ANTI_LAG_LAYER=false
FSR_INDICATOR=false
FLATPAK=false
TEMPORARY=''
GAMING_ENV=()

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
cleanup() { [[ -z "$TEMPORARY" ]] || rm -f -- "$TEMPORARY"; }

usage() {
    cat <<'EOF'
用法：bash proton_setup.sh 操作 [选项]
操作（一次一个；无参数只显示帮助）：
  --apply          备份后写入 ~/.config/environment.d/gaming.conf
  --restore        恢复最近一次应用前的 gaming.conf
  --diagnose       只读检查配置、显示器与 Steam 启动时继承的环境
  --print-config   预览将生成的配置，不写入文件
  --steam          用本次参数启动 Steam（先手动完全退出已有 Steam）
选项：
  --fps N          帧率上限，默认 117；范围 1..1000
  --cache-size N[G|M]   Mesa 磁盘着色器缓存上限，默认 12G
  --dx12-lowlatency     使用实验性 VKD3D 低延迟分支；不支持帧生成/Anti-Lag 2
  --anti-lag-layer      加载可选 low_latency_layer 的 Anti-Lag 模式
  --fsr-indicator       打开 FSR 4 验证水印
  --flatpak            仅配合 --steam，为 Flatpak Steam 显式传递参数
  --help               显示帮助

默认：原生 Wayland、DXVK VRR 低延迟、117 FPS、12G 缓存。
HDR 自动检测、兼容游戏的 FSR 4 升级交给新版 Proton-CachyOS 默认处理。
FSR 质量档、Anti-Lag 2、HDR 需在游戏内开启；VRR 需在 KDE 显示设置中开启。
environment.d 通常需注销重登才传入桌面；不会更新已运行的 Steam。
--steam 直接使用本次命令的参数，不读取 gaming.conf；自定义选项需重复传入。
EOF
}

build_environment() {
    [[ "$FPS" =~ ^[1-9][0-9]{0,3}$ ]] && ((FPS <= 1000)) || die 'fps 必须是 1..1000 的整数'
    [[ "$CACHE_SIZE" =~ ^[1-9][0-9]{0,4}[GM]$ ]] || die 'cache-size 格式应为 12G 或 512M'
    [[ "$ANTI_LAG_LAYER" == false || "$DX12_LOWLATENCY" == 0 ]] || die '请分别测试 Anti-Lag 层与 VKD3D 低延迟，不要同时启用'
    GAMING_ENV=(
        'PROTON_ENABLE_WAYLAND=1'
        'PROTON_DXVK_LOWLATENCY=1'
        'DXVK_FRAME_PACE=low-latency-vrr'
        "DXVK_FRAME_RATE=$FPS"
        "PROTON_VKD3D_LOWLATENCY=$DX12_LOWLATENCY"
        "VKD3D_FRAME_RATE=$FPS"
        "MESA_SHADER_CACHE_MAX_SIZE=$CACHE_SIZE"
    )
    if "$ANTI_LAG_LAYER"; then GAMING_ENV+=('LOW_LATENCY_LAYER=1'); fi
    if "$FSR_INDICATOR"; then GAMING_ENV+=('PROTON_FSR4_INDICATOR=1'); fi
}

print_config() {
    cat <<'EOF'
# Managed by sh/cachyos/proton_setup.sh
# 针对 Proton-CachyOS；不切换 Steam 的兼容性工具，也不修改游戏画质选项。
# KDE 显示器设置：3840x2160 / 120Hz / HDR / 自适应同步。
# 游戏内：FSR Quality 起步，支持时开启 Anti-Lag 2；优先测试关闭帧生成。
# HDR 检测和兼容游戏的 FSR 4 升级使用新版 Proton-CachyOS 默认行为。
# DXVK/VKD3D 低延迟分支的参数不同；VKD3D 分支不是 Anti-Lag 2 开关。
EOF
    printf '%s\n' "${GAMING_ENV[@]}"
}

lock_state() {
    need flock
    mkdir -p "$STATE_HOME/backups"
    exec 9> "$STATE_HOME/lock"
    flock -n 9 || die '另一个配置操作正在进行'
}

backup_config() {
    BACKUP_DIR=$(mktemp -d "$STATE_HOME/backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
    if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
        [[ -f "$CONFIG_FILE" || -L "$CONFIG_FILE" ]] || die 'gaming.conf 不是普通文件或符号链接'
        cp -a -- "$CONFIG_FILE" "$BACKUP_DIR/gaming.conf"
    else
        touch "$BACKUP_DIR/absent"
    fi
    # 保存文件所属路径，避免换了 XDG_CONFIG_HOME 后误恢复到另一个位置。
    printf '%s\n' "$CONFIG_FILE" > "$BACKUP_DIR/target"
    printf '%s\n' "${BACKUP_DIR##*/}" > "$STATE_HOME/latest"
    printf '已备份：%s\n' "$BACKUP_DIR"
}

apply_config() {
    lock_state
    mkdir -p "$(dirname "$CONFIG_FILE")"
    TEMPORARY=$(mktemp "$(dirname "$CONFIG_FILE")/.gaming-XXXXXX")
    print_config > "$TEMPORARY"
    if [[ -f "$CONFIG_FILE" ]] && cmp -s -- "$TEMPORARY" "$CONFIG_FILE"; then
        printf '配置已相同，无需修改；保留原备份。\n'
        return
    fi
    backup_config
    chmod 644 "$TEMPORARY"
    mv -fT -- "$TEMPORARY" "$CONFIG_FILE"
    TEMPORARY=''
    printf '已写入：%s\n' "$CONFIG_FILE"
    printf '请注销并重新登录。现在测试可完全退出 Steam 后，用本脚本 --steam 启动。\n'
    printf 'Steam 兼容性工具请选 Proton-CachyOS (SLR)；游戏内开启 FSR/HDR/Anti-Lag。\n'
}

restore_config() {
    lock_state
    [[ -f "$STATE_HOME/latest" ]] || die '没有可恢复的备份'
    local name backup target
    IFS= read -r name < "$STATE_HOME/latest"
    [[ "$name" =~ ^[0-9]{8}-[0-9]{6}-[a-zA-Z0-9]{6}$ ]] || die '备份名称无效'
    backup="$STATE_HOME/backups/$name"
    [[ -f "$backup/target" ]] || die '备份不完整'
    IFS= read -r target < "$backup/target"
    [[ "$target" == "$CONFIG_FILE" ]] || die '备份的配置路径与当前 XDG_CONFIG_HOME 不一致'
    if [[ -f "$backup/absent" ]]; then
        rm -f -- "$CONFIG_FILE"
    else
        [[ -f "$backup/gaming.conf" || -L "$backup/gaming.conf" ]] || die '备份缺少 gaming.conf'
        mkdir -p "$(dirname "$CONFIG_FILE")"
        TEMPORARY=$(mktemp "$(dirname "$CONFIG_FILE")/.gaming-XXXXXX")
        cp -a --remove-destination -- "$backup/gaming.conf" "$TEMPORARY"
        mv -fT -- "$TEMPORARY" "$CONFIG_FILE"
        TEMPORARY=''
    fi
    printf '已恢复：%s\n请注销重登；当前进程中的旧环境不会自动清除。\n' "$backup"
}

steam_running() { pgrep -u "$UID" -x steam >/dev/null 2>&1; }

launch_steam() {
    need pgrep
    steam_running && die 'Steam 已在运行，请从 Steam 菜单完全退出后重试（无需结束游戏进程）'
    local -a command_args=(steam) env_args=()
    local item
    if "$FLATPAK"; then
        need flatpak
        command_args=(flatpak run)
        # 清除本脚本可选项在旧桌面会话中的残留；本次启用的项在下方覆盖。
        for item in LOW_LATENCY_LAYER LOW_LATENCY_LAYER_REFLEX PROTON_FSR4_INDICATOR; do
            command_args+=("--unset-env=$item")
        done
        for item in "${GAMING_ENV[@]}"; do command_args+=("--env=$item"); done
        command_args+=(com.valvesoftware.Steam)
    else
        need steam
    fi
    for item in LOW_LATENCY_LAYER LOW_LATENCY_LAYER_REFLEX PROTON_FSR4_INDICATOR; do env_args+=(-u "$item"); done
    printf '启动 Steam：%s FPS；HDR/FSR 4 使用新版 Proton-CachyOS 默认行为，请确认已选择该兼容性工具。\n' "$FPS"
    exec env "${env_args[@]}" "${GAMING_ENV[@]}" "${command_args[@]}"
}

diagnose() {
    printf '会话：%s / %s\n配置：%s\n' "${XDG_CURRENT_DESKTOP:-未知}" "${XDG_SESSION_TYPE:-未知}" "$CONFIG_FILE"
    if [[ -f "$CONFIG_FILE" ]]; then cat -- "$CONFIG_FILE"; else printf '尚未写入配置。\n'; fi
    if command -v lspci >/dev/null 2>&1; then lspci -nn | awk '/VGA|3D controller|Display controller/'; fi
    if command -v kscreen-doctor >/dev/null 2>&1; then
        # 只读 CLI 无需创建 Wayland/X11 窗口；也便于在受限终端中诊断。
        local display_output
        if display_output=$(ulimit -c 0; QT_QPA_PLATFORM=offscreen kscreen-doctor -o) && [[ -n "$display_output" ]]; then
            printf '%s\n' "$display_output"
        else
            printf '无法读取 KScreen，请在桌面终端中检查显示设置。\n'
        fi
    fi
    if command -v pacman >/dev/null 2>&1; then pacman -Q mesa vulkan-radeon proton-cachyos-slr 2>/dev/null || true; fi
    if command -v pgrep >/dev/null 2>&1; then
        local pid
        while IFS= read -r pid; do
            printf '\nSteam PID %s 启动时的环境（不代表最终游戏进程）：\n' "$pid"
            if [[ -r "/proc/$pid/environ" ]]; then
                tr '\0' '\n' < "/proc/$pid/environ" | awk '/^(PROTON_ENABLE_WAYLAND|DXVK_HDR|PROTON_FSR4_UPGRADE|PROTON_DXVK_LOWLATENCY|DXVK_FRAME_PACE|DXVK_FRAME_RATE|PROTON_VKD3D_LOWLATENCY|VKD3D_FRAME_RATE|DXVK_CONFIG|MESA_SHADER_CACHE_MAX_SIZE|LOW_LATENCY_LAYER|LOW_LATENCY_LAYER_REFLEX|PROTON_FSR4_INDICATOR)=/'
            else
                printf '无法读取进程环境。\n'
            fi
        done < <(pgrep -u "$UID" -x steam || true)
    fi
    printf '\n无输出的参数表示进程启动时未携带；配置文件存在不等于游戏已启用功能。\n'
}

main() {
    local action='' selected=false
    while (($#)); do
        case "$1" in
            --apply|--restore|--diagnose|--print-config|--steam)
                [[ "$selected" == false ]] || die '一次只能指定一个操作'
                selected=true
                case "$1" in --apply) action=apply_config ;; --restore) action=restore_config ;; --diagnose) action=diagnose ;; --print-config) action=print_config ;; --steam) action=launch_steam ;; esac
                shift ;;
            --fps|--cache-size)
                (($# >= 2)) || die "$1 缺少值"
                case "$1" in --fps) FPS=$2 ;; --cache-size) CACHE_SIZE=$2 ;; esac
                shift 2 ;;
            --dx12-lowlatency) DX12_LOWLATENCY=1; shift ;;
            --anti-lag-layer) ANTI_LAG_LAYER=true; shift ;;
            --fsr-indicator) FSR_INDICATOR=true; shift ;;
            --flatpak) FLATPAK=true; shift ;;
            --help|-h) usage; return 0 ;;
            *) die "未知参数：$1" ;;
        esac
    done
    [[ -n "$action" ]] || { usage; return 0; }
    [[ "$FLATPAK" == false || "$action" == launch_steam ]] || die '--flatpak 仅支持 --steam；environment.d 不保证穿透沙盒'
    build_environment
    if [[ "$action" == apply_config || "$action" == restore_config || "$action" == launch_steam ]]; then
        ((EUID != 0)) || die '请用桌面普通用户运行，不要 sudo 整个脚本'
    fi
    trap cleanup EXIT
    "$action"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
