package com.example.clipboardmerger

data class ClipboardItem(
    val id: Long = System.currentTimeMillis(),
    val content: String,
    val timestamp: Long = System.currentTimeMillis(),
    val isSelected: Boolean = false
)