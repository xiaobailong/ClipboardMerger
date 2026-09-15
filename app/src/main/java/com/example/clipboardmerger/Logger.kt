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

    private const val TAG = "ClipboardMerger"
    private const val LOG_FILE_PREFIX = "clipboard_merger_log"
    private const val LOG_RETENTION_DAYS = 7L
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.getDefault())
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())

    private var logFile: File? = null
    private var logFilePath: String = "N/A"
    private var initialized = false

    @Synchronized
    fun init(context: android.content.Context) {
        if (initialized) return
        initialized = true

        val appCtx = context.applicationContext
        val sb = StringBuilder()

        val sdk = android.os.Build.VERSION.SDK_INT
        val model = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"

        sb.append("=== ClipboardMerger v${getVersionName(appCtx)} ===\n")
        sb.append("=== SDK: $sdk | Device: $model ===\n")

        val result = trySetupLog()
        sb.append("=== Log: $result ===\n")

        sb.append("=== Log started ===")
        writeLine(sb.toString())
        android.util.Log.d(TAG, sb.toString())
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
                        android.util.Log.d(TAG, "cleanOldLogs: ${file.name} lastModified=${dateFormat.format(Date(file.lastModified()))}, deleted=$deleted")
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "cleanOldLogs failed: ${e.message}")
        }
    }

    fun d(message: String) {
        val timestamp = timestampFormat.format(Date())
        val thread = Thread.currentThread().name
        val line = "[$timestamp][$thread] $message"
        android.util.Log.d(TAG, message)
        writeLine(line)
    }

    fun w(message: String) {
        val timestamp = timestampFormat.format(Date())
        val thread = Thread.currentThread().name
        val line = "[$timestamp][$thread] WARN: $message"
        android.util.Log.w(TAG, message)
        writeLine(line)
    }

    fun e(message: String, throwable: Throwable? = null) {
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
            android.util.Log.e(TAG, "Log write failed: ${ex.message}")
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