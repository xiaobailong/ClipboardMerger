# 绑定App 功能交接文档

> 最后更新：2026-10-01（v1.80 修复轮）| 当前代码版本：v1.80（工作区未提交；v1.79 已发布）

---

## 1. 功能概述

在设置中新增"绑定App"功能。用户选择一个应用（如"抖音"），当该应用在前台运行且剪集输入法未被激活时，自动弹出输入法切换提醒。

### 1.1 用户操作流程
1. 设置 → 绑定App → 弹出应用列表弹窗（全量已安装应用）
2. 单选目标应用（如"抖音"）
3. 首次使用需授权「使用情况访问权限」（跳系统设置页）
4. 以后打开抖音时，手机屏幕顶部弹出悬浮通知"切换到剪集输入法"
5. 点击通知 → 弹出输入法选择器 → 用户手动选择剪集

---

## 2. 涉及文件清单

| 文件 | 角色 | 变更类型 |
|---|---|---|
| `app/src/main/java/com/example/clipboardmerger/ClipboardService.kt` | 前台服务，检测前台App + 发通知 | **重写** |
| `app/src/main/java/com/example/clipboardmerger/MainActivity.kt` | 绑定App UI（弹窗、权限、保存） | **新增方法** |
| `app/src/main/java/com/example/clipboardmerger/PickerActivity.kt` | 透明Activity，调用 `showInputMethodPicker()` | **新建** |
| `app/src/main/AndroidManifest.xml` | 注册服务/权限/queries/PickerActivity | **修改** |
| `app/src/main/res/layout/dialog_bind_app.xml` | 应用列表弹窗布局 | **新建** |
| `app/src/main/res/values/strings.xml` | 绑定App相关字符串 | **新增 8 条** |

---

## 3. 核心技术方案与版本演进

### 3.1 前台App检测：UsageStats → UsageEvents

| 版本 | 方案 | 效果 |
|---|---|---|
| v1.74 | `queryUsageStats(INTERVAL_DAILY)` 按 `lastTimeUsed` 排序 | ❌ 误差大，桌面优先级高于目标App |
| v1.75+ | `usageStatsManager.queryEvents(now-15s, now)` + `MOVE_TO_FOREGROUND` | ✅ 精确捕获应用切换 |
| 间隔 | `Handler.postDelayed(runnable, 5000L)` 每 5 秒检测一次 | |

**关键代码**：[ClipboardService.kt](file:///d:/WorkSpace/test/ClipboardMerger/app/src/main/java/com/example/clipboardmerger/ClipboardService.kt#L252-L281) `getForegroundPackage()`

### 3.2 应用列表不全 → `<queries>` + `MATCH_ALL`

| 问题 | 修复 |
|---|---|
| Android 11+ 包可见性限制，只显示 21 个系统App | [AndroidManifest.xml](file:///d:/WorkSpace/test/ClipboardMerger/app/src/main/AndroidManifest.xml#L17-L20) 加 `<queries>` 声明 `MAIN` intent；[MainActivity.kt](file:///d:/WorkSpace/test/ClipboardMerger/app/src/main/java/com/example/clipboardmerger/MainActivity.kt#L800-L810) 使用 `PackageManager.MATCH_ALL` |
| 最终显示 **112 个应用** | ✅ |

### 3.3 服务保活 → 前台服务

| 问题 | 修复 |
|---|---|
| 华为/鸿蒙后台服务 1.5 秒被杀死 | [ClipboardService.kt](file:///d:/WorkSpace/test/ClipboardMerger/app/src/main/java/com/example/clipboardmerger/ClipboardService.kt#L69-L72) `startForeground()` + [AndroidManifest.xml](file:///d:/WorkSpace/test/ClipboardMerger/app/src/main/AndroidManifest.xml#L11-L12) 声明 `FOREGROUND_SERVICE_DATA_SYNC` |
| 前台通知静默 | `IMPORTANCE_MIN` 渠道，状态栏不显示图标 |
| 服务持续运行 | ✅ |

### 3.4 输入法切换提醒 — 四次方案迭代

| 版本 | 方案 | 结果 |
|---|---|---|
| v1.75 | `InputMethodManager.showInputMethodPicker()`（后台 Service 调用） | ❌ 调用被丢弃（当时误判为“华为拦截”） |
| v1.77 | 通知 → `ACTION_INPUT_METHOD_SETTINGS`（设置页） | ❌ 打开的是启用/关闭页面，不是选择器 |
| v1.78-79 | 通知 → 透明 [PickerActivity](file:///d:/WorkSpace/test/ClipboardMerger/app/src/main/java/com/example/clipboardmerger/PickerActivity.kt) → `showInputMethodPicker()`（onCreate 里立刻调） | ❌ 窗口还没拿到焦点 ⇒ 调用被 IMMS **静默忽略**；渠道无振动 ⇒ 通知只进抽屉 |
| **v1.80** | 可见卡片提醒页（拿到窗口焦点后 400ms 再调 + 1.5s 补一次 + 手动兜底）；通知换**新渠道 ID** + 全屏 Intent | ✅ 根因已定位并改完（编译通过，待真机复验） |

---

## 4. v1.80：根因与修复（待真机复验）

### 4.1 真根因（一次性说清 A / B 两个问题）

**问题 B（选择器不弹出）— 根因 = 调用时机早于“窗口拿到焦点”**：

Android 12 的 `InputMethodManagerService.canShowInputMethodPickerLocked()`（`InputMethodManagerService.java:3680-3693`）只在
①调用方就是**当前焦点窗口的 client**（`mCurFocusedWindowClient`）②或调用方 uid 拥有当前输入法 时才返回 true；
否则 `showInputMethodPickerFromClient()`（同文件 `3696-3714`）只写一句系统日志 `Slog.w("Ignoring showInputMethodPickerFromClient of uid ...")` 就 return ——
**应用侧既没有异常也没有返回值**。而 `mCurFocusedWindowClient` 只在 `startInputOrWindowGainedFocus` 成功（窗口已获得焦点）后赋值（同文件 `3503-3505`）。

v1.78 / v1.79 都在 `onCreate` 里（启动后约 8ms）就调用 ⇒ **必然被丢弃**。这不是华为特有的拦截（`PIT-028` 已按此修正）。

真机日志（v1.79 实跑，`jianji_log_2026-10-01.txt`）：
```
00:52:42.841  bind app notification sent for [抖音]
00:53:01.517  PickerActivity: onCreate, showing input method picker
00:53:01.525  PickerActivity: showInputMethodPicker called, will finish after 1.5s delay
00:53:03.109  PickerActivity: destroyed        ← 活了 1.5s、调用没抛异常，选择器就是不出现
```
（§5 里“v1.79 未见运行记录”的旧结论作废：日志中确有 v1.79 记录。）

**问题 A（通知不悬浮）— 根因 = 渠道属性不可变 + 只发普通通知**：
`bind_app_channel` 是 v1.77 创建的（未开振动），Android 渠道属性创建后不再更新：v1.78 改代码加 `enableVibration`、
v1.79 对**同一 ID** `deleteNotificationChannel` + 重建，实测都无效（通知仍只进抽屉）⇒ 只能换新 ID。

### 4.2 v1.80 的改动

| 文件 | 改动 |
|---|---|
| `PickerActivity.kt` | 重写：**可见**半透明卡片页；`onWindowFocusChanged(true)` 后延迟 `400ms` 调 `showInputMethodPicker()`，再等 `1500ms` 若窗口焦点仍在（= 被忽略）补一次；窗口失焦后再回来 ⇒ 自动 `finish()`（回到抖音）；`60s` 兜底自动关闭 |
| `res/layout/activity_picker.xml` | 新建：遮罩 + 卡片 + 文案 + 三个按钮（弹出选择器 / 打开系统输入法设置 / 关闭） |
| `res/values/themes.xml` | 新增 `Theme.JianJi.Picker`（`windowIsTranslucent` + 透明 windowBackground + 无标题） |
| `res/values/colors.xml`、`res/values/strings.xml` | 新增 `picker_scrim` + 7 条文案 |
| `AndroidManifest.xml` | `PickerActivity` 换 `Theme.JianJi.Picker`；新增 `USE_FULL_SCREEN_INTENT` 权限 |
| `ClipboardService.kt` | 渠道 ID → `bind_app_channel_v2`（HIGH + 振动 + badge）并删掉 `bind_app_channel`；通知加 `setFullScreenIntent(pendingIntent, true)` + `VISIBILITY_PUBLIC`；启动时打一行诊断；通知 Intent 携带 App 名给提醒页 |

### 4.3 真机验证步骤（下次照做）

1. 安装 v1.80 → 打开剪集 → 设置 → 绑定App → 选抖音（确认「使用情况访问权限」已开）
2. 打开抖音：**期望**顶部出现悬浮横幅，或直接弹出「切换到剪集输入法」提醒卡片
3. 点卡片上的「弹出输入法选择器」：**期望**系统输入法选择器出现；选「剪集」后卡片自动消失
4. 若选择器仍不出现：日志会有两条 `showInputMethodPicker() called` + 一条 `window still focused ... picker may have been ignored`，
   用卡片上的「打开系统输入法设置」手动切换（华为兜底）
5. 要看的日志行：`notificationsEnabled=... importance=... shouldVibrate=...`、`bind app notification sent for [...]`、
   `PickerActivity: onWindowFocusChanged hasFocus=true, attempts=0`、`showInputMethodPicker() called (attempt=1)`

---

## 5. 日志文件路径

| 类型 | 路径 |
|---|---|
| **手机端日志**（从 app 导出） | `/storage/emulated/0/Download/JianJi/jianji_log_YYYY-MM-DD.txt` |
| **PC 端复制后** | `C:\Users\766698\Downloads\jianji_log_YYYY-MM-DD.txt` |
| **本次对话涉及日志** | `C:\Users\766698\Downloads\jianji_log_2026-10-01.txt` |

### 日志关键关键词 grep
```
checkForegroundApp      → 检测触发
bound app.*foreground   → 命中绑定App
sending notification    → 发通知
bind app notification   → 通知已发送
PickerActivity          → 用户点击了通知
showInputMethodPicker   → 选择器调用
cooldown active         → 冷却中，跳过
no MOVE_TO_FOREGROUND   → 15s 内无前台切换事件
```

### 本次对话日志中版本分布

| 版本行 | 时间 | 关键事件 |
|---|---|---|
| v1.75 L1-102 | 00:00:34 | 初始版本：`showInputMethodPicker()` 调用但华为拦截 |
| v1.76 L103-207 | 00:08:34 | 加 `UsageEvents` → 精确检测到抖音 `00:08:44` |
| v1.77 L208-283 | 00:17:24 | 通知方案：`notification sent for [抖音]` → 用户点开是设置页 |
| v1.78 L284-470 | 00:36:44 | PickerActivity 方案：通知发送成功 + Activity 启动 → 选择器没出来 |
| v1.79 L472-793 | 00:52:37 | 实跑记录：`notification sent` → 18s 后用户点通知 → `showInputMethodPicker` 调用 → 1.5s 后 destroyed，选择器仍不出现 |

---

## 6. 关键常量

| 常量 | 值 | 位置 |
|---|---|---|
| 检测间隔 | `5000L` ms | ClipboardService.kt `startForegroundAppCheck()` |
| 冷却时间 | `120_000L` ms（2分钟） | ClipboardService.kt `PICKER_COOLDOWN_MS` |
| UsageEvents 窗口 | `15_000L` ms（15秒） | ClipboardService.kt `getForegroundPackage()` |
| PickerActivity 自动关闭 | `60_000L` ms | PickerActivity.kt `AUTO_CLOSE_MS` |
| 调选择器延迟 / 补一次 | `400L` / `1500L` ms | PickerActivity.kt `PICKER_DELAY_MS` / `RETRY_DELAY_MS` |
| 渠道ID | `bind_app_channel_v2`（旧的 `bind_app_channel` 已删除） | ClipboardService.kt `BIND_CHANNEL_ID` |
| 通知ID | `2` | ClipboardService.kt `BIND_NOTIFICATION_ID` |
| Settings key | `bound_app_package` / `bound_app_label` | MainActivity.kt / ClipboardService.kt |

---

## 7. 下一步建议

1. 真机验证 v1.80（步骤见 §4.3），重点看：通知是否悬浮 / 提醒卡片是否弹出 / 选择器是否出现
2. 若选择器仍不出现：看日志区分「窗口焦点没拿到」还是「拿到焦点仍被系统忽略」
   —— 后者可考虑上「悬浮窗按钮（`SYSTEM_ALERT_WINDOW`）」方案（点悬浮按钮 → 打开提醒卡片 → 再调选择器）
3. 通知渠道：换新 ID 后是全新渠道（默认开启 + 振动）。若用户在系统设置里动过旧渠道的开关，新渠道不受影响
4. 兜底方案（永远可用）：`Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)` 已在提醒卡片里做成按钮

---

## 8. 设备信息

| 项目 | 值 |
|---|---|
| 测试设备 | HUAWEI LIO-AN00m |
| Android SDK | 31 (Android 12) |
| 系统类型 | HarmonyOS / EMUI |
| 敏感行为 | 拦截 `showInputMethodPicker()` 后台调用、激进杀后台服务 |