package com.example.clipboardmerger

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

object RecycleBinRepository {

    private const val PREFS_NAME = "clipboard_recycle_bin"
    private const val KEY_ITEMS = "items"
    private const val MAX_ITEMS = 5000

    /** 回收站保留天数设置项（存放在主设置 SharedPreferences 中） */
    private const val SETTINGS_PREFS = "clipboard_merger_settings"
    private const val KEY_RETENTION_DAYS = "recycle_bin_retention_days"
    private const val DEFAULT_RETENTION_DAYS = 30
    /** -1 表示永久保留 */
    const val RETENTION_FOREVER = -1

    private fun getPrefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun getRetentionDays(context: Context): Int {
        val prefs = context.getSharedPreferences(SETTINGS_PREFS, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_RETENTION_DAYS, DEFAULT_RETENTION_DAYS)
    }

    fun setRetentionDays(context: Context, days: Int) {
        val prefs = context.getSharedPreferences(SETTINGS_PREFS, Context.MODE_PRIVATE)
        prefs.edit().putInt(KEY_RETENTION_DAYS, days).apply()
        Logger.d("RecycleBinRepository.setRetentionDays: days=$days")
    }

    fun loadItems(context: Context): MutableList<RecyclerItem> {
        Logger.d("RecycleBinRepository.loadItems: start")
        val json = getPrefs(context).getString(KEY_ITEMS, null)
        if (json == null) {
            Logger.d("RecycleBinRepository.loadItems: no saved data, return empty list")
            return mutableListOf()
        }
        val arr = JSONArray(json)
        val list = mutableListOf<RecyclerItem>()
        for (i in 0 until arr.length()) {
            try {
                val obj = arr.getJSONObject(i)
                list.add(
                    RecyclerItem(
                        id = obj.getLong("id"),
                        content = obj.getString("content"),
                        timestamp = obj.getLong("timestamp"),
                        batchId = obj.getString("batchId"),
                        deletedAt = obj.getLong("deletedAt"),
                        source = obj.optString("source", "app"),
                        isSelected = false
                    )
                )
            } catch (e: Exception) {
                Logger.w("RecycleBinRepository.loadItems: parse error at index $i: ${e.message}")
            }
        }
        val cleaned = purgeExpired(context, list)
        Logger.d("RecycleBinRepository.loadItems: loaded ${cleaned.size} items")
        return cleaned
    }

    /** 清理超过保留天数的项，返回清理后的列表；若有清理会自动持久化 */
    private fun purgeExpired(context: Context, items: MutableList<RecyclerItem>): MutableList<RecyclerItem> {
        val retentionDays = getRetentionDays(context)
        if (retentionDays == RETENTION_FOREVER) {
            return items
        }
        val cutoff = System.currentTimeMillis() - retentionDays * 24L * 60 * 60 * 1000
        val before = items.size
        val kept = items.filterTo(mutableListOf()) { it.deletedAt >= cutoff }
        val removed = before - kept.size
        if (removed > 0) {
            Logger.d("RecycleBinRepository.purgeExpired: removed $removed expired items (retention=$retentionDays days)")
            saveItems(context, kept)
        }
        return kept
    }

    fun saveItems(context: Context, items: List<RecyclerItem>) {
        Logger.d("RecycleBinRepository.saveItems: saving ${items.size} items")
        val arr = JSONArray()
        val limit = items.size.coerceAtMost(MAX_ITEMS)
        for (i in 0 until limit) {
            val item = items[i]
            arr.put(
                JSONObject().apply {
                    put("id", item.id)
                    put("content", item.content)
                    put("timestamp", item.timestamp)
                    put("batchId", item.batchId)
                    put("deletedAt", item.deletedAt)
                    put("source", item.source)
                }
            )
        }
        getPrefs(context).edit().putString(KEY_ITEMS, arr.toString()).apply()
        Logger.d("RecycleBinRepository.saveItems: saved ${arr.length()} items to storage")
    }

    /**
     * 将剪贴板项移入回收站。
     * 去重规则：回收站中已存在相同 content 的项不再重复添加。
     */
    fun moveToRecycleBin(context: Context, items: List<ClipboardItem>, source: String): String {
        if (items.isEmpty()) {
            Logger.d("RecycleBinRepository.moveToRecycleBin: empty list, skip")
            return ""
        }
        val batchId = generateBatchId()
        val now = System.currentTimeMillis()
        Logger.d("RecycleBinRepository.moveToRecycleBin: batchId=$batchId, count=${items.size}, source=$source")
        val existing = loadItems(context)
        val existingContents = existing.map { it.content }.toHashSet()
        val addedIds = HashSet<Long>()
        var addedCount = 0
        items.forEach { item ->
            if (existingContents.contains(item.content)) {
                Logger.d("RecycleBinRepository.moveToRecycleBin: skip duplicate content")
                return@forEach
            }
            existingContents.add(item.content)
            var newId = System.currentTimeMillis() + item.id % 1000
            while (addedIds.contains(newId) || existing.any { it.id == newId }) {
                newId++
            }
            addedIds.add(newId)
            existing.add(
                0, RecyclerItem(
                    id = newId,
                    content = item.content,
                    timestamp = item.timestamp,
                    batchId = batchId,
                    deletedAt = now,
                    source = source
                )
            )
            addedCount++
        }
        saveItems(context, existing)
        Logger.d("RecycleBinRepository.moveToRecycleBin: done, added=$addedCount, total=${existing.size}")
        return batchId
    }

    fun removeItems(context: Context, itemIds: List<Long>) {
        if (itemIds.isEmpty()) return
        Logger.d("RecycleBinRepository.removeItems: removing ${itemIds.size} items")
        val idSet = itemIds.toSet()
        val existing = loadItems(context)
        existing.removeAll { it.id in idSet }
        saveItems(context, existing)
    }

    fun removeBatch(context: Context, batchId: String) {
        Logger.d("RecycleBinRepository.removeBatch: batchId=$batchId")
        val existing = loadItems(context)
        existing.removeAll { it.batchId == batchId }
        saveItems(context, existing)
    }

    fun getBatchIds(context: Context): List<String> {
        val items = loadItems(context)
        return items.map { it.batchId }.distinct().sortedDescending()
    }

    fun getItemsByBatch(context: Context, batchId: String): List<RecyclerItem> {
        return loadItems(context).filter { it.batchId == batchId }
    }

    fun clearAll(context: Context) {
        Logger.d("RecycleBinRepository.clearAll")
        getPrefs(context).edit().putString(KEY_ITEMS, JSONArray().toString()).apply()
        Logger.d("RecycleBinRepository.clearAll: done")
    }
}