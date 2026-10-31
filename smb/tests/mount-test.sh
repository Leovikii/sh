#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../mount.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
FSTAB="$TEST_DIR/fstab"
CREDENTIALS_DIR="$TEST_DIR/credentials"
printf '/dev/root / ext4 defaults 0 1\n' > "$FSTAB"
chmod 640 "$FSTAB"
cp -p "$FSTAB" "$TEST_DIR/original"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() { if "$@"; then fail "expected failure: $*"; fi; }

valid_ip 10.9.6.2
for value in 256.1.1.1 01.2.3.4 '1.2.3.4;id' ''; do expect_failure valid_ip "$value"; done
valid_share '共享 disk$'
for value in '/export/OMV' '//host/share' 'a\b' . .. $'a\nb' ''; do expect_failure valid_share "$value"; done
valid_path '/mnt/共享 disk'
expect_failure valid_path relative
expect_failure valid_path $'/mnt/a\nb'
[[ $(fstab_escape '/mnt/a\b c') == '/mnt/a\134b\040c' ]]

command() {
    if [[ $* == '-v mount.cifs' ]]; then return 0; fi
    builtin command "$@"
}
systemctl() {
    printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"
    case $1 in
        daemon-reload) return "${RELOAD_RESULT:-0}" ;;
        is-active) return "${AUTOMOUNT_ACTIVE:-1}" ;;
        start) return "${START_RESULT:-0}" ;;
        stop) return "${STOP_RESULT:-0}" ;;
        *) fail "unexpected systemctl: $*" ;;
    esac
}
timeout() {
    printf '%s\n' "$*" >> "$TEST_DIR/timeout.log"
    shift 2
    "$@"
}
findmnt() {
    if [[ $* == *'-o SOURCE --nofsroot'* ]]; then
        printf '%s\n' "${MOCK_MOUNTED_SOURCE:-$source}"
        return "${VERIFY_RESULT:-0}"
    fi
    return "${MOUNTED_RESULT:-1}"
}

TARGET="$TEST_DIR/挂载 disk"
INPUT=$(printf '%s\n10.9.6.2\n共享 disk\nNAS user\n password,\\$`literal` \n\n%s\n1\ny\ny\n' "$TARGET" "$(id -un)")
mount_share <<< "$INPUT" > "$TEST_DIR/menu.log"
[[ $(stat -c %a "$CREDENTIALS_DIR") == 700 ]]
[[ $(stat -c %a "$TARGET") == 555 ]]
CREDENTIAL=$(find "$CREDENTIALS_DIR" -type f -print)
[[ $(stat -c %a "$CREDENTIAL") == 600 ]]
printf 'username=NAS user\npassword= password,\\$`literal` \ndomain=\n' > "$TEST_DIR/expected.credentials"
cmp "$TEST_DIR/expected.credentials" "$CREDENTIAL"
! grep -Fq 'literal' "$TEST_DIR/menu.log"
! grep -Fq 'literal' "$TEST_DIR/systemctl.log"
! grep -Fq 'literal' "$FSTAB"
[[ $(stat -c %a "$FSTAB") == 640 ]]
cmp "$TEST_DIR/original" "$FSTAB.smb.bak"
PARSED=$(builtin command findmnt --fstab --tab-file "$FSTAB" -rn -t cifs -o SOURCE)
printf -v PARSED '%b' "$PARSED"
[[ $PARSED == '//10.9.6.2/共享 disk' ]]
PARSED=$(builtin command findmnt --fstab --tab-file "$FSTAB" -rn -t cifs -o TARGET)
printf -v PARSED '%b' "$PARSED"
[[ $PARSED == "$TARGET" ]]
read -r SOURCE OPTIONS < <(configured_entry "$TARGET")
[[ ,$OPTIONS, == *,credentials="$CREDENTIAL",* && ,$OPTIONS, == *,vers=3,* && ,$OPTIONS, == *,soft,* ]]
[[ ,$OPTIONS, == *,x-systemd.automount,* && ,$OPTIONS, != *,noauto,* ]]
AUTO_UNIT=$(unit_name "$TARGET" automount)
MOUNT_UNIT=$(unit_name "$TARGET" mount)
grep -Fxq "start $AUTO_UNIT" "$TEST_DIR/systemctl.log"
grep -Fxq "start $MOUNT_UNIT" "$TEST_DIR/systemctl.log"
grep -Fq -- '--kill-after=2s 20s systemctl start' "$TEST_DIR/timeout.log"

# 关闭和重开不访问服务器，也不重新输入凭据。
toggle_autoconnect <<< "$TARGET"$'\ny'
read -r SOURCE OPTIONS < <(configured_entry "$TARGET")
[[ ,$OPTIONS, == *,noauto,* && ,$OPTIONS, != *,x-systemd.automount,* ]]
cp "$FSTAB" "$TEST_DIR/disabled"
mount_share <<< "$TARGET"$'\n'
cmp "$TEST_DIR/disabled" "$FSTAB"
[[ $(find "$CREDENTIALS_DIR" -type f | wc -l) == 1 ]]
toggle_autoconnect <<< "$TARGET"$'\ny'
read -r SOURCE OPTIONS < <(configured_entry "$TARGET")
[[ ,$OPTIONS, == *,x-systemd.automount,* && ,$OPTIONS, != *,noauto,* ]]
START_RESULT=1 expect_failure mount_share <<< "$TARGET"$'\n'
VERIFY_RESULT=1 expect_failure mount_share <<< "$TARGET"$'\n'
MOCK_MOUNTED_SOURCE='//10.9.6.99/wrong' expect_failure mount_share <<< "$TARGET"$'\n'
configured_entry "$TARGET" >/dev/null
[[ -f $CREDENTIAL ]]
AUTOMOUNT_ACTIVE=0 unmount_share <<< "$TARGET"
grep -Fxq "stop $AUTO_UNIT $MOUNT_UNIT" "$TEST_DIR/systemctl.log"
STOP_RESULT=1 expect_failure unmount_share <<< "$TARGET"
configured_entry "$TARGET" >/dev/null

# 刷新失败/超时必须还原；其他工具的挂载不能覆盖。
cp "$FSTAB" "$TEST_DIR/before-reload"
RELOAD_RESULT=1 expect_failure save_entry "$TARGET" '//10.9.6.2/other' "$OPTIONS"
cmp "$TEST_DIR/before-reload" "$FSTAB"
RELOAD_RESULT=124 expect_failure save_entry "$TARGET" '//10.9.6.2/other' "$OPTIONS"
cmp "$TEST_DIR/before-reload" "$FSTAB"
printf '10.9.6.2:/OMV %s nfs defaults 0 0 #nfs-mount.sh\n' "$(fstab_escape "$TEST_DIR/manual")" >> "$FSTAB"
cp "$FSTAB" "$TEST_DIR/with-manual"
expect_failure save_entry "$TEST_DIR/manual" '//10.9.6.2/OMV' "$OPTIONS"
cmp "$TEST_DIR/with-manual" "$FSTAB"

# 只读、关闭开机连接和取消操作。
RO_TARGET="$TEST_DIR/readonly"
RO_INPUT=$(printf '%s\n10.9.6.2\nOMV\nuser\nsecret\nWORKGROUP\n%s\n2\nn\ny\n' "$RO_TARGET" "$(id -un)")
mount_share <<< "$RO_INPUT"
read -r SOURCE OPTIONS < <(configured_entry "$RO_TARGET")
[[ ,$OPTIONS, == *,ro,* && ,$OPTIONS, != *,rw,* && ,$OPTIONS, == *,noauto,* ]]
toggle_autoconnect <<< "$RO_TARGET"$'\ny'
read -r SOURCE OPTIONS < <(configured_entry "$RO_TARGET")
[[ ,$OPTIONS, == *,ro,* && ,$OPTIONS, != *,rw,* ]]
RECONFIG_INPUT=$(printf '%s\n2\n10.9.6.3\nBackup\nnewuser\nnewsecret\n\n%s\n2\nn\ny\n' "$RO_TARGET" "$(id -un)")
# 模拟测试用户拥有的目录；实际脚本仅允许 root 所有的现有目录。
stat() {
    if [[ $* == "-c %u -- $RO_TARGET" ]]; then printf '0\n'; else builtin command stat "$@"; fi
}
mount_share <<< "$RECONFIG_INPUT"
read -r SOURCE OPTIONS < <(configured_entry "$RO_TARGET")
[[ $SOURCE == '//10.9.6.3/Backup' && ,$OPTIONS, == *,ro,* && ,$OPTIONS, == *,noauto,* ]]
unset -f stat
CANCEL_TARGET="$TEST_DIR/cancelled"
CANCEL_INPUT=$(printf '%s\n10.9.6.2\nOMV\nuser\nsecret\n\n%s\n1\ny\nn\n' "$CANCEL_TARGET" "$(id -un)")
mount_share <<< "$CANCEL_INPUT"
[[ ! -e $CANCEL_TARGET ]]
[[ $(find "$CREDENTIALS_DIR" -type f | wc -l) == 3 ]]
expect_failure mount_share <<< "$TEST_DIR/manual"
expect_failure mount_share <<< '/'
expect_failure toggle_autoconnect <<< "$TEST_DIR/unknown"
show_status > "$TEST_DIR/status.log"
! grep -Fq 'secret' "$TEST_DIR/status.log"
[[ -z $(find "$TEST_DIR" -name 'fstab.smb.??????' -print) ]]
printf '\nPASS: SMB credentials, fstab, reconnect, switches and failure handling\n'
