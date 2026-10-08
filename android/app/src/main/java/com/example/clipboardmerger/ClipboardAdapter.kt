package com.example.clipboardmerger

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.example.clipboardmerger.databinding.ItemClipboardBinding
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ClipboardAdapter(
    private val onToggleSelection: (Int) -> Unit,
    private val onDelete: (Int) -> Unit
) : RecyclerView.Adapter<ClipboardAdapter.ViewHolder>() {

    private val items = mutableListOf<ClipboardItem>()
    private val dateFormat = SimpleDateFormat("HH:mm:ss", Locale.getDefault())

    fun submitList(newList: List<ClipboardItem>) {
        items.clear()
        items.addAll(newList)
        Logger.d("ClipboardAdapter.submitList: count=${items.size}")
        notifyDataSetChanged()
    }

    fun removeItem(position: Int) {
        if (position in 0 until items.size) {
            items.removeAt(position)
            notifyItemRemoved(position)
            notifyItemRangeChanged(position, items.size - position)
            Logger.d("ClipboardAdapter.removeItem: position=$position, remaining=${items.size}")
        }
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        Logger.d("ClipboardAdapter.onCreateViewHolder")
        val binding = ItemClipboardBinding.inflate(
            LayoutInflater.from(parent.context), parent, false
        )
        return ViewHolder(binding)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        holder.bind(items[position], position)
    }

    override fun getItemCount(): Int = items.size

    inner class ViewHolder(val binding: ItemClipboardBinding) :
        RecyclerView.ViewHolder(binding.root) {

        val cardView = binding.cardView

        init {
            binding.checkBox.setOnCheckedChangeListener { _, _ ->
                val pos = adapterPosition
                if (pos != RecyclerView.NO_POSITION) {
                    Logger.d("ClipboardAdapter.ViewHolder: checkbox toggled at position=$pos")
                    onToggleSelection(pos)
                }
            }
        }

        fun bind(item: ClipboardItem, position: Int) {
            binding.tvIndex.text = "#${position + 1}  ${dateFormat.format(Date(item.timestamp))}"
            binding.tvContent.text = item.content
            binding.checkBox.setOnCheckedChangeListener(null)
            binding.checkBox.isChecked = item.isSelected
            binding.checkBox.setOnCheckedChangeListener { _, _ ->
                val pos = adapterPosition
                if (pos != RecyclerView.NO_POSITION) {
                    Logger.d("ClipboardAdapter.bind: checkbox toggled at position=$pos")
                    onToggleSelection(pos)
                }
            }
        }
    }
}