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
