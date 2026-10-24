package com.example.clipboardmerger

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

object RecycleBinRepository {

    private const val PREFS_NAME = "clipboard_recycle_bin"
    private const val KEY_ITEMS = "items"
    private const val MAX_ITEMS = 5000

    private fun getPrefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
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
        Logger.d("RecycleBinRepository.loadItems: loaded ${list.size} items")
        return list
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

    fun moveToRecycleBin(context: Context, items: List<ClipboardItem>, source: String): String {
        if (items.isEmpty()) {
            Logger.d("RecycleBinRepository.moveToRecycleBin: empty list, skip")
            return ""
        }
        val batchId = generateBatchId()
        val now = System.currentTimeMillis()
        Logger.d("RecycleBinRepository.moveToRecycleBin: batchId=$batchId, count=${items.size}, source=$source")
        val existing = loadItems(context)
        val addedIds = HashSet<Long>()
        items.forEach { item ->
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
        }
        saveItems(context, existing)
        Logger.d("RecycleBinRepository.moveToRecycleBin: done, total=${existing.size}")
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