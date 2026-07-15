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
     * @return SN 字符串；取不到（非定制系统环境）返回空串。
     */
    fun getCpuSerial(context: Context): String {
        return try {
            val sn = DwFirmwareInfo.getInstance(context).cpuSerial ?: ""
            if (sn.isEmpty()) {
                Log.w(TAG, "getCpuSerial returned empty")
            }
            sn
        } catch (e: Throwable) {
            Log.w(TAG, "getCpuSerial failed: ${e.message}")
            ""
        }
    }
}
