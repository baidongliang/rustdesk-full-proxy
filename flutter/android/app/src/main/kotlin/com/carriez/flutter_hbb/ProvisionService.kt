package com.carriez.flutter_hbb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import ffi.FFI

/**
 * 业务 app 拉起/配置入口（多厂家一体机兼容，v2 身份方案）。
 *
 * 业务 app 拿到设备序列号后拉起本服务：
 * ```kotlin
 * val intent = Intent(ProvisionService.ACTION_PROVISION).apply {
 *     setPackage("cn.xinzx.rustdesk.android")
 *     putExtra(ProvisionService.EXTRA_SN, serial)   // 设备序列号/资产编号
 * }
 * // 业务 app 在前台：startService(intent)
 * // 业务 app 在后台：startForegroundService(intent)（本服务会短暂前台化满足系统要求）
 * context.startForegroundService(intent)
 * ```
 *
 * 服务流程：调用方校验（uid → 包名 → 白名单）→ 保存 SN（SnHelper 缓存，粘性身份）
 * → 注入 Rust 核心（FFI.setAndroidSn）→ 启动 MainService（ID 派生/注册/密码 v2 派生
 * /采集与投屏全链路既有逻辑）→ 无障碍自愈 → 退出。
 *
 * 校验规则：调用方 uid 解析包名，需命中白名单（默认含本包 / cn.xinzx.library.app /
 * com.android.shell 供 adb 部署调试；可经 prefs KEY_PROVISION_CALLERS 调整，
 * 逗号分隔 contains 匹配）。未命中一律拒绝并记日志，不保存不启动。
 *
 * 已安装场景重复拉起：按业务 app 下发的 SN 更新本地缓存（SN 变更 = 设备身份变更，
 * ID/派生密码自动跟随，服务器上旧记录由运维按死锁清理流程处理）。
 */
class ProvisionService : Service() {

    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 可能被 startForegroundService 从后台拉起：按系统要求短暂前台化
        goForeground()

        val sn = intent?.getStringExtra(EXTRA_SN)?.trim().orEmpty()
        val caller = callerPackage()
        val allowed = isAllowedCaller(caller)
        InputTraceLog.i(
            this,
            "provision caller=$caller allowed=$allowed snLen=${sn.length} snNorm=${snPasswordNormalize(sn)}"
        )

        if (!allowed) {
            InputTraceLog.w(this, "provision rejected: caller not in whitelist")
        } else if (sn.isEmpty() || sn.equals(UNKNOWN, ignoreCase = true)) {
            InputTraceLog.w(this, "provision rejected: empty/unknown sn")
        } else {
            SnHelper.saveProvisionedSn(this, sn)
            try {
                FFI.setAndroidSn(sn)
                InputTraceLog.i(this, "setAndroidSn done (provisioned)")
            } catch (e: Throwable) {
                InputTraceLog.w(this, "setAndroidSn failed (core may start later): ${e.message}")
            }
            startMainService()
            SilentPermsHelper.applyAsync(this, "provisioned")
            InputTraceLog.i(this, "provision done sn=$sn")
        }

        stopForegroundRendering()
        stopSelf()
        return START_NOT_STICKY
    }

    private fun callerPackage(): String {
        val uid = Binder.getCallingUid()
        return packageManager.getNameForUid(uid)?.trim().orEmpty()
    }

    private fun isAllowedCaller(pkg: String): Boolean {
        if (pkg == packageName) return true
        val prefs = getSharedPreferences(KEY_SHARED_PREFERENCES, Context.MODE_PRIVATE)
        val list = prefs.getString(KEY_PROVISION_CALLERS, DEFAULT_PROVISION_CALLERS)
            ?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        return list.any { pkg == it || pkg.endsWith(":$it") || pkg.contains(it) }
    }

    private fun goForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "RustDesk 配置", NotificationManager.IMPORTANCE_MIN)
            )
        }
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("RustDesk")
            .setContentText("正在接收设备配置…")
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notif)
        foreground = true
    }

    private fun stopForegroundRendering() {
        if (foreground) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            foreground = false
        }
    }

    private fun startMainService() {
        val it = Intent(this, MainService::class.java).apply {
            action = ACT_INIT_MEDIA_PROJECTION_AND_SERVICE
            putExtra(EXT_INIT_FROM_BOOT, true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(it)
        } else {
            startService(it)
        }
    }

    companion object {
        const val ACTION_PROVISION = "cn.xinzx.rustdesk.android.PROVISION"
        const val EXTRA_SN = "sn"
        private const val CHANNEL_ID = "provision"
        private const val NOTIF_ID = 1001
        private const val UNKNOWN = "unknown"

        /** 默认允许的调用方（逗号分隔 contains 匹配） */
        const val DEFAULT_PROVISION_CALLERS =
            "cn.xinzx.library.app,com.android.shell,cn.xinzx.rustdesk.android"
        const val KEY_PROVISION_CALLERS = "KEY_PROVISION_CALLERS"

        /** 与 Rust normalize_sn 一致：大写、仅字母数字、去 @server 后缀 */
        fun snPasswordNormalize(raw: String): String {
            val s = raw.split('@').first().trim().toUpperCase()
            val sb = StringBuilder()
            for (c in s) {
                if (c.isLetterOrDigit() && c.code <= 0x7f) sb.append(c)
            }
            return sb.toString()
        }
    }
}
