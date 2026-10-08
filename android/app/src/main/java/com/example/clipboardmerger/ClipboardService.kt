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
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.inputmethod.InputMethodManager

class ClipboardService : Service() {

    private var clipboardManager: ClipboardManager? = null

    private val foregroundCheckHandler = Handler(Looper.getMainLooper())
    private var foregroundCheckRunnable: Runnable? = null
    private var lastPickerShownTime = 0L

    /** 上一次检测到的前台包名：用来判断“刚刚进入绑定 App”（进入即重置提醒门） */
    private var lastForegroundPackage: String? = null

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
        // 用户在「提醒设置」里关掉后台监听服务后，任何残留的启动请求都不再把它拉起来（常驻通知随之消失）
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(MainActivity.KEY_BACKGROUND_SERVICE_ENABLED, true)) {
            Logger.d("ClipboardService.onStartCommand: background service disabled by user, stopSelf")
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 用户从「最近任务」划掉本应用：安排 1 秒后把后台服务拉回来（华为一键清理后也走这条路复活）
        Logger.d("ClipboardService.onTaskRemoved: task removed, scheduling restart")
        KeepAlive.scheduleRestart(this, 1_000L)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        Logger.d("========== ClipboardService.onDestroy ==========")
        BindAppBubble.hide()
        stopForegroundAppCheck()
        clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        super.onDestroy()
    }

    /** 常驻通知用哪条渠道：用户在提醒设置里选了“隐藏常驻通知”就用 IMPORTANCE_NONE 那条 */
    private fun serviceChannelId(): String {
        val hidden = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(MainActivity.KEY_HIDE_PERSISTENT_NOTIFICATION, false)
        return if (hidden) HIDDEN_CHANNEL_ID else CHANNEL_ID
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)

            // 常驻通知渠道：默认 IMPORTANCE_MIN（无状态栏图标、抽屉里最底部那一条）；
            // 用户嫌“一直显示”时切到 IMPORTANCE_NONE —— 通知记录照旧提交（前台服务身份成立、服务不会被杀），
            // 但系统不再展示它。渠道属性创建后不可变 ⇒ 两条 ID 二选一，把不用的那条删掉。
            val hidden = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(MainActivity.KEY_HIDE_PERSISTENT_NOTIFICATION, false)
            val channelId = serviceChannelId()
            manager.deleteNotificationChannel(if (hidden) CHANNEL_ID else HIDDEN_CHANNEL_ID)

            val channel = NotificationChannel(
                channelId,
                "后台服务",
                if (hidden) NotificationManager.IMPORTANCE_NONE else NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = if (hidden) "已隐藏（后台监听仍在运行）" else "剪集后台监听中"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
            Logger.d("ClipboardService: service channel=$channelId, hidden=$hidden")

            // 渠道属性创建后不可变：v1.77 的老渠道没开振动，v2 又**没有声音** ——
            // 华为/鸿蒙把“无声音”的渠道按“静默通知”处理，不给悬浮横幅（实测 importance=4 仍不弹）。
            // 所以再换新 ID v3：高重要性 + 声音 + 振动，并把老 ID 都删掉。
            manager.deleteNotificationChannel(LEGACY_BIND_CHANNEL_ID)
            manager.deleteNotificationChannel(LEGACY_BIND_CHANNEL_ID_V2)

            val bindChannel = NotificationChannel(
                BIND_CHANNEL_ID,
                "输入法切换提醒",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "检测到绑定应用时提醒切换输入法"
                setShowBadge(true)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 200, 100, 300)
                // 必须带声音：没声音的渠道在华为上等同“静默通知”，不会有横幅
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .build()
                )
            }
            manager.createNotificationChannel(bindChannel)

            val current = manager.getNotificationChannel(BIND_CHANNEL_ID)
            val canOverlay = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
            Logger.d(
                "ClipboardService: notificationsEnabled=${manager.areNotificationsEnabled()}, " +
                    "bindChannel=${current?.id}, importance=${current?.importance}, " +
                    "shouldVibrate=${current?.shouldVibrate()}, hasSound=${current?.sound != null}, " +
                    "canDrawOverlays=$canOverlay"
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
            Notification.Builder(this, serviceChannelId())
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

        // 提醒总开关（「提醒设置」里可关）：关闭后既不出气泡，也不再发提醒通知，并把已发出的撤掉
        if (!prefs.getBoolean(MainActivity.KEY_REMINDER_ENABLED, true)) {
            BindAppBubble.hide()
            cancelReminderNotification()
            return
        }

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

        // 离开绑定 App ⇒ 记一笔，下次再进来重新允许提醒一次
        // （旧实现是 2 分钟内存冷却 ⇒ 用户看到“抖音来回开好几次，只有第一次有提醒”，见 ISSUE-007）
        if (foregroundPkg != boundPackage) {
            if (lastForegroundPackage == boundPackage) {
                Logger.d("ClipboardService: bound app left foreground, next entry will remind again")
            }
            BindAppBubble.hide()
            lastForegroundPackage = foregroundPkg
            return
        }

        val justEntered = lastForegroundPackage != boundPackage
        lastForegroundPackage = boundPackage

        val now = System.currentTimeMillis()
        if (justEntered) {
            Logger.d("ClipboardService: bound app entered foreground, reminder gate reset")
            lastPickerShownTime = 0L
        }
        if (now - lastPickerShownTime < PICKER_MIN_INTERVAL_MS) {
            Logger.d("ClipboardService.checkForegroundApp: reminded ${now - lastPickerShownTime}ms ago, skip")
            return
        }

        Logger.d("ClipboardService: bound app [$boundPackage] in foreground, IME not active, reminding")
        lastPickerShownTime = now

        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val appName = resolveAppName(boundPackage)

            if (BindAppBubble.canShow(this)) {
                // 静音 / 振动 / 免打扰下通知横幅会被系统整个吞掉 ⇒ 改走自绘悬浮窗（不经过通知系统）
                showBubbleReminder(appName)
            } else {
                Logger.w("ClipboardService: overlay permission NOT granted, falling back to notification")
                sendReminderNotification(nm, appName)
            }
        } catch (e: Exception) {
            Logger.e("ClipboardService: failed to show reminder: ${e.message}", e)
        }
    }

    /** 撤掉“提醒”那条通知（关掉提醒开关、或改走悬浮气泡时） */
    private fun cancelReminderNotification() {
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(BIND_NOTIFICATION_ID)
        } catch (e: Exception) {
            Logger.w("ClipboardService: cancel reminder notification failed: ${e.message}")
        }
    }

    /**
     * 悬浮提醒（**静音 / 振动 / 免打扰下依然可见**）。
     *
     * 华为/鸿蒙在静音、振动、免打扰三种状态下会把通知横幅整个吞掉（实测 `importance=4` + 有声音也没用），
     * 而 `TYPE_APPLICATION_OVERLAY` 是应用自绘窗口，完全不经过通知系统 ⇒ 这几种模式下都能看到。
     * 点气泡才打开提醒页（用户主动点击，不依赖后台启动豁免），比“自动弹窗”也更不打扰。
     */
    private fun showBubbleReminder(appName: String) {
        BindAppBubble.hide()
        cancelReminderNotification()
        BindAppBubble.show(
            context = this,
            text = getString(R.string.bind_app_bubble_text, appName),
            onClick = {
                Logger.d("ClipboardService: overlay bubble clicked, opening reminder page")
                BindAppBubble.hide()
                try {
                    val intent = Intent(this, PickerActivity::class.java)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    intent.putExtra(PickerActivity.EXTRA_APP_NAME, appName)
                    startActivity(intent)
                } catch (e: Exception) {
                    Logger.e("ClipboardService: open reminder page failed: ${e.message}", e)
                }
            },
            onClose = { BindAppBubble.hide() }
        )
        vibrateReminder()
    }

    /** 提醒时直接振一下（走 Vibrator，不经过通知系统，静音/振动模式下也能被感知） */
    private fun vibrateReminder() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            if (vibrator.hasVibrator()) {
                vibrator.vibrate(VibrationEffect.createOneShot(300L, VibrationEffect.DEFAULT_AMPLITUDE))
                Logger.d("ClipboardService: vibrated reminder feedback")
            }
        } catch (e: Exception) {
            Logger.w("ClipboardService: vibrate failed: ${e.message}")
        }
    }

    /** 取绑定 App 的显示名（取不到就用包名） */
    private fun resolveAppName(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (e: Exception) {
        pkg
    }

    /** 没有悬浮窗权限时的兜底：高重要性通知（含全屏 Intent） */
    private fun sendReminderNotification(nm: NotificationManager, appName: String) {
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
        Logger.d(
            "ClipboardService: bind app notification sent for [$appName] " +
                "(no overlay permission: 静音/免打扰下可能看不到，建议开启「悬浮提醒权限」)"
        )
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
        // 同一次“进入绑定 App”只提醒一次；相邻两次提醒的最短间隔（防抖动）
        private const val PICKER_MIN_INTERVAL_MS = 15_000L
        private const val CHANNEL_ID = "clipboard_service_channel"

        /** 隐藏版常驻通知渠道（IMPORTANCE_NONE：不展示，但前台服务身份成立） */
        private const val HIDDEN_CHANNEL_ID = "clipboard_service_channel_hidden"
        private const val NOTIFICATION_ID = 1
        // 渠道 ID 换新（属性创建后不可变：v2 没有声音 ⇒ 华为按“静默通知”处理，不给横幅，见 ISSUE-007）
        private const val BIND_CHANNEL_ID = "bind_app_channel_v3"
        private const val LEGACY_BIND_CHANNEL_ID = "bind_app_channel"
        private const val LEGACY_BIND_CHANNEL_ID_V2 = "bind_app_channel_v2"
        const val BIND_NOTIFICATION_ID = 2
    }
}