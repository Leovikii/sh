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
        echo -e "  ${GREEN}1.${PLAIN} 部署 / 启动容器 ${YELLOW}(自动初始化目录与配置)${PLAIN}"
        echo -e "  ${GREEN}2.${PLAIN} 停止容器"
        echo -e "  ${GREEN}3.${PLAIN} 重启容器"
        echo -e "  ${GREEN}4.${PLAIN} 查看实时日志 (Ctrl+C 返回菜单)"
        echo -e "  ${GREEN}5.${PLAIN} 编辑 Config.xml"
        ui::divider
        echo -e "  ${GREEN}6.${PLAIN} 在线更新本脚本"
        echo -e "  ${GREEN}7.${PLAIN} 备份数据目录"
        echo -e "  ${GREEN}8.${PLAIN} 显示访问信息"
        ui::divider
        echo -e "  ${GREEN}9.${PLAIN} 卸载 (容器 / 镜像 / 数据)"
        echo -e "  ${GREEN}0.${PLAIN} 退出"
        ui::divider
        echo
        local opt
        ui::prompt " 请输入选项 [0-9]: " opt
        case "$opt" in
            1)  renewx::deploy ;;
            2)  renewx::stop ;;
            3)  renewx::restart ;;
            4)  renewx::logs ;;
            5)  renewx::edit_config ;;
            6)  renewx::update_script ;;
            7)  renewx::backup ;;
            8)  renewx::show_access ;;
            9)  renewx::uninstall ;;
            0)  exit 0 ;;
            *)  log::err "无效选项，请重新输入" ;;
        esac
        ui::pause
    done
}
