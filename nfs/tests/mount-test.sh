#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../mount.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
FSTAB="$TEST_DIR/fstab"
printf '/dev/root / ext4 defaults 0 1\n' > "$FSTAB"
chmod 640 "$FSTAB"
cp -p "$FSTAB" "$TEST_DIR/original"

expect_failure() {
    if "$@"; then
        printf 'FAIL: expected failure: %s\n' "$*" >&2
        exit 1
    fi
}

valid_ip 192.168.1.10
valid_ip 0.0.0.0
valid_ip 255.255.255.255
for ip in 256.1.1.1 192.168.1 01.2.3.4 '1.2.3.4;id' ''; do
    expect_failure valid_ip "$ip"
done
valid_path '/mnt/共享 disk'
expect_failure valid_path relative
expect_failure valid_path $'/mnt/test\nother'

command() {
    if [[ $* == '-v mount.nfs' ]]; then return 0; fi
    builtin command "$@"
}
mountpoint() { [[ ${IS_MOUNTED:-0} == 1 ]]; }
mount() { printf '%s\n' "$@" > "$TEST_DIR/mount.args"; return "${MOUNT_RESULT:-0}"; }
findmnt() {
    if [[ $* == *'-o SOURCE'* ]]; then
        printf '%s\n' "${MOCK_SOURCE:-192.168.1.10:/export/共享\x20disk}"
    else
        printf '%s\n' "${FSTYPE:-nfs4}"
    fi
    return "${FINDMNT_RESULT:-0}"
}
umount() { printf '%s\n' "$@" > "$TEST_DIR/umount.args"; return "${UMOUNT_RESULT:-0}"; }
systemd_ready() { return "${SYSTEMD_RESULT:-0}"; }
systemctl() { printf '%s\n' "$*" >> "$TEST_DIR/systemctl.log"; return "${SYSTEMCTL_RESULT:-0}"; }

TARGET="$TEST_DIR/共享 disk"
BASE_INPUT=$(printf '192.168.1.10\n/export/共享 disk\n%s' "$TARGET")
INPUT=$BASE_INPUT$'\ny\nn'
mount_share <<< "$INPUT"
printf '%s\n' -t nfs -o rw,hard,nosuid,nodev -- '192.168.1.10:/export/共享 disk' "$TARGET" > "$TEST_DIR/expected"
cmp "$TEST_DIR/expected" "$TEST_DIR/mount.args"
rm "$TEST_DIR/mount.args"

mount_share <<< "$BASE_INPUT"$'\nn'
[[ ! -e $TEST_DIR/mount.args ]]
IS_MOUNTED=1 expect_failure mount_share <<< "$INPUT"
touch "$TARGET/.hidden"
expect_failure mount_share <<< "$INPUT"
[[ ! -e $TEST_DIR/mount.args && -f $TARGET/.hidden ]]
rm "$TARGET/.hidden"
MOUNT_RESULT=1 expect_failure mount_share <<< "$INPUT"

unmount_share <<< "$TARGET"
printf '%s\n' -- "$TARGET" > "$TEST_DIR/expected"
cmp "$TEST_DIR/expected" "$TEST_DIR/umount.args"
rm "$TEST_DIR/umount.args"
FSTYPE=ext4 expect_failure unmount_share <<< "$TARGET"
FINDMNT_RESULT=1 expect_failure unmount_share <<< "$TARGET"
[[ ! -e $TEST_DIR/umount.args ]]
UMOUNT_RESULT=1 expect_failure unmount_share <<< "$TARGET"

# 默认开启、重复保存、空格/反斜杠转义及真实 fstab 解析。
MOUNT_RESULT=1 expect_failure mount_share <<< "$BASE_INPUT"$'\ny\ny'
cmp "$TEST_DIR/original" "$FSTAB"
mount_share <<< "$BASE_INPUT"$'\ny\n'
autoconnect_enabled "$TARGET"
[[ $(stat -c %a "$FSTAB") == 640 ]]
cmp "$TEST_DIR/original" "$FSTAB.nfs.bak"
cp "$FSTAB" "$TEST_DIR/enabled"
save_autoconnect "$TARGET" '192.168.1.10:/export/共享 disk'
cmp "$TEST_DIR/enabled" "$FSTAB"
[[ $(grep -c '^daemon-reload$' "$TEST_DIR/systemctl.log") == 1 ]]
PARSED=$(builtin command findmnt --fstab --tab-file "$FSTAB" -rn -t nfs -o SOURCE)
printf -v PARSED '%b' "$PARSED"
[[ $PARSED == '192.168.1.10:/export/共享 disk' ]]
PARSED=$(builtin command findmnt --fstab --tab-file "$FSTAB" -rn -t nfs -o TARGET)
printf -v PARSED '%b' "$PARSED"
[[ $PARSED == "$TARGET" ]]
[[ $(fstab_escape '/mnt/a\b c') == '/mnt/a\134b\040c' ]]

# 开关只修改目标条目，关闭无需服务器在线。
save_autoconnect '/mnt/other share' '192.168.1.11:/backup'
toggle_autoconnect <<< "$TARGET"$'\ny'
expect_failure autoconnect_enabled "$TARGET"
autoconnect_enabled '/mnt/other share'
save_autoconnect '/mnt/other share'
cmp "$TEST_DIR/original" "$FSTAB"
toggle_autoconnect <<< "$TARGET"$'\ny'
autoconnect_enabled "$TARGET"
mount_share <<< "$INPUT"
expect_failure autoconnect_enabled "$TARGET"
cmp "$TEST_DIR/original" "$FSTAB"

# 拒绝接管手动配置；刷新失败时还原；无 systemd 时不写配置。
printf '192.168.1.20:/manual %s nfs defaults 0 0\n' "$(fstab_escape "$TARGET")" >> "$FSTAB"
cp "$FSTAB" "$TEST_DIR/manual"
expect_failure save_autoconnect "$TARGET" '192.168.1.10:/export/share'
cmp "$TEST_DIR/manual" "$FSTAB"
expect_failure save_autoconnect "$TARGET"
cmp "$TEST_DIR/manual" "$FSTAB"
cp "$TEST_DIR/original" "$FSTAB"
SYSTEMCTL_RESULT=1 expect_failure save_autoconnect "$TARGET" '192.168.1.10:/export/share'
cmp "$TEST_DIR/original" "$FSTAB"
SYSTEMD_RESULT=1 expect_failure save_autoconnect "$TARGET" '192.168.1.10:/export/share'
cmp "$TEST_DIR/original" "$FSTAB"
[[ -z $(find "$TEST_DIR" -name 'fstab.nfs.??????' -print) ]]
printf '\nPASS\n'
