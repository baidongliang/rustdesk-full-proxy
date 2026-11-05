package com.carriez.flutter_hbb

import android.content.Context
import android.os.SystemClock

/**
 * 无障碍运行时自愈触发器。
 *
 * 背景：InputService（无障碍服务）运行中崩溃后，Android 进入退避不再重绑，
 * 而 app 进程（Rust 核心）仍存活——注册/视频/收指令全部正常，唯独指令注入被丢弃，
 * 且启动时的 SilentPermsHelper 自愈不会再触发（app 没有重启）。
 *
 * 本触发器挂在输入注入的丢弃分支上：连续丢弃达到阈值后调用
 * [SilentPermsHelper.applyAsync]（复用启动自愈逻辑：保留其他无障碍服务、
 * 直写/root 兜底），并以指数退避限制自愈频率，防止"一启用就崩"的服务造成自愈风暴。
 *
 * 预算重置：输入恢复正常持续 [HEALTHY_RESET_MS] 后，重试次数清零，
 * 下一次故障重新拿满预算。健康期间零开销（计数器归零后仅做一次比较）。
 */
object AccessibilitySelfHeal {
    private const val TAG = "AccessibilitySelfHeal"

    /** 连续丢弃达到该次数才触发自愈（鼠标移动 30~60 次/秒，约等于 100ms 内即触发）。 */
    private const val DROP_THRESHOLD = 3

    /** 每轮故障周期的最大自愈次数。 */
    private const val MAX_ATTEMPTS = 5

    /** 退避序列（毫秒）：第 1 次立即，之后 10s/20s/40s/60s 封顶。 */
    private val BACKOFF_MS = longArrayOf(0L, 10_000L, 20_000L, 40_000L, 60_000L)

    /** 输入持续健康该时长后，重置自愈预算。 */
    private const val HEALTHY_RESET_MS = 60_000L

    @Volatile private var dropCount = 0
    @Volatile private var attempts = 0
    @Volatile private var nextHealAt = 0L
    @Volatile private var healthySince = 0L
    @Volatile private var exhaustedLogged = false

    /** 输入注入因 InputService 未绑定被丢弃时调用（指针/按键共用）。 */
    @Synchronized
    fun onInputDropped(context: Context) {
        dropCount++
        if (dropCount < DROP_THRESHOLD) {
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (attempts >= MAX_ATTEMPTS) {
            if (!exhaustedLogged) {
                exhaustedLogged = true
                InputTraceLog.e(
                    context,
                    "$TAG self-heal exhausted attempts=$MAX_ATTEMPTS, waiting for input recovery to reset budget"
                )
            }
            return
        }
        if (now < nextHealAt) {
            return
        }
        dropCount = 0
        attempts++
        val backoff = BACKOFF_MS[attempts.coerceAtMost(BACKOFF_MS.size - 1)]
        nextHealAt = now + backoff
        InputTraceLog.w(
            context,
            "$TAG self-heal triggered attempt=$attempts backoffMs=$backoff (InputService unbound, runtime heal)"
        )
        SilentPermsHelper.applyAsync(context, "runtime_unbound:attempt$attempts")
    }

    /** 输入注入正常执行时调用。 */
    @Synchronized
    fun onInputHealthy(context: Context) {
        val now = SystemClock.elapsedRealtime()
        if (healthySince == 0L) {
            healthySince = now
        }
        if (dropCount == 0 && attempts == 0) {
            return
        }
        if (now - healthySince >= HEALTHY_RESET_MS) {
            InputTraceLog.i(
                context,
                "$TAG input healthy for ${HEALTHY_RESET_MS}ms, reset self-heal budget (was attempts=$attempts)"
            )
            reset()
        }
    }

    @Synchronized
    private fun reset() {
        dropCount = 0
        attempts = 0
        nextHealAt = 0L
        healthySince = 0L
        exhaustedLogged = false
    }
}
