package com.example.clipboardmerger

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button

class ClipboardInputMethodService : InputMethodService() {

    private var clipboardManager: ClipboardManager? = null

    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        Logger.d("IMEService.ClipboardListener: onPrimaryClipChanged triggered")
        val clip = clipboardManager?.primaryClip
        if (clip == null) {
            Logger.w("IMEService.ClipboardListener: primaryClip is null")
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
            Logger.d("IMEService.ClipboardListener[$i]: textLen=${text.length}, coercedLen=${coerced.length}")
            if (text.isNotBlank()) {
                ClipboardRepository.addItem(applicationContext, text)
                captured = true
            } else if (coerced.isNotBlank()) {
                ClipboardRepository.addItem(applicationContext, coerced)
                captured = true
            }
        }
        if (captured) {
            Logger.d("IMEService.ClipboardListener: sending broadcast")
            val intent = Intent(ClipboardService.ACTION_CLIPBOARD_UPDATED).apply {
                setPackage(packageName)
            }
            sendBroadcast(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Logger.init(this)
        Logger.d("========== ClipboardInputMethodService.onCreate ==========")
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
        Logger.d("IMEService: clipboard listener registered")
    }

    override fun onCreateInputView(): View {
        Logger.d("IMEService.onCreateInputView")
        val view = layoutInflater.inflate(R.layout.ime_view, null)

        val btnOpenApp = view.findViewById<Button>(R.id.btnOpenApp)
        btnOpenApp.setOnClickListener {
            Logger.d("IMEService: Open App button clicked")
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
        }

        val btnSwitchBack = view.findViewById<Button>(R.id.btnSwitchBack)
        btnSwitchBack.setOnClickListener {
            Logger.d("IMEService: Switch IME button clicked")
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
        }

        return view
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        Logger.d("IMEService.onStartInputView: restarting=$restarting")
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        Logger.d("IMEService.onFinishInputView: finishingInput=$finishingInput")
    }

    override fun onDestroy() {
        Logger.d("========== ClipboardInputMethodService.onDestroy ==========")
        clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        super.onDestroy()
    }
}