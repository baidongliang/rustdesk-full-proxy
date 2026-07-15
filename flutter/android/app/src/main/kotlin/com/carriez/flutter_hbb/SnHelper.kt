package com.carriez.flutter_hbb

import android.content.Context
import android.util.Log
import com.dewod.sdk.DwFirmwareInfo

/**
 * 设备 SN 获取工具。
 *
 * 通过定制系统 SDK [DwFirmwareInfo.getCpuSerial] 读取 CPU 序列号作为设备 SN。
 *
 * 注意：
 * - 调用前需确保已完成 [MainApplication.initDewodSdk] 的安全程序注册，否则定制系统
 *   服务会拒绝。
 * - SDK 走定制系统隐藏服务，普通 Android 设备 / 模拟器上调不通会抛异常，这里统一
 *   try-catch 返回空串，避免上抛导致崩溃。
 */
object SnHelper {
    private const val TAG = "SnHelper"

    /**
     * 获取设备 SN（CPU 序列号）。
     *
     * 带 SharedPreferences 缓存：首次成功取到后持久化，后续直接读缓存，
     * 避免 SDK 单例状态导致二次调用失败（实测 dewod SDK 重启后 getCpuSerial 偶发返回空）。
     * @return SN 字符串；取不到（非定制系统环境）返回空串。
     */
    fun getCpuSerial(context: Context): String {
        // 1. 先读缓存
        val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, Context.MODE_PRIVATE)
        val cached = prefs.getString(KEY_DEVICE_SN, "")
        if (!cached.isNullOrEmpty()) {
            Log.d(TAG, "getCpuSerial from cache: $cached")
            return cached
        }
        // 2. 缓存空，调 SDK 取
        val sn = try {
            val v = DwFirmwareInfo.getInstance(context).cpuSerial ?: ""
            if (v.isEmpty()) {
                Log.w(TAG, "getCpuSerial returned empty")
            }
            v
        } catch (e: Throwable) {
            Log.w(TAG, "getCpuSerial failed: ${e.message}")
            ""
        }
        // 3. 取到则缓存
        if (sn.isNotEmpty()) {
            prefs.edit().putString(KEY_DEVICE_SN, sn).apply()
            Log.i(TAG, "getCpuSerial from SDK and cached: $sn")
        }
        return sn
    }
}
