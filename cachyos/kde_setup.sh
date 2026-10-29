#!/usr/bin/env bash
# 方案 A：Breeze + Klassy 装饰 + Catppuccin Mocha + Papirus-Dark + Bibata。
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}/cachyos-kde
SCHEME=CatppuccinMochaPink
CURSOR=Bibata-Modern-Ice
FILES=(kdeglobals plasmarc kcminputrc kwinrc)
ALL_COMPONENTS=(breeze klassy colors papirus bibata)
COMPONENTS=("${ALL_COMPONENTS[@]}")
DATA_DIRS=()
IFS=: read -r -a DATA_DIRS <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
DATA_DIRS=("$DATA_HOME" "${DATA_DIRS[@]}")
PLUGIN_ROOT=''
DECORATION_DIR=''

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

usage() {
    cat <<'EOF'
用法：bash cachyos/kde_setup.sh [操作] [组件...]
  无参数      打开菜单，可一键安装并应用，或选择组件
  --setup     安装缺失组件并应用，省略组件时处理全部
  --diagnose  只读检测环境、组件和当前配置
  --install   仅安装缺少的组件，不应用主题；包管理器保留交互确认
  --apply     检查完整性，备份后应用方案 A；已符合的配置跳过
  --restore   恢复最近一次应用前的四个完整配置文件
  --help      显示帮助
组件：breeze klassy colors papirus bibata（可空格分隔指定多个）
示例：bash cachyos/kde_setup.sh --setup colors papirus
请在普通用户的 Plasma 6 Wayland 会话中运行，不要 sudo 整个脚本。
安装针对 CachyOS/Arch；缺少仓库包时使用现有 paru/yay，不自动安装 AUR helper。
EOF
}

selected() {
    local part
    for part in "${COMPONENTS[@]}"; do [[ "$part" != "$1" ]] || return 0; done
    return 1
}

detect_plugins() {
    PLUGIN_ROOT=''
    DECORATION_DIR=''
    local tool
    for tool in qtpaths6 /usr/lib/qt6/bin/qtpaths6 /usr/lib/qt6/bin/qtpaths; do
        if command -v "$tool" >/dev/null 2>&1; then
            PLUGIN_ROOT=$("$tool" --plugin-dir)
            break
        fi
    done
    [[ -n "$PLUGIN_ROOT" ]] || return 0
    # 以本机原生 Breeze 插件确定 ABI，不把旧 KDecoration2 插件当成新版可用组件。
    local abi
    for abi in 3 2; do
        if [[ -f "$PLUGIN_ROOT/org.kde.kdecoration$abi/org.kde.breeze.so" ]]; then
            DECORATION_DIR="$PLUGIN_ROOT/org.kde.kdecoration$abi"
            break
        fi
    done
}

data_file() {
    local root
    for root in "${DATA_DIRS[@]}"; do
        if [[ -f "$root/$1" ]]; then printf '%s\n' "$root/$1"; return 0; fi
    done
    return 1
}

has_component() {
    case "$1" in
        breeze)
            [[ -f "$PLUGIN_ROOT/styles/breeze6.so" && -n "$DECORATION_DIR" ]] &&
                data_file plasma/desktoptheme/default/metadata.json >/dev/null ;;
        klassy) [[ -n "$DECORATION_DIR" && -f "$DECORATION_DIR/org.kde.klassy.so" ]] ;;
        papirus) data_file icons/Papirus-Dark/index.theme >/dev/null ;;
        bibata)
            # Qt 的图标搜索路径包含传统 ~/.icons。
            [[ -f "$HOME/.icons/$CURSOR/index.theme" && -f "$HOME/.icons/$CURSOR/cursors/left_ptr" ]] ||
                { data_file "icons/$CURSOR/index.theme" >/dev/null && data_file "icons/$CURSOR/cursors/left_ptr" >/dev/null; } ;;
        colors) data_file "color-schemes/$SCHEME.colors" >/dev/null ;;
    esac
}

read_setting() {
    kreadconfig6 --file "$CONFIG_HOME/$1" --group "$2" --key "$3" --default "${4:-}"
}

targets() {
    # 最后一列是未显式配置时的 KDE 默认值。
    if selected breeze; then cat <<'EOF'
kdeglobals|KDE|widgetStyle|Breeze|Breeze
plasmarc|Theme|name|default|default
EOF
    fi
    if selected papirus; then cat <<'EOF'
kdeglobals|Icons|Theme|Papirus-Dark|breeze
EOF
    fi
    if selected colors; then cat <<EOF
kdeglobals|General|accentColorFromWallpaper|false|false
kdeglobals|General|AccentColor|0,0,0,0|0,0,0,0
kdeglobals|General|ColorScheme|$SCHEME|BreezeLight
EOF
    fi
    if selected bibata; then cat <<EOF
kcminputrc|Mouse|cursorTheme|$CURSOR|breeze_cursors
EOF
    fi
    if selected klassy; then cat <<'EOF'
kwinrc|org.kde.kdecoration2|library|org.kde.klassy|org.kde.breeze
kwinrc|org.kde.kdecoration2|theme|Klassy|Breeze
kwinrc|org.kde.kdecoration2|NoPlugin|false|false
EOF
    fi
}

diagnose() {
    printf '系统：'; sed -n 's/^PRETTY_NAME=//p' /etc/os-release
    printf '会话：%s / %s / Plasma %s\n' "${XDG_CURRENT_DESKTOP:-未知}" "${XDG_SESSION_TYPE:-未知}" "${KDE_SESSION_VERSION:-未知}"
    printf '窗口装饰目录：%s\n' "${DECORATION_DIR:-未找到原生 Breeze 插件}"
    local part
    for part in "${COMPONENTS[@]}"; do
        if has_component "$part"; then printf '[已有] %s\n' "$part"; else printf '[缺少] %s\n' "$part"; fi
    done
    if command -v pacman >/dev/null 2>&1; then
        pacman -Q plasma-workspace kdecoration 2>/dev/null || true
    fi
    if command -v kreadconfig6 >/dev/null 2>&1; then
        local file group key value fallback current
        while IFS='|' read -r file group key value fallback; do
            current=$(read_setting "$file" "$group" "$key" "$fallback")
            printf '%s [%s] %s：%s → %s\n' "$file" "$group" "$key" "$current" "$value"
        done < <(targets)
        printf '光标尺寸（保留）：%s\n' "$(read_setting kcminputrc Mouse cursorSize '系统默认')"
    fi
    printf '安装不会应用配置；--apply 不安装软件，不修改布局、渲染参数或字体。\n'
}

install_components() {
    need pacman
    local part package helper='' candidate
    local -a repo=() aur=()
    for part in "${COMPONENTS[@]}"; do
        [[ "$part" != colors ]] || continue
        if has_component "$part"; then printf '跳过已有组件：%s\n' "$part"; continue; fi
        case "$part" in
            breeze) package=breeze ;;
            klassy) package=klassy ;;
            papirus) package=papirus-icon-theme ;;
            bibata) package=bibata-cursor-theme ;;
        esac
        if pacman -Q "$package" >/dev/null 2>&1 ||
            { [[ "$part" == bibata ]] && pacman -Q bibata-cursor-theme-bin >/dev/null 2>&1; }; then
            die "$package 已安装但所需文件不可用；请检查文件完整性和 Klassy/KDecoration ABI，修复或重编译后重试"
        fi
        if pacman -Si "$package" >/dev/null 2>&1; then
            repo+=("$package")
        else
            case "$part" in
                klassy) aur+=(klassy) ;;
                bibata) aur+=(bibata-cursor-theme-bin) ;;
                *) die "当前仓库没有 $package，请先检查软件源" ;;
            esac
        fi
    done
    # 在任何包安装前检查所需 helper，避免执行到一半才发现无法继续。
    if ((${#aur[@]})); then
        for candidate in paru yay; do
            if command -v "$candidate" >/dev/null 2>&1; then helper=$candidate; break; fi
        done
        [[ -n "$helper" ]] || die "缺少 paru/yay；请先自行安装 AUR 包：${aur[*]}"
    fi
    if ((${#repo[@]})); then
        need sudo
        printf '安装缺少的仓库包并完整升级系统：%s\n' "${repo[*]}"
        sudo pacman -Syu --needed "${repo[@]}"
    fi
    if ((${#aur[@]})); then
        printf '通过 %s 安装缺少的 AUR 包并升级；请审阅 PKGBUILD：%s\n' "$helper" "${aur[*]}"
        "$helper" -Syu --needed "${aur[@]}"
    fi
    if selected colors; then
        if has_component colors; then
            printf '跳过已有配色：%s\n' "$SCHEME"
        else
            [[ -f "$SCRIPT_DIR/kde/$SCHEME.colors" ]] || die '缺少随仓库附带的 .colors 文件，请下载完整仓库'
            mkdir -p "$DATA_HOME/color-schemes"
            [[ ! -L "$DATA_HOME/color-schemes/$SCHEME.colors" ]] || die '配色目标是符号链接，拒绝覆盖'
            cp -p -- "$SCRIPT_DIR/kde/$SCHEME.colors" "$DATA_HOME/color-schemes/$SCHEME.colors"
        fi
    fi
    detect_plugins
    for part in "${COMPONENTS[@]}"; do
        has_component "$part" || die "安装后仍找不到可用的 $part；未应用任何主题配置"
    done
    printf '所选组件已齐全：%s\n' "${COMPONENTS[*]}"
}

check_config_files() {
    local file
    [[ ! -L "$CONFIG_HOME" ]] || die '配置目录是符号链接，请通过 dotfiles 工具管理'
    for file in "${FILES[@]}"; do
        [[ ! -L "$CONFIG_HOME/$file" ]] || die "$file 是符号链接，拒绝覆盖"
        [[ ! -e "$CONFIG_HOME/$file" || -f "$CONFIG_HOME/$file" ]] || die "$file 不是普通文件"
    done
}

backup_config() {
    umask 077
    mkdir -p "$STATE_HOME/backups"
    local directory file
    directory=$(mktemp -d "$STATE_HOME/backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
    for file in "${FILES[@]}"; do
        if [[ -f "$CONFIG_HOME/$file" ]]; then
            cp -p -- "$CONFIG_HOME/$file" "$directory/$file"
        else
            touch "$directory/$file.absent"
        fi
    done
    printf '%s\n' "${directory##*/}" > "$STATE_HOME/latest"
    printf '已备份：%s\n' "$directory"
}

write_setting() {
    local file=$1 group=$2 key=$3 value=$4
    if [[ "$(read_setting "$file" "$group" "$key" "${5:-}")" != "$value" ]]; then
        kwriteconfig6 --file "$CONFIG_HOME/$file" --group "$group" --key "$key" --notify "$value"
    fi
}

check_session() {
    [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* && "${KDE_SESSION_VERSION:-}" == 6 && "${XDG_SESSION_TYPE:-}" == wayland ]] ||
        die '请在 Plasma 6 Wayland 会话的终端内应用'
    need qdbus6
}

apply_config() {
    check_session
    local tool part file group key value fallback current
    for tool in kreadconfig6 kwriteconfig6; do need "$tool"; done
    if selected colors; then need plasma-apply-colorscheme; fi
    if selected breeze; then need plasma-apply-desktoptheme; fi
    if selected bibata; then need plasma-apply-cursortheme; fi
    for part in "${COMPONENTS[@]}"; do
        has_component "$part" || die "缺少可用的 $part，请先运行 --install；未修改配置"
    done
    check_config_files
    local changed=false recolor=false
    while IFS='|' read -r file group key value fallback; do
        current=$(read_setting "$file" "$group" "$key" "$fallback")
        if [[ "$current" != "$value" ]]; then
            printf '将设置 %s [%s] %s：%s → %s\n' "$file" "$group" "$key" "$current" "$value"
            changed=true
            [[ "$group" != General ]] || recolor=true
        fi
    done < <(targets)
    if ! "$changed"; then printf '所选配置已符合目标，跳过写入和备份。\n'; return; fi
    qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation >/dev/null
    backup_config
    trap 'printf "应用未完成。备份已保留，可运行 --restore 恢复；注销重登后刷新外观。\n" >&2' ERR
    mkdir -p "$CONFIG_HOME"
    if selected colors; then
        write_setting kdeglobals General accentColorFromWallpaper false false
        write_setting kdeglobals General AccentColor 0,0,0,0 0,0,0,0
        if [[ "$(read_setting kdeglobals General ColorScheme BreezeLight)" != "$SCHEME" ]]; then
            plasma-apply-colorscheme "$SCHEME"
        elif "$recolor"; then
            # KDE CLI 的 --accent-color 分支不切换配色，必须在正确配色上单独调用。
            plasma-apply-colorscheme --accent-color transparent
        fi
    fi
    if selected breeze && [[ "$(read_setting plasmarc Theme name default)" != default ]]; then
        plasma-apply-desktoptheme default
    fi
    if selected bibata && [[ "$(read_setting kcminputrc Mouse cursorTheme breeze_cursors)" != "$CURSOR" ]]; then
        local size
        size=$(read_setting kcminputrc Mouse cursorSize)
        plasma-apply-cursortheme "$CURSOR"
        # 部分版本的工具会重置尺寸；保留原设置（含未指定尺寸的情况）。
        if [[ -n "$size" ]]; then
            write_setting kcminputrc Mouse cursorSize "$size"
        else
            kwriteconfig6 --file "$CONFIG_HOME/kcminputrc" --group Mouse --key cursorSize --delete
        fi
    fi
    while IFS='|' read -r file group key value fallback; do
        write_setting "$file" "$group" "$key" "$value" "$fallback"
    done < <(targets)
    qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure
    while IFS='|' read -r file group key value fallback; do
        [[ "$(read_setting "$file" "$group" "$key" "$fallback")" == "$value" ]] || die "配置校验失败：$file [$group] $key；可运行 --restore"
    done < <(targets)
    trap - ERR
    printf '已应用：%s\n建议注销重登，让所有应用同步外观；不会自动重启桌面。\n' "${COMPONENTS[*]}"
}

restore_config() {
    check_config_files
    [[ -f "$STATE_HOME/latest" ]] || die '没有可恢复的备份'
    local id directory file
    read -r id < "$STATE_HOME/latest"
    [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-[a-zA-Z0-9]{6}$ ]] || die '备份索引无效'
    directory="$STATE_HOME/backups/$id"
    [[ -d "$directory" && ! -L "$directory" ]] || die '备份目录无效'
    for file in "${FILES[@]}"; do
        [[ ! -L "$directory/$file" && ( -f "$directory/$file" || -f "$directory/$file.absent" ) ]] || die "备份不完整：$file"
    done
    mkdir -p "$CONFIG_HOME"
    for file in "${FILES[@]}"; do
        if [[ -f "$directory/$file" ]]; then cp -p -- "$directory/$file" "$CONFIG_HOME/$file";
        else rm -f -- "$CONFIG_HOME/$file"; fi
    done
    printf '已恢复完整配置快照：%s\n请注销重登以刷新外观；已安装的主题包保留。\n' "$directory"
}

choose_components() {
    local index part status answer number invalid
    local -a numbers=() labels=('Breeze 应用与桌面样式' 'Klassy 窗口装饰' 'Catppuccin Mocha Pink 配色' 'Papirus-Dark 图标' 'Bibata 光标')
    printf '\n  选择组件\n  ────────────────────────────────────\n'
    for index in "${!ALL_COMPONENTS[@]}"; do
        part=${ALL_COMPONENTS[index]}
        if has_component "$part"; then status=已安装; else status=待安装; fi
        printf '  %s  %s · %s\n' "$((index + 1))" "${labels[index]}" "$status"
    done
    printf '\n  输入编号，空格分隔，如 2 3 4；0 返回\n'
    while true; do
        COMPONENTS=()
        IFS= read -r -p '  组件 › ' answer || return 0
        [[ -n "$answer" && "$answer" != 0 ]] || return 0
        read -r -a numbers <<< "$answer"
        invalid=false
        for number in "${numbers[@]}"; do
            case "$number" in
                [1-5]) part=${ALL_COMPONENTS[number - 1]}; if ! selected "$part"; then COMPONENTS+=("$part"); fi ;;
                *) invalid=true ;;
            esac
        done
        if ! "$invalid" && ((${#COMPONENTS[@]})); then return 0; fi
        printf '  请输入 1–5 的编号，或 0 返回。\n'
    done
}

menu() {
    local answer
    while true; do
        cat <<'EOF'

  KDE · 方案 A
  ────────────────────────────────────
  Breeze + Klassy · Mocha Pink

  1  一键安装并应用全部
  2  选择组件安装并应用
  3  查看当前状态
  4  恢复上次配置

  0  退出

EOF
        IFS= read -r -p '  选择 › ' answer || return 0
        case "$answer" in
            1) main --setup; return ;;
            2) choose_components
               if ((${#COMPONENTS[@]})); then main --setup "${COMPONENTS[@]}"; return; fi ;;
            3) main --diagnose; return ;;
            4) main --restore; return ;;
            0) return ;;
            *) printf '  请输入 0–4。\n' ;;
        esac
    done
}

main() {
    if (($# == 0)); then detect_plugins; menu; return; fi
    local action=$1 part
    shift
    case "$action" in
        --help|-h) usage; return ;;
        --diagnose) ;;
        --install|--apply|--setup|--restore) ((EUID != 0)) || die '请使用普通用户运行，不要 sudo 整个脚本' ;;
        *) die "未知参数：$action；请使用 --help" ;;
    esac
    COMPONENTS=("${ALL_COMPONENTS[@]}")
    if (($#)); then
        [[ "$action" != --restore ]] || die '--restore 不接受组件参数'
        COMPONENTS=()
        for part in "$@"; do
            case "$part" in breeze|klassy|colors|papirus|bibata) ;; *) die "未知组件：$part" ;; esac
            if ! selected "$part"; then COMPONENTS+=("$part"); fi
        done
    fi
    detect_plugins
    case "$action" in
        --diagnose) diagnose ;;
        --install) install_components ;;
        --apply) apply_config ;;
        --setup)
            check_session
            check_config_files
            qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation >/dev/null
            install_components
            apply_config
            ;;
        --restore) restore_config ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
