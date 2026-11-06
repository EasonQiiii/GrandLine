#!/bin/bash
# 构建 GrandLine.app（无需 Xcode 工程，直接调用 swiftc）
set -euo pipefail
cd "$(dirname "$0")"

APP="GrandLine.app"
SDK="$(xcrun --show-sdk-path)"

echo "==> 清理旧产物"
rm -rf "$APP" build
mkdir -p build

echo "==> 编译 Swift 源码"
swiftc -O \
    -target arm64-apple-macosx14.0 \
    -sdk "$SDK" \
    Sources/GrandLine/*.swift \
    -o build/GrandLine

echo "==> 组装 App Bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/GrandLine "$APP/Contents/MacOS/GrandLine"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/GrandLine.icns ]; then
    cp Resources/GrandLine.icns "$APP/Contents/Resources/GrandLine.icns"
    echo "    图标：Resources/GrandLine.icns"
else
    echo "    未找到 Resources/GrandLine.icns（可选：./scripts.sh icon 重新生成）"
fi

echo "==> 代码签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || echo "   签名跳过（不影响本机运行）"

echo "==> 完成：$(pwd)/$APP"
echo "    运行：open $APP"
