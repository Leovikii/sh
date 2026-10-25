#!/usr/bin/env bash
# CachyOS / Arch 用户级字体设置。普通用户运行，不要 sudo 整个脚本。
set -euo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/cachyos-fonts"
CONFIG_FILE="$CONFIG_HOME/fontconfig/conf.d/60-cachyos-fonts.conf"
UI_FONT='Sarasa UI SC'
MONO_FONT='Sarasa Term SC'
RGBA=none
FONT_SIZE=11

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1"; }

usage() {
    cat <<'EOF'
用法：bash font_setup.sh [操作] [选项]
  --diagnose       只读检查字体匹配、渲染设置和配置来源
  --install        官方仓库安装字体（sudo pacman -Syu，包含系统升级）
  --apply          备份后应用用户级 Fontconfig，KDE 下同步桌面字体
  --restore        恢复最近应用前的配置（包括整个 kdeglobals 快照）
  --print-config   仅向标准输出生成 XML，便于预览与测试
  --rgba none|rgb|bgr|vrgb|vbgr    默认 none（灰度抗锯齿）
  --size 9..18      KDE 字号，默认 11pt
  --help           显示帮助；无操作参数时进入菜单
建议：4K / 150% 先用 sarasa + none；RGB/BGR 仅在确认面板排列后试用。
EOF
}

validate_options() {
    case "$RGBA" in none|rgb|bgr|vrgb|vbgr) ;; *) die '无效的 rgba' ;; esac
    [[ "$FONT_SIZE" =~ ^(9|1[0-8])$ ]] || die '字号必须是 9..18 的整数'
}

install_fonts() {
    need pacman; need sudo; need fc-cache
    printf '将更新系统并安装官方字体包；pacman 会显示清单并询问确认。\n'
    # Arch 不支持局部升级；不使用 -Sy，也不需要 AUR helper。
    sudo pacman -Syu --needed ttf-sarasa-gothic noto-fonts-cjk noto-fonts-emoji
    fc-cache -f
    printf '字体安装完成。\n'
}

has_family() {
    # fc-match 会回退到其他字体，不能用它判断字体是否已安装。
    fc-list -f '%{family}\n' | tr ',' '\n' | awk -v family="$1" '
        $0 == family { found=1 } END { exit !found }'
}

print_config() {
    cat <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <!-- Managed by sh/cachyos/font_setup.sh -->
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>$RGBA</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
  </match>
  <!-- 只关闭轮廓字体的内嵌位图，保留 Noto Color Emoji 等位图彩色字体。 -->
  <match target="font">
    <test name="outline"><bool>true</bool></test>
    <edit name="embeddedbitmap" mode="assign"><bool>false</bool></edit>
  </match>

EOF
    # 仅针对泛型请求选择地区字形，保留明确指定的字体。
    local lang region sarasa_region generic family
    for lang in zh-tw zh-hk ja ko; do
        case "$lang" in zh-tw) region=TC ;; zh-hk) region=HK ;; ja) region=JP ;; ko) region=KR ;; esac
        case "$lang" in zh-tw) sarasa_region=TC ;; zh-hk) sarasa_region=HC ;; ja) sarasa_region=J ;; ko) sarasa_region=K ;; esac
        for generic in sans-serif serif monospace; do
            case "$generic" in
                sans-serif) family="Sarasa UI $sarasa_region" ;;
                serif) family="Noto Serif CJK $region" ;;
                monospace) family="Sarasa Term $sarasa_region" ;;
            esac
            cat <<EOF
  <match target="pattern">
    <test name="family" qual="any"><string>$generic</string></test>
    <test name="lang" compare="contains"><string>$lang</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>$family</string></edit>
  </match>
EOF
        done
    done
    cat <<EOF
  <alias binding="strong">
    <family>sans-serif</family>
    <prefer><family>$UI_FONT</family><family>Noto Sans CJK SC</family><family>Noto Sans</family></prefer>
  </alias>
  <alias binding="strong">
    <family>serif</family>
    <prefer><family>Noto Serif CJK SC</family><family>Noto Serif</family></prefer>
  </alias>
  <alias binding="strong">
    <family>monospace</family>
    <prefer><family>$MONO_FONT</family><family>Noto Sans Mono CJK SC</family><family>Noto Sans Mono</family></prefer>
  </alias>
  <alias binding="strong">
    <family>emoji</family><prefer><family>Noto Color Emoji</family></prefer>
  </alias>
</fontconfig>
EOF
}

diagnose() {
    need fc-match; need fc-conflist
    printf '会话：%s / %s\n' "${XDG_CURRENT_DESKTOP:-未知}" "${XDG_SESSION_TYPE:-未知}"
    if command -v pacman >/dev/null 2>&1; then
        pacman -Q fontconfig freetype2 plasma-workspace noto-fonts-cjk noto-fonts-emoji ttf-sarasa-gothic 2>/dev/null || true
    fi
    local pattern
    for pattern in 'sans-serif:lang=en:charset=41' 'monospace:lang=en:charset=41' \
        'sans-serif:lang=zh-cn' 'serif:lang=zh-cn' 'monospace:lang=zh-cn' \
        'sans-serif:lang=zh-tw' 'sans-serif:lang=zh-hk' 'sans-serif:lang=ja' 'sans-serif:lang=ko' \
        'sans-serif:charset=4e2d' 'serif:charset=4e2d' 'monospace:charset=4e2d' 'emoji:charset=1f600'; do
        printf '%s -> ' "$pattern"
        fc-match -f '%{family} | %{style}\n' "$pattern"
    done
    printf '\n渲染值：hintstyle 1=slight；rgba 1=rgb、2=bgr、5=none\n'
    fc-match -f '%{family}: antialias=%{antialias} hinting=%{hinting} hintstyle=%{hintstyle} rgba=%{rgba} embeddedbitmap=%{embeddedbitmap}\n' 'sans-serif:lang=zh-cn'
    printf '\n已加载配置：\n'
    fc-conflist | awk '/^\+ /'
    if [[ -f "$CONFIG_HOME/fontconfig/fonts.conf" || -f "$HOME/.fonts.conf" ]]; then
        printf '\n注意：已有 fonts.conf，可能覆盖本脚本的独立配置，请检查重复规则。\n'
    fi
    if [[ -n "${FREETYPE_PROPERTIES:-}" ]]; then
        printf '\nFREETYPE_PROPERTIES=%s\n' "$FREETYPE_PROPERTIES"
    fi
    printf '\n缩放请在 KDE 显示设置或 kscreen-doctor -o 中确认；Xwayland Scale 不等于所有输出的缩放。\n'
}

backup_config() {
    mkdir -p "$STATE_HOME/backups"
    BACKUP_DIR=$(mktemp -d "$STATE_HOME/backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
    local relative
    for relative in fontconfig/conf.d/60-cachyos-fonts.conf kdeglobals; do
        mkdir -p "$BACKUP_DIR/$(dirname "$relative")"
        if [[ -e "$CONFIG_HOME/$relative" || -L "$CONFIG_HOME/$relative" ]]; then
            cp -a -- "$CONFIG_HOME/$relative" "$BACKUP_DIR/$relative"
        else
            touch "$BACKUP_DIR/$relative.absent"
        fi
    done
    printf '%s\n' "$BACKUP_DIR" > "$STATE_HOME/latest"
    printf '已备份：%s\n' "$BACKUP_DIR"
}

apply_config() {
    need fc-list; need fc-cache; need fc-match; need fc-conflist
    local family kde=false
    for family in "$UI_FONT" "$MONO_FONT" 'Noto Serif CJK SC' 'Noto Color Emoji'; do
        has_family "$family" || die "缺少字体 $family，请先执行 --install"
    done
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]; then need kwriteconfig6; kde=true; fi
    if "$kde" && [[ -L "$CONFIG_HOME/kdeglobals" ]]; then
        die 'kdeglobals 是符号链接，请通过 dotfiles 管理工具调整 KDE 字体；可用 --print-config 获取 Fontconfig 配置'
    fi
    backup_config
    mkdir -p "$(dirname "$CONFIG_FILE")"
    # 同目录临时文件再重命名，不截断已有文件或跟随其符号链接。
    local temporary
    temporary=$(mktemp "$(dirname "$CONFIG_FILE")/.font-setup-XXXXXX")
    print_config > "$temporary"
    mv -f -- "$temporary" "$CONFIG_FILE"
    if "$kde"; then
        local key font="$UI_FONT,$FONT_SIZE,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
        for key in font menuFont toolBarFont; do
            kwriteconfig6 --file "$CONFIG_HOME/kdeglobals" --group General --key "$key" "$font"
        done
        kwriteconfig6 --file "$CONFIG_HOME/kdeglobals" --group General --key fixed "$MONO_FONT,$FONT_SIZE,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
        kwriteconfig6 --file "$CONFIG_HOME/kdeglobals" --group General --key smallestReadableFont "$UI_FONT,$((FONT_SIZE-2)),-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
        kwriteconfig6 --file "$CONFIG_HOME/kdeglobals" --group WM --key activeFont "$font"
        # KDE 上游 FontAASettingsStore::save() 使用这些键，不带连字符。
        kwriteconfig6 --file "$CONFIG_HOME/kdeglobals" --group General --key XftAntialias --type bool true
        kwriteconfig6 --file "$CONFIG_HOME/kdeglobals" --group General --key XftHintStyle hintslight
        kwriteconfig6 --file "$CONFIG_HOME/kdeglobals" --group General --key XftSubPixel "$RGBA"
    fi
    fc-cache -f
    printf '已应用更纱 / %s / %spt。请注销并重新登录，再比较测试页。\n' "$RGBA" "$FONT_SIZE"
    printf '可用 --restore 回退（含整个 kdeglobals）；应用显式字体需在各自设置中调整。\n'
    diagnose
}

restore_config() {
    need fc-cache
    [[ -f "$STATE_HOME/latest" ]] || die '没有可恢复的备份'
    local backup relative
    IFS= read -r backup < "$STATE_HOME/latest"
    [[ -d "$backup" && "$backup" == "$STATE_HOME/backups/"* ]] || die '无效的备份路径'
    for relative in fontconfig/conf.d/60-cachyos-fonts.conf kdeglobals; do
        [[ -e "$backup/$relative" || -L "$backup/$relative" || -f "$backup/$relative.absent" ]] || die "备份不完整：$relative"
    done
    for relative in fontconfig/conf.d/60-cachyos-fonts.conf kdeglobals; do
        if [[ -f "$backup/$relative.absent" ]]; then
            rm -f -- "$CONFIG_HOME/$relative"
        else
            mkdir -p "$CONFIG_HOME/$(dirname "$relative")"
            cp -a --remove-destination -- "$backup/$relative" "$CONFIG_HOME/$relative"
        fi
    done
    fc-cache -f
    printf '已从 %s 恢复，请注销并重新登录。kdeglobals 已恢复为应用前的完整快照。\n' "$backup"
}

menu() {
    local option action status
    while true; do
        printf '\n字体设置（更纱 / %s / %spt）\n1. 只读诊断\n2. 安装字体\n3. 应用配置\n4. 恢复最近备份（含整个 kdeglobals）\n0. 退出\n' "$RGBA" "$FONT_SIZE"
        read -r -p '选择 [0-4]: ' option || return 0
        case "$option" in
            1|2|3|4)
                case "$option" in 1) action=diagnose ;; 2) action=install_fonts ;; 3) action=apply_config ;; 4) action=restore_config ;; esac
                # 不将函数放进 if/||，以免 Bash 隐式禁用函数内的 errexit。
                set +e
                (set -e; "$action")
                status=$?
                set -e
                [[ "$status" -eq 0 ]] || printf '操作未完成（退出码 %s），请检查以上错误。\n' "$status" >&2
                ;;
            0) return 0 ;;
            *) printf '无效选项。\n' ;;
        esac
    done
}

main() {
    local action=menu selected=false
    while (($#)); do
        case "$1" in
            --diagnose|--install|--apply|--restore|--print-config)
                [[ "$selected" == false ]] || die '一次只能指定一个操作'
                selected=true
                case "$1" in --diagnose) action=diagnose ;; --install) action=install_fonts ;; --apply) action=apply_config ;; --restore) action=restore_config ;; --print-config) action=print_config ;; esac
                shift ;;
            --rgba|--size)
                (($# >= 2)) || die "$1 缺少值"
                case "$1" in --rgba) RGBA=$2 ;; --size) FONT_SIZE=$2 ;; esac
                shift 2 ;;
            --help|-h) usage; return 0 ;;
            *) die "未知参数：$1" ;;
        esac
    done
    validate_options
    if [[ "$action" != diagnose && "$action" != print_config && "$EUID" -eq 0 ]]; then
        die '请用桌面普通用户运行，安装时脚本会单独调用 sudo'
    fi
    "$action"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
