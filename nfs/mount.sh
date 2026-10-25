#!/usr/bin/env bash

FSTAB=/etc/fstab
AUTO_TAG='#nfs-mount.sh'
MOUNT_OPTIONS='rw,nosuid,nodev,proto=tcp,softerr,timeo=20,retrans=2,retry=0'
AUTO_EXTRA_OPTIONS='_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60s,x-systemd.mount-timeout=15s'
AUTO_OPTIONS="$MOUNT_OPTIONS,$AUTO_EXTRA_OPTIONS"

error() { printf '错误：%s\n' "$*" >&2; }

valid_ip() {
    local octet
    local -a octets
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$1"
    for octet in "${octets[@]}"; do
        [[ $octet == 0 || $octet != 0* ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

valid_path() {
    [[ $1 == /* && ! $1 =~ [[:cntrl:]] ]]
}

fstab_escape() {
    local value=${1//\\/\\134}
    printf '%s' "${value// /\\040}"
}

autoconnect_enabled() {
    NFS_TARGET=$(fstab_escape "$1") NFS_TAG=$AUTO_TAG awk '
        $1 !~ /^#/ && $2 == ENVIRON["NFS_TARGET"] && $NF == ENVIRON["NFS_TAG"] { found=1 }
        END { exit !found }
    ' "$FSTAB"
}

systemd_ready() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

save_autoconnect() (
    local target=$1 source=${2:-} options=${3:-$AUTO_OPTIONS} tmp encoded_target encoded_source status
    systemd_ready || { error '开机自动连接需要 systemd。'; exit 1; }
    flock -w 5 -x 9 || { error '配置正在更新，请稍后重试。'; exit 1; }
    [[ -f $FSTAB && ! -L $FSTAB ]] || { error 'fstab 不是普通文件，请手动配置。'; exit 1; }
    encoded_target=$(fstab_escape "$target")
    encoded_source=$(fstab_escape "$source")
    if NFS_TARGET=$encoded_target NFS_TAG=$AUTO_TAG awk '
        $1 !~ /^#/ && $2 == ENVIRON["NFS_TARGET"] && $NF != ENVIRON["NFS_TAG"] { found=1 }
        END { exit !found }
    ' "$FSTAB"; then
        error '此目录已有其他 fstab 配置，请先手动处理。'
        exit 1
    fi
    tmp=$(mktemp "${FSTAB}.nfs.XXXXXX") || exit 1
    trap 'rm -f -- "$tmp"' EXIT
    cp -p -- "$FSTAB" "$tmp" || exit 1
    NFS_TARGET=$encoded_target NFS_TAG=$AUTO_TAG awk '
        !($1 !~ /^#/ && $2 == ENVIRON["NFS_TARGET"] && $NF == ENVIRON["NFS_TAG"])
    ' "$FSTAB" > "$tmp" || exit 1
    if [[ -n $source ]]; then
        printf '%s %s nfs %s 0 0 %s\n' "$encoded_source" "$encoded_target" "$options" "$AUTO_TAG" >> "$tmp" || exit 1
    fi
    if cmp -s -- "$FSTAB" "$tmp"; then
        exit 0
    fi
    cp -p --remove-destination -- "$FSTAB" "$FSTAB.nfs.bak" || exit 1
    mv -f -- "$tmp" "$FSTAB" || exit 1
    if timeout --kill-after=2s 20s systemctl daemon-reload; then
        exit 0
    else
        status=$?
        if ((status == 124 || status == 137)); then
            printf '配置已保存，但刷新 systemd 超时，重启后生效。\n'
            exit 0
        fi
        if cp -p -- "$FSTAB.nfs.bak" "$tmp" && mv -f -- "$tmp" "$FSTAB"; then
            timeout --kill-after=2s 20s systemctl daemon-reload || true
            error '刷新 systemd 失败，fstab 已还原。'
        else
            error "刷新失败且无法还原，请从 $FSTAB.nfs.bak 恢复。"
        fi
        exit 1
    fi
) 9>"${FSTAB}.nfs.lock"

toggle_autoconnect() {
    local target source answer current_options options=$AUTO_OPTIONS
    printf '\n── 开机自动连接 ──\n'
    read -r -p '本地目录 [/mnt/nfs]：' target || return 1
    target=${target:-/mnt/nfs}
    valid_path "$target" || { error '请输入有效的绝对路径。'; return 1; }
    target=$(realpath -ms -- "$target") || return 1
    if autoconnect_enabled "$target"; then
        read -r -p '当前已开启，关闭自动连接？[y/N]：' answer || return 1
        [[ $answer == [yY] ]] || return 0
        save_autoconnect "$target" || return 1
        printf '✓ 已关闭，下次开机生效；当前挂载保留。\n'
    else
        source=$(findmnt -C -rn -M "$target" -t nfs,nfs4 -o SOURCE --nofsroot) || {
            error '请先通过菜单挂载此 NFS 共享。'
            return 1
        }
        # findmnt --raw 将空格和反斜杠编码为十六进制。
        printf -v source '%b' "$source"
        valid_ip "${source%%:*}" && valid_path "${source#*:}" || {
            error '仅支持 IPv4 地址和绝对共享路径。'
            return 1
        }
        read -r -p '当前未开启，开启自动连接？[Y/n]：' answer || return 1
        [[ -z $answer || $answer == [yY] ]] || return 0
        current_options=$(findmnt -C -rn -M "$target" -t nfs,nfs4 -o OPTIONS) || return 1
        [[ ,$current_options, != *,ro,* ]] || options=${options/#rw,/ro,}
        save_autoconnect "$target" "$source" "$options" || return 1
        printf '✓ 已开启：开机建立入口，访问目录时自动连接。\n'
    fi
}

mount_share() {
    local ip share target answer entries automatic access mount_options=$MOUNT_OPTIONS
    if ! command -v mount.nfs >/dev/null 2>&1; then
        error '请先安装 NFS 客户端：Debian/Ubuntu 用 nfs-common；Arch/CachyOS/Fedora 用 nfs-utils。'
        return 1
    fi

    printf '\n── 挂载 NFS ──\n'
    read -r -p '服务器 IPv4（例 192.168.1.10）：' ip || return 1
    valid_ip "$ip" || { error '请输入有效的 IPv4 地址。'; return 1; }
    read -r -p '共享路径（例 /volume1/share）：' share || return 1
    valid_path "$share" || { error '共享路径须以 / 开头，不能包含控制字符。'; return 1; }
    read -r -p '本地目录 [/mnt/nfs]：' target || return 1
    target=${target:-/mnt/nfs}
    valid_path "$target" || { error '本地目录须为绝对路径，不能包含控制字符。'; return 1; }
    target=$(realpath -ms -- "$target") || return 1
    if findmnt -C -rn -M "$target" -o TARGET >/dev/null; then
        error '该目录已有挂载，请先卸载或换一个目录。'
        return 1
    fi
    target=$(realpath -m -- "$target") || return 1

    if mountpoint -q -- "$target"; then
        error '该目录已有挂载，请先卸载或换一个目录。'
        return 1
    fi
    if [[ -e $target && ! -d $target ]]; then
        error '本地路径不是目录。'
        return 1
    fi
    if [[ -d $target ]]; then
        entries=$(find "$target" -mindepth 1 -maxdepth 1 -print -quit) || return 1
        [[ -z $entries ]] || { error '目录非空，请使用空目录。'; return 1; }
    fi

    read -r -p '访问方式 [1 读写 / 2 只读，默认 1]：' access || return 1
    case $access in
        ''|1) printf '断线时读写会超时报错，未完成的写入可能损坏文件。\n' ;;
        2) mount_options=${mount_options/#rw,/ro,} ;;
        *) error '请输入 1 或 2。'; return 1 ;;
    esac
    printf '\n  %s:%s → %s\n' "$ip" "$share" "$target"
    read -r -p '确认挂载？[y/N]：' answer || return 1
    [[ $answer == [yY] ]] || { printf '已取消。\n'; return 0; }
    read -r -p '开机自动连接？[Y/n]：' automatic || return 1
    case $automatic in
        ''|[yY]) automatic=yes ;;
        [nN]) automatic=no ;;
        *) error '请输入 y 或 n。'; return 1 ;;
    esac
    mkdir -p -- "$target" || return 1
    if timeout --kill-after=2s 15s mount -t nfs -o "$mount_options" -- "$ip:$share" "$target"; then
        printf '✓ 已挂载：%s\n' "$target"
    else
        error '挂载失败或连接超时，请检查服务器、共享路径和授权。'
        return 1
    fi
    if [[ $automatic == yes ]]; then
        save_autoconnect "$target" "$ip:$share" "$mount_options,$AUTO_EXTRA_OPTIONS" || {
            error '当前挂载可用，但开机自动连接设置失败。'
            return 1
        }
        printf '✓ 已开启：开机建立入口，访问目录时自动连接。\n'
    elif autoconnect_enabled "$target"; then
        save_autoconnect "$target" || return 1
        printf '✓ 已关闭开机自动连接，下次开机生效。\n'
    fi
}

unmount_share() {
    local target fstype
    printf '\n── 卸载 NFS ──\n'
    read -r -p '本地目录 [/mnt/nfs]：' target || return 1
    target=${target:-/mnt/nfs}
    valid_path "$target" || { error '请输入有效的绝对路径。'; return 1; }
    target=$(realpath -ms -- "$target") || return 1
    fstype=$(findmnt -C -rn -M "$target" -t nfs,nfs4 -o FSTYPE) || {
        error '该目录没有挂载。'
        return 1
    }
    case $fstype in
        nfs|nfs4) ;;
        *) error '该目录不是 NFS 挂载。'; return 1 ;;
    esac
    if timeout --kill-after=2s 15s umount -i -c -- "$target"; then
        printf '✓ 已卸载：%s\n' "$target"
        if autoconnect_enabled "$target"; then
            printf '开机自动连接仍开启，可在菜单 4 关闭。\n'
        fi
    else
        error '卸载失败，请关闭正在使用该目录的程序后重试。'
        return 1
    fi
}

main() {
    local choice cmd cyan='' reset=''
    [[ $(uname -s) == Linux ]] || { error '此脚本仅支持 Linux。'; return 1; }
    ((EUID == 0)) || { error "请用 sudo bash $0 运行。"; return 1; }
    for cmd in mount umount findmnt mountpoint realpath find awk flock mktemp cp mv cmp rm timeout; do
        command -v "$cmd" >/dev/null 2>&1 || { error "缺少命令：$cmd"; return 1; }
    done
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
        cyan=$'\033[36m'
        reset=$'\033[0m'
    fi

    while true; do
        printf '\n%s┌────────────────────────────┐\n│       局域网 NFS 挂载      │\n└────────────────────────────┘%s\n' "$cyan" "$reset"
        printf '  1  挂载共享\n  2  卸载共享\n  3  查看挂载\n  4  开机自动连接开关\n  0  退出\n\n'
        read -r -p '请选择 [0-4]：' choice || return 0
        case $choice in
            1) mount_share ;;
            2) unmount_share ;;
            3) findmnt -t nfs,nfs4 -o SOURCE,TARGET || printf '暂无 NFS 挂载，或无法读取挂载信息。\n' ;;
            4) toggle_autoconnect ;;
            0) return 0 ;;
            *) printf '请输入 0、1、2、3 或 4。\n' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
