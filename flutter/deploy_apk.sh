#!/usr/bin/env bash
#
# 被控端一键部署：安装 APK + 授予 WRITE_SECURE_SETTINGS（免 root）+ 拉起服务。
#
# 用法：
#   ./deploy_apk.sh [设备IP:端口] [APK路径]
#   # 设备默认 192.168.1.107:5555；APK 默认取 build/app/outputs/flutter-apk/app-release.apk
#
set -e

ADB=${ADB:-adb}
DEV="${1:-192.168.1.107:5555}"
PKG="cn.xinzx.rustdesk.android"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK="${2:-$SCRIPT_DIR/build/app/outputs/flutter-apk/app-release.apk}"

echo "==> 设备: $DEV"
echo "==> APK:  $APK"

"$ADB" connect "$DEV" 2>/dev/null || true

echo "==> 1/3 安装 APK"
"$ADB" -s "$DEV" install -r "$APK"

echo "==> 2/3 授予 WRITE_SECURE_SETTINGS（免 root，无障碍由 app 自动自愈）"
"$ADB" -s "$DEV" shell pm grant "$PKG" android.permission.WRITE_SECURE_SETTINGS

echo "==> 3/3 拉起被控服务（无 UI）"
"$ADB" -s "$DEV" shell am broadcast \
  -n "$PKG/com.carriez.flutter_hbb.BootReceiver" \
  -a com.carriez.flutter_hbb.DEBUG_BOOT_COMPLETED

sleep 8
echo "==> 验证"
"$ADB" -s "$DEV" shell dumpsys accessibility 2>&1 | grep -E "Bound|Crashed" | head -3
echo "==> 完成。Bound services 含 RustDesk Input 且 Crashed 为空即部署成功。"
echo "    （注意：卸载重装后需重跑本脚本；install -r 覆盖安装则 grant 保留）"
