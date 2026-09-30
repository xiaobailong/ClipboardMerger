package com.example.clipboardmerger

import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
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
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        Logger.d("ClipboardService.onCreate: foreground started")
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

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "后台服务",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "剪集后台监听中"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)

            // 渠道属性创建后不可变：v1.77 建的老渠道没开振动（⇒ 没有悬浮横幅），
            // 之后只改代码 / 对同一个 ID 做 delete+重建 都会被系统记住旧属性（ISSUE-007）。
            // 因此直接换新 ID 重建，并把老 ID 删掉，免得设置里留一条静音渠道。
            manager.deleteNotificationChannel(LEGACY_BIND_CHANNEL_ID)

            val bindChannel = NotificationChannel(
                BIND_CHANNEL_ID,
                "输入法切换提醒",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "检测到绑定应用时提醒切换输入法"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 200, 100, 300)
                setShowBadge(true)
            }
            manager.createNotificationChannel(bindChannel)

            val current = manager.getNotificationChannel(BIND_CHANNEL_ID)
            Logger.d(
                "ClipboardService: notificationsEnabled=${manager.areNotificationsEnabled()}, " +
                    "bindChannel=${current?.id}, importance=${current?.importance}, " +
                    "shouldVibrate=${current?.shouldVibrate()}"
            )
        }
    }

    private fun buildNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("剪集")
                .setContentText("后台监听中")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("剪集")
                .setContentText("后台监听中")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build()
        }
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
        if (boundPackage.isEmpty()) {
            Logger.d("ClipboardService.checkForegroundApp: no bound app, skip")
            return
        }

        if (!isUsageStatsPermissionGranted()) {
            Logger.w("ClipboardService.checkForegroundApp: usage stats permission NOT granted, skip")
            return
        }

        if (isInputMethodDefault()) {
            Logger.d("ClipboardService.checkForegroundApp: IME already default, skip")
            return
        }

        val foregroundPkg = getForegroundPackage()
        if (foregroundPkg == null) {
            Logger.w("ClipboardService.checkForegroundApp: getForegroundPackage returned null")
            return
        }

        Logger.d("ClipboardService.checkForegroundApp: foreground=[$foregroundPkg], bound=[$boundPackage]")
        if (foregroundPkg != boundPackage) return

        val now = System.currentTimeMillis()
        if (now - lastPickerShownTime < PICKER_COOLDOWN_MS) {
            Logger.d("ClipboardService.checkForegroundApp: cooldown active, skip picker")
            return
        }

        Logger.d("ClipboardService: bound app [$boundPackage] in foreground, IME not active, sending notification")
        lastPickerShownTime = now

        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val appName = try {
                packageManager.getApplicationLabel(
                    packageManager.getApplicationInfo(boundPackage, 0)
                ).toString()
            } catch (e: Exception) {
                boundPackage
            }

            val pickerIntent = Intent(this, PickerActivity::class.java)
            pickerIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            pickerIntent.putExtra(PickerActivity.EXTRA_APP_NAME, appName)
            val pendingIntent = PendingIntent.getActivity(
                this, 1,
                pickerIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, BIND_CHANNEL_ID)
                    .setContentTitle("切换到剪集输入法")
                    .setContentText("$appName 正在运行，点击切换")
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .setCategory(Notification.CATEGORY_MESSAGE)
                    .setVisibility(Notification.VISIBILITY_PUBLIC)
                    // 全屏 Intent：设备正在使用时会退化成“悬浮横幅”，息屏 / 锁屏时直接拉起提醒页。
                    // 只发普通通知时（v1.77~v1.79）提醒只会进抽屉，用户在华为上根本看不到（ISSUE-007）。
                    .setFullScreenIntent(pendingIntent, true)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
                    .setContentTitle("切换到剪集输入法")
                    .setContentText("$appName 正在运行，点击切换")
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setContentIntent(pendingIntent)
                    .setAutoCancel(true)
                    .setPriority(Notification.PRIORITY_HIGH)
                    .setDefaults(Notification.DEFAULT_VIBRATE)
                    .build()
            }
            nm.notify(BIND_NOTIFICATION_ID, notification)
            Logger.d("ClipboardService: bind app notification sent for [$appName]")
        } catch (e: Exception) {
            Logger.e("ClipboardService: failed to send notification: ${e.message}", e)
        }
    }

    private fun getForegroundPackage(): String? {
        return try {
            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val now = System.currentTimeMillis()
            val events = usm.queryEvents(now - 15_000, now)
            var lastPackage: String? = null
            var lastTime = 0L
            val event = UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                if (event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) {
                    if (event.timeStamp > lastTime) {
                        lastTime = event.timeStamp
                        lastPackage = event.packageName
                    }
                }
            }
            if (lastPackage != null) {
                Logger.d("ClipboardService.getForegroundPackage: event=MOVE_TO_FOREGROUND, pkg=[$lastPackage], lastTime=$lastTime")
            } else {
                Logger.d("ClipboardService.getForegroundPackage: no MOVE_TO_FOREGROUND in 15s window")
            }
            lastPackage
        } catch (e: Exception) {
            Logger.w("ClipboardService.getForegroundPackage: failed: ${e.message}")
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
        private const val CHANNEL_ID = "clipboard_service_channel"
        private const val NOTIFICATION_ID = 1
        // 渠道 ID 换新（老 ID "bind_app_channel" 的“无振动”属性不可修改，见 ISSUE-007）
        private const val BIND_CHANNEL_ID = "bind_app_channel_v2"
        private const val LEGACY_BIND_CHANNEL_ID = "bind_app_channel"
        private const val BIND_NOTIFICATION_ID = 2
    }
}