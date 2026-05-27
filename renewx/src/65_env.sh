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
