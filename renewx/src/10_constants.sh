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
