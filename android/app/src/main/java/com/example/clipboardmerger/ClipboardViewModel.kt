package com.example.clipboardmerger

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.MutableLiveData

class ClipboardViewModel(application: Application) : AndroidViewModel(application) {

    val items: MutableLiveData<MutableList<ClipboardItem>> = MutableLiveData(
        ClipboardRepository.loadItems(application)
    )

    val recycleItems: MutableLiveData<MutableList<RecyclerItem>> = MutableLiveData(
        RecycleBinRepository.loadItems(application)
    )

    fun reloadFromRepository() {
        val saved = ClipboardRepository.loadItems(getApplication())
        Logger.d("ViewModel.reloadFromRepository: loading from repository, got ${saved.size} items")
        items.value = saved
    }

    fun reloadRecycleBin() {
        val saved = RecycleBinRepository.loadItems(getApplication())
        Logger.d("ViewModel.reloadRecycleBin: got ${saved.size} items")
        recycleItems.value = saved
    }

    fun addItem(content: String) {
        Logger.d("ViewModel.addItem: content length=${content.length}, blank=${content.isBlank()}")
        if (content.isBlank()) {
            Logger.d("ViewModel.addItem: skip (blank content)")
            return
        }
        val list = items.value ?: mutableListOf()
        if (list.isNotEmpty() && list[0].content == content) {
            Logger.d("ViewModel.addItem: skip (duplicate with latest item)")
            return
        }
        list.add(0, ClipboardItem(content = content))
        items.value = list
        persist()
        Logger.d("ViewModel.addItem: added, total count=${list.size}")
    }

    fun toggleSelection(position: Int) {
        val list = items.value ?: return
        Logger.d("ViewModel.toggleSelection: position=$position, listSize=${list.size}")
        if (position in 0 until list.size) {
            val item = list[position]
            list[position] = item.copy(isSelected = !item.isSelected)
            items.value = list
            Logger.d("ViewModel.toggleSelection: toggled to ${list[position].isSelected}")
        }
    }

    fun selectAll() {
        val list = items.value ?: return
        Logger.d("ViewModel.selectAll: total=${list.size}")
        items.value = list.map { it.copy(isSelected = true) }.toMutableList()
    }

    fun deselectAll() {
        val list = items.value ?: return
        Logger.d("ViewModel.deselectAll: total=${list.size}")
        items.value = list.map { it.copy(isSelected = false) }.toMutableList()
    }

    fun getSelectedItems(): List<ClipboardItem> {
        val selected = items.value?.filter { it.isSelected } ?: emptyList()
        Logger.d("ViewModel.getSelectedItems: selected=${selected.size}")
        return selected
    }

    fun mergeSelected(): String? {
        Logger.d("ViewModel.mergeSelected: start")
        val selected = getSelectedItems()
        if (selected.isEmpty()) {
            Logger.d("ViewModel.mergeSelected: no items selected, return null")
            return null
        }
        val merged = selected.sortedByDescending { it.timestamp }
            .joinToString(separator = "\n") { it.content }
        val list = items.value ?: mutableListOf()
        list.add(0, ClipboardItem(content = merged, isSelected = false))
        items.value = list
        persist()
        Logger.d("ViewModel.mergeSelected: merged length=${merged.length}, total=${list.size}")
        return merged
    }

    fun clearAll() {
        Logger.d("ViewModel.clearAll: move all items to recycle bin")
        val list = items.value ?: mutableListOf()
        if (list.isNotEmpty()) {
            RecycleBinRepository.moveToRecycleBin(getApplication(), list, "app")
        }
        items.value = mutableListOf()
        ClipboardRepository.clearAll(getApplication())
        reloadRecycleBin()
        Logger.d("ViewModel.clearAll: done, repository also cleared")
    }

    fun deleteItem(position: Int) {
        val list = items.value ?: return
        if (position in 0 until list.size) {
            val item = list[position]
            Logger.d("ViewModel.deleteItem: position=$position, content length=${item.content.length}")
            RecycleBinRepository.moveToRecycleBin(getApplication(), listOf(item), "app")
            list.removeAt(position)
            items.value = list
            persist()
            reloadRecycleBin()
            Logger.d("ViewModel.deleteItem: done, remaining=${list.size}")
        }
    }

    // ==================== 回收站选择相关 ====================

    fun toggleRecycleSelection(position: Int) {
        val list = recycleItems.value ?: return
        if (position in 0 until list.size) {
            val item = list[position]
            list[position] = item.copy(isSelected = !item.isSelected)
            recycleItems.value = list
        }
    }

    fun selectAllRecycle() {
        val list = recycleItems.value ?: return
        recycleItems.value = list.map { it.copy(isSelected = true) }.toMutableList()
    }

    fun deselectAllRecycle() {
        val list = recycleItems.value ?: return
        recycleItems.value = list.map { it.copy(isSelected = false) }.toMutableList()
    }

    fun getSelectedRecycleItems(): List<RecyclerItem> {
        return recycleItems.value?.filter { it.isSelected } ?: emptyList()
    }

    fun getBatchIds(): List<String> {
        return RecycleBinRepository.getBatchIds(getApplication())
    }

    // ==================== 恢复操作 ====================

    private fun restoreItemsToClipboard(recyclerItems: List<RecyclerItem>) {
        if (recyclerItems.isEmpty()) return
        val list = items.value ?: mutableListOf()
        val restored = recyclerItems
            .sortedByDescending { it.timestamp }
            .map { ClipboardItem(content = it.content, timestamp = it.timestamp) }
        restored.forEach { item ->
            if (list.isEmpty() || list[0].content != item.content) {
                list.add(0, item)
            }
        }
        items.value = list
        persist()
    }

    fun restoreAll() {
        Logger.d("ViewModel.restoreAll: restoring all recycle bin items")
        val all = recycleItems.value ?: mutableListOf()
        if (all.isEmpty()) return
        restoreItemsToClipboard(all)
        RecycleBinRepository.clearAll(getApplication())
        reloadRecycleBin()
        Logger.d("ViewModel.restoreAll: restored ${all.size} items")
    }

    fun restoreSelected() {
        Logger.d("ViewModel.restoreSelected: restoring selected items")
        val selected = getSelectedRecycleItems()
        if (selected.isEmpty()) return
        restoreItemsToClipboard(selected)
        RecycleBinRepository.removeItems(getApplication(), selected.map { it.id })
        reloadRecycleBin()
        Logger.d("ViewModel.restoreSelected: restored ${selected.size} items")
    }

    fun restoreRecentBatch() {
        Logger.d("ViewModel.restoreRecentBatch: restoring most recent batch")
        val batches = getBatchIds()
        if (batches.isEmpty()) return
        val recentBatch = batches.first()
        val batchItems = recycleItems.value?.filter { it.batchId == recentBatch } ?: emptyList()
        if (batchItems.isEmpty()) return
        restoreItemsToClipboard(batchItems)
        RecycleBinRepository.removeBatch(getApplication(), recentBatch)
        reloadRecycleBin()
        Logger.d("ViewModel.restoreRecentBatch: restored batch=$recentBatch, count=${batchItems.size}")
    }

    fun restoreBatch(batchId: String) {
        Logger.d("ViewModel.restoreBatch: batchId=$batchId")
        val batchItems = recycleItems.value?.filter { it.batchId == batchId } ?: emptyList()
        if (batchItems.isEmpty()) return
        restoreItemsToClipboard(batchItems)
        RecycleBinRepository.removeBatch(getApplication(), batchId)
        reloadRecycleBin()
        Logger.d("ViewModel.restoreBatch: restored ${batchItems.size} items from batch=$batchId")
    }

    fun permanentDeleteSelected() {
        Logger.d("ViewModel.permanentDeleteSelected: deleting selected items permanently")
        val selected = getSelectedRecycleItems()
        if (selected.isEmpty()) return
        RecycleBinRepository.removeItems(getApplication(), selected.map { it.id })
        reloadRecycleBin()
        Logger.d("ViewModel.permanentDeleteSelected: deleted ${selected.size} items")
    }

    fun clearRecycleBin() {
        Logger.d("ViewModel.clearRecycleBin: emptying recycle bin permanently")
        RecycleBinRepository.clearAll(getApplication())
        reloadRecycleBin()
    }

    private fun persist() {
        val list = items.value ?: return
        ClipboardRepository.saveItems(getApplication(), list)
    }

    override fun onCleared() {
        super.onCleared()
        Logger.d("ViewModel.onCleared")
    }
}