package com.carriez.flutter_hbb

import android.content.Context
import android.os.Build
import android.util.Log

/**
 * 设备 SN 获取工具。
 *
 * 与业务 app 的 DeviceSerialUtil 保持一致：优先读取 Android 设备序列号
 * [Build.getSerial] / [Build.SERIAL]，定制设备上应为 DWDEV...。
 */
object SnHelper {
    private const val TAG = "SnHelper"
    private const val UNKNOWN = "unknown"

    /**
     * 获取设备 SN。
     *
     * 带 SharedPreferences 缓存：优先读系统真实 SN，系统读取失败时才回退缓存过的
     * DWDEV 设备 SN，避免 CPU 序列号污染 RustDesk ID。
     * @return SN 字符串；取不到（非定制系统环境）返回空串。
     */
    fun getCpuSerial(context: Context): String {
        val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, Context.MODE_PRIVATE)
        val cached = prefs.getString(KEY_DEVICE_SN, "")
        if (!cached.isNullOrEmpty()) {
            Log.d(TAG, "getCpuSerial cached candidate: $cached")
        }

        val sn = readDeviceSerial()
        if (sn.isNotEmpty()) {
            Log.i(TAG, "getDeviceSerialNumber: $sn")
            cacheIfChanged(prefs, cached, sn, "system_serial")
            return sn
        }

        if (!cached.isNullOrEmpty() && cached.startsWith("DWDEV")) {
            Log.d(TAG, "getDeviceSerialNumber from cache fallback: $cached")
            return cached
        }

        if (!cached.isNullOrEmpty()) {
            Log.w(TAG, "ignore non-DWDEV cached sn: $cached")
        }
        return ""
    }

    private fun readDeviceSerial(): String {
        val buildSerial = try {
            Build.getSerial()
        } catch (e: SecurityException) {
            Log.w(TAG, "Build.getSerial permission denied: ${e.message}")
            ""
        } catch (e: Throwable) {
            Log.w(TAG, "Build.getSerial failed: ${e.message}")
            ""
        }
        normalize(buildSerial)?.let { return it }
        normalize(Build.SERIAL)?.let { return it }
        normalize(readProp("ro.boot.serialno"))?.let { return it }
        normalize(readProp("ro.serialno"))?.let { return it }
        Log.w(TAG, "getDeviceSerialNumber returned empty")
        return ""
    }

    private fun readProp(name: String): String {
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("/system/bin/getprop", name))
            val out = p.inputStream.bufferedReader().readText().trim()
            p.waitFor()
            out
        } catch (e: Throwable) {
            Log.w(TAG, "readProp $name failed: ${e.message}")
            ""
        }
    }

    private fun normalize(value: String?): String? {
        val v = value?.trim().orEmpty()
        if (v.isEmpty() || UNKNOWN.equals(v, ignoreCase = true)) {
            return null
        }
        return v
    }

    private fun cacheIfChanged(
        prefs: android.content.SharedPreferences,
        cached: String?,
        sn: String,
        source: String,
    ) {
        if (cached != sn) {
            prefs.edit().putString(KEY_DEVICE_SN, sn).apply()
            Log.i(TAG, "getCpuSerial cached from $source: $sn")
        }
    }
}
