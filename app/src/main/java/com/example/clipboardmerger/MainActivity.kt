package com.example.clipboardmerger

import android.app.AlertDialog
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Canvas
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
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
    private var clipboardManager: ClipboardManager? = null
    private var selfUpdating = false
    private val handler = Handler(Looper.getMainLooper())
    private var pendingClipboardRead: Runnable? = null

    private val clipboardUpdateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            Logger.d("BroadcastReceiver: received clipboard update from service")
            viewModel.reloadFromRepository()
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
        observeViewModel()
        registerClipboardListener()
        registerClipboardUpdateReceiver()
        setupIMEStatus()
        startClipboardService()

        viewModel.reloadFromRepository()
        readCurrentClipboard()
        setupTabs()
        setupGitHubButtons()
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
        setupIMEStatus()
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
                val position = viewHolder.adapterPosition
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
        Logger.d("startClipboardService: start")
        val intent = Intent(this, ClipboardService::class.java)
        startService(intent)
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
        if (isDefault) {
            binding.tvAccessibilityStatus.text = getString(R.string.ime_status_active)
            binding.tvAccessibilityStatus.setBackgroundColor(0xFFE8F5E9.toInt())
            binding.tvAccessibilityStatus.setTextColor(0xFF2E7D32.toInt())
        } else {
            binding.tvAccessibilityStatus.text = getString(R.string.ime_status_disabled)
            binding.tvAccessibilityStatus.setBackgroundColor(0xFFFFF3E0.toInt())
            binding.tvAccessibilityStatus.setTextColor(0xFFE65100.toInt())
        }
        binding.tvAccessibilityStatus.visibility = View.VISIBLE
        binding.tvAccessibilityStatus.setOnClickListener {
            Logger.d("IME status clicked, opening input method picker")
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showInputMethodPicker()
            Toast.makeText(this, "Select \"ClipboardMerger\" as your keyboard to enable background clipboard monitoring", Toast.LENGTH_LONG).show()
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
        binding.tabLayout.addTab(binding.tabLayout.newTab().setText(R.string.tab_github))
        binding.tabLayout.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab?) {
                when (tab?.position) {
                    0 -> {
                        binding.layoutClipboard.visibility = View.VISIBLE
                        binding.layoutGithub.root.visibility = View.GONE
                    }
                    1 -> {
                        binding.layoutClipboard.visibility = View.GONE
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
        popup.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                R.id.action_log_settings -> {
                    showLogSettingsDialog()
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

    private fun showLogSettingsDialog() {
        Logger.d("Log settings dialog: opened")
        val dialogView = layoutInflater.inflate(R.layout.dialog_settings, null)
        val switchLogOutput = dialogView.findViewById<SwitchCompat>(R.id.switchLogOutput)
        val tvLogPath = dialogView.findViewById<TextView>(R.id.tvLogPath)

        switchLogOutput.isChecked = Logger.isEnabled()
        tvLogPath.text = getString(R.string.settings_log_path, Logger.getLogPath())

        // 拨动即生效并持久化：不依赖“确定”按钮，进程重启后依然是这个值
        switchLogOutput.setOnCheckedChangeListener { _, isChecked ->
            Logger.setEnabled(this, isChecked)
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
        dialogView.findViewById<TextView>(R.id.tvAboutLogFile).text = Logger.getLogPath()

        AlertDialog.Builder(this)
            .setTitle(R.string.about_title)
            .setView(dialogView)
            .setPositiveButton(android.R.string.ok, null)
            .show()
    }
}