#!/usr/bin/env bash
set +x

FSTAB=/etc/fstab
CREDENTIALS_DIR=/etc/smb-mount.credentials
AUTO_TAG='#smb-mount.sh'
MOUNT_OPTIONS='rw,nosuid,nodev,vers=3,soft,echo_interval=5'
SYSTEMD_OPTIONS='_netdev,nofail,x-systemd.mount-timeout=15s'
AUTO_OPTIONS='x-systemd.automount,x-systemd.idle-timeout=60s'

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

valid_text() { [[ -n $1 && ! $1 =~ [[:cntrl:]] ]]; }
valid_path() { valid_text "$1" && [[ $1 == /* ]]; }
valid_share() { valid_text "$1" && [[ $1 != */* && $1 != *\\* && $1 != . && $1 != .. ]]; }

fstab_escape() {
    local value=${1//\\/\\134}
    printf '%s' "${value// /\\040}"
}

configured_entry() {
    SMB_TARGET=$(fstab_escape "$1") SMB_TAG=$AUTO_TAG awk '
        $1 !~ /^#/ && $2 == ENVIRON["SMB_TARGET"] && $3 == "cifs" && $NF == ENVIRON["SMB_TAG"] { print $1, $4; found=1 }
        END { exit !found }
    ' "$FSTAB"
}

check_conflict() {
    if SMB_TARGET=$(fstab_escape "$1") SMB_TAG=$AUTO_TAG awk '
        $1 !~ /^#/ && $2 == ENVIRON["SMB_TARGET"] && ($3 != "cifs" || $NF != ENVIRON["SMB_TAG"]) { found=1 }
        END { exit !found }
    ' "$FSTAB"; then
        error '此目录已有其他 fstab 配置，请换目录或先手动处理。'
        return 1
    fi
}

save_entry() (
    local target=$1 source=$2 options=$3 tmp encoded_target
    flock -w 5 -x 9 || { error '配置正在更新，请稍后重试。'; exit 1; }
    [[ -f $FSTAB && ! -L $FSTAB ]] || { error 'fstab 不是普通文件。'; exit 1; }
    check_conflict "$target" || exit 1
    encoded_target=$(fstab_escape "$target")
    tmp=$(mktemp "${FSTAB}.smb.XXXXXX") || exit 1
    trap 'rm -f -- "$tmp"' EXIT
    cp -p -- "$FSTAB" "$tmp" || exit 1
    SMB_TARGET=$encoded_target SMB_TAG=$AUTO_TAG awk '
        !($1 !~ /^#/ && $2 == ENVIRON["SMB_TARGET"] && $3 == "cifs" && $NF == ENVIRON["SMB_TAG"])
    ' "$FSTAB" > "$tmp" || exit 1
    printf '%s %s cifs %s 0 0 %s\n' "$(fstab_escape "$source")" "$encoded_target" "$options" "$AUTO_TAG" >> "$tmp" || exit 1
    cmp -s -- "$FSTAB" "$tmp" && exit 0
    cp -p --remove-destination -- "$FSTAB" "$FSTAB.smb.bak" || exit 1
    mv -f -- "$tmp" "$FSTAB" || exit 1
    if ! timeout --kill-after=2s 20s systemctl daemon-reload; then
        if cp -p -- "$FSTAB.smb.bak" "$tmp" && mv -f -- "$tmp" "$FSTAB"; then
            timeout --kill-after=2s 20s systemctl daemon-reload || true
            error '刷新 systemd 失败，fstab 已还原。'
        else
            error "无法还原，请从 $FSTAB.smb.bak 恢复配置。"
        fi
        exit 1
    fi
) 9>"${FSTAB}.smb.lock"

read_target() {
    read -r -p '本地完整挂载点 [/mnt/smb]：' target || return 1
    target=${target:-/mnt/smb}
    valid_path "$target" || { error '请输入有效的绝对路径。'; return 1; }
    target=$(realpath -ms -- "$target") || return 1
    [[ $target != / ]] || { error '不能使用根目录。'; return 1; }
}

unit_name() { systemd-escape --path --suffix="$2" -- "$1"; }

connect_share() {
    local target=$1 source options mounted_source
    read -r source options < <(configured_entry "$target")
    [[ -n $source && -n $options ]] || { error '未找到此目录的脚本配置。'; return 1; }
    if ! findmnt -C -rn -M "$target" -t cifs >/dev/null; then
        if [[ ,$options, == *,x-systemd.automount,* ]]; then
            timeout --kill-after=2s 20s systemctl start "$(unit_name "$target" automount)" || {
                error '按需入口启动失败，请检查 systemctl 状态。'; return 1;
            }
        fi
        if ! timeout --kill-after=2s 20s systemctl start "$(unit_name "$target" mount)"; then
            error '连接失败或超时。配置和凭据已保存，可在菜单 1 重试；检查 OMV 的 SMB 服务、共享名与账号权限。'
            return 1
        fi
    fi
    mounted_source=$(findmnt -C -rn -M "$target" -t cifs -o SOURCE --nofsroot) || {
        error '未检测到 CIFS 挂载，请检查是否存在覆盖 fstab 的自定义 systemd 单元。'
        return 1
    }
    printf -v source '%b' "$source"
    printf -v mounted_source '%b' "$mounted_source"
    if [[ $mounted_source != "$source" ]]; then
        error '该目录实际连接的共享与保存配置不一致，请先卸载并检查 systemd 配置。'
        return 1
    fi
    printf '✓ 已挂载：%s\n' "$target"
}

mount_share() {
    local ip share target username password domain local_user uid gid access automatic answer credential options entry
    command -v mount.cifs >/dev/null 2>&1 || {
        error '请先安装 cifs-utils：Arch/CachyOS 用 pacman；Debian/Ubuntu 用 apt；Fedora 用 dnf。'
        return 1
    }
    printf '\n── 连接 SMB 共享 ──\n'
    read_target || return 1
    check_conflict "$target" || return 1
    if entry=$(configured_entry "$target"); then
        read -r -p '已有配置 [1 连接 / 2 重新配置 / 0 返回，默认 1]：' answer || return 1
        case $answer in
            ''|1)
                connect_share "$target"
                return $? ;;
            2) ;;
            0) return 0 ;;
            *) error '请输入 0、1 或 2。'; return 1 ;;
        esac
    fi
    if findmnt -C -rn -M "$target" >/dev/null; then
        error '该目录已有挂载或按需入口，请先用菜单 2 卸载或换目录。'
        return 1
    fi
    [[ $(realpath -m -- "$target") == "$target" ]] || { error '挂载点不能经过符号链接。'; return 1; }
    if [[ -e $target ]]; then
        [[ -d $target && ! -L $target && $(stat -c %u -- "$target") == 0 ]] || {
            error '请使用由 root 拥有的空目录，或输入一个尚不存在的目录。'
            return 1
        }
        [[ -z $(find "$target" -mindepth 1 -maxdepth 1 -print -quit) ]] || { error '目录非空，请换目录。'; return 1; }
    fi
    read -r -p '服务器 IPv4（例 10.9.6.2）：' ip || return 1
    valid_ip "$ip" || { error '请输入有效的 IPv4。'; return 1; }
    read -r -p 'SMB 共享名（例 OMV，不是 /export/OMV）：' share || return 1
    valid_share "$share" || { error '请输入一个共享名，不能包含 /、反斜杠或控制字符。'; return 1; }
    read -r -p 'OMV 用户名：' username || return 1
    valid_text "$username" || { error '用户名不能为空或包含控制字符。'; return 1; }
    IFS= read -r -s -p 'OMV 密码（输入不显示）：' password || { printf '\n'; return 1; }
    printf '\n'
    [[ ! $password =~ [[:cntrl:]] ]] || { error '密码不能包含控制字符。'; return 1; }
    read -r -p '域 / 工作组 [留空即可]：' domain || return 1
    [[ ! $domain =~ [[:cntrl:]] ]] || { error '域不能包含控制字符。'; return 1; }
    local_user=${SUDO_USER:-}
    [[ $local_user != root ]] || local_user=''
    read -r -p "本机访问用户${local_user:+ [$local_user]}：" answer || return 1
    local_user=${answer:-$local_user}
    uid=$(id -u -- "$local_user" 2>/dev/null) && gid=$(id -g -- "$local_user" 2>/dev/null) || {
        error '本机用户不存在。'; return 1;
    }
    read -r -p '访问方式 [1 读写 / 2 只读，默认 1]：' access || return 1
    options=$MOUNT_OPTIONS
    case $access in
        ''|1) printf '断线时写入可能失败；重要文件请确认复制成功。\n' ;;
        2) options=${options/#rw,/ro,} ;;
        *) error '请输入 1 或 2。'; return 1 ;;
    esac
    read -r -p '开机按需连接？[Y/n]：' automatic || return 1
    case $automatic in
        ''|[yY]) automatic=yes ;;
        [nN]) automatic=no ;;
        *) error '请输入 y 或 n。'; return 1 ;;
    esac
    printf '\n  //%s/%s → %s\n  本机用户：%s；开机按需连接：%s\n' "$ip" "$share" "$target" "$local_user" "$automatic"
    read -r -p '保存凭据并立即连接？[y/N]：' answer || return 1
    [[ $answer == [yY] ]] || { printf '已取消。\n'; return 0; }
    [[ ! -L $CREDENTIALS_DIR ]] || { error '凭据目录不能是符号链接。'; return 1; }
    if [[ -e $CREDENTIALS_DIR ]]; then
        [[ -d $CREDENTIALS_DIR && $(stat -c %u -- "$CREDENTIALS_DIR") == "$EUID" ]] || {
            error '凭据目录所有者异常。'; return 1;
        }
    fi
    mkdir -p -m 700 -- "$CREDENTIALS_DIR" || return 1
    chmod 700 -- "$CREDENTIALS_DIR" || return 1
    credential=$(mktemp "$CREDENTIALS_DIR/share.XXXXXXXX") || return 1
    chmod 600 -- "$credential" || { rm -f -- "$credential"; return 1; }
    if ! printf 'username=%s\npassword=%s\ndomain=%s\n' "$username" "$password" "$domain" > "$credential"; then
        rm -f -- "$credential"
        return 1
    fi
    unset password
    mkdir -p -- "$target" && chmod 0555 -- "$target" || { rm -f -- "$credential"; return 1; }
    options+=",credentials=$credential,uid=$uid,gid=$gid,file_mode=0664,dir_mode=0775,$SYSTEMD_OPTIONS"
    if [[ $automatic == yes ]]; then options+=",$AUTO_OPTIONS"; else options+=',noauto'; fi
    if ! save_entry "$target" "//$ip/$share" "$options"; then
        # 保留凭据，以免还原失败后的 fstab 指向已删除文件。
        error "配置未完成，凭据保存在 $credential，请检查 fstab 后再删除。"
        return 1
    fi
    printf '✓ 凭据已保存，后续连接和重启无需重新输入密码。\n'
    connect_share "$target"
}

unmount_share() {
    local target
    printf '\n── 卸载 SMB ──\n'
    read_target || return 1
    configured_entry "$target" >/dev/null || { error '此目录没有脚本管理的 SMB 配置。'; return 1; }
    local -a units=("$(unit_name "$target" mount)")
    if systemctl is-active --quiet "$(unit_name "$target" automount)"; then
        units=("$(unit_name "$target" automount)" "${units[@]}")
    fi
    if timeout --kill-after=2s 20s systemctl stop "${units[@]}"; then
        printf '✓ 已卸载并停止本次按需入口。保存的凭据和开机设置保留。\n'
    else
        error '卸载未完成，请关闭占用文件的程序，并检查 systemctl 状态；脚本不会强制卸载。'
        return 1
    fi
}

toggle_autoconnect() {
    local target source options answer
    printf '\n── 开机按需连接 ──\n'
    read_target || return 1
    read -r source options < <(configured_entry "$target")
    [[ -n $source && -n $options ]] || { error '请先通过菜单 1 保存共享配置。'; return 1; }
    if [[ ,$options, == *,x-systemd.automount,* ]]; then
        read -r -p '当前已开启，关闭？[y/N]：' answer || return 1
        [[ $answer == [yY] ]] || return 0
        options=${options//,x-systemd.automount/}
        options=${options//,x-systemd.idle-timeout=60s/}
        options+=',noauto'
    else
        read -r -p '当前已关闭，开启？[Y/n]：' answer || return 1
        [[ -z $answer || $answer == [yY] ]] || return 0
        options=${options//,noauto/}
        options+=",$AUTO_OPTIONS"
    fi
    save_entry "$target" "$source" "$options" || return 1
    printf '✓ 已保存，下次开机生效。当前连接保留；可先卸载，再从菜单 1 连接以立即应用。\n'
}

show_status() {
    printf '\n── 当前 SMB 挂载 ──\n'
    findmnt -C -t cifs -o SOURCE,TARGET || printf '暂无 SMB 挂载。\n'
    printf '\n── 已保存的连接 ──\n'
    awk -v tag="$AUTO_TAG" '$1 !~ /^#/ && $3 == "cifs" && $NF == tag {
        source=$1; target=$2; gsub(/\\040/, " ", source); gsub(/\\040/, " ", target)
        printf "  %s → %s  [开机按需：%s]\n", source, target, index("," $4 ",", ",x-systemd.automount,") ? "开" : "关"
    }' "$FSTAB"
}

main() {
    local cmd choice cyan='' reset=''
    [[ $(uname -s) == Linux ]] || { error '此脚本仅支持 Linux。'; return 1; }
    ((EUID == 0)) || { error "请用 sudo bash $0 运行。"; return 1; }
    [[ -d /run/systemd/system ]] || { error '需要 systemd。'; return 1; }
    for cmd in systemctl systemd-escape findmnt realpath find awk flock mktemp cp mv cmp rm timeout stat id mkdir chmod; do
        command -v "$cmd" >/dev/null 2>&1 || { error "缺少命令：$cmd"; return 1; }
    done
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
        cyan=$'\033[36m'; reset=$'\033[0m'
    fi
    while true; do
        printf '\n%s┌────────────────────────────┐\n│       局域网 SMB 挂载      │\n└────────────────────────────┘%s\n' "$cyan" "$reset"
        printf '  1  挂载 / 连接共享\n  2  卸载共享\n  3  查看状态\n  4  开机按需连接开关\n  0  退出\n\n'
        read -r -p '请选择 [0-4]：' choice || return 0
        case $choice in
            1) mount_share ;;
            2) unmount_share ;;
            3) show_status ;;
            4) toggle_autoconnect ;;
            0) return 0 ;;
            *) printf '请输入 0、1、2、3 或 4。\n' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
