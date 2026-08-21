package com.carriez.flutter_hbb

import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * 定制设备静默授权工具。
 *
 * 封装无障碍自愈 toggle 逻辑，供 [MainApplication] 和 [BootReceiver] 共用。
 *
 * 无障碍自愈原理：Android 把被判定为"崩溃"的无障碍服务加入 Crashed services 列表，
 * 退避期内不再绑定。先完全禁用（清 crashed 标记）再重新启用，强制系统重新发起绑定。
 *
 * 生效路径（优先级从高到低）：
 * 1. WRITE_SECURE_SETTINGS 已授予（普通 adb 执行一次
 *    `pm grant cn.xinzx.rustdesk.android android.permission.WRITE_SECURE_SETTINGS`，
 *    无需 root；系统签名预装则天然持有）：直接 Settings.Secure 读写
 *    enabled_accessibility_services，全程 app 内自愈。
 * 2. 设备 root（su 可用）：execRoot 执行 settings 命令。
 * 3. 都不可用：仅上报 startup_health，等 [deploy_silent_perms.sh] 兜底。
 *
 * 投屏免框不走本类：主路径是 MainApplication 的
 * DwSecure.registerSafeProgram（定制 SystemUI 自动放行授权框）。
 */
object SilentPermsHelper {
    private const val TAG = "SilentPerms"
    private const val INPUT_SERVICE = "com.carriez.flutter_hbb.InputService"
    private const val APPLY_THROTTLE_MS = 5_000L
    @Volatile
    private var lastApplyAt = 0L

    /**
     * 应用静默授权（无障碍自愈）。异步执行（后台线程），不阻塞调用方。
     */
    fun applyAsync(context: Context, reason: String = "startup") {
        val now = SystemClock.elapsedRealtime()
        if (now - lastApplyAt < APPLY_THROTTLE_MS) {
            Log.d(TAG, "applyAsync throttled reason=$reason")
            return
        }
        lastApplyAt = now
        thread {
            try {
                applySync(context, reason)
            } catch (e: Throwable) {
                Log.w(TAG, "applyAsync err reason=$reason: ${e.message}")
            }
        }
    }

    /**
     * 同步应用静默授权（阻塞，应在后台线程调用）。
     * @return true 表示无障碍已恢复到位。
     */
    fun applySync(context: Context, reason: String = "startup"): Boolean {
        val sn = SnHelper.getCpuSerial(context)
        val pkg = context.packageName
        val root = hasRoot()
        val secureWritable = canWriteSecureSettings(context)
        val attempts = if (root || secureWritable) 3 else 1
        var inputOpen = InputService.isOpen

        for (attempt in 1..attempts) {
            inputOpen = InputService.isOpen
            if (inputOpen) {
                break
            }
            healAccessibility(context, pkg, preferDirectWrite = secureWritable)
            Thread.sleep(600)
            inputOpen = InputService.isOpen
            if (inputOpen) {
                break
            }
            if (attempt < attempts) {
                Thread.sleep(1_200)
            }
        }

        reportStartupHealth(reason, sn, root, secureWritable, inputOpen)
        if (!root && !secureWritable) {
            Log.i(TAG, "skipped: no root / no WRITE_SECURE_SETTINGS reason=$reason")
            return false
        }
        return inputOpen
    }

    /**
     * 无障碍自愈：先禁用（清 crashed 标记），间隔后再启用。
     * 幂等，可重复调用。优先直写 secure settings（授权通道），root 命令兜底。
     */
    fun healAccessibility(context: Context, pkg: String, preferDirectWrite: Boolean) {
        val svc = "$pkg/$INPUT_SERVICE"
        val current = readEnabledAccessibilityServices(context, preferDirectWrite)
        val filtered = current.filter { it != svc }
        val joined = (filtered + svc).distinct().joinToString(":")
        putSecure(context, "accessibility_enabled", "0", preferDirectWrite)
        Thread.sleep(2000)
        putSecure(context, "accessibility_enabled", "1", preferDirectWrite)
        Thread.sleep(1000)
        putSecure(context, "enabled_accessibility_services", joined, preferDirectWrite)
        Log.i(TAG, "accessibility healed ($svc) directWrite=$preferDirectWrite")
    }

    /** 读取当前已启用的无障碍服务列表。 */
    private fun readEnabledAccessibilityServices(
        context: Context,
        preferDirectWrite: Boolean
    ): List<String> {
        val raw = if (preferDirectWrite) {
            Settings.Secure.getString(context.contentResolver, "enabled_accessibility_services")
        } else {
            execRoot("settings get secure enabled_accessibility_services")
        }?.trim().orEmpty()
        if (raw.isEmpty() || raw == "null") {
            return emptyList()
        }
        return raw.split(':').map { it.trim() }.filter { it.isNotEmpty() }
    }

    /** 写 secure setting：直写（WRITE_SECURE_SETTINGS 已授予时），失败回落 root 命令。 */
    private fun putSecure(context: Context, key: String, value: String, preferDirectWrite: Boolean) {
        if (preferDirectWrite) {
            if (Settings.Secure.putString(context.contentResolver, key, value)) {
                return
            }
            Log.w(TAG, "direct put secure failed: $key, fallback to root")
        }
        execRoot("settings put secure $key '$value'")
    }

    /** WRITE_SECURE_SETTINGS 是否已授予（adb pm grant 或系统签名）。 */
    private fun canWriteSecureSettings(context: Context): Boolean {
        return context.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun reportStartupHealth(
        reason: String,
        sn: String,
        root: Boolean,
        secureWritable: Boolean,
        inputOpen: Boolean,
    ) {
        val payload = JSONObject().apply {
            put("reason", reason)
            put("sn_ok", sn.isNotEmpty())
            put("root", root)
            put("secure_write", secureWritable)
            put("input_open", inputOpen)
            put("service_ready", MainService.isReady)
            put("service_start", MainService.isStart)
            put("timestamp", System.currentTimeMillis())
        }.toString()
        Log.i(TAG, "startup_health $payload")
        Handler(Looper.getMainLooper()).post {
            MainActivity.flutterMethodChannel?.invokeMethod("on_startup_health", payload)
        }
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
