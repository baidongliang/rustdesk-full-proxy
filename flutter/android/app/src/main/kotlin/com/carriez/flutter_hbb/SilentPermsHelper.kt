package com.carriez.flutter_hbb

import android.content.Context
import android.util.Log
import kotlin.concurrent.thread

/**
 * 定制设备静默授权工具（root 路径）。
 *
 * 封装投屏免框 appops + 无障碍自愈 toggle 逻辑，供 [MainApplication] 和
 * [BootReceiver] 共用。
 *
 * 无障碍自愈原理：Android 把被判定为"崩溃"的无障碍服务加入 Crashed services 列表，
 * 退避期内不再绑定。先完全禁用（清 crashed 标记）再重新启用，强制系统重新发起绑定。
 *
 * 注意：app 进程内 `Runtime.exec("su")` 在普通签名下无权限（su 只允许 shell/adb uid），
 * 此类仅在 app 获得系统签名（系统签名预装路径）时生效。当前实际生效靠
 * [deploy_silent_perms.sh] adb 脚本；此类作为系统签名预装路径的预留。
 */
object SilentPermsHelper {
    private const val TAG = "SilentPerms"
    private const val INPUT_SERVICE = "com.carriez.flutter_hbb.InputService"

    /**
     * 应用全部静默授权：投屏 appops + 无障碍自愈。
     * 异步执行（后台线程），不阻塞调用方。
     */
    fun applyAsync(context: Context) {
        thread {
            try {
                applySync(context)
            } catch (e: Throwable) {
                Log.w(TAG, "applyAsync err: ${e.message}")
            }
        }
    }

    /**
     * 同步应用全部静默授权（阻塞，应在后台线程调用）。
     * @return true 表示 root 可用且已执行。
     */
    fun applySync(context: Context): Boolean {
        if (!hasRoot()) {
            Log.i(TAG, "skipped: no root")
            return false
        }
        val pkg = context.packageName
        // 1. 投屏免框 appop
        execRoot("appops set $pkg PROJECT_MEDIA allow")
        Log.i(TAG, "PROJECT_MEDIA allow")
        // 2. 无障碍自愈：toggle 清 crashed 标记
        healAccessibility(pkg)
        return true
    }

    /**
     * 无障碍自愈：先禁用（清 crashed 标记），间隔后再启用。
     * 幂等，可重复调用。
     */
    fun healAccessibility(pkg: String) {
        val svc = "$pkg/$INPUT_SERVICE"
        execRoot("settings put secure accessibility_enabled 0")
        execRoot("settings delete secure enabled_accessibility_services")
        Thread.sleep(2000)
        execRoot("settings put secure accessibility_enabled 1")
        Thread.sleep(1000)
        execRoot("settings put secure enabled_accessibility_services '$svc'")
        Log.i(TAG, "accessibility healed ($svc)")
    }

    /** 检测 root：直接尝试 su 执行 id，成功即有 root。 */
    private fun hasRoot(): Boolean {
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("su", "-c", "id"))
            val ok = p.waitFor() == 0
            val out = p.inputStream.bufferedReader().readText()
            ok && out.contains("uid=0")
        } catch (e: Exception) {
            false
        }
    }

    /** 以 root 执行命令。 */
    private fun execRoot(cmd: String): String {
        val p = Runtime.getRuntime().exec(arrayOf("su", "-c", cmd))
        val out = p.inputStream.bufferedReader().readText()
        p.waitFor()
        return out
    }
}
