#!/bin/sh

VERSION="2.0.0"
SCRIPT_NAME="overlay.sh"
MIN_OPENWRT_MAJOR=25
MIN_OPENWRT_MINOR=12
MIN_FREE_SECTORS=2048
SUPPORTED_FS="ext2 ext3 ext4 f2fs"
LOCK_DIR="/tmp/overlay-expand.lock"

FORCE=0
ACTION="menu"
LOCK_HELD=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    ESC=$(printf '\033')
    GREEN="${ESC}[0;32m"
    RED="${ESC}[0;31m"
    YELLOW="${ESC}[1;33m"
    CYAN="${ESC}[0;36m"
    BOLD="${ESC}[1m"
    DIM="${ESC}[2m"
    NC="${ESC}[0m"
else
    GREEN="" RED="" YELLOW="" CYAN="" BOLD="" DIM="" NC=""
fi

info() { printf '%s[INFO]%s %s\n' "$GREEN" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[ERR ]%s %s\n' "$RED" "$NC" "$*" >&2; }
hr()   { printf '%s------------------------------------------------------------%s\n' "$DIM" "$NC"; }

usage() {
    cat <<EOF
用法: sh $SCRIPT_NAME [选项]
  -c, --check    只读诊断
  -e, --expand   扩容，执行前确认
  -y, --auto     自动扩容，不请求确认
      --force    忽略最低版本限制，安全检查仍不可跳过
  -V, --version  显示版本
  -h, --help     显示帮助
EOF
}

set_action() {
    if [ "$ACTION" != "menu" ] && [ "$ACTION" != "$1" ]; then
        err "一次只能指定一种操作"
        usage
        exit 2
    fi
    ACTION="$1"
}

parse_args() {
    for _ARG in "$@"; do
        case "$_ARG" in
            -c|--check)   set_action check ;;
            -e|--expand)  set_action expand ;;
            -y|--auto)    set_action auto ;;
            --force)      FORCE=1 ;;
            -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            -h|--help)    usage; exit 0 ;;
            *)            err "未知选项: $_ARG"; usage; exit 2 ;;
        esac
    done
}

read_uint() {
    _UINT=$(cat "$1" 2>/dev/null) || return 1
    case "$_UINT" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$_UINT"
}

sysfs_partition_from_mm() {
    [ -n "$1" ] || return 1
    _SYSFS=$(readlink -f "/sys/dev/block/$1" 2>/dev/null) || return 1
    [ -f "$_SYSFS/partition" ] || return 1
    printf '%s\n' "$_SYSFS"
}

find_root_partition() {
    # squashfs 固件优先以 /rom 的主次设备号定位 rootfs 分区。
    _ROOT_MM=$(awk '$5 == "/rom" {print $3; exit}' /proc/self/mountinfo 2>/dev/null)
    _ROOT_SYSFS=$(sysfs_partition_from_mm "$_ROOT_MM") && {
        printf '%s\n' "$_ROOT_SYSFS"
        return 0
    }

    # ext4 等直接根挂载布局可由 / 的主次设备号定位。
    _ROOT_MM=$(awk '$5 == "/" {print $3; exit}' /proc/self/mountinfo 2>/dev/null)
    _ROOT_SYSFS=$(sysfs_partition_from_mm "$_ROOT_MM") && {
        printf '%s\n' "$_ROOT_SYSFS"
        return 0
    }

    # /dev/root 常见于内核命令行指定根设备的布局。
    if [ -e /dev/root ]; then
        _ROOT_HEX=$(stat -c '%t:%T' /dev/root 2>/dev/null)
        case "$_ROOT_HEX" in
            *:*)
                _ROOT_MAJ=$((0x${_ROOT_HEX%:*}))
                _ROOT_MIN=$((0x${_ROOT_HEX#*:}))
                _ROOT_SYSFS=$(sysfs_partition_from_mm "$_ROOT_MAJ:$_ROOT_MIN") && {
                    printf '%s\n' "$_ROOT_SYSFS"
                    return 0
                }
                ;;
        esac
    fi

    # 最后尝试 mountinfo 分隔符后的真实挂载源。
    _ROOT_SOURCE=$(awk '$5 == "/" {
        for (i = 1; i <= NF; i++) {
            if ($i == "-") { print $(i + 2); exit }
        }
    }' /proc/self/mountinfo 2>/dev/null)
    case "$_ROOT_SOURCE" in
        /dev/*)
            _ROOT_NAME=${_ROOT_SOURCE##*/}
            _ROOT_SYSFS=$(readlink -f "/sys/class/block/$_ROOT_NAME" 2>/dev/null)
            if [ -f "$_ROOT_SYSFS/partition" ]; then
                printf '%s\n' "$_ROOT_SYSFS"
                return 0
            fi
            ;;
    esac
    return 1
}

probe_environment() {
    ROOT_SYSFS=$(find_root_partition) || return 1
    ROOT_PART_NAME=${ROOT_SYSFS##*/}
    ROOT_DISK_SYSFS=${ROOT_SYSFS%/*}
    ROOT_DISK_NAME=${ROOT_DISK_SYSFS##*/}
    ROOT_DEV="/dev/$ROOT_PART_NAME"
    ROOT_DISK="/dev/$ROOT_DISK_NAME"

    ROOT_PART_NUM=$(read_uint "/sys/class/block/$ROOT_PART_NAME/partition") || return 1
    DISK_SECTORS=$(read_uint "/sys/class/block/$ROOT_DISK_NAME/size") || return 1
    PART_START=$(read_uint "/sys/class/block/$ROOT_PART_NAME/start") || return 1
    PART_SECTORS=$(read_uint "/sys/class/block/$ROOT_PART_NAME/size") || return 1

    PART_END=$((PART_START + PART_SECTORS))
    [ "$DISK_SECTORS" -ge "$PART_END" ] || return 1
    FREE_SECTORS=$((DISK_SECTORS - PART_END))
    FREE_MIB=$((FREE_SECTORS / 2048))
    PART_MIB=$((PART_SECTORS / 2048))
    DISK_MIB=$((DISK_SECTORS / 2048))

    OVERLAY_SOURCE=$(awk '$2 == "/overlay" {print $1; exit}' /proc/mounts 2>/dev/null)
    OVERLAY_FS=$(awk '$2 == "/overlay" {print $3; exit}' /proc/mounts 2>/dev/null)
    case "$OVERLAY_SOURCE" in
        /dev/*) OVERLAY_DEV=$(readlink -f "$OVERLAY_SOURCE" 2>/dev/null) ;;
        *)      OVERLAY_DEV="" ;;
    esac
    RESIZE_DEV=${OVERLAY_DEV:-$ROOT_DEV}
    return 0
}

partition_is_last() {
    _LAST_SEEN_ROOT=0
    for _LAST_PATH in /sys/class/block/"$ROOT_DISK_NAME"/"$ROOT_DISK_NAME"*; do
        [ -f "$_LAST_PATH/partition" ] || continue
        _LAST_NAME=${_LAST_PATH##*/}
        _LAST_START=$(read_uint "$_LAST_PATH/start") || return 1
        if [ "$_LAST_NAME" = "$ROOT_PART_NAME" ]; then
            _LAST_SEEN_ROOT=1
        elif [ "$_LAST_START" -gt "$PART_START" ]; then
            return 1
        fi
    done
    [ "$_LAST_SEEN_ROOT" = "1" ]
}

read_openwrt_version() {
    if [ -f /etc/openwrt_release ]; then
        (. /etc/openwrt_release 2>/dev/null; printf '%s\n' "$DISTRIB_RELEASE")
    elif grep -qi openwrt /etc/os-release 2>/dev/null; then
        (. /etc/os-release 2>/dev/null; printf '%s\n' "$VERSION_ID")
    else
        return 1
    fi
}

version_is_supported() {
    _VER_MAJOR=$(printf '%s\n' "$1" | awk -F. '{print $1 + 0}')
    _VER_MINOR=$(printf '%s\n' "$1" | awk -F. '{print $2 + 0}')
    [ "$_VER_MAJOR" -gt "$MIN_OPENWRT_MAJOR" ] || {
        [ "$_VER_MAJOR" -eq "$MIN_OPENWRT_MAJOR" ] &&
        [ "$_VER_MINOR" -ge "$MIN_OPENWRT_MINOR" ]
    }
}

check_environment() {
    CHECK_ERRORS=0
    CHECK_WARNINGS=0
    info "兼容性与安全检查 v$VERSION"

    OPENWRT_VERSION=$(read_openwrt_version)
    if [ -n "$OPENWRT_VERSION" ]; then
        ok "系统: OpenWrt $OPENWRT_VERSION"
        if version_is_supported "$OPENWRT_VERSION"; then
            ok "版本满足 ${MIN_OPENWRT_MAJOR}.${MIN_OPENWRT_MINOR}+"
        elif [ "$FORCE" = "1" ]; then
            warn "版本低于 ${MIN_OPENWRT_MAJOR}.${MIN_OPENWRT_MINOR}，已由 --force 忽略"
            CHECK_WARNINGS=$((CHECK_WARNINGS + 1))
        else
            err "版本低于 ${MIN_OPENWRT_MAJOR}.${MIN_OPENWRT_MINOR}；确认兼容后可使用 --force"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
        fi
    else
        err "未检测到 OpenWrt"
        CHECK_ERRORS=$((CHECK_ERRORS + 1))
    fi

    if ! probe_environment; then
        err "无法可靠识别根磁盘、rootfs 分区或容量"
        CHECK_ERRORS=$((CHECK_ERRORS + 1))
        hr
        err "检查失败: $CHECK_ERRORS 项错误"
        return 1
    fi

    ok "根分区: $ROOT_DEV (#$ROOT_PART_NUM)，根磁盘: $ROOT_DISK"

    case "$ROOT_DISK_NAME" in
        mtdblock*|ubiblock*|ubi*)
            err "不支持 NAND/UBI 根设备: $ROOT_DISK_NAME"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
            ;;
        sd*|vd*|nvme*|hd*|xvd*|mmcblk*)
            ok "块设备类型受支持: $ROOT_DISK_NAME"
            ;;
        *)
            warn "未识别的块设备类型: $ROOT_DISK_NAME"
            CHECK_WARNINGS=$((CHECK_WARNINGS + 1))
            ;;
    esac

    if partition_is_last; then
        ok "$ROOT_PART_NAME 是磁盘上的最后一个分区"
    else
        err "无法确认 $ROOT_PART_NAME 为最后一个分区，拒绝扩展以免覆盖数据"
        CHECK_ERRORS=$((CHECK_ERRORS + 1))
    fi

    case " $SUPPORTED_FS " in
        *" $OVERLAY_FS "*) ok "overlay 文件系统: $OVERLAY_FS" ;;
        *)
            err "不支持的 overlay 文件系统: ${OVERLAY_FS:-未挂载}"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
            ;;
    esac

    case "$OVERLAY_DEV" in
        /dev/loop*) ok "overlay 设备: $OVERLAY_DEV" ;;
        "$ROOT_DEV") ok "overlay 直接位于 rootfs 分区" ;;
        /dev/*)
            err "检测到独立 overlay 分区 $OVERLAY_SOURCE，本工具不会扩展它"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
            ;;
        *)
            err "无法识别 overlay 块设备"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
            ;;
    esac

    if command -v apk >/dev/null 2>&1; then
        ok "apk 包管理器可用"
    else
        warn "apk 不可用；若缺少依赖，脚本将无法自动安装"
        CHECK_WARNINGS=$((CHECK_WARNINGS + 1))
    fi

    hr
    if [ "$CHECK_ERRORS" -gt 0 ]; then
        err "检查失败: $CHECK_ERRORS 项错误，$CHECK_WARNINGS 项警告"
        return 1
    fi
    if [ "$CHECK_WARNINGS" -gt 0 ]; then
        warn "检查通过: $CHECK_WARNINGS 项警告"
    else
        ok "检查全部通过"
    fi
    return 0
}

show_status() {
    probe_environment || {
        err "无法读取当前状态"
        return 1
    }
    printf '\n%s当前状态%s\n' "$BOLD" "$NC"
    printf '  根磁盘:       %s (%s MiB)\n' "$ROOT_DISK" "$DISK_MIB"
    printf '  rootfs 分区:  %s (#%s, %s MiB)\n' "$ROOT_DEV" "$ROOT_PART_NUM" "$PART_MIB"
    printf '  overlay:      %s (%s)\n' "${OVERLAY_SOURCE:-未知}" "${OVERLAY_FS:-未知}"
    printf '  可扩展空间:   %s MiB\n\n' "$FREE_MIB"
    df -h /overlay /rom / 2>/dev/null || df -h 2>/dev/null
}

require_root() {
    if [ "$(id -u)" != "0" ]; then
        err "扩容操作必须以 root 身份运行"
        return 1
    fi
}

required_dependencies() {
    REQUIRED_DEPS="parted:parted"
    case "$OVERLAY_DEV" in /dev/loop*) REQUIRED_DEPS="$REQUIRED_DEPS losetup:losetup" ;; esac
    case "$OVERLAY_FS" in
        f2fs)           REQUIRED_DEPS="$REQUIRED_DEPS f2fs-tools:resize.f2fs" ;;
        ext2|ext3|ext4) REQUIRED_DEPS="$REQUIRED_DEPS resize2fs:resize2fs" ;;
    esac
}

install_dependencies() {
    required_dependencies
    MISSING_PACKAGES=""
    for _DEP in $REQUIRED_DEPS; do
        _DEP_PACKAGE=${_DEP%%:*}
        _DEP_COMMAND=${_DEP#*:}
        if command -v "$_DEP_COMMAND" >/dev/null 2>&1; then
            ok "依赖已存在: $_DEP_COMMAND"
        else
            MISSING_PACKAGES="$MISSING_PACKAGES $_DEP_PACKAGE"
        fi
    done

    [ -n "$MISSING_PACKAGES" ] || return 0
    command -v apk >/dev/null 2>&1 || {
        err "缺少依赖:$MISSING_PACKAGES，且 apk 不可用"
        return 1
    }

    info "更新 apk 索引"
    apk update || warn "索引更新失败，将尝试使用现有索引"
    info "安装依赖:$MISSING_PACKAGES"
    # 包名由上面的固定映射生成，可安全进行单词拆分。
    apk add $MISSING_PACKAGES || return 1

    for _DEP in $REQUIRED_DEPS; do
        _DEP_COMMAND=${_DEP#*:}
        command -v "$_DEP_COMMAND" >/dev/null 2>&1 || {
            err "安装后仍找不到命令: $_DEP_COMMAND"
            return 1
        }
    done
    return 0
}

acquire_lock() {
    if mkdir -m 700 "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=1
        trap 'release_lock' 0
        trap 'exit 130' HUP INT TERM
        return 0
    fi
    err "已有扩容任务在运行，或存在遗留锁: $LOCK_DIR"
    return 1
}

release_lock() {
    if [ "$LOCK_HELD" = "1" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
}

clear_lock_traps() {
    release_lock
    trap - 0 HUP INT TERM
}

expand_partition() {
    probe_environment || return 1
    partition_is_last || {
        err "写入前安全检查失败: rootfs 不是最后一个分区"
        return 1
    }
    [ "$FREE_SECTORS" -ge "$MIN_FREE_SECTORS" ] || {
        info "rootfs 分区已到磁盘末尾"
        return 0
    }

    OLD_PART_SECTORS=$PART_SECTORS
    info "扩展 $ROOT_DEV 到 $ROOT_DISK 末尾"
    parted -f -s "$ROOT_DISK" resizepart "$ROOT_PART_NUM" 100% || {
        err "parted 扩展分区失败"
        return 1
    }

    partprobe "$ROOT_DISK" 2>/dev/null || partx -u "$ROOT_DISK" 2>/dev/null || true
    for _RETRY in 1 2 3; do
        probe_environment || return 1
        if [ "$PART_SECTORS" -gt "$OLD_PART_SECTORS" ]; then
            ok "内核已识别新的分区容量"
            return 0
        fi
        sleep 1
    done

    warn "磁盘分区表已更新，但内核仍使用旧容量"
    warn "请重启后再次运行: sh $SCRIPT_NAME --expand"
    return 3
}

resize_overlay() {
    probe_environment || return 1
    case "$OVERLAY_DEV" in
        /dev/loop*)
            info "刷新 loop 设备容量: $OVERLAY_DEV"
            losetup -c "$OVERLAY_DEV" || {
                err "无法刷新 loop 设备，请重启后重试"
                return 3
            }
            ;;
        "$ROOT_DEV") ;;
        *)
            err "写入前检查失败: overlay 设备已变化"
            return 1
            ;;
    esac

    case "$OVERLAY_FS" in
        f2fs)
            info "在线扩展 f2fs: $RESIZE_DEV"
            resize.f2fs "$RESIZE_DEV" || return 1
            ;;
        ext2|ext3|ext4)
            info "在线扩展 $OVERLAY_FS: $RESIZE_DEV"
            resize2fs "$RESIZE_DEV" || return 1
            ;;
        *)
            err "不支持的 overlay 文件系统: $OVERLAY_FS"
            return 1
            ;;
    esac
    ok "overlay 文件系统容量已同步"
    return 0
}

confirm_expand() {
    [ -t 0 ] || {
        err "当前没有交互输入；请在终端运行，或明确使用 --auto"
        return 2
    }
    printf '\n%s即将安装必要依赖，并扩展 %s 与 %s。%s\n' "$YELLOW" "$ROOT_DEV" "$OVERLAY_FS" "$NC"
    warn "分区操作有风险，请先备份重要配置。"
    printf '确认继续? [y/N]: '
    read CONFIRM_VALUE || return 2
    case "$CONFIRM_VALUE" in
        y|Y|yes|YES) return 0 ;;
        *) info "已取消"; return 1 ;;
    esac
}

run_expand() {
    EXPAND_AUTO="$1"
    require_root || return 1
    check_environment || {
        err "环境检查未通过，未执行任何修改"
        return 1
    }
    show_status || return 1

    if [ "$EXPAND_AUTO" != "1" ]; then
        confirm_expand
        CONFIRM_RC=$?
        [ "$CONFIRM_RC" -eq 0 ] || {
            [ "$CONFIRM_RC" -eq 1 ] && return 0
            return "$CONFIRM_RC"
        }
    fi

    acquire_lock || return 1
    EXPAND_RC=0
    install_dependencies || EXPAND_RC=1
    if [ "$EXPAND_RC" -eq 0 ]; then
        expand_partition
        EXPAND_RC=$?
    fi
    if [ "$EXPAND_RC" -eq 0 ]; then
        resize_overlay
        EXPAND_RC=$?
    fi
    clear_lock_traps

    if [ "$EXPAND_RC" -eq 0 ]; then
        show_status
        ok "扩容流程完成"
    elif [ "$EXPAND_RC" -eq 3 ]; then
        warn "需要重启设备后再次运行脚本以完成扩容"
    else
        err "扩容失败；请根据上方错误排查，分区写入后不要强制断电"
    fi
    return "$EXPAND_RC"
}

pause_menu() {
    printf '\n%s按 Enter 返回菜单...%s' "$DIM" "$NC"
    read MENU_PAUSE || return 1
}

print_menu() {
    if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
        clear
    fi
    printf '%s%sOpenWrt Overlay 扩容工具%s  %sv%s%s\n' "$CYAN" "$BOLD" "$NC" "$DIM" "$VERSION" "$NC"
    hr
    if probe_environment; then
        printf '  根磁盘: %s   rootfs: %s (#%s)\n' "$ROOT_DISK" "$ROOT_DEV" "$ROOT_PART_NUM"
        printf '  overlay: %s (%s)   可扩展: %s MiB\n' "${OVERLAY_SOURCE:-未知}" "${OVERLAY_FS:-未知}" "$FREE_MIB"
    else
        warn "当前环境无法识别，请先运行诊断"
    fi
    [ "$FORCE" = "1" ] && warn "--force 已启用，仅忽略最低版本限制"
    hr
    printf '  %s1%s) 只读诊断\n' "$GREEN" "$NC"
    printf '  %s2%s) 安全扩容（执行前确认）\n' "$GREEN" "$NC"
    printf '  %s0%s) 退出\n\n' "$RED" "$NC"
    printf '请选择 [0-2]: '
}

run_menu() {
    [ -t 0 ] || {
        err "无交互终端，请使用 --check、--expand 或 --auto"
        return 2
    }
    while true; do
        print_menu
        read MENU_CHOICE || return 0
        printf '\n'
        case "$MENU_CHOICE" in
            1) check_environment; show_status; pause_menu || return 0 ;;
            2) run_expand 0; pause_menu || return 0 ;;
            0) info "已退出"; return 0 ;;
            *) warn "无效选项: $MENU_CHOICE"; pause_menu || return 0 ;;
        esac
    done
}

main() {
    parse_args "$@"
    case "$ACTION" in
        check)  check_environment; CHECK_RC=$?; show_status; return "$CHECK_RC" ;;
        expand) run_expand 0 ;;
        auto)   run_expand 1 ;;
        menu)   run_menu ;;
    esac
}

main "$@"
exit $?
