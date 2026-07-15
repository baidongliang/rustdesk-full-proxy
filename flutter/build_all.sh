#!/usr/bin/env bash
#
# 三端构建脚本（本轮：验证可行性）。
#
# 覆盖：Android 被控端 APK + macOS 控制端 + Windows 控制端。
# 前提：NDK、vcpkg 依赖、Flutter、Rust 工具链已就绪（参见根目录 README / build.py）。
#
# 用法：
#   ./build_all.sh android     # 只编 Android 被控端 APK
#   ./build_all.sh macos       # 只编 macOS 控制端
#   ./build_all.sh windows     # 只编 Windows 控制端（需在 Windows 上执行）
#   ./build_all.sh all         # 全部（Windows 部分仅在 Windows 上能跑）
#
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_DIR="$ROOT_DIR/flutter"
cd "$FLUTTER_DIR"

build_android_rust() {
    echo "==> [1/2] 构建 Android arm64 Rust .so"
    # 依赖：NDK r25c+、vcpkg（ffmpeg 等）。首次需先跑 ./build_android_deps.sh
    # 编出的 .so 落在 android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
    ./ndk_arm64.sh
}

build_android_apk() {
    echo "==> [2/2] 构建 Android 被控端 APK"
    # applicationId: cn.xinzx.rustdesk.android
    # 被控端无 UI，开机自启，预设固定密码 xinzx2026
    flutter build apk --target-platform android-arm64 --release \
        --obfuscate --split-debug-info ./split-debug-info
    echo "==> APK 输出：build/app/outputs/flutter-apk/app-release.apk"
}

build_macos() {
    echo "==> 构建 macOS 控制端"
    # Bundle ID: cn.xinzx.rustdesk.desktop
    # 需先构建 Rust 静态库（build.py --flutter --macos）
    flutter build macos --release
    echo "==> 输出：build/macos/Build/Products/Release/cn.xinzx.rustdesk.desktop.app（或 rustdesk.app）"
}

build_windows() {
    echo "==> 构建 Windows 控制端（需在 Windows 上执行）"
    # 本轮 Runner.rc 未改，exe 名仍为 rustdesk.exe
    # 需先构建 Rust 静态库（build.py --flutter --windows）
    flutter build windows --release
    echo "==> 输出：build/windows/runner/Release"
}

case "${1:-all}" in
    android)
        build_android_rust
        build_android_apk
        ;;
    macos)
        build_macos
        ;;
    windows)
        build_windows
        ;;
    all)
        build_android_rust
        build_android_apk
        build_macos
        echo "==> Windows 端请在 Windows 机器上执行：./build_all.sh windows"
        ;;
    *)
        echo "用法: $0 {android|macos|windows|all}"
        exit 1
        ;;
esac

echo "==> 构建完成"
