#!/bin/bash
#
# build.sh - 拼接 src/*.sh + 注入 assets/Config.xml -> renewx.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${ROOT}/src"
ASSETS_DIR="${ROOT}/assets"
OUT_FILE="${ROOT}/renewx.sh"

XML_FILE="${ASSETS_DIR}/Config.xml"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "[ERROR] 源码目录缺失: $SRC_DIR" >&2
    exit 1
fi
if [[ ! -f "$XML_FILE" ]]; then
    echo "[ERROR] 资源文件缺失: $XML_FILE" >&2
    exit 1
fi

BUILD_TIME="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
BUILD_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'untracked')"

TMP="$(mktemp)"
trap 'rm -f "$TMP" "${TMP}.xml"' EXIT

# 1) 按文件名顺序拼接 src/*.sh
#    非首个模块去掉首行 shebang（如有），保持单一 shebang
echo "[*] 拼接 src/*.sh"
first=1
for f in "$SRC_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    if [[ $first -eq 1 ]]; then
        cat "$f" >> "$TMP"
        first=0
    else
        # 跳过模块顶部的 shebang 行（防御性，正常模块没有）
        awk 'NR==1 && /^#!/ {next} {print}' "$f" >> "$TMP"
    fi
    echo "" >> "$TMP"
done

# 2) 注入 Config.xml 到 __INLINE_CONFIG_XML__ 占位符
echo "[*] 注入 Config.xml"
if ! grep -q '__INLINE_CONFIG_XML__' "$TMP"; then
    echo "[ERROR] 未找到 __INLINE_CONFIG_XML__ 占位符" >&2
    exit 1
fi

# 把整个 XML 文件作为字面量替换占位符所在的整行
# 用 awk 读 XML 到字符串后逐行打印替代
awk -v xml_path="$XML_FILE" '
    BEGIN {
        xml = ""
        while ((getline line < xml_path) > 0) {
            xml = xml line "\n"
        }
        close(xml_path)
        # 去掉末尾多余换行（heredoc 自带分隔）
        sub(/\n$/, "", xml)
    }
    /^[[:space:]]*__INLINE_CONFIG_XML__[[:space:]]*$/ {
        print xml
        next
    }
    { print }
' "$TMP" > "${TMP}.xml"
mv "${TMP}.xml" "$TMP"

# 3) 替换构建元信息占位符
echo "[*] 注入构建元信息"
awk -v bt="$BUILD_TIME" -v bc="$BUILD_COMMIT" '
    { gsub(/__BUILD_TIME__/, bt); gsub(/__BUILD_COMMIT__/, bc); print }
' "$TMP" > "${TMP}.xml"
mv "${TMP}.xml" "$TMP"

# 4) bash -n 语法校验
echo "[*] 语法校验 (bash -n)"
if ! bash -n "$TMP"; then
    echo "[ERROR] 生成的脚本未通过语法检查" >&2
    cp "$TMP" "${OUT_FILE}.broken"
    echo "        已保留: ${OUT_FILE}.broken" >&2
    exit 1
fi

# 5) 输出
mv "$TMP" "$OUT_FILE"
chmod +x "$OUT_FILE"
trap - EXIT

size="$(wc -c < "$OUT_FILE" | tr -d ' ')"
lines="$(wc -l < "$OUT_FILE" | tr -d ' ')"
echo "[OK] 构建完成: $OUT_FILE"
echo "     大小: ${size} bytes / ${lines} 行"
echo "     时间: $BUILD_TIME"
echo "     提交: $BUILD_COMMIT"
