package com.example.clipboardmerger

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 绑定App 的「悬浮提醒」气泡 —— 应用自绘的 WindowManager 悬浮窗。
 *
 * 为什么不用通知：华为 / 鸿蒙在**静音、振动、免打扰**三种状态下会把通知横幅整个吞掉
 * （实测渠道 `importance=4` + 有声音也不弹），而 `TYPE_APPLICATION_OVERLAY` 不经过通知系统 ⇒ 都能看到。
 * 需要「显示在其他应用上层」(`SYSTEM_ALERT_WINDOW`) 权限（入口：更多 → 悬浮提醒权限）。
 *
 * 窗口带 `FLAG_NOT_FOCUSABLE`，所以不抢焦点、不影响用户在其它 App 里打字。
 */
object BindAppBubble {

    private var view: View? = null
    private var windowManager: WindowManager? = null

    /** 是否已授予悬浮窗权限 */
    fun canShow(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

    fun isShown(): Boolean = view != null

    fun show(context: Context, text: String, onClick: () -> Unit, onClose: () -> Unit) {
        if (!canShow(context)) {
            Logger.w("BindAppBubble: overlay permission not granted, skip")
            return
        }
        if (view != null) {
            Logger.d("BindAppBubble: already shown, skip")
            return
        }
        val appContext = context.applicationContext
        try {
            val wm = appContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager

            val label = TextView(appContext).apply {
                this.text = text
                setTextColor(Color.WHITE)
                textSize = 14f
            }
            val close = TextView(appContext).apply {
                this.text = "✕"
                setTextColor(Color.parseColor("#B3FFFFFF"))
                textSize = 16f
                setPadding(dp(appContext, 12), 0, dp(appContext, 8), 0)
                setOnClickListener { onClose() }
            }
            val root = LinearLayout(appContext).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(
                    dp(appContext, 16), dp(appContext, 12),
                    dp(appContext, 6), dp(appContext, 12)
                )
                background = GradientDrawable().apply {
                    cornerRadius = dp(appContext, 24).toFloat()
                    setColor(Color.parseColor("#F2202124"))
                }
                elevation = dp(appContext, 8).toFloat()
                addView(label)
                addView(close)
                setOnClickListener { onClick() }
            }

            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            }
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                    or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                y = dp(appContext, 96)
            }

            wm.addView(root, params)
            windowManager = wm
            view = root
            Logger.d("BindAppBubble: shown")
        } catch (e: Exception) {
            Logger.e("BindAppBubble: show failed: ${e.message}", e)
            view = null
            windowManager = null
        }
    }

    fun hide() {
        val v = view ?: return
        try {
            windowManager?.removeView(v)
        } catch (e: Exception) {
            Logger.w("BindAppBubble: hide failed: ${e.message}")
        }
        view = null
        windowManager = null
        Logger.d("BindAppBubble: hidden")
    }

    private fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density).toInt()
}
