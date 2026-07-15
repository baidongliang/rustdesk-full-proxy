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
        // 被控端构建：最早把 conn-type 标为 incoming，使 Flutter 的
        // bind.isIncomingOnly() 在渲染 HomePage 前就返回 true，隐藏所有控制端 UI。
        // 控制端构建不调用此方法（保留双向能力）。
        FFI.setHostOnly()
        FFI.onAppStart(applicationContext)
        initDewodSdk()
        // 定制设备静默授权（root）：投屏免框 + 无障碍免手动开。
        // 异步执行，不阻塞 app 启动；非 root 设备安静失败。
        applySilentPermissions()
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

    /**
     * 定制设备静默授权（需 root）。
     *
     * 1. `appops set PROJECT_MEDIA allow`：让 MediaProjection 投屏授权框自动通过
     *    （定制 SystemUI 检测到此 appop 为 allow 时免手动确认）。
     * 2. 写 `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES`：把 InputService 加入
     *    已启用无障碍服务，免去用户到系统设置手动开。
     *
     * 仅在 root 可用时生效；非定制设备安静失败，不影响 app 运行。
     * 幂等：每次启动都设置一遍，确保状态正确（避免被系统重置）。
     */
    private fun applySilentPermissions() {
        thread {
            try {
                if (!hasRoot()) {
                    Log.i(TAG, "silent perms skipped: no root")
                    return@thread
                }
                val pkg = packageName
                // 1. 投屏 appop
                execRoot("appops set $pkg PROJECT_MEDIA allow")
                Log.i(TAG, "silent perm: PROJECT_MEDIA allow")
                // 2. 无障碍：写 secure settings 启用 InputService
                val svc = "$pkg/com.carriez.flutter_hbb.InputService"
                execRoot("settings put secure enabled_accessibility_services '$svc'")
                execRoot("settings put secure accessibility_enabled 1")
                Log.i(TAG, "silent perm: accessibility enabled ($svc)")
            } catch (e: Throwable) {
                Log.w(TAG, "applySilentPermissions err: ${e.message}")
            }
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

