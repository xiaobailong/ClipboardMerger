package com.example.clipboardmerger

import android.content.res.ColorStateList
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.example.clipboardmerger.databinding.ItemClipboardBinding

class RecycleBinAdapter(
    private val palette: SkinPalette,
    private val onToggleSelection: (Int) -> Unit,
    private val onDelete: (Int) -> Unit
) : RecyclerView.Adapter<RecycleBinAdapter.ViewHolder>() {

    private val items = mutableListOf<RecyclerItem>()

    fun submitList(newList: List<RecyclerItem>) {
        items.clear()
        items.addAll(newList)
        Logger.d("RecycleBinAdapter.submitList: count=${items.size}")
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val binding = ItemClipboardBinding.inflate(
            LayoutInflater.from(parent.context), parent, false
        )
        return ViewHolder(binding)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        holder.bind(items[position])
    }

    override fun getItemCount(): Int = items.size

    inner class ViewHolder(val binding: ItemClipboardBinding) :
        RecyclerView.ViewHolder(binding.root) {

        val cardView = binding.cardView

        init {
            binding.checkBox.setOnCheckedChangeListener { _, _ ->
                val pos = bindingAdapterPosition
                if (pos != RecyclerView.NO_POSITION) {
                    Logger.d("RecycleBinAdapter.ViewHolder: checkbox toggled at position=$pos")
                    onToggleSelection(pos)
                }
            }
        }

        fun bind(item: RecyclerItem) {
            binding.cardView.setCardBackgroundColor(palette.cardBg)
            binding.deleteBackground.setBackgroundColor(palette.danger)
            binding.tvIndex.setTextColor(palette.textSecondary)
            binding.tvContent.setTextColor(palette.textPrimary)
            binding.checkBox.buttonTintList = ColorStateList.valueOf(palette.accent)

            val sourceLabel = if (item.source == "ime") "键盘" else "应用"
            binding.tvIndex.text = "$sourceLabel · ${item.batchId}"
            binding.tvContent.text = item.content
            binding.checkBox.setOnCheckedChangeListener(null)
            binding.checkBox.isChecked = item.isSelected
            binding.checkBox.setOnCheckedChangeListener { _, _ ->
                val pos = bindingAdapterPosition
                if (pos != RecyclerView.NO_POSITION) {
                    Logger.d("RecycleBinAdapter.bind: checkbox toggled at position=$pos")
                    onToggleSelection(pos)
                }
            }
        }
    }
}