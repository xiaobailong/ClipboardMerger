package com.example.clipboardmerger

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.view.accessibility.AccessibilityEvent

class ClipboardAccessibilityService : AccessibilityService() {

    private var clipboardManager: ClipboardManager? = null
    private var isListening = false

    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        Logger.d("AccessibilityService.ClipboardListener: onPrimaryClipChanged triggered")
        val clip = clipboardManager?.primaryClip
        if (clip == null) {
            Logger.w("AccessibilityService.ClipboardListener: primaryClip is null")
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
            Logger.d("AccessibilityService.ClipboardListener[$i]: textLen=${text.length}, coercedLen=${coerced.length}")
            if (text.isNotBlank()) {
                ClipboardRepository.addItem(applicationContext, text)
                captured = true
            } else if (coerced.isNotBlank()) {
                ClipboardRepository.addItem(applicationContext, coerced)
                captured = true
            }
        }
        if (captured) {
            Logger.d("AccessibilityService.ClipboardListener: sending broadcast")
            val intent = Intent(ClipboardService.ACTION_CLIPBOARD_UPDATED).apply {
                setPackage(packageName)
            }
            sendBroadcast(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Logger.init(this)
        Logger.d("========== AccessibilityService.onCreate ==========")
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Logger.d("========== AccessibilityService.onServiceConnected ==========")
        startListening()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!isListening) {
            startListening()
        }
    }

    override fun onInterrupt() {
        Logger.d("AccessibilityService.onInterrupt")
    }

    override fun onDestroy() {
        Logger.d("========== AccessibilityService.onDestroy ==========")
        stopListening()
        super.onDestroy()
    }

    private fun startListening() {
        if (isListening) return
        isListening = true
        clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
        Logger.d("AccessibilityService: clipboard listener registered, privileged=true")
    }

    private fun stopListening() {
        isListening = false
        clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        Logger.d("AccessibilityService: clipboard listener removed")
    }
}