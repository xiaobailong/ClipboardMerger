package com.example.clipboardmerger

import android.os.Environment
import java.io.File
import java.io.FileWriter
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object Logger {

    /** 日志开关的持久化位置（与 MainActivity 共用同一份 SharedPreferences） */
    const val PREFS_NAME = "clipboard_merger_settings"
    const val KEY_LOG_ENABLED = "log_enabled"

    private const val TAG = "ClipboardMerger"
    private const val LOG_FILE_PREFIX = "clipboard_merger_log"
    private const val LOG_RETENTION_DAYS = 7L
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.getDefault())
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())

    private var logFile: File? = null
    private var logFilePath: String = "N/A"
    private var initialized = false
    private var enabled = true

    @Synchronized
    fun init(context: android.content.Context) {
        if (initialized) return
        initialized = true

        val appCtx = context.applicationContext
        val sb = StringBuilder()

        // 开关状态必须从 SharedPreferences 恢复：Activity / Service / 输入法服务可能在不同进程生命周期里先后启动，
        // 只靠内存里的布尔量会在进程重启后回到默认值 true（历史缺陷：关掉日志后仍有输出）
        enabled = readEnabledFromPrefs(appCtx)

        val sdk = android.os.Build.VERSION.SDK_INT
        val model = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"

        sb.append("=== ClipboardMerger v${getVersionName(appCtx)} ===\n")
        sb.append("=== SDK: $sdk | Device: $model ===\n")

        val result = trySetupLog()
        sb.append("=== Log: $result ===\n")

        sb.append("=== Log started ===\n")
        sb.append("=== Log enabled: $enabled ===\n")
        writeLine(sb.toString())
        if (enabled) {
            android.util.Log.d(TAG, sb.toString())
        }
    }

    private fun readEnabledFromPrefs(context: android.content.Context): Boolean {
        return try {
            context.getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
                .getBoolean(KEY_LOG_ENABLED, true)
        } catch (e: Exception) {
            true
        }
    }

    private fun trySetupLog(): String {
        return try {
            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            val logDir = File(downloadsDir, "ClipboardMerger")
            if (!logDir.exists()) logDir.mkdirs()

            cleanOldLogs(logDir)

            val today = dateFormat.format(Date())
            val file = File(logDir, "${LOG_FILE_PREFIX}_${today}.txt")
            logFile = file
            logFilePath = file.absolutePath
            "OK: $logFilePath"
        } catch (e: Exception) {
            "FAILED: ${e.message}"
        }
    }

    private fun cleanOldLogs(dir: File) {
        try {
            val cutoffTime = System.currentTimeMillis() - LOG_RETENTION_DAYS * 24 * 60 * 60 * 1000L
            val logFiles = dir.listFiles { f ->
                f.isFile && f.name.startsWith(LOG_FILE_PREFIX) && f.name.endsWith(".txt")
            }
            if (logFiles != null) {
                for (file in logFiles) {
                    if (file.lastModified() < cutoffTime) {
                        val deleted = file.delete()
                        if (enabled) {
                            android.util.Log.d(TAG, "cleanOldLogs: ${file.name} lastModified=${dateFormat.format(Date(file.lastModified()))}, deleted=$deleted")
                        }
                    }
                }
            }
        } catch (e: Exception) {
            if (enabled) {
                android.util.Log.w(TAG, "cleanOldLogs failed: ${e.message}")
            }
        }
    }

    /**
     * 开关日志输出并持久化到 SharedPreferences。
     * 只保留这一个入口：任何进程重新启动都能读到同一份设置，不依赖内存中的临时状态。
     */
    @Synchronized
    fun setEnabled(context: android.content.Context, enabled: Boolean) {
        this.enabled = enabled
        try {
            context.applicationContext
                .getSharedPreferences(PREFS_NAME, android.content.Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_LOG_ENABLED, enabled)
                .apply()
        } catch (e: Exception) {
            android.util.Log.e(TAG, "Log setting save failed: ${e.message}")
        }
        // 关闭期间不建日志文件；重新打开时补建，避免本进程内后续日志无处可写
        if (enabled && logFile == null) {
            val result = trySetupLog()
            android.util.Log.d(TAG, "Log re-enabled, file setup: $result")
        }
    }

    fun isEnabled(): Boolean = enabled

    fun d(message: String) {
        if (!enabled) return
        val timestamp = timestampFormat.format(Date())
        val thread = Thread.currentThread().name
        val line = "[$timestamp][$thread] $message"
        android.util.Log.d(TAG, message)
        writeLine(line)
    }

    fun w(message: String) {
        if (!enabled) return
        val timestamp = timestampFormat.format(Date())
        val thread = Thread.currentThread().name
        val line = "[$timestamp][$thread] WARN: $message"
        android.util.Log.w(TAG, message)
        writeLine(line)
    }

    fun e(message: String, throwable: Throwable? = null) {
        if (!enabled) return
        val timestamp = timestampFormat.format(Date())
        val thread = Thread.currentThread().name
        val sb = StringBuilder()
        sb.append("[$timestamp][$thread] ERROR: $message")
        if (throwable != null) {
            val sw = StringWriter()
            throwable.printStackTrace(PrintWriter(sw))
            sb.append("\n").append(sw.toString())
        }
        android.util.Log.e(TAG, message, throwable)
        writeLine(sb.toString())
    }

    private fun writeLine(line: String) {
        if (!enabled) return
        val text = line + "\n"
        try {
            logFile?.let { file ->
                file.parentFile?.mkdirs()
                FileWriter(file, true).use { writer ->
                    writer.append(text)
                    writer.flush()
                }
            }
        } catch (ex: Exception) {
            if (enabled) {
                android.util.Log.e(TAG, "Log write failed: ${ex.message}")
            }
        }
    }

    fun getLogPath(): String = logFilePath

    private fun getVersionName(context: android.content.Context): String {
        return try {
            val pkgInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            pkgInfo.versionName ?: "unknown"
        } catch (e: Exception) {
            "unknown"
        }
    }
}