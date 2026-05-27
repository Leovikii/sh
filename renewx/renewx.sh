#!/bin/bash
#
# renewx.sh - MS365 E5 RenewX 一键部署管理脚本
#
# 由 build.sh 自动拼接生成，请勿直接编辑本文件。
# 源码位于 src/ 与 assets/，运行 `bash build.sh` 重新生成。
#
# Build:    2026-05-27 16:04:44 UTC
# Commit:   68bcff6
#

set -uo pipefail

# ==============================================================================
# 全局常量
# ==============================================================================

SCRIPT_VERSION="1.2.0"
SCRIPT_NAME="renewx.sh"
INSTALL_PATH="/usr/local/bin/renewx"
CONTAINER_NAME="renewx"
IMAGE_NAME="gladtbam/ms365_e5_renewx:latest"

# 脚本自更新源
SCRIPT_URL="https://raw.githubusercontent.com/Leovikii/sh/main/renewx/renewx.sh"

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

# 颜色 — 用 $'...' 让 \033 在赋值时立刻解析为 ESC
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
PLAIN=$'\033[0m'

trap 'echo -e "\n${YELLOW}[WARN]${PLAIN} 接收到退出指令，脚本终止。"; exit 130' INT TERM HUP

# ==============================================================================
# 日志 / UI 工具
# ==============================================================================

log::info() { echo -e "${GREEN}[INFO]${PLAIN} $1" >&2; }
log::warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1" >&2; }
log::err()  { echo -e "${RED}[ERROR]${PLAIN} $1" >&2; }
log::step() { echo -e "${BLUE}[*]${PLAIN} $1" >&2; }

ui::clear()   { clear; }
ui::divider() { echo -e "────────────────────────────────────────────────"; }

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

ui::pause() { read -n 1 -s -r -p "按任意键继续..." || exit 130; echo; }

# ==============================================================================
# 系统 / Docker 检测
# ==============================================================================

sys::has_cmd() { command -v "$1" &>/dev/null; }

sys::require_root() {
    [[ $EUID -ne 0 ]] && { log::err "请使用 root 用户运行此脚本 (sudo -i)"; exit 1; }
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
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

renewx::running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

renewx::status_text() {
    if renewx::running; then
        echo -e "${GREEN}运行中${PLAIN}"
    elif renewx::exists; then
        echo -e "${RED}已停止${PLAIN}"
    else
        echo -e "${YELLOW}未部署${PLAIN}"
    fi
}

renewx::image_id() {
    docker image inspect --format '{{.Id}}' "$IMAGE_NAME" 2>/dev/null \
        | sed 's/sha256://;s/^\(.\{12\}\).*/\1/'
}

renewx::image_text() {
    local id
    id="$(renewx::image_id)"
    [[ -z "$id" ]] && { echo -e "${YELLOW}未拉取${PLAIN}"; return; }
    echo -e "${CYAN}${id}${PLAIN}"
}

# 从 Config.xml 解析端口（仅用于展示）
# 注：grep -oP 依赖 GNU grep（PCRE），常见 Linux 发行版默认满足
renewx::cfg_port() {
    [[ -f "$CONFIG_FILE" ]] || { echo "$CONTAINER_PORT"; return; }
    local p
    p=$(grep -oP '(?<=<Port>)[^<]+' "$CONFIG_FILE" 2>/dev/null | head -n1)
    echo "${p:-$CONTAINER_PORT}"
}

# ==============================================================================
# Config.xml 写入
# 模板由 build.sh 在构建期注入；XML 内的 __ADMIN_PASSWORD__ 占位符
# 在运行时被用户输入的密码替换
# ==============================================================================

renewx::write_config() {
    local password="$1"
    local tmp
    tmp="$(mktemp)" || { log::err "无法创建临时文件"; return 1; }

    cat > "$tmp" <<'CONFIG_EOF'
<?xml version="1.0" encoding="utf-8" ?>
<Configuration>
	<!--站点服务器基本配置-->
	<Serivce>
		<!--服务访问端口-->
		<Port>1066</Port>
		<!--管理员密码(管理员登录路由/Admin/Login) 重要：首次启动前必须更改-->
		<LoginPassword>__ADMIN_PASSWORD__</LoginPassword>
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

    # 用 awk 做字面量替换，避免密码中含 / & \ 等被 sed 解释
    awk -v pw="$password" '{
        gsub(/__ADMIN_PASSWORD__/, pw)
        print
    }' "$tmp" > "$CONFIG_FILE"

    rm -f "$tmp"
    chmod 0640 "$CONFIG_FILE"
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
    mkdir -p "$DEPLOY_DIR" "$APPDATA_DIR" "$KEYS_DIR"
    chmod 0755 "$DATA_ROOT" "$DEPLOY_DIR" "$APPDATA_DIR" "$KEYS_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        log::info "检测到已存在的 Config.xml，保留现有配置"
        if ui::confirm "是否重置为新密码并覆盖配置?"; then
            local bak="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
            cp -a "$CONFIG_FILE" "$bak"
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

    if sys::has_cmd caddy; then
        echo
        log::step "Caddy 反向代理设置"
        if ui::confirm "检测到已安装 Caddy，是否为您生成 RenewX 的反代配置？"; then
            local domain
            ui::prompt "请输入需要绑定并反代的外部域名 (含端口，如 my.domain.com:8443): " domain
            if [[ -n "$domain" ]]; then
                mkdir -p /etc/caddy/sites.d
                
                if [[ -f /etc/caddy/Caddyfile ]] && ! grep -q 'import /etc/caddy/sites.d/\*.caddy' /etc/caddy/Caddyfile; then
                    echo -e "\nimport /etc/caddy/sites.d/*.caddy" >> /etc/caddy/Caddyfile
                elif [[ ! -f /etc/caddy/Caddyfile ]]; then
                    echo "import /etc/caddy/sites.d/*.caddy" > /etc/caddy/Caddyfile
                fi

                cat > /etc/caddy/sites.d/renewx.caddy << EOF
${domain} {
    reverse_proxy 127.0.0.1:1066 {
        # 告诉后端："外部用户使用的是 443 端口，请按这个生成跳转链接"
        header_up X-Forwarded-Port 443
    }

    tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem
}
EOF
                log::info "反代配置已写入: /etc/caddy/sites.d/renewx.caddy"
                log::warn "注意：请确保后续将证书放置在 /etc/caddy/certs/cert.pem 和 key.pem"
                if ui::confirm "是否立即重启 Caddy 服务以应用配置?"; then
                    systemctl restart caddy && log::info "Caddy 已重启。"
                fi
            else
                log::warn "未输入域名，跳过反代配置。"
            fi
        fi
    fi
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
            log::info "容器已启动"
            renewx::show_access
            return 0
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
    if docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --label com.centurylinklabs.watchtower.enable=false \
        -e "TZ=${TZ_VALUE}" \
        -v "${DEPLOY_DIR}:/renewx/Deploy/" \
        -v "${APPDATA_DIR}:/renewx/appdata/" \
        -v "${KEYS_DIR}:/root/.aspnet/DataProtection-Keys" \
        -p "${HOST_BIND}:${HOST_PORT}:${CONTAINER_PORT}" \
        "$IMAGE_NAME" >/dev/null; then
        log::info "容器创建成功"
        renewx::show_access
    else
        log::err "容器创建失败，请查看 docker 日志"
        return 1
    fi
}

renewx::stop() {
    if ! renewx::running; then
        log::warn "容器未在运行"
        return 0
    fi
    log::step "停止容器..."
    docker stop "$CONTAINER_NAME" >/dev/null && log::info "已停止"
}

renewx::restart() {
    if ! renewx::exists; then
        log::err "容器不存在，请先执行菜单 [1] 部署"
        return 1
    fi
    log::step "重启容器..."
    docker restart "$CONTAINER_NAME" >/dev/null && log::info "已重启"
}

# 查看实时日志：本地禁用 INT trap，让 Ctrl+C 仅终止 docker logs，不退出脚本
renewx::logs() {
    if ! renewx::exists; then
        log::err "容器不存在"
        return 1
    fi
    log::info "实时日志 — Ctrl+C 退出 (不会终止容器)"
    echo
    trap - INT
    docker logs -f --tail 100 "$CONTAINER_NAME" 2>&1 || true
    trap 'echo -e "\n${YELLOW}[WARN]${PLAIN} 接收到退出指令，脚本终止。"; exit 130' INT
}

renewx::edit_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log::err "Config.xml 不存在，请先执行菜单 [1] 部署"
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
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    if [[ ! -w "$self" ]]; then
        log::err "脚本文件不可写: $self"
        log::warn "请用 root 权限或检查文件属性后重试"
        return 1
    fi

    local fetcher
    if   sys::has_cmd curl; then fetcher="curl"
    elif sys::has_cmd wget; then fetcher="wget"
    else log::err "未找到 curl 或 wget，无法在线更新"; return 1
    fi

    log::step "下载最新脚本: $SCRIPT_URL"
    local tmp
    tmp="$(mktemp)" || { log::err "无法创建临时文件"; return 1; }

    local ok=0
    if [[ "$fetcher" == "curl" ]]; then
        curl -fsSL --connect-timeout 10 -o "$tmp" "$SCRIPT_URL" && ok=1
    else
        wget -q --timeout=10 -O "$tmp" "$SCRIPT_URL" && ok=1
    fi
    if [[ $ok -ne 1 || ! -s "$tmp" ]]; then
        log::err "下载失败"
        rm -f "$tmp"
        return 1
    fi

    if ! head -n1 "$tmp" | grep -q '^#!.*sh'; then
        log::err "下载内容不像 shell 脚本，已放弃更新"
        rm -f "$tmp"
        return 1
    fi
    if ! bash -n "$tmp"; then
        log::err "新脚本语法检查未通过，已放弃更新"
        rm -f "$tmp"
        return 1
    fi

    if cmp -s "$tmp" "$self"; then
        log::info "已是最新版本，无需更新"
        rm -f "$tmp"
        return 0
    fi

    local bak="${self}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$self" "$bak" || { log::err "备份失败"; rm -f "$tmp"; return 1; }
    log::info "原脚本已备份: $bak"

    if ! cat "$tmp" > "$self"; then
        log::err "写入失败，正在回滚"
        cp -a "$bak" "$self"
        rm -f "$tmp"
        return 1
    fi
    chmod +x "$self"
    rm -f "$tmp"

    log::info "脚本已更新，请重新运行: bash $self"
    exit 0
}

renewx::backup() {
    if [[ ! -d "$DATA_ROOT" ]]; then
        log::err "数据目录不存在，无可备份内容"
        return 1
    fi
    mkdir -p "$BACKUP_ROOT"
    local stamp tarball errlog
    stamp="$(date +%Y%m%d-%H%M%S)"
    tarball="${BACKUP_ROOT}/renewx-${stamp}.tar.gz"
    errlog="$(mktemp)"

    log::step "打包 $DATA_ROOT -> $tarball"
    if tar -czf "$tarball" -C "$(dirname "$DATA_ROOT")" "$(basename "$DATA_ROOT")" 2>"$errlog"; then
        log::info "备份完成: $tarball"
        log::info "大小: $(du -h "$tarball" | awk '{print $1}')"
        rm -f "$errlog"
    else
        log::err "备份失败，错误信息如下:"
        sed 's/^/    /' "$errlog" >&2
        rm -f "$tarball" "$errlog"
        return 1
    fi
}

renewx::show_access() {
    local port
    port="$(renewx::cfg_port)"
    echo
    echo -e "  ${GREEN}━━━ RenewX 访问信息 ━━━${PLAIN}"
    echo -e "  本机访问 : ${BLUE}http://${HOST_BIND}:${port}${PLAIN}"
    echo -e "  管理路由 : ${BLUE}http://${HOST_BIND}:${port}/Admin/Login${PLAIN}"
    echo -e "  管理密码 : ${YELLOW}（已在部署时由您设置，遗忘可在菜单 [5] 编辑 Config.xml 查看）${PLAIN}"
    echo -e "  端口绑定 : ${HOST_BIND}:${HOST_PORT} (仅本机)"
    echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "  ${CYAN}提示${PLAIN}: 端口仅监听 127.0.0.1，外网访问需自行配置反代 (如 Caddy)"
    echo -e "  ${CYAN}反代${PLAIN}: 务必传递 X-Forwarded-Proto / Host 头，避免 ASP.NET 生成错误重定向"
}

renewx::uninstall() {
    log::warn "即将卸载 RenewX"
    echo
    if renewx::exists; then
        log::step "移除容器..."
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        log::info "容器已移除"
    else
        log::info "容器不存在，跳过"
    fi

    if ui::confirm "是否一并删除本地镜像 ${IMAGE_NAME} ?"; then
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
        if ui::confirm "是否删除数据目录? (强烈建议先用菜单 [7] 备份)"; then
            rm -rf "$DATA_ROOT"
            log::info "数据目录已删除"
        else
            log::info "已保留 $DATA_ROOT"
        fi
    fi

    # 清理快捷指令
    if [[ -n "${INSTALL_PATH:-}" && -f "$INSTALL_PATH" ]]; then
        rm -f "$INSTALL_PATH"
        log::info "全局快捷指令 ($INSTALL_PATH) 已移除"
    fi

    if sys::has_cmd caddy; then
        echo
        log::warn "检测到系统安装了 Caddy 环境。"
        if ui::confirm "是否连同 Caddy 一起彻底卸载并清理配置？(慎重，可能影响其他业务)"; then
            log::step "卸载 Caddy..."
            systemctl stop caddy 2>/dev/null || true
            systemctl disable caddy 2>/dev/null || true
            apt-get purge -y caddy >/dev/null 2>&1
            rm -rf /etc/caddy /usr/share/caddy /var/lib/caddy /var/log/caddy
            log::info "Caddy 已被彻底清理"
        fi
    fi

    if sys::has_cmd docker; then
        echo
        log::warn "检测到系统安装了 Docker 引擎。"
        if ui::confirm "是否连同 Docker 一起彻底卸载并清理数据目录？(高危，将丢失所有容器数据)"; then
            log::step "卸载 Docker..."
            systemctl stop docker 2>/dev/null || true
            systemctl disable docker 2>/dev/null || true
            apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io >/dev/null 2>&1
            rm -rf /var/lib/docker /var/lib/containerd /etc/docker
            log::info "Docker 引擎及数据已被彻底清理"
        fi
    fi

    log::info "RenewX 相关组件及脚本清理已完成！"
}

# ==============================================================================
# 环境依赖管理 (Docker / Caddy)
# ==============================================================================

env::install_docker() {
    log::info "准备安装 Docker 环境..."
    if sys::has_cmd docker; then
        log::warn "Docker 已安装，跳过。"
        return
    fi
    log::step "使用官方脚本安装 Docker..."
    curl -fsSL https://get.docker.com | bash || { log::err "Docker 安装失败"; return 1; }
    systemctl enable --now docker
    log::info "Docker 安装完成并已启动。"
}

env::install_caddy() {
    log::info "准备安装 Caddy..."
    if ! sys::has_cmd caddy; then
        log::step "安装 Caddy (Debian 官方源)..."
        apt-get update
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update
        apt-get install -y caddy || { log::err "Caddy 安装失败"; return 1; }
        log::info "Caddy 安装完成。"
    else
        log::info "Caddy 已安装，跳过安装步骤。"
    fi
}

env::install_all() {
    env::install_docker
    env::install_caddy
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
        echo -e "  ${GREEN}3.${PLAIN} 停止容器"
        echo -e "  ${GREEN}4.${PLAIN} 重启容器"
        echo -e "  ${GREEN}5.${PLAIN} 查看实时日志 (Ctrl+C 返回菜单)"
        echo -e "  ${GREEN}6.${PLAIN} 编辑 Config.xml"
        ui::divider
        echo -e "  ${GREEN}7.${PLAIN} 在线更新本脚本"
        echo -e "  ${GREEN}8.${PLAIN} 备份数据目录"
        echo -e "  ${GREEN}9.${PLAIN} 显示访问信息"
        ui::divider
        echo -e "  ${GREEN}10.${PLAIN} 卸载 (容器 / 镜像 / 数据 / 快捷指令)"
        echo -e "  ${GREEN}0.${PLAIN} 退出"
        ui::divider
        echo
        local opt
        ui::prompt " 请输入选项 [0-10]: " opt
        case "$opt" in
            1)  env::menu ;;
            2)  renewx::deploy; ui::pause ;;
            3)  renewx::stop; ui::pause ;;
            4)  renewx::restart; ui::pause ;;
            5)  renewx::logs ;;
            6)  renewx::edit_config; ui::pause ;;
            7)  renewx::update_script; ui::pause ;;
            8)  renewx::backup; ui::pause ;;
            9)  renewx::show_access; ui::pause ;;
            10) renewx::uninstall; ui::pause ;;
            0)  exit 0 ;;
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
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    if [[ "$self" != "$INSTALL_PATH" ]]; then
        if cp "$self" "$INSTALL_PATH" 2>/dev/null; then
            chmod +x "$INSTALL_PATH"
        fi
    fi
}

main() {
    sys::require_root
    sys::install_shortcut
    menu::main "$@"
}

main "$@"

