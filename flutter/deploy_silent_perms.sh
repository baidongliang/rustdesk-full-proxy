#!/usr/bin/env bash
#
# 被控端静默授权部署脚本（定制 dewod 设备）。
#
# 模式 1（默认，无需 root）：授予 WRITE_SECURE_SETTINGS（development 权限，
#   普通 adb 即可 grant），之后由 app 内 SilentPermsHelper 在每次启动/开机时
#   自行读写 secure settings 完成无障碍自愈（含 crashed 退避清理）。
#   投屏免框主路径是 app 内 DwSecure.registerSafeProgram（定制 SystemUI 自动放行），
#   本脚本无需处理。
#
# 模式 2（--root，兜底）：adb root 后直接改 appops + settings，
#   适合排查问题或 app 自愈失效时手动兜底。
#
# 用法：
#   ./deploy_silent_perms.sh [设备IP:端口] [--root]   # 默认 192.168.1.107:5555
#
set -e

ADB=${ADB:-adb}
DEV=""
ROOT_MODE=0
for arg in "$@"; do
  case "$arg" in
    --root) ROOT_MODE=1 ;;
    *) DEV="$arg" ;;
  esac
done
DEV="${DEV:-192.168.1.107:5555}"
PKG="cn.xinzx.rustdesk.android"
SVC="$PKG/com.carriez.flutter_hbb.InputService"

echo "==> 目标设备: $DEV (root模式: $ROOT_MODE)"
echo "==> 包名: $PKG"

if [ "$ROOT_MODE" -eq 1 ]; then
  echo "==> [root 模式] 获取 root"
  "$ADB" -s "$DEV" root 2>/dev/null || true
  sleep 3
  "$ADB" connect "$DEV" 2>/dev/null || true
  sleep 2

  echo "==> 1. 投屏免框：appops PROJECT_MEDIA allow"
  "$ADB" -s "$DEV" shell appops set "$PKG" PROJECT_MEDIA allow

  echo "==> 2. 无障碍自愈：清除 Crashed 标记 + 重新绑定"
  echo "    2.1 先完全禁用无障碍（清 crashed 退避标记）"
  "$ADB" -s "$DEV" shell settings put secure accessibility_enabled 0
  "$ADB" -s "$DEV" shell settings delete secure enabled_accessibility_services
  sleep 3
  echo "    2.2 再启用（系统重新发起绑定）"
  "$ADB" -s "$DEV" shell settings put secure accessibility_enabled 1
  sleep 2
  "$ADB" -s "$DEV" shell settings put secure enabled_accessibility_services "$SVC"
  sleep 3
else
  echo "==> [免 root 模式] 授予 WRITE_SECURE_SETTINGS（development 权限）"
  "$ADB" -s "$DEV" shell pm grant "$PKG" android.permission.WRITE_SECURE_SETTINGS
  echo "    已授予。无障碍由 app 启动时自动自愈（SilentPermsHelper 直写 secure settings）。"
  echo "    若设备上 app 未运行，可触发一次启动："
  echo "      adb -s $DEV shell am broadcast -n $PKG/com.carriez.flutter_hbb.BootReceiver -a com.carriez.flutter_hbb.DEBUG_BOOT_COMPLETED"
fi

echo "==> 验证"
echo "    无障碍绑定状态:"
"$ADB" -s "$DEV" shell dumpsys accessibility 2>&1 | grep -E "Bound|Crashed" | head -3

echo ""
echo "==> 完成。若 Bound services 含 RustDesk Input 且 Crashed 为空，则成功。"
