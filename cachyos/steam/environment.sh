# Managed by sh/cachyos/steam_setup.sh; POSIX shell, also sourced by KDE.
# Configuration is data, never shell code. Keep its syntax compatible with environment.d.
steam_env_keys='PROTON_ENABLE_WAYLAND PROTON_DXVK_LOWLATENCY DXVK_FRAME_PACE DXVK_FRAME_RATE VKD3D_FRAME_RATE MESA_SHADER_CACHE_MAX_SIZE LOW_LATENCY_LAYER PROTON_VKD3D_LOWLATENCY PROTON_FSR4_INDICATOR SDL_GAMECONTROLLERTYPE'
steam_legacy_keys='LOW_LATENCY_LAYER_REFLEX DXVK_HDR PROTON_FSR4_UPGRADE'

steam_config_lines() {
    [ -r "$1" ] || { printf '找不到 Steam 配置：%s\n' "$1" >&2; return 1; }
    LC_ALL=C awk '
        /^[[:space:]]*(#|$)/ {next}
        function fail() {printf "Steam 配置第 %d 行无效或参数不受支持\n", NR > "/dev/stderr"; bad=1}
        {
            eq=index($0,"="); key=substr($0,1,eq-1); value=substr($0,eq+1)
            if (!eq || seen[key]++) {fail(); next}
            valid=0
            if (key ~ /^(PROTON_ENABLE_WAYLAND|PROTON_DXVK_LOWLATENCY|LOW_LATENCY_LAYER|PROTON_VKD3D_LOWLATENCY|PROTON_FSR4_INDICATOR)$/)
                valid=(value ~ /^[01]$/)
            if (key ~ /^(DXVK_FRAME_RATE|VKD3D_FRAME_RATE)$/)
                valid=(value ~ /^[1-9][0-9]*$/ && length(value)<=4 && value+0<=1000)
            if (key=="MESA_SHADER_CACHE_MAX_SIZE") valid=(value ~ /^[1-9][0-9]*[GM]$/ && length(value)<=6)
            if (key=="DXVK_FRAME_PACE") valid=(value ~ /^(low-latency-vrr|low-latency|max-frame-latency)$/)
            if (key=="SDL_GAMECONTROLLERTYPE") valid=(value ~ /^0x[0-9a-fA-F]+\/0x[0-9a-fA-F]+=Xbox360$/)
            if (!valid) {fail(); next}
            values[key]=value; lines[++count]=$0
        }
        END {
            if (values["LOW_LATENCY_LAYER"]=="1" && values["PROTON_VKD3D_LOWLATENCY"]=="1") {
                print "Anti-Lag 层不能与实验性 VKD3D 低延迟同时启用" > "/dev/stderr"; bad=1
            }
            if (values["DXVK_FRAME_RATE"]!="" && values["VKD3D_FRAME_RATE"]!="" && values["DXVK_FRAME_RATE"]!=values["VKD3D_FRAME_RATE"]) {
                print "DXVK 与 VKD3D 帧率上限必须一致" > "/dev/stderr"; bad=1
            }
            if (bad) exit 1
            for (i=1;i<=count;i++) print lines[i]
        }
    ' "$1"
}

steam_load_environment() {
    # Validate everything before changing the calling session.
    steam_config_data=$(steam_config_lines "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/gaming.conf") || return 1
    for steam_config_key in $steam_env_keys $steam_legacy_keys; do
        unset "$steam_config_key"
    done
    while IFS= read -r steam_config_line; do
        [ -z "$steam_config_line" ] || export "$steam_config_line"
    done <<EOF_STEAM_ENV
$steam_config_data
EOF_STEAM_ENV
    unset steam_config_data steam_config_key steam_config_line
}
