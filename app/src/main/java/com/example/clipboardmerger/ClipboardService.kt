package com.example.clipboardmerger

import android.app.AppOpsManager
import android.app.Service
import android.app.usage.UsageStatsManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.view.inputmethod.InputMethodManager

class ClipboardService : Service() {

    private var clipboardManager: ClipboardManager? = null

    private val foregroundCheckHandler = Handler(Looper.getMainLooper())
    private var foregroundCheckRunnable: Runnable? = null
    private var lastPickerShownTime = 0L

    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        Logger.d("Service.ClipboardListener: onPrimaryClipChanged triggered")
        val clip = clipboardManager?.primaryClip
        if (clip == null) {
            Logger.w("Service.ClipboardListener: primaryClip is null (may be Android 10+ background restriction)")
            return@OnPrimaryClipChangedListener
        }
        var captured = false
        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i)
            val text = item.text?.toString() ?: ""
            val coerced = try {
                item.coerceToText(applicationContext).toString()
            } catch (e: Exception) {
                ""
            }
            Logger.d("Service.ClipboardListener[$i]: textLen=${text.length}, coercedLen=${coerced.length}")
            if (text.isNotBlank()) {
                ClipboardRepository.addItem(applicationContext, text)
                captured = true
            } else if (coerced.isNotBlank()) {
                ClipboardRepository.addItem(applicationContext, coerced)
                captured = true
            }
        }
        if (captured) {
            Logger.d("Service.ClipboardListener: sending broadcast to notify activity")
            val intent = Intent(ACTION_CLIPBOARD_UPDATED).apply {
                setPackage(packageName)
            }
            sendBroadcast(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Logger.init(this)
        Logger.d("========== ClipboardService.onCreate ==========")
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
        Logger.d("ClipboardService.onCreate: clipboard listener registered")
        startForegroundAppCheck()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Logger.d("ClipboardService.onStartCommand: flags=$flags, startId=$startId")
        return START_STICKY
    }

    override fun onDestroy() {
        Logger.d("========== ClipboardService.onDestroy ==========")
        stopForegroundAppCheck()
        clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? {
        Logger.d("ClipboardService.onBind")
        return null
    }

    private fun startForegroundAppCheck() {
        val runnable = object : Runnable {
            override fun run() {
                checkForegroundApp()
                foregroundCheckHandler.postDelayed(this, 5000L)
            }
        }
        foregroundCheckRunnable = runnable
        foregroundCheckHandler.postDelayed(runnable, 5000L)
        Logger.d("ClipboardService: foreground app check started")
    }

    private fun stopForegroundAppCheck() {
        foregroundCheckRunnable?.let { foregroundCheckHandler.removeCallbacks(it) }
        foregroundCheckRunnable = null
        Logger.d("ClipboardService: foreground app check stopped")
    }

    private fun checkForegroundApp() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val boundPackage = prefs.getString(KEY_BOUND_APP_PACKAGE, "") ?: ""
        if (boundPackage.isEmpty()) return

        if (!isUsageStatsPermissionGranted()) return

        if (isInputMethodDefault()) return

        val foregroundPkg = getForegroundPackage() ?: return
        if (foregroundPkg != boundPackage) return

        val now = System.currentTimeMillis()
        if (now - lastPickerShownTime < PICKER_COOLDOWN_MS) return

        Logger.d("ClipboardService: bound app [$boundPackage] in foreground, IME not active, showing picker")
        lastPickerShownTime = now

        try {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
            Logger.d("ClipboardService: input method picker shown")
        } catch (e: Exception) {
            Logger.e("ClipboardService: failed to show picker: ${e.message}", e)
        }
    }

    private fun getForegroundPackage(): String? {
        return try {
            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val now = System.currentTimeMillis()
            val stats = usm.queryUsageStats(
                UsageStatsManager.INTERVAL_DAILY,
                now - 10_000,
                now
            )
            if (stats.isNullOrEmpty()) return null
            val foreground = stats.maxByOrNull { it.lastTimeUsed }
            foreground?.packageName
        } catch (e: Exception) {
            Logger.w("ClipboardService: getForegroundPackage failed: ${e.message}")
            null
        }
    }

    private fun isUsageStatsPermissionGranted(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun isInputMethodDefault(): Boolean {
        val defaultIme = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.DEFAULT_INPUT_METHOD
        )
        return defaultIme != null && defaultIme.contains(packageName)
    }

    companion object {
        const val ACTION_CLIPBOARD_UPDATED = "com.example.clipboardmerger.CLIPBOARD_UPDATED"
        private const val PREFS_NAME = "clipboard_merger_settings"
        private const val KEY_BOUND_APP_PACKAGE = "bound_app_package"
        private const val PICKER_COOLDOWN_MS = 120_000L
    }
}