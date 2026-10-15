package com.example.clipboardmerger

import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView

class ClipboardInputMethodService : InputMethodService() {

    private var clipboardManager: ClipboardManager? = null
    private var lastClipLabel: String = ""
    private var tvStatus: TextView? = null
    private var rvClipboard: RecyclerView? = null
    private var imeAdapter: ImeClipboardAdapter? = null
    /** 面板根 view：切皮肤 / 每次显示时按皮肤重新上色（onCreateInputView 只会在面板首次创建时调用） */
    private var imeRootView: View? = null

    private val clipboardUpdateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            Logger.d("IMEService.BroadcastReceiver: received clipboard update")
            refreshClipboardList()
        }
    }

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
            refreshClipboardList()
            val intent = Intent(ACTION_CLIPBOARD_UPDATED).apply {
                setPackage(packageName)
            }
            sendBroadcast(intent)
        }
    }

    private fun refreshClipboardList() {
        val items = ClipboardRepository.loadItems(applicationContext)
            .sortedByDescending { it.timestamp }
        Logger.d("IMEService.refreshClipboardList: loaded ${items.size} items")
        imeAdapter?.submitList(items)
        val count = items.size
        tvStatus?.text = if (count > 0) "📋 $count 条记录" else "📋 剪贴板监听"
    }

    override fun onCreate() {
        super.onCreate()
        Logger.init(this)
        // 剪集输入法被系统启动时，顺手把后台监听服务补起来（华为清理后最可靠的“复活点”）
        KeepAlive.startServiceIfEnabled(this)
        Logger.d("========== ClipboardInputMethodService.onCreate ==========")
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
        Logger.d("IMEService: clipboard listener registered")
        val filter = IntentFilter(ACTION_CLIPBOARD_UPDATED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(clipboardUpdateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(clipboardUpdateReceiver, filter)
        }
        Logger.d("IMEService: broadcast receiver registered")
    }

    override fun onCreateInputView(): View {
        Logger.d("IMEService.onCreateInputView")
        val view = layoutInflater.inflate(R.layout.ime_view, null)
        imeRootView = view

        val screenHeight = resources.displayMetrics.heightPixels
        val maxHeight = (screenHeight * 0.25).toInt()
        val density = resources.displayMetrics.density
        val reservedDp = 40
        val reservedPx = (reservedDp * density).toInt()
        Logger.d("IMEService.onCreateInputView: screenHeight=$screenHeight, maxHeight=$maxHeight, density=$density, reservedPx=$reservedPx")

        val btnClearClipboard = view.findViewById<Button>(R.id.btnClearClipboard)
        val btnPasteLast = view.findViewById<Button>(R.id.btnPasteLast)
        val btnPasteAll = view.findViewById<Button>(R.id.btnPasteAll)
        val btnSwitchBack = view.findViewById<Button>(R.id.btnSwitchBack)
        val btnDelete = view.findViewById<Button>(R.id.btnDelete)
        val btnSettings = view.findViewById<Button>(R.id.btnSettings)
        val btnHideIme = view.findViewById<Button>(R.id.btnHideIme)
        tvStatus = view.findViewById<TextView>(R.id.tvImeStatus)
        rvClipboard = view.findViewById<RecyclerView>(R.id.rvImeClipboard)
        // 框架 addView 强制 WRAP_CONTENT 覆盖根 view.layoutParams，但 rv 在 LinearLayout 内部的 layoutParams 不受影响；
        // 直接设 rv 高度 = maxHeight - 按钮栏 - 状态栏预留，不再依赖 weight（weight 在 WRAP_CONTENT 下行为不可控）
        val rvHeight = (maxHeight - reservedPx).coerceAtLeast(0)
        rvClipboard?.layoutParams?.height = rvHeight
        Logger.d("IMEService.onCreateInputView: rvHeight=$rvHeight, rvLpHeight=${rvClipboard?.layoutParams?.height}")

        // 延迟记录布局后的实际高度（用于诊断漂移/高度问题）
        view.post {
            val btnBar = view.findViewById<LinearLayout>(R.id.btnBarContainer)
            val actualViewH = view.height
            val actualRvH = rvClipboard?.height ?: -1
            val actualBtnBarH = btnBar?.height ?: -1
            val actualTvStatusH = tvStatus?.height ?: -1
            val lpHeight = view.layoutParams?.height ?: -2
            Logger.d("IMEService.layout: viewH=$actualViewH, rvH=$actualRvH, btnBarH=$actualBtnBarH, statusH=$actualTvStatusH, viewLpHeight=$lpHeight, screenH=$screenHeight, maxH=$maxHeight")
        }

        imeAdapter = ImeClipboardAdapter(SkinStore.palette(this))
        imeAdapter?.onItemClickListener = { item ->
            Logger.d("IMEService: item clicked, committing text len=${item.content.length}")
            currentInputConnection?.commitText(item.content, 1)
            tvStatus?.text = "✅ 已粘贴"
        }
        rvClipboard?.layoutManager = LinearLayoutManager(this)
        rvClipboard?.adapter = imeAdapter

        refreshClipboardList()

        btnClearClipboard.setOnClickListener {
            Logger.d("IMEService: clear system clipboard and all collected items")
            val clip = ClipData.newPlainText("", "")
            clipboardManager?.setPrimaryClip(clip)
            ClipboardRepository.clearAll(applicationContext)
            lastClipLabel = ""
            imeAdapter?.submitList(emptyList())
            tvStatus?.text = "剪切板已清空"
            val intent = Intent(ACTION_CLIPBOARD_UPDATED).apply {
                setPackage(packageName)
            }
            sendBroadcast(intent)
        }

        btnPasteLast.setOnClickListener {
            Logger.d("IMEService: paste button clicked")
            val selectedItems = imeAdapter?.getSelectedItems() ?: emptyList()
            if (selectedItems.isNotEmpty()) {
                val text = selectedItems
                    .sortedByDescending { it.timestamp }
                    .joinToString(separator = "\n") { it.content }
                Logger.d("IMEService: pasting ${selectedItems.size} selected items, len=${text.length}")
                currentInputConnection?.commitText(text, 1)
                imeAdapter?.clearSelection()
                tvStatus?.text = "✅ 已粘贴 ${selectedItems.size} 条"
            } else {
                val items = imeAdapter?.getItems() ?: emptyList()
                if (items.isNotEmpty()) {
                    val latest = items[0].content
                    Logger.d("IMEService: pasting latest item, len=${latest.length}")
                    currentInputConnection?.commitText(latest, 1)
                    tvStatus?.text = "✅ 已粘贴最新记录"
                } else {
                    tvStatus?.text = "📋 无记录"
                }
            }
        }

        btnPasteAll.setOnClickListener {
            Logger.d("IMEService: paste ALL clips")
            val items = imeAdapter?.getItems() ?: ClipboardRepository.loadItems(applicationContext)
            if (items.isEmpty()) {
                Logger.d("IMEService: pasteAll - no items")
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
                } else if (selectedText != null && selectedText.isEmpty()) {
                    tvStatus?.text = "⚠ 未选中任何文字"
                } else {
                    Logger.d("IMEService: delete - selectedText is null (likely WebView), trying commitText + DEL key")
                    ic.commitText("", 1)
                    val now = SystemClock.uptimeMillis()
                    ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL, 0, 0, 0, 0, KeyEvent.FLAG_SOFT_KEYBOARD))
                    ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL, 0, 0, 0, 0, KeyEvent.FLAG_SOFT_KEYBOARD))
                    tvStatus?.text = "已删除选中内容"
                }
            } else {
                tvStatus?.text = "⚠ 无输入连接"
            }
        }

        btnSwitchBack.setOnClickListener {
            Logger.d("IMEService: switch IME button clicked")
            try {
                val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val targetImeId = prefs.getString(KEY_TARGET_IME, "") ?: ""
                if (targetImeId.isEmpty()) {
                    Logger.d("IMEService: no saved target IME, will switch to next IME (default behavior)")
                } else {
                    Logger.d("IMEService: using saved target IME id=[$targetImeId]")
                }
                switchToTargetIme(targetImeId)
            } catch (e: Throwable) {
                Logger.e("IMEService: switchToTargetIme exception: ${e.message}", e)
                try {
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                    Logger.d("IMEService: fallback - showing input method picker")
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

        // 「⚙」齿轮按钮 → 「键盘设置」菜单（皮肤在这个菜单里切，App 侧共用同一份设置，见 SkinStore）
        btnSettings.setOnClickListener {
            Logger.d("IMEService: gear button clicked, current skin=${SkinStore.get(this)}")
            showSettingsMenu()
        }

        // 「隐藏」：收起面板（requestHideSelf 是 IME 侧收起软键盘的官方入口，不需要窗口 token）
        btnHideIme.setOnClickListener {
            Logger.d("IMEService: hide button clicked, requestHideSelf")
            try {
                requestHideSelf(0)
            } catch (e: Exception) {
                Logger.w("IMEService: requestHideSelf failed: ${e.message}")
                hideWindow()
            }
        }

        applySkin()

        return view
    }

    /**
     * 把当前皮肤应用到面板（根底色 / 按钮栏 / 按钮 / 历史列表 / 状态条）。
     * onCreateInputView（面板首次创建）+ onStartInputView（每次显示）都会调，
     * 所以 App 侧改了皮肤后，键盘下次显示就是新皮肤。
     */
    private fun applySkin() {
        val view = imeRootView ?: return
        val p = SkinStore.palette(this)
        Logger.d("IMEService.applySkin: ${SkinStore.get(this)}")

        view.setBackgroundColor(p.imeBg)
        view.findViewById<View>(R.id.btnBarScroll)?.setBackgroundColor(p.imeBarBg)
        rvClipboard?.setBackgroundColor(p.imeBg)
        tvStatus?.setBackgroundColor(p.imeStatusBg)
        tvStatus?.setTextColor(p.imeStatusFg)

        // 按钮底色顺序与 SkinPalette.imeKeyColors 一致：粘贴/全部粘贴/切换/删除/清空/⚙设置/隐藏
        val buttonIds = listOf(
            R.id.btnPasteLast, R.id.btnPasteAll, R.id.btnSwitchBack,
            R.id.btnDelete, R.id.btnClearClipboard, R.id.btnSettings, R.id.btnHideIme
        )
        for ((index, id) in buttonIds.withIndex()) {
            val button = view.findViewById<Button>(id) ?: continue
            button.setBackgroundColor(p.imeKeyColors.getOrElse(index) { p.imeKeyColors.last() })
            button.setTextColor(p.imeKeyFg)
        }

        imeAdapter?.let { adapter ->
            adapter.palette = p
            adapter.notifyDataSetChanged()
        }
    }

    /**
     * 面板内「⚙」按钮：弹出「键盘设置」菜单（对齐鸿蒙版键盘的 ⚙ 设置）。
     *
     * 皮肤只是菜单里的一项 —— 齿轮只做入口，选项在 [showSkinDialog] 里；以后键盘自己的设置
     * （切换目标 / 面板高度之类）往这里加一项即可，不要再往按钮栏塞独立按钮。
     */
    private fun showSettingsMenu() {
        val current = SkinStore.displayName(this, SkinStore.get(this))
        val items = arrayOf(getString(R.string.ime_menu_skin, current))
        Logger.d("IMEService.showSettingsMenu: opened, current skin=${SkinStore.get(this)}")
        try {
            val dialog = AlertDialog.Builder(this)
                .setTitle(R.string.ime_menu_title)
                .setItems(items) { _, which ->
                    Logger.d("IMEService.showSettingsMenu: clicked item=$which")
                    if (which == 0) showSkinDialog()
                }
                .setNegativeButton(android.R.string.cancel, null)
                .create()
            attachImeWindow(dialog)
            dialog.show()
        } catch (e: Exception) {
            Logger.w("IMEService.showSettingsMenu failed: ${e.message}, fallback=直接开皮肤弹框")
            showSkinDialog()
        }
    }

    /**
     * 输入法内的弹框必须依附输入法窗口：窗口类型 TYPE_APPLICATION_ATTACHED_DIALOG + 输入法窗口 token，
     * 否则 WMS 会丢 BadTokenException（App 侧 Activity 的 AlertDialog 不需要这一步）。
     */
    private fun attachImeWindow(dialog: AlertDialog) {
        val imeToken = window.window?.attributes?.token
        Logger.d("IMEService.attachImeWindow: imeToken=${imeToken != null}")
        dialog.window?.let { w ->
            w.setType(WindowManager.LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG)
            if (imeToken != null) {
                val lp = w.attributes
                lp.token = imeToken
                w.attributes = lp
            }
        }
    }

    /**
     * 「键盘设置 → 皮肤」弹框（对齐鸿蒙版键盘 ⚙ 里的「键盘皮肤」）。
     *
     * 弹框依附输入法窗口（见 [attachImeWindow]）；个别系统/机型仍可能拒绝 ⇒ catch 后兜底成
     * 「直接切到另一套」，保证入口任何时候都有效果（不崩、不静默）。
     */
    private fun showSkinDialog() {
        val ids = arrayOf(SKIN_HARMONY, SKIN_ANDROID)
        val labels = arrayOf(getString(R.string.skin_harmony), getString(R.string.skin_android))
        val currentId = SkinStore.get(this)
        val checked = ids.indexOf(currentId).coerceAtLeast(0)
        try {
            val dialog = AlertDialog.Builder(this)
                .setTitle(R.string.skin_title)
                .setSingleChoiceItems(labels, checked) { d, which ->
                    setSkin(ids[which])
                    d.dismiss()
                }
                .setNegativeButton(android.R.string.cancel, null)
                .create()

            attachImeWindow(dialog)
            dialog.show()
            Logger.d("IMEService.showSkinDialog: shown, current=$currentId, checked=$checked")
        } catch (e: Exception) {
            Logger.w("IMEService.showSkinDialog failed: ${e.message}, fallback=直接切换")
            setSkin(if (currentId == SKIN_ANDROID) SKIN_HARMONY else SKIN_ANDROID)
        }
    }

    /** 切换皮肤：持久化 → 立即给当前面板上色 → 状态条回显（App 侧下次进前台也是新皮肤） */
    private fun setSkin(id: String) {
        SkinStore.set(this, id)
        applySkin()
        tvStatus?.text = getString(R.string.skin_switched, SkinStore.displayName(this, id))
        Logger.d("IMEService.setSkin: $id")
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        // 面板 view 会复用：App 侧刚改过皮肤时靠这里补上（见 applySkin 注释）
        applySkin()
        val rvH = rvClipboard?.height ?: -1
        val rvItemCount = imeAdapter?.itemCount ?: -1
        Logger.d("IMEService.onStartInputView: restarting=$restarting, fieldName=${info?.fieldName}, rvH=$rvH, rvItems=$rvItemCount")
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        Logger.d("IMEService.onFinishInputView: finishingInput=$finishingInput")
    }

    override fun onDestroy() {
        Logger.d("========== ClipboardInputMethodService.onDestroy ==========")
        clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        try {
            unregisterReceiver(clipboardUpdateReceiver)
            Logger.d("IMEService: broadcast receiver unregistered")
        } catch (e: Exception) {
            Logger.w("IMEService: unregister receiver failed: ${e.message}")
        }
        super.onDestroy()
    }

    private fun switchToTargetIme(targetImeId: String) {
        Logger.d("IMEService.switchToTargetIme: ENTER targetImeId=[$targetImeId]")
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

        val targetIndex: Int
        if (targetImeId.isNotEmpty()) {
            targetIndex = enabledImes.indexOfFirst { it.id == targetImeId }
            if (targetIndex < 0) {
                Logger.d("IMEService.switchToTargetIme: saved IME id=[$targetImeId] not found in enabled list, showing picker")
                imm.showInputMethodPicker()
                return
            }
            Logger.d("IMEService.switchToTargetIme: found saved IME at index=$targetIndex")
        } else {
            val currentId = getCurrentInputMethodId()
            val currentIndex = enabledImes.indexOfFirst { it.id == currentId }
            if (currentIndex < 0) {
                Logger.d("IMEService.switchToTargetIme: current IME not found, showing picker")
                imm.showInputMethodPicker()
                return
            }
            targetIndex = (currentIndex + 1) % enabledImes.size
            Logger.d("IMEService.switchToTargetIme: no saved IME, switching to next: currentIndex=$currentIndex, targetIndex=$targetIndex")
        }

        Logger.d("IMEService.switchToTargetIme: targetIndex=$targetIndex")
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

        Logger.d("IMEService.switchToTargetIme: targetId=$targetId, currentId=$currentId")
        tvStatus?.text = "\u5207\u6362\u4e2d\u2026"

        if (targetImeId.isNotEmpty()) {
            switchToSpecificIme(targetImeId, imm)
        } else {
            switchToNextIme(imm)
        }
    }

    private fun switchToSpecificIme(targetImeId: String, imm: InputMethodManager) {
        val imeToken = window.window?.attributes?.token
        Logger.d("IMEService.switchToSpecificIme: targetImeId=[$targetImeId], imeToken=${imeToken != null}")
        if (imeToken == null) {
            Logger.w("IMEService.switchToSpecificIme: imeToken is null, showing picker")
            imm.showInputMethodPicker()
            return
        }
        try {
            val method = InputMethodManager::class.java.getMethod("setInputMethod", IBinder::class.java, String::class.java)
            method.invoke(imm, imeToken, targetImeId)
            Logger.d("IMEService.switchToSpecificIme: reflection succeeded")
        } catch (e: Exception) {
            Logger.w("IMEService.switchToSpecificIme: reflection failed: ${e.message}, showing picker")
            imm.showInputMethodPicker()
        }
    }

    private fun switchToNextIme(imm: InputMethodManager) {
        val imeToken = window.window?.attributes?.token
        Logger.d("IMEService.switchToNextIme: imeToken=${imeToken != null}")
        if (imeToken == null) {
            Logger.w("IMEService.switchToNextIme: imeToken is null, showing picker")
            imm.showInputMethodPicker()
            return
        }
        try {
            imm.switchToNextInputMethod(imeToken, false)
            Logger.d("IMEService.switchToNextIme: switchToNextInputMethod called")
        } catch (e: Exception) {
            Logger.e("IMEService.switchToNextIme: failed: ${e.message}", e)
            imm.showInputMethodPicker()
        }
    }

    private fun getCurrentInputMethodId(): String {
        return ComponentName(this, this::class.java).flattenToShortString()
    }

    companion object {
        const val ACTION_CLIPBOARD_UPDATED = "com.example.clipboardmerger.CLIPBOARD_UPDATED"
        const val PREFS_NAME = "clipboard_merger_settings"
        const val KEY_TARGET_IME = "target_ime_id"
    }
}