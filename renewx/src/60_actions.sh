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
