#!/usr/bin/env bash
# Native Steam / KDE: one environment.d file, shared by every managed entry point.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/steam-setup"
CONFIG_FILE="$CONFIG_HOME/environment.d/gaming.conf"
DESKTOP_FILE="$DATA_HOME/applications/steam.desktop"
HELPER="$HOME/.local/bin/steam-managed"
ENV_LIBRARY="$DATA_HOME/steam-setup/environment.sh"
KDE_FILE="$CONFIG_HOME/plasma-workspace/env/gaming-env.sh"
DESKTOP_SOURCE=/usr/share/applications/steam.desktop
STAGE=''
. "$ROOT/steam/environment.sh"
declare -A SETTINGS=()

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n "$STAGE" ]]; then rm -rf -- "$STAGE"; fi; }
usage() {
    cat <<'HELP'
用法：bash steam_setup.sh 操作 [选项]
  --print-config   预览配置；读取已保存值并合并明确指定的选项
  --apply          无备份安装/更新配置、启动器和 KDE 登录加载器
  --steam          读取已保存配置启动 Steam；-- 后的参数原样传给 Steam
  --diagnose       只读比较配置与 Steam 环境，并显示手柄分类日志
  --remove         无备份删除本脚本管理的启动设置（不改 Steam 游戏/账户配置）
选项：
  --fps N / --cache-size 12G     默认 117 FPS / 12G
  --anti-lag-layer / --no-anti-lag-layer
  --dx12-lowlatency             可选实验分支；与 Anti-Lag 层互斥
  --fsr-indicator               可选 FSR 验证水印
  --flatpak                    仅用于 --steam 的临时启动
现有配置优先；首次安装使用 Wayland、DXVK VRR 低延迟和 Anti-Lag 层。
检测到 Vader 5 Pro（37d7:2401）时添加 Xbox360 分类；已有分类予以保留。
普通菜单启动器每次读取配置，不重复保存参数。配置不执行 shell 表达式。
HELP
}

read_settings() {
    local lines line
    if [[ -f "$CONFIG_FILE" ]]; then
        lines=$(steam_config_lines "$CONFIG_FILE") || exit 1
    else
        lines=$'PROTON_ENABLE_WAYLAND=1\nPROTON_DXVK_LOWLATENCY=1\nDXVK_FRAME_PACE=low-latency-vrr\nDXVK_FRAME_RATE=117\nVKD3D_FRAME_RATE=117\nMESA_SHADER_CACHE_MAX_SIZE=12G\nLOW_LATENCY_LAYER=1'
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] || SETTINGS[${line%%=*}]=${line#*=}
    done <<< "$lines"
    if [[ ! -v SETTINGS[SDL_GAMECONTROLLERTYPE] ]]; then
        local device
        for device in /sys/bus/usb/devices/*; do
            [[ -r "$device/idVendor" && -r "$device/idProduct" ]] || continue
            if [[ $(< "$device/idVendor") == 37d7 && $(< "$device/idProduct") == 2401 ]]; then
                SETTINGS[SDL_GAMECONTROLLERTYPE]='0x37d7/0x2401=Xbox360'
                break
            fi
        done
    fi
    # Unset is the normal upstream choice; the loader clears stale inherited overrides.
    if [[ "${SETTINGS[PROTON_VKD3D_LOWLATENCY]:-}" == 0 ]]; then unset 'SETTINGS[PROTON_VKD3D_LOWLATENCY]'; fi
}

print_config() {
    printf '# Managed by sh/cachyos/steam_setup.sh\n# Plain KEY=VALUE only; no quotes, export, substitutions or inline comments.\n'
    local key
    for key in $steam_env_keys; do
        if [[ -v SETTINGS[$key] ]]; then printf '%s=%s\n' "$key" "${SETTINGS[$key]}"; fi
    done
}

check_owned() {
    local path=$1
    [[ -e "$path" || -L "$path" ]] || return 0
    [[ -f "$path" && ! -L "$path" ]] || fail "拒绝覆盖或删除非普通文件：$path"
    grep -Eq '^# Managed by sh/cachyos/steam_setup\.sh' "$path" || fail "文件不属于本脚本：$path"
}

lock_state() {
    mkdir -p "$STATE_HOME"
    exec 9> "$STATE_HOME/lock"
    flock -n 9 || fail '另一个配置操作正在进行'
}

refresh_menu() {
    if command -v kbuildsycoca6 >/dev/null && [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]; then
        kbuildsycoca6 --noincremental >/dev/null 2>&1 || printf '菜单刷新未成功；重新登录后会刷新。\n' >&2
    fi
}

refresh_user_environment() {
    # A running desktop cannot be rewritten; managed launches read the file directly.
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* && -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v systemctl >/dev/null; then
        local -a keys=() values=()
        read -r -a keys <<< "$steam_env_keys $steam_legacy_keys"
        if ! systemctl --user unset-environment "${keys[@]}"; then
            printf '用户服务环境未刷新；下次登录生效。\n' >&2
            return
        fi
        if [[ -f "$CONFIG_FILE" ]]; then
            mapfile -t values < <(steam_config_lines "$CONFIG_FILE")
            if ((${#values[@]})); then
                systemctl --user set-environment "${values[@]}" || printf '用户服务环境未刷新；下次登录生效。\n' >&2
                if command -v dbus-update-activation-environment >/dev/null; then
                    dbus-update-activation-environment "${values[@]}" || printf 'D-Bus 启动环境未刷新；下次登录生效。\n' >&2
                fi
            fi
        fi
    fi
}

apply_config() {
    lock_state
    [[ -f "$DESKTOP_SOURCE" ]] || fail "找不到原生 Steam 入口：$DESKTOP_SOURCE"
    local path index=0
    for path in "$CONFIG_FILE" "$DESKTOP_FILE" "$HELPER" "$ENV_LIBRARY" "$KDE_FILE"; do check_owned "$path"; done
    STAGE=$(mktemp -d "$STATE_HOME/stage-XXXXXX")
    print_config > "$STAGE/config"
    steam_config_lines "$STAGE/config" >/dev/null || exit 1
    cp -- "$ROOT/steam/environment.sh" "$STAGE/library"
    cp -- "$ROOT/steam/steam-managed" "$STAGE/helper"
    cat > "$STAGE/kde" <<'KDE'
# Managed by sh/cachyos/steam_setup.sh
if [ -r "${XDG_DATA_HOME:-$HOME/.local/share}/steam-setup/environment.sh" ]; then
    . "${XDG_DATA_HOME:-$HOME/.local/share}/steam-setup/environment.sh"
    steam_load_environment || printf 'Steam 会话参数未加载，请检查 gaming.conf。\n' >&2
fi
KDE
    python3 - "$DESKTOP_SOURCE" "$HELPER" > "$STAGE/steam.desktop" <<'PY_DESKTOP'
import sys
from pathlib import Path
# Escape both desktop-entry string encoding and Exec argument encoding.
p=sys.argv[2].replace('\\','\\\\\\\\').replace('"','\\\\\\"').replace('$','\\\\$').replace('`','\\\\`').replace('%','%%')
if '\n' in p or '\r' in p: sys.exit('启动器路径不能含换行')
print('# Managed by sh/cachyos/steam_setup.sh')
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('Exec='):
        command=line[5:]
        if not (command=='/usr/bin/steam' or command.startswith('/usr/bin/steam ')):
            sys.exit('系统 Steam 入口的 Exec 格式未知，未安装')
        line='Exec="'+p+'"'+command[len('/usr/bin/steam'):]
    print(line)
PY_DESKTOP
    if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$STAGE/steam.desktop" >/dev/null || exit 1; fi
    local -a sources=(config steam.desktop helper library kde)
    local -a targets=("$CONFIG_FILE" "$DESKTOP_FILE" "$HELPER" "$ENV_LIBRARY" "$KDE_FILE")
    for path in "${targets[@]}"; do
        if [[ ! -f "$path" ]] || ! cmp -s -- "$STAGE/${sources[index]}" "$path"; then
            mkdir -p -- "$(dirname -- "$path")"
            local temporary
            temporary=$(mktemp "$(dirname -- "$path")/.steam-setup-XXXXXX")
            cp -- "$STAGE/${sources[index]}" "$temporary"
            if [[ "$path" == "$HELPER" ]]; then chmod 755 "$temporary"; else chmod 644 "$temporary"; fi
            mv -fT -- "$temporary" "$path"
            printf '已更新：%s\n' "$path"
        fi
        index=$((index+1))
    done
    refresh_user_environment
    refresh_menu
    printf '已统一设置（未创建备份）。完全退出 Steam 后，从菜单启动即可。\n'
}

remove_config() {
    lock_state
    local path
    local -a targets=("$CONFIG_FILE" "$DESKTOP_FILE" "$HELPER" "$ENV_LIBRARY" "$KDE_FILE")
    for path in "${targets[@]}"; do check_owned "$path"; done
    for path in "${targets[@]}"; do
        if [[ -e "$path" ]]; then rm -- "$path"; printf '已清理：%s\n' "$path"; fi
    done
    refresh_user_environment
    refresh_menu
    printf '已删除本脚本的启动设置；未修改 Steam 账户、游戏或手柄布局。\n旧会话环境需注销重登才会彻底消失。\n'
}

launch_steam() {
    [[ -x "$HELPER" ]] || fail '请先运行 --apply'
    if pgrep -u "$UID" -x steam >/dev/null; then fail 'Steam 已在运行；先从 Steam 菜单完全退出以载入新配置'; fi
    local -a env_args=()
    local key
    for key in $steam_env_keys $steam_legacy_keys; do env_args+=(-u "$key"); done
    if "$FLATPAK"; then STEAM_ARGS=(--flatpak "${STEAM_ARGS[@]}"); fi
    # All entry points use saved values, never a second set of CLI defaults.
    if "$HAS_OPTIONS"; then fail '--steam 读取已保存配置；请先用 --apply 保存自定义选项'; fi
    exec env "${env_args[@]}" "$HELPER" "${STEAM_ARGS[@]}"
}

diagnose() {
    print_config
    python3 - "$CONFIG_FILE" "$ENV_LIBRARY" <<'PY_DIAG'
import os,subprocess,sys
from pathlib import Path
result=subprocess.run(['/bin/sh','-c','. "$1"; steam_config_lines "$2"','check',sys.argv[2],sys.argv[1]],capture_output=True,text=True)
if result.returncode: sys.exit(result.stderr)
expected=dict(line.split('=',1) for line in result.stdout.splitlines())
keys=set(expected)|{'PROTON_VKD3D_LOWLATENCY','LOW_LATENCY_LAYER_REFLEX','DXVK_HDR','PROTON_FSR4_UPGRADE','PROTON_FSR4_INDICATOR','LOW_LATENCY_LAYER'}
found=False
for p in Path('/proc').iterdir():
    if not p.name.isdigit(): continue
    try:
        if p.stat().st_uid!=os.getuid() or (p/'comm').read_text().strip()!='steam': continue
        found=True
        env=dict(x.split('=',1) for x in (p/'environ').read_bytes().decode(errors='replace').split('\0') if '=' in x)
        print('\nSteam PID',p.name)
        for key in sorted(keys):
            print(key+'='+env.get(key,'<未设置>')+(' [与配置一致]' if env.get(key)==expected.get(key) else ' [与配置不同，请完全退出后重启]'))
    except (OSError,ValueError): pass
if not found: print('\n未发现可读取的 Steam 进程。')
p=Path.home()/'.local/share/Steam/logs/controller_ui.txt'
if p.is_file():
    lines=p.read_text(errors='replace').splitlines()
    print('\n近期手柄分类（历史日志不等于当前硬件状态）：')
    print('\n'.join(x for x in lines[-150:] if 'Type:' in x or 'controller_xbox360' in x)[-1800:])
print('\n环境匹配不代表游戏内已启用 HDR、FSR 或 Anti-Lag。')
PY_DIAG
}

main() {
    local action='' option
    local -a options=()
    STEAM_ARGS=(); FLATPAK=false; HAS_OPTIONS=false
    while (($#)); do
        case "$1" in
            --apply|--remove|--steam|--diagnose|--print-config)
                [[ -z "$action" ]] || fail '一次只能指定一个操作'
                action=$1; shift ;;
            --fps|--cache-size)
                (($#>=2)) || fail "$1 缺少值"
                options+=("$1" "$2"); HAS_OPTIONS=true; shift 2 ;;
            --dx12-lowlatency|--anti-lag-layer|--no-anti-lag-layer|--fsr-indicator)
                options+=("$1"); HAS_OPTIONS=true; shift ;;
            --flatpak) FLATPAK=true; shift ;;
            --) shift; STEAM_ARGS=("$@"); break ;;
            --help|-h) usage; return ;;
            *) fail "未知参数：$1" ;;
        esac
    done
    [[ -n "$action" ]] || { usage; return; }
    [[ "$FLATPAK" == false || "$action" == --steam ]] || fail '--flatpak 仅支持 --steam'
    [[ ${#STEAM_ARGS[@]} == 0 || "$action" == --steam ]] || fail '-- 后的参数仅用于 --steam'
    if [[ "$action" != --print-config && "$action" != --diagnose ]]; then ((EUID!=0)) || fail '请用桌面普通用户运行'; fi
    trap cleanup EXIT
    if [[ "$action" == --remove ]]; then remove_config; return; fi
    read_settings
    set -- "${options[@]}"
    while (($#)); do
        option=$1; shift
        case "$option" in
            --fps) SETTINGS[DXVK_FRAME_RATE]=$1; SETTINGS[VKD3D_FRAME_RATE]=$1; shift ;;
            --cache-size) SETTINGS[MESA_SHADER_CACHE_MAX_SIZE]=$1; shift ;;
            --dx12-lowlatency) SETTINGS[PROTON_VKD3D_LOWLATENCY]=1 ;;
            --anti-lag-layer) SETTINGS[LOW_LATENCY_LAYER]=1 ;;
            --no-anti-lag-layer) unset 'SETTINGS[LOW_LATENCY_LAYER]' ;;
            --fsr-indicator) SETTINGS[PROTON_FSR4_INDICATOR]=1 ;;
        esac
    done
    # Explicit requests for both paths are errors in either argument order.
    if [[ "${SETTINGS[PROTON_VKD3D_LOWLATENCY]:-}" == 1 ]]; then
        if [[ " ${options[*]} " == *' --anti-lag-layer '* ]]; then fail 'Anti-Lag 层不能与实验性 VKD3D 低延迟同时启用'; fi
        unset 'SETTINGS[LOW_LATENCY_LAYER]'
    fi
    steam_config_lines <(print_config) >/dev/null || exit 1
    case "$action" in
        --apply) apply_config ;;
        --steam) launch_steam ;;
        --diagnose) diagnose ;;
        --print-config) print_config ;;
    esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
