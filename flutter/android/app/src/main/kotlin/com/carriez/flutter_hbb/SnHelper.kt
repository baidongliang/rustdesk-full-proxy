package com.carriez.flutter_hbb

import android.content.Context
import android.util.Log

/**
 * 设备 SN 获取工具。
 *
 * SN 唯一权威来源是业务 app 经 ProvisionService 下发并持久化的缓存
 * [KEY_DEVICE_SN]（粘性身份，重启后仍有效）。不读取系统序列号：业务 app
 * 从未下发 SN 即视为无身份——被控端不启动核心、不注册，等待下发。
 */
object SnHelper {
    private const val TAG = "SnHelper"
    private const val UNKNOWN = "unknown"

    /**
     * 获取设备 SN（仅业务 app 经 ProvisionService 下发的持久化缓存）。
     * @return SN 字符串；从未下发或值无效时返回空串。
     */
    fun getCpuSerial(context: Context): String {
        val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, Context.MODE_PRIVATE)
        val sn = prefs.getString(KEY_DEVICE_SN, "").orEmpty().trim()
        if (sn.isEmpty() || UNKNOWN.equals(sn, ignoreCase = true)) {
            Log.w(TAG, "no provisioned sn (waiting for provision)")
            return ""
        }
        Log.i(TAG, "provisioned sn len=${sn.length}")
        return sn
    }

    /**
     * 保存业务 app 经 ProvisionService 下发的设备 SN（本缓存的唯一写入方），
     * 供后续启动直接使用（含被控端未启动时的冷启动路径）。
     */
    fun saveProvisionedSn(context: Context, sn: String) {
        val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_DEVICE_SN, sn).apply()
        Log.i(TAG, "saveProvisionedSn: $sn")
    }

    /** 本地是否已有业务 app 下发的 SN，决定启动时是否初始化核心。 */
    fun hasIdentity(context: Context): Boolean {
        return getCpuSerial(context).isNotEmpty()
    }
}
