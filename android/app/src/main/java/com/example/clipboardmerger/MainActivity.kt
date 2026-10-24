package com.example.clipboardmerger

import android.app.AlertDialog
import android.app.AppOpsManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import android.text.Editable
import android.text.TextWatcher
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.PopupMenu
import androidx.appcompat.widget.SwitchCompat
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.clipboardmerger.databinding.ActivityMainBinding
import com.google.android.material.tabs.TabLayout
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var viewModel: ClipboardViewModel
    private lateinit var adapter: ClipboardAdapter
    private lateinit var recycleAdapter: RecycleBinAdapter
    private var clipboardManager: ClipboardManager? = null
    private var selfUpdating = false
    private val handler = Handler(Looper.getMainLooper())
    private var pendingClipboardRead: Runnable? = null

    private val clipboardUpdateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            Logger.d("BroadcastReceiver: received clipboard update from service")
            viewModel.reloadFromRepository()
            viewModel.reloadRecycleBin()
        }
    }

    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        Logger.d("ClipboardListener: onPrimaryClipChanged triggered, selfUpdating=$selfUpdating")
        if (selfUpdating) {
            Logger.d("ClipboardListener: skip (selfUpdating=true)")
            return@OnPrimaryClipChangedListener
        }
        val clip = clipboardManager?.primaryClip
        if (clip == null) {
            Logger.w("ClipboardListener: primaryClip is null")
            return@OnPrimaryClipChangedListener
        }
        val label = clip.description.label?.toString() ?: ""
        Logger.d("ClipboardListener: itemCount=${clip.itemCount}, label=[$label]")
        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i)
            val text = item.text?.toString() ?: ""
            val html = item.htmlText ?: ""
            val uri = item.uri?.toString() ?: ""
            val coerced = try {
                item.coerceToText(applicationContext).toString()
            } catch (e: Exception) {
                "coerceToText failed: ${e.message}"
            }
            Logger.d("ClipboardListener[$i]: textLen=${text.length}, htmlLen=${html.length}, uri=[$uri], coercedLen=${coerced.length}")
            if (text.isNotBlank()) {
                viewModel.addItem(text)
            } else if (coerced.isNotBlank() && !coerced.startsWith("coerceToText failed")) {
                Logger.d("ClipboardListener[$i]: using coerced text as fallback")
                viewModel.addItem(coerced)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 日志开关由 Logger 自己从 SharedPreferences 恢复，Activity / Service / 输入法服务启动顺序不影响开关状态
        Logger.init(this)
        Logger.d("========== onCreate ==========")
        Logger.d("SDK_INT=${Build.VERSION.SDK_INT}, MANUFACTURER=${Build.MANUFACTURER}, MODEL=${Build.MODEL}")
        Logger.d("Log file path: ${Logger.getLogPath()}")

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar)

        val versionName = getVersionName()
        binding.toolbar.subtitle = "v$versionName"
        Logger.d("App version: $versionName")

        viewModel = ViewModelProvider(this)[ClipboardViewModel::class.java]
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        Logger.d("ClipboardManager obtained: ${clipboardManager != null}")

        setupRecyclerView()
        setupSwipeToDelete()
        setupSwipeRefresh()
        setupButtons()
        setupRecycleBin()
        observeViewModel()
        registerClipboardListener()
        registerClipboardUpdateReceiver()
        setupIMEStatus()
        setupBindAppStatus()
        startClipboardService()

        viewModel.reloadFromRepository()
        readCurrentClipboard()
        setupTabs()
        setupGitHubButtons()
        applySkin()
        Logger.d("========== onCreate finished ==========")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Logger.d("========== onNewIntent ==========")
        scheduleClipboardRead()
    }

    override fun onResume() {
        super.onResume()
        Logger.d("========== onResume ==========")
        viewModel.reloadFromRepository()
        viewModel.reloadRecycleBin()
        setupIMEStatus()
        setupBindAppStatus()
        scheduleClipboardRead()
        Logger.d("========== onResume finished ==========")
    }

    override fun onPause() {
        super.onPause()
        Logger.d("========== onPause ==========")
        cancelScheduledClipboardRead()
    }

    override fun onDestroy() {
        Logger.d("========== onDestroy ==========")
        cancelScheduledClipboardRead()
        clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        try {
            unregisterReceiver(clipboardUpdateReceiver)
            Logger.d("BroadcastReceiver unregistered")
        } catch (e: Exception) {
            Logger.w("BroadcastReceiver unregister failed: ${e.message}")
        }
        Logger.d("ClipboardListener removed, items count=${viewModel.items.value?.size ?: 0}")
        super.onDestroy()
    }

    private fun readCurrentClipboard() {
        Logger.d("readCurrentClipboard: start, selfUpdating=$selfUpdating")
        if (selfUpdating) {
            Logger.d("readCurrentClipboard: skip (selfUpdating=true)")
            return
        }
        val clip = clipboardManager?.primaryClip
        if (clip == null) {
            Logger.w("readCurrentClipboard: primaryClip is null")
            return
        }
        val description = clip.description
        val label = description.label?.toString() ?: ""
        Logger.d("readCurrentClipboard: itemCount=${clip.itemCount}, label=[$label]")
        for (i in 0 until clip.itemCount) {
            val item = clip.getItemAt(i)
            val text = item.text?.toString() ?: ""
            val html = item.htmlText ?: ""
            val uri = item.uri?.toString() ?: ""
            val coerced = try {
                item.coerceToText(applicationContext).toString()
            } catch (e: Exception) {
                "coerceToText failed: ${e.message}"
            }
            Logger.d("readCurrentClipboard[$i]: textLen=${text.length}, htmlLen=${html.length}, uri=[$uri], coercedLen=${coerced.length}")
            if (text.isNotBlank()) {
                viewModel.addItem(text)
            } else if (coerced.isNotBlank() && !coerced.startsWith("coerceToText failed")) {
                Logger.d("readCurrentClipboard[$i]: using coerced text as fallback")
                viewModel.addItem(coerced)
            }
        }
    }

    private fun scheduleClipboardRead() {
        cancelScheduledClipboardRead()
        val runnable = Runnable {
            Logger.d("[SCHEDULED] Running delayed clipboard read")
            readCurrentClipboard()
            pendingClipboardRead = null
        }
        pendingClipboardRead = runnable
        handler.postDelayed(runnable, 500)
        Logger.d("scheduleClipboardRead: posted with 500ms delay")
    }

    private fun cancelScheduledClipboardRead() {
        pendingClipboardRead?.let {
            handler.removeCallbacks(it)
            Logger.d("cancelScheduledClipboardRead: cancelled pending read")
        }
        pendingClipboardRead = null
    }

    private fun setupRecyclerView() {
        Logger.d("setupRecyclerView")
        adapter = ClipboardAdapter(
            palette = SkinStore.palette(this),
            onToggleSelection = { position -> viewModel.toggleSelection(position) },
            onDelete = { position -> deleteItemAt(position) }
        )
        binding.recyclerView.layoutManager = LinearLayoutManager(this)
        binding.recyclerView.adapter = adapter
    }

    private fun setupSwipeToDelete() {
        Logger.d("setupSwipeToDelete")
        val itemTouchHelper = ItemTouchHelper(object : ItemTouchHelper.SimpleCallback(
            0, ItemTouchHelper.LEFT
        ) {
            override fun getSwipeThreshold(viewHolder: RecyclerView.ViewHolder): Float = 0.25f

            override fun getSwipeEscapeVelocity(defaultValue: Float): Float = defaultValue * 0.5f

            override fun onMove(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                target: RecyclerView.ViewHolder
            ): Boolean = false

            override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
                val position = viewHolder.bindingAdapterPosition
                if (position != RecyclerView.NO_POSITION) {
                    Logger.d("ItemTouchHelper.onSwiped: position=$position")
                    deleteItemAt(position)
                }
            }

            override fun onChildDraw(
                c: Canvas,
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                dX: Float,
                dY: Float,
                actionState: Int,
                isCurrentlyActive: Boolean
            ) {
                if (actionState == ItemTouchHelper.ACTION_STATE_SWIPE) {
                    val holder = viewHolder as? ClipboardAdapter.ViewHolder
                    val cardView = holder?.cardView ?: viewHolder.itemView
                    val translationX = dX.coerceAtMost(0f)
                    cardView.translationX = translationX
                    return
                }
                super.onChildDraw(c, recyclerView, viewHolder, dX, dY, actionState, isCurrentlyActive)
            }

            override fun clearView(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder
            ) {
                super.clearView(recyclerView, viewHolder)
                val holder = viewHolder as? ClipboardAdapter.ViewHolder
                holder?.cardView?.translationX = 0f
            }
        })
        itemTouchHelper.attachToRecyclerView(binding.recyclerView)
    }

    private fun deleteItemAt(position: Int) {
        Logger.d("deleteItemAt: position=$position")
        viewModel.deleteItem(position)
        Toast.makeText(this, R.string.toast_item_deleted, Toast.LENGTH_SHORT).show()
    }

    private fun setupSwipeRefresh() {
        Logger.d("setupSwipeRefresh")
        binding.swipeRefresh.setColorSchemeResources(
            android.R.color.holo_blue_bright,
            android.R.color.holo_green_light,
            android.R.color.holo_orange_light
        )
        binding.swipeRefresh.setOnRefreshListener {
            Logger.d("[SWIPE] Pull-to-refresh triggered")
            viewModel.reloadFromRepository()
            binding.swipeRefresh.isRefreshing = false
            Logger.d("[SWIPE] Refresh complete, items=${viewModel.items.value?.size ?: 0}")
        }
    }

    private fun setupButtons() {
        Logger.d("setupButtons")
        binding.btnSelectAll.setOnClickListener {
            Logger.d("[BUTTON] SelectAll clicked")
            viewModel.selectAll()
        }
        binding.btnDeselectAll.setOnClickListener {
            Logger.d("[BUTTON] DeselectAll clicked")
            viewModel.deselectAll()
        }
        binding.btnMerge.setOnClickListener {
            Logger.d("[BUTTON] Merge clicked")
            performMerge()
        }
        binding.btnClear.setOnClickListener {
            Logger.d("[BUTTON] Clear clicked")
            viewModel.clearAll()
        }
    }

    private fun observeViewModel() {
        Logger.d("observeViewModel")
        viewModel.items.observe(this) { list ->
            Logger.d("ViewModel items changed: size=${list.size}")
            adapter.submitList(list)
            binding.tvEmpty.visibility =
                if (list.isEmpty()) View.VISIBLE else View.GONE
            binding.recyclerView.visibility =
                if (list.isEmpty()) View.GONE else View.VISIBLE
        }
        viewModel.recycleItems.observe(this) { list ->
            Logger.d("ViewModel recycleItems changed: size=${list.size}")
            recycleAdapter.submitList(list)
            val recycleRoot = binding.layoutRecycleBin.root
            recycleRoot.findViewById<android.widget.TextView>(R.id.tvRecycleEmpty).visibility =
                if (list.isEmpty()) View.VISIBLE else View.GONE
            recycleRoot.findViewById<RecyclerView>(R.id.rvRecycleBin).visibility =
                if (list.isEmpty()) View.GONE else View.VISIBLE
        }
    }

    private fun setupRecycleBin() {
        Logger.d("setupRecycleBin")
        val recycleRoot = binding.layoutRecycleBin.root
        recycleAdapter = RecycleBinAdapter(
            palette = SkinStore.palette(this),
            onToggleSelection = { position -> viewModel.toggleRecycleSelection(position) },
            onDelete = { position -> deleteRecycleItemAt(position) }
        )
        val rvRecycle = recycleRoot.findViewById<RecyclerView>(R.id.rvRecycleBin)
        rvRecycle.layoutManager = LinearLayoutManager(this)
        rvRecycle.adapter = recycleAdapter

        val swipeToDelete = ItemTouchHelper(object : ItemTouchHelper.SimpleCallback(
            0, ItemTouchHelper.LEFT
        ) {
            override fun getSwipeThreshold(viewHolder: RecyclerView.ViewHolder): Float = 0.25f
            override fun getSwipeEscapeVelocity(defaultValue: Float): Float = defaultValue * 0.5f
            override fun onMove(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                target: RecyclerView.ViewHolder
            ): Boolean = false

            override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
                val position = viewHolder.bindingAdapterPosition
                if (position != RecyclerView.NO_POSITION) {
                    Logger.d("RecycleBin.onSwiped: position=$position")
                    deleteRecycleItemAt(position)
                }
            }

            override fun onChildDraw(
                c: Canvas, recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder,
                dX: Float, dY: Float, actionState: Int, isCurrentlyActive: Boolean
            ) {
                if (actionState == ItemTouchHelper.ACTION_STATE_SWIPE) {
                    val holder = viewHolder as? RecycleBinAdapter.ViewHolder
                    val cardView = holder?.cardView ?: viewHolder.itemView
                    cardView.translationX = dX.coerceAtMost(0f)
                    return
                }
                super.onChildDraw(c, recyclerView, viewHolder, dX, dY, actionState, isCurrentlyActive)
            }

            override fun clearView(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder) {
                super.clearView(recyclerView, viewHolder)
                val holder = viewHolder as? RecycleBinAdapter.ViewHolder
                holder?.cardView?.translationX = 0f
            }
        })
        swipeToDelete.attachToRecyclerView(rvRecycle)

        recycleRoot.findViewById<View>(R.id.btnRecycleSelectAll).setOnClickListener {
            Logger.d("[BUTTON] Recycle SelectAll clicked")
            viewModel.selectAllRecycle()
        }
        recycleRoot.findViewById<View>(R.id.btnRecycleDeselectAll).setOnClickListener {
            Logger.d("[BUTTON] Recycle DeselectAll clicked")
            viewModel.deselectAllRecycle()
        }
        recycleRoot.findViewById<View>(R.id.btnRecycleRestoreSelected).setOnClickListener {
            Logger.d("[BUTTON] Recycle RestoreSelected clicked")
            restoreSelectedItems()
        }
        recycleRoot.findViewById<View>(R.id.btnRecycleRestoreAll).setOnClickListener {
            Logger.d("[BUTTON] Recycle RestoreAll clicked")
            restoreAllItems()
        }
        recycleRoot.findViewById<View>(R.id.btnRecycleRestoreRecent).setOnClickListener {
            Logger.d("[BUTTON] Recycle RestoreRecent clicked")
            restoreRecentBatch()
        }
        recycleRoot.findViewById<View>(R.id.btnRecycleRestoreBatch).setOnClickListener {
            Logger.d("[BUTTON] Recycle RestoreBatch clicked")
            showRestoreBatchDialog()
        }
        recycleRoot.findViewById<View>(R.id.btnRecycleClear).setOnClickListener {
            Logger.d("[BUTTON] Recycle Clear clicked")
            clearRecycleBin()
        }
    }

    private fun deleteRecycleItemAt(position: Int) {
        Logger.d("deleteRecycleItemAt: position=$position")
        val list = viewModel.recycleItems.value ?: return
        if (position in 0 until list.size) {
            val item = list[position]
            RecycleBinRepository.removeItems(this, listOf(item.id))
            viewModel.reloadRecycleBin()
            Toast.makeText(this, R.string.toast_item_deleted, Toast.LENGTH_SHORT).show()
        }
    }

    private fun restoreAllItems() {
        val all = viewModel.recycleItems.value ?: emptyList()
        if (all.isEmpty()) {
            Toast.makeText(this, R.string.toast_recycle_empty, Toast.LENGTH_SHORT).show()
            return
        }
        val count = all.size
        viewModel.restoreAll()
        notifyClipboardUpdated()
        Toast.makeText(this, getString(R.string.toast_restore_all_done, count), Toast.LENGTH_SHORT).show()
    }

    private fun restoreSelectedItems() {
        val selected = viewModel.getSelectedRecycleItems()
        if (selected.isEmpty()) {
            Toast.makeText(this, R.string.toast_restore_selected_none, Toast.LENGTH_SHORT).show()
            return
        }
        val count = selected.size
        viewModel.restoreSelected()
        notifyClipboardUpdated()
        Toast.makeText(this, getString(R.string.toast_restore_selected_done, count), Toast.LENGTH_SHORT).show()
    }

    private fun restoreRecentBatch() {
        val batches = viewModel.getBatchIds()
        if (batches.isEmpty()) {
            Toast.makeText(this, R.string.toast_recycle_empty, Toast.LENGTH_SHORT).show()
            return
        }
        val recent = batches.first()
        val count = viewModel.recycleItems.value?.count { it.batchId == recent } ?: 0
        viewModel.restoreRecentBatch()
        notifyClipboardUpdated()
        Toast.makeText(this, getString(R.string.toast_restore_recent_done, count), Toast.LENGTH_SHORT).show()
    }

    private fun showRestoreBatchDialog() {
        val batches = viewModel.getBatchIds()
        if (batches.isEmpty()) {
            Toast.makeText(this, R.string.dialog_restore_batch_empty, Toast.LENGTH_SHORT).show()
            return
        }
        val batchCounts = batches.associateWith { batchId ->
            viewModel.recycleItems.value?.count { it.batchId == batchId } ?: 0
        }
        val labels = batches.map { batchId ->
            val count = batchCounts[batchId] ?: 0
            "$batchId  ($count 条)"
        }
        val listView = ListView(this)
        val batchAdapter = ArrayAdapter(this, android.R.layout.simple_list_item_single_choice, labels)
        listView.adapter = batchAdapter
        listView.choiceMode = ListView.CHOICE_MODE_SINGLE
        listView.setItemChecked(0, true)

        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.dialog_restore_batch_title)
            .setView(listView)
            .setPositiveButton(R.string.dialog_restore_batch_confirm) { _, _ ->
                val pos = listView.checkedItemPosition
                if (pos in batches.indices) {
                    val batchId = batches[pos]
                    val count = batchCounts[batchId] ?: 0
                    viewModel.restoreBatch(batchId)
                    notifyClipboardUpdated()
                    Toast.makeText(this, getString(R.string.toast_restore_batch_done, count), Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .create()
        dialog.show()
    }

    private fun clearRecycleBin() {
        val all = viewModel.recycleItems.value ?: emptyList()
        if (all.isEmpty()) {
            Toast.makeText(this, R.string.toast_recycle_empty, Toast.LENGTH_SHORT).show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.btn_recycle_clear)
            .setMessage("确定要清空回收站吗？此操作不可撤销。")
            .setPositiveButton(android.R.string.ok) { _, _ ->
                viewModel.clearRecycleBin()
                Toast.makeText(this, R.string.toast_recycle_cleared, Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun notifyClipboardUpdated() {
        val intent = Intent(ClipboardService.ACTION_CLIPBOARD_UPDATED).apply {
            setPackage(packageName)
        }
        sendBroadcast(intent)
        Logger.d("notifyClipboardUpdated: broadcast sent")
    }

    private fun performMerge() {
        Logger.d("performMerge: start")
        val merged = viewModel.mergeSelected()
        if (merged == null) {
            Logger.d("performMerge: no items selected, showing toast")
            Toast.makeText(this, R.string.toast_select_item, Toast.LENGTH_SHORT).show()
            return
        }
        Logger.d("performMerge: merged length=${merged.length}")
        selfUpdating = true
        val clip = ClipData.newPlainText(getString(R.string.txt_merged_hint), merged)
        clipboardManager?.setPrimaryClip(clip)
        selfUpdating = false
        Logger.d("performMerge: setPrimaryClip done")
        Toast.makeText(this, R.string.toast_merged, Toast.LENGTH_SHORT).show()
    }

    private fun registerClipboardListener() {
        Logger.d("registerClipboardListener")
        clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
        Logger.d("registerClipboardListener: listener registered successfully")
    }

    private fun registerClipboardUpdateReceiver() {
        Logger.d("registerClipboardUpdateReceiver")
        val filter = IntentFilter(ClipboardService.ACTION_CLIPBOARD_UPDATED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(clipboardUpdateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(clipboardUpdateReceiver, filter)
        }
        Logger.d("registerClipboardUpdateReceiver: registered")
    }

    private fun startClipboardService() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_BACKGROUND_SERVICE_ENABLED, true)) {
            Logger.d("startClipboardService: background service disabled by user, skip")
            return
        }
        Logger.d("startClipboardService: start")
        val intent = Intent(this, ClipboardService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        Logger.d("startClipboardService: started")
    }

    private fun getVersionName(): String {
        return try {
            val pkgInfo = packageManager.getPackageInfo(packageName, 0)
            pkgInfo.versionName ?: "unknown"
        } catch (e: Exception) {
            Logger.w("getVersionName failed: ${e.message}")
            "unknown"
        }
    }

    private fun setupIMEStatus() {
        val isDefault = isInputMethodDefault()
        Logger.d("setupIMEStatus: isDefault=$isDefault")
        // 状态条配色跟皮肤走（原来硬编码 0xFFE8F5E9 / 0xFFFFF3E0，切皮肤后不跟着变）
        val p = SkinStore.palette(this)
        if (isDefault) {
            binding.tvAccessibilityStatus.text = getString(R.string.ime_status_active)
            binding.tvAccessibilityStatus.setBackgroundColor(p.statusOnBg)
            binding.tvAccessibilityStatus.setTextColor(p.statusOnFg)
        } else {
            binding.tvAccessibilityStatus.text = getString(R.string.ime_status_disabled)
            binding.tvAccessibilityStatus.setBackgroundColor(p.statusOffBg)
            binding.tvAccessibilityStatus.setTextColor(p.statusOffFg)
        }
        binding.tvAccessibilityStatus.visibility = View.VISIBLE
        binding.tvAccessibilityStatus.setOnClickListener {
            Logger.d("IME status clicked, opening input method picker")
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
            Toast.makeText(this, "Select \"剪集\" as your keyboard to enable background clipboard monitoring", Toast.LENGTH_LONG).show()
        }
    }

    private fun isInputMethodDefault(): Boolean {
        val defaultIme = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        val result = defaultIme != null && defaultIme.contains(packageName)
        Logger.d("isInputMethodDefault: package=$packageName, defaultIme=$defaultIme, result=$result")
        return result
    }

    private fun setupTabs() {
        Logger.d("setupTabs")
        binding.tabLayout.addTab(binding.tabLayout.newTab().setText(R.string.tab_clipboard))
        binding.tabLayout.addTab(binding.tabLayout.newTab().setText(R.string.tab_recycle_bin))
        binding.tabLayout.addTab(binding.tabLayout.newTab().setText(R.string.tab_github))
        binding.tabLayout.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab?) {
                when (tab?.position) {
                    0 -> {
                        binding.layoutClipboard.visibility = View.VISIBLE
                        binding.layoutRecycleBin.root.visibility = View.GONE
                        binding.layoutGithub.root.visibility = View.GONE
                    }
                    1 -> {
                        binding.layoutClipboard.visibility = View.GONE
                        binding.layoutRecycleBin.root.visibility = View.VISIBLE
                        binding.layoutGithub.root.visibility = View.GONE
                        viewModel.reloadRecycleBin()
                    }
                    2 -> {
                        binding.layoutClipboard.visibility = View.GONE
                        binding.layoutRecycleBin.root.visibility = View.GONE
                        binding.layoutGithub.root.visibility = View.VISIBLE
                    }
                }
            }
            override fun onTabUnselected(tab: TabLayout.Tab?) {}
            override fun onTabReselected(tab: TabLayout.Tab?) {}
        })
    }

    private fun setupGitHubButtons() {
        Logger.d("setupGitHubButtons")
        val githubRoot = binding.layoutGithub.root
        val etContent = githubRoot.findViewById<EditText>(R.id.etGithubContent)
        val btnEdit = githubRoot.findViewById<TextView>(R.id.btnGithubEdit)
        val btnSave = githubRoot.findViewById<TextView>(R.id.btnGithubSave)
        val btnSettings = githubRoot.findViewById<TextView>(R.id.btnGithubSettings)
        val tvStatus = githubRoot.findViewById<TextView>(R.id.tvGithubStatus)
        val githubHelper = GitHubHelper(this)

        btnEdit.setOnClickListener {
            Logger.d("GitHub: edit button clicked")
            if (!githubHelper.hasSettings()) {
                Toast.makeText(this, R.string.github_need_settings, Toast.LENGTH_SHORT).show()
                showGithubSettingsDialog()
                return@setOnClickListener
            }
            tvStatus.text = getString(R.string.github_fetching)
            btnEdit.isEnabled = false
            btnSave.isEnabled = false
            lifecycleScope.launch(Dispatchers.IO) {
                val result = try {
                    withTimeout(10000L) {
                        runInterruptible(Dispatchers.IO) {
                            githubHelper.fetchFile()
                        }
                    }
                } catch (e: TimeoutCancellationException) {
                    Result.failure(Exception("请求超时（20秒），请检查网络是否可访问 GitHub"))
                } catch (e: Exception) {
                    Result.failure(e)
                }
                withContext(Dispatchers.Main) {
                    btnEdit.isEnabled = true
                    btnSave.isEnabled = true
                    result.onSuccess { content ->
                        etContent.setText(content)
                        etContent.isEnabled = true
                        tvStatus.text = this@MainActivity.getString(R.string.github_fetch_success, content.length)
                        Toast.makeText(this@MainActivity, R.string.github_fetch_success_toast, Toast.LENGTH_SHORT).show()
                    }.onFailure { e ->
                        tvStatus.text = this@MainActivity.getString(R.string.github_fetch_failed, e.message ?: "")
                        Toast.makeText(this@MainActivity, this@MainActivity.getString(R.string.github_fetch_failed, e.message ?: ""), Toast.LENGTH_LONG).show()
                    }
                }
            }
        }

        btnSave.setOnClickListener {
            Logger.d("GitHub: save button clicked")
            if (!githubHelper.hasSettings()) {
                Toast.makeText(this, R.string.github_need_settings, Toast.LENGTH_SHORT).show()
                showGithubSettingsDialog()
                return@setOnClickListener
            }
            val content = etContent.text.toString()
            if (content.isBlank()) {
                Toast.makeText(this, R.string.github_empty_content, Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            tvStatus.text = getString(R.string.github_saving)
            btnEdit.isEnabled = false
            btnSave.isEnabled = false
            lifecycleScope.launch(Dispatchers.IO) {
                val result = try {
                    withTimeout(15000L) {
                        runInterruptible(Dispatchers.IO) {
                            githubHelper.saveFile(content)
                        }
                    }
                } catch (e: TimeoutCancellationException) {
                    Result.failure(Exception("保存超时（30秒），请检查网络是否可访问 GitHub"))
                } catch (e: Exception) {
                    Result.failure(e)
                }
                withContext(Dispatchers.Main) {
                    btnEdit.isEnabled = true
                    btnSave.isEnabled = true
                    result.onSuccess {
                        tvStatus.text = this@MainActivity.getString(R.string.github_save_success)
                        Toast.makeText(this@MainActivity, R.string.github_save_success_toast, Toast.LENGTH_SHORT).show()
                    }.onFailure { e ->
                        tvStatus.text = this@MainActivity.getString(R.string.github_save_failed, e.message ?: "")
                        Toast.makeText(this@MainActivity, this@MainActivity.getString(R.string.github_save_failed, e.message ?: ""), Toast.LENGTH_LONG).show()
                    }
                }
            }
        }

        btnSettings.setOnClickListener {
            Logger.d("GitHub: settings button clicked")
            showGithubSettingsDialog()
        }
    }

    private fun showGithubSettingsDialog() {
        val dialogView = layoutInflater.inflate(R.layout.dialog_github_settings, null)
        val etRepoUrl = dialogView.findViewById<EditText>(R.id.etRepoUrl)
        val etToken = dialogView.findViewById<EditText>(R.id.etToken)
        val etFilePath = dialogView.findViewById<EditText>(R.id.etFilePath)
        val githubHelper = GitHubHelper(this)

        etRepoUrl.setText(githubHelper.getRepoUrl())
        etToken.setText(githubHelper.getToken())
        etFilePath.setText(githubHelper.getFilePath())

        AlertDialog.Builder(this)
            .setTitle(R.string.github_settings_title)
            .setView(dialogView)
            .setPositiveButton(R.string.github_save_settings) { _, _ ->
                val repoUrl = etRepoUrl.text.toString().trim()
                val token = etToken.text.toString().trim()
                val filePath = etFilePath.text.toString().trim()
                githubHelper.saveSettings(repoUrl, token, filePath)
                Toast.makeText(this, R.string.github_settings_saved, Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.toolbar_menu, menu)
        // 「⋮」图标配置期是白色（配紫色顶栏）；鸿蒙风是白底栏 ⇒ 这里按皮肤文字色染色。
        // 菜单可能在 applySkin() 之后才创建（invalidateOptionsMenu 会重走本方法），两处都要设。
        menu.findItem(R.id.action_settings)?.icon?.mutate()?.setTintList(
            ColorStateList.valueOf(SkinStore.palette(this).barText)
        )
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        return when (item.itemId) {
            R.id.action_settings -> {
                showOverflowMenu()
                true
            }
            else -> super.onOptionsItemSelected(item)
        }
    }

    /** 工具栏“三个点”按钮：点击弹出下拉菜单（日志 / 关于） */
    private fun showOverflowMenu() {
        Logger.d("Overflow menu: more button clicked")
        val anchor = binding.toolbar.findViewById<View>(R.id.action_settings) ?: binding.toolbar
        val popup = PopupMenu(this, anchor)
        popup.menuInflater.inflate(R.menu.settings_menu, popup.menu)
        // 菜单项直接带上当前皮肤名，省得进弹框才知道现在是哪套
        popup.menu.findItem(R.id.action_skin)?.title =
            getString(R.string.settings_skin) + "：" + SkinStore.displayName(this, SkinStore.get(this))
        popup.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                R.id.action_log_settings -> {
                    showLogSettingsDialog()
                    true
                }
                R.id.action_skin -> {
                    showSkinDialog()
                    true
                }
                R.id.action_ime_settings -> {
                    showImeSettingsDialog()
                    true
                }
                R.id.action_bind_app -> {
                    showBindAppDialog()
                    true
                }
                R.id.action_overlay_permission -> {
                    showOverlayPermissionDialog()
                    true
                }
                R.id.action_reminder_settings -> {
                    showReminderSettingsDialog()
                    true
                }
                R.id.action_recycle_bin_settings -> {
                    showRecycleBinSettingsDialog()
                    true
                }
                R.id.action_keep_alive -> {
                    showKeepAliveDialog()
                    true
                }
                R.id.action_about -> {
                    showAboutDialog()
                    true
                }
                else -> false
            }
        }
        popup.show()
    }

    /**
     * 把当前皮肤应用到主界面（工具栏 / 标签页 / 页面底色 / 状态条 / 列表 / 按钮）。
     * 配色一律从 [SkinStore] 取，别在别处硬编码：切皮肤走 [showSkinDialog] → recreate()，
     * 这里会跟着新皮肤再跑一遍；输入法面板那边见 ClipboardInputMethodService.applySkin()。
     */
    private fun applySkin() {
        val p = SkinStore.palette(this)
        Logger.d("applySkin: ${SkinStore.get(this)}")

        // 页面底色
        binding.root.setBackgroundColor(p.pageBg)
        binding.layoutClipboard.setBackgroundColor(p.pageBg)
        binding.recyclerView.setBackgroundColor(p.pageBg)
        binding.tvEmpty.setTextColor(p.textSecondary)

        // 顶栏 + 标签页
        binding.toolbar.setBackgroundColor(p.barBg)
        binding.toolbar.setTitleTextColor(p.barText)
        binding.toolbar.setSubtitleTextColor(p.barTextDim)
        // 「⋮」设置按钮：图标原图是白色（当年配紫色顶栏），鸿蒙风是白底栏 ⇒ 白色图标等于隐形，
        // 这里按皮肤文字色给菜单图标染色（mutate 避免污染 drawable 的共享状态）
        binding.toolbar.menu.findItem(R.id.action_settings)?.icon?.let { icon ->
            icon.mutate().setTintList(ColorStateList.valueOf(p.barText))
        }
        binding.tabLayout.setBackgroundColor(p.barBg)
        binding.tabLayout.setSelectedTabIndicatorColor(p.tabIndicator)
        binding.tabLayout.setTabTextColors(p.barTextDim, p.barText)

        // 剪贴板页按钮：MaterialButton 默认文字色取主题 colorPrimary，不跟着皮肤走 ⇒ 显式指定
        binding.btnSelectAll.setTextColor(p.accent)
        binding.btnDeselectAll.setTextColor(p.textSecondary)
        binding.btnMerge.backgroundTintList = ColorStateList.valueOf(p.accent)
        binding.btnMerge.setTextColor(0xFFFFFFFF.toInt())
        binding.btnClear.setTextColor(p.danger)

        // 回收站页按钮与底色
        val recycleRoot = binding.layoutRecycleBin.root
        recycleRoot.setBackgroundColor(p.pageBg)
        recycleRoot.findViewById<RecyclerView>(R.id.rvRecycleBin).setBackgroundColor(p.pageBg)
        recycleRoot.findViewById<android.widget.TextView>(R.id.tvRecycleEmpty).setTextColor(p.textSecondary)
        recycleRoot.findViewById<View>(R.id.btnRecycleSelectAll).let { (it as android.widget.TextView).setTextColor(p.accent) }
        recycleRoot.findViewById<View>(R.id.btnRecycleDeselectAll).let { (it as android.widget.TextView).setTextColor(p.textSecondary) }
        recycleRoot.findViewById<View>(R.id.btnRecycleRestoreSelected).let { btn ->
            (btn as com.google.android.material.button.MaterialButton).backgroundTintList = ColorStateList.valueOf(p.accent)
            btn.setTextColor(0xFFFFFFFF.toInt())
        }
        recycleRoot.findViewById<View>(R.id.btnRecycleRestoreAll).let { (it as android.widget.TextView).setTextColor(p.accent) }
        recycleRoot.findViewById<View>(R.id.btnRecycleRestoreRecent).let { (it as android.widget.TextView).setTextColor(p.accent) }
        recycleRoot.findViewById<View>(R.id.btnRecycleRestoreBatch).let { (it as android.widget.TextView).setTextColor(p.accent) }
        recycleRoot.findViewById<View>(R.id.btnRecycleClear).let { (it as android.widget.TextView).setTextColor(p.danger) }
        if (::recycleAdapter.isInitialized) {
            recycleAdapter.notifyDataSetChanged()
        }
    }

    /** 「皮肤」：两套皮肤单选（App 与输入法键盘共用同一份设置，见 SkinStore） */
    private fun showSkinDialog() {
        val ids = arrayOf(SKIN_HARMONY, SKIN_ANDROID)
        val labels = arrayOf(getString(R.string.skin_harmony), getString(R.string.skin_android))
        val currentId = SkinStore.get(this)
        Logger.d("Skin dialog: opened, current=$currentId")

        val dialogView = layoutInflater.inflate(R.layout.dialog_skin, null)
        val listView = dialogView.findViewById<ListView>(R.id.listSkin)
        val tvCurrent = dialogView.findViewById<TextView>(R.id.tvSkinCurrent)

        listView.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_single_choice, labels)
        val currentIndex = ids.indexOf(currentId).coerceAtLeast(0)
        listView.setItemChecked(currentIndex, true)
        listView.setSelection(currentIndex)
        tvCurrent.text = getString(R.string.skin_current, SkinStore.displayName(this, currentId))

        AlertDialog.Builder(this)
            .setTitle(R.string.skin_title)
            .setView(dialogView)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val position = listView.checkedItemPosition
                Logger.d("Skin dialog: OK clicked, position=$position")
                if (position < 0 || position >= ids.size) {
                    Logger.w("Skin dialog: invalid position=$position, no change")
                    return@setPositiveButton
                }
                val picked = ids[position]
                if (picked == currentId) {
                    Logger.d("Skin dialog: same skin [$picked], no change")
                    return@setPositiveButton
                }
                SkinStore.set(this, picked)
                Toast.makeText(
                    this,
                    getString(R.string.skin_switched, SkinStore.displayName(this, picked)),
                    Toast.LENGTH_SHORT
                ).show()
                // recreate：让所有已 inflate 的布局按新皮肤重建（配色只在 applySkin 里设）
                recreate()
            }
            .setNegativeButton(android.R.string.cancel) { _, _ ->
                Logger.d("Skin dialog: cancelled, no change")
            }
            .show()
    }

    private fun showLogSettingsDialog() {
        Logger.d("Log settings dialog: opened")
        val dialogView = layoutInflater.inflate(R.layout.dialog_settings, null)
        val switchLogOutput = dialogView.findViewById<SwitchCompat>(R.id.switchLogOutput)
        val tvLogPath = dialogView.findViewById<TextView>(R.id.tvLogPath)

        switchLogOutput.isChecked = Logger.isEnabled()
        tvLogPath.text = logPathText()

        // 拨动即生效并持久化：不依赖“确定”按钮，进程重启后依然是这个值
        switchLogOutput.setOnCheckedChangeListener { _, isChecked ->
            Logger.setEnabled(this, isChecked)
            tvLogPath.text = logPathText()
            Logger.d("Log settings dialog: log output changed to $isChecked")
            Toast.makeText(
                this,
                if (isChecked) R.string.settings_log_on else R.string.settings_log_off,
                Toast.LENGTH_SHORT
            ).show()
        }

        AlertDialog.Builder(this)
            .setTitle(R.string.settings_log_title)
            .setView(dialogView)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    /** 后台保活说明：华为「一键清理」会连本应用一起杀，这里给出系统侧该开/该设的东西 */
    private fun showKeepAliveDialog() {
        Logger.d("Keep alive dialog: opened")
        val ignoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }
        val message = getString(R.string.keep_alive_message) + "\n\n" + getString(
            R.string.keep_alive_status,
            getString(if (ignoring) R.string.keep_alive_yes else R.string.keep_alive_no)
        )
        AlertDialog.Builder(this)
            .setTitle(R.string.keep_alive_title)
            .setMessage(message)
            .setPositiveButton(R.string.keep_alive_open_app_settings) { _, _ -> openAppDetailsSettings() }
            .setNeutralButton(R.string.keep_alive_ignore_battery) { _, _ -> requestIgnoreBatteryOptimization() }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /** 打开系统「应用信息」页：华为在这里设 应用启动管理（自启动 / 关联启动 / 后台活动） */
    private fun openAppDetailsSettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
            )
            Logger.d("Keep alive: app details settings opened")
        } catch (e: Exception) {
            Logger.e("Keep alive: open app details failed: ${e.message}", e)
        }
    }

    /** 申请「忽略电池优化」：Android 12+ 起这也顺带放开了“后台启动前台服务”的限制 */
    private fun requestIgnoreBatteryOptimization() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(packageName)) {
            Toast.makeText(this, R.string.keep_alive_already_ignored, Toast.LENGTH_SHORT).show()
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
            Logger.d("Keep alive: request ignore battery optimizations")
        } catch (e: Exception) {
            Logger.e("Keep alive: request ignore battery failed: ${e.message}", e)
            openAppDetailsSettings()
        }
    }

    /** 「提醒设置」：悬浮提醒 / 后台监听服务（通知栏常驻通知）两个开关，拨动即生效并持久化 */
    private fun showReminderSettingsDialog() {
        Logger.d("Reminder settings dialog: opened")
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val dialogView = layoutInflater.inflate(R.layout.dialog_reminder_settings, null)
        val switchReminder = dialogView.findViewById<SwitchCompat>(R.id.switchReminderEnabled)
        val switchService = dialogView.findViewById<SwitchCompat>(R.id.switchBackgroundService)

        switchReminder.isChecked = prefs.getBoolean(KEY_REMINDER_ENABLED, true)
        switchService.isChecked = prefs.getBoolean(KEY_BACKGROUND_SERVICE_ENABLED, true)

        // 拨动即生效并持久化：不依赖“确定”按钮，进程重启后依然生效
        switchReminder.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean(KEY_REMINDER_ENABLED, isChecked).apply()
            Logger.d("Reminder settings: reminder enabled=$isChecked")
            if (!isChecked) {
                BindAppBubble.hide()
                try {
                    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                        .cancel(ClipboardService.BIND_NOTIFICATION_ID)
                } catch (e: Exception) {
                    Logger.w("Reminder settings: cancel reminder notification failed: ${e.message}")
                }
            }
            Toast.makeText(
                this,
                if (isChecked) R.string.reminder_on else R.string.reminder_off,
                Toast.LENGTH_SHORT
            ).show()
        }

        val switchHideNotification = dialogView.findViewById<SwitchCompat>(R.id.switchHidePersistentNotification)
        switchHideNotification.isChecked = prefs.getBoolean(KEY_HIDE_PERSISTENT_NOTIFICATION, false)
        switchHideNotification.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean(KEY_HIDE_PERSISTENT_NOTIFICATION, isChecked).apply()
            Logger.d("Reminder settings: hide persistent notification=$isChecked")
            // 渠道属性不可变 ⇒ 改这条要重启服务来重建渠道与常驻通知（仅当后台服务是开着的时候）
            if (prefs.getBoolean(KEY_BACKGROUND_SERVICE_ENABLED, true)) {
                stopService(Intent(this, ClipboardService::class.java))
                startClipboardService()
            }
            Toast.makeText(
                this,
                if (isChecked) R.string.hide_notification_on else R.string.hide_notification_off,
                Toast.LENGTH_SHORT
            ).show()
        }

        switchService.setOnCheckedChangeListener { _, isChecked ->
            prefs.edit().putBoolean(KEY_BACKGROUND_SERVICE_ENABLED, isChecked).apply()
            Logger.d("Reminder settings: background service enabled=$isChecked")
            if (isChecked) {
                startClipboardService()
            } else {
                stopService(Intent(this, ClipboardService::class.java))
                BindAppBubble.hide()
            }
            Toast.makeText(
                this,
                if (isChecked) R.string.background_service_on else R.string.background_service_off,
                Toast.LENGTH_SHORT
            ).show()
        }

        AlertDialog.Builder(this)
            .setTitle(R.string.reminder_settings_title)
            .setView(dialogView)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    /** 「回收站设置」：选择回收站保留数据的最大天数，过期自动清理 */
    private fun showRecycleBinSettingsDialog() {
        Logger.d("Recycle bin settings dialog: opened")
        val daysOptions = intArrayOf(7, 15, 30, 90, RecycleBinRepository.RETENTION_FOREVER)
        val labels = arrayOf(
            getString(R.string.recycle_retention_7_days),
            getString(R.string.recycle_retention_15_days),
            getString(R.string.recycle_retention_30_days),
            getString(R.string.recycle_retention_90_days),
            getString(R.string.recycle_retention_forever)
        )
        val current = RecycleBinRepository.getRetentionDays(this)
        val currentIndex = daysOptions.indexOf(current).let { if (it < 0) 2 else it }

        var selectedIndex = currentIndex
        AlertDialog.Builder(this)
            .setTitle(R.string.recycle_settings_title)
            .setSingleChoiceItems(labels, currentIndex) { _, which ->
                selectedIndex = which
            }
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val days = daysOptions[selectedIndex]
                RecycleBinRepository.setRetentionDays(this, days)
                val msg = if (days == RecycleBinRepository.RETENTION_FOREVER) {
                    getString(R.string.recycle_retention_forever_toast)
                } else {
                    getString(R.string.recycle_retention_changed_toast, days)
                }
                Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
                Logger.d("Recycle bin settings: retention days set to $days")
                viewModel.reloadRecycleBin()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /** 日志文件路径文案：开关关闭（或文件尚未创建）时标注“当前未创建”——此时不会创建 Download 目录 */
    private fun logPathText(): String {
        val path = Logger.getLogPath()
        val suffix = if (Logger.isLogFileActive()) "" else getString(R.string.log_file_not_created)
        return getString(R.string.settings_log_path, path + suffix)
    }

    private fun showAboutDialog() {
        Logger.d("About dialog: opened")
        val dialogView = layoutInflater.inflate(R.layout.dialog_about, null)
        val unknown = getString(R.string.about_value_unknown)

        dialogView.findViewById<TextView>(R.id.tvAboutVersion).text = getString(
            R.string.about_version_line,
            BuildConfig.VERSION_NAME,
            BuildConfig.VERSION_CODE
        )
        dialogView.findViewById<TextView>(R.id.tvAboutBuildType).text = BuildConfig.BUILD_TYPE
        dialogView.findViewById<TextView>(R.id.tvAboutBuildTime).text =
            BuildConfig.BUILD_TIME.ifBlank { unknown }
        dialogView.findViewById<TextView>(R.id.tvAboutGitCommit).text =
            BuildConfig.GIT_COMMIT.ifBlank { unknown }
        dialogView.findViewById<TextView>(R.id.tvAboutPackage).text = packageName
        dialogView.findViewById<TextView>(R.id.tvAboutEnv).text =
            "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}"
        dialogView.findViewById<TextView>(R.id.tvAboutLogFile).text =
            Logger.getLogPath() + if (Logger.isLogFileActive()) "" else getString(R.string.log_file_not_created)

        AlertDialog.Builder(this)
            .setTitle(R.string.about_title)
            .setView(dialogView)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }

    private fun showImeSettingsDialog() {
        Logger.d("IME settings dialog: opened")
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val enabledImes = imm.enabledInputMethodList
        Logger.d("IME settings dialog: total enabled IMEs count=${enabledImes.size}")

        val imeLabels = mutableListOf<String>()
        val imeIds = mutableListOf<String>()

        imeLabels.add(getString(R.string.ime_settings_none))
        imeIds.add("")

        for (ime in enabledImes) {
            val label = ime.loadLabel(packageManager).toString()
            val id = ime.id
            Logger.d("IME settings dialog: ime id=[$id], label=[$label]")
            if (id == "$packageName/${ClipboardInputMethodService::class.java.simpleName}") {
                Logger.d("IME settings dialog: skip self ime id=[$id]")
                continue
            }
            imeLabels.add(label)
            imeIds.add(id)
        }
        Logger.d("IME settings dialog: candidate IMEs count=${imeLabels.size - 1}")
        if (imeLabels.size <= 1) {
            Logger.w("IME settings dialog: no other IMEs enabled, only default option available")
        }

        val dialogView = layoutInflater.inflate(R.layout.dialog_ime_settings, null)
        val listView = dialogView.findViewById<ListView>(R.id.listIme)

        val adapter = ArrayAdapter(this, android.R.layout.simple_list_item_single_choice, imeLabels)
        listView.adapter = adapter

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val savedImeId = prefs.getString(KEY_TARGET_IME, "") ?: ""
        val savedIndex = imeIds.indexOf(savedImeId).coerceAtLeast(0)
        Logger.d("IME settings dialog: restored savedImeId=[$savedImeId], index=$savedIndex")
        listView.setItemChecked(savedIndex, true)
        listView.setSelection(savedIndex)

        AlertDialog.Builder(this)
            .setTitle(R.string.ime_settings_title)
            .setView(dialogView)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val selectedPosition = listView.checkedItemPosition
                Logger.d("IME settings dialog: OK clicked, checkedItemPosition=$selectedPosition")
                if (selectedPosition >= 0 && selectedPosition < imeIds.size) {
                    val selectedImeId = imeIds[selectedPosition]
                    val selectedLabel = imeLabels[selectedPosition]
                    prefs.edit().putString(KEY_TARGET_IME, selectedImeId).apply()
                    Logger.d("IME settings dialog: saved imeId=[$selectedImeId], label=[$selectedLabel]")
                    Toast.makeText(this, R.string.ime_settings_saved, Toast.LENGTH_SHORT).show()
                } else {
                    Logger.w("IME settings dialog: invalid selectedPosition=$selectedPosition, no save")
                }
            }
            .setNegativeButton(android.R.string.cancel) { _, _ ->
                Logger.d("IME settings dialog: cancelled, no changes saved")
            }
            .show()

        listView.onItemClickListener = AdapterView.OnItemClickListener { _, _, position, _ ->
            Logger.d("IME settings dialog: list item clicked position=$position, label=[${imeLabels[position]}]")
            listView.setItemChecked(position, true)
        }
    }

    private fun setupBindAppStatus() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val label = prefs.getString(KEY_BOUND_APP_LABEL, "")
        val tv = binding.tvBindAppStatus
        val p = SkinStore.palette(this)
        tv.setBackgroundColor(p.bindBg)
        tv.setTextColor(p.bindFg)
        if (!label.isNullOrBlank()) {
            tv.text = getString(R.string.bind_app_status_bound, label)
            tv.visibility = View.VISIBLE
        } else {
            tv.text = getString(R.string.bind_app_status_none)
            tv.visibility = View.GONE
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

    private fun requestUsageStatsPermission() {
        Logger.d("BindApp: requesting usage stats permission")
        AlertDialog.Builder(this)
            .setTitle(R.string.bind_app_permission_required)
            .setMessage("需要「使用情况访问权限」才能检测前台应用。\n\n请在接下来的设置页面中找到「剪集」并开启权限。")
            .setPositiveButton("去授权") { _, _ ->
                val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                startActivity(intent)
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun showBindAppDialog() {
        Logger.d("BindApp dialog: opened")
        if (!isUsageStatsPermissionGranted()) {
            Logger.d("BindApp dialog: usage stats permission not granted, requesting")
            requestUsageStatsPermission()
            return
        }

        val pm = packageManager
        val mainIntent = Intent(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_LAUNCHER) }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PackageManager.MATCH_ALL
        } else {
            0
        }
        val activities = pm.queryIntentActivities(mainIntent, flags)
        val appEntries = activities
            .map { it.activityInfo }
            .distinctBy { it.packageName }
            .sortedBy { it.loadLabel(pm).toString().lowercase() }

        // 第 0 条固定是「不绑定（关闭）」；searchKey = 应用名 + 包名（均小写），供搜索框过滤
        val allLabels = mutableListOf<String>()
        val allPackages = mutableListOf<String>()
        val allSearchKeys = mutableListOf<String>()
        allLabels.add(getString(R.string.bind_app_none))
        allPackages.add("")
        allSearchKeys.add("")
        for (info in appEntries) {
            if (info.packageName == packageName) continue
            val label = info.loadLabel(pm).toString()
            allLabels.add(label)
            allPackages.add(info.packageName)
            allSearchKeys.add("$label ${info.packageName}".lowercase())
        }
        Logger.d("BindApp dialog: found ${appEntries.size} launchable apps, selectable=${allLabels.size - 1}")

        val dialogView = layoutInflater.inflate(R.layout.dialog_bind_app, null)
        val listView = dialogView.findViewById<ListView>(R.id.listBindApp)
        val searchBox = dialogView.findViewById<EditText>(R.id.etBindAppSearch)

        val shownLabels = mutableListOf<String>()
        val shownPackages = mutableListOf<String>()
        val adapter = ArrayAdapter(this, android.R.layout.simple_list_item_single_choice, shownLabels)
        listView.adapter = adapter

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val savedPackage = prefs.getString(KEY_BOUND_APP_PACKAGE, "") ?: ""
        var pendingPackage = savedPackage

        /** 按关键字重建列表（应用名 / 包名都匹配；「不绑定（关闭）」始终保留） */
        fun applyFilter(keyword: String) {
            val kw = keyword.trim().lowercase()
            shownLabels.clear()
            shownPackages.clear()
            for (i in allLabels.indices) {
                if (i == 0 || kw.isEmpty() || allSearchKeys[i].contains(kw)) {
                    shownLabels.add(allLabels[i])
                    shownPackages.add(allPackages[i])
                }
            }
            adapter.notifyDataSetChanged()
            val index = shownPackages.indexOf(pendingPackage).coerceAtLeast(0)
            listView.setItemChecked(index, true)
            listView.setSelection(index)
            Logger.d("BindApp dialog: filter=[$kw], shown=${shownLabels.size}, checked=$index")
        }
        applyFilter("")

        searchBox.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                applyFilter(s?.toString().orEmpty())
            }
        })

        AlertDialog.Builder(this)
            .setTitle(R.string.bind_app_title)
            .setView(dialogView)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val selectedPosition = listView.checkedItemPosition
                Logger.d("BindApp dialog: OK clicked, checkedItemPosition=$selectedPosition")
                if (selectedPosition >= 0 && selectedPosition < shownPackages.size) {
                    val selectedPackage = shownPackages[selectedPosition]
                    val selectedLabel = shownLabels[selectedPosition]
                    prefs.edit()
                        .putString(KEY_BOUND_APP_PACKAGE, selectedPackage)
                        .putString(KEY_BOUND_APP_LABEL, selectedLabel)
                        .apply()
                    Logger.d("BindApp dialog: saved package=[$selectedPackage], label=[$selectedLabel]")
                    setupBindAppStatus()
                    Toast.makeText(this, R.string.bind_app_saved, Toast.LENGTH_SHORT).show()
                    if (selectedPackage.isNotEmpty()) ensureOverlayPermission()
                } else {
                    Logger.w("BindApp dialog: invalid selectedPosition=$selectedPosition, no save")
                }
            }
            .setNegativeButton(android.R.string.cancel) { _, _ ->
                Logger.d("BindApp dialog: cancelled, no changes saved")
            }
            .show()

        listView.onItemClickListener = AdapterView.OnItemClickListener { _, _, position, _ ->
            val label = if (position < shownLabels.size) shownLabels[position] else "?"
            Logger.d("BindApp dialog: list item clicked position=$position, label=[$label]")
            listView.setItemChecked(position, true)
            if (position < shownPackages.size) pendingPackage = shownPackages[position]
        }
    }

    /** 「悬浮提醒权限」入口（更多菜单）：显示当前状态 + 跳系统授权页 */
    private fun showOverlayPermissionDialog() {
        val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
        Logger.d("Overlay permission dialog: opened, granted=$granted")
        val builder = AlertDialog.Builder(this)
            .setTitle(R.string.overlay_permission_title)
            .setMessage(
                if (granted) getString(R.string.overlay_permission_granted)
                else getString(R.string.overlay_permission_missing)
            )
            .setNegativeButton(android.R.string.cancel, null)
        if (granted) {
            builder.setPositiveButton(android.R.string.ok, null)
        } else {
            builder.setPositiveButton(R.string.bind_app_overlay_grant) { _, _ -> openOverlayPermissionPage() }
        }
        builder.show()
    }

    /** 打开系统的「显示在其他应用上层」授权页 */
    private fun openOverlayPermissionPage() {
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
            )
            Logger.d("BindApp: ACTION_MANAGE_OVERLAY_PERMISSION launched")
        } catch (e: Exception) {
            Logger.e("BindApp: failed to open overlay permission page: ${e.message}", e)
        }
    }

    private fun ensureOverlayPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (Settings.canDrawOverlays(this)) {
            Logger.d("BindApp: overlay permission already granted")
            return
        }
        Logger.d("BindApp: overlay permission NOT granted, prompting user")
        AlertDialog.Builder(this)
            .setTitle(R.string.bind_app_overlay_title)
            .setMessage(R.string.bind_app_overlay_message)
            .setPositiveButton(R.string.bind_app_overlay_grant) { _, _ ->
                try {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                    )
                    Logger.d("BindApp: ACTION_MANAGE_OVERLAY_PERMISSION launched")
                } catch (e: Exception) {
                    Logger.e("BindApp: failed to open overlay permission page: ${e.message}", e)
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    companion object {
        const val PREFS_NAME = "clipboard_merger_settings"
        const val KEY_TARGET_IME = "target_ime_id"
        const val KEY_BOUND_APP_PACKAGE = "bound_app_package"
        const val KEY_BOUND_APP_LABEL = "bound_app_label"

        /** 悬浮提醒（气泡 + 振动 + 提醒通知）总开关 */
        const val KEY_REMINDER_ENABLED = "bind_app_reminder_enabled"

        /** 后台监听服务开关（前台服务常驻通知随之显示/消失） */
        const val KEY_BACKGROUND_SERVICE_ENABLED = "background_service_enabled"

        /** 隐藏常驻通知（后台服务继续跑，只是不再显示那条通知） */
        const val KEY_HIDE_PERSISTENT_NOTIFICATION = "hide_persistent_notification"
    }
}