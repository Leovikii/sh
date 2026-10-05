#!/usr/bin/env bash
# subtitle-sync managed entry
# OMV / Debian：组件管理与单组字幕调轴。

VENV_DIR=/opt/ffsubsync-venv
LINK_NAME=/usr/local/bin/subtitle-sync
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
TEMP_SUB=''
UPDATE_BACKUP=''
GREEN='' YELLOW='' RED='' RESET=''
if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
    GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' RESET=$'\e[0m'
fi

error() { printf '%s错误：%s%s\n' "$RED" "$*" "$RESET" >&2; }
pause() { read -r -p '按回车返回…' _ || true; }
header() { printf '\n%s\n────────────────────────────────────\n' "$1"; }

cleanup() {
    [[ ! $TEMP_SUB ]] || rm -f -- "$TEMP_SUB"
    if [[ $UPDATE_BACKUP && -d $UPDATE_BACKUP ]]; then
        # 保留原路径，确保虚拟环境中的绝对路径仍有效。
        rm -rf -- "$VENV_DIR" && mv -- "$UPDATE_BACKUP" "$VENV_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

owned_venv() {
    [[ -f $VENV_DIR/.subtitle-sync-owned || -f $VENV_DIR/.installed_by_subsync ]]
}

ready() {
    command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null &&
        [[ -x $VENV_DIR/bin/ffs ]] && "$VENV_DIR/bin/ffs" --help >/dev/null 2>&1
}

show_status() {
    local version
    for command in ffmpeg ffprobe python3; do
        if command -v "$command" >/dev/null; then
            case $command in
                python3) version=$(python3 --version 2>&1) ;;
                *) version=$("$command" -version 2>/dev/null); version=${version%%$'\n'*} ;;
            esac
            printf '%-10s %s\n' "$command" "$version"
        else
            printf '%-10s 未安装\n' "$command"
        fi
    done
    if [[ -x $VENV_DIR/bin/python ]] && version=$("$VENV_DIR/bin/python" -c 'from importlib.metadata import version; print(version("ffsubsync"))' 2>/dev/null); then
        printf 'FFsubsync  %s\n' "$version"
    else
        printf 'FFsubsync  未安装或环境损坏\n'
    fi
    printf '运行环境   %s\n' "$VENV_DIR"
}

as_admin() {
    if (( EUID == 0 )); then
        "$1"
    elif command -v sudo >/dev/null; then
        sudo bash "$SCRIPT_PATH" "$2"
    else
        error '此操作需要管理员权限，请使用 root 运行组件管理。'
        return 1
    fi
}

install_components() {
    local pkg
    local -a missing=()
    command -v apt-get >/dev/null || { error '组件管理仅支持 OMV / Debian 的 apt 环境。'; return 1; }
    if [[ -e $VENV_DIR ]] && ! owned_venv; then
        error "拒绝修改非本工具管理的目录：$VENV_DIR"; return 1
    fi
    if [[ -e $LINK_NAME || -L $LINK_NAME ]] && ! grep -q '^# subtitle-sync managed entry$' "$LINK_NAME" 2>/dev/null; then
        error "快捷命令已被其他工具占用：$LINK_NAME"; return 1
    fi
    for pkg in ffmpeg python3 python3-venv; do
        [[ $(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null) == 'install ok installed' ]] || missing+=("$pkg")
    done
    if (( ${#missing[@]} )); then
        apt-get update && apt-get install -y "${missing[@]}" || return 1
    fi
    mkdir -p -- "$VENV_DIR" && touch "$VENV_DIR/.subtitle-sync-owned" || return 1
    python3 -m venv "$VENV_DIR" || return 1
    install_python_packages || return 1
    if [[ $SCRIPT_PATH != "$LINK_NAME" ]]; then
        install -m 755 -- "$SCRIPT_PATH" "$LINK_NAME" || return 1
    fi
    printf '%s安装完成，可运行 subtitle-sync。%s\n' "$GREEN" "$RESET"
}

install_python_packages() {
    # 由 pip 解析实际版本依赖，不再维护过时的手写依赖清单。
    "$VENV_DIR/bin/python" -m pip install --upgrade ffsubsync || return 1
    "$VENV_DIR/bin/python" -m pip check && ready || {
        error '组件验证失败，请检查上面的安装信息。'; return 1
    }
}

update_components() {
    local snapshot
    owned_venv && [[ -x $VENV_DIR/bin/python ]] || { error '请先安装组件。'; return 1; }
    snapshot=$(mktemp -d "${VENV_DIR%/*}/.subtitle-sync-update.XXXXXX") || return 1
    if ! cp -a -- "$VENV_DIR/." "$snapshot/"; then
        rm -rf -- "$snapshot"; return 1
    fi
    UPDATE_BACKUP=$snapshot
    if install_python_packages; then
        rm -rf -- "$UPDATE_BACKUP"; UPDATE_BACKUP=''
        printf '%sFFsubsync 更新完成。%s\n' "$GREEN" "$RESET"
    else
        printf '%s更新失败，恢复原环境。%s\n' "$YELLOW" "$RESET"
        rm -rf -- "$VENV_DIR"
        mv -- "$UPDATE_BACKUP" "$VENV_DIR" || return 1
        UPDATE_BACKUP=''
        return 1
    fi
}

uninstall_components() {
    local answer
    printf '将删除工具专用环境及快捷命令；保留系统组件和字幕。\n'
    read -r -p '确认卸载？[y/N]：' answer || return 1
    [[ $answer == [yY] ]] || { printf '已取消。\n'; return 0; }
    if [[ -e $VENV_DIR ]]; then
        owned_venv || { error "拒绝删除非本工具管理的目录：$VENV_DIR"; return 1; }
        rm -rf -- "$VENV_DIR" || return 1
    fi
    if [[ -f $LINK_NAME ]] && grep -q '^# subtitle-sync managed entry$' "$LINK_NAME"; then
        rm -f -- "$LINK_NAME" || return 1
    fi
    # 兼容旧脚本：仅清理指向旧专用环境的包装命令。
    if [[ -f /usr/local/bin/ffs ]] && grep -qxF 'exec /opt/ffsubsync-venv/bin/ffs "$@"' /usr/local/bin/ffs; then
        rm -f -- /usr/local/bin/ffs || return 1
    fi
    if [[ -L /usr/local/bin/subsync && $(readlink -- /usr/local/bin/subsync) == */install_subsync.sh ]] &&
        grep -q '^VENV_DIR="/opt/ffsubsync-venv"$' /usr/local/bin/subsync 2>/dev/null; then
        rm -f -- /usr/local/bin/subsync || return 1
    fi
    printf '%s卸载完成。%s\n' "$GREEN" "$RESET"
}

read_path() {
    local prompt=$1 value
    if [[ -t 0 ]]; then
        read -e -r -p "$prompt" value || return 1
    else
        read -r -p "$prompt" value || return 1
    fi
    [[ $value ]] || return 1
    # 只去除成对引号，绝不 eval 用户输入。
    if [[ $value == \"*\" || $value == \'*\' ]]; then
        value=${value:1:${#value}-2}
    fi
    case $value in '~') value=$HOME ;; '~/'*) value="$HOME/${value:2}" ;; esac
    REPLY=$(readlink -e -- "$value" 2>/dev/null) || { error '路径不存在。'; return 2; }
    [[ -f $REPLY && -r $REPLY && -s $REPLY ]] || { error '请选择可读、非空的普通文件。'; return 2; }
}

valid_subtitle() {
    [[ -f $1 && -r $1 && -s $1 ]] || return 1
    case ${1,,} in *.srt|*.ass) return 0 ;; *) return 1 ;; esac
}

select_subtitle() {
    local dir=$1 file choice status
    local -a candidates=()
    while IFS= read -r -d '' file; do
        valid_subtitle "$file" && candidates+=("$file")
    done < <(find "$dir" -maxdepth 1 -type f \( -iname '*.srt' -o -iname '*.ass' \) -print0 | sort -z)
    while true; do
        header '选择字幕'
        if (( ${#candidates[@]} )); then
            for file in "${!candidates[@]}"; do
                printf '  %d  %s\n' "$((file + 1))" "${candidates[file]##*/}"
            done
        else
            printf '同目录未找到可读、非空的 SRT / ASS 字幕。\n'
        fi
        printf '\n  m  手动输入字幕路径\n  0  返回\n'
        if (( ${#candidates[@]} == 1 )); then
            read -r -p '选择 [回车默认 1]：' choice || return 1
            choice=${choice:-1}
        elif (( ${#candidates[@]} == 0 )); then
            choice=m
        else
            read -r -p '选择：' choice || return 1
        fi
        case $choice in
            0) return 1 ;;
            m|M)
                read_path '字幕路径 [空输入返回]：'; status=$?
                (( status != 1 )) || return 1
                (( status == 0 )) || continue
                valid_subtitle "$REPLY" || { error '仅支持 .srt / .ass 字幕。'; continue; }
                return 0 ;;
            *)
                if [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#candidates[@]} )); then
                    REPLY=${candidates[choice-1]}; return 0
                fi
                error '无效选项。' ;;
        esac
    done
}

sync_subtitle() {
    local video subtitle dir base ext output answer backup='' start status
    ready || { error '组件未就绪，请先安装 / 修复组件。'; return 1; }
    header '开始调轴'
    printf '请输入 NAS 上的路径；支持 Tab 补全，空输入返回。\n'
    while true; do
        read_path '视频路径：'; status=$?
        (( status != 1 )) || return 0
        (( status == 0 )) && break
    done
    video=$REPLY; dir=${video%/*}; base=${video##*/}; base=${base%.*}
    while true; do
        select_subtitle "$dir" || return 0
        subtitle=$REPLY; ext=${subtitle##*.}; output="$dir/$base.$ext"
        header '确认任务'
        printf '视频  %s\n字幕  %s\n输出  %s\n\n' "$video" "$subtitle" "$output"
        printf '  y  开始调轴\n  s  重新选择字幕\n  0  返回\n'
        read -r -p '选择 [默认取消]：' answer || return 0
        [[ $answer == [sS] ]] && continue
        [[ $answer == [yY] ]] || return 0
        break
    done
    [[ -w $dir ]] || { error '视频所在目录不可写。'; return 1; }
    if [[ -e $output || -L $output ]]; then
        [[ -f $output && ! -L $output ]] || { error '目标不是普通文件或是符号链接，拒绝替换。'; return 1; }
        printf '%s目标已存在，必须备份后才能替换。%s\n' "$YELLOW" "$RESET"
        read -r -p '备份后替换？[y/N]：' answer || return 0
        [[ $answer == [yY] ]] || return 0
        backup=$(mktemp "$output.bak.XXXXXX") || return 1
        cp -p -- "$output" "$backup" || { rm -f -- "$backup"; return 1; }
        printf '备份  %s\n' "$backup"
    fi
    TEMP_SUB=$(mktemp "$dir/.subtitle-sync.XXXXXX.$ext") || return 1
    start=$SECONDS
    if "$VENV_DIR/bin/ffs" "$video" -i "$subtitle" -o "$TEMP_SUB" && [[ -s $TEMP_SUB ]]; then
        # 新文件继承字幕权限，替换时继承目标权限，供 NAS 播放器读取。
        if ! chmod --reference="${backup:-$subtitle}" -- "$TEMP_SUB"; then
            error '无法设置输出权限，原文件保留。'
            rm -f -- "$TEMP_SUB"; TEMP_SUB=''; return 1
        fi
        # 无覆盖授权时，用硬链接原子发布，避免执行期间新文件被覆盖。
        if [[ $backup ]]; then
            [[ ! -L $output && ! -d $output ]] && mv -f -- "$TEMP_SUB" "$output"
        else
            ln -- "$TEMP_SUB" "$output" && rm -f -- "$TEMP_SUB"
        fi
        status=$?
        if (( status == 0 )); then
            TEMP_SUB=''
            printf '\n%s调轴完成%s\n输出  %s\n耗时  %s 秒\n' "$GREEN" "$RESET" "$output" "$((SECONDS - start))"
            return 0
        fi
        error '写入结果失败，原文件及备份保留。'
    else
        error '调轴失败或输出为空，原字幕保留。'
    fi
    rm -f -- "$TEMP_SUB"; TEMP_SUB=''
    return 1
}

components_menu() {
    local choice
    while true; do
        header '组件管理'
        show_status
        printf '\n  1  安装 / 修复组件\n  2  更新 FFsubsync\n  3  卸载工具组件\n\n  0  返回\n'
        read -r -p '选择 [0–3]：' choice || return
        case $choice in
            1) as_admin install_components install; pause ;;
            2) as_admin update_components update; pause ;;
            3) as_admin uninstall_components uninstall; pause ;;
            0) return ;;
            *) error '无效选项。' ;;
        esac
    done
}

main() {
    local choice
    case ${1:-} in
        install) as_admin install_components install; return $? ;;
        update) as_admin update_components update; return $? ;;
        uninstall) as_admin uninstall_components uninstall; return $? ;;
        status) show_status; return $? ;;
        sync) sync_subtitle; return $? ;;
        '') ;;
        *) printf '用法：%s [install|update|uninstall|status|sync]\n' "${0##*/}"; return 1 ;;
    esac
    while true; do
        header '字幕调轴 · FFsubsync'
        if ready; then printf '%s组件状态：就绪%s\n' "$GREEN" "$RESET"
        else printf '%s组件状态：需要安装 / 修复%s\n' "$YELLOW" "$RESET"; fi
        printf '\n  1  开始调轴\n  2  组件管理\n\n  0  退出\n'
        read -r -p '选择 [0–2]：' choice || return 0
        case $choice in
            1) sync_subtitle; pause ;;
            2) components_menu ;;
            0) return 0 ;;
            *) error '无效选项。' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
