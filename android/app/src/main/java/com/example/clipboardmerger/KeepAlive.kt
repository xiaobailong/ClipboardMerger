package com.example.clipboardmerger

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock

/**
 * 后台保活：华为「一键清理」会把后台进程一起杀掉，而且不会自动拉回来（即便开了自启动）。
 *
 * 这里做三件事，尽量让 [ClipboardService] 被杀之后能自己回来：
 * ①开机 / 应用更新后由 [BootReceiver] 拉起；
 * ②从最近任务划掉时（[ClipboardService.onTaskRemoved]）安排 1 秒后的一次性闹钟把自己拉回来；
 * ③[ClipboardInputMethodService] 启动时顺手把后台服务补起来 —— 剪集本身是输入法，只要用户还在用它，
 *   点任何输入框时系统都会启动输入法服务，这就是最可靠的“复活点”。
 *
 * 注：被系统**强行停止**（force-stop，部分清理工具会这么做）之后，任何方式都拉不起来，
 * 只能用户手动点开一次 App —— 这是 Android 的设计，不是 App 能绕过的。
 */
object KeepAlive {

    private const val RESTART_REQUEST_CODE = 1001

    private fun isEnabled(context: Context): Boolean =
        context.applicationContext
            .getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(MainActivity.KEY_BACKGROUND_SERVICE_ENABLED, true)

    /** 用户开关允许时把后台服务拉起来（已在跑也没关系，`onStartCommand` 是幂等的） */
    fun startServiceIfEnabled(context: Context) {
        val appContext = context.applicationContext
        if (!isEnabled(appContext)) {
            Logger.d("KeepAlive: background service disabled by user, skip")
            return
        }
        try {
            val intent = Intent(appContext, ClipboardService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                appContext.startForegroundService(intent)
            } else {
                appContext.startService(intent)
            }
            Logger.d("KeepAlive: background service start requested")
        } catch (e: Exception) {
            // Android 12+ 限制“后台启动前台服务”，被拦时抛 ForegroundServiceStartNotAllowedException
            Logger.w("KeepAlive: start foreground service failed: ${e.message}")
        }
    }

    /** 安排一次“稍后把自己拉回来”（用 getForegroundService 的 PendingIntent，避免落到后台启动限制里） */
    fun scheduleRestart(context: Context, delayMs: Long) {
        val appContext = context.applicationContext
        if (!isEnabled(appContext)) {
            Logger.d("KeepAlive: background service disabled by user, no restart scheduled")
            return
        }
        try {
            val intent = Intent(appContext, ClipboardService::class.java)
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val pendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PendingIntent.getForegroundService(appContext, RESTART_REQUEST_CODE, intent, flags)
            } else {
                PendingIntent.getService(appContext, RESTART_REQUEST_CODE, intent, flags)
            }
            val am = appContext.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + delayMs, pendingIntent)
            Logger.d("KeepAlive: restart scheduled in ${delayMs}ms")
        } catch (e: Exception) {
            Logger.w("KeepAlive: schedule restart failed: ${e.message}")
        }
    }
}
