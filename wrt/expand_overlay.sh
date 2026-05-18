#!/bin/sh
# =========================================================
# 脚本: expand_overlay.sh
# 功能: 在 OpenWrt 设备上在线扩容 rootfs/overlay 分区到磁盘剩余空间
# 适用: x86 squashfs / ext4 / f2fs overlay (其它平台需通过兼容性检查)
# 用法:
#   sh expand_overlay.sh --check     # 只诊断不修改
#   sh expand_overlay.sh             # 交互式扩容
#   sh expand_overlay.sh -y          # 非交互直接扩容
#   sh expand_overlay.sh --version   # 显示版本
#   sh expand_overlay.sh --force     # 跳过兼容性硬阻断 (危险)
# 注: 在 OpenWrt 设备本机运行 (busybox sh / ash 兼容)
# =========================================================

VERSION="1.1.0"
SCRIPT_NAME="expand_overlay.sh"

# 已通过测试的 OpenWrt 主版本 (空格分隔，主.次)
SUPPORTED_OPENWRT="21.02 22.03 23.05 24.10"
# 已支持的 overlay 文件系统
SUPPORTED_FS="ext2 ext3 ext4 f2fs"
# 已支持的根盘前缀 (sysfs 里的设备名前缀)
SUPPORTED_DISK_PREFIX="sd vd nvme hd xvd"
# 已知不兼容的根盘前缀 (NAND / NOR / UBI 体系，需要别的工具链)
INCOMPAT_DISK_PREFIX="mtdblock ubiblock ubi"

set -e

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()   { printf "${RED}[ERR ]${NC} %s\n" "$*"; }

MODE="run"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --check|-c)   MODE="check" ;;
        -y|--yes)     MODE="auto"  ;;
        --force)      FORCE=1 ;;
        --version|-V) printf "%s %s\n" "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
        -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    esac
done

printf "${GREEN}== %s v%s ==${NC}\n" "$SCRIPT_NAME" "$VERSION"

[ "$(id -u)" = "0" ] || { err "请用 root 运行"; exit 1; }

# =========================================================
# 兼容性检查 (硬阻断 = HARD, 警告 = SOFT)
# 只有 HARD 全部通过才允许进入扩容流程; --force 可强行越过
# =========================================================
compat_check() {
    info "==== 兼容性自检 v$VERSION ===="
    HARD_FAIL=0
    SOFT_WARN=0

    # 1. 必须是 OpenWrt
    OW_VER=""
    if [ -f /etc/openwrt_release ]; then
        OW_VER=$(. /etc/openwrt_release 2>/dev/null; echo "$DISTRIB_RELEASE")
        info "[OK ] 系统: OpenWrt $OW_VER"
    elif grep -qi openwrt /etc/os-release 2>/dev/null; then
        OW_VER=$(. /etc/os-release 2>/dev/null; echo "$VERSION_ID")
        info "[OK ] 系统: OpenWrt (os-release) $OW_VER"
    else
        err  "[FAIL] 非 OpenWrt 系统，本脚本仅适用于 OpenWrt"
        HARD_FAIL=$((HARD_FAIL+1))
    fi

    # 1b. OpenWrt 主版本是否在白名单
    if [ -n "$OW_VER" ]; then
        OW_MAJ=$(echo "$OW_VER" | awk -F. '{printf "%s.%s", $1, $2}')
        MATCH=0
        for v in $SUPPORTED_OPENWRT; do
            [ "$OW_MAJ" = "$v" ] && MATCH=1
        done
        if [ "$MATCH" = "1" ]; then
            info "[OK ] OpenWrt 版本 $OW_MAJ 在已测试列表"
        else
            warn "[WARN] OpenWrt 版本 $OW_MAJ 未在测试列表 ($SUPPORTED_OPENWRT)"
            SOFT_WARN=$((SOFT_WARN+1))
        fi
    fi

    # 2. 必须能解析 /
    R_SRC=$(awk '$2 == "/" {print $1; exit}' /proc/mounts)
    if [ -z "$R_SRC" ]; then
        err  "[FAIL] 无法识别 / 挂载源"
        HARD_FAIL=$((HARD_FAIL+1))
    else
        info "[OK ] 根挂载源: $R_SRC"
    fi

    # 3. 必须有 /overlay
    OV_LINE=$(awk '$2 == "/overlay" {print; exit}' /proc/mounts)
    if [ -z "$OV_LINE" ]; then
        err  "[FAIL] 未挂载 /overlay (可能是 ext4 整盘版而非 squashfs 版，请用 resize2fs / 已被自动覆盖)"
        HARD_FAIL=$((HARD_FAIL+1))
    else
        info "[OK ] /overlay 已挂载: $(echo "$OV_LINE" | awk '{print $1, $3}')"
    fi

    # 4. overlay 文件系统必须可识别
    OV_FS=$(echo "$OV_LINE" | awk '{print $3}')
    if [ -n "$OV_FS" ]; then
        FS_OK=0
        for f in $SUPPORTED_FS; do
            [ "$OV_FS" = "$f" ] && FS_OK=1
        done
        if [ "$FS_OK" = "1" ]; then
            info "[OK ] overlay 文件系统: $OV_FS"
        else
            err  "[FAIL] overlay 文件系统 $OV_FS 不在支持列表 ($SUPPORTED_FS)"
            HARD_FAIL=$((HARD_FAIL+1))
        fi
    fi

    # 5. 根盘必须是真实块设备前缀，且不在 NAND 黑名单
    R_BLK=$(readlink -f /sys/dev/block/$(awk '$1 == "/dev/root" {print $3; exit}' /proc/self/mountinfo 2>/dev/null) 2>/dev/null || true)
    [ -z "$R_BLK" ] && R_BLK=$(readlink -f /sys/class/block/$(basename "$R_SRC" 2>/dev/null) 2>/dev/null || true)
    if [ -z "$R_BLK" ] || [ ! -e "$R_BLK" ]; then
        err  "[FAIL] 无法定位 sysfs 根分区节点"
        HARD_FAIL=$((HARD_FAIL+1))
    else
        D_NAME=$(basename "${R_BLK%/*}")
        info "[OK ] 根盘 sysfs: $D_NAME"
        for bad in $INCOMPAT_DISK_PREFIX; do
            case "$D_NAME" in
                ${bad}*)
                    err "[FAIL] 根盘 $D_NAME 是 NAND/UBI 类设备，本脚本不支持 (需 ubirsize/sysupgrade)"
                    HARD_FAIL=$((HARD_FAIL+1))
                    ;;
            esac
        done
        DISK_OK=0
        for ok in $SUPPORTED_DISK_PREFIX; do
            case "$D_NAME" in
                ${ok}*) DISK_OK=1 ;;
            esac
        done
        if [ "$DISK_OK" = "0" ]; then
            warn "[WARN] 根盘前缀 $D_NAME 不在常见列表 ($SUPPORTED_DISK_PREFIX)"
            SOFT_WARN=$((SOFT_WARN+1))
        fi
    fi

    # 6. 关键命令是否齐全 (parted 必需; sgdisk/resize 工具是建议)
    command -v parted >/dev/null 2>&1 || {
        warn "[WARN] 未安装 parted，扩容时会尝试自动 opkg install"
        SOFT_WARN=$((SOFT_WARN+1))
    }

    # 7. 必须能读取磁盘 size
    if [ -n "$R_BLK" ]; then
        D_NAME=$(basename "${R_BLK%/*}")
        if [ ! -r "/sys/class/block/$D_NAME/size" ]; then
            err "[FAIL] 无法读取 /sys/class/block/$D_NAME/size"
            HARD_FAIL=$((HARD_FAIL+1))
        fi
    fi

    echo
    if [ "$HARD_FAIL" -gt 0 ]; then
        err "兼容性检查未通过: $HARD_FAIL 项硬阻断, $SOFT_WARN 项警告"
        if [ "$FORCE" = "1" ]; then
            warn "--force 已指定，强行继续 (出问题自己负责)"
            return 0
        fi
        err "脚本终止。如确认环境特殊可加 --force 跳过 (不推荐)"
        exit 2
    fi
    if [ "$SOFT_WARN" -gt 0 ]; then
        warn "兼容性检查通过，但有 $SOFT_WARN 项警告，请留意上方输出"
    else
        info "兼容性检查全部通过"
    fi
    return 0
}

compat_check

# ---------- 1. 收集当前信息 ----------
info "==== 当前挂载与容量 ===="
df -hT 2>/dev/null | grep -E "Filesystem|/rom|/overlay|/$|tmpfs" || df -h
echo
echo "/proc/mounts 中的 rom/overlay:"
grep -E " /rom | /overlay " /proc/mounts || true
echo

# ---------- 2. 识别根盘和分区 ----------
ROOT_SRC="$(awk '$2 == "/" {print $1; exit}' /proc/mounts)"
ROOT_BLK="$(readlink -f /sys/dev/block/"$(awk '$1 == "/dev/root" {print $3; exit}' /proc/self/mountinfo)" 2>/dev/null || true)"

if [ -z "$ROOT_BLK" ] || [ ! -e "$ROOT_BLK" ]; then
    # 备用方式: 根据 /dev/root 的 major:minor 反查
    RDEV=$(stat -c '%t:%T' /dev/root 2>/dev/null)
    [ -n "$RDEV" ] && ROOT_BLK=$(readlink -f /sys/dev/block/$(printf '%d:%d' 0x${RDEV%:*} 0x${RDEV#*:}) 2>/dev/null) || true
fi

if [ -z "$ROOT_BLK" ]; then
    err "无法定位根分区 sysfs 节点，脚本无法继续"
    exit 1
fi

ROOT_PART_NAME="${ROOT_BLK##*/}"                  # 例: sda2
ROOT_DISK_NAME="$(basename "${ROOT_BLK%/*}")"     # 例: sda
ROOT_DISK="/dev/$ROOT_DISK_NAME"
ROOT_DEV="/dev/$ROOT_PART_NAME"
ROOT_PART_NUM="$(cat "/sys/class/block/$ROOT_PART_NAME/partition" 2>/dev/null || echo "?")"

LOOP_DEV="$(awk '$1 ~ "^/dev/loop" && $2 == "/overlay" {print $1; exit}' /proc/self/mountinfo)"
OVERLAY_FS="$(awk '$2 == "/overlay" {print $3; exit}' /proc/self/mountinfo)"
[ -z "$OVERLAY_FS" ] && OVERLAY_FS="$(awk '$2 == "/overlay" {print $3; exit}' /proc/mounts)"

info "==== 识别结果 ===="
info "整盘:         $ROOT_DISK"
info "rootfs 分区:  $ROOT_DEV (#$ROOT_PART_NUM)"
info "overlay 设备: ${LOOP_DEV:-(无 loop, 可能是独立分区)}"
info "overlay 文件系统: ${OVERLAY_FS:-未知}"

# ---------- 3. 显示分区表 ----------
echo
info "==== 当前分区表 ===="
if command -v parted >/dev/null 2>&1; then
    parted -s "$ROOT_DISK" unit MiB print free || true
else
    cat /proc/partitions
    warn "未安装 parted，仅显示 /proc/partitions"
fi

# ---------- 4. 计算可扩容空间 ----------
DISK_SECTORS=$(cat /sys/class/block/$ROOT_DISK_NAME/size 2>/dev/null || echo 0)
PART_START=$(cat /sys/class/block/$ROOT_PART_NAME/start 2>/dev/null || echo 0)
PART_SECTORS=$(cat /sys/class/block/$ROOT_PART_NAME/size 2>/dev/null || echo 0)
END_USED=$((PART_START + PART_SECTORS))
FREE_SECTORS=$((DISK_SECTORS - END_USED))
FREE_MB=$((FREE_SECTORS / 2048))

echo
info "磁盘总扇区:   $DISK_SECTORS"
info "rootfs 末尾:  $END_USED"
info "可扩容空间:   ${FREE_SECTORS} 扇区 (~${FREE_MB} MiB)"

if [ "$FREE_SECTORS" -lt 2048 ]; then
    warn "剩余空间不足 1MiB，没必要扩容 (或者你刷的镜像盘比磁盘还大?)"
    [ "$MODE" = "check" ] || exit 0
fi

[ "$MODE" = "check" ] && { info "--check 模式结束"; exit 0; }

# ---------- 5. 安装依赖 ----------
info "==== 安装必要工具 ===="
opkg update >/dev/null 2>&1 || warn "opkg update 失败 (先确认网络/源)"
NEEDS="parted losetup blkid"
case "$OVERLAY_FS" in
    f2fs)        NEEDS="$NEEDS f2fsck resize-f2fs" ;;
    ext2|ext3|ext4) NEEDS="$NEEDS e2fsprogs" ;;
esac
for p in $NEEDS; do
    opkg list-installed | grep -q "^$p " && continue
    info "安装 $p"
    opkg install "$p" >/dev/null 2>&1 || warn "安装 $p 失败 (可能换了名称，自行确认)"
done
command -v parted >/dev/null 2>&1 || { err "缺少 parted，无法继续"; exit 1; }

# ---------- 6. 二次确认 ----------
if [ "$MODE" != "auto" ]; then
    echo
    warn "即将把 $ROOT_DEV 扩到磁盘末尾，并在线 resize $OVERLAY_FS"
    warn "建议先 \`opkg list-installed > /tmp/pkgs.txt\` 留底，配置已在 overlay 不会丢"
    printf "继续? [y/N]: "
    read C
    case "$C" in y|Y) ;; *) info "用户取消"; exit 0 ;; esac
fi

# ---------- 7. 修复 GPT (备份头位置) ----------
if command -v sgdisk >/dev/null 2>&1; then
    info "sgdisk -e 修复 GPT 备份头"
    sgdisk -e "$ROOT_DISK" >/dev/null 2>&1 || warn "sgdisk -e 失败 (可能是 MBR，无所谓)"
else
    warn "未安装 sgdisk，跳过 GPT 备份头修复 (MBR 镜像可忽略)"
fi

# ---------- 8. 扩展分区 ----------
info "parted resizepart $ROOT_PART_NUM 100%"
parted -f -s "$ROOT_DISK" resizepart "$ROOT_PART_NUM" 100%

# ---------- 9. 让内核重读分区表 ----------
info "通知内核重读分区表"
partx -u "$ROOT_DISK" 2>/dev/null || partprobe "$ROOT_DISK" 2>/dev/null || \
    warn "partx/partprobe 都不可用，可能需要 reboot 后再 resize"

# ---------- 10. 更新 loop 设备尺寸 ----------
if [ -n "$LOOP_DEV" ]; then
    info "losetup -c $LOOP_DEV (刷新 loop 容量)"
    losetup -c "$LOOP_DEV"
fi

# ---------- 11. 在线扩容文件系统 ----------
TARGET="${LOOP_DEV:-$ROOT_DEV}"
case "$OVERLAY_FS" in
    f2fs)
        info "resize.f2fs $TARGET (在线)"
        if command -v resize.f2fs >/dev/null 2>&1; then
            resize.f2fs "$TARGET" || warn "resize.f2fs 失败 — 重启后再跑一次本脚本通常即可"
        else
            warn "缺 resize.f2fs，无法在线扩容 f2fs。请安装 resize-f2fs 后重试。"
        fi
        ;;
    ext2|ext3|ext4)
        info "resize2fs $TARGET (在线)"
        resize2fs "$TARGET" || warn "resize2fs 失败"
        ;;
    *)
        warn "未识别 overlay 文件系统 ($OVERLAY_FS)，跳过 fs resize，请手动处理"
        ;;
esac

# ---------- 12. 结果 ----------
echo
info "==== 扩容后状态 ===="
df -hT 2>/dev/null | grep -E "Filesystem|/rom|/overlay|/$" || df -h
echo
info "完成。如果 /overlay 大小没变化，请 reboot 后再次确认 (内核某些版本上线 resize 需重启生效)。"
