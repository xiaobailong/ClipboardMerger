package com.example.clipboardmerger

import android.Manifest
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModelProvider
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.clipboardmerger.databinding.ActivityMainBinding

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

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        Logger.d("Notification permission result: granted=$granted")
        if (granted) {
            startClipboardService()
        } else {
            Logger.w("Notification permission denied")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Logger.init(this)
        Logger.d("========== onCreate ==========")
        Logger.d("SDK_INT=${Build.VERSION.SDK_INT}, MANUFACTURER=${Build.MANUFACTURER}, MODEL=${Build.MODEL}")
        Logger.d("Log file path: ${Logger.getLogPath()}")

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

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
        setupAccessibilityStatus()
        requestNotificationPermission()

        viewModel.reloadFromRepository()
        readCurrentClipboard()
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
        setupAccessibilityStatus()
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
            readCurrentClipboard()
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
                if (list.isEmpty()) android.view.View.VISIBLE else android.view.View.GONE
            binding.recyclerView.visibility =
                if (list.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE
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

    private fun requestNotificationPermission() {
        Logger.d("requestNotificationPermission: SDK_INT=${Build.VERSION.SDK_INT}")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val hasPermission = ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            Logger.d("requestNotificationPermission: hasPermission=$hasPermission")
            if (!hasPermission) {
                Logger.d("requestNotificationPermission: launching permission request")
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                Logger.d("requestNotificationPermission: already granted, starting service")
                startClipboardService()
            }
        } else {
            Logger.d("requestNotificationPermission: SDK < TIRAMISU, starting service directly")
            startClipboardService()
        }
    }

    private fun startClipboardService() {
        Logger.d("startClipboardService: start")
        val intent = Intent(this, ClipboardService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
            Logger.d("startClipboardService: started as foreground service")
        } else {
            startService(intent)
            Logger.d("startClipboardService: started as regular service")
        }
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

    private fun setupAccessibilityStatus() {
        val enabled = isAccessibilityServiceEnabled()
        Logger.d("setupAccessibilityStatus: enabled=$enabled")
        if (enabled) {
            binding.tvAccessibilityStatus.text = getString(R.string.accessibility_status_enabled)
            binding.tvAccessibilityStatus.setBackgroundColor(0xFFE8F5E9.toInt())
            binding.tvAccessibilityStatus.setTextColor(0xFF2E7D32.toInt())
        } else {
            binding.tvAccessibilityStatus.text = getString(R.string.accessibility_status_disabled)
            binding.tvAccessibilityStatus.setBackgroundColor(0xFFFFF3E0.toInt())
            binding.tvAccessibilityStatus.setTextColor(0xFFE65100.toInt())
        }
        binding.tvAccessibilityStatus.visibility = android.view.View.VISIBLE
        binding.tvAccessibilityStatus.setOnClickListener {
            Logger.d("Accessibility status clicked, opening settings")
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            startActivity(intent)
            Toast.makeText(this, "Find \"ClipboardMerger\" and enable it", Toast.LENGTH_LONG).show()
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val serviceName = "$packageName/.ClipboardAccessibilityService"
        val enabledServices = try {
            Settings.Secure.getString(
                contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: ""
        } catch (e: Exception) {
            Logger.w("isAccessibilityServiceEnabled: read settings failed: ${e.message}")
            ""
        }
        return enabledServices.contains(serviceName) || enabledServices.contains(packageName + "/" + packageName + ".ClipboardAccessibilityService")
    }
}