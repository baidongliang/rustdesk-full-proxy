package com.carriez.flutter_hbb

import android.app.Application
import android.util.Log
import ffi.FFI

class MainApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        InputTraceLog.d(this, "App start")
        try {
            // 1. 先取 SN 注入 Rust 核心（供 gen_id 派生稳定 ID，避免重装即变）。
            //    来源：业务 app 经 ProvisionService 下发并持久化的缓存（唯一来源）。
            val sn = SnHelper.getCpuSerial(applicationContext)
            InputTraceLog.i(this, "getCpuSerial sn=$sn")
            InputTraceLog.i(this, "host sn candidate sn=$sn len=${sn.length} provisioned=true")
            if (sn.isNotEmpty()) {
                FFI.setAndroidSn(sn)
                InputTraceLog.i(this, "setAndroidSn done")
            }
            // 2. 标 incoming-only（必须在 UI 渲染前）。
            FFI.setHostOnly()
            InputTraceLog.i(this, "setHostOnly done")
            // 3. v2 身份方案：有身份（业务 app 下发的缓存 SN）才启动核心并注册；
            //    无身份（新装未拉起）跳过——不再有随机 ID 兜底，等 ProvisionService 拉起。
            if (sn.isNotEmpty()) {
                FFI.onAppStart(applicationContext)
                prefsMarkCoreStarted()
            } else {
                InputTraceLog.w(this, "no device identity yet, skip core start (waiting for provision)")
            }
            // 4. 定制设备静默授权（root）：无障碍自愈。
            // 异步执行，不阻塞 app 启动；非 root 设备安静失败。
            SilentPermsHelper.applyAsync(this, "app_onCreate")
        } catch (e: Throwable) {
            InputTraceLog.e(this, "onCreate init failed: ${e.message}", e)
        }
    }

    /** 标记核心已成功启动过（BootReceiver 据此恢复存量设备的开机自启）。 */
    private fun prefsMarkCoreStarted() {
        getSharedPreferences(KEY_SHARED_PREFERENCES, MODE_PRIVATE)
            .edit().putBoolean(KEY_CORE_STARTED, true).apply()
    }

}
