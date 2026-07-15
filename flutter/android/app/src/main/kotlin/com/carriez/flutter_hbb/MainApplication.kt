package com.carriez.flutter_hbb

import android.app.Application
import android.util.Log
import com.dewod.sdk.DwFirmwareInfo
import com.dewod.sdk.DwSecure
import ffi.FFI
import kotlin.concurrent.thread

class MainApplication : Application() {
    companion object {
        private const val TAG = "MainApplication"
        // 定制系统安全程序注册口令（由需求方提供，所有被控端实例统一）
        private const val SAFE_PROGRAM_KEY = "Dewod1234"
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "App start")
        initDewodSdk()
        // 1. 先取 SN 注入 Rust 核心（供 gen_id 派生稳定 ID，避免重装即变）。
        val sn = SnHelper.getCpuSerial(applicationContext)
        if (sn.isNotEmpty()) {
            FFI.setAndroidSn(sn)
        }
        // 2. 标 incoming-only（必须在 UI 渲染前）。
        FFI.setHostOnly()
        FFI.onAppStart(applicationContext)
        // 3. 定制设备静默授权（root）：投屏免框 + 无障碍自愈。
        // 异步执行，不阻塞 app 启动；非 root 设备安静失败。
        SilentPermsHelper.applyAsync(this)
    }

    /**
     * 初始化定制系统 SDK。
     *
     * 两件事：
     * 1. 注册为定制系统"安全程序"——必须在调用任何其他 SDK 能力（如取 SN）之前完成，
     *    否则定制系统服务会因调用方未认证而拒绝。
     * 2. （SN 取数由 [SnHelper] 在需要时调用，不在此预热）
     *
     * SDK 走定制系统的隐藏服务（Context.getSystemService），普通 Android 设备 / 模拟器
     * 上调不通会抛异常，因此全部 try-catch 兜底，绝不影响 app 启动。
     */
    private fun initDewodSdk() {
        try {
            val ok = DwSecure.getInstance(this).registerSafeProgram(SAFE_PROGRAM_KEY)
            Log.i(TAG, "registerSafeProgram($SAFE_PROGRAM_KEY) -> $ok")
        } catch (e: Throwable) {
            // 非定制系统环境（开发机/模拟器）会走到这里，属预期情况
            Log.w(TAG, "registerSafeProgram failed: ${e.message}")
        }
    }
}

