#!/bin/bash
#
# renewx.sh - MS365 E5 RenewX 一键部署管理脚本
#
# 本文件是唯一源码，可直接下载、运行和维护。
#

set -uo pipefail

# ==============================================================================
# 全局常量
# ==============================================================================

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="renewx.sh"
INSTALL_PATH="/usr/local/bin/renewx"
CONTAINER_NAME="renewx"
IMAGE_NAME="gladtbam/ms365_e5_renewx:latest"
OLD_CONTAINER_PREFIX="renewx-rollback"

# 脚本自更新源
SCRIPT_URL_RAW="https://raw.githubusercontent.com/Leovikii/sh/main/renewx/renewx.sh"
SCRIPT_URL_CDN="https://cdn.jsdelivr.net/gh/Leovikii/sh@main/renewx/renewx.sh"

# 数据目录
DATA_ROOT="/opt/renewx"
DEPLOY_DIR="${DATA_ROOT}/deploy"
APPDATA_DIR="${DATA_ROOT}/appdata"
KEYS_DIR="${DATA_ROOT}/keys"
CONFIG_FILE="${DEPLOY_DIR}/Config.xml"

HOST_BIND="127.0.0.1"
HOST_PORT="1066"
CONTAINER_PORT="1066"
TZ_VALUE="Asia/Shanghai"

BACKUP_ROOT="/var/backups/renewx"
CADDY_SITE_FILE="/etc/caddy/sites.d/renewx.caddy"
CADDY_IMPORT="import /etc/caddy/sites.d/*.caddy"
LOCK_FILE="/run/lock/renewx-manager.lock"
PAUSED_CONTAINER=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    CYAN=$'\033[36m'
    PLAIN=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" PLAIN=""
fi

cleanup_runtime() {
    if [[ "$PAUSED_CONTAINER" == "1" ]] && command -v docker >/dev/null 2>&1; then
        docker unpause "$CONTAINER_NAME" >/dev/null 2>&1 || true
        PAUSED_CONTAINER=0
    fi
}

on_signal() {
    cleanup_runtime
    printf '\n%s[WARN]%s 接收到退出指令，脚本终止。\n' "$YELLOW" "$PLAIN" >&2
    exit 130
}
trap cleanup_runtime EXIT
trap on_signal INT TERM HUP

# ==============================================================================
# 日志 / UI 工具
# ==============================================================================

log::info() { printf '%s[INFO]%s %s\n' "$GREEN" "$PLAIN" "$*" >&2; }
log::warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
log::err()  { printf '%s[ERROR]%s %s\n' "$RED" "$PLAIN" "$*" >&2; }
log::step() { printf '%s[*]%s %s\n' "$BLUE" "$PLAIN" "$*" >&2; }

ui::clear() {
    [[ -t 1 ]] && command -v clear >/dev/null 2>&1 && clear
    return 0
}
ui::divider() { printf '%s\n' '────────────────────────────────────────────────'; }

ui::confirm() {
    local prompt="$1" ans
    read -r -p "$prompt (y/N): " ans || exit 130
    [[ "${ans,,}" == "y" ]]
}

ui::prompt() {
    local prompt="$1" varname="$2"
    read -r -p "$prompt" "$varname" || exit 130
}

ui::prompt_secret() {
    local prompt="$1" varname="$2"
    read -r -s -p "$prompt" "$varname" || exit 130
    echo >&2
}

ui::pause() {
    read -n 1 -s -r -p "按任意键继续..." || return 1
    printf '\n'
}

# ==============================================================================
# 系统 / Docker 检测
# ==============================================================================

sys::has_cmd() { command -v "$1" &>/dev/null; }

sys::require_root() {
    if [[ $EUID -ne 0 ]]; then
        log::err "请使用 root 用户运行此脚本 (sudo -i)"
        return 1
    fi
}

sys::require_docker() {
    if ! sys::has_cmd docker; then
        log::err "未检测到 Docker，请先安装 Docker (可用主菜单 -> 安装环境依赖)"
        return 1
    fi
    if ! docker info &>/dev/null; then
        log::err "Docker 守护进程未运行，请先启动: systemctl start docker"
        return 1
    fi
    return 0
}

# ==============================================================================
# 容器状态查询
# ==============================================================================

renewx::exists() {
    docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

action::with_lock() {
    if ! sys::has_cmd flock; then
        log::warn "系统缺少 flock，无法启用并发保护"
        "$@"
        return $?
    fi

    local lock_fd rc
    exec {lock_fd}>"$LOCK_FILE" || { log::err "无法创建操作锁: $LOCK_FILE"; return 1; }
    if ! flock -n "$lock_fd"; then
        exec {lock_fd}>&-
        log::err "另一个 RenewX 管理任务正在运行"
        return 1
    fi
    "$@"
    rc=$?
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return "$rc"
}

renewx::running() {
    [[ "$(docker container inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

renewx::status_text() {
    if renewx::running; then
        printf '%s运行中%s\n' "$GREEN" "$PLAIN"
    elif renewx::exists; then
        printf '%s已停止%s\n' "$RED" "$PLAIN"
    else
        printf '%s未部署%s\n' "$YELLOW" "$PLAIN"
    fi
}

renewx::image_id() {
    docker image inspect --format '{{.Id}}' "$IMAGE_NAME" 2>/dev/null \
        | sed 's/sha256://;s/^\(.\{12\}\).*/\1/'
}

renewx::image_text() {
    local id
    id="$(renewx::image_id)"
    [[ -z "$id" ]] && { printf '%s未拉取%s\n' "$YELLOW" "$PLAIN"; return; }
    printf '%s%s%s\n' "$CYAN" "$id" "$PLAIN"
}

# 从 Config.xml 解析端口（仅用于展示，不依赖 GNU grep PCRE）
renewx::cfg_port() {
    [[ -f "$CONFIG_FILE" ]] || { echo "$CONTAINER_PORT"; return; }
    local p
    p=$(sed -n 's:.*<Port>\([^<]*\)</Port>.*:\1:p' "$CONFIG_FILE" 2>/dev/null | head -n1)
    [[ "$p" =~ ^[0-9]+$ ]] || p="$CONTAINER_PORT"
    echo "${p:-$CONTAINER_PORT}"
}

# ==============================================================================
# Config.xml 写入；模板直接嵌入本脚本。
# ==============================================================================

renewx::xml_escape() {
    awk 'BEGIN { ORS = "" }
    {
        if (NR > 1) printf "\n"
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if      (c == "&")  printf "&amp;"
            else if (c == "<")  printf "&lt;"
            else if (c == ">")  printf "&gt;"
            else if (c == "\"") printf "&quot;"
            else if (c == "\047") printf "&apos;"
            else                  printf "%s", c
        }
    }'
}

renewx::write_config() {
    local password="$1"
    local escaped_password tmp
    escaped_password="$(printf '%s' "$password" | renewx::xml_escape)" || return 1
    tmp="$(mktemp "${DEPLOY_DIR}/.Config.xml.XXXXXX")" || {
        log::err "无法在配置目录创建临时文件"
        return 1
    }

    if ! cat > "$tmp" <<CONFIG_EOF
<?xml version="1.0" encoding="utf-8" ?>
<Configuration>
	<!--站点服务器基本配置-->
	<Serivce>
		<!--服务访问端口-->
		<Port>1066</Port>
		<!--管理员密码(管理员登录路由/Admin/Login) 重要：首次启动前必须更改-->
		<LoginPassword>${escaped_password}</LoginPassword>
		<!--是否启用内核多线程支持-->
		<CoreMultiThread>true</CoreMultiThread>
		<!--网站备案（选填）-->
		<ICP>
			<!--备案显示文本-->
			<Text></Text>
			<!--备案管理查询机构跳转链接-->
			<Link>https://beian.miit.gov.cn</Link>
		</ICP>
		<!--Bootstrap CDN 若要更改请务必使用bootstrap@5.1.3版本（选填）-->
		<CDN>
			<!--Bootstrap CSS文件CDN bootstrap.min.css-->
			<CSS>https://cdn.staticfile.org/bootstrap/5.1.3/css/bootstrap.min.css</CSS>
			<!--Bootstrap JS文件CDN bootstrap.bundle.min.js-->
			<JS>https://cdn.staticfile.org/bootstrap/5.1.3/js/bootstrap.bundle.min.js</JS>
		</CDN>
	</Serivce>
	<!--站点Kestrel服务器HTTPS配置 （只支持IIS证书类型 即PFX格式的证书）-->
	<HTTPS>
		<!--Kestrel是否启用HTTPS(SSL加密传输)-->
		<Enable>false</Enable>
		<!--SSL证书文件名 (需要将PFX格式的SSL证书放置于该配置文件的同级目录Deploy文件夹下) 如e5.sundayrx.net.pfx-->
		<!--不填则默认使用Dev localhost 本地证书-->
		<Certificate></Certificate>
		<!--SSL证书密钥(PFX证书的访问密钥)-->
		<Password></Password>
	</HTTPS>
	<!--共享站点配置,不共享可无视以下内容 (若要共享站点 请自备以下所需的配置信息 且配置中HTTPS必须启用)-->
	<ShareSite>
		<!--是否启用站点共享-->
		<Enable>false</Enable>
		<!--SMTP邮件发送支持-->
		<SMTP>
			<!--发件邮箱-->
			<Email></Email>
			<!--邮箱密钥-->
			<Password></Password>
			<!--SMTP服务器地址-->
			<Host></Host>
			<!--SMTP服务器端口-->
			<Port>587</Port>
			<!--SMTP服务器是否使用SSL传输-->
			<EnableSSL>true</EnableSSL>
		</SMTP>
		<!--第三方OAuth登录支持(至少启用以下一种OAuth否则其他用户无法注册)-->
		<OAuth>
			<!--微软登录授权-->
			<Microsoft>
				<!--是否启用该OAuth-->
				<Enable>true</Enable>
				<!--应用程序Id-->
				<ClientId></ClientId>
				<!--应用程序访问机密-->
				<ClientSecret></ClientSecret>
			</Microsoft>
			<!--GitHub登录授权-->
			<Github>
				<!--是否启用该OAuth-->
				<Enable>true</Enable>
				<!--应用程序Id-->
				<ClientId></ClientId>
				<!--应用程序访问机密-->
				<ClientSecret></ClientSecret>
			</Github>
		</OAuth>
		<!--站点系统设置-->
		<System>
			<!--站点启动后默认是否允许用户注册 建议为false-->
			<AllowRegister>false</AllowRegister>
			<!--站点启动后默认公告（换行符请使用 &#x000D;&#x000A; 进行换行）-->
			<Notice></Notice>
			<!--站点运营者-->
			<Master></Master>
			<!--站点运营者推广链接-->
			<MasterLink></MasterLink>
			<!--站点新用户默认配额数-->
			<DefaultQuota>1</DefaultQuota>
			<!--站点自动特赦时间间隔 （单位：天 至少30天）-->
			<AutoSpecialPardonInterval>30</AutoSpecialPardonInterval>
		</System>
	</ShareSite>
</Configuration>
CONFIG_EOF
    then
        rm -f "$tmp"
        return 1
    fi

    chmod 0640 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$CONFIG_FILE"
}

# 交互式收集管理员密码：两次输入校验、空值拒绝
renewx::ask_password() {
    local pw1 pw2
    while :; do
        ui::prompt_secret "请输入管理员登录密码（不会回显）: " pw1
        if [[ -z "$pw1" ]]; then
            log::warn "密码不能为空，请重新输入"
            continue
        fi
        ui::prompt_secret "请再次输入以确认: " pw2
        if [[ "$pw1" != "$pw2" ]]; then
            log::warn "两次输入不一致，请重新输入"
            continue
        fi
        printf '%s' "$pw1"
        return 0
    done
}

# ==============================================================================
# 业务动作
# ==============================================================================

# 准备数据目录与 Config.xml
# 已存在的 Config.xml 默认保留（用户可能修改过密码 / OAuth）
renewx::prepare() {
    log::step "准备数据目录: $DATA_ROOT"
    mkdir -p "$DEPLOY_DIR" "$APPDATA_DIR" "$KEYS_DIR" || {
        log::err "无法创建数据目录"
        return 1
    }
    chmod 0755 "$DATA_ROOT" "$DEPLOY_DIR" "$APPDATA_DIR" "$KEYS_DIR" || return 1

    if [[ -f "$CONFIG_FILE" ]]; then
        log::info "检测到已存在的 Config.xml，保留现有配置"
        if ui::confirm "是否重置为新密码并覆盖配置?"; then
            local bak="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
            cp -a "$CONFIG_FILE" "$bak" || { log::err "配置备份失败"; return 1; }
            log::info "原配置已备份: $bak"
        else
            return 0
        fi
    fi

    echo
    log::step "设置管理员密码（用于 /Admin/Login 登录）"
    local password
    password="$(renewx::ask_password)" || return 1
    renewx::write_config "$password" || { log::err "Config.xml 生成失败"; return 1; }
    log::info "Config.xml 已写入: $CONFIG_FILE"
}

renewx::create_container() {
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --label com.centurylinklabs.watchtower.enable=false \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        -e "TZ=${TZ_VALUE}" \
        -v "${DEPLOY_DIR}:/renewx/Deploy/" \
        -v "${APPDATA_DIR}:/renewx/appdata/" \
        -v "${KEYS_DIR}:/root/.aspnet/DataProtection-Keys" \
        -p "${HOST_BIND}:${HOST_PORT}:${CONTAINER_PORT}" \
        "$IMAGE_NAME" >/dev/null
}

# 部署/启动：合并目录创建、密码设置、镜像拉取、容器创建
renewx::deploy() {
    sys::require_docker || return 1

    if renewx::running; then
        log::info "容器已在运行中"
        return 0
    fi

    if renewx::exists; then
        log::step "容器已存在，启动中..."
        if docker start "$CONTAINER_NAME" >/dev/null; then
            sleep 2
            if renewx::running; then
                log::info "容器已启动"
                renewx::show_access
                return 0
            fi
            log::err "容器启动后立即退出，请查看日志"
            docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
            return 1
        fi
        log::err "启动失败，请查看日志"
        return 1
    fi

    renewx::prepare || return 1

    log::step "拉取镜像 $IMAGE_NAME ..."
    if ! docker pull "$IMAGE_NAME"; then
        log::err "镜像拉取失败"
        return 1
    fi

    log::step "创建并启动容器..."
    if renewx::create_container; then
        sleep 2
        if renewx::running; then
            log::info "容器创建成功"
            renewx::show_access
        else
            log::err "容器已创建但未保持运行，最近日志如下"
            docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
            return 1
        fi
    else
        log::err "容器创建失败，请查看 docker 日志"
        return 1
    fi
}

# 更新容器：先拉取镜像，再以旧容器作为可回滚副本重建。
renewx::update_container() {
    sys::require_docker || return 1
    renewx::exists || { log::err "容器不存在，请先部署"; return 1; }

    local current_image latest_image rollback_name was_running=0
    current_image="$(docker container inspect --format '{{.Image}}' "$CONTAINER_NAME")" || return 1
    renewx::running && was_running=1

    log::step "拉取最新镜像 $IMAGE_NAME ..."
    docker pull "$IMAGE_NAME" || { log::err "镜像拉取失败，原容器未修改"; return 1; }
    latest_image="$(docker image inspect --format '{{.Id}}' "$IMAGE_NAME" 2>/dev/null)"
    if [[ -n "$latest_image" && "$current_image" == "$latest_image" ]]; then
        log::info "容器已使用最新镜像"
        return 0
    fi

    rollback_name="${OLD_CONTAINER_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    if (( was_running )) && ! docker stop "$CONTAINER_NAME" >/dev/null; then
        log::err "无法停止旧容器，更新已取消"
        return 1
    fi
    if ! docker rename "$CONTAINER_NAME" "$rollback_name"; then
        (( was_running )) && docker start "$CONTAINER_NAME" >/dev/null || true
        log::err "无法创建回滚容器，更新已取消"
        return 1
    fi

    if renewx::create_container; then
        sleep 3
    fi
    if renewx::running; then
        if ! docker rm -f "$rollback_name" >/dev/null 2>&1; then
            log::warn "新容器已运行，但旧回滚容器未能删除: $rollback_name"
        fi
        log::info "容器更新完成"
        renewx::show_access
        return 0
    fi

    log::err "新容器启动失败，正在恢复旧容器"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if docker rename "$rollback_name" "$CONTAINER_NAME"; then
        if (( was_running )) && ! docker start "$CONTAINER_NAME" >/dev/null; then
            log::err "旧容器名称已恢复，但启动失败"
        else
            log::warn "旧容器已恢复"
        fi
    else
        log::err "自动回滚失败，旧容器仍保留为: $rollback_name"
    fi
    return 1
}

renewx::stop() {
    sys::require_docker || return 1
    if ! renewx::running; then
        log::warn "容器未在运行"
        return 0
    fi
    log::step "停止容器..."
    docker stop "$CONTAINER_NAME" >/dev/null && log::info "已停止"
}

renewx::restart() {
    sys::require_docker || return 1
    if ! renewx::exists; then
        log::err "容器不存在，请先执行菜单 [2] 部署"
        return 1
    fi
    log::step "重启容器..."
    if docker restart "$CONTAINER_NAME" >/dev/null; then
        sleep 2
        renewx::running && { log::info "已重启"; return 0; }
    fi
    log::err "容器重启失败"
    return 1
}

# 查看实时日志：Docker 接收 Ctrl+C，脚本忽略本次 INT 并返回菜单。
renewx::logs() {
    sys::require_docker || return 1
    if ! renewx::exists; then
        log::err "容器不存在"
        return 1
    fi
    log::info "实时日志 — Ctrl+C 退出 (不会终止容器)"
    echo
    trap ':' INT
    docker logs -f --tail 100 "$CONTAINER_NAME" 2>&1 || true
    trap on_signal INT
}

renewx::edit_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log::err "Config.xml 不存在，请先执行菜单 [2] 部署"
        return 1
    fi
    local editor="${EDITOR:-}"
    if [[ -z "$editor" ]]; then
        if   sys::has_cmd nano; then editor="nano"
        elif sys::has_cmd vim;  then editor="vim"
        elif sys::has_cmd vi;   then editor="vi"
        else log::err "未找到可用编辑器 (nano/vim/vi)，请手动编辑: $CONFIG_FILE"; return 1
        fi
    fi
    "$editor" "$CONFIG_FILE"
    log::info "Config.xml 已保存"
    if renewx::running && ui::confirm "配置已修改，是否立即重启容器使其生效?"; then
        renewx::restart
    fi
}

renewx::update_script() {
    local self target target_dir tmp fetcher url downloaded=0 shortcut_tmp
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    if [[ -f "$self" && -w "$self" && "$self" != /dev/fd/* ]]; then
        target="$self"
    else
        target="$INSTALL_PATH"
    fi
    if [[ -e "$target" ]] && ! grep -q '^SCRIPT_NAME="renewx.sh"$' "$target"; then
        log::err "目标文件不是 RenewX 管理脚本，拒绝覆盖: $target"
        return 1
    fi
    target_dir="$(dirname "$target")"
    [[ -d "$target_dir" && -w "$target_dir" ]] || {
        log::err "更新目录不可写: $target_dir"
        return 1
    }

    if   sys::has_cmd curl; then fetcher="curl"
    elif sys::has_cmd wget; then fetcher="wget"
    else log::err "未找到 curl 或 wget，无法在线更新"; return 1
    fi

    tmp="$(mktemp "${target_dir}/.renewx.update.XXXXXX")" || {
        log::err "无法创建同目录更新文件"
        return 1
    }

    for url in "$SCRIPT_URL_RAW" "$SCRIPT_URL_CDN"; do
        log::step "尝试下载: $url"
        if [[ "$fetcher" == "curl" ]]; then
            curl -fL --retry 2 --connect-timeout 10 --max-time 90 -o "$tmp" "$url" && downloaded=1
        else
            wget -q --timeout=20 --tries=2 -O "$tmp" "$url" && downloaded=1
        fi
        (( downloaded )) && [[ -s "$tmp" ]] && break
    done
    if (( ! downloaded )) || [[ ! -s "$tmp" ]]; then
        log::err "原始地址与 CDN 地址均下载失败"
        rm -f "$tmp"
        return 1
    fi

    if ! head -n1 "$tmp" | grep -q '^#!/.*bash' ||
       ! grep -q '^SCRIPT_NAME="renewx.sh"$' "$tmp"; then
        log::err "下载内容不像 shell 脚本，已放弃更新"
        rm -f "$tmp"
        return 1
    fi
    if ! bash -n "$tmp"; then
        log::err "新脚本语法检查未通过，已放弃更新"
        rm -f "$tmp"
        return 1
    fi

    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        log::info "已是最新版本，无需更新"
        rm -f "$tmp"
        return 0
    fi

    if [[ -f "$target" ]]; then
        local bak="${target}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$target" "$bak" || { log::err "备份失败"; rm -f "$tmp"; return 1; }
        log::info "原脚本已备份: $bak"
    fi

    chmod 0755 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target" || { log::err "原子替换失败"; rm -f "$tmp"; return 1; }

    if [[ "$target" != "$INSTALL_PATH" ]]; then
        if [[ -e "$INSTALL_PATH" ]] && ! grep -q '^SCRIPT_NAME="renewx.sh"$' "$INSTALL_PATH"; then
            log::warn "快捷指令路径被其他文件占用，未同步: $INSTALL_PATH"
            log::info "脚本已更新，请重新运行: $target"
            exit 0
        fi
        shortcut_tmp="$(mktemp /usr/local/bin/.renewx.update.XXXXXX 2>/dev/null)" || shortcut_tmp=""
        if [[ -z "$shortcut_tmp" ]] ||
           ! install -m 0755 "$target" "$shortcut_tmp" ||
           ! mv -f "$shortcut_tmp" "$INSTALL_PATH"; then
            [[ -n "$shortcut_tmp" ]] && rm -f "$shortcut_tmp"
            log::warn "脚本已更新，但快捷指令同步失败: $INSTALL_PATH"
        fi
    fi

    log::info "脚本已更新，请重新运行: $target"
    exit 0
}

renewx::backup() {
    if [[ ! -d "$DATA_ROOT" ]]; then
        log::err "数据目录不存在，无可备份内容"
        return 1
    fi
    mkdir -p "$BACKUP_ROOT" || { log::err "无法创建备份目录"; return 1; }
    local stamp tarball errlog
    stamp="$(date +%Y%m%d-%H%M%S)"
    tarball="${BACKUP_ROOT}/renewx-${stamp}.tar.gz"
    errlog="$(mktemp)" || return 1

    if renewx::running; then
        log::step "暂停容器以获得一致性备份..."
        docker pause "$CONTAINER_NAME" >/dev/null || {
            log::err "无法暂停容器，备份已取消"
            rm -f "$errlog"
            return 1
        }
        PAUSED_CONTAINER=1
    fi

    log::step "打包 $DATA_ROOT -> $tarball"
    if tar -czf "$tarball" -C "$(dirname "$DATA_ROOT")" "$(basename "$DATA_ROOT")" 2>"$errlog"; then
        cleanup_runtime
        chmod 0600 "$tarball" || log::warn "无法收紧备份文件权限"
        log::info "备份完成: $tarball"
        log::info "大小: $(du -h "$tarball" | awk '{print $1}')"
        rm -f "$errlog"
    else
        cleanup_runtime
        log::err "备份失败，错误信息如下:"
        sed 's/^/    /' "$errlog" >&2
        rm -f "$tarball" "$errlog"
        return 1
    fi
}

renewx::show_access() {
    local port
    port="$(renewx::cfg_port)"
    printf '\n  %s━━━ RenewX 访问信息 ━━━%s\n' "$GREEN" "$PLAIN"
    printf '  本机访问 : %shttp://%s:%s%s\n' "$BLUE" "$HOST_BIND" "$port" "$PLAIN"
    printf '  管理路由 : %shttp://%s:%s/Admin/Login%s\n' "$BLUE" "$HOST_BIND" "$port" "$PLAIN"
    printf '  管理密码 : %s（已在部署时设置，遗忘可在菜单 [7] 编辑 Config.xml 查看）%s\n' "$YELLOW" "$PLAIN"
    printf '  端口绑定 : %s:%s (仅本机)\n' "$HOST_BIND" "$HOST_PORT"
    printf '  %s━━━━━━━━━━━━━━━━━━━━━━%s\n' "$GREEN" "$PLAIN"
    printf '  %s提示%s: 端口仅监听 127.0.0.1，外网访问需配置反代（如 Caddy）\n' "$CYAN" "$PLAIN"
}

renewx::uninstall() {
    log::warn "即将卸载 RenewX"
    ui::confirm "确认移除 RenewX 容器和管理快捷指令?" || {
        log::info "已取消卸载"
        return 0
    }

    if sys::has_cmd docker && renewx::exists; then
        log::step "移除容器..."
        if docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1; then
            log::info "容器已移除"
        else
            log::err "容器移除失败，为保护数据已终止卸载"
            return 1
        fi
    else
        log::info "容器不存在，跳过"
    fi

    if sys::has_cmd docker && ui::confirm "是否一并删除本地镜像 ${IMAGE_NAME} ?"; then
        if docker rmi "$IMAGE_NAME" >/dev/null 2>&1; then
            log::info "镜像已删除"
        else
            log::warn "镜像删除失败 (可能仍被引用)"
        fi
    fi

    if [[ -d "$DATA_ROOT" ]]; then
        echo
        log::warn "⚠ 数据目录 $DATA_ROOT 包含 Config.xml 与运行时数据"
        log::warn "  删除后无法恢复（管理员密码、OAuth 配置、共享站点数据全部丢失）"
        local delete_token
        ui::prompt "输入 DELETE 确认永久删除数据，其他输入将保留: " delete_token
        if [[ "$delete_token" == "DELETE" ]]; then
            [[ "$DATA_ROOT" == "/opt/renewx" ]] || {
                log::err "数据目录安全校验失败，拒绝删除: $DATA_ROOT"
                return 1
            }
            rm -rf "$DATA_ROOT"
            log::info "数据目录已删除"
        else
            log::info "已保留 $DATA_ROOT"
        fi
    fi

    # 清理快捷指令
    if [[ -f "$INSTALL_PATH" ]] && grep -q '^SCRIPT_NAME="renewx.sh"$' "$INSTALL_PATH"; then
        rm -f "$INSTALL_PATH"
        log::info "全局快捷指令 ($INSTALL_PATH) 已移除"
    fi

    if [[ -f "$CADDY_SITE_FILE" ]] && ui::confirm "是否删除 RenewX 的 Caddy 站点配置?"; then
        rm -f "$CADDY_SITE_FILE"
        if sys::has_cmd caddy && caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
            systemctl reload caddy 2>/dev/null || true
        fi
        log::info "RenewX Caddy 站点配置已删除"
    fi

    log::info "RenewX 卸载完成；共享的 Docker 与 Caddy 环境已保留"
}

renewx::configure_caddy() {
    sys::require_docker || return 1
    sys::has_cmd caddy || {
        log::err "未安装 Caddy，请先从环境菜单安装"
        return 1
    }
    renewx::exists || {
        log::err "RenewX 尚未部署"
        return 1
    }

    local site_addr port temp_site caddy_backup="" site_backup="" main_existed=0
    ui::prompt "请输入域名或域名:端口（如 renewx.example.com）: " site_addr
    if [[ ! "$site_addr" =~ ^([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+(:[0-9]{1,5})?$ ]]; then
        log::err "地址格式无效"
        return 1
    fi
    if [[ "$site_addr" == *:* ]]; then
        port="${site_addr##*:}"
        (( 10#$port >= 1 && 10#$port <= 65535 )) || {
            log::err "端口必须在 1-65535 之间"
            return 1
        }
    fi

    mkdir -p /etc/caddy/sites.d || return 1
    chmod 0755 /etc/caddy/sites.d || return 1
    temp_site="$(mktemp /etc/caddy/sites.d/.renewx.caddy.XXXXXX)" || return 1
    cat > "$temp_site" <<EOF
${site_addr} {
    reverse_proxy ${HOST_BIND}:${HOST_PORT}
}
EOF
    chmod 0644 "$temp_site" || { rm -f "$temp_site"; return 1; }

    if ! caddy validate --adapter caddyfile --config "$temp_site" >/dev/null 2>&1; then
        rm -f "$temp_site"
        log::err "生成的 Caddy 配置未通过校验"
        return 1
    fi

    if [[ -f /etc/caddy/Caddyfile ]]; then
        main_existed=1
        caddy_backup="$(mktemp)" || { rm -f "$temp_site"; return 1; }
        cp -a /etc/caddy/Caddyfile "$caddy_backup" || {
            rm -f "$temp_site" "$caddy_backup"
            return 1
        }
    fi
    if [[ -f "$CADDY_SITE_FILE" ]]; then
        site_backup="$(mktemp)" || {
            rm -f "$temp_site" "$caddy_backup"
            return 1
        }
        cp -a "$CADDY_SITE_FILE" "$site_backup" || {
            rm -f "$temp_site" "$caddy_backup" "$site_backup"
            return 1
        }
    fi

    if (( main_existed )); then
        if ! grep -Fxq "$CADDY_IMPORT" /etc/caddy/Caddyfile; then
            printf '\n%s\n' "$CADDY_IMPORT" >> /etc/caddy/Caddyfile || {
                cp -a "$caddy_backup" /etc/caddy/Caddyfile || true
                rm -f "$temp_site" "$caddy_backup" "$site_backup"
                return 1
            }
        fi
    elif ! printf '%s\n' "$CADDY_IMPORT" > /etc/caddy/Caddyfile; then
        rm -f "$temp_site" "$site_backup"
        return 1
    fi
    if ! mv -f "$temp_site" "$CADDY_SITE_FILE"; then
        if (( main_existed )); then
            cp -a "$caddy_backup" /etc/caddy/Caddyfile || true
        else
            rm -f /etc/caddy/Caddyfile
        fi
        rm -f "$temp_site" "$caddy_backup" "$site_backup"
        return 1
    fi
    caddy fmt --overwrite "$CADDY_SITE_FILE" >/dev/null 2>&1 || true

    if ! caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        log::err "完整 Caddy 配置校验失败，正在回滚"
        if [[ -n "$site_backup" ]]; then
            cp -a "$site_backup" "$CADDY_SITE_FILE"
        else
            rm -f "$CADDY_SITE_FILE"
        fi
        if [[ -n "$caddy_backup" ]]; then
            cp -a "$caddy_backup" /etc/caddy/Caddyfile
        else
            rm -f /etc/caddy/Caddyfile
        fi
        rm -f "$site_backup" "$caddy_backup"
        return 1
    fi

    if ! systemctl reload caddy; then
        log::err "Caddy 重载失败，正在恢复原配置"
        if [[ -n "$site_backup" ]]; then
            cp -a "$site_backup" "$CADDY_SITE_FILE" || true
        else
            rm -f "$CADDY_SITE_FILE"
        fi
        if [[ -n "$caddy_backup" ]]; then
            cp -a "$caddy_backup" /etc/caddy/Caddyfile || true
        else
            rm -f /etc/caddy/Caddyfile
        fi
        systemctl reload caddy >/dev/null 2>&1 || true
        rm -f "$site_backup" "$caddy_backup"
        return 1
    fi
    rm -f "$site_backup" "$caddy_backup"
    log::info "Caddy 反向代理已配置: https://$site_addr"
}

# ==============================================================================
# 环境依赖管理 (Docker / Caddy)
# ==============================================================================

env::install_docker() {
    log::info "准备安装 Docker 环境..."
    if sys::has_cmd docker; then
        log::info "Docker 已安装，跳过"
        systemctl enable --now docker >/dev/null 2>&1 || true
        return 0
    fi
    sys::has_cmd apt-get || { log::err "Docker 自动安装仅支持 Debian/Ubuntu/Linux Mint"; return 1; }
    sys::has_cmd dpkg || { log::err "未找到 dpkg，无法识别系统架构"; return 1; }
    sys::has_cmd systemctl || { log::err "仅支持使用 systemd 的系统"; return 1; }

    local distro_id repo_os codename architecture key_tmp
    distro_id="" repo_os="" codename=""
    [[ -r /etc/os-release ]] || { log::err "无法读取 /etc/os-release"; return 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    distro_id="${ID:-}"
    case "$distro_id" in
        ubuntu)    repo_os="ubuntu"; codename="${VERSION_CODENAME:-}" ;;
        debian)    repo_os="debian"; codename="${VERSION_CODENAME:-}" ;;
        linuxmint) repo_os="ubuntu"; codename="${UBUNTU_CODENAME:-}" ;;
        *)
            log::err "暂不支持自动安装 Docker: ${PRETTY_NAME:-$distro_id}"
            return 1
            ;;
    esac
    case "$codename" in ''|*[!a-zA-Z0-9._-]*) log::err "无法识别基础发行版代号"; return 1 ;; esac
    architecture="$(dpkg --print-architecture)" || return 1

    log::step "配置 Docker 官方 ${repo_os}/${codename} 软件源..."
    # 清理此前失败安装可能遗留的错误 Docker 发行版源。
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update || return 1
    apt-get install -y ca-certificates curl || return 1
    install -m 0755 -d /etc/apt/keyrings || return 1
    key_tmp="$(mktemp)" || return 1
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 90 \
        -o "$key_tmp" "https://download.docker.com/linux/${repo_os}/gpg"; then
        rm -f "$key_tmp"
        log::err "Docker 仓库签名密钥下载失败"
        return 1
    fi
    if ! install -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc; then
        rm -f "$key_tmp"
        return 1
    fi
    rm -f "$key_tmp"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$architecture" "$repo_os" "$codename" > /etc/apt/sources.list.d/docker.list || return 1

    if ! apt-get update ||
       ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        log::err "Docker 软件包安装失败"
        return 1
    fi
    systemctl enable --now docker || { log::err "Docker 服务启动失败"; return 1; }
    docker info >/dev/null 2>&1 || { log::err "Docker 守护进程不可用"; return 1; }
    log::info "Docker 安装完成并已启动"
}

env::install_caddy() {
    log::info "准备安装 Caddy..."
    if sys::has_cmd caddy; then
        log::info "Caddy 已安装，跳过"
        return 0
    fi
    sys::has_cmd apt-get || { log::err "Caddy 自动安装仅支持 Debian/Ubuntu"; return 1; }

    local temp_dir
    temp_dir="$(mktemp -d)" || return 1
    log::step "配置 Caddy 官方软件源..."
    if ! apt-get update ||
       ! apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg; then
        rm -rf "$temp_dir"
        return 1
    fi
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 90 \
            -o "$temp_dir/caddy.gpg" 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' ||
       ! curl -fL --retry 2 --connect-timeout 10 --max-time 90 \
            -o "$temp_dir/caddy.list" 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' ||
       ! gpg --dearmor --yes -o "$temp_dir/caddy-keyring.gpg" "$temp_dir/caddy.gpg"; then
        rm -rf "$temp_dir"
        log::err "Caddy 软件源配置下载失败"
        return 1
    fi
    if ! install -m 0644 "$temp_dir/caddy-keyring.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg ||
       ! install -m 0644 "$temp_dir/caddy.list" /etc/apt/sources.list.d/caddy-stable.list; then
        rm -rf "$temp_dir"
        log::err "无法写入 Caddy 软件源配置"
        return 1
    fi
    rm -rf "$temp_dir"
    apt-get update && apt-get install -y caddy || { log::err "Caddy 安装失败"; return 1; }
    systemctl enable --now caddy >/dev/null 2>&1 || true
    log::info "Caddy 安装完成"
}

env::install_all() {
    env::install_docker && env::install_caddy
}

env::menu() {
    while true; do
        ui::clear
        echo -e "════════════════════════════════════════════════"
        echo -e "          ${BLUE}常用环境与依赖安装${PLAIN}"
        echo -e "════════════════════════════════════════════════"
        echo -e "  ${GREEN}1.${PLAIN} 安装 Docker (官方源)"
        echo -e "  ${GREEN}2.${PLAIN} 安装 Caddy  (官方源)"
        echo -e "  ${GREEN}3.${PLAIN} 一键安装 Docker 与 Caddy"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        ui::divider
        echo
        local opt
        ui::prompt " 请输入选项 [0-3]: " opt
        case "$opt" in
            1) env::install_docker ;;
            2) env::install_caddy ;;
            3) env::install_all ;;
            0) return 0 ;;
            *) log::err "无效选项" ;;
        esac
        ui::pause
    done
}

# ==============================================================================
# 主菜单
# ==============================================================================

menu::main() {
    while true; do
        local st img port
        st="$(renewx::status_text)"
        img="$(renewx::image_text)"
        port="$(renewx::cfg_port)"

        ui::clear
        echo -e "════════════════════════════════════════════════"
        echo -e "          ${BLUE}RenewX 一键部署管理脚本${PLAIN}"
        echo -e "                ${GREEN}v${SCRIPT_VERSION}${PLAIN}"
        echo -e "════════════════════════════════════════════════"
        echo -e " 容器状态 : ${st}"
        echo -e " 镜像版本 : ${img}"
        echo -e " 监听地址 : ${BLUE}${HOST_BIND}:${port}${PLAIN}"
        echo -e " 数据目录 : ${CYAN}${DATA_ROOT}${PLAIN}"
        ui::divider
        echo -e "  ${GREEN}1.${PLAIN} 安装环境依赖 (Docker / Caddy)"
        echo -e "  ${GREEN}2.${PLAIN} 部署 / 启动容器 ${YELLOW}(自动初始化目录与配置)${PLAIN}"
        echo -e "  ${GREEN}3.${PLAIN} 更新容器镜像 ${YELLOW}(失败自动回滚)${PLAIN}"
        echo -e "  ${GREEN}4.${PLAIN} 停止容器"
        echo -e "  ${GREEN}5.${PLAIN} 重启容器"
        echo -e "  ${GREEN}6.${PLAIN} 查看实时日志 (Ctrl+C 返回菜单)"
        echo -e "  ${GREEN}7.${PLAIN} 编辑 Config.xml"
        echo -e "  ${GREEN}8.${PLAIN} 配置 Caddy 反向代理"
        ui::divider
        echo -e "  ${GREEN}9.${PLAIN} 备份数据目录"
        echo -e "  ${GREEN}10.${PLAIN} 显示访问信息"
        echo -e "  ${GREEN}11.${PLAIN} 在线更新本脚本"
        ui::divider
        echo -e "  ${GREEN}12.${PLAIN} 卸载 RenewX（保留 Docker / Caddy）"
        echo -e "  ${GREEN}0.${PLAIN} 退出"
        ui::divider
        echo
        local opt
        ui::prompt " 请输入选项 [0-12]: " opt
        case "$opt" in
            1)  env::menu ;;
            2)  action::with_lock renewx::deploy; ui::pause ;;
            3)  action::with_lock renewx::update_container; ui::pause ;;
            4)  action::with_lock renewx::stop; ui::pause ;;
            5)  action::with_lock renewx::restart; ui::pause ;;
            6)  renewx::logs ;;
            7)  action::with_lock renewx::edit_config; ui::pause ;;
            8)  action::with_lock renewx::configure_caddy; ui::pause ;;
            9)  action::with_lock renewx::backup; ui::pause ;;
            10) renewx::show_access; ui::pause ;;
            11) renewx::update_script; ui::pause ;;
            12) action::with_lock renewx::uninstall; ui::pause ;;
            0)  return 0 ;;
            *)  log::err "无效选项，请重新输入"; ui::pause ;;
        esac
    done
}

# ==============================================================================
# 入口
# ==============================================================================

# ==============================================================================
# 快捷指令自启动安装
# ==============================================================================

sys::install_shortcut() {
    local self tmp
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    if [[ ! -f "$self" ]]; then
        log::warn "当前通过管道或进程替换运行，跳过快捷指令安装"
        return 0
    fi
    [[ "$self" == "$INSTALL_PATH" ]] && return 0
    if [[ -e "$INSTALL_PATH" ]] && ! grep -q '^SCRIPT_NAME="renewx.sh"$' "$INSTALL_PATH"; then
        log::warn "快捷指令路径已被其他文件占用，拒绝覆盖: $INSTALL_PATH"
        return 1
    fi
    [[ -f "$INSTALL_PATH" ]] && cmp -s "$self" "$INSTALL_PATH" && return 0
    tmp="$(mktemp /usr/local/bin/.renewx.install.XXXXXX)" || return 1
    if install -m 0755 "$self" "$tmp" && mv -f "$tmp" "$INSTALL_PATH"; then
        return 0
    fi
    rm -f "$tmp"
    log::warn "无法安装全局快捷指令: $INSTALL_PATH"
    return 1
}

usage() {
    cat <<EOF
用法: bash $SCRIPT_NAME [选项]
  --status       显示当前状态
  -V, --version  显示版本
  -h, --help     显示帮助

无参数运行时进入交互管理菜单。
EOF
}

renewx::print_status() {
    printf 'RenewX %s\n' "$SCRIPT_VERSION"
    if ! sys::has_cmd docker; then
        printf 'Docker: 未安装\n容器: 未部署\n'
        return 0
    fi
    printf 'Docker: 已安装\n'
    if ! docker info >/dev/null 2>&1; then
        printf 'Docker 守护进程: 不可用或当前用户无访问权限\n'
        return 1
    fi
    printf '容器: %b\n' "$(renewx::status_text)"
    printf '镜像: %b\n' "$(renewx::image_text)"
    printf '数据目录: %s\n' "$DATA_ROOT"
}

main() {
    if (( $# > 1 )); then
        log::err "参数过多"
        usage
        return 2
    fi
    case "${1:-}" in
        -h|--help)    usage; return 0 ;;
        -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; return 0 ;;
        --status)     renewx::print_status; return $? ;;
        "") ;;
        *)            log::err "未知选项: $1"; usage; return 2 ;;
    esac
    [[ -t 0 ]] || { log::err "无交互终端，请在终端直接运行脚本"; return 2; }
    sys::require_root || return 1
    sys::install_shortcut || true
    menu::main
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi
