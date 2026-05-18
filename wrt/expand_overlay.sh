#!/bin/sh
# =========================================================
# 脚本: expand_overlay.sh
# 功能: 在 OpenWrt 设备上在线扩容 rootfs/overlay 分区到磁盘剩余空间
# 适用: OpenWrt 25.12+ (apk 包管理器), x86 squashfs / ext4 / f2fs overlay
# 用法: 直接运行进入交互菜单, 或:
#   sh expand_overlay.sh --check    一键诊断
#   sh expand_overlay.sh --expand   一键扩容(含确认)
#   sh expand_overlay.sh --auto     一键扩容(无确认)
#   sh expand_overlay.sh --version  显示版本
#   sh expand_overlay.sh --force    跳过兼容性硬阻断
# =========================================================

VERSION="1.3.0"
SCRIPT_NAME="expand_overlay.sh"

MIN_OPENWRT_MAJOR=25
MIN_OPENWRT_MINOR=12
SUPPORTED_FS="ext2 ext3 ext4 f2fs"
SUPPORTED_DISK_PREFIX="sd vd nvme hd xvd"
INCOMPAT_DISK_PREFIX="mtdblock ubiblock ubi"

# ---------- 颜色 / 输出辅助 ----------
# 用真正的 ESC 字节填充变量, heredoc(cat <<EOF) 才能正确显示颜色
ESC=$(printf '\033')
GREEN="${ESC}[0;32m"; RED="${ESC}[0;31m"; YELLOW="${ESC}[1;33m"
CYAN="${ESC}[0;36m";  BLUE="${ESC}[0;34m"
BOLD="${ESC}[1m";     DIM="${ESC}[2m";    NC="${ESC}[0m"

info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()   { printf "${RED}[ERR ]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
hr()    { printf "${DIM}------------------------------------------------------------${NC}\n"; }
pause() { printf "\n${DIM}按 Enter 返回菜单...${NC}"; read _DUMMY; }
clr()   { command -v clear >/dev/null 2>&1 && clear || printf '\n\n'; }

# ---------- 全局状态 (由 detect_env 填充) ----------
ROOT_DISK=""; ROOT_DISK_NAME=""
ROOT_DEV="";  ROOT_PART_NAME=""; ROOT_PART_NUM=""
LOOP_DEV="";  OVERLAY_FS=""
DISK_SECTORS=0; PART_START=0; PART_SECTORS=0
FREE_SECTORS=0; FREE_MB=0
COMPAT_OK=0
ENV_OK=0
FORCE=0

# ---------- 参数解析 (支持 one-shot 模式) ----------
ONE_SHOT=""
for arg in "$@"; do
    case "$arg" in
        --check|-c)   ONE_SHOT="check" ;;
        --expand|-e)  ONE_SHOT="expand" ;;
        --auto|-y)    ONE_SHOT="auto"  ;;
        --force)      FORCE=1 ;;
        --version|-V) printf "%s %s\n" "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
        -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    esac
done

[ "$(id -u)" = "0" ] || { err "请用 root 运行"; exit 1; }

# =========================================================
# 通用: 定位 rootfs 分区的 sysfs 路径
# 优先级: /rom 的 mountinfo > /dev/root 的 mountinfo > stat /dev/root
# 输出: 完整 sysfs 路径 (如 /sys/devices/.../block/sda/sda2), 失败为空
# =========================================================
find_root_blk() {
    _BLK=""

    # 方法 1: /rom 是 squashfs 的挂载点, 必然指向 rootfs 分区, 最可靠
    _MM=$(awk '$5 == "/rom" {print $3; exit}' /proc/self/mountinfo 2>/dev/null)
    if [ -n "$_MM" ]; then
        _BLK=$(readlink -f "/sys/dev/block/$_MM" 2>/dev/null)
    fi

    # 方法 2: mountinfo 里直接找 /dev/root 行
    if [ -z "$_BLK" ] || [ ! -e "$_BLK" ]; then
        _MM=$(awk '$1 == "/dev/root" {print $3; exit}' /proc/self/mountinfo 2>/dev/null)
        if [ -n "$_MM" ]; then
            _BLK=$(readlink -f "/sys/dev/block/$_MM" 2>/dev/null)
        fi
    fi

    # 方法 3: stat /dev/root
    if { [ -z "$_BLK" ] || [ ! -e "$_BLK" ]; } && [ -e /dev/root ]; then
        _RDEV=$(stat -c '%t:%T' /dev/root 2>/dev/null)
        if [ -n "$_RDEV" ]; then
            _MAJ=$((0x${_RDEV%:*}))
            _MIN=$((0x${_RDEV#*:}))
            _BLK=$(readlink -f "/sys/dev/block/$_MAJ:$_MIN" 2>/dev/null)
        fi
    fi

    # 方法 4: 从 / 挂载源直接 basename (兜底, 对 overlayfs:/ 无效)
    if [ -z "$_BLK" ] || [ ! -e "$_BLK" ]; then
        _R_SRC=$(awk '$2 == "/" {print $1; exit}' /proc/mounts 2>/dev/null)
        case "$_R_SRC" in
            /dev/*)
                _BLK=$(readlink -f "/sys/class/block/$(basename "$_R_SRC")" 2>/dev/null)
                ;;
        esac
    fi

    # 校验: 必须是真正的分区 (有 partition 文件) 或块设备节点
    if [ -n "$_BLK" ] && [ -e "$_BLK" ] && [ -e "$_BLK/partition" ]; then
        printf '%s\n' "$_BLK"
        return 0
    fi
    return 1
}

# =========================================================
# 1) 兼容性自检
# =========================================================
compat_check() {
    info "==== 兼容性自检 v$VERSION ===="
    HARD_FAIL=0
    SOFT_WARN=0

    OW_VER=""
    if [ -f /etc/openwrt_release ]; then
        OW_VER=$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_RELEASE")
        ok "系统: OpenWrt $OW_VER"
    elif grep -qi openwrt /etc/os-release 2>/dev/null; then
        OW_VER=$(. /etc/os-release 2>/dev/null; echo "$VERSION_ID")
        ok "系统: OpenWrt (os-release) $OW_VER"
    else
        err "非 OpenWrt 系统，本脚本仅适用于 OpenWrt 25.12+"
        HARD_FAIL=$((HARD_FAIL+1))
    fi

    if [ -n "$OW_VER" ]; then
        OW_MAJ=$(echo "$OW_VER" | awk -F. '{print $1+0}')
        OW_MIN=$(echo "$OW_VER" | awk -F. '{print $2+0}')
        if [ "$OW_MAJ" -gt "$MIN_OPENWRT_MAJOR" ] 2>/dev/null \
           || { [ "$OW_MAJ" -eq "$MIN_OPENWRT_MAJOR" ] && [ "$OW_MIN" -ge "$MIN_OPENWRT_MINOR" ]; } 2>/dev/null; then
            ok "OpenWrt 版本 $OW_VER >= ${MIN_OPENWRT_MAJOR}.${MIN_OPENWRT_MINOR}"
        else
            err "OpenWrt 版本 $OW_VER 低于 ${MIN_OPENWRT_MAJOR}.${MIN_OPENWRT_MINOR}"
            HARD_FAIL=$((HARD_FAIL+1))
        fi
    fi

    if command -v apk >/dev/null 2>&1; then
        ok "apk 包管理器: $(apk --version 2>/dev/null | head -n1)"
    else
        err "未找到 apk 命令 (本脚本仅支持 OpenWrt 25.12+ 的 apk 体系)"
        HARD_FAIL=$((HARD_FAIL+1))
    fi

    R_SRC=$(awk '$2 == "/" {print $1; exit}' /proc/mounts)
    if [ -z "$R_SRC" ]; then
        err "无法识别 / 挂载源"
        HARD_FAIL=$((HARD_FAIL+1))
    else
        ok "根挂载源: $R_SRC"
    fi

    OV_LINE=$(awk '$2 == "/overlay" {print; exit}' /proc/mounts)
    if [ -z "$OV_LINE" ]; then
        err "未挂载 /overlay (本脚本针对 squashfs+overlay 布局)"
        HARD_FAIL=$((HARD_FAIL+1))
    else
        ok "/overlay: $(echo "$OV_LINE" | awk '{print $1, $3}')"
    fi

    OV_FS=$(echo "$OV_LINE" | awk '{print $3}')
    if [ -n "$OV_FS" ]; then
        FS_OK=0
        for f in $SUPPORTED_FS; do
            [ "$OV_FS" = "$f" ] && FS_OK=1
        done
        if [ "$FS_OK" = "1" ]; then
            ok "overlay 文件系统: $OV_FS"
        else
            err "overlay 文件系统 $OV_FS 不在支持列表 ($SUPPORTED_FS)"
            HARD_FAIL=$((HARD_FAIL+1))
        fi
    fi

    R_BLK=$(find_root_blk)
    if [ -z "$R_BLK" ] || [ ! -e "$R_BLK" ]; then
        err "无法定位 sysfs 根分区节点"
        HARD_FAIL=$((HARD_FAIL+1))
    else
        D_NAME=$(basename "${R_BLK%/*}")
        P_NAME=$(basename "$R_BLK")
        ok "根盘 sysfs: $D_NAME (分区 $P_NAME)"
        for bad in $INCOMPAT_DISK_PREFIX; do
            case "$D_NAME" in
                ${bad}*)
                    err "根盘 $D_NAME 是 NAND/UBI 类设备，本脚本不支持"
                    HARD_FAIL=$((HARD_FAIL+1))
                    ;;
            esac
        done
        DISK_OK=0
        for okp in $SUPPORTED_DISK_PREFIX; do
            case "$D_NAME" in
                ${okp}*) DISK_OK=1 ;;
            esac
        done
        if [ "$DISK_OK" = "0" ]; then
            warn "根盘前缀 $D_NAME 不在常见列表 ($SUPPORTED_DISK_PREFIX)"
            SOFT_WARN=$((SOFT_WARN+1))
        fi
        if [ ! -r "/sys/class/block/$D_NAME/size" ]; then
            err "无法读取 /sys/class/block/$D_NAME/size"
            HARD_FAIL=$((HARD_FAIL+1))
        fi
    fi

    command -v parted >/dev/null 2>&1 || {
        warn "未安装 parted，扩容时会通过 apk 自动安装"
        SOFT_WARN=$((SOFT_WARN+1))
    }

    echo
    if [ "$HARD_FAIL" -gt 0 ]; then
        err "兼容性检查未通过: $HARD_FAIL 项硬阻断, $SOFT_WARN 项警告"
        if [ "$FORCE" = "1" ]; then
            warn "--force 已指定，强行继续"
            COMPAT_OK=1; return 0
        fi
        COMPAT_OK=0; return 1
    fi
    if [ "$SOFT_WARN" -gt 0 ]; then
        warn "兼容性检查通过，但有 $SOFT_WARN 项警告"
    else
        info "兼容性检查全部通过"
    fi
    COMPAT_OK=1
    return 0
}

# =========================================================
# 2) 环境探测 (识别根盘/分区/loop/fs)
# =========================================================
detect_env() {
    R_BLK=$(find_root_blk)
    if [ -z "$R_BLK" ]; then
        err "无法定位根分区 sysfs 节点"
        ENV_OK=0
        return 1
    fi

    ROOT_PART_NAME="${R_BLK##*/}"
    ROOT_DISK_NAME=$(basename "${R_BLK%/*}")
    ROOT_DISK="/dev/$ROOT_DISK_NAME"
    ROOT_DEV="/dev/$ROOT_PART_NAME"
    ROOT_PART_NUM=$(cat "/sys/class/block/$ROOT_PART_NAME/partition" 2>/dev/null || echo "?")

    LOOP_DEV=$(awk '$1 ~ "^/dev/loop" && $2 == "/overlay" {print $1; exit}' /proc/mounts)
    OVERLAY_FS=$(awk '$2 == "/overlay" {print $3; exit}' /proc/mounts)

    DISK_SECTORS=$(cat "/sys/class/block/$ROOT_DISK_NAME/size" 2>/dev/null || echo 0)
    PART_START=$(cat "/sys/class/block/$ROOT_PART_NAME/start" 2>/dev/null || echo 0)
    PART_SECTORS=$(cat "/sys/class/block/$ROOT_PART_NAME/size" 2>/dev/null || echo 0)
    END_USED=$((PART_START + PART_SECTORS))
    FREE_SECTORS=$((DISK_SECTORS - END_USED))
    [ "$FREE_SECTORS" -lt 0 ] && FREE_SECTORS=0
    FREE_MB=$((FREE_SECTORS / 2048))
    ENV_OK=1
    return 0
}

# =========================================================
# 3) 显示当前状态
# =========================================================
show_status() {
    detect_env || return 1
    info "==== 当前挂载与容量 ===="
    df -hT 2>/dev/null | grep -E "Filesystem|/rom|/overlay|/$|tmpfs" || df -h
    echo
    info "==== 识别结果 ===="
    printf "  整盘:         ${BOLD}%s${NC}\n" "$ROOT_DISK"
    printf "  rootfs 分区:  ${BOLD}%s${NC} (#%s)\n" "$ROOT_DEV" "$ROOT_PART_NUM"
    printf "  overlay 设备: ${BOLD}%s${NC}\n" "${LOOP_DEV:-(无 loop)}"
    printf "  overlay fs:   ${BOLD}%s${NC}\n" "${OVERLAY_FS:-未知}"
    echo
    info "==== 当前分区表 ===="
    if command -v parted >/dev/null 2>&1; then
        parted -s "$ROOT_DISK" unit MiB print free 2>/dev/null || cat /proc/partitions
    else
        cat /proc/partitions
        warn "未安装 parted，仅显示 /proc/partitions"
    fi
    echo
    info "==== 可扩容空间 ===="
    printf "  磁盘总扇区:   %s\n" "$DISK_SECTORS"
    printf "  rootfs 末尾:  %s\n" "$((PART_START + PART_SECTORS))"
    printf "  可扩容空间:   ${BOLD}%s${NC} 扇区 (~${BOLD}%s${NC} MiB)\n" "$FREE_SECTORS" "$FREE_MB"
}

# =========================================================
# 4) 安装依赖 (apk)
# =========================================================
install_deps() {
    detect_env || return 1
    info "==== 安装必要工具 (apk) ===="

    # 先检查 apk 仓库是否配置
    if [ ! -s /etc/apk/repositories ] && [ -z "$(ls /etc/apk/repositories.d/ 2>/dev/null)" ]; then
        err "/etc/apk/repositories 为空, apk 没法装任何包"
        warn "通常 OpenWrt 25.12 默认就有源, 检查文件是否被清空"
        return 1
    fi

    info "apk update (显示真实输出)"
    if ! apk update; then
        warn "apk update 失败 — 网络/源/DNS 有一个出了问题"
        warn "排查: ping 8.8.8.8 / nslookup downloads.openwrt.org / cat /etc/apk/repositories"
    fi

    NEEDS="parted losetup blkid"
    case "$OVERLAY_FS" in
        f2fs)           NEEDS="$NEEDS f2fs-tools" ;;
        ext2|ext3|ext4) NEEDS="$NEEDS resize2fs"  ;;
    esac

    FAIL_LIST=""
    for p in $NEEDS; do
        # 已有命令(非 apk 包形式)就跳过, 例如 losetup/blkid 在 busybox 里就有
        case "$p" in
            losetup|blkid)
                if command -v "$p" >/dev/null 2>&1; then
                    ok "$p 已存在 (busybox 自带或已安装)"
                    continue
                fi
                ;;
        esac
        if apk info -e "$p" >/dev/null 2>&1; then
            ok "$p 已安装"
            continue
        fi
        info "apk add $p (显示真实输出)"
        if apk add "$p"; then
            ok "$p 安装成功"
        else
            err "$p 安装失败 (上面是 apk 真实报错)"
            FAIL_LIST="$FAIL_LIST $p"
        fi
    done

    if [ -n "$FAIL_LIST" ]; then
        echo
        warn "以下包未能安装:$FAIL_LIST"
        warn "常见原因:"
        warn "  1) 没网/DNS 故障 — 试: opkg/apk update; ping downloads.openwrt.org"
        warn "  2) /overlay 已满 — df -h /overlay 看下 Use%"
        warn "  3) 25.12 早期版本源不全 — 试: apk update; apk add --force-broken-world parted"
    fi

    if ! command -v parted >/dev/null 2>&1; then
        err "缺少 parted，无法继续"
        return 1
    fi
    return 0
}

# =========================================================
# 5) 扩展分区
# =========================================================
expand_partition() {
    detect_env || return 1
    if [ "$FREE_SECTORS" -lt 2048 ]; then
        warn "剩余空间不足 1MiB，无须扩容"
        return 0
    fi
    if command -v sgdisk >/dev/null 2>&1; then
        info "sgdisk -e 修复 GPT 备份头"
        sgdisk -e "$ROOT_DISK" >/dev/null 2>&1 || warn "sgdisk -e 失败 (可能是 MBR)"
    else
        warn "未安装 sgdisk，跳过 GPT 备份头修复 (MBR 镜像可忽略)"
    fi
    info "parted resizepart $ROOT_PART_NUM 100%"
    parted -f -s "$ROOT_DISK" resizepart "$ROOT_PART_NUM" 100% || {
        err "parted resizepart 失败"; return 1;
    }
    info "通知内核重读分区表"
    partx -u "$ROOT_DISK" 2>/dev/null || partprobe "$ROOT_DISK" 2>/dev/null || \
        warn "partx/partprobe 都不可用，可能需要 reboot"
    if [ -n "$LOOP_DEV" ]; then
        info "losetup -c $LOOP_DEV (刷新 loop 容量)"
        losetup -c "$LOOP_DEV" || warn "losetup -c 失败"
    fi
    detect_env
    ok "分区扩展完成"
    return 0
}

# =========================================================
# 6) 在线 resize 文件系统
# =========================================================
resize_fs() {
    detect_env || return 1
    TARGET="${LOOP_DEV:-$ROOT_DEV}"

    # loop 设备先刷新一次, 让它跟上底层分区的当前尺寸
    if [ -n "$LOOP_DEV" ] && command -v losetup >/dev/null 2>&1; then
        info "losetup -c $LOOP_DEV (刷新 loop 容量)"
        losetup -c "$LOOP_DEV" || warn "losetup -c 失败 (可能需要 reboot)"
    fi

    case "$OVERLAY_FS" in
        f2fs)
            info "resize.f2fs $TARGET (在线)"
            if command -v resize.f2fs >/dev/null 2>&1; then
                resize.f2fs "$TARGET" || { warn "resize.f2fs 失败 — 重启后再跑一次通常即可"; return 1; }
            else
                err "缺 resize.f2fs，请先安装 f2fs-tools"; return 1
            fi
            ;;
        ext2|ext3|ext4)
            if ! command -v resize2fs >/dev/null 2>&1; then
                err "缺 resize2fs, 请先在菜单 [5] 安装依赖"
                return 1
            fi
            info "resize2fs $TARGET (在线)"
            resize2fs "$TARGET" || { warn "resize2fs 失败"; return 1; }
            ;;
        *)
            err "未识别 overlay 文件系统 ($OVERLAY_FS)"; return 1 ;;
    esac
    ok "文件系统扩容完成"
    return 0
}

# =========================================================
# 检查 overlay 文件系统大小是否已经匹配底层分区
# 返回 0 = fs 跟分区一致, 不需要 resize
# 返回 1 = fs 比分区小, 需要 resize
# =========================================================
fs_needs_resize() {
    [ -z "$LOOP_DEV" ] && return 1
    # df 拿到的 fs 总块数 (1K)
    FS_KB=$(df -P "$LOOP_DEV" 2>/dev/null | awk 'NR==2 {print $2}')
    # blockdev 拿底层分区字节数 (优先) 或从 sysfs 读扇区数
    PART_KB=""
    if command -v blockdev >/dev/null 2>&1; then
        BYTES=$(blockdev --getsize64 "$ROOT_DEV" 2>/dev/null)
        [ -n "$BYTES" ] && PART_KB=$((BYTES / 1024))
    fi
    [ -z "$PART_KB" ] && PART_KB=$((PART_SECTORS / 2))
    [ -z "$FS_KB" ] || [ -z "$PART_KB" ] && return 1
    # 留 4 MiB 误差
    DIFF=$((PART_KB - FS_KB))
    [ "$DIFF" -gt 4096 ] && return 1 || return 0
}

# =========================================================
# 7) 一键完整扩容
# =========================================================
do_full_expand() {
    AUTO="$1"
    compat_check || { err "兼容性检查未通过, 流程终止"; return 1; }
    show_status

    # 三种状态:
    # A) 分区有空间 → 完整流程 (扩分区 + resize fs)
    # B) 分区已满, 但 fs 还小 → 只跑 resize fs (前次中断)
    # C) 分区已满 + fs 已满 → 真的没事可做
    NEED_PART=0
    NEED_FS=0
    [ "$FREE_SECTORS" -ge 2048 ] && NEED_PART=1
    if fs_needs_resize; then
        NEED_FS=0
    else
        NEED_FS=1
    fi

    if [ "$NEED_PART" = "0" ] && [ "$NEED_FS" = "0" ]; then
        info "分区与文件系统都已占满磁盘, 无可扩容空间"
        return 0
    fi

    install_deps || return 1

    if [ "$AUTO" != "1" ]; then
        echo
        if [ "$NEED_PART" = "1" ]; then
            warn "即将把 $ROOT_DEV 扩到磁盘末尾, 并在线 resize $OVERLAY_FS"
        else
            warn "分区已扩好, 仅需在线 resize $OVERLAY_FS ($LOOP_DEV)"
        fi
        warn "配置都在 overlay 中, 扩容不会丢数据, 但仍建议先备份"
        printf "确认继续? [y/N]: "
        read CONFIRM
        case "$CONFIRM" in y|Y) ;; *) info "用户取消"; return 0 ;; esac
    fi

    if [ "$NEED_PART" = "1" ]; then
        expand_partition || return 1
    fi
    if [ "$NEED_FS" = "1" ]; then
        resize_fs || return 1
    fi

    echo
    info "==== 扩容后状态 ===="
    df -hT 2>/dev/null | grep -E "Filesystem|/rom|/overlay|/$" || df -h
    echo
    info "完成。如果 /overlay 大小没变化, 请 reboot 后从菜单 [7] 再跑一次。"
    return 0
}

# =========================================================
# 8) 关于 / 帮助
# =========================================================
show_about() {
    cat <<EOF
${CYAN}${BOLD}$SCRIPT_NAME${NC}  ${DIM}v$VERSION${NC}

  在 OpenWrt 设备上在线扩容 squashfs 镜像的 overlay 分区到磁盘剩余空间。

${BOLD}适用范围${NC}
  - OpenWrt ${MIN_OPENWRT_MAJOR}.${MIN_OPENWRT_MINOR}+ (apk 包管理器)
  - 块设备根盘: $SUPPORTED_DISK_PREFIX
  - overlay 文件系统: $SUPPORTED_FS
  - ${RED}不支持${NC}: NAND/UBI ($INCOMPAT_DISK_PREFIX)

${BOLD}流程${NC}
  ① 兼容性自检 → ② 探测分区/loop → ③ apk 安装依赖 →
  ④ sgdisk 修 GPT → ⑤ parted resizepart → ⑥ partx -u →
  ⑦ losetup -c 刷新 loop → ⑧ resize.f2fs / resize2fs

${BOLD}命令行参数${NC}
  --check, -c    一键诊断, 只读
  --expand, -e   一键扩容 (含确认)
  --auto, -y     一键扩容 (无确认)
  --force        即使兼容性检查不通过也强行执行 (危险)
  --version, -V  显示版本
  -h, --help     脚本头注释

${BOLD}注意${NC}
  overlay 中的 LuCI 配置/已装包不会丢失。
  若 fs resize 报"设备没变大", reboot 后再 [6] 一次即可。
EOF
}

# =========================================================
# 9) 菜单 UI
# =========================================================
print_banner() {
    clr
    printf "${CYAN}${BOLD}"
    cat <<'EOF'
  ╔════════════════════════════════════════════════════════════╗
  ║       OpenWrt Overlay 在线扩容工具                         ║
EOF
    printf "  ║       version %-7s                                      ║\n" "$VERSION"
    cat <<'EOF'
  ║       适用 OpenWrt 25.12+ (apk 包管理器)                   ║
  ╚════════════════════════════════════════════════════════════╝
EOF
    printf "${NC}"
}

print_summary() {
    detect_env >/dev/null 2>&1
    OW=$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_RELEASE")
    [ -z "$OW" ] && OW="未知"
    APK_VER=$(command -v apk >/dev/null 2>&1 && apk --version 2>/dev/null | head -n1 || echo "未安装")

    printf "  ${DIM}系统:${NC}    ${BOLD}OpenWrt %s${NC}   ${DIM}apk:${NC} %s\n" "$OW" "$APK_VER"
    printf "  ${DIM}整盘:${NC}    ${BOLD}%s${NC}   ${DIM}rootfs:${NC} ${BOLD}%s${NC} (#%s)\n" \
        "${ROOT_DISK:-?}" "${ROOT_DEV:-?}" "${ROOT_PART_NUM:-?}"
    printf "  ${DIM}overlay:${NC} ${BOLD}%s${NC}   ${DIM}fs:${NC} ${BOLD}%s${NC}\n" \
        "${LOOP_DEV:-(无)}" "${OVERLAY_FS:-?}"
    if [ "$FREE_MB" -gt 0 ] 2>/dev/null; then
        printf "  ${DIM}可扩空间:${NC} ${GREEN}${BOLD}%s MiB${NC}\n" "$FREE_MB"
    else
        printf "  ${DIM}可扩空间:${NC} ${YELLOW}%s MiB${NC}\n" "${FREE_MB:-0}"
    fi
    hr
}

main_menu() {
    while true; do
        print_banner
        print_summary
        cat <<EOF

    ${BOLD}诊断${NC}
      ${BOLD}${GREEN}1${NC})  兼容性自检         ${DIM}(只读, 安全)${NC}
      ${BOLD}${GREEN}2${NC})  查看当前状态       ${DIM}(分区 / 挂载 / 容量)${NC}

    ${BOLD}扩容${NC}
      ${BOLD}${GREEN}3${NC})  一键扩容           ${DIM}(推荐, 含二次确认)${NC}
      ${BOLD}${YELLOW}4${NC})  自动扩容           ${DIM}(无确认, 危险)${NC}

    ${BOLD}分步操作${NC}
      ${BOLD}${GREEN}5${NC})  仅安装依赖
      ${BOLD}${GREEN}6${NC})  仅扩展分区         ${DIM}(parted / partx / losetup)${NC}
      ${BOLD}${GREEN}7${NC})  仅 resize 文件系统 ${DIM}(分区已扩好的情况)${NC}

    ${BOLD}其它${NC}
      ${BOLD}${CYAN}8${NC})  关于 / 帮助
      ${BOLD}${CYAN}9${NC})  切换 --force 模式  ${DIM}(当前: $( [ "$FORCE" = "1" ] && printf "${RED}ON${NC}" || printf "OFF" ))${NC}
      ${BOLD}${RED}0${NC})  退出

EOF
        printf "  请选择 ${BOLD}[0-9]${NC}: "
        read CHOICE
        echo
        case "$CHOICE" in
            1) compat_check ;;
            2) show_status ;;
            3) do_full_expand 0 ;;
            4) do_full_expand 1 ;;
            5) compat_check && install_deps ;;
            6) compat_check && install_deps && expand_partition ;;
            7) compat_check && resize_fs ;;
            8) show_about ;;
            9)
                if [ "$FORCE" = "1" ]; then FORCE=0; info "已关闭 --force"
                else FORCE=1; warn "已开启 --force, 兼容性检查将被忽略"
                fi
                ;;
            0) info "再见"; exit 0 ;;
            "") ;;
            *) warn "无效选项: $CHOICE" ;;
        esac
        pause
    done
}

# =========================================================
# 入口分发
# =========================================================
case "$ONE_SHOT" in
    check)  compat_check; show_status ;;
    expand) do_full_expand 0 ;;
    auto)   do_full_expand 1 ;;
    *)      main_menu ;;
esac
