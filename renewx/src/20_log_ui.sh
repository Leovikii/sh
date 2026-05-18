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
