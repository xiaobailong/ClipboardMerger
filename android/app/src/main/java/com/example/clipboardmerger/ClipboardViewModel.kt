package com.example.clipboardmerger

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.MutableLiveData

class ClipboardViewModel(application: Application) : AndroidViewModel(application) {

    val items: MutableLiveData<MutableList<ClipboardItem>> = MutableLiveData(
        ClipboardRepository.loadItems(application)
    )

    fun reloadFromRepository() {
        val saved = ClipboardRepository.loadItems(getApplication())
        Logger.d("ViewModel.reloadFromRepository: loading from repository, got ${saved.size} items")
        items.value = saved
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
        Logger.d("ViewModel.clearAll: clearing all items")
        items.value = mutableListOf()
        ClipboardRepository.clearAll(getApplication())
        Logger.d("ViewModel.clearAll: done, repository also cleared")
    }

    fun deleteItem(position: Int) {
        val list = items.value ?: return
        if (position in 0 until list.size) {
            Logger.d("ViewModel.deleteItem: position=$position, content length=${list[position].content.length}")
            list.removeAt(position)
            items.value = list
            persist()
            Logger.d("ViewModel.deleteItem: done, remaining=${list.size}")
        }
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