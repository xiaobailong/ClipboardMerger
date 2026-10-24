package com.example.clipboardmerger

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class RecyclerItem(
    val id: Long = System.currentTimeMillis(),
    val content: String,
    val timestamp: Long,
    val batchId: String,
    val deletedAt: Long,
    val source: String,
    val isSelected: Boolean = false
)

private val batchFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())

fun generateBatchId(): String = batchFormat.format(Date())

fun formatBatchTime(batchId: String): String = batchId