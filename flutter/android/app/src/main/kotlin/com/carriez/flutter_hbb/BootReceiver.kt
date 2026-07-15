package com.carriez.flutter_hbb

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

const val DEBUG_BOOT_COMPLETED = "com.carriez.flutter_hbb.DEBUG_BOOT_COMPLETED"

class BootReceiver : BroadcastReceiver() {
    private val logTag = "tagBootReceiver"

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(logTag, "onReceive ${intent.action}")

        if (Intent.ACTION_BOOT_COMPLETED == intent.action || DEBUG_BOOT_COMPLETED == intent.action) {
            // 被控端定制设备：默认开机即启被控服务。
            // 不再检查 KEY_START_ON_BOOT_OPT（被控端常驻）与运行时权限（定制设备由系统预置授予）。
            // 仍保留对 SharedPreferences 的读取：若用户/运维显式置为 false 则尊重（便于排障时临时关闭）。
            val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, FlutterActivity.MODE_PRIVATE)
            if (prefs.getBoolean(KEY_START_ON_BOOT_OPT_DISABLE, false)) {
                Log.d(logTag, "explicitly disabled via KEY_START_ON_BOOT_OPT_DISABLE")
                return
            }

            val it = Intent(context, MainService::class.java).apply {
                action = ACT_INIT_MEDIA_PROJECTION_AND_SERVICE
                putExtra(EXT_INIT_FROM_BOOT, true)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(it)
            } else {
                context.startService(it)
            }
        }
    }
}
