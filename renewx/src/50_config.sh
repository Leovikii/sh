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
__INLINE_CONFIG_XML__
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
