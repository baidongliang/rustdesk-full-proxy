@echo off
setlocal

rem ============================================================
rem  RustDesk host (controlled-end) one-click deployer - Windows
rem  Usage: deploy_apk.bat [device_ip:port] [apk_path]
rem    - device default: 192.168.1.107:5555
rem    - apk default: newest rustdesk-host-*.apk next to this script
rem      (falls back to the repo root one level up)
rem  Requires adb.exe in PATH (Android platform-tools)
rem ============================================================

set DEV=%1
if "%DEV%"=="" set DEV=192.168.1.107:5555
set APK=%2
set PKG=cn.xinzx.rustdesk.android
if "%APK%"=="" for /f "delims=" %%f in ('dir /b /a-d /o-d "%~dp0rustdesk-host-*.apk" 2^>nul') do if not defined APK set "APK=%~dp0%%f"
if "%APK%"=="" for /f "delims=" %%f in ('dir /b /a-d /o-d "%~dp0..\rustdesk-host-*.apk" 2^>nul') do if not defined APK set "APK=%~dp0..\%%f"
if "%APK%"=="" set "APK=%~dp0build\app\outputs\flutter-apk\app-release.apk"
if "%APK%"=="" (
  echo [FAILED] No rustdesk-host-*.apk found next to this script.
  echo          Pass the apk path: deploy_apk.bat [device] path\to\apk
  pause
  exit /b 1
)

echo == Device: %DEV%
echo == APK:    %APK%
echo.

echo == adb connect
adb connect %DEV%

echo == [1/3] Install APK (-r keeps permission and data)
adb -s %DEV% install -r "%APK%" < nul
if errorlevel 1 goto INSTALL_FAIL

echo == [2/3] Grant WRITE_SECURE_SETTINGS (no root, once per install)
adb -s %DEV% shell pm grant %PKG% android.permission.WRITE_SECURE_SETTINGS < nul

echo == [3/3] Start host service (also auto-starts on device reboot)
adb -s %DEV% shell am broadcast -n %PKG%/com.carriez.flutter_hbb.BootReceiver -a com.carriez.flutter_hbb.DEBUG_BOOT_COMPLETED

echo == Wait 8s then verify...
timeout /t 8 /nobreak >nul

echo == Verify: process exists + "Bound services" contains RustDesk Input
adb -s %DEV% shell ps -A | findstr rustdesk
adb -s %DEV% shell dumpsys accessibility | findstr "Bound services"

echo.
echo == Done. Device registers online with SN as ID, digits-after-prefix as password.
echo    Note: re-run this script after full uninstall; install -r keeps the grant.
pause
exit /b 0

:INSTALL_FAIL
echo.
echo [FAILED] Install failed. Check adb output above.
echo         Common causes: wrong APK path / device not connected / signature conflict.
pause
exit /b 1
