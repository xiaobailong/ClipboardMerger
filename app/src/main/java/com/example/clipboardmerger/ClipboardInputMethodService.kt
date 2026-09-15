package com.example.clipboardmerger

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.TextView

class ClipboardInputMethodService : InputMethodService() {

    private var clipboardManager: ClipboardManager? = null
    private var lastClipLabel: String = ""

    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        Logger.d("IMEService.ClipboardListener: onPrimaryClipChanged triggered")
        val clip = clipboardManager?.primaryClip
        if (clip == null) {
            Logger.w("IMEService.ClipboardListener: primaryClip is null (IME is not default or app in background)")
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
                lastClipLabel = text.take(40)
                captured = true
            } else if (coerced.isNotBlank()) {
                ClipboardRepository.addItem(applicationContext, coerced)
                lastClipLabel = coerced.take(40)
                captured = true
            }
        }
        if (captured) {
            Logger.d("IMEService.ClipboardListener: sending broadcast, label=[$lastClipLabel]")
            val intent = Intent(ACTION_CLIPBOARD_UPDATED).apply {
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

        val etInput = view.findViewById<EditText>(R.id.etInput)
        val btnSend = view.findViewById<Button>(R.id.btnSend)
        val btnPasteLast = view.findViewById<Button>(R.id.btnPasteLast)
        val btnPasteAll = view.findViewById<Button>(R.id.btnPasteAll)
        val btnSwitchBack = view.findViewById<Button>(R.id.btnSwitchBack)
        val tvStatus = view.findViewById<TextView>(R.id.tvImeStatus)

        btnSend.setOnClickListener {
            val text = etInput.text?.toString() ?: ""
            if (text.isNotEmpty()) {
                Logger.d("IMEService: sending text to app, len=${text.length}")
                currentInputConnection?.commitText(text, 1)
                etInput.text?.clear()
            }
        }

        btnPasteLast.setOnClickListener {
            Logger.d("IMEService: paste last clip, label=[$lastClipLabel]")
            val clip = clipboardManager?.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0).text?.toString()
                    ?: clip.getItemAt(0).coerceToText(applicationContext).toString()
                if (text.isNotEmpty()) {
                    currentInputConnection?.commitText(text, 1)
                }
            } else {
                tvStatus.text = "📋 No clip data (IME must be default)"
            }
        }

        btnPasteAll.setOnClickListener {
            Logger.d("IMEService: paste ALL clips")
            val items = ClipboardRepository.loadItems(applicationContext)
            if (items.isEmpty()) {
                Logger.d("IMEService: pasteAll - no items in repository")
                tvStatus.text = "📋 No items collected yet"
                return@setOnClickListener
            }
            val merged = items
                .sortedByDescending { it.timestamp }
                .joinToString(separator = "\n") { it.content }
            Logger.d("IMEService: pasteAll - ${items.size} items, merged len=${merged.length}")
            currentInputConnection?.commitText(merged, 1)
            tvStatus.text = "✅ Pasted ${items.size} items"
        }

        btnSwitchBack.setOnClickListener {
            Logger.d("IMEService: switch IME button clicked")
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
        }

        return view
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        Logger.d("IMEService.onStartInputView: restarting=$restarting, fieldName=${info?.fieldName}")
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

    companion object {
        const val ACTION_CLIPBOARD_UPDATED = "com.example.clipboardmerger.CLIPBOARD_UPDATED"
    }
}