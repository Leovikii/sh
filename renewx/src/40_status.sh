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
