package com.example.clipboardmerger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机 / 应用更新后把后台监听服务拉回来。
 *
 * 华为「一键清理」之后如果进程是被普通 LMK 杀掉的，靠 [KeepAlive.scheduleRestart] 与输入法启动补回来；
 * 如果是重启手机 / 应用刚更新，则靠这里。被 force-stop 的情况系统不会发任何广播，只能用户手动打开 App。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        Logger.init(context)
        Logger.d("BootReceiver: onReceive action=$action")
        when (action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> KeepAlive.startServiceIfEnabled(context)
            else -> Logger.d("BootReceiver: ignored action=$action")
        }
    }
}
