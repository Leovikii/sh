#!/usr/bin/env bash
# bash omv/tests/subtitle-sync-test.sh
set -eu
source "$(dirname -- "${BASH_SOURCE[0]}")/../subtitle-sync.sh"
TEST_DIR=$(mktemp -d)
trap 'cleanup; rm -rf -- "$TEST_DIR"' EXIT
VENV_DIR="$TEST_DIR/venv"
mkdir -p "$VENV_DIR/bin" "$TEST_DIR/media" "$TEST_DIR/empty"
cat > "$VENV_DIR/bin/ffs" <<'MOCK'
#!/bin/sh
case ${MOCK_MODE:-ok} in
    fail) exit 1 ;;
    empty) exit 0 ;;
    conflict) printf 'new arrival' > "$MOCK_CONFLICT" ;;
esac
cp -- "$3" "$5"
MOCK
chmod +x "$VENV_DIR/bin/ffs"
ready() { return 0; }
expect_failure() {
    if "$@"; then
        printf 'FAIL: expected command to fail: %s\n' "$*" >&2
        exit 1
    fi
}
printf 'video' > "$TEST_DIR/media/Episode 01.mkv"
printf 'source A' > "$TEST_DIR/media/a.SRT"
printf 'source B' > "$TEST_DIR/media/b.ass"
touch "$TEST_DIR/media/empty.srt"
mkdir "$TEST_DIR/media/directory.srt"
mkdir "$TEST_DIR/media/nested"
printf 'nested' > "$TEST_DIR/media/nested/hidden.srt"

# 候选过滤、多个候选必须选择、大小写扩展名。
select_subtitle "$TEST_DIR/media" > "$TEST_DIR/log" <<< '2'
[[ $REPLY == "$TEST_DIR/media/b.ass" ]]
expect_failure grep -qE 'empty.srt|directory.srt|hidden.srt' "$TEST_DIR/log"
select_subtitle "$TEST_DIR/media" > "$TEST_DIR/log" <<< "$(printf 'm\n%s\n' "$TEST_DIR/media/a.SRT")"
[[ $REPLY == "$TEST_DIR/media/a.SRT" ]]

# 无候选手动输入，支持成对引号和空格。
select_subtitle "$TEST_DIR/empty" > "$TEST_DIR/log" <<< "\"$TEST_DIR/media/a.SRT\""
[[ $REPLY == "$TEST_DIR/media/a.SRT" ]]
rm "$TEST_DIR/media/b.ass"
select_subtitle "$TEST_DIR/media" > "$TEST_DIR/log" <<< ''
[[ $REPLY == "$TEST_DIR/media/a.SRT" ]]
expect_failure read_path '路径：' > "$TEST_DIR/log" 2>&1 <<< "$TEST_DIR/media/empty.srt"

# 生成视频同名字幕并保留源文件。
INPUT=$(printf '%s\n\ny\n' "$TEST_DIR/media/Episode 01.mkv")
sync_subtitle > "$TEST_DIR/log" <<< "$INPUT"
OUTPUT="$TEST_DIR/media/Episode 01.SRT"
[[ $(cat "$OUTPUT") == 'source A' && $(cat "$TEST_DIR/media/a.SRT") == 'source A' ]]

# 已有目标默认取消。
printf 'existing' > "$OUTPUT"
INPUT=$(printf '%s\n1\ny\n\n' "$TEST_DIR/media/Episode 01.mkv")
sync_subtitle > "$TEST_DIR/log" <<< "$INPUT"
[[ $(cat "$OUTPUT") == existing ]]

# 明确备份后替换，源字幕也可以是目标自身。
INPUT=$(printf '%s\n1\ny\ny\n' "$TEST_DIR/media/Episode 01.mkv")
sync_subtitle > "$TEST_DIR/log" <<< "$INPUT"
[[ $(cat "$OUTPUT") == existing ]]
BACKUPS=("$OUTPUT".bak.*)
[[ -f ${BACKUPS[0]} && $(cat "${BACKUPS[0]}") == existing ]]

# 独立源字幕替换目标，并保留替换前内容。
INPUT=$(printf '%s\n2\ny\ny\n' "$TEST_DIR/media/Episode 01.mkv")
sync_subtitle > "$TEST_DIR/log" <<< "$INPUT"
[[ $(cat "$OUTPUT") == 'source A' && $(cat "$TEST_DIR/media/a.SRT") == 'source A' ]]

# 调轴失败、空输出均不覆盖目标。
export MOCK_MODE=fail
expect_failure sync_subtitle > "$TEST_DIR/log" 2>&1 <<< "$INPUT"
[[ $(cat "$OUTPUT") == 'source A' && ! $TEMP_SUB ]]
export MOCK_MODE=empty
expect_failure sync_subtitle > "$TEST_DIR/log" 2>&1 <<< "$INPUT"
[[ $(cat "$OUTPUT") == 'source A' && ! $TEMP_SUB ]]

# 任务开始后出现目标，不得在未授权时覆盖。
rm "$OUTPUT"
export MOCK_MODE=conflict MOCK_CONFLICT="$OUTPUT"
INPUT=$(printf '%s\n\ny\n' "$TEST_DIR/media/Episode 01.mkv")
expect_failure sync_subtitle > "$TEST_DIR/log" 2>&1 <<< "$INPUT"
[[ $(cat "$OUTPUT") == 'new arrival' && ! $TEMP_SUB ]]

# 更新失败完整恢复旧环境，不残留新依赖。
touch "$VENV_DIR/.subtitle-sync-owned" "$VENV_DIR/bin/python"
chmod +x "$VENV_DIR/bin/python"
install_python_packages() {
    printf broken > "$VENV_DIR/bin/ffs"
    touch "$VENV_DIR/new-dependency"
    return 1
}
expect_failure update_components > "$TEST_DIR/log" 2>&1
[[ ! $UPDATE_BACKUP && ! -e $VENV_DIR/new-dependency ]]
grep -q '^#!/bin/sh$' "$VENV_DIR/bin/ffs"
printf 'PASS: selection, paths, output, backup, failure, conflict, update rollback\n'
