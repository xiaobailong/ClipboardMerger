package com.example.clipboardmerger

import android.content.ComponentName
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.TextView

class ClipboardInputMethodService : InputMethodService() {

    private var clipboardManager: ClipboardManager? = null
    private var lastClipLabel: String = ""
    private var tvStatus: TextView? = null
    private val handler = Handler(Looper.getMainLooper())

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

        val btnClearClipboard = view.findViewById<Button>(R.id.btnClearClipboard)
        val btnPasteLast = view.findViewById<Button>(R.id.btnPasteLast)
        val btnPasteAll = view.findViewById<Button>(R.id.btnPasteAll)
        val btnSwitchBack = view.findViewById<Button>(R.id.btnSwitchBack)
        val btnDelete = view.findViewById<Button>(R.id.btnDelete)
        tvStatus = view.findViewById<TextView>(R.id.tvImeStatus)

        btnClearClipboard.setOnClickListener {
            Logger.d("IMEService: clear system clipboard and all collected items")
            val clip = ClipData.newPlainText("", "")
            clipboardManager?.setPrimaryClip(clip)
            ClipboardRepository.clearAll(applicationContext)
            lastClipLabel = ""
            tvStatus?.text = "剪切板已清空"
            val intent = Intent(ACTION_CLIPBOARD_UPDATED).apply {
                setPackage(packageName)
            }
            sendBroadcast(intent)
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
                tvStatus?.text = "📋 No clip data (IME must be default)"
            }
        }

        btnPasteAll.setOnClickListener {
            Logger.d("IMEService: paste ALL clips")
            val items = ClipboardRepository.loadItems(applicationContext)
            if (items.isEmpty()) {
                Logger.d("IMEService: pasteAll - no items in repository")
                tvStatus?.text = "📋 No items collected yet"
                return@setOnClickListener
            }
            val merged = items
                .sortedByDescending { it.timestamp }
                .joinToString(separator = "\n") { it.content }
            Logger.d("IMEService: pasteAll - ${items.size} items, merged len=${merged.length}")
            currentInputConnection?.commitText(merged, 1)
            tvStatus?.text = "✅ Pasted ${items.size} items"
        }

        btnDelete.setOnClickListener {
            Logger.d("IMEService: delete button clicked")
            val ic = currentInputConnection
            if (ic != null) {
                val selectedText = ic.getSelectedText(0)
                Logger.d("IMEService: delete - selectedText=[${selectedText}], len=${selectedText?.length}")
                if (!selectedText.isNullOrEmpty()) {
                    ic.commitText("", 1)
                    tvStatus?.text = "已删除选中文字 (${selectedText.length} chars)"
                } else {
                    tvStatus?.text = "⚠ 未选中任何文字"
                }
            } else {
                tvStatus?.text = "⚠ 无输入连接"
            }
        }

        btnSwitchBack.setOnClickListener {
            Logger.d("IMEService: switch IME button clicked")
            try {
                switchToTargetIme(0)
            } catch (e: Throwable) {
                Logger.e("IMEService: switchToTargetIme exception: ${e.message}", e)
                try {
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                    imm.showInputMethodPicker()
                } catch (e2: Exception) {
                    Logger.e("IMEService: fallback picker also failed: ${e2.message}", e2)
                }
            }
        }
        btnSwitchBack.setOnLongClickListener {
            Logger.d("IMEService: switch IME button long-pressed, showing picker")
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
            true
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

    private fun switchToTargetIme(targetIndex: Int) {
        Logger.d("IMEService.switchToTargetIme: ENTER targetIndex=$targetIndex")
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val enabledImes = imm.enabledInputMethodList
        Logger.d("IMEService.switchToTargetIme: enabledImes count=${enabledImes.size}")
        for ((i, ime) in enabledImes.withIndex()) {
            val label = ime.loadLabel(packageManager).toString()
            Logger.d("IMEService.switchToTargetIme: [$i] id=${ime.id} label=$label")
        }
        if (enabledImes.isEmpty()) {
            Logger.d("IMEService.switchToTargetIme: no enabled IMEs, showing picker")
            imm.showInputMethodPicker()
            return
        }

        if (targetIndex < 0 || targetIndex >= enabledImes.size) {
            Logger.d("IMEService.switchToTargetIme: targetIndex=$targetIndex out of range [0..${enabledImes.size - 1}], showing picker")
            imm.showInputMethodPicker()
            return
        }

        Logger.d("IMEService.switchToTargetIme: val targetId...")
        val targetId = enabledImes[targetIndex].id
        Logger.d("IMEService.switchToTargetIme: targetId=$targetId")
        Logger.d("IMEService.switchToTargetIme: val currentId...")
        val currentId = getCurrentInputMethodId()
        Logger.d("IMEService.switchToTargetIme: currentId=$currentId")
        Logger.d("IMEService.switchToTargetIme: val currentIndex...")
        val currentIndex = enabledImes.indexOfFirst { it.id == currentId }
        Logger.d("IMEService.switchToTargetIme: currentIndex=$currentIndex")
        val total = enabledImes.size

        val steps = if (currentIndex < 0) {
            targetIndex
        } else {
            (targetIndex - currentIndex + total) % total
        }
        Logger.d("IMEService.switchToTargetIme: steps=$steps")

        if (steps == 0) {
            Logger.d("IMEService.switchToTargetIme: already on target (index=$targetIndex, id=$targetId)")
            return
        }

        Logger.d("IMEService.switchToTargetIme: current=$currentId (idx=$currentIndex), target=$targetId (idx=$targetIndex), steps=$steps")
        tvStatus?.text = "切换中…"
        switchNextN(steps, imm)
    }

    private fun switchNextN(remaining: Int, imm: InputMethodManager) {
        Logger.d("IMEService.switchNextN: remaining=$remaining")
        if (remaining <= 0) {
            tvStatus?.text = "\uD83D\uDCD6 剪贴板监听"
            Logger.d("IMEService.switchNextN: done")
            return
        }
        try {
            val token = window.window?.attributes?.token
            Logger.d("IMEService.switchNextN: token=${token != null}")
            imm.switchToNextInputMethod(token, false)
        } catch (e: Exception) {
            Logger.e("IMEService.switchNextN: switchToNextInputMethod failed: ${e.message}", e)
        }
        handler.postDelayed({
            switchNextN(remaining - 1, imm)
        }, 80)
    }

    private fun getCurrentInputMethodId(): String {
        return ComponentName(this, this::class.java).flattenToShortString()
    }

    companion object {
        const val ACTION_CLIPBOARD_UPDATED = "com.example.clipboardmerger.CLIPBOARD_UPDATED"
    }
}