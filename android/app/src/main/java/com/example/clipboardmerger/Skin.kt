package com.example.clipboardmerger

import android.content.Context

/**
 * 皮肤 id（取值与鸿蒙版 `model/Theme.ets` 的 THEME_HARMONY / THEME_ANDROID 对齐，便于两端对照）
 * - 鸿蒙风：清淡白 + 蓝色强调色（默认）
 * - Android 原版：紫顶栏 + 深绿键盘（改动前的原样）
 */
const val SKIN_HARMONY = "harmony"
const val SKIN_ANDROID = "android"

/** 一套皮肤的全部颜色（主界面 + 输入法面板） */
class SkinPalette(
    val pageBg: Int,
    val barBg: Int,
    val barText: Int,
    val barTextDim: Int,
    val tabIndicator: Int,
    val cardBg: Int,
    val textPrimary: Int,
    val textSecondary: Int,
    val accent: Int,
    val danger: Int,
    val statusOffBg: Int,
    val statusOffFg: Int,
    val statusOnBg: Int,
    val statusOnFg: Int,
    val bindBg: Int,
    val bindFg: Int,
    val imeBg: Int,
    val imeBarBg: Int,
    /** 输入法按钮底色，顺序固定：粘贴 / 全部粘贴 / 切换 / 删除 / 清空 / ▼隐藏 / ⚙设置 */
    val imeKeyColors: List<Int>,
    val imeKeyFg: Int,
    val imeItemBg: Int,
    val imeItemFg: Int,
    val imeMark: Int,
    val imeStatusBg: Int,
    val imeStatusFg: Int
)

/** 鸿蒙风：清淡白（对齐鸿蒙版 HARMONY_PALETTE） */
val HARMONY_SKIN: SkinPalette = SkinPalette(
    pageBg = 0xFFF2F2F7.toInt(),
    barBg = 0xFFFFFFFF.toInt(),
    barText = 0xFF1C1C1E.toInt(),
    barTextDim = 0xFF8E8E93.toInt(),
    tabIndicator = 0xFF0A59F7.toInt(),
    cardBg = 0xFFFFFFFF.toInt(),
    textPrimary = 0xFF1C1C1E.toInt(),
    textSecondary = 0xFF8E8E93.toInt(),
    accent = 0xFF0A59F7.toInt(),
    danger = 0xFFE84026.toInt(),
    statusOffBg = 0xFFFFF7E6.toInt(),
    statusOffFg = 0xFFB26A00.toInt(),
    statusOnBg = 0xFFEAF7EE.toInt(),
    statusOnFg = 0xFF1F7A3D.toInt(),
    bindBg = 0xFFEAF1FF.toInt(),
    bindFg = 0xFF0A59F7.toInt(),
    imeBg = 0xFFF2F2F7.toInt(),
    imeBarBg = 0xFFFFFFFF.toInt(),
    imeKeyColors = listOf(
        0xFFE9E9EB.toInt(), 0xFFE9E9EB.toInt(), 0xFFE9E9EB.toInt(), 0xFFE9E9EB.toInt(),
        0xFFE9E9EB.toInt(), 0xFFE9E9EB.toInt(), 0xFFE9E9EB.toInt()
    ),
    imeKeyFg = 0xFF1C1C1E.toInt(),
    imeItemBg = 0xFFFFFFFF.toInt(),
    imeItemFg = 0xFF1C1C1E.toInt(),
    imeMark = 0xFF8C8C8C.toInt(),
    imeStatusBg = 0xFFE5E5EA.toInt(),
    imeStatusFg = 0xFF6E6E73.toInt()
)

/** Android 原版：紫顶栏 + 白卡片 + 深绿键盘（取值来自改动前的 colors.xml 与 layout/ime_view.xml） */
val ANDROID_SKIN: SkinPalette = SkinPalette(
    pageBg = 0xFFF5F5F5.toInt(),
    barBg = 0xFF6200EE.toInt(),
    barText = 0xFFFFFFFF.toInt(),
    barTextDim = 0x80FFFFFF.toInt(),
    tabIndicator = 0xFFFFFFFF.toInt(),
    cardBg = 0xFFFFFFFF.toInt(),
    textPrimary = 0xDE000000.toInt(),
    textSecondary = 0x99000000.toInt(),
    accent = 0xFF6200EE.toInt(),
    danger = 0xFFE53935.toInt(),
    statusOffBg = 0xFFFFF3E0.toInt(),
    statusOffFg = 0xFFE65100.toInt(),
    statusOnBg = 0xFFE8F5E9.toInt(),
    statusOnFg = 0xFF2E7D32.toInt(),
    bindBg = 0xFFE3F2FD.toInt(),
    bindFg = 0xFF1565C0.toInt(),
    imeBg = 0xFF14501E.toInt(),
    imeBarBg = 0xFF1B5E20.toInt(),
    imeKeyColors = listOf(
        0xFF388E3C.toInt(), 0xFFFF9800.toInt(), 0xFF2E7D32.toInt(), 0xFFD32F2F.toInt(),
        0xFFB00020.toInt(), 0xFF455A64.toInt(), 0xFF37474F.toInt()
    ),
    imeKeyFg = 0xFFFFFFFF.toInt(),
    imeItemBg = 0xFF1A3A1A.toInt(),
    imeItemFg = 0xFFE8F5E9.toInt(),
    imeMark = 0xFFA5D6A7.toInt(),
    imeStatusBg = 0xFF0D3D13.toInt(),
    imeStatusFg = 0xFFFFFFFF.toInt()
)

/**
 * 皮肤设置的唯一入口：持久化在 `clipboard_merger_settings / skin_id`。
 *
 * App（Activity）与「剪集输入法」（InputMethodService）同进程、同一份 SharedPreferences，
 * 所以两边共用一套皮肤：App 里改完，键盘每次显示（onStartInputView）重读一次即生效。
 * 读都走 [palette]/[get]，不要在别处硬编码颜色。
 */
object SkinStore {

    const val PREFS_NAME = "clipboard_merger_settings"
    const val KEY_SKIN = "skin_id"

    /** 当前皮肤 id（缺省 / 异常一律回鸿蒙风） */
    fun get(context: Context): String {
        return try {
            val raw = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(KEY_SKIN, SKIN_HARMONY)
            if (raw == SKIN_ANDROID) SKIN_ANDROID else SKIN_HARMONY
        } catch (e: Exception) {
            Logger.w("SkinStore.get failed: ${e.message}, fallback=$SKIN_HARMONY")
            SKIN_HARMONY
        }
    }

    /** 切换并持久化 */
    fun set(context: Context, id: String) {
        try {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_SKIN, id)
                .apply()
            Logger.d("SkinStore.set: $id")
        } catch (e: Exception) {
            Logger.w("SkinStore.set failed: ${e.message}")
        }
    }

    fun palette(context: Context): SkinPalette = paletteOf(get(context))

    fun paletteOf(id: String): SkinPalette =
        if (id == SKIN_ANDROID) ANDROID_SKIN else HARMONY_SKIN

    /** 皮肤中文名（弹框 / 状态栏文案统一从这里取） */
    fun displayName(context: Context, id: String): String =
        context.getString(if (id == SKIN_ANDROID) R.string.skin_name_android else R.string.skin_name_harmony)
}
