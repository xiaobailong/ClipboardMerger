package com.example.clipboardmerger

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.TextView

/**
 * 「切换到剪集输入法」提醒页（绑定App 功能）。
 *
 * 一个页面只留**一层**弹框（v1.84 起）：
 * ①进来时本页**完全不可见**（透明窗口 + 卡片 `GONE`），只负责“拿到窗口焦点 → 调起系统输入法选择器”；
 *   选择器出现后就是用户唯一看到的弹框 —— 不再有“提醒卡片 + 选择器”两层叠加（用户反馈的“两层弹框”）。
 * ②若 [CARD_FALLBACK_DELAY_MS] 之后本页仍持有着窗口焦点（说明选择器没弹出来，例如被系统拦了），
 *   才把兜底卡片显示出来（弹出选择器 / 打开系统输入法设置 / 关闭）。
 *
 * 为什么必须先拿到窗口焦点：`InputMethodManagerService.canShowInputMethodPickerLocked()` 只在
 * 「调用方 == 当前焦点窗口的 client」或「调用方就是当前输入法」时才真的弹选择器，否则只写一条系统日志
 * （`Slog.w("Ignoring showInputMethodPickerFromClient of uid ...")`）后静默丢弃 —— 应用侧既没有异常
 * 也没有返回值（旧实现 v1.78 / v1.79 在 `onCreate` 里就调，所以选择器永远不弹）。
 *
 * 为什么自动只调一次：`InputMethodMenuController.showInputMethodMenu()` 是「先
 * `hideInputMethodMenuLocked()` 再新建 dialog」，重复调用会把已经弹出的选择器关掉再重开（“一闪而过”）。
 */
class PickerActivity : Activity() {

    private val handler = Handler(Looper.getMainLooper())
    private var attemptCount = 0
    private var destroyed = false
    private var cardRevealed = false

    /** 本页窗口失去焦点的时间点；0 = 当前持有焦点 */
    private var focusLostAt = 0L

    private val showPickerRunnable = Runnable { tryShowPicker("auto") }

    /** 选择器没弹出来（本页一直没失焦）⇒ 才把兜底卡片显出来 */
    private val revealCardRunnable = Runnable {
        if (destroyed || cardRevealed) return@Runnable
        if (!hasWindowFocus()) {
            Logger.d("PickerActivity: fallback card not needed (window lost focus = picker shown)")
            return@Runnable
        }
        Logger.w("PickerActivity: picker did not show within ${CARD_FALLBACK_DELAY_MS}ms, revealing fallback card")
        revealCard()
    }

    private val autoCloseRunnable = Runnable {
        if (destroyed) return@Runnable
        Logger.d("PickerActivity: auto close after ${AUTO_CLOSE_MS}ms")
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_picker)

        // 默认完全不可见：让“系统输入法选择器”成为唯一一层弹框
        findViewById<View>(R.id.pickerRoot).setBackgroundColor(Color.TRANSPARENT)
        findViewById<View>(R.id.pickerCard).visibility = View.GONE

        val appName = intent?.getStringExtra(EXTRA_APP_NAME).orEmpty()
        findViewById<TextView>(R.id.tvPickerMessage).text = if (appName.isBlank()) {
            getString(R.string.picker_message_default)
        } else {
            getString(R.string.picker_message, appName)
        }

        findViewById<Button>(R.id.btnPickerSwitch).setOnClickListener {
            Logger.d("PickerActivity: manual switch button clicked")
            revealCard()
            tryShowPicker("manual")
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
        Logger.d("PickerActivity: onCreate finished (invisible), waiting for window focus (app=[$appName])")
    }

    /** 把兜底卡片显出来（只有“选择器没弹出来”时才会走到这里） */
    private fun revealCard() {
        if (cardRevealed) return
        cardRevealed = true
        findViewById<View>(R.id.pickerRoot).setBackgroundResource(R.color.picker_scrim)
        findViewById<View>(R.id.pickerCard).visibility = View.VISIBLE
        Logger.d("PickerActivity: fallback card revealed")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        Logger.d("PickerActivity: onWindowFocusChanged hasFocus=$hasFocus, attempts=$attemptCount")
        if (hasFocus) {
            if (focusLostAt > 0L) {
                val lostMs = SystemClock.elapsedRealtime() - focusLostAt
                focusLostAt = 0L
                if (lostMs >= MIN_PICKER_VISIBLE_MS) {
                    // 失焦够久 ⇒ 选择器真的弹出来过、现在已被关掉（用户选完 / 取消）⇒ 本页退场
                    Logger.d("PickerActivity: picker shown & dismissed (${lostMs}ms), finishing")
                    finish()
                    return
                }
                // 极短失焦多半只是窗口切换抖动：忽略，继续等 / 走兜底卡片
                Logger.d("PickerActivity: focus flap ${lostMs}ms ignored")
            }
            if (attemptCount == 0) {
                // 必须等本应用的窗口成为“当前焦点窗口”之后再调，否则 IMMS 直接忽略（见类注释）
                handler.postDelayed(showPickerRunnable, PICKER_DELAY_MS)
                handler.postDelayed(revealCardRunnable, CARD_FALLBACK_DELAY_MS)
            }
        } else if (attemptCount > 0) {
            focusLostAt = SystemClock.elapsedRealtime()
        }
    }

    private fun tryShowPicker(source: String) {
        if (destroyed) return
        attemptCount++
        try {
            val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
            Logger.d("PickerActivity: showInputMethodPicker() called (source=$source, attempt=$attemptCount)")
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

        /** 请求后过多久仍没失焦 ⇒ 认为选择器没弹出来，显示兜底卡片 */
        private const val CARD_FALLBACK_DELAY_MS = 1_600L

        /** 失焦超过这个时长才算“选择器真的弹出来过”（更短的一律当抖动忽略） */
        private const val MIN_PICKER_VISIBLE_MS = 250L

        /** 本页最长存活时间，避免用户不管它时窗口一直挂着 */
        private const val AUTO_CLOSE_MS = 60_000L
    }
}
