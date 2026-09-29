package com.example.clipboardmerger

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView

class ImeClipboardAdapter : RecyclerView.Adapter<ImeClipboardAdapter.ViewHolder>() {

    private val items = mutableListOf<ClipboardItem>()

    fun submitList(newList: List<ClipboardItem>) {
        items.clear()
        items.addAll(newList)
        notifyDataSetChanged()
    }

    fun getItem(position: Int): ClipboardItem? {
        return if (position in 0 until items.size) items[position] else null
    }

    fun getItems(): List<ClipboardItem> = items.toList()

    fun setItemSelected(position: Int, selected: Boolean) {
        if (position in 0 until items.size) {
            items[position] = items[position].copy(isSelected = selected)
            notifyItemChanged(position)
        }
    }

    fun toggleSelection(position: Int) {
        if (position in 0 until items.size) {
            items[position] = items[position].copy(isSelected = !items[position].isSelected)
            notifyItemChanged(position)
        }
    }

    fun clearSelection() {
        for (i in items.indices) {
            if (items[i].isSelected) {
                items[i] = items[i].copy(isSelected = false)
                notifyItemChanged(i)
            }
        }
    }

    fun getSelectedItems(): List<ClipboardItem> = items.filter { it.isSelected }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_ime_clipboard, parent, false)
        return ViewHolder(view as android.widget.LinearLayout)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        holder.bind(items[position], position)
    }

    override fun getItemCount(): Int = items.size

    inner class ViewHolder(itemView: android.widget.LinearLayout) : RecyclerView.ViewHolder(itemView) {

        private val checkBox: android.widget.CheckBox = itemView.findViewById(R.id.cbImeItem)
        private val tvContent: android.widget.TextView = itemView.findViewById(R.id.tvImeContent)

        init {
            checkBox.setOnCheckedChangeListener { _, _ ->
                val pos = adapterPosition
                if (pos != RecyclerView.NO_POSITION) {
                    toggleSelection(pos)
                }
            }
        }

        fun bind(item: ClipboardItem, position: Int) {
            tvContent.text = item.content
            checkBox.setOnCheckedChangeListener(null)
            checkBox.isChecked = item.isSelected
            checkBox.setOnCheckedChangeListener { _, _ ->
                val pos = adapterPosition
                if (pos != RecyclerView.NO_POSITION) {
                    toggleSelection(pos)
                }
            }
        }
    }
}