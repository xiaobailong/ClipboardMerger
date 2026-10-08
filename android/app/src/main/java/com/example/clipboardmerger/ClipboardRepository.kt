package com.example.clipboardmerger

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

object ClipboardRepository {

    private const val PREFS_NAME = "clipboard_history"
    private const val KEY_ITEMS = "items"
    private const val MAX_ITEMS = 5000

    private fun getPrefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun loadItems(context: Context): MutableList<ClipboardItem> {
        Logger.d("ClipboardRepository.loadItems: start")
        val json = getPrefs(context).getString(KEY_ITEMS, null)
        if (json == null) {
            Logger.d("ClipboardRepository.loadItems: no saved data, return empty list")
            return mutableListOf()
        }
        val arr = JSONArray(json)
        val list = mutableListOf<ClipboardItem>()
        for (i in 0 until arr.length()) {
            try {
                val obj = arr.getJSONObject(i)
                list.add(
                    ClipboardItem(
                        id = obj.getLong("id"),
                        content = obj.getString("content"),
                        timestamp = obj.getLong("timestamp"),
                        isSelected = false
                    )
                )
            } catch (e: Exception) {
                Logger.w("ClipboardRepository.loadItems: parse error at index $i: ${e.message}")
            }
        }
        Logger.d("ClipboardRepository.loadItems: loaded ${list.size} items")
        return list
    }

    fun saveItems(context: Context, items: List<ClipboardItem>) {
        Logger.d("ClipboardRepository.saveItems: saving ${items.size} items")
        val arr = JSONArray()
        val limit = items.size.coerceAtMost(MAX_ITEMS)
        for (i in 0 until limit) {
            val item = items[i]
            arr.put(
                JSONObject().apply {
                    put("id", item.id)
                    put("content", item.content)
                    put("timestamp", item.timestamp)
                }
            )
        }
        getPrefs(context).edit().putString(KEY_ITEMS, arr.toString()).apply()
        Logger.d("ClipboardRepository.saveItems: saved ${arr.length()} items to storage")
    }

    fun addItem(context: Context, content: String) {
        if (content.isBlank()) {
            Logger.d("ClipboardRepository.addItem: skip (blank content)")
            return
        }
        Logger.d("ClipboardRepository.addItem: content length=${content.length}")
        val items = loadItems(context)
        if (items.isNotEmpty() && items[0].content == content) {
            Logger.d("ClipboardRepository.addItem: skip (duplicate with latest item)")
            return
        }
        items.add(0, ClipboardItem(content = content))
        saveItems(context, items)
        Logger.d("ClipboardRepository.addItem: done, total=${items.size}")
    }

    fun clearAll(context: Context) {
        Logger.d("ClipboardRepository.clearAll")
        getPrefs(context).edit().putString(KEY_ITEMS, JSONArray().toString()).apply()
        Logger.d("ClipboardRepository.clearAll: done")
    }
}