#!/usr/bin/env bash
# Plasma Login Manager / KWin Wayland：独立的登录界面单屏配置。
set -euo pipefail

usage() {
    cat <<'EOF'
用法：bash cachyos/login_screen_setup.sh [--preview|--apply] [--primary DP-1]
  --preview   输出生成的 JSON，不修改文件（默认）
  --apply     备份后写入 Plasma Login Manager 的显示配置
  --primary   指定保留的接口；省略时从已保存布局的 priority=1 推断
请在普通用户下运行；--apply 内部使用 sudo，不会重启登录服务。
仅支持 Plasma Login Manager 的 KWin Wayland 登录界面，不支持 SDDM。
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
action=--preview
primary=''
while (($#)); do
    case "$1" in
        --preview|--apply) action=$1; shift ;;
        --primary)
            (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || die '--primary 后需要接口名，例如 DP-1'
            primary=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "未知选项：$1" ;;
    esac
done
[[ "$EUID" != 0 ]] || die '请以普通用户运行，不要 sudo 整个脚本'
command -v python3 >/dev/null || die '缺少 python3'
source_config=${XDG_CONFIG_HOME:-$HOME/.config}/kwinoutputconfig.json
[[ -f "$source_config" ]] || die "找不到 $source_config；请先在 KDE 显示设置中保存布局"

generated=$(mktemp)
trap 'rm -f -- "$generated"' EXIT
python3 - "$source_config" "$primary" > "$generated" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        config = json.load(stream)
    if not isinstance(config, list):
        raise ValueError('不支持的 KWin 配置格式')
    groups = {group['name']: group['data'] for group in config}
    if len(groups) != len(config):
        raise ValueError('配置包含重复分组')
    outputs, setups = groups['outputs'], groups['setups']
    if not isinstance(outputs, list) or not outputs or not isinstance(setups, list) or not setups:
        raise ValueError('配置没有显示器或布局')
    names = [output['connectorName'] for output in outputs]
    candidates = set()
    for setup in setups:
        if not setup['outputs']:
            raise ValueError('发现空布局')
        indices = set()
        for output in setup['outputs']:
            index = output['outputIndex']
            if type(index) is not int or not 0 <= index < len(outputs) or index in indices:
                raise ValueError('显示器索引无效或重复')
            indices.add(index)
            if type(output['enabled']) is not bool:
                raise ValueError('显示器 enabled 字段无效')
            if output['enabled'] and output.get('priority') == 1:
                candidates.add(names[index])
    primary = sys.argv[2]
    if not primary:
        if len(candidates) != 1:
            raise ValueError('无法唯一推断主屏，请用 --primary 指定；可用接口：' + ', '.join(names))
        primary = candidates.pop()
    matching = {index for index, name in enumerate(names) if name == primary}
    if not matching:
        raise ValueError('主屏不存在；可用接口：' + ', '.join(names))
    changed = 0
    for setup in setups:
        active = [output for output in setup['outputs'] if output['outputIndex'] in matching]
        if not active:
            # 主屏未连接时保留原布局，避免只连副屏时无法登录。
            continue
        if len(active) != 1:
            raise ValueError('同一布局中主屏接口不唯一')
        for output in setup['outputs']:
            enabled = output is active[0]
            output.update(enabled=enabled, priority=1 if enabled else 0, replicationSource='')
            if enabled:
                output['position'] = {'x': 0, 'y': 0}
        changed += 1
    if not changed:
        raise ValueError('没有包含该主屏的布局')
    print(f'登录主屏：{primary}；生成 {changed} 个单屏布局，主屏缺席的布局保留。', file=sys.stderr)
    json.dump(config, sys.stdout, ensure_ascii=False, indent=4, allow_nan=False)
    print()
except (OSError, ValueError, KeyError, TypeError) as error:
    sys.exit(f'错误：无法生成配置：{error}')
PY

if [[ "$action" == --preview ]]; then
    cat -- "$generated"
    exit 0
fi

manager=$(readlink -f /etc/systemd/system/display-manager.service) || die '未找到登录管理器服务'
[[ "${manager##*/}" == plasmalogin.service ]] || die '当前登录管理器不是 Plasma Login Manager；未写入配置'
account=$(getent passwd plasmalogin) || die '缺少 plasmalogin 账户'
IFS=: read -r _ _ uid gid _ greeter_home _ <<< "$account"
[[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$greeter_home" == /* && "$greeter_home" != / ]] || die '登录账户信息无效'

sudo bash -s -- "$greeter_home" "$uid" "$gid" "$generated" <<'ROOT'
set -euo pipefail
home=$1 uid=$2 gid=$3 generated=$4
config=$home/.config
target=$config/kwinoutputconfig.json
for path in "$home" "$config" "$target"; do
    if [[ -L "$path" ]]; then printf '拒绝覆盖符号链接：%s\n' "$path" >&2; exit 1; fi
done
[[ -d "$home" && ( ! -e "$config" || -d "$config" ) && ( ! -e "$target" || -f "$target" ) ]] || exit 1
if [[ -f "$target" ]] && cmp -s -- "$generated" "$target"; then
    printf '登录显示配置已符合，无需更改。\n'
    exit 0
fi
if [[ ! -d "$config" ]]; then install -d -o "$uid" -g "$gid" -m 700 -- "$config"; fi
backup=$(mktemp -d "$config/login-screen-backup.XXXXXXXX")
if [[ -f "$target" ]]; then
    cp -a -- "$target" "$backup/kwinoutputconfig.json"
else
    touch "$backup/original-absent"
fi
pending=$(mktemp "$config/.kwinoutputconfig.XXXXXXXX")
trap 'rm -f -- "$pending"' EXIT
install -o "$uid" -g "$gid" -m 600 -- "$generated" "$pending"
mv -f -- "$pending" "$target"
printf '已写入：%s\n备份：%s\n重启电脑后验证；本次不会重启登录服务。\n' "$target" "$backup"
ROOT
