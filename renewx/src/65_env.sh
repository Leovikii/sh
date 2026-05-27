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
    log::info "准备安装 Caddy 及配置反代..."
    if ! sys::has_cmd caddy; then
        log::step "安装 Caddy (Debian 官方源)..."
        apt-get update
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt-get update
        apt-get install -y caddy || { log::err "Caddy 安装失败"; return 1; }
    else
        log::info "Caddy 已安装，跳过安装步骤。"
    fi

    log::step "写入 Caddy 反代配置..."
    local domain
    ui::prompt "请输入需要绑定并反代的外部域名 (含端口，如 my.domain.com:8443): " domain
    if [[ -z "$domain" ]]; then
        log::warn "未输入域名，取消反代配置生成。"
        return
    fi

    # 确保 /etc/caddy 和 sites.d 存在
    mkdir -p /etc/caddy/sites.d
    
    # 确保默认的 Caddyfile 包含了 import /etc/caddy/sites.d/*.caddy
    if [[ -f /etc/caddy/Caddyfile ]] && ! grep -q 'import /etc/caddy/sites.d/\*.caddy' /etc/caddy/Caddyfile; then
        echo -e "\nimport /etc/caddy/sites.d/*.caddy" >> /etc/caddy/Caddyfile
    elif [[ ! -f /etc/caddy/Caddyfile ]]; then
        echo "import /etc/caddy/sites.d/*.caddy" > /etc/caddy/Caddyfile
    fi

    # 写入 renewx 专属配置
    cat > /etc/caddy/sites.d/renewx.caddy << EOF
${domain} {
    reverse_proxy 127.0.0.1:1066 {
        # 告诉后端："外部用户使用的是 443 端口，请按这个生成跳转链接"
        header_up X-Forwarded-Port 443
    }

    tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem
}
EOF
    
    log::info "配置已写入: /etc/caddy/sites.d/renewx.caddy"
    log::warn "请确保您已手动将证书放置在: /etc/caddy/certs/cert.pem 和 key.pem"
    if ui::confirm "是否立即重启 Caddy 服务以应用配置?"; then
        systemctl restart caddy && log::info "Caddy 已重启。"
    fi
}

env::menu() {
    while true; do
        ui::clear
        echo -e "════════════════════════════════════════════════"
        echo -e "          ${BLUE}常用环境与依赖安装${PLAIN}"
        echo -e "════════════════════════════════════════════════"
        echo -e "  ${GREEN}1.${PLAIN} 安装 Docker (官方源)"
        echo -e "  ${GREEN}2.${PLAIN} 安装 Caddy  (官方源) + 配置反代"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        ui::divider
        echo
        local opt
        ui::prompt " 请输入选项 [0-2]: " opt
        case "$opt" in
            1) env::install_docker ;;
            2) env::install_caddy ;;
            0) return 0 ;;
            *) log::err "无效选项" ;;
        esac
        ui::pause
    done
}
