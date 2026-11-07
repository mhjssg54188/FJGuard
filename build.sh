#!/usr/bin/env bash
# 构建可刷入的 FJGuard 模块包
# 依赖：bash、zip、unzip、zipinfo（Linux/macOS/CI 通用；设备端请勿用此脚本）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(sed -n 's/^version=//p' "$HERE/module.prop")"
OUT_DIR="${OUT_DIR:-$HERE/dist}"
OUT="$OUT_DIR/FJGuard-${VERSION}.zip"

[ -n "$VERSION" ] || { echo "❌ module.prop 缺少 version 字段"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 只打包模块运行时需要的文件；module.prop 必须在 zip 根目录
for item in module.prop customize.sh post-fs-data.sh service.sh uninstall.sh \
            README.md LICENSE bin config hook META-INF docs; do
    [ -e "$HERE/$item" ] && cp -a "$HERE/$item" "$STAGE"/
done

# 统一权限：默认 644，脚本/二进制入口 755
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$STAGE"/*.sh "$STAGE"/bin/*.sh "$STAGE"/hook/*.sh \
          "$STAGE"/META-INF/com/google/android/update-binary

mkdir -p "$OUT_DIR"
rm -f "$OUT"
( cd "$STAGE" && zip -r -9 -q "$OUT" . -x '.*' -x '*/.*' )

# 校验
unzip -t "$OUT" >/dev/null || { echo "❌ zip 完整性校验失败"; exit 1; }
if ! zipinfo -1 "$OUT" | grep -qx 'module.prop'; then
    echo "❌ module.prop 不在 zip 根目录（Magisk/KernelSU 会拒绝安装）"
    exit 1
fi
if [ ! -f "$STAGE"/META-INF/com/google/android/update-binary ]; then
    echo "⚠️  缺少 META-INF/update-binary（Magisk 管理器刷入需要）"
fi

echo "✅ 构建完成：$OUT"
echo "   版本：$VERSION  大小：$(wc -c < "$OUT") 字节  文件数：$(zipinfo -1 "$OUT" | wc -l)"
