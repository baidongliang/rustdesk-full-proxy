#!/usr/bin/env bash
#
# 被控端静默授权部署脚本（定制设备，需 adb root）。
#
# 作用：一次性设置投屏免框 + 无障碍自愈，解决 InputService 进 crashed 退避的问题。
# 建议在装机/每次设备重启后执行一次。
#
# 用法：
#   ./deploy_silent_perms.sh [设备IP:端口]   # 默认 192.168.1.107:5555
#
set -e

ADB=${ADB:-adb}
DEV="${1:-192.168.1.107:5555}"
PKG="cn.xinzx.rustdesk.android"
SVC="$PKG/com.carriez.flutter_hbb.InputService"

echo "==> 目标设备: $DEV"
echo "==> 包名: $PKG"

echo "==> 1. 获取 root（userdebug build 才支持）"
"$ADB" -s "$DEV" root 2>/dev/null || true
sleep 3
"$ADB" connect "$DEV" 2>/dev/null || true
sleep 2

echo "==> 2. 投屏免框：appops PROJECT_MEDIA allow"
"$ADB" -s "$DEV" shell appops set "$PKG" PROJECT_MEDIA allow

echo "==> 3. 无障碍自愈：清除 Crashed 标记 + 重新绑定"
echo "    3.1 先完全禁用无障碍（清 crashed 退避标记）"
"$ADB" -s "$DEV" shell settings put secure accessibility_enabled 0
"$ADB" -s "$DEV" shell settings delete secure enabled_accessibility_services
sleep 3
echo "    3.2 再启用（系统重新发起绑定）"
"$ADB" -s "$DEV" shell settings put secure accessibility_enabled 1
sleep 2
"$ADB" -s "$DEV" shell settings put secure enabled_accessibility_services "$SVC"
sleep 3

echo "==> 4. 验证"
echo "    投屏 appop:"
"$ADB" -s "$DEV" shell appops get "$PKG" PROJECT_MEDIA
echo "    无障碍绑定状态:"
"$ADB" -s "$DEV" shell dumpsys accessibility 2>&1 | grep -E "Bound|Enabled|Binding|Crashed" | head -4

echo ""
echo "==> 完成。若 Bound services 含 RustDesk Input 且 Crashed 为空，则成功。"
