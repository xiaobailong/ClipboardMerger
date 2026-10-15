package com.example.clipboardmerger

import android.content.res.ColorStateList
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import com.example.clipboardmerger.databinding.ItemClipboardBinding
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class ClipboardAdapter(
    private val palette: SkinPalette,
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
                // bindingAdapterPosition（adapterPosition 在 RecyclerView 1.3 起废弃）
                val pos = bindingAdapterPosition
                if (pos != RecyclerView.NO_POSITION) {
                    Logger.d("ClipboardAdapter.ViewHolder: checkbox toggled at position=$pos")
                    onToggleSelection(pos)
                }
            }
        }

        fun bind(item: ClipboardItem, position: Int) {
            // 卡片配色跟随皮肤（dialog 切皮肤后 MainActivity recreate ⇒ 适配器是新建的，颜色一定是最新的）
            binding.cardView.setCardBackgroundColor(palette.cardBg)
            binding.deleteBackground.setBackgroundColor(palette.danger)
            binding.tvIndex.setTextColor(palette.textSecondary)
            binding.tvContent.setTextColor(palette.textPrimary)
            binding.checkBox.buttonTintList = ColorStateList.valueOf(palette.accent)

            binding.tvIndex.text = "#${position + 1}  ${dateFormat.format(Date(item.timestamp))}"
            binding.tvContent.text = item.content
            binding.checkBox.setOnCheckedChangeListener(null)
            binding.checkBox.isChecked = item.isSelected
            binding.checkBox.setOnCheckedChangeListener { _, _ ->
                val pos = bindingAdapterPosition
                if (pos != RecyclerView.NO_POSITION) {
                    Logger.d("ClipboardAdapter.bind: checkbox toggled at position=$pos")
                    onToggleSelection(pos)
                }
            }
        }
    }
}