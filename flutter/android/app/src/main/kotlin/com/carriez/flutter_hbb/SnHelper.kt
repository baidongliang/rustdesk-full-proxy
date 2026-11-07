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
     * 读取顺序：系统真实 SN（Build.getSerial/SERIAL）→ getprop 系统属性 →
     * 本地缓存（含业务 app 经 ProvisionService 下发的 SN，任意厂家格式）。
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

        if (!cached.isNullOrEmpty()) {
            // 多厂家兼容：业务 app 经 ProvisionService 传入的 SN 也缓存于此，
            // 不限定 DWDEV 前缀（v2 身份方案以缓存/系统 SN 为派生源）。
            Log.i(TAG, "getDeviceSerialNumber from cache fallback: $cached")
            return cached
        }

        Log.w(TAG, "getDeviceSerialNumber returned empty")
        return ""
    }

    /**
     * 保存业务 app 经 ProvisionService 下发的设备 SN（身份权威来源），
     * 供后续启动直接使用（含被控端未启动时的冷启动路径）。
     */
    fun saveProvisionedSn(context: Context, sn: String) {
        val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_DEVICE_SN, sn).apply()
        Log.i(TAG, "saveProvisionedSn: $sn")
    }

    /** 本地是否已有可用 SN（缓存或系统可读），决定开机是否自启服务。 */
    fun hasIdentity(context: Context): Boolean {
        return getCpuSerial(context).isNotEmpty()
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
