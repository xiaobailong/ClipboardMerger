package com.example.clipboardmerger

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.TextView

/**
 * 「切换到剪集输入法」提醒页（绑定App 功能）。
 *
 * 由 [ClipboardService] 发出的通知拉起（通知带全屏 Intent + 高重要性渠道，保证提醒能被看到）。
 *
 * 关键点（本次修复）：系统的 InputMethodManagerService.canShowInputMethodPickerLocked() 只在
 * 「调用方 == 当前焦点窗口的 client」或「调用方就是当前输入法」时才真的弹选择器，否则只写一条
 * 系统日志（Slog.w "Ignoring showInputMethodPickerFromClient of uid ..."）后静默丢弃 —— 应用侧
 * 既没有异常也没有返回值，看起来像"调用成功但界面不出现"。
 * 旧实现（v1.78 / v1.79）在 onCreate 里立刻调用（此时窗口还没拿到焦点）⇒ 选择器永远不弹。
 * 现在改为：窗口拿到焦点（onWindowFocusChanged(true)）之后再延迟 [PICKER_DELAY_MS] 调用，
 * 再等 [RETRY_DELAY_MS] 若窗口焦点仍在（说明选择器没弹出来）补一次，并保留手动兜底按钮。
 */
class PickerActivity : Activity() {

    private val handler = Handler(Looper.getMainLooper())
    private var attemptCount = 0
    private var destroyed = false

    /** 请求过选择器之后窗口是否失去过焦点（= 系统选择器真的弹出来了） */
    private var lostFocusAfterRequest = false

    private val showPickerRunnable = Runnable { tryShowPicker() }

    private val retryRunnable = Runnable {
        if (destroyed) return@Runnable
        if (hasWindowFocus()) {
            Logger.w("PickerActivity: window still focused ${RETRY_DELAY_MS}ms after request, picker may have been ignored by the system")
        }
        tryShowPicker()
    }

    private val autoCloseRunnable = Runnable {
        if (destroyed) return@Runnable
        Logger.d("PickerActivity: auto close after ${AUTO_CLOSE_MS}ms")
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_picker)

        val appName = intent?.getStringExtra(EXTRA_APP_NAME).orEmpty()
        val message = findViewById<TextView>(R.id.tvPickerMessage)
        message.text = if (appName.isBlank()) {
            getString(R.string.picker_message_default)
        } else {
            getString(R.string.picker_message, appName)
        }

        findViewById<Button>(R.id.btnPickerSwitch).setOnClickListener {
            Logger.d("PickerActivity: manual switch button clicked")
            tryShowPicker()
        }
        findViewById<Button>(R.id.btnPickerSettings).setOnClickListener {
            Logger.d("PickerActivity: open input method settings clicked")
            openInputMethodSettings()
        }
        findViewById<Button>(R.id.btnPickerClose).setOnClickListener {
            Logger.d("PickerActivity: close button clicked")
            finish()
        }

        handler.postDelayed(autoCloseRunnable, AUTO_CLOSE_MS)
        Logger.d("PickerActivity: onCreate finished, waiting for window focus (app=[$appName])")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        Logger.d("PickerActivity: onWindowFocusChanged hasFocus=$hasFocus, attempts=$attemptCount")
        if (hasFocus) {
            if (lostFocusAfterRequest) {
                // 选择器弹出过又被关掉（用户已经选完输入法）⇒ 提醒页自动退场
                Logger.d("PickerActivity: window focused again after picker, finishing")
                finish()
                return
            }
            if (attemptCount == 0) {
                // 必须等本应用的窗口成为“当前焦点窗口”之后再调，否则 IMMS 直接忽略（见类注释）
                handler.postDelayed(showPickerRunnable, PICKER_DELAY_MS)
                handler.postDelayed(retryRunnable, PICKER_DELAY_MS + RETRY_DELAY_MS)
            }
        } else if (attemptCount > 0) {
            lostFocusAfterRequest = true
        }
    }

    private fun tryShowPicker() {
        if (destroyed) return
        attemptCount++
        try {
            val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
            Logger.d("PickerActivity: showInputMethodPicker() called (attempt=$attemptCount)")
        } catch (e: Exception) {
            Logger.e("PickerActivity: showInputMethodPicker failed: ${e.message}", e)
        }
    }

    /** 兜底：部分华为/鸿蒙系统会拦截选择器，至少把用户送到系统输入法设置页 */
    private fun openInputMethodSettings() {
        try {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
            Logger.d("PickerActivity: ACTION_INPUT_METHOD_SETTINGS launched")
        } catch (e: Exception) {
            Logger.e("PickerActivity: failed to open input method settings: ${e.message}", e)
        }
        finish()
    }

    override fun onDestroy() {
        destroyed = true
        handler.removeCallbacksAndMessages(null)
        Logger.d("PickerActivity: destroyed")
        super.onDestroy()
    }

    companion object {
        const val EXTRA_APP_NAME = "extra_app_name"

        /** 拿到窗口焦点后延迟多久再请求选择器（留给 IMMS 更新“当前焦点窗口 client”） */
        private const val PICKER_DELAY_MS = 400L

        /** 第一次请求后过多久检查“选择器是不是被忽略了”并补一次 */
        private const val RETRY_DELAY_MS = 1500L

        /** 提醒页最长存活时间，避免用户不管它时窗口一直挂着 */
        private const val AUTO_CLOSE_MS = 60_000L
    }
}
